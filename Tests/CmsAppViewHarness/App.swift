import SwiftUI
import RipulAgent

/// The host the UI checks drive: the scratch site `tab-bar-iphone-scratch` as
/// an app, as its anonymous visitor, with one host tab (an Account tab, as
/// WAC Next adds). `--fresh` forgets the remembered tab first.
@main
struct CmsAppViewHost: App {
    static let cmsId = "cms_yiqxgp66pbjs"
    static let siteKey = "pk_live_dag96obwwcp3kqsa0mfkj26p"

    init() {
        if CommandLine.arguments.contains("--fresh") {
            UserDefaults.standard.removeObject(forKey: "io.ripul.cms.app.tab.\(Self.cmsId)")
        }
    }

    /// `--refused`: a key the server turns away, so the site never loads.
    static var key: String {
        CommandLine.arguments.contains("--refused") ? "pk_live_not_a_real_key" : siteKey
    }

    /// `--page <slug>`: open that page once the site has loaded.
    static var page: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--page"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var body: some Scene {
        WindowGroup {
            CmsAppView(
                cmsId: Self.cmsId,
                clientConfig: CmsClientConfig(getToken: { nil }),
                visitorSiteKey: Self.key,
                hostTabs: [
                    CmsAppHostTab(id: "account", title: "Account", systemImage: "person.crop.circle") {
                        List {
                            Text("Signed in as a visitor")
                            Button("Sign out", role: .destructive) {}
                        }
                        .navigationTitle("Account")
                    }
                ],
                initialPageSlug: Self.page
            )
        }
    }
}
