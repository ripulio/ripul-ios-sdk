import Foundation
import Network

// MARK: - A sign-in returning to this device

/// Catches a sign-in's return to `http://localhost:<port>/<path>` on this
/// device, so a sign-in begun on a Mac finishes here with nothing to copy.
///
/// Some command-line tools sign in with OAuth's loopback return (RFC 8252,
/// section 7.3): the browser comes back to a listener the tool runs on
/// `localhost`. Claude Code does (`claude auth login`, CLI 2.1.283). When the
/// tool is on a Mac and the browser on the phone, the phone listens on the same
/// port on its own loopback and opens the sign-in in the system's sheet
/// (`WebAuthenticationSession`: Safari itself, which Google's and Claude's
/// sign-in pages accept, unlike a web view inside an app). The browser's return
/// lands here, and its address goes to the Mac, which hands it to the tool's
/// own listener. The tool redeems the code with the PKCE verifier only it holds.
///
/// The return is answered with a redirect to `ripul-sign-in://returned`, the
/// sheet's own callback, so the sheet closes by itself. Only a return carrying
/// the sign-in's own `state` is taken; anything else on the port is refused
/// and the sheet stays open. The listeners are on 127.0.0.1 and ::1 only, so
/// nothing off the device reaches them and iOS asks no Local Network question.
@MainActor
final class LoopbackSignInReturn {
    /// The sheet's callback scheme. The redirect to it closes the sheet; it
    /// opens no app.
    static let scheme = "ripul-sign-in"

    enum Outcome: Equatable {
        /// The address the browser returned to, exactly as it asked for it.
        case returned(String)
        /// The person declined on the sign-in page.
        case denied(String)
    }

    let port: UInt16
    let path: String
    private let state: String
    private var listeners: [NWListener] = []
    private var connections: [UUID: NWConnection] = [:]
    private(set) var outcome: Outcome?

    /// The return `authorizeURL` asks for, when it is to this device's loopback
    /// and carries a state. Nil otherwise: that sign-in returns elsewhere.
    init?(authorizeURL: URL) {
        let items = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
              let target = URLComponents(string: redirect), target.scheme?.lowercased() == "http",
              let host = target.host?.lowercased(), host == "localhost" || host == "127.0.0.1",
              let port = target.port, (1...65535).contains(port),
              let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty else { return nil }
        self.port = UInt16(port)
        self.path = target.path.isEmpty ? "/" : target.path
        self.state = state
    }

    /// Listens on the port on 127.0.0.1 and ::1. False when neither could be
    /// had: on the Mac being signed in, or a simulator sharing its loopback,
    /// the tool itself holds the port, and the browser returns to it directly.
    /// The iPhone simulator held both; on a Mac (Catalyst) one process cannot
    /// hold both on one port, and the second is refused. A browser tries both
    /// for `localhost`, so either one is enough.
    func start() async -> Bool {
        var listening = false
        for host in ["127.0.0.1", "::1"] {
            if await listen(on: host) { listening = true }
        }
        return listening
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
        connections.values.forEach { $0.cancel() }
        connections = [:]
    }

    private func listen(on host: String) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var settled = false
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        if !settled { settled = true; continuation.resume(returning: true) }
                    case .failed, .cancelled, .waiting:
                        // `.waiting` is a port already taken: it would wait for it, and the
                        // browser's return must not.
                        if !settled { settled = true; listener.cancel(); continuation.resume(returning: false) }
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        if ready { listeners.append(listener) }
        return ready
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.connections.removeValue(forKey: id)?.cancel()
        }
        read(connection, id: id, data: Data())
    }

    private func read(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384 - data.count) { [weak self] next, _, complete, failure in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var data = data
                if let next { data.append(next) }
                if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                    self.answer(connection, id: id, head: String(decoding: data[..<end.lowerBound], as: UTF8.self))
                } else if failure != nil || complete || data.count >= 16_384 {
                    self.connections.removeValue(forKey: id)?.cancel()
                } else {
                    self.read(connection, id: id, data: data)
                }
            }
        }
    }

    private func answer(_ connection: NWConnection, id: UUID, head: String) {
        let found = Self.requestTarget(inHead: head).flatMap {
            Self.outcome(ofRequestTarget: $0, path: path, port: port, state: state)
        }
        var response: String
        if let found, outcome == nil {
            outcome = found
            response = "HTTP/1.1 302 Found\r\nLocation: \(Self.scheme)://returned\r\n"
        } else {
            response = "HTTP/1.1 \(found == nil ? "404 Not Found" : "409 Conflict")\r\n"
        }
        response += "Cache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.connections.removeValue(forKey: id)?.cancel() }
        })
    }

    /// The target of a GET, from a request's head. Lines are split on
    /// `isNewline`: to Swift, "\r\n" is one Character, so a test for "\r" or
    /// "\n" alone never finds the end of the request line.
    nonisolated static func requestTarget(inHead head: String) -> String? {
        let requestLine = (head.split(whereSeparator: \.isNewline).first ?? "").split(separator: " ")
        guard requestLine.count == 3, requestLine[0] == "GET", requestLine[2].hasPrefix("HTTP/") else { return nil }
        return String(requestLine[1])
    }

    /// What a request on the port means for this sign-in: its return when the
    /// path and `state` are its own, with a code or with the page's refusal.
    /// Nil for anything else (another path, another sign-in's state, no code).
    nonisolated static func outcome(ofRequestTarget target: String, path: String, port: UInt16, state: String) -> Outcome? {
        guard target.hasPrefix("/"), let parts = URLComponents(string: "http://localhost:\(port)\(target)"),
              parts.path == path, let items = parts.queryItems,
              items.first(where: { $0.name == "state" })?.value == state else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let error = value("error") {
            return .denied(error == "access_denied" ? "The sign-in was not authorized."
                           : "The sign-in page reported: \(value("error_description") ?? error)")
        }
        guard value("code") != nil else { return nil }
        return .returned("http://localhost:\(port)\(target)")
    }
}
