import SwiftUI

/// Native entry only: neither a saved key nor the draft is exposed to the bridge.
@available(iOS 26.0, macOS 26.0, *)
struct DeviceSpeechKeySection: View {
    @State private var draft = ""
    @State private var configured = DeviceSpeechCredentials.isConfigured
    @State private var busy = false
    @State private var error: String?
    @State private var voices: [SpeechService.Voice] = []
    @State private var removing = false
    @AppStorage(SpeechPreferences.deviceVoiceIdKey, store: SpeechPreferences.store) private var voiceID = ""

    var body: some View {
        Section {
            if configured {
                Label("Key saved on this device", systemImage: "checkmark.shield")
                    .uiKitIdentifier("VoiceSettings.deviceKey.saved")
            }
            SecureField(configured ? "Replacement ElevenLabs API key" : "ElevenLabs API key", text: $draft)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .uiKitIdentifier("VoiceSettings.deviceKey.input")
                .ripulAIContextExcluded()
            Button(busy ? "Checking…" : (configured ? "Check and replace key" : "Check and save key")) { save() }
                .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .uiKitIdentifier("VoiceSettings.deviceKey.save")
            if configured {
                Button("Remove device key", role: .destructive) { removing = true }
                    .disabled(busy).uiKitIdentifier("VoiceSettings.deviceKey.remove")
                if !voices.isEmpty {
                    Picker("ElevenLabs voice", selection: $voiceID) {
                        Text("Automatic").tag("")
                        ForEach(voices) { Text($0.name).tag($0.id) }
                    }.uiKitIdentifier("VoiceSettings.deviceKey.voice")
                }
                Button("Refresh voices") { Task { await refresh() } }.disabled(busy)
                NavigationLink {
                    ElevenLabsUsageScreen { try await ElevenLabsDirectAPI(apiKey: { try DeviceSpeechCredentials.read() }).usage() }
                } label: {
                    Label("Usage & billing", systemImage: "chart.bar")
                }
                .uiKitIdentifier("VoiceSettings.deviceKey.usage")
            }
            if let error { Text(error).foregroundStyle(.red).uiKitIdentifier("VoiceSettings.deviceKey.error") }
        } header: {
            Text("Your ElevenLabs key")
        } footer: {
            Text("Optional. Stored in this app’s Keychain on this device. Speech and transcription connect directly to ElevenLabs using your account and quota. Nothing passes through Ripul’s servers or your paired Mac. Without a key, Standalone uses Apple speech. Internet access is needed for ElevenLabs.")
        }
        .alert("Remove ElevenLabs key?", isPresented: $removing) {
            Button("Remove", role: .destructive) {
                do {
                    try DeviceSpeechCredentials.remove()
                    configured = false; draft = ""; voices = []; error = nil
                    if BundledAgentRuntime.isEnabled { SpeechPreferences.store.set("apple", forKey: SpeechPreferences.dictationProviderKey) }
                } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Standalone will use Apple speech. Your ElevenLabs account is unchanged.") }
        .task { if configured { await refresh() } }
        .onDisappear { draft = "" }
    }
    private func save() {
        busy = true; error = nil
        let candidate = draft
        Task { @MainActor in
            defer { busy = false }
            do {
                let key = try DeviceSpeechCredentials.validate(candidate)
                let provider = ElevenLabsNativeSpeechProvider(tokenProvider: { nil }, deviceKeyProvider: { key })
                let available = try await provider.listVoices()
                try Task.checkCancellation()
                try DeviceSpeechCredentials.save(key)
                configured = true; voices = available; draft = ""
                SpeechPreferences.store.set("elevenlabs", forKey: SpeechPreferences.dictationProviderKey)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func refresh() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            voices = try await ElevenLabsNativeSpeechProvider(tokenProvider: { nil }, deviceKeyProvider: { try DeviceSpeechCredentials.read() }).listVoices()
        } catch { self.error = error.localizedDescription }
    }
}
