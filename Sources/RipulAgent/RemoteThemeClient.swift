import Foundation
import CryptoKit

/// Loads a public theme without delaying launch. The last accepted server document is
/// authoritative; the bundled document is used until one is available. The host validates
/// and applies the WHOLE document, including fields outside the SDK's theme vocabulary.
@MainActor
public final class RipulRemoteThemeClient {
    public enum Origin: String { case bundled, cache, server }
    public private(set) var origin: Origin = .bundled
    public private(set) var lastError: String?
    public let url: URL

    public static func hostedURL(themeID: String) -> URL {
        URL(string: RipulDomain.llmProxyURL)!
            .appendingPathComponent("v1/app-themes").appendingPathComponent(themeID)
    }

    private struct CachedTheme: Codable {
        let url: URL
        let etag: String?
        let data: Data
    }

    private let fallback: Data
    private let cacheFile: URL
    private let apply: (Data) throws -> Void
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    private var accepted: CachedTheme?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var editors: Set<UUID> = []
    private static let maximumBytes = 512 * 1024

    public var authoritativeDocument: Data { accepted?.data ?? fallback }
    public var authoritativeETag: String? { accepted?.etag }

    /// An editor owns a frozen draft. Foreground refresh must not replace its preview.
    public func beginEditing() -> UUID {
        let lease = UUID(); editors.insert(lease); stop(); return lease
    }
    public func endEditing(_ lease: UUID) {
        editors.remove(lease)
        if editors.isEmpty { refreshInBackground() }
    }
    public func preview(_ data: Data) throws { try accept(data) }

    /// Called only after the server acknowledges a successful publication.
    public func acceptPublication(_ manifest: RipulThemeManifest) throws {
        stop()
        try accept(manifest.data)
        let value = CachedTheme(url: url, etag: manifest.etag, data: manifest.data)
        accepted = value; origin = .server; lastError = nil
        do {
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: cacheFile, options: .atomic)
        } catch { lastError = "Theme published, but could not cache it: \(error.localizedDescription)" }
    }

    public convenience init(url: URL, fallback: Data,
                            cacheDirectory: URL? = nil,
                            validateAndApply: @escaping (Data) throws -> Void) {
        self.init(url: url, fallback: fallback, cacheDirectory: cacheDirectory,
                  validateAndApply: validateAndApply,
                  fetch: { try await URLSession.shared.data(for: $0) })
    }

    init(url: URL, fallback: Data, cacheDirectory: URL? = nil,
         validateAndApply: @escaping (Data) throws -> Void,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.url = url
        self.fallback = fallback
        self.apply = validateAndApply
        self.fetch = fetch
        let root = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ripul/Themes", isDirectory: true)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        self.cacheFile = root.appendingPathComponent(key + ".json")
    }

    /// Applies local data synchronously, then schedules a network refresh. No network
    /// request is awaited. A cache the current app cannot decode falls back to the bundle.
    public func start() throws {
        stop()
        accepted = nil
        lastError = nil
        if let bytes = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode(CachedTheme.self, from: bytes),
           cached.url == url,
           (try? accept(cached.data)) != nil {
            accepted = cached
            origin = .cache
        } else {
            try accept(fallback)
            origin = .bundled
        }
        refreshInBackground()
    }

    /// Restores the server's last accepted document after a local editor preview.
    public func restoreAuthoritativeTheme() throws {
        try accept(accepted?.data ?? fallback)
    }

    public func stop() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refreshInBackground() {
        guard editors.isEmpty, refreshTask == nil else { return }
        let currentGeneration = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchLatest(generation: currentGeneration)
            if self.generation == currentGeneration { self.refreshTask = nil }
        }
    }

    /// Coalesces with any request already in flight. Intended for explicit refresh UI;
    /// launch and foreground callers should use `start` / `refreshInBackground`.
    public func refresh() async {
        refreshInBackground()
        await refreshTask?.value
    }

    private func accept(_ data: Data) throws {
        guard data.count <= Self.maximumBytes,
              (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw ThemeError.invalidDocument
        }
        // The callback must decode/validate before changing any live state.
        try apply(data)
    }

    private func fetchLatest(generation requestedGeneration: UUID) async {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = accepted?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await fetch(request)
            guard generation == requestedGeneration, !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse else { throw ThemeError.invalidResponse }
            if http.statusCode == 304, let accepted {
                // Even an unchanged server version supersedes local editor previews.
                try accept(accepted.data)
            } else {
                guard http.statusCode == 200 else { throw ThemeError.http(http.statusCode) }
                try accept(data)
                let value = CachedTheme(url: url, etag: http.value(forHTTPHeaderField: "ETag"), data: data)
                accepted = value
                // Cache failure must not prevent an already validated theme going live.
                do {
                    try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try JSONEncoder().encode(value).write(to: cacheFile, options: .atomic)
                } catch {
                    lastError = "Theme applied, but could not cache it: \(error.localizedDescription)"
                    origin = .server
                    return
                }
            }
            origin = .server
            lastError = nil
        } catch {
            guard generation == requestedGeneration, !Task.isCancelled else { return }
            lastError = error.localizedDescription
            // Preserve the last valid local/remote theme on timeout, HTTP failure,
            // malformed JSON, or a document incompatible with this app version.
        }
    }

    private enum ThemeError: LocalizedError {
        case invalidDocument, invalidResponse, http(Int)
        var errorDescription: String? {
            switch self {
            case .invalidDocument: return "Theme must be a JSON object no larger than 512 KiB."
            case .invalidResponse: return "Theme server returned an invalid response."
            case .http(let status): return "Theme server returned HTTP \(status)."
            }
        }
    }
}
