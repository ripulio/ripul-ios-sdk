import SwiftUI

extension View {
    /// Excludes a credential-entry presentation from agent inspection and
    /// capture, and retires existing screen/voice capture before entry begins.
    /// Apply to the presented sheet, so protection lasts through AutoFill UI.
    @MainActor public func ripulPrivateInput() -> some View {
        modifier(PrivateInputModifier())
    }
}

private struct PrivateInputModifier: ViewModifier {
    @State private var protection: UUID?

    func body(content: Content) -> some View {
        content
            .ripulAIContextExcluded()
            .onAppear {
                guard protection == nil else { return }
                protection = SecureInputProtection.begin()
                #if os(iOS)
                LiveStreamHost.shared.pauseForSecureInput()
                RipulViewExplorer.dismiss()
                VoiceModePresence.shared.controller?.stop()
                #endif
            }
            .onDisappear {
                if let protection { SecureInputProtection.end(protection) }
                protection = nil
            }
    }
}
