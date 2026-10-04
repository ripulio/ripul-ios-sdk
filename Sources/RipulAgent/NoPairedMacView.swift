import SwiftUI

private struct RipulSignedInKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    /// Whether this app is signed in to a Ripul account. An app sets it false
    /// where it runs without one, and `NoPairedMacView`'s help then starts its
    /// Normal steps with signing in on this device. True unless an app says
    /// otherwise, so nobody is told to sign in on a guess.
    ///
    /// Ripul sets it false in Standalone only: with App startup on Normal, a
    /// signed-out app shows its sign-in screen over everything, so the help
    /// cannot be reached. That is why the signed-out wording names App startup.
    var ripulSignedIn: Bool {
        get { self[RipulSignedInKey.self] }
        set { self[RipulSignedInKey.self] = newValue }
    }
}

/// What a screen shows when it has no Mac to work through.
///
/// One view for every screen that needs a Mac, so they all say the same thing
/// and whatever is added here (a way to pair, a way to wake a sleeping Mac)
/// reaches each of them at once. A screen supplies only the sentence saying
/// what it does with a Mac; the title, the icon and the layout are decided
/// here. `actions` is for a screen that can already offer a way out.
///
/// The help button after the title opens `ConnectMacHelpScreen`: the two ways
/// to connect a Mac, and where to get Ripul Host.
///
/// Sizes itself to its container as `ContentUnavailableView` does: a card in
/// a `List`, centred on a bare screen.
public struct NoPairedMacView<Actions: View>: View {
    private let purpose: String
    private let actions: Actions
    @State private var showingHelp = false
    @Environment(\.ripulSignedIn) private var signedIn

    public init(_ purpose: String, @ViewBuilder actions: () -> Actions) {
        self.purpose = purpose
        self.actions = actions()
    }

    public var body: some View {
        ContentUnavailableView {
            Label {
                HStack(spacing: 6) {
                    // A hidden twin of the help button, so the title stays centred.
                    helpIcon.hidden().accessibilityHidden(true)
                    Text("No Paired Mac")
                    // Borderless: in a List row a plain button would take the whole row's tap.
                    Button { showingHelp = true } label: { helpIcon }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("How to connect a Mac")
                        .uiKitIdentifier("NoPairedMacView.help")
                }
            } icon: {
                Image(systemName: "desktopcomputer")
            }
        } description: {
            Text(purpose)
        } actions: {
            actions
        }
        .sheet(isPresented: $showingHelp) { ConnectMacHelpScreen(signedIn: signedIn) }
        .uiKitIdentifier("NoPairedMacView")
    }

    private var helpIcon: some View {
        Image(systemName: "questionmark.circle").font(.body.weight(.regular))
    }
}

public extension NoPairedMacView where Actions == EmptyView {
    init(_ purpose: String) {
        self.init(purpose) { EmptyView() }
    }
}
