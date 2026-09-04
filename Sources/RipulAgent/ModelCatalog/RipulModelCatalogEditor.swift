#if os(iOS)
import SwiftUI

// ---------------------------------------------------------------------------
// Catalog entry editor — the native Form equivalent of the web ModelEditDialog
// (Basic Info / API Configuration / Pricing), plus the CLI fields the web
// dialog never grew. Create and duplicate share the same sheet: duplicate is
// just create seeded from an existing row.
// ---------------------------------------------------------------------------

@available(iOS 16.0, *)
struct RipulModelCatalogEditorSheet: View {
    let client: RipulModelCatalogClient
    /// Prefill source: the row being edited, or a copy seed when duplicating.
    let seed: RipulCatalogModel?
    /// True for create/duplicate (POST, id editable), false for edit (PATCH).
    let isNew: Bool
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    private static let providers = ["anthropic", "openai", "openrouter", "backend"]
    private static let apiFormats = ["openai", "anthropic", "openrouter"]
    private static let efforts = ["", "low", "medium", "high", "xhigh", "max"]

    @State private var name = ""
    @State private var catalogId = ""
    @State private var group = ""
    @State private var descriptionText = ""
    @State private var provider = "anthropic"
    @State private var apiFormat = "anthropic"
    @State private var gatewayProvider = ""
    @State private var apiModelId = ""
    @State private var urlText = ""
    @State private var secretName = ""
    @State private var maxInputText = ""
    @State private var maxOutputText = ""
    @State private var supportsThinking = false
    @State private var useNativeEndpoint = false
    @State private var perMInputText = ""
    @State private var perMOutputText = ""
    @State private var tier = "standard"
    @State private var sortOrderText = ""
    @State private var enabled = true
    @State private var clientType = ""
    @State private var cliModelId = ""
    @State private var cliRawMode = false
    @State private var cliEffort = ""
    @State private var cliMode = "session"
    @State private var supportsTools = false
    @State private var idEdited = false
    /// onChange(of: catalogId) can't tell the user's typing from suggestId()'s
    /// writes — it fires after the write, so a plain reset gets clobbered. The
    /// flag marks the next change as programmatic.
    @State private var suppressIdLatch = false

    @State private var saving = false
    @State private var errorMessage: String?

    private var isCli: Bool {
        clientType.hasSuffix("-cli") || !cliModelId.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedId: String { catalogId.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool {
        guard !trimmedName.isEmpty, !trimmedId.isEmpty else { return false }
        // Mirrors the server's validateModelRequest: proxy models need a wire
        // target; CLI models run client-side and don't.
        if !isCli {
            guard !apiModelId.trimmingCharacters(in: .whitespaces).isEmpty,
                  !urlText.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    TextField("Display name", text: $name)
                    TextField("Group", text: $group)
                    TextField("Description", text: $descriptionText, axis: .vertical)
                }
                Section("Type") {
                    Picker("Provider", selection: $provider) {
                        ForEach(Self.providers, id: \.self) { Text($0.capitalized).tag($0) }
                        if !Self.providers.contains(provider) {
                            Text(provider).tag(provider)
                        }
                    }
                    if provider == "backend" {
                        Picker("API format", selection: $apiFormat) {
                            ForEach(Self.apiFormats, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        TextField("Gateway provider (e.g. google-ai-studio)", text: $gatewayProvider)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    TextField("Client type (CLI models, e.g. claude-cli)", text: $clientType)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if isCli {
                    Section("CLI") {
                        TextField("Model alias (passed via --model)", text: $cliModelId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Toggle("Raw mode", isOn: $cliRawMode)
                        Picker("Effort", selection: $cliEffort) {
                            ForEach(Self.efforts, id: \.self) {
                                Text($0.isEmpty ? "Default" : $0.capitalized).tag($0)
                            }
                        }
                        Picker("History mode", selection: $cliMode) {
                            Text("Session").tag("session")
                            Text("Stateless").tag("stateless")
                        }
                        Toggle("Supports tools", isOn: $supportsTools)
                    }
                } else {
                    Section("API") {
                        TextField("Model ID sent to the API", text: $apiModelId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Endpoint URL", text: $urlText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        TextField("Secret name", text: $secretName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Max input tokens", text: $maxInputText)
                            .keyboardType(.numberPad)
                        TextField("Max output tokens", text: $maxOutputText)
                            .keyboardType(.numberPad)
                        Toggle("Supports extended thinking", isOn: $supportsThinking)
                        Toggle("Use native endpoint (site keys)", isOn: $useNativeEndpoint)
                    }
                }
                Section("Pricing") {
                    TextField("$ per M input tokens", text: $perMInputText)
                        .keyboardType(.decimalPad)
                    TextField("$ per M output tokens", text: $perMOutputText)
                        .keyboardType(.decimalPad)
                    Picker("Tier", selection: $tier) {
                        Text("Standard").tag("standard")
                        Text("Premium").tag("premium")
                    }
                }
                Section("Availability") {
                    Toggle("Enabled", isOn: $enabled)
                    TextField("Sort order", text: $sortOrderText)
                        .keyboardType(.numberPad)
                }
                Section {
                    TextField("id", text: $catalogId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(!isNew)
                        .foregroundStyle(isNew ? Color.primary : Color.secondary)
                        .onChange(of: catalogId) { _ in
                            if suppressIdLatch {
                                suppressIdLatch = false
                            } else {
                                idEdited = true
                            }
                        }
                } header: {
                    Text("Catalog ID")
                } footer: {
                    Text(isNew
                        ? "Auto-suggested from the name; edit if you like."
                        : "The catalog id can't be changed.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .navigationTitle(isNew ? "New Model" : "Edit Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save).disabled(!canSave)
                    }
                }
            }
            .onAppear(perform: seedFields)
            .onChange(of: name) { _ in suggestId() }
        }
    }

    private func seedFields() {
        guard let m = seed else { return }
        name = m.name
        catalogId = m.id
        group = m.group ?? ""
        descriptionText = m.description ?? ""
        provider = m.provider
        apiFormat = m.apiFormat ?? "anthropic"
        gatewayProvider = m.gatewayProvider ?? ""
        apiModelId = m.modelId
        urlText = m.url
        secretName = m.secretName ?? ""
        maxInputText = m.maxInputTokens.map(String.init) ?? ""
        maxOutputText = m.maxOutputTokens.map(String.init) ?? ""
        supportsThinking = m.supportsThinking ?? false
        useNativeEndpoint = m.useNativeEndpoint ?? false
        perMInputText = m.perMInput == 0 ? "" : String(format: "%g", m.perMInput)
        perMOutputText = m.perMOutput == 0 ? "" : String(format: "%g", m.perMOutput)
        tier = m.tier
        sortOrderText = String(m.sortOrder)
        enabled = m.enabled
        clientType = m.clientType ?? ""
        cliModelId = m.cliModelId ?? ""
        cliRawMode = m.cliRawMode ?? false
        cliEffort = m.cliEffort ?? ""
        cliMode = m.cliMode ?? "session"
        supportsTools = m.supportsTools ?? false
        idEdited = true
    }

    /// While creating from scratch, keep the suggested id in sync with the name.
    private func suggestId() {
        guard isNew, !idEdited else { return }
        let slug = trimmedName.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, ch in
                if ch == "-" && out.hasSuffix("-") { return }
                out.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard slug != catalogId else { return }
        suppressIdLatch = true
        catalogId = slug
    }

    private func save() {
        errorMessage = nil
        saving = true
        let body = buildBody()
        let id = trimmedId
        Task {
            do {
                if isNew {
                    try await client.create(body)
                } else {
                    try await client.update(id: id, body)
                }
                saving = false
                onSaved()
                dismiss()
            } catch {
                saving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func buildBody() -> RipulModelUpsert {
        let cli = isCli
        return RipulModelUpsert(
            id: trimmedId,
            name: trimmedName,
            provider: provider,
            apiFormat: provider == "backend" ? apiFormat : nil,
            gatewayProvider: optional(gatewayProvider),
            modelId: cli ? "" : apiModelId.trimmingCharacters(in: .whitespaces),
            url: cli ? "" : urlText.trimmingCharacters(in: .whitespaces),
            secretName: cli ? nil : optional(secretName),
            perMInput: Double(perMInputText.trimmingCharacters(in: .whitespaces)) ?? 0,
            perMOutput: Double(perMOutputText.trimmingCharacters(in: .whitespaces)) ?? 0,
            maxInputTokens: Int(maxInputText.trimmingCharacters(in: .whitespaces)),
            maxOutputTokens: Int(maxOutputText.trimmingCharacters(in: .whitespaces)),
            description: optional(descriptionText),
            enabled: enabled,
            sortOrder: Int(sortOrderText.trimmingCharacters(in: .whitespaces)),
            tier: tier,
            group: optional(group),
            supportsThinking: supportsThinking,
            useNativeEndpoint: useNativeEndpoint,
            clientType: optional(clientType),
            supportsTools: cli ? supportsTools : nil,
            cliMode: cli ? cliMode : nil,
            cliRawMode: cli ? cliRawMode : nil,
            cliModelId: cli ? optional(cliModelId) : nil,
            cliEffort: cli ? optional(cliEffort) : nil
        )
    }

    private func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
