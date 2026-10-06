import Foundation
import CryptoKit

/// Loads a public theme without delaying launch. The last accepted server document is
/// the publication baseline; a saved local draft is restored over it for preview.
/// The bundled document is used until a server version is available. The host validates
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
    let draftURL: URL
    private let cacheFile: URL
    private let apply: (Data) throws -> Void
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    private var accepted: CachedTheme?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var editors: Set<UUID> = []
    private var hasLocalPreview = false
    private var deferredCapture: ((Data?) throws -> Data)?
    private static let maximumBytes = 512 * 1024

    public var authoritativeDocument: Data { accepted?.data ?? fallback }
    public var authoritativeETag: String? { accepted?.etag }

    /// An editor owns a frozen draft. Foreground refresh must not replace its preview.
    public func beginEditing() -> UUID {
        let lease = UUID(); editors.insert(lease); stop(); return lease
    }
    public func endEditing(_ lease: UUID) {
        editors.remove(lease)
        guard editors.isEmpty else { return }
        // A host editor holding a lease (Home cards) changes the live theme without
        // owning a draft of its own: keep the result before refreshes resume.
        if let capture = deferredCapture { deferredCapture = nil; recordLocalEdit(capture) }
        refreshInBackground()
    }
    /// Preview through the host's complete apply path without publishing or changing
    /// the server baseline. Keep it visible after the editor closes.
    public func preview(_ data: Data) throws {
        try accept(data)
        stop() // An already-running fetch must not overwrite this preview either.
        hasLocalPreview = try canonical(data) != canonical(authoritativeDocument)
    }

    /// The saved draft's document, when there is one. nil when absent or unreadable.
    var savedDraftDocument: Data? {
        guard let bytes = try? Data(contentsOf: draftURL),
              let draft = try? JSONDecoder().decode(RipulThemeDraft.self, from: bytes) else { return nil }
        return draft.data
    }

    /// Keep an edit that is ALREADY LIVE as the saved draft, so it survives relaunch and
    /// server refreshes and is offered for publishing like a text edit. Nothing is
    /// re-applied. An open editor owns the draft, so this yields to its lease; a draft
    /// whose source is not valid JSON is being repaired in Theme Management and is kept.
    func saveLocalEdit(_ document: Data) throws {
        guard editors.isEmpty else { return }
        let existing: RipulThemeDraft?
        if FileManager.default.fileExists(atPath: draftURL.path) {
            existing = try JSONDecoder().decode(RipulThemeDraft.self, from: Data(contentsOf: draftURL))
            if let existing, (try? canonical(existing.data)) == nil { return }
        } else { existing = nil }
        let baseline = existing?.baseline ?? authoritativeDocument
        if try canonical(document) == canonical(baseline) {
            try removeSavedDraft()
            hasLocalPreview = false
            return
        }
        _ = try RipulThemeManifest(data: document, etag: nil)
        let draft = RipulThemeDraft(text: String(decoding: document, as: UTF8.self), baseline: baseline,
                                    etag: existing.map { $0.etag } ?? authoritativeETag)
        try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: draftURL, options: .atomic)
        stop() // An already-running fetch must not replace the edit.
        hasLocalPreview = true
    }

    /// `saveLocalEdit` over the complete live document, as `capture` builds it on top of
    /// the saved draft. A failure keeps the edit live and is reported in `lastError`.
    func recordLocalEdit(_ capture: @escaping (Data?) throws -> Data) {
        guard editors.isEmpty else { deferredCapture = capture; return }
        do { try saveLocalEdit(capture(savedDraftDocument)) }
        catch { lastError = "Could not save this theme edit on the phone: \(error.localizedDescription)" }
    }

    /// Theme Management saved or removed the draft itself: refreshes follow that state.
    func noteSavedDraft(hasChanges: Bool) {
        hasLocalPreview = hasChanges
        if hasChanges { stop() }
    }

    private func canonical(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
    }

    /// Called only after the server acknowledges a successful publication.
    public func acceptPublication(_ manifest: RipulThemeManifest) throws {
        stop()
        try accept(manifest.data)
        let value = CachedTheme(url: url, etag: manifest.etag, data: manifest.data)
        accepted = value; origin = .server; lastError = nil
        hasLocalPreview = false
        do {
            try removeSavedDraft()
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: cacheFile, options: .atomic)
        } catch { lastError = "Theme published, but could not update local theme storage: \(error.localizedDescription)" }
    }

    public convenience init(url: URL, fallback: Data,
                            cacheDirectory: URL? = nil,
                            validateAndApply: @escaping (Data) throws -> Void) {
        self.init(url: url, fallback: fallback, cacheDirectory: cacheDirectory,
                  validateAndApply: validateAndApply,
                  fetch: { try await URLSession.shared.data(for: $0) })
    }

    init(url: URL, fallback: Data, cacheDirectory: URL? = nil, draftURL: URL? = nil,
         validateAndApply: @escaping (Data) throws -> Void,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.url = url
        self.draftURL = draftURL ?? RipulThemeDraft.location(for: url)
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
        hasLocalPreview = false
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
        // Saved editor changes are a local preview, never the server baseline.
        // Restore before scheduling a fetch so launch/foreground cannot erase them.
        if FileManager.default.fileExists(atPath: draftURL.path) {
            do {
                let draft = try JSONDecoder().decode(RipulThemeDraft.self, from: Data(contentsOf: draftURL))
                if try canonical(draft.data) != canonical(draft.baseline) {
                    try preview(draft.data)
                }
            } catch {
                // Keep invalid source edits available for repair in Theme Management.
                lastError = "Could not restore the saved theme draft: \(error.localizedDescription)"
            }
        }
        refreshInBackground()
    }

    /// Restores the server's last accepted document after a local editor preview.
    public func restoreAuthoritativeTheme() throws {
        try accept(accepted?.data ?? fallback)
        try removeSavedDraft()
        hasLocalPreview = false
    }

    private func removeSavedDraft() throws {
        if FileManager.default.fileExists(atPath: draftURL.path) {
            try FileManager.default.removeItem(at: draftURL)
        }
    }

    public func stop() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refreshInBackground() {
        guard editors.isEmpty, !hasLocalPreview, refreshTask == nil else { return }
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
            if http.statusCode == 304, accepted != nil {
                // Unchanged, and already applied: refreshInBackground never runs
                // with a differing local preview (hasLocalPreview) or an open
                // editor, so the live theme IS `accepted`. Re-applying it bumped
                // NativeTextUpdates and posted .ripulThemeDidChange, re-rendering
                // the app root on every foreground for nothing.
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
