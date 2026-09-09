import SwiftUI

/// Voice & speech hub — reached from the root of Settings (promoted out of
/// Debug once voice grew real user-facing controls). Dictation provider,
/// conversation-mode presentation, recognition language, and the sandbox.
/// iOS pushes it in the settings NavigationStack; macOS presents it in a
/// sheet wrapped in its own NavigationStack (so the sandbox link pushes).
@available(iOS 26.0, macOS 26.0, *)
public struct VoiceSettingsScreen: View {
    let tokenProvider: () -> String?

    public init(tokenProvider: @escaping () -> String?) { self.tokenProvider = tokenProvider }

    @AppStorage(SpeechPreferences.dictationProviderKey, store: SpeechPreferences.store) private var chatDictationProvider = "apple"
    // Must match SpeechPreferences.voiceModeStyle's fallback, or the picker
    // shows a selection the app is not actually using.
    @AppStorage(SpeechPreferences.voiceModeStyleKey, store: SpeechPreferences.store) private var voiceModeStyle = "compact"
    @AppStorage(SpeechPreferences.speechLanguageKey, store: SpeechPreferences.store) private var speechLanguage = "en"
    @AppStorage(SpeechPreferences.speechKeytermsKey, store: SpeechPreferences.store) private var speechKeyterms = "Ripul"
    @AppStorage(SpeechPreferences.speechPaceKey, store: SpeechPreferences.store) private var speechPace = 1.0
    @AppStorage(SpeechPreferences.speechExpressivenessKey, store: SpeechPreferences.store) private var speechExpressiveness = 0.35

    /// A site key's voice profile can lock speech config. When it does, these
    /// controls still show the effective values but stop accepting edits —
    /// silently ignoring them would read as a broken settings screen.
    private var isManaged: Bool { SpeechPreferences.isManagedByProfile }

    public var body: some View {
        Form {
            if isManaged {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Managed by \(SpeechPreferences.managingProfileName ?? "this site key")")
                            Text("Voice settings are set by the site key and can't be changed here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .uiKitIdentifier("VoiceSettingsScreen.managedBanner")
                }
            }

            Section {
                Picker(selection: $chatDictationProvider) {
                    Text("Apple (on-device)").tag("apple")
                    Text("ElevenLabs").tag("elevenlabs")
                } label: {
                    Label("Dictation provider", systemImage: "mic.badge.plus")
                }
                .uiKitIdentifier("VoiceSettingsScreen.dictationProvider")
            } header: {
                Text("Recognition")
            } footer: {
                Text("Apple runs on-device and works offline; ElevenLabs uses cloud transcription. Your choice is saved in this app and is not synced to other apps or devices.")
            }
            .disabled(isManaged)

            Section {
                TextField("Ripul, WKWebView, xcodegen…", text: $speechKeyterms, axis: .vertical)
                    .lineLimit(1...3)
                    .autocorrectionDisabled()
                    .uiKitIdentifier("VoiceSettingsScreen.keyterms")
            } header: {
                Text("Key terms")
            } footer: {
                Text("Comma-separated names and jargon the recognizer should prefer — product names, technical terms. Applies to ElevenLabs recognition.")
            }
            .disabled(isManaged)

            Section {
                Picker(selection: $voiceModeStyle) {
                    Text("Full screen").tag("fullscreen")
                    Text("Compact panel").tag("compact")
                } label: {
                    Label("Voice mode style", systemImage: "rectangle.bottomthird.inset.filled")
                }
                .uiKitIdentifier("VoiceSettingsScreen.voiceModeStyle")
            } header: {
                Text("Conversation mode")
            } footer: {
                Text("Tap the mic in chat to start a hands-free conversation; double-tap for dictation into the text box.")
            }
            .disabled(isManaged)

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label("Pace", systemImage: "hare")
                        Spacer()
                        Text(String(format: "%.2f×", speechPace))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $speechPace, in: 0.7...1.2, step: 0.05)
                        .uiKitIdentifier("VoiceSettingsScreen.pace")
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label("Expressiveness", systemImage: "theatermasks")
                        Spacer()
                        Text(String(format: "%.0f%%", speechExpressiveness * 100))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $speechExpressiveness, in: 0...1, step: 0.05)
                        .uiKitIdentifier("VoiceSettingsScreen.expressiveness")
                }
            } header: {
                Text("Delivery")
            } footer: {
                Text("Applies to ElevenLabs speech — replies, acknowledgments, and read-aloud. Higher expressiveness is livelier but slightly less steady.")
            }
            .disabled(isManaged)

            Section("Language") {
                Picker(selection: $speechLanguage) {
                    Text("English").tag("en")
                    Text("German").tag("de")
                    Text("Dutch").tag("nl")
                    Text("French").tag("fr")
                    Text("Spanish").tag("es")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Auto-detect").tag("auto")
                } label: {
                    Label("Speech language", systemImage: "globe")
                }
                .uiKitIdentifier("VoiceSettingsScreen.speechLanguage")
            }
            .disabled(isManaged)

            Section("Testing") {
                NavigationLink {
                    SpeechSandboxScreen(tokenProvider: tokenProvider)
                } label: {
                    Label("Speech Sandbox", systemImage: "waveform")
                }
                .uiKitIdentifier("VoiceSettingsScreen.speechSandbox")
            }
        }
        .navigationTitle("Voice")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}
