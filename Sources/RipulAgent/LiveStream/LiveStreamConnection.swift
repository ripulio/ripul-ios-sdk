import Foundation
import Network
import Security

// MARK: - Protection

/// A direct Live View connection's protection: TLS 1.2 keyed by a one-time
/// session key that the app hands out only through the account's relay
/// (`live_stream_offer`), with an ephemeral ECDHE exchange on top — so the
/// key alone, which the relay carried, can't decrypt a recording of the
/// session. No certificates on either side: iOS can't mint an identity in
/// memory the way the Mac's LAN mirror does with openssl.
///
/// Network.framework has no TLS 1.3 external pre-shared key (the handshake
/// fails), hence 1.2. It also falls back to plain PSK, silently, when it
/// can't use a suite asked for — so each end checks the negotiated suite
/// (`isProtected`) before trusting the connection.
public enum LiveStreamTLS {
    /// TLS_ECDHE_PSK_WITH_AES_256_CBC_SHA, TLS_ECDHE_PSK_WITH_AES_128_CBC_SHA.
    static let suites: [UInt16] = [0xC036, 0xC035]

    public static func parameters(key: Data, session: String) -> NWParameters {
        parameters(key: key, session: session, suites: suites)
    }

    /// Any suite list — tests use it to offer a suite the app must refuse.
    static func parameters(key: Data, session: String, suites: [UInt16]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(session.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        for suite in suites {
            if let value = tls_ciphersuite_t(rawValue: suite) {
                sec_protocol_options_append_tls_ciphersuite(options, value)
            }
        }
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// True once the handshake settled on one of `suites`.
    public static func isProtected(_ connection: NWConnection) -> Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return false
        }
        let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata)
        return suites.contains(suite.rawValue)
    }

    /// A fresh 256-bit session key.
    public static func newKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No system randomness for a Live View key")
        return Data(bytes)
    }
}

public enum LiveStreamError: Error, LocalizedError, Equatable {
    case closed
    case malformed
    case unprotected
    case timedOut
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .closed: "The direct connection closed"
        case .malformed: "The direct connection sent something unreadable"
        case .unprotected: "The direct connection wasn't protected as required"
        case .timedOut: "The direct connection didn't answer in time"
        case .refused(let reason): reason
        }
    }
}

// MARK: - Framed messages

/// `LiveStreamWire` messages over one protected connection.
public final class LiveStreamChannel: @unchecked Sendable {
    public let connection: NWConnection
    private let receiveLimit: Int
    private let lock = NSLock()
    private var inFlight = 0

    public init(_ connection: NWConnection, receiveLimit: Int) {
        self.connection = connection
        self.receiveLimit = receiveLimit
    }

    /// Bytes handed to the connection and not yet sent. Video checks it and
    /// skips a frame rather than let delay build up behind a slow network.
    public var pendingBytes: Int { lock.withLock { inFlight } }

    public func send(_ type: LiveStreamMessage, _ payload: Data) async throws {
        let data = LiveStreamWire.frame(type, payload)
        adjust(data.count)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                self?.adjust(-data.count)
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func send(_ type: LiveStreamMessage, json: [String: Any]) async throws {
        try await send(type, (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8))
    }

    /// Queue without waiting — for video, whose sender watches `pendingBytes`.
    public func enqueue(_ type: LiveStreamMessage, _ payload: Data) {
        let data = LiveStreamWire.frame(type, payload)
        adjust(data.count)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.adjust(-data.count) })
    }

    /// The next message of a kind this build knows; others are read and dropped.
    public func receive() async throws -> (type: LiveStreamMessage, payload: Data) {
        while true {
            let header = try await read(LiveStreamWire.headerLength)
            guard let (kind, length) = LiveStreamWire.rawHeader(header, limit: receiveLimit) else {
                throw LiveStreamError.malformed
            }
            let payload = length == 0 ? Data() : try await read(length)
            if let type = LiveStreamMessage(rawValue: kind) { return (type, payload) }
        }
    }

    public func close() { connection.cancel() }

    private func adjust(_ bytes: Int) { lock.withLock { inFlight += bytes } }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: LiveStreamError.closed) }
            }
        }
    }
}

/// Runs its body at most once, whichever callback gets there first.
final class LiveStreamOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    @discardableResult
    func run(_ body: () -> Void) -> Bool {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
        return first
    }
}

extension NWConnection {
    /// Starts the connection and waits until it's ready. A refusal, a failed
    /// handshake (a wrong key shows up as waiting), cancellation or the
    /// timeout all throw, and cancel the connection.
    func liveStreamReady(queue: DispatchQueue, timeout: TimeInterval) async throws {
        let once = LiveStreamOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        once.run { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        if once.run({ continuation.resume(throwing: error) }) { self?.cancel() }
                    case .cancelled:
                        once.run { continuation.resume(throwing: LiveStreamError.closed) }
                    default:
                        break
                    }
                }
                start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    if once.run({ continuation.resume(throwing: LiveStreamError.timedOut) }) { self?.cancel() }
                }
            }
        } onCancel: {
            cancel()
        }
    }
}
