import Foundation
import Network
import Darwin

// MARK: - The app's end

/// The app's end of a direct Live View session: listens on an ephemeral port
/// for exactly one viewer holding this session's key. The first connection
/// that completes a protected handshake and says hello naming the session
/// wins; the listener then stops, and every other connection is closed. It
/// also stops at `accept`'s deadline or on `cancel`, so a port is open only
/// between an offer and its viewer arriving.
public final class LiveStreamListener: @unchecked Sendable {
    public typealias Accepted = (channel: LiveStreamChannel, hello: [String: Any])

    public let session: String
    public let key: Data
    /// Connections still handshaking or saying hello, at most.
    static let maxPending = 4
    /// How long a connection has, once connected, to say hello.
    static let helloDeadline: TimeInterval = 5

    private let queue = DispatchQueue(label: "io.ripul.livestream.listener")
    private var listener: NWListener?
    private var pending: [ObjectIdentifier: NWConnection] = [:]
    private var outcome: Result<Accepted, Error>?
    private var waiter: CheckedContinuation<Accepted, Error>?

    public init(session: String = UUID().uuidString, key: Data = LiveStreamTLS.newKey()) {
        self.session = session
        self.key = key
    }

    /// Starts listening on every interface; returns the port.
    public func start() async throws -> UInt16 {
        let listener = try NWListener(using: LiveStreamTLS.parameters(key: key, session: session), on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.admit(connection) }
        let once = LiveStreamOnce()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error), .waiting(let error):
                    once.run { continuation.resume(throwing: error) }
                    self?.finish(.failure(error), winner: nil)
                case .cancelled:
                    once.run { continuation.resume(throwing: LiveStreamError.closed) }
                default:
                    break
                }
            }
            queue.async {
                self.listener = listener
                listener.start(queue: self.queue)
            }
        }
    }

    /// Waits for the viewer, up to `timeout`; the listener stops either way.
    public func accept(timeout: TimeInterval) async throws -> Accepted {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(LiveStreamError.timedOut), winner: nil)
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let outcome = self.outcome { continuation.resume(with: outcome) } else { self.waiter = continuation }
            }
        }
    }

    public func cancel() {
        queue.async { self.finish(.failure(LiveStreamError.closed), winner: nil) }
    }

    // Everything below runs on `queue`.

    private func admit(_ connection: NWConnection) {
        guard listener != nil, outcome == nil, pending.count < Self.maxPending else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        pending[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready: self.greet(connection)
            case .waiting: connection.cancel()
            case .failed, .cancelled: self.pending.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.helloDeadline) { [weak self] in
            self?.pending.removeValue(forKey: id)?.cancel()
        }
    }

    private func greet(_ connection: NWConnection) {
        guard LiveStreamTLS.isProtected(connection) else {
            connection.cancel()
            return
        }
        let channel = LiveStreamChannel(connection, receiveLimit: LiveStreamWire.maxToApp)
        let session = session
        Task { [weak self] in
            do {
                let (type, payload) = try await channel.receive()
                let hello = LiveStreamWire.json(payload)
                guard type == .hello, hello["session"] as? String == session else {
                    throw LiveStreamError.refused("Not this session")
                }
                self?.queue.async { self?.finish(.success((channel, hello)), winner: connection) }
            } catch {
                connection.cancel()
            }
        }
    }

    private func finish(_ result: Result<Accepted, Error>, winner: NWConnection?) {
        guard outcome == nil else {
            winner?.cancel()
            return
        }
        outcome = result
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        if let winner {
            winner.stateUpdateHandler = nil
            pending.removeValue(forKey: ObjectIdentifier(winner))
        }
        for connection in pending.values { connection.cancel() }
        pending.removeAll()
        waiter?.resume(with: result)
        waiter = nil
    }
}

// MARK: - The viewer's end

public enum LiveStreamClient {
    /// Tries the addresses in the order given, each starting `stagger` after
    /// the one before, and keeps the first that completes a protected
    /// handshake within `timeout`; then says hello. The others are closed,
    /// including any that connect a moment later. Put the preferred route
    /// first: the head start is what makes Wi-Fi win over Tailscale when
    /// both work.
    public static func connect(to addresses: [String], port: UInt16, key: Data, session: String,
                               hello: [String: Any] = [:], timeout: TimeInterval,
                               stagger: TimeInterval = 0.25) async throws
        -> (channel: LiveStreamChannel, address: String) {
        guard let port = NWEndpoint.Port(rawValue: port), !addresses.isEmpty else {
            throw LiveStreamError.refused("No address to connect to")
        }
        let queue = DispatchQueue(label: "io.ripul.livestream.client")
        var lastError: Error = LiveStreamError.timedOut
        let winner: (LiveStreamChannel, String)? = await withTaskGroup(of: Result<(LiveStreamChannel, String), Error>.self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask {
                    if index > 0 {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(Double(index) * stagger * 1_000_000_000))
                        } catch {
                            return .failure(error)
                        }
                    }
                    let connection = NWConnection(host: NWEndpoint.Host(address), port: port,
                                                  using: LiveStreamTLS.parameters(key: key, session: session))
                    do {
                        try await connection.liveStreamReady(queue: queue, timeout: timeout)
                        guard LiveStreamTLS.isProtected(connection) else {
                            connection.cancel()
                            throw LiveStreamError.unprotected
                        }
                        return .success((LiveStreamChannel(connection, receiveLimit: LiveStreamWire.maxToViewer), address))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var first: (LiveStreamChannel, String)?
            while let result = await group.next() {
                switch result {
                case .success(let connected):
                    if first == nil {
                        first = connected
                        group.cancelAll()
                    } else {
                        connected.0.close()
                    }
                case .failure(let error):
                    if !(error is CancellationError) { lastError = error }
                }
            }
            return first
        }
        guard let (channel, address) = winner else { throw lastError }
        var greeting = hello
        greeting["session"] = session
        do {
            try await channel.send(.hello, json: greeting)
        } catch {
            channel.close()
            throw error
        }
        return (channel, address)
    }
}

// MARK: - Where a viewer can reach this device

public enum LiveStreamAddresses {
    public enum Route: String, Sendable {
        /// The same Wi-Fi or Ethernet (private IPv4).
        case lan
        /// Tailscale's address range, 100.64.0.0/10.
        case tailnet
    }

    /// This device's IPv4 addresses a viewer might reach, Wi-Fi first: up to
    /// four private ones and one Tailscale one.
    public static func current() -> [(address: String, route: Route)] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var lan: [String] = [], tailnet: [String] = []
        var cursor = interfaces
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: name)
            switch route(for: value) {
            case .lan where !lan.contains(value): lan.append(value)
            case .tailnet where !tailnet.contains(value): tailnet.append(value)
            default: break
            }
        }
        return lan.prefix(4).map { ($0, .lan) } + tailnet.prefix(1).map { ($0, .tailnet) }
    }

    /// Which route a canonical dotted IPv4 address belongs to; nil for any other address.
    public static func route(for address: String) -> Route? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { part in UInt8(part).flatMap { String($0) == part ? Int($0) : nil } }
        guard bytes.count == 4 else { return nil }
        switch (bytes[0], bytes[1]) {
        case (10, _), (172, 16...31), (192, 168), (169, 254): return .lan
        case (100, 64...127): return .tailnet
        default: return nil
        }
    }
}
