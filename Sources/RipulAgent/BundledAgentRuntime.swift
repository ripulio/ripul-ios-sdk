import Foundation
import Network
import CryptoKit
import WebKit

/// Serves only the signed app's inventoried runtime assets on loopback. It has
/// no command, upload, proxy or filesystem-browsing routes. Keeping a stable
/// origin preserves WebKit storage without depending on a hosted web cache.
@MainActor
public final class BundledAgentRuntime: ObservableObject {
    public static let shared = BundledAgentRuntime()
    public static let modeKey = "ripul.standalone.enabled"
    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: modeKey) }
    @Published public private(set) var baseURL: URL?
    @Published public private(set) var error: String?
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var root: URL?
    private var files: [String: Asset] = [:]
    private var starting: Task<URL, Error>?
    private let queue = DispatchQueue(label: "ripul.bundled-runtime", qos: .utility)
    private let portKey = "ripul.standalone.assetPort"

    struct Asset: Decodable { let sha256: String; let bytes: Int }
    struct Manifest: Decodable { let version: Int; let protocolVersion: Int; let entry: String; let files: [String: Asset] }
    private struct RuntimeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    public func start(bundle: Bundle = .main) async throws -> URL {
        if let baseURL { return baseURL }
        if let starting { return try await starting.value }
        let task = Task { @MainActor in try await self.startListener(bundle: bundle) }
        starting = task
        defer { starting = nil }
        do { let url = try await task.value; error = nil; return url }
        catch { self.error = error.localizedDescription; throw error }
    }

    private func startListener(bundle: Bundle) async throws -> URL {
        guard let directory = bundle.url(forResource: "StandaloneRuntime", withExtension: nil) else {
            throw RuntimeError(message: "This build is missing its standalone interface. Install a complete app build.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("runtime-manifest.json")))
        guard manifest.version == 1, manifest.protocolVersion == 1, manifest.entry == "popup.html",
              manifest.files[manifest.entry] != nil,
              manifest.files.keys.allSatisfy(Self.validAssetPath) else {
            throw RuntimeError(message: "The bundled interface is incompatible or damaged")
        }
        root = directory; files = manifest.files
        let previous = UserDefaults.standard.integer(forKey: portKey)
        let port = previous > 1023 && previous <= 65535 ? UInt16(previous) : 0
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            var settled = false
            server.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard !settled, let actual = server.port else { return }
                        settled = true
                        let url = URL(string: "http://127.0.0.1:\(actual.rawValue)")!
                        UserDefaults.standard.set(Int(actual.rawValue), forKey: self.portKey)
                        self.baseURL = url
                        continuation.resume(returning: url)
                    case .failed(let failure):
                        self.baseURL = nil; self.listener = nil; server.cancel()
                        if !settled { settled = true; continuation.resume(throwing: failure) }
                    case .cancelled:
                        self.baseURL = nil
                        if !settled { settled = true; continuation.resume(throwing: RuntimeError(message: "The local interface server stopped")) }
                    default: break
                    }
                }
            }
            server.start(queue: queue)
        }
    }

    static func validAssetPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Native capabilities require the live listener and its exact main-frame
    /// origin. A URL parameter, iframe or another localhost port cannot opt in.
    public func trusts(_ message: WKScriptMessage) -> Bool {
        guard let baseURL, listener != nil, message.frameInfo.isMainFrame else { return false }
        let origin = message.frameInfo.securityOrigin
        return origin.protocol == "http" && origin.host == "127.0.0.1" && origin.port == baseURL.port
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 32 else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection
        connection.start(queue: queue)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.clients.removeValue(forKey: id)?.cancel()
        }
        readHeaders(connection, id: id, data: Data())
    }

    private func readHeaders(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - data.count) { [weak self] next, _, complete, failure in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var data = data; if let next { data.append(next) }
                if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(connection, id: id, headers: String(decoding: data[..<range.lowerBound], as: UTF8.self))
                } else if failure != nil || complete || data.count >= 8192 {
                    self.clients.removeValue(forKey: id)?.cancel()
                } else { self.readHeaders(connection, id: id, data: data) }
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, headers: String) {
        let lines = headers.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let expectedHost = baseURL.map { "127.0.0.1:\($0.port!)" }
        var status = 404; var body = Data(); var mime = "text/plain"
        if parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD", host == expectedHost,
           let targetPath = parts[1].split(separator: "?", maxSplits: 1).first,
           let path = String(targetPath).removingPercentEncoding, let root {
            let asset = path == "/popup" || path == "/" ? "popup.html" : String(path.dropFirst())
            if path.hasPrefix("/"), Self.validAssetPath(asset), let entry = files[asset], entry.bytes <= 32 * 1024 * 1024,
               let content = try? Data(contentsOf: root.appendingPathComponent(asset)), content.count == entry.bytes,
               SHA256.hash(data: content).map({ String(format: "%02x", $0) }).joined() == entry.sha256 {
                body = content; status = 200
                mime = Self.mimeType(asset)
            }
        }
        let policy = "default-src 'none'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; worker-src 'self' blob:; base-uri 'none'; form-action 'none'; frame-src 'none'; frame-ancestors 'none'"
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: \(policy)\r\n\r\n".utf8)
        if parts.first != "HEAD" { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.clients.removeValue(forKey: id)?.cancel() }
        })
    }

    private static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}
