import Foundation

/// Native mirror of the web layer's host-mode preferences (hostEnabled,
/// machineName). The web copies live in localStorage, which a web-data wipe or
/// heal purge destroys — after which the host silently stopped hosting and the
/// machine vanished from every client's registry until someone re-enabled it
/// (the remaining slice of the onboarding trap once machineId became stable).
///
/// Mirroring in UserDefaults lets the web layer restore hosting state on the
/// next boot: values are injected as `window.__ripulHostPrefs` (AgentWebView,
/// documentStart) and refreshed into the live page on pageDidFinish and after
/// every `host-prefs:set` write (AgentBridge).
public enum HostPreferences {

    private static let enabledKey = "ripul.hostEnabled"
    private static let nameKey = "ripul.machineName"

    /// nil = never set (fresh install) — the web layer keeps its own default.
    public static var hostEnabled: Bool? {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// nil = never set — the web layer keeps its own default name.
    public static var machineName: String? {
        get { UserDefaults.standard.string(forKey: nameKey) }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    /// JSON object literal for `window.__ripulHostPrefs = <json>;` — fields are
    /// null when unset so the web layer can tell "no mirror" apart from false.
    ///
    /// On macOS, hosting is always on — it is not user-switchable. Any stored
    /// `hostEnabled` value is ignored in favour of a hard `true`, ensuring the
    /// relay bridge starts immediately after a web-data wipe or heal purge.
    public static var injectionJSON: String {
        #if os(macOS)
        let effectiveHostEnabled: Any = true  // always-on on Mac
        #else
        let effectiveHostEnabled: Any = hostEnabled ?? NSNull()
        #endif
        let dict: [String: Any] = [
            "hostEnabled": effectiveHostEnabled,
            "machineName": machineName ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
