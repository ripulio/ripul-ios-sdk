import Foundation

/// Every address and id WAC Next uses, in one place.
enum Config {
    /// WAC's sign-in routes (`email_login/*`) on the seeded `emaillogin` cluster: the same HTTPS
    /// base WAC Dev uses (`ProviderLogin.secureAPI`). The Pages proxy behind it forwards only
    /// those routes.
    static let signInBase = URL(string: "https://business.wac.rocks/wac-login-test/api/v1/")!

    /// The same cluster's ordinary API (`user`, `user/logout`) over HTTPS: the console load
    /// balancer's route that the sign-in proxy above forwards to. It strips the prefix and reaches
    /// `wac-dev-emaillogin-web`.
    static let apiBase = URL(string: "https://ops.wac.rocks/wac-login-test/api/v1/")!

    /// The trial server's synthetic test login, standing in for Apple and Google. Reserved
    /// numbers only (+44 7700 900xxx); this one is WAC Next's own. Never Peter's account: Rails
    /// keeps one session per user, so signing in to it would sign his WAC Dev phone out.
    /// A simulator build starts with test user B (918, user 64): 917 (user 63) is the one Peter's
    /// phone is signed in to, and on 30 Oct an agent's typing ran before the sign-in screen had
    /// loaded, so the 917 default signed in on a simulator and ended his phone's session.
    #if targetEnvironment(simulator)
    static let testEmail = "wac-next-918@example.invalid"
    static let testPhone = "+447700900918"
    #else
    static let testEmail = "wac-next-917@example.invalid"
    static let testPhone = "+447700900917"
    #endif
    static let testName = "WAC Next"

    // MARK: The CMS site

    /// The CMS definition id of the `wac-app` site. Its tabs (Shifts, Jobs) come from the
    /// `tabBar` on its shell page; `CmsAppView` draws them as iOS's own tab bar.
    static let cmsId = "cms_1kp9x89jzhvv"
    /// The site's publishable key.
    static let siteKey = "pk_live_h7cgxwojhra52il8waea5rld"
    /// The origin the site key allows, as WAC's `RipulConfig.originHeader`. The SDK presents
    /// it when it checks the key (`CmsClientConfig.origin`); the key allows no other.
    static let origin = "https://wac-next.app"

    static var cmsConfigured: Bool { !cmsId.isEmpty && !siteKey.isEmpty }
}
