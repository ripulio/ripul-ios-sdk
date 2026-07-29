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
