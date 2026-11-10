import Foundation

/// Every address and id wac for business uses, in one place. The app is the
/// `wac` CMS site (business.wac.rocks) drawn natively: the same pages, data and
/// sign-in as the website.
enum BusinessConfig {
    /// The website. Business accounts sign in here, with WAC's own accounts
    /// (clerk.wac.rocks), in the system's sign-in sheet; the page hands the app a
    /// one-time code it trades for a session of its own.
    static let siteURL = URL(string: "https://business.wac.rocks")!

    /// Where the website's sign-in sends the code: the app's own scheme. The site
    /// key lists it (`portalAuth.nativeRedirects`), or the handoff refuses it.
    static let redirect = URL(string: "wacbusiness://portal-signed-in")!

    /// The CMS definition id of the `wac` site ("WAC Customer Portal").
    static let cmsId = "cms_x5xpger1lv3j"
    /// The website's site key (publishable), the one business.wac.rocks resolves to.
    static let siteKey = "pk_live_2qbx8m0vxxkqnr8i14mpri8s"
    /// WAC's own sign-in service: the site key's `portalAuth.clerkPublishableKey`.
    static let providerKey = "pk_live_Y2xlcmsud2FjLnJvY2tzJA"
    /// The origin presented when the site key is checked: the website's own.
    static let origin = "https://business.wac.rocks"
}
