import SwiftUI
import PhotosUI
@testable import RipulAgent

@main
struct SpeechPrivacyHostApp: App {
    init() {
        if ProcessInfo.processInfo.arguments.contains("--profile") {
            SpeechPreferences.store = UserDefaults(suiteName: "io.ripul.tests.profile")!
            if ProcessInfo.processInfo.arguments.contains("--reset-profile") {
                SpeechPreferences.store.removePersistentDomain(forName: "io.ripul.tests.profile")
            }
        } else {
            SpeechPreferences.activeProfile = VoiceProfileConfig(sttProviderId: "apple-native", allowUserOverride: false)
        }
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--profile") { ProfileHostView() }
            else { PrivacyHostView() }
        }
    }
}

private struct PrivacyHostView: View {
    @StateObject private var voice = VoiceModeController()
    @StateObject private var bridge = AgentBridge()
    @State private var text = ""
    @State private var images: [NativeImageAttachment] = []
    @State private var photos: [PhotosPickerItem] = []
    @State private var responseCount = 0
    private let provider = AppleSpeechProvider()
    private var dictation: Bool { ProcessInfo.processInfo.arguments.contains("--dictation") }

    var body: some View {
        VStack {
            Text("Host responsive: \(responseCount)")
            Button("Still responsive") { responseCount += 1 }
            Spacer()
            NativeChatInput(
                text: $text, imageAttachments: $images, selectedPhotos: $photos,
                onSubmit: {}, speechProvider: provider,
                onEnterVoiceMode: dictation ? nil : { _ in
                    voice.start(bridge: bridge, tokenProvider: nil)
                    return true
                }
            )
        }
        .padding()
        .modifier(SpeechInputWarningModifier(message: $voice.microphoneWarning))
    }
}

private struct ProfileHostView: View {
    private let bridge: AgentBridge
    private let model: RipulSessionListModel
    private let cache = UserDefaultsSessionCache()
    @State private var showProfile = false
    @State private var effectiveProvider = ""

    init() {
        let bridge = AgentBridge(audience: .developer)
        self.bridge = bridge
        self.model = RipulSessionListModel(bridge: bridge, tokenProvider: { nil }, cache: cache)
    }

    var body: some View {
        VStack {
            Menu("Sessions menu") {
                SessionListMenu(bridge: bridge, model: model, cache: cache, showingSessionList: .constant(true))
            }
            Text("Effective provider: \(effectiveProvider)")
        }
        .onAppear { effectiveProvider = SpeechPreferences.dictationProviderId }
        .onReceive(NotificationCenter.default.publisher(for: .ripulShowProfile)) { notification in
            guard notification.object as? AgentBridge === bridge else { return }
            showProfile = true
        }
        .sheet(isPresented: $showProfile, onDismiss: { effectiveProvider = SpeechPreferences.dictationProviderId }) {
            NavigationStack {
                RipulProfileScreen(bridge: bridge, userName: "Test User", userEmail: nil,
                                   tokenProvider: { nil }, onSignOut: {}, planContent: { EmptyView() })
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showProfile = false } } }
            }
        }
    }
}
