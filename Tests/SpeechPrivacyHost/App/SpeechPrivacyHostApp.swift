import SwiftUI
import PhotosUI
@testable import RipulAgent

@main
struct SpeechPrivacyHostApp: App {
    init() {
        SpeechPreferences.activeProfile = VoiceProfileConfig(sttProviderId: "apple-native", allowUserOverride: false)
    }

    var body: some Scene { WindowGroup { PrivacyHostView() } }
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
