import SwiftUI
import RipulAgent

/// The signed-in app: the business site drawn by the SDK as a whole app. Its
/// five tabs come from the `tabBar` on the site's top-bar shell (iPhone-only
/// items, so the website itself is unchanged), and its bell and account avatar
/// from that tab bar's toolbar. Every request carries the app's session from
/// WAC's own sign-in, so each page shows exactly what the website shows them.
struct SignedInView: View {
    let member: CmsPortalMember
    @EnvironmentObject private var session: CmsPortalSession
    @StateObject private var links = CmsAppController()
    @State private var confirmingSignOut = false

    var body: some View {
        CmsAppView(
            cmsId: BusinessConfig.cmsId,
            clientConfig: CmsClientConfig(
                getToken: { nil },
                // The bell keeps its read records under the member's email, and the
                // account avatar shows their initials, as on the website.
                userName: member.name,
                userEmail: member.email,
                origin: BusinessConfig.origin,
                portalTokenProvider: { [session] in await session.token() }
            ),
            visitorSiteKey: BusinessConfig.siteKey,
            hostTabs: [
                // Sign out is in the account avatar's menu (the toolbar), so this tab
                // shows only while the site can't load: Sign out stays reachable then,
                // and the bar keeps the site's five tabs, with no More.
                CmsAppHostTab(id: "account", title: "Account", systemImage: "person.crop.circle",
                              onlyWhileSiteUnavailable: true) {
                    AccountView(member: member, confirmingSignOut: $confirmingSignOut)
                },
            ],
            hostActions: [
                "signOut": { confirmingSignOut = true },
            ],
            controller: links
        )
        .alert("Sign out", isPresented: $confirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) { Task { await session.signOut() } }
        } message: {
            Text("Are you sure you want to sign out?")
        }
        // wacbusiness://ripul-page/<slug> opens a page (CmsAppController.handle(url:)).
        .onOpenURL { links.handle(url: $0) }
        // The same link from an agent's open_app_url (simulator tests).
        .onReceive(NotificationCenter.default.publisher(for: .ripulOpenAppURL)) { note in
            if let url = note.object as? URL { links.handle(url: url) }
        }
    }
}

/// Who is signed in, and Sign out: the one screen the site can't draw, since
/// the website's account menu lives in its top bar.
private struct AccountView: View {
    let member: CmsPortalMember
    @Binding var confirmingSignOut: Bool

    var body: some View {
        List {
            Section {
                if let name = member.name, !name.isEmpty {
                    LabeledContent("Name", value: name)
                        .accessibilityIdentifier("account.name")
                }
                LabeledContent("Email", value: member.email ?? "—")
                    .accessibilityIdentifier("account.email")
            } footer: {
                Text("Signed in with your wac for business account, as on business.wac.rocks.")
            }

            Section {
                CmsFormPresentationSetting(cmsId: BusinessConfig.cmsId)
                    .accessibilityIdentifier("account.formPresentation")
            } header: {
                Text("On this iPhone")
            }

            Section {
                Link(destination: BusinessConfig.siteURL) {
                    Label("Open the website", systemImage: "safari")
                }
                Button(role: .destructive) {
                    confirmingSignOut = true
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityIdentifier("account.signOut")
            }
        }
        .navigationTitle("Account")
    }
}
