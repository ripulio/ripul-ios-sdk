import Foundation
import Network

// MARK: - A session through a relay room
//
// A direct Live View connection needs its two devices on one network or one
// tailnet. A support session has neither: the customer's phone is wherever it
// is, and signed in to nothing of Ripul's. So each end connects out to a room
// on Ripul's servers (`SupportRoom` in the worker) and the room passes
// `LiveStreamWire` frames between them, one frame a WebSocket message.
//
// The room decides what crosses: the app's picture one way, and where the
// supporter points the other. It says who is there in `room` messages.

public enum LiveStreamRelay {
    public enum Role: String, Sendable {
        /// The app being shown.
        case customer
        /// The person looking at it.
        case supporter
    }

    /// Ripul's API host, where the rooms are. A WebSocket goes to it directly: the
    /// app host's `/api` path, which HTTP calls use, turns sockets away.
    public static let server = URL(string: RipulDomain.llmProxyURL)!

    /// The room's address for one end of the session with this code.
    public static func url(server: URL = server, code: String, role: Role, token: String) -> URL? {
        let path = server.appendingPathComponent("v1/support/sessions/\(code)/ws")
        guard var parts = URLComponents(url: path, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.queryItems = [URLQueryItem(name: "role", value: role.rawValue), URLQueryItem(name: "token", value: token)]
        return parts.url
    }

    /// Opens one end's connection to the room. Throws when the room turns it
    /// away (the session is over, or the token isn't its own) or can't be
    /// reached in `timeout`.
    public static func connect(server: URL = server, code: String, role: Role, token: String,
                               timeout: TimeInterval = 10) async throws -> LiveStreamChannel {
        guard let url = url(server: server, code: code, role: role, token: token) else {
            throw LiveStreamError.refused("The support session's address is not valid")
        }
        let limit = role == .customer ? LiveStreamWire.maxToApp : LiveStreamWire.maxToViewer
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        socket.maximumMessageSize = limit + LiveStreamWire.headerLength
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = url.scheme == "ws" ? NWParameters(tls: nil, tcp: tcp)
                                            : NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        try await connection.liveStreamReady(queue: DispatchQueue(label: "io.ripul.livestream.relay"), timeout: timeout)
        return LiveStreamChannel(connection, receiveLimit: limit, webSocket: true)
    }
}
