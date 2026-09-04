import SwiftUI

/// Native management screen for voice profiles (vp_*) — the org-scoped,
/// shareable speech configuration site keys bind to. Mirrors the web admin
/// section's semantics (list / create / edit / delete over
/// /admin/voice-profiles) with native presentation: List + Form, push
/// navigation, swipe-to-delete.
struct VoiceProfilesScreen: View {
    var baseURL: URL = AgentConfiguration.defaultBaseURL
    let tokenProvider: () -> String?

    @State private var profiles: [VoiceProfileRecord] = []
    @State private var loading = false
    @State private var loadError: String?

    private var client: VoiceProfileAdminClient {
        VoiceProfileAdminClient(baseURL: baseURL, tokenProvider: tokenProvider)
    }

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section {
                if profiles.isEmpty && !loading && loadError == nil {
                    Text("No voice profiles yet. Create one and bind site keys to it — many keys can share one profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    NavigationLink {
                        VoiceProfileEditorScreen(
                            baseURL: baseURL,
                            tokenProvider: tokenProvider,
                            existing: profile,
                            onSaved: { await reload() }
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(profile.name)
                                if profile.allowUserOverride == false {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let description = profile.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .uiKitIdentifier("VoiceProfilesScreen.row.\(profile.id)")
                }
                .onDelete { indexSet in
                    Task { await delete(at: indexSet) }
                }
            } footer: {
                Text("Speech configuration site keys bind to. A locked profile (padlock) overrides user voice settings in its portals.")
            }
        }
        .navigationTitle("Voice Profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    VoiceProfileEditorScreen(
                        baseURL: baseURL,
                        tokenProvider: tokenProvider,
                        existing: nil,
                        onSaved: { await reload() }
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .uiKitIdentifier("VoiceProfilesScreen.create")
            }
        }
        .overlay {
            if loading && profiles.isEmpty {
                ProgressView()
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            profiles = try await client.list()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(at indexSet: IndexSet) async {
        let doomed = indexSet.map { profiles[$0] }
        for profile in doomed {
            do {
                try await client.delete(id: profile.id)
                profiles.removeAll { $0.id == profile.id }
            } catch {
                loadError = "Delete failed: \(error.localizedDescription)"
            }
        }
    }
}

/// Create/edit form for one profile. Mirrors the Voice settings hub's
/// controls (same pickers, same slider ranges) so the vocabulary matches
/// what users see in their own voice settings.
struct VoiceProfileEditorScreen: View {
    var baseURL: URL = AgentConfiguration.defaultBaseURL
    let tokenProvider: () -> String?
    let existing: VoiceProfileRecord?
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var profileDescription = ""
    @State private var sttProviderId = ""
    @State private var voiceId = ""
    @State private var pace = 1.0
    @State private var expressiveness = 0.35
    @State private var language = "en"
    @State private var keyterms = ""
    // Matches SpeechPreferences.voiceModeStyle's fallback. Getting this wrong
    // is worse than a cosmetic mismatch: opening a profile that never set a
    // style and saving it would silently PIN the stale default.
    @State private var voiceModeStyle = "compact"
    @State private var voiceEnabled = true
    @State private var allowUserOverride = true

    private struct VoiceOption: Identifiable, Equatable {
        let id: String
        let name: String
    }

    @State private var voices: [VoiceOption] = []
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        Form {
            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section("Profile") {
                TextField("Name", text: $name)
                    .uiKitIdentifier("VoiceProfileEditor.name")
                TextField("Description (optional)", text: $profileDescription, axis: .vertical)
                    .lineLimit(1...3)
                    .uiKitIdentifier("VoiceProfileEditor.description")
            }

            Section {
                Picker(selection: $sttProviderId) {
                    Text("Not set (user choice)").tag("")
                    Text("Apple (on-device)").tag("apple-native")
                    Text("ElevenLabs").tag("elevenlabs")
                } label: {
                    Label("Dictation provider", systemImage: "mic.badge.plus")
                }
                .uiKitIdentifier("VoiceProfileEditor.sttProvider")
            } header: {
                Text("Recognition")
            }

            Section {
                Picker(selection: $voiceId) {
                    Text("Region default").tag("")
                    ForEach(voices, id: \.id) { voice in
                        Text(voice.name).tag(voice.id)
                    }
                } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }
                .uiKitIdentifier("VoiceProfileEditor.voice")
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label("Pace", systemImage: "hare")
                        Spacer()
                        Text(String(format: "%.2f×", pace))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $pace, in: 0.7...1.2, step: 0.05)
                        .uiKitIdentifier("VoiceProfileEditor.pace")
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label("Expressiveness", systemImage: "theatermasks")
                        Spacer()
                        Text(String(format: "%.0f%%", expressiveness * 100))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $expressiveness, in: 0...1, step: 0.05)
                        .uiKitIdentifier("VoiceProfileEditor.expressiveness")
                }
            } header: {
                Text("Delivery")
            }

            Section {
                Picker(selection: $language) {
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
                .uiKitIdentifier("VoiceProfileEditor.language")
                TextField("Ripul, WKWebView…", text: $keyterms, axis: .vertical)
                    .lineLimit(1...3)
                    .autocorrectionDisabled()
                    .uiKitIdentifier("VoiceProfileEditor.keyterms")
            } header: {
                Text("Language & key terms")
            } footer: {
                Text("Key terms are comma-separated vocabulary the recognizer should prefer. Profiles merge these with the user's own terms.")
            }

            Section {
                Toggle(isOn: $voiceEnabled) {
                    Label("Enable voice features", systemImage: "waveform")
                }
                .uiKitIdentifier("VoiceProfileEditor.voiceEnabled")
                Picker(selection: $voiceModeStyle) {
                    Text("Full screen").tag("fullscreen")
                    Text("Compact panel").tag("compact")
                } label: {
                    Label("Voice mode style", systemImage: "rectangle.bottomthird.inset.filled")
                }
                .uiKitIdentifier("VoiceProfileEditor.voiceModeStyle")
                .disabled(!voiceEnabled)
                Toggle(isOn: $allowUserOverride) {
                    Label("Allow user override", systemImage: "person.badge.shield.checkmark")
                }
                .uiKitIdentifier("VoiceProfileEditor.allowOverride")
            } header: {
                Text("Behavior")
            } footer: {
                Text(voiceEnabled
                     ? "With override off, this profile is authoritative: portals bound to it ignore user voice settings."
                     : "Voice off: portals bound to this profile show no mic, no read-aloud, and no hands-free mode.")
            }
        }
        .navigationTitle(existing == nil ? "New Profile" : existing!.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .uiKitIdentifier("VoiceProfileEditor.save")
            }
        }
        .onAppear { populate() }
        .task { await loadVoices() }
    }

    private func populate() {
        guard let existing else { return }
        name = existing.name
        profileDescription = existing.description ?? ""
        sttProviderId = existing.sttProviderId ?? ""
        voiceId = existing.voiceId ?? ""
        pace = existing.pace ?? 1.0
        expressiveness = existing.expressiveness ?? 0.35
        language = existing.language ?? "en"
        keyterms = (existing.keyterms ?? []).joined(separator: ", ")
        voiceModeStyle = existing.voiceModeStyle ?? "compact"
        voiceEnabled = existing.voiceEnabled ?? true
        allowUserOverride = existing.allowUserOverride ?? true
    }

    private func loadVoices() async {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let provider = ElevenLabsNativeSpeechProvider(tokenProvider: tokenProvider)
        let catalog = (try? await provider.listVoices()) ?? []
        voices = catalog
            .map { VoiceOption(id: $0.id, name: $0.name) }
            .sorted { $0.name < $1.name }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let terms = keyterms
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let input = VoiceProfileInput(
            name: name.trimmingCharacters(in: .whitespaces),
            description: profileDescription.isEmpty ? nil : profileDescription,
            ttsProviderId: nil,
            voiceId: voiceId.isEmpty ? nil : voiceId,
            pace: pace,
            expressiveness: expressiveness,
            sttProviderId: sttProviderId.isEmpty ? nil : sttProviderId,
            language: language,
            keyterms: terms.isEmpty ? nil : terms,
            voiceEnabled: voiceEnabled,
            voiceModeStyle: voiceModeStyle,
            allowUserOverride: allowUserOverride
        )
        let client = VoiceProfileAdminClient(baseURL: baseURL, tokenProvider: tokenProvider)
        do {
            if let existing {
                _ = try await client.update(id: existing.id, input)
            } else {
                _ = try await client.create(input)
            }
            await onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
