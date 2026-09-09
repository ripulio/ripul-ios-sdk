import SwiftUI

/// Native speech sandbox — reached from Settings → Debug. Switches between
/// speech engines through NativeSpeechProviding (the Swift mirror of the web
/// app's provider model): Apple's on-device engine, or ElevenLabs through the
/// same worker routes and single-use-token custody the web provider uses.
/// iOS pushes it in the settings NavigationStack; macOS presents it in a
/// sheet (macOS settings has no stack to push onto).
@available(iOS 26.0, macOS 26.0, *)
public struct SpeechSandboxScreen: View {
    let tokenProvider: () -> String?

    public init(tokenProvider: @escaping () -> String?) { self.tokenProvider = tokenProvider }

    @State private var providers: [any NativeSpeechProviding] = []
    @State private var selectedProviderId = "apple"

    @State private var voices: [SpeechService.Voice] = []
    @State private var selectedVoiceId = ""
    @State private var voicesError: String?
    @State private var ttsText = "The quick brown fox jumps over the lazy dog."
    @State private var errorMessage: String?

    @State private var isTranscribing = false
    @State private var partialTranscript = ""
    @State private var committedSegments: [String] = []

    private var provider: (any NativeSpeechProviding)? {
        providers.first { $0.id == selectedProviderId }
    }

    public var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $selectedProviderId) {
                    ForEach(providers, id: \.id) { p in
                        Text(p.label).tag(p.id)
                    }
                }
                .pickerStyle(.segmented)
                .uiKitIdentifier("SpeechSandboxScreen.providerPicker")
            }

            Section("Voice") {
                if let voicesError {
                    Text(voicesError).foregroundStyle(.red)
                } else {
                    Picker("Voice", selection: $selectedVoiceId) {
                        ForEach(voices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .uiKitIdentifier("SpeechSandboxScreen.voicePicker")
                    LabeledContent("Available", value: "\(voices.count) voices")
                }
            }

            Section("Text to speech") {
                TextField("Text", text: $ttsText, axis: .vertical)
                    .lineLimit(2...5)
                    .uiKitIdentifier("SpeechSandboxScreen.ttsText")
                HStack {
                    Button {
                        speak()
                    } label: {
                        Label("Speak", systemImage: "speaker.wave.2")
                    }
                    .disabled(ttsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .uiKitIdentifier("SpeechSandboxScreen.speakButton")
                    Spacer()
                    Button("Stop") { provider?.stopSpeaking() }
                        .uiKitIdentifier("SpeechSandboxScreen.stopSpeakingButton")
                }
            }

            Section("Live transcription") {
                Button {
                    toggleTranscription()
                } label: {
                    Label(
                        isTranscribing ? "Stop transcribing" : "Start live transcription",
                        systemImage: isTranscribing ? "stop.circle" : "waveform"
                    )
                    .foregroundStyle(isTranscribing ? Color.red : Color.accentColor)
                }
                .uiKitIdentifier("SpeechSandboxScreen.transcribeToggle")

                if isTranscribing || !partialTranscript.isEmpty || !committedSegments.isEmpty {
                    (Text(committedSegments.joined(separator: " "))
                        + Text(committedSegments.isEmpty ? "" : " ")
                        + Text(partialTranscript).foregroundStyle(.secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .uiKitIdentifier("SpeechSandboxScreen.transcript")
                } else {
                    Text("Transcript appears here.")
                        .foregroundStyle(.tertiary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .uiKitIdentifier("SpeechSandboxScreen.error")
                }
            }
        }
        .navigationTitle("Speech Sandbox")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .task {
            providers = [
                AppleSpeechProvider(),
                ElevenLabsNativeSpeechProvider(tokenProvider: tokenProvider),
            ]
            await loadVoices()
        }
        .onChange(of: selectedProviderId) {
            switchProvider()
        }
        .onDisappear {
            provider?.stopTranscription()
            provider?.stopSpeaking()
        }
    }

    private func switchProvider() {
        // The previous provider may still be speaking/transcribing — stop all.
        for p in providers {
            p.stopTranscription()
            p.stopSpeaking()
        }
        isTranscribing = false
        partialTranscript = ""
        committedSegments = []
        errorMessage = nil
        voices = []
        selectedVoiceId = ""
        Task { await loadVoices() }
    }

    private func loadVoices() async {
        voicesError = nil
        guard let provider else { return }
        do {
            let list = try await provider.listVoices()
            voices = list
            selectedVoiceId = list.first?.id ?? ""
        } catch {
            voicesError = error.localizedDescription
        }
    }

    private func speak() {
        errorMessage = nil
        guard let provider else { return }
        Task {
            do {
                try await provider.speak(
                    text: ttsText.trimmingCharacters(in: .whitespacesAndNewlines),
                    voiceId: selectedVoiceId.isEmpty ? nil : selectedVoiceId,
                    onPlaybackEnd: nil
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func toggleTranscription() {
        guard let provider else { return }
        if isTranscribing {
            provider.stopTranscription()
            return
        }
        errorMessage = nil
        partialTranscript = ""
        committedSegments = []
        Task {
            do {
                try await provider.startTranscription { event in
                    switch event {
                    case .partial(let text):
                        partialTranscript = text
                    case .committed(let text):
                        committedSegments.append(text)
                        partialTranscript = ""
                    case .audioLevel:
                        break
                    case .error(let message):
                        errorMessage = message
                    case .ended:
                        isTranscribing = false
                        partialTranscript = ""
                    }
                }
                isTranscribing = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
