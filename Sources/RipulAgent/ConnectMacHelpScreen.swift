import SwiftUI

/// The two ways a Mac gets connected, opened from `NoPairedMacView`'s help
/// button: through a Ripul account (Normal), or paired with this phone
/// directly. Both need Ripul Host on the Mac, so the page that installs it is
/// linked from the step that says so.
///
/// Normal needs the same account on both ends. When this device has none yet
/// (`signedIn` false, see `EnvironmentValues.ripulSignedIn`), its steps start
/// with signing in here, before the Mac is touched.
struct ConnectMacHelpScreen: View {
    let signedIn: Bool
    @Environment(\.dismiss) private var dismiss

    private static let downloadURL = URL(string: RipulDomain.macDownloadURL)!
    /// The address as someone would type it on the Mac: no scheme.
    private static let downloadAddress = "\(RipulDomain.demoHost)\(downloadURL.path)"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Ripul's agents run on your Mac. This device reaches the Mac in one of two ways, and both need Ripul Host installed on it.")
                        .foregroundStyle(.secondary)
                }
                Section("Normal") {
                    Text("Your Mac connects through your Ripul account. You can reach it from anywhere, and every screen can use it.")
                        .foregroundStyle(.secondary)
                    if !signedIn {
                        step(1, "Sign in on this device first. In Settings, set App startup to Normal, then sign in to your Ripul account.")
                    }
                    step(firstMacStep, "On your Mac, open this page and install Ripul Host.")
                    Link(destination: Self.downloadURL) {
                        Label(Self.downloadAddress, systemImage: "arrow.down.circle")
                    }
                    .uiKitIdentifier("ConnectMacHelpScreen.download")
                    step(firstMacStep + 1, signedIn ? "Open Ripul Host and sign in with the Ripul account you use here."
                                                    : "Open Ripul Host and sign in with the same Ripul account.")
                    step(firstMacStep + 2, "Leave it running. Your Mac appears in Ripul by itself.")
                }
                Section {
                    Text("This device talks straight to your Mac over the same Wi-Fi, or over Tailscale when you are away. Nothing goes through Ripul's servers, and no account is needed.")
                        .foregroundStyle(.secondary)
                    step(1, "Install Ripul Host on your Mac from the same page.")
                    step(2, "In Ripul Host, open Paired Phones and choose Pair iPhone.")
                    step(3, "Here, open Paired Macs and scan the code. Then approve this device on the Mac.")
                } header: {
                    Text("Direct")
                } footer: {
                    Text(signedIn ? "Direct pairing is for chats. With App startup set to Standalone in Settings, Files and the Dock use a paired Mac too. Every other screen needs the Normal connection."
                                  : "Direct pairing covers chats, Files and the Dock. Every other screen needs the Normal connection.")
                }
            }
            .navigationTitle("Connecting a Mac")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .ripulSheet(.page)
        .uiKitIdentifier("ConnectMacHelpScreen")
    }

    /// Signing in on this device comes first when it has not been done.
    private var firstMacStep: Int { signedIn ? 1 : 2 }

    private func step(_ number: Int, _ text: String) -> some View {
        Label(text, systemImage: "\(number).circle.fill")
    }
}
