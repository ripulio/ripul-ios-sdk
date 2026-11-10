import SwiftUI
import RipulAgent

@main
struct WACBusinessApp: App {
    /// WAC's business sign-in: the system's sign-in sheet on the website, then the
    /// app's own session, kept in the Keychain.
    @StateObject private var session = CmsPortalSession(
        siteURL: BusinessConfig.siteURL,
        providerKey: BusinessConfig.providerKey,
        siteKey: BusinessConfig.siteKey,
        redirect: BusinessConfig.redirect,
        keychainService: "com.WAC.business.portal-session"
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .task {
                    // Lets an agent's chat drive this simulator build (docs/simulator-tools.md).
                    #if targetEnvironment(simulator) && DEBUG
                    RipulSimulatorTools.start(registry: RipulToolRegistry())
                    #endif
                }
        }
    }
}

/// Signed in or not: the session in the Keychain.
struct RootView: View {
    @EnvironmentObject private var session: CmsPortalSession

    var body: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "BusinessVisitorPreview") {
            VisitorPreview()
        } else {
            signedInOrOut
        }
        #else
        signedInOrOut
        #endif
    }

    @ViewBuilder
    private var signedInOrOut: some View {
        switch session.state {
        case .signedOut, .signingIn:
            SignInView()
        case .signedIn(let member):
            SignedInView(member: member)
                // A different person signed in: a fresh app, not the last one's pages.
                .id(member.id)
        }
    }
}

#if DEBUG
/// An agent's check without a business login: the site as a signed-out visitor
/// sees it, its public pages and the tab bar's toolbar included. On with
/// `defaults write com.WAC.business BusinessVisitorPreview -bool YES` (in the
/// simulator: `xcrun simctl spawn <udid> defaults write …`) or the launch argument
/// `-BusinessVisitorPreview YES`. Debug builds only.
private struct VisitorPreview: View {
    var body: some View {
        CmsAppView(
            cmsId: BusinessConfig.cmsId,
            clientConfig: CmsClientConfig(getToken: { nil }, origin: BusinessConfig.origin),
            visitorSiteKey: BusinessConfig.siteKey
        )
    }
}
#endif

extension Color {
    /// The business site's primary colour (its theme's `palette.primary`).
    static let wacPurple = Color(red: 0x75 / 255, green: 0x35 / 255, blue: 0x89 / 255) // theme-exempt: the brand, before the site's theme has loaded
}

/// The site's brand gradient, edge to edge, with the logo: the launch and
/// sign-in backdrop, before the site's own theme has loaded.
struct BrandBackdrop<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0x6d / 255, green: 0x31 / 255, blue: 0x80 / 255), // theme-exempt: the site's gradient stops
                         Color(red: 0x7c / 255, green: 0x3b / 255, blue: 0x91 / 255)], // theme-exempt: the site's gradient stops
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            VStack(spacing: 40) {
                Spacer()
                Image("BusinessLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260)
                    .accessibilityLabel("wac for business")
                content
                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }
}
