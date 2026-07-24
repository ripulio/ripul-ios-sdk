import Foundation

/// Stable per-installation identity for this app install.
///
/// Backed by `UserDefaults.standard`, which survives an install-over
/// (devicectl / OTA — the app data container is preserved) but is wiped by a
/// full uninstall (container deleted). That lifetime deliberately matches the
/// web layer's localStorage caches (pairings, roomId): an install-over keeps
/// identity AND caches, so the client rejoins the relay with the SAME clientId
/// and the relay's same-clientId replace logic evicts the pre-install ghost
/// immediately instead of waiting for the ~90s stale reaper; an uninstall
/// wipes both, so regenerating a fresh identity is correct there.
///
/// Injected into the web layer as `window.__ripulInstallationId` at document
/// start (see AgentWebView).
public enum InstallationIdentity {

    private static let defaultsKey = "ripul.installationId"
    private static var cached: String?

    /// Raw UUID, stable for the lifetime of the install.
    public static var id: String {
        if let cached { return cached }
        if let existing = UserDefaults.standard.string(forKey: defaultsKey) {
            cached = existing
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
        cached = fresh
        return fresh
    }

    /// Hyphen-free form for embedding in relay clientIds — the web layer parses
    /// `controller-<userId>-<suffix>` by splitting on '-', so the suffix must
    /// not contain hyphens.
    public static var clientIdSegment: String {
        id.replacingOccurrences(of: "-", with: "")
    }
}
