import Foundation

/// Storage abstraction for the session-list stack.
///
/// The native app persists machines, unified sessions, last-active timestamps,
/// raw-mode flags and machine icons in its own shared `UserDefaults`
/// (`appDefaults`). When the list is embedded by a third-party host (e.g. WAC's
/// developer tool), those keys must live in an **isolated** suite so they never
/// collide with the host app's own defaults. Every persisted read/write in the
/// extracted session-list code goes through this protocol instead of touching
/// `UserDefaults` directly.
///
/// Mirrors the subset of `UserDefaults` the session list actually uses, plus a
/// `userDefaults` escape hatch that backs `@AppStorage(store:)` bindings in the
/// SwiftUI list.
/// Cache keys for the console's seeded-context bootstrap (native-tool-registry
/// phase 3). Written by `RipulAgentConsole.fetchSeededContexts`, read by
/// `RipulAgentScreen.agentConfig` — the id is server-derived, never hardcoded.
enum RipulSeededContextCache {
    static let devContextIdKey = "ripulSeededDevContextId"
}

public protocol RipulSessionCache: AnyObject {
    func data(forKey key: String) -> Data?
    func stringArray(forKey key: String) -> [String]?
    func dictionary(forKey key: String) -> [String: Any]?
    func bool(forKey key: String) -> Bool
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)

    /// The backing store, for `@AppStorage(store:)` and any typed access the
    /// protocol does not enumerate.
    var userDefaults: UserDefaults { get }
}

/// Default `RipulSessionCache` backed by a `UserDefaults` suite.
///
/// - The native app passes an adapter over its existing `appDefaults` so
///   behaviour (including macOS per-profile isolation) is unchanged.
/// - A third-party host passes `UserDefaultsSessionCache(suiteName: "…")` so the
///   session-list keys are namespaced away from the host's own defaults.
public final class UserDefaultsSessionCache: RipulSessionCache {
    public let userDefaults: UserDefaults

    public init(suite: UserDefaults = .standard) {
        self.userDefaults = suite
    }

    /// Convenience for a namespaced suite. Falls back to `.standard` if the
    /// suite name is invalid (matches `UserDefaults(suiteName:)` semantics).
    public convenience init(suiteName: String) {
        self.init(suite: UserDefaults(suiteName: suiteName) ?? .standard)
    }

    public func data(forKey key: String) -> Data? { userDefaults.data(forKey: key) }
    public func stringArray(forKey key: String) -> [String]? { userDefaults.stringArray(forKey: key) }
    public func dictionary(forKey key: String) -> [String: Any]? { userDefaults.dictionary(forKey: key) }
    public func bool(forKey key: String) -> Bool { userDefaults.bool(forKey: key) }
    public func object(forKey key: String) -> Any? { userDefaults.object(forKey: key) }
    public func set(_ value: Any?, forKey key: String) { userDefaults.set(value, forKey: key) }
    public func removeObject(forKey key: String) { userDefaults.removeObject(forKey: key) }
}

/// Lookup for the per-session model-picker cache (`ripulSessionModelIds`).
///
/// The model pickers (iOS context menu / ModelPickerSheet, macOS sidebar +
/// agent screen) write the user's choice at tap time, keyed by the LIVE
/// ChatSession.id (tab id). The entry survives app restarts — but nothing
/// re-applies it when a closed session is reopened: the web's open/import path
/// re-derives the override from the transcript's last assistant model, which
/// can't represent models outside the Claude opus/haiku/sonnet families (Kimi
/// k3, Fable) or effort variants. Pushing the cached choice via
/// `AgentBridge.setChatModel` right after a successful (re)open restores the
/// model the native session actually shows as selected.
public enum SessionModelSelectionCache {
    /// The cache key both platforms' pickers write.
    public static let key = "ripulSessionModelIds"

    /// The whole picker map, read once.
    ///
    /// For callers that resolve a pick for MANY sessions in a row. The
    /// convenience overload below re-reads the key on every call, and
    /// `UserDefaults.dictionary(forKey:)` is not a pointer hand-off — it bridges
    /// the plist into a fresh Swift dictionary each time. A session-list rebuild
    /// resolves a pick for every row, so that was one full read per row, per
    /// rebuild, on the main actor. Read the map once and use `modelId(map:)`.
    public static func loadMap(cache: RipulSessionCache) -> [String: String] {
        (cache.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    /// The cached catalog model id for a session being (re)opened, trying every
    /// known alias: the live tab id, the row id, and all matchKeys — each with
    /// and without the `cli_` prefix (ChatSession ids carry it, bare CLI uuids
    /// don't).
    public static func modelId(cache: RipulSessionCache, session: UnifiedSession, liveTabId: String?) -> String? {
        modelId(map: loadMap(cache: cache), session: session, liveTabId: liveTabId)
    }

    /// As above, against a map the caller already holds.
    public static func modelId(map: [String: String], session: UnifiedSession, liveTabId: String?) -> String? {
        guard !map.isEmpty else { return nil }
        var keys: [String] = []
        if let liveTabId { keys.append(liveTabId) }
        keys.append(session.id)
        keys.append(contentsOf: session.matchKeys)
        for k in keys {
            if let hit = map[k] { return hit }
            if k.hasPrefix("cli_"), let hit = map[String(k.dropFirst(4))] { return hit }
            if let hit = map["cli_\(k)"] { return hit }
        }
        return nil
    }
}
