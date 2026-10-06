import SwiftUI
import Speech

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
    @AppStorage(SpeechPreferences.voiceSendModeKey, store: SpeechPreferences.store) private var voiceSendMode = SpeechPreferences.defaultVoiceSendMode.rawValue
    @AppStorage(SpeechPreferences.sayStopToInterruptKey, store: SpeechPreferences.store) private var sayStopToInterrupt = false
    @AppStorage(SpeechPreferences.speechLanguageKey, store: SpeechPreferences.store) private var speechLanguage = "en"
    @AppStorage(SpeechPreferences.speechKeytermsKey, store: SpeechPreferences.store) private var speechKeyterms = "Ripul"
    @AppStorage(SpeechPreferences.speechPaceKey, store: SpeechPreferences.store) private var speechPace = 1.0
    @AppStorage(SpeechPreferences.speechExpressivenessKey, store: SpeechPreferences.store) private var speechExpressiveness = 0.35

    /// A site key's voice profile can lock speech config. When it does, these
    /// controls still show the effective values but stop accepting edits —
    /// silently ignoring them would read as a broken settings screen.
    private var isManaged: Bool { !BundledAgentRuntime.isEnabled && SpeechPreferences.isManagedByProfile }
    @State private var hasDeviceKey = DeviceSpeechCredentials.isConfigured

    /// What "no choice" means: the site key's model when its profile names
    /// one, otherwise the built-in default.
    private var defaultModelLabel: String {
        let id = SpeechPreferences.activeProfile?.ttsModelId ?? ElevenLabsModelOption.defaultModelId
        let label = ElevenLabsModelOption.named(id)?.label ?? id
        return SpeechPreferences.activeProfile?.ttsModelId == nil ? "Default (\(label))" : "Site default (\(label))"
    }

    public var body: some View {
        Form {
            DeviceSpeechKeySection()
            if isManaged {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Managed by \(SpeechPreferences.managingProfileName ?? "this site key")")
                            Text("Voice and recognition settings are managed here. You can still choose when to send your messages.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .uiKitIdentifier("VoiceSettingsScreen.managedBanner")
                }
            }

            // Standalone without a key speaks with Apple, so there is no model to choose.
            if !(BundledAgentRuntime.isEnabled && !hasDeviceKey) {
                Section {
                    ForEach(SpeechRole.allCases, id: \.self) { role in
                        ElevenLabsModelPicker(role: role, defaultLabel: defaultModelLabel)
                    }
                } header: {
                    Text("ElevenLabs models")
                } footer: {
                    Text("Replies are what conversation mode says back, acknowledgements are the short lines while the agent works, and read aloud is the speaker button on a message. "
                         + ElevenLabsModelOption.all.map { "\($0.label): \($0.summary)" }.joined(separator: " "))
                }
                .disabled(isManaged)
            }

            Section {
                Picker(selection: $chatDictationProvider) {
                    Text("Apple (on-device)").tag("apple")
                    Text("ElevenLabs").tag("elevenlabs")
                        .disabled(BundledAgentRuntime.isEnabled && !hasDeviceKey)
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
                Picker("Send messages", selection: $voiceSendMode) {
                    Text("Detect pauses automatically").tag(VoiceSendMode.automatic.rawValue)
                    Text("Say \"Send command\"").tag(VoiceSendMode.sendCommand.rawValue)
                }
                .uiKitIdentifier("VoiceSettingsScreen.voiceSendMode")
            } header: {
                Text("Sending in conversation mode")
            } footer: {
                Text(voiceSendMode == VoiceSendMode.sendCommand.rawValue
                     ? "Finish with \"Send command\" and pause briefly. The closing phrase is removed before sending. Other pauses let you keep thinking; you can also tap Send. Saved in this app on this device."
                     : "Messages send automatically when you pause speaking. You can also tap Send. Saved in this app on this device.")
            }

            Section {
                Toggle("Say \"Stop\" to interrupt", isOn: $sayStopToInterrupt)
                    .uiKitIdentifier("VoiceSettingsScreen.sayStopToInterrupt")
                    .onChange(of: sayStopToInterrupt) { _, on in
                        // The listener uses on-device recognition, which needs
                        // this permission even when dictation uses ElevenLabs.
                        // Ask here rather than mid-readout.
                        if on { SFSpeechRecognizer.requestAuthorization { _ in } }
                    }
            } header: {
                Text("Interrupting")
            } footer: {
                Text("Experimental. While Ripul is talking, the microphone stays on and listens only for \"stop\", \"pause\" or \"wait\", using speech recognition on this device. Tapping always works. Saved in this app on this device.")
            }

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
                Text("Applies to ElevenLabs speech — replies, acknowledgments, and read-aloud. Higher expressiveness is livelier but slightly less steady. Eleven v4 ignores Pace.")
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
        .onReceive(NotificationCenter.default.publisher(for: DeviceSpeechCredentials.changed)) { _ in hasDeviceKey = DeviceSpeechCredentials.isConfigured }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

/// One job's ElevenLabs model, stored per role in the speech preferences.
@available(iOS 26.0, macOS 26.0, *)
private struct ElevenLabsModelPicker: View {
    let role: SpeechRole
    let defaultLabel: String
    @AppStorage private var modelId: String

    init(role: SpeechRole, defaultLabel: String) {
        self.role = role
        self.defaultLabel = defaultLabel
        _modelId = AppStorage(wrappedValue: "", SpeechPreferences.ttsModelKey(for: role), store: SpeechPreferences.store)
    }

    var body: some View {
        Picker(selection: $modelId) {
            Text(defaultLabel).tag("")
            ForEach(ElevenLabsModelOption.all) { model in
                Text(model.label).tag(model.id)
            }
        } label: {
            Label(role.title, systemImage: icon)
        }
        .uiKitIdentifier("VoiceSettingsScreen.ttsModel.\(role.rawValue)")
    }

    private var icon: String {
        switch role {
        case .reply: return "bubble.left.and.text.bubble.right"
        case .acknowledgement: return "checkmark.bubble"
        case .readAloud: return "speaker.wave.2"
        }
    }
}
