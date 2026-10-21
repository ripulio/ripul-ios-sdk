import Foundation

/// Which Ripul site an app on the SDK talks to.
///
/// An app compiles in one site: its publishable key and the CMS definition its
/// portal draws. Every Ripul surface reads the site through here — portal,
/// agent, conversations — so a developer build can point them all at another
/// site the developer belongs to (a demo site, say) from the dev helper, and
/// Reset puts them back.
///
/// **Store builds have no switch.** Everything that chooses another site — the
/// stored choice, the listing call, the picker and the marker — is compiled
/// only with `DEBUG`, `RIPUL_DEVELOPER_BUILD` or `RIPUL_DEVELOPER_TOOLS`. Without
/// them `siteKey(compiled:)` and `cmsId(compiled:)` return what they are given
/// and nothing else exists. `RIPUL_DEVELOPER_TOOLS` is for sideloaded beta and
/// dev builds: unlike `RIPUL_DEVELOPER_BUILD` it brings in no private API, but
/// like it, it must never be set on a build for TestFlight or the App Store,
/// and the upload checks refuse a binary carrying `RipulSiteSwitch.marker`.
///
/// **The server is the backstop.** The picker lists only the sites the signed-in
/// Ripul person belongs to (`GET /v1/site-key/memberships`), and each site's
/// key, membership and row rules still decide what comes back, so a modified
/// build reaches nothing more than its user could already reach.
///
/// It moves only what the SDK talks to; an app's own backend is not part of it.
public enum RipulSiteSwitch {
    /// Posted on the main thread when the chosen site changes or is reset.
    /// Surfaces that hold a site key (a cached portal menu, an open agent)
    /// refresh or rebuild on it.
    public static let didChange = Notification.Name("RipulSiteSwitch.didChange")

    /// The site the app compiled in, and the origin its key accepts. The
    /// picker lists only sites that accept the same origin.
    public struct CompiledSite: Equatable, Sendable {
        public var publishableKey: String
        public var cmsId: String
        public var origin: String
        public var name: String

        public init(publishableKey: String, cmsId: String, origin: String, name: String) {
            self.publishableKey = publishableKey
            self.cmsId = cmsId
            self.origin = origin
            self.name = name
        }
    }

    /// The key to send: the compiled one, or in a developer build the site the
    /// developer picked over it.
    public static func siteKey(compiled: String) -> String {
        #if DEBUG || RIPUL_DEVELOPER_BUILD || RIPUL_DEVELOPER_TOOLS
        if let choice = RipulSiteSwitchStore.choice(over: compiled) { return choice.publishableKey }
        #endif
        return compiled
    }

    /// The CMS definition to draw: the compiled one, or the picked site's.
    /// `compiledKey` is the key the compiled definition belongs to.
    public static func cmsId(compiled: String, compiledKey: String) -> String {
        #if DEBUG || RIPUL_DEVELOPER_BUILD || RIPUL_DEVELOPER_TOOLS
        if let choice = RipulSiteSwitchStore.choice(over: compiledKey), let cms = choice.cmsDefinitionId { return cms }
        #endif
        return compiled
    }

    /// The picked site's name, or nil on the compiled site (always nil in a store build).
    public static func switchedSiteName(compiledKey: String) -> String? {
        #if DEBUG || RIPUL_DEVELOPER_BUILD || RIPUL_DEVELOPER_TOOLS
        return RipulSiteSwitchStore.choice(over: compiledKey)?.name
        #else
        return nil
        #endif
    }

    /// Whether this build can switch at all. False in a store build.
    public static var isAvailable: Bool {
        #if DEBUG || RIPUL_DEVELOPER_BUILD || RIPUL_DEVELOPER_TOOLS
        return RipulSiteSwitchStore.compiled != nil
        #else
        return false
        #endif
    }

    /// Tell the dev helper what the app compiled in. Call once at launch,
    /// before any Ripul surface opens. In a developer build this also shows the
    /// marker when a switch from an earlier launch is still in force. Does
    /// nothing in a store build.
    public static func register(_ site: CompiledSite) {
        #if DEBUG || RIPUL_DEVELOPER_BUILD || RIPUL_DEVELOPER_TOOLS
        RipulSiteSwitchStore.compiled = site
        #if os(iOS)
        DispatchQueue.main.async { RipulSiteSwitchMarker.shared.startShowing() }
        #endif
        #endif
    }

    /// Back to the compiled site. Call it when the person signs out of the app;
    /// the SDK calls it itself when the dev helper's Ripul account signs out.
    public static func reset() {
        #if DEBUG || RIPUL_DEVELOPER_BUILD || RIPUL_DEVELOPER_TOOLS
        RipulSiteSwitchStore.set(nil)
        #endif
    }
}

#if DEBUG || RIPUL_DEVELOPER_BUILD || RIPUL_DEVELOPER_TOOLS

extension RipulSiteSwitch {
    /// A string present in a binary exactly when the switch is compiled in.
    /// The TestFlight and App Store upload checks look for it.
    public static let marker = "RIPUL_SITE_SWITCH_COMPILED_IN"
}

/// One site the signed-in person belongs to, from `GET /v1/site-key/memberships`.
public struct RipulMemberSite: Codable, Equatable, Identifiable, Sendable {
    public var siteKeyId: String
    public var publishableKey: String
    public var name: String
    public var slug: String?
    public var cmsDefinitionId: String?
    public var role: String
    public var id: String { siteKeyId }
}

/// The stored choice, kept per compiled key: a choice made over one compiled
/// key is ignored by a build that compiles in another.
enum RipulSiteSwitchStore {
    private static let defaultsKey = "io.ripul.siteSwitch.choice.v1"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _compiled: RipulSiteSwitch.CompiledSite?

    static var compiled: RipulSiteSwitch.CompiledSite? {
        get { lock.lock(); defer { lock.unlock() }; return _compiled }
        set { lock.lock(); _compiled = newValue; lock.unlock() }
    }

    private struct Stored: Codable {
        var compiledKey: String
        var site: RipulMemberSite
        var marker: String
    }

    static func choice(over compiledKey: String) -> RipulMemberSite? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.marker == RipulSiteSwitch.marker,
              stored.compiledKey == compiledKey,
              stored.site.publishableKey != compiledKey else { return nil }
        return stored.site
    }

    /// nil — or the compiled site itself — clears the choice.
    static func set(_ site: RipulMemberSite?) {
        let before = compiled.flatMap { choice(over: $0.publishableKey) }
        if let site, let compiled, site.publishableKey != compiled.publishableKey,
           let data = try? JSONEncoder().encode(Stored(compiledKey: compiled.publishableKey, site: site, marker: RipulSiteSwitch.marker)) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        let after = compiled.flatMap { choice(over: $0.publishableKey) }
        guard before != after else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: RipulSiteSwitch.didChange, object: nil)
            #if os(iOS)
            RipulSiteSwitchMarker.shared.update()
            #endif
        }
    }
}

/// Reads the sites the signed-in Ripul person may switch to.
enum RipulSiteSwitchAPI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func memberSites(baseURL: URL, token: String, origin: String) async throws -> [RipulMemberSite] {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/site-key/memberships"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "origin", value: origin)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure(message: message ?? "The sites could not be listed (HTTP \(status)).")
        }
        struct Body: Decodable { let sites: [RipulMemberSite] }
        return try JSONDecoder().decode(Body.self, from: data).sites
    }
}

#endif
