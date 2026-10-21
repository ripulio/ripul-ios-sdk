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
    /// A Mac shared with this person's team whose owner has not shared this
    /// screen's area with them, and the area's name ("the Dock"). The screen
    /// has no Mac to work through, but "No Paired Mac" would send a team
    /// member off to pair one; this says why instead.
    private var withheldBy: String?
    private var area = ""
    @State private var showingHelp = false
    @Environment(\.ripulSignedIn) private var signedIn

    public init(_ purpose: String, @ViewBuilder actions: () -> Actions) {
        self.purpose = purpose
        self.actions = actions()
    }

    /// Says a team Mac is there but this area of it is not shared, when
    /// `macName` is set; otherwise the usual "No Paired Mac".
    public func withheld(by macName: String?, area: String) -> Self {
        var copy = self
        copy.withheldBy = macName
        copy.area = area
        return copy
    }

    public var body: some View {
        if let withheldBy {
            ContentUnavailableView {
                Label {
                    Text("Not Shared With Your Team").ripulEmptyStateTitle()
                } icon: {
                    Image(systemName: "lock")
                }
            } description: {
                Text("\(withheldBy)'s owner hasn't shared \(area) with your team.")
                    .ripulEmptyStateDescription()
            }
            .uiKitIdentifier("NoPairedMacView.withheld")
        } else {
            noPairedMac
        }
    }

    private var noPairedMac: some View {
        ContentUnavailableView {
            Label {
                HStack(spacing: 6) {
                    // A hidden twin of the help button, so the title stays centred.
                    helpIcon.hidden().accessibilityHidden(true)
                    Text("No Paired Mac").ripulEmptyStateTitle()
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
                .ripulEmptyStateDescription()
        } actions: {
            actions
        }
        .ripulSheet(isPresented: $showingHelp) { ConnectMacHelpScreen(signedIn: signedIn) }
        .uiKitIdentifier("NoPairedMacView")
    }

    private var helpIcon: some View {
        Image(systemName: "questionmark.circle").font(.ripulIcon(.body, weight: .regular))
    }
}

public extension NoPairedMacView where Actions == EmptyView {
    init(_ purpose: String) {
        self.init(purpose) { EmptyView() }
    }
}
