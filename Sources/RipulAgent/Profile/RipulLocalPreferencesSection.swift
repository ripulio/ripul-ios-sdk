import SwiftUI

/// Shared by Settings and Profile; these preferences belong to the device.
@available(iOS 26.0, macOS 26.0, *)
public struct RipulLocalPreferencesSection: View {
    @ObservedObject private var bridge: AgentBridge
    private let tokenProvider: () -> String?
    @AppStorage("ripul.localTheme", store: SpeechPreferences.store) private var theme = "auto"
    public init(bridge: AgentBridge, tokenProvider: @escaping () -> String?) {
        self.bridge = bridge; self.tokenProvider = tokenProvider
    }
    public var body: some View {
        Section("Appearance and voice") {
            NavigationLink { VoiceSettingsScreen(tokenProvider: tokenProvider) } label: {
                Label("Voice", systemImage: "waveform")
            }.uiKitIdentifier("ProfileScreen.preferences.voice")
            Picker(selection: $theme) {
                Text("Auto (System)").tag("auto")
                Text("Dark Gradient").tag("darkGradient")
                Text("Dark Flat").tag("darkFlat")
                Text("Dark Minimal").tag("darkMinimal")
                Text("Dark Glass").tag("darkGlass")
                Text("Dark Neon").tag("darkNeon")
                Text("Dark Aurora").tag("darkAurora")
                Text("Light").tag("light")
            } label: { Label("Theme", systemImage: "paintpalette") }
                .uiKitIdentifier("ProfileScreen.preferences.theme")
                .onChange(of: theme) { _ in apply() }
                .task {
                    if SpeechPreferences.store.object(forKey: "ripul.localTheme") != nil { apply() }
                    else if let existing = try? await bridge.callAsyncJavaScript("return window.__ripulGetTheme?.()") as? String {
                        theme = existing
                    }
                }
        }
    }
    private func apply() { bridge.applyDeviceTheme() }
}

extension AgentBridge {
    public func applyDeviceTheme() {
        guard let theme = SpeechPreferences.store.string(forKey: "ripul.localTheme"),
              ["auto", "darkGradient", "darkFlat", "darkMinimal", "darkGlass", "darkNeon", "darkAurora", "light"].contains(theme) else { return }
        evaluateJavaScript("window.__ripulSetTheme?.('\(theme)')")
    }
}
