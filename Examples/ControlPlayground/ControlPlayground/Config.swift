import Foundation

/// Every address and id the app uses, in one place.
enum Config {
    /// The CMS definition id of `control-playground`: made-up data, every page public.
    static let cmsId = "cms_r55ri3v0pk02"
    /// The site's publishable key (`sk_n3hk6kpwggfq`).
    static let siteKey = "pk_live_qsq1sm5g186o0p3n3u544fh1"
    /// The playground's own address (its custom domain), on the key's allowedOrigins,
    /// sent as `Origin` with every request.
    static let origin = "https://playground.ripul.io"

    /// The site the app opens: the playground, or another public site an agent
    /// names in the launch environment to check a block against it
    /// (`SIMCTL_CHILD_PLAYGROUND_CMS_ID`, `_SITE_KEY`, `_ORIGIN`). Another site
    /// is read with a site-key session, as its own app reads it.
    static var site: (cmsId: String, siteKey: String, origin: String, sendsSiteKey: Bool) {
        // The launch environment, else the app's defaults (`simctl spawn <udid> defaults
        // write io.ripul.playground PLAYGROUND_CMS_ID …`), which survive a relaunch.
        let value: (String) -> String? = { name in
            (ProcessInfo.processInfo.environment[name] ?? UserDefaults.standard.string(forKey: name)).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let id = value("PLAYGROUND_CMS_ID"), let key = value("PLAYGROUND_SITE_KEY") {
            return (id, key, value("PLAYGROUND_ORIGIN") ?? origin, false)
        }
        return (cmsId, siteKey, origin, true)
    }
}
