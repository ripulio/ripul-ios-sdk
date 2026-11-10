import SwiftUI
import RipulAgent

@main
struct WACNextApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if let session = app.session {
                    SignedInView(session: session)
                } else {
                    SignInView()
                }
            }
            .environmentObject(app)
            .task {
                // Lets an agent's chat drive this simulator build (docs/simulator-tools.md).
                #if targetEnvironment(simulator) && DEBUG
                RipulSimulatorTools.start(registry: RipulToolRegistry())
                #endif
            }
        }
    }
}

/// Signed in or not: the WAC session in the Keychain.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var session: WACSession? = SessionStore.load()

    func signedIn(_ session: WACSession) {
        SessionStore.save(session)
        self.session = session
    }

    /// Ends the token on WAC's server (best effort), then forgets it here.
    func signOut() async {
        if let session { await WACAPI.logout(session) }
        SessionStore.clear()
        session = nil
    }
}
