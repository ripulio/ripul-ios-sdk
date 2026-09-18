import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

/// Shared by conversation mode and standalone dictation on both platforms.
struct SpeechInputWarningModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("Microphone unavailable", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            // A denied mic is a dead end without this: the OS will not ask
            // again, so the only way back is the privacy pane. Offer it on
            // every warning rather than trying to tell denial apart from the
            // other setup failures, which are equally unrecoverable in-process.
            Button("Open Settings") {
                Self.openMicrophonePrivacySettings()
                message = nil
            }
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    /// Deep-links to the microphone privacy list. macOS (both Catalyst and
    /// AppKit) takes the System Settings URL scheme; iOS can only open the
    /// app's own settings page, which is where its mic switch lives anyway.
    static func openMicrophonePrivacySettings() {
        #if targetEnvironment(macCatalyst)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        UIApplication.shared.open(url)
        #elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}
