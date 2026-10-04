import Foundation
import Network

/// The network a voice socket connected or dropped on, for `[VOICE-STT]`
/// lines. The TLS failure that drops these sockets (-9820, the peer rejecting
/// a record) has been seen on one phone in clusters, and nothing recorded
/// whether those were Wi-Fi or cellular, IPv4 or IPv6, tunnelled or not.
///
/// Interface classes only. No addresses, network names or host names, so the
/// summary is safe for the persisted voice journal.
final class VoiceNetworkPath: @unchecked Sendable {
    static let shared = VoiceNetworkPath()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var latest: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.latest = path
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "io.ripul.speech.network-path", qos: .utility))
    }

    var summary: String {
        lock.lock()
        let path = latest ?? monitor.currentPath
        lock.unlock()
        return Self.describe(path)
    }

    /// Interfaces in the order the system prefers them. `other` first is a
    /// tunnel (a VPN, Tailscale) carrying the traffic.
    static func describe(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map { interface -> String in
            switch interface.type {
            case .wifi: return "wifi"
            case .cellular: return "cellular"
            case .wiredEthernet: return "wired"
            case .loopback: return "loopback"
            case .other: return "other"
            @unknown default: return "unknown"
            }
        }
        let status: String
        switch path.status {
        case .satisfied: status = "up"
        case .unsatisfied: status = "down"
        case .requiresConnection: status = "dormant"
        @unknown default: status = "unknown"
        }
        return "net=\(interfaces.isEmpty ? "none" : interfaces.joined(separator: "+")) path=\(status) expensive=\(path.isExpensive) constrained=\(path.isConstrained) ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6)"
    }
}

/// Logs how each buffered voice socket was carried, once its handshake ends:
/// HTTP version, TLS version and cipher, address family, and whether the
/// connection was cellular, proxied or multipath. Attached per task, so the
/// sockets stay on the session they already used.
final class SpeechSocketMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SpeechSocketMetrics()

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        voiceDiagnostic("[VOICE-STT] socket \(Self.describe(transaction)) handshakeMs=\(Int(metrics.taskInterval.duration * 1000)) stream=\(task.taskDescription ?? "none")")
    }

    static func describe(_ transaction: URLSessionTaskTransactionMetrics) -> String {
        let tls: String
        switch transaction.negotiatedTLSProtocolVersion {
        case .TLSv13?: tls = "1.3"
        case .TLSv12?: tls = "1.2"
        case let other?: tls = String(format: "0x%04x", other.rawValue)
        case nil: tls = "none"
        }
        let cipher = transaction.negotiatedTLSCipherSuite.map { String(format: "0x%04x", $0.rawValue) } ?? "none"
        // The address itself is not logged, only its family.
        let family = transaction.remoteAddress.map { $0.contains(":") ? "v6" : "v4" } ?? "unknown"
        return "protocol=\(transaction.networkProtocolName ?? "unknown") tls=\(tls) cipher=\(cipher) ip=\(family) cellular=\(transaction.isCellular) expensive=\(transaction.isExpensive) constrained=\(transaction.isConstrained) multipath=\(transaction.isMultipath) proxy=\(transaction.isProxyConnection) reused=\(transaction.isReusedConnection)"
    }
}
