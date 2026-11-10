import Foundation
import Network

// MARK: - A screen through a relay room
//
// When a viewer can reach a Mac neither on Wi-Fi nor over Tailscale, the
// screen's video goes through a room on Ripul's servers instead
// (`ScreenRelayRoom` in the worker). The viewer, signed in, makes the room
// and gets a token for each end; it keeps its own and gives the Mac the
// other in its `screen:offer`. Both connect out, and the room passes the
// session's frames between them as a direct connection would carry them,
// each sealed with the viewer's one-time key (`LiveStreamSeal`).

public enum LiveStreamScreenRelay {
    /// A room made for one session.
    public struct Room: Sendable, Equatable {
        public let room: String
        public let viewerToken: String
        public let sourceToken: String

        public init(room: String, viewerToken: String, sourceToken: String) {
            self.room = room
            self.viewerToken = viewerToken
            self.sourceToken = sourceToken
        }
    }

    /// Ripul's API host, where the rooms are (WebSockets go to it directly).
    public static var server: URL { LiveStreamRelay.server }

    /// Whether `text` could be a room's id: 22 characters of URL-safe base64.
    public static func isRoomId(_ text: String) -> Bool {
        text.count == 22 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Makes a room, signed in as the viewer (`bearer` is its Clerk token).
    public static func makeRoom(server: URL = server, bearer: String, timeout: TimeInterval = 8) async throws -> Room {
        var request = URLRequest(url: server.appendingPathComponent("v1/screen-relay/rooms"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200, let room = json["room"] as? String, isRoomId(room),
              let viewer = json["viewerToken"] as? String, let source = json["sourceToken"] as? String else {
            let said = (json["error"] as? [String: Any])?["message"] as? String ?? json["error"] as? String
            throw LiveStreamError.refused(said ?? "The relay couldn't be reached (\(status))")
        }
        return Room(room: room, viewerToken: viewer, sourceToken: source)
    }

    /// One end's address in a room.
    public static func url(server: URL = server, room: String, side: LiveStreamSeal.Side, token: String) -> URL? {
        guard isRoomId(room) else { return nil }
        let path = server.appendingPathComponent("v1/screen-relay/rooms/\(room)/ws")
        guard var parts = URLComponents(url: path, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.queryItems = [URLQueryItem(name: "role", value: side.rawValue), URLQueryItem(name: "token", value: token)]
        return parts.url
    }

    /// Opens one end's connection to a room, sealed with the viewer's key.
    /// Throws when the room turns it away (gone, or not this token) or can't
    /// be reached in `timeout`.
    public static func connect(server: URL = server, room: String, side: LiveStreamSeal.Side, token: String,
                               key: Data, timeout: TimeInterval = 10) async throws -> LiveStreamChannel {
        guard key.count == 32 else { throw LiveStreamError.refused("A relay needs the session's 32-byte key") }
        guard let url = url(server: server, room: room, side: side, token: token) else {
            throw LiveStreamError.refused("The relay's address is not valid")
        }
        // The viewer takes pictures; the screen's end takes input.
        let limit = side == .viewer ? LiveStreamWire.maxToViewer : LiveStreamWire.maxToApp
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        socket.maximumMessageSize = limit + LiveStreamWire.headerLength + LiveStreamSeal.overhead
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = url.scheme == "ws" ? NWParameters(tls: nil, tcp: tcp)
                                            : NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        try await connection.liveStreamReady(queue: DispatchQueue(label: "io.ripul.livestream.screenrelay"), timeout: timeout)
        return LiveStreamChannel(connection, receiveLimit: limit, webSocket: true, seal: LiveStreamSeal(key: key, side: side))
    }
}
