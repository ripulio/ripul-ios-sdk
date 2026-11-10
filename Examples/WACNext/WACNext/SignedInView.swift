import SwiftUI
import RipulAgent

/// The signed-in app: the `wac-app` CMS site drawn by the SDK as a whole app, its tabs
/// on iOS's own tab bar, with this app's Account tab after them. The CMS doesn't own
/// sign-in, so the app signs out: a site card's `open: { host: "signOut" }` asks it to.
/// Account (who you are, Sign out) is this app's own screen only while the site isn't
/// loaded; otherwise the site's Profile hub (Home's person button) has Logout.
struct SignedInView: View {
    let session: WACSession
    @EnvironmentObject private var app: AppModel
    @StateObject private var links = CmsAppController()
    /// Rails keeps one session per user, so signing in elsewhere ends this one. The site
    /// would then answer "No access" in place of every tab, Account included, so an ended
    /// session goes straight to Account (the message and Sign out) instead.
    @State private var sessionEnded = false
    /// The hub's Logout asks first, as WAC's does ("Are you sure you want to log out?").
    @State private var confirmingSignOut = false

    var body: some View {
        if Config.cmsConfigured && !sessionEnded {
            appView
                .task { await checkSession() }
        } else {
            NavigationStack { AccountView(session: session) }
        }
    }

    private func checkSession() async {
        do {
            _ = try await WACAPI.user(session)
        } catch let failure as WACAPI.Failure where failure.code == "session_ended" {
            sessionEnded = true
        } catch {
            // Offline or a server error: the site shows its own error and Try again.
        }
    }

    private var appView: some View {
        CmsAppView(
            cmsId: Config.cmsId,
            clientConfig: CmsClientConfig(
                getToken: { nil },
                // WAC's own headers are the portal credentials: the worker checks them
                // with Rails and runs every query as this person.
                portalCredentialProvider: { SessionStore.load().map(WACAPI.headers(for:)) },
                origin: Config.origin
            ),
            visitorSiteKey: Config.siteKey,
            hostTabs: [
                // The site draws Profile (its hub, from Home's person button) and the Legal
                // hub; this tab shows only while the site can't be reached, so Sign out stays
                // within reach then.
                CmsAppHostTab(id: "account", title: "Account", systemImage: "person.crop.circle",
                              onlyWhileSiteUnavailable: true) {
                    AccountView(session: session)
                },
            ],
            hostActions: [
                "signOut": { confirmingSignOut = true },
            ],
            controller: links
        )
        .alert("Log out", isPresented: $confirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Log out", role: .destructive) { Task { await app.signOut() } }
        } message: {
            Text("Are you sure you want to log out?")
        }
        // A tap on the running shift's Live Activity opens its page.
        .onOpenURL { links.handle(url: $0) }
        // The same link from an agent's open_app_url (simulator tests).
        .onReceive(NotificationCenter.default.publisher(for: .ripulOpenAppURL)) { note in
            if let url = note.object as? URL { links.handle(url: url) }
        }
    }
}

/// Proves the WAC token works (`GET /api/v1/user`), and signs out. Drawn in the site's
/// `wacHub` list style (WAC's settings-hub cards), so this screen of the app's own reads
/// like the CMS tabs beside it; outside `CmsAppView` it falls back to iOS's own list.
private struct AccountView: View {
    let session: WACSession
    @EnvironmentObject private var app: AppModel
    @State private var user: WACAPI.User?
    @State private var error: String?
    @State private var loading = false
    @State private var signingOut = false

    var body: some View {
        List {
            Section {
                if let user {
                    CmsListRow("User id", systemImage: "number", trailing: user.id)
                        .cmsListRow()
                        .accessibilityIdentifier("user.id")
                    CmsListRow("Name", systemImage: "person", trailing: user.name.isEmpty ? "—" : user.name)
                        .cmsListRow()
                        .accessibilityIdentifier("user.name")
                    if !user.phone.isEmpty {
                        CmsListRow("Number", systemImage: "phone", trailing: user.phone)
                            .cmsListRow()
                    }
                } else if loading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Asking WAC who you are…")
                    }
                    .cmsListRow()
                }
                if let error {
                    Text(WACAPI.message(for: error))
                        .foregroundStyle(.red)
                        .cmsListRow()
                        .accessibilityIdentifier("user.error")
                    Button { Task { await load() } } label: {
                        CmsListRow("Try again", systemImage: "arrow.clockwise")
                    }
                    .cmsListRow()
                }
            } footer: {
                Text("From WAC's GET /api/v1/user with this app's token.")
            }

            if Config.cmsConfigured {
                Section {
                    CmsFormPresentationSetting(cmsId: Config.cmsId)
                        .cmsListRow()
                        .accessibilityIdentifier("formPresentation")
                } header: {
                    Text("On this iPhone")
                } footer: {
                    Text("Pages slide in under the masthead and go back with a swipe; sheets swipe away. As the site sets: shifts, holidays and sick days as pages, events as sheets.")
                }
            }

            if !Config.cmsConfigured {
                Section {
                    Text("The shifts appear once Config.swift has the CMS id and site key.")
                        .foregroundStyle(.secondary)
                        .cmsListRow()
                        .accessibilityIdentifier("cms.notConfigured")
                }
            }

            Section {
                Button(role: .destructive) {
                    signingOut = true
                    Task { await app.signOut() }
                } label: {
                    CmsListRow("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive)
                }
                .cmsListRow()
                .disabled(signingOut)
                .accessibilityIdentifier("signOut")
            }
        }
        // The site's masthead, as on its CMS pages; the first card cuts into it.
        // Inside the list style, so the band draws over the style's page colour.
        .cmsSiteMasthead("Account", cut: "rounded")
        .cmsListStyle("wacHub")
        .navigationTitle("Account")
        .refreshable { await load() }
        .task { if user == nil { await load() } }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            user = try await WACAPI.user(session)
        } catch let failure as WACAPI.Failure {
            error = failure.code
        } catch {
            self.error = "network"
        }
    }
}
