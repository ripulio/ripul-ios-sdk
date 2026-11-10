import SwiftUI
import RipulAgent

/// The control playground as an app: its tab bar is iOS's own, each page drawn
/// natively by the SDK. Nobody signs in: every request carries the site's
/// publishable key as `X-Site-Key`, so it reads the site's public, made-up data
/// and its forms open but can't save.
@main
struct PlaygroundApp: App {
    @StateObject private var links = CmsAppController()

    var body: some Scene {
        WindowGroup {
            CmsAppView(
                cmsId: Config.site.cmsId,
                clientConfig: CmsClientConfig(
                    getToken: { nil },
                    origin: Config.site.origin,
                    visitorSendsSiteKey: Config.site.sendsSiteKey
                ),
                visitorSiteKey: Config.site.siteKey,
                controller: links
            )
            // `ripul-playground://ripul-page/<slug>` opens any page, the tab bar's or not;
            // an agent's `device_open_app_url` arrives as the notification.
            .onOpenURL { links.handle(url: $0) }
            .onReceive(NotificationCenter.default.publisher(for: .ripulOpenAppURL)) { note in
                if let url = note.object as? URL { links.handle(url: url) }
            }
            .task {
                // `SIMCTL_CHILD_PLAYGROUND_PAGE=<slug> xcrun simctl launch …` opens on that page.
                if let page = ProcessInfo.processInfo.environment["PLAYGROUND_PAGE"] ?? UserDefaults.standard.string(forKey: "PLAYGROUND_PAGE"), !page.isEmpty {
                    links.open(pageSlug: page)
                }
                // Lets an agent's chat drive this simulator build (docs/simulator-tools.md).
                #if targetEnvironment(simulator) && DEBUG
                RipulSimulatorTools.start(registry: RipulToolRegistry())
                #endif
            }
        }
    }
}
