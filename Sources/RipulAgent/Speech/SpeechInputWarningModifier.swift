import SwiftUI

/// Shared by conversation mode and standalone dictation on both platforms.
struct SpeechInputWarningModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("Microphone unavailable", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}
