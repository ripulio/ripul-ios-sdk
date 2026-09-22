import SwiftUI

@available(iOS 26.0, macOS 26.0, *)
public struct NewChatModelCatalog {
    public var models: [ModelInfo]
    public var isLoading: Bool
    public var error: String?
    public init(models: [ModelInfo] = [], isLoading: Bool = false, error: String? = nil) {
        self.models = models; self.isLoading = isLoading; self.error = error
    }
}

/// One creation sheet for every first-party entry point. The host supplies the
/// available destinations and transport; model rows reuse the ordinary picker.
@available(iOS 26.0, macOS 26.0, *)
public struct NewChatSheet: View {
    public static let preferencesKey = "ripul.newChat.preferences"
    let machines: [NewChatMachine]
    let relayModels: [ModelInfo]
    let directModels: [ModelInfo]
    let directCatalogs: [String: NewChatModelCatalog]?
    let loadDirectModels: ((String) async -> Void)?
    let cache: RipulSessionCache
    let allowsRelay: Bool
    let preferredRelayID: String?
    let modelsLoading: Bool
    let modelsError: String?
    let onRetryModels: (() -> Void)?
    let onManageAccess: () -> Void
    let onDismiss: () -> Void
    let onManageCodexAccounts: ((NewChatMachine) -> Void)?
    let onLaunch: (NewChatLaunch) async throws -> Void
    @State private var draft: NewChatDraft
    @State private var search = ""
    @State private var loadingID: String?
    @State private var error: String?
    @State private var previousLaunch: NewChatLaunch?
    @State private var usingCustomFolder = false
    @FocusState private var editingFolder: Bool

    public init(machines: [NewChatMachine], relayModels: [ModelInfo], directModels: [ModelInfo],
                cache: RipulSessionCache, allowsRelay: Bool = true, preferredRelayID: String? = nil, preferredDirectID: String? = nil,
                directCatalogs: [String: NewChatModelCatalog]? = nil,
                loadDirectModels: ((String) async -> Void)? = nil,
                modelsLoading: Bool = false, modelsError: String? = nil,
                onRetryModels: (() -> Void)? = nil, onManageAccess: @escaping () -> Void,
                onDismiss: @escaping () -> Void, onManageCodexAccounts: ((NewChatMachine) -> Void)? = nil, onLaunch: @escaping (NewChatLaunch) async throws -> Void) {
        self.machines = machines; self.relayModels = relayModels; self.directModels = directModels
        self.directCatalogs = directCatalogs; self.loadDirectModels = loadDirectModels
        self.cache = cache; self.allowsRelay = allowsRelay; self.preferredRelayID = preferredRelayID
        self.modelsLoading = modelsLoading; self.modelsError = modelsError; self.onRetryModels = onRetryModels
        self.onManageCodexAccounts = onManageCodexAccounts
        self.onManageAccess = onManageAccess; self.onDismiss = onDismiss; self.onLaunch = onLaunch
        var initial = NewChatDraft(data: cache.object(forKey: Self.preferencesKey) as? Data,
                                   forcedConnection: allowsRelay ? nil : .direct)
        if let preferredDirectID {
            initial.select(machines.first(where: { $0.connection == .direct && $0.id == preferredDirectID })
                ?? NewChatMachine(id: preferredDirectID, name: "The selected Mac", connection: .direct))
        }
        initial.selectInitial(from: machines, preferredRelayID: preferredRelayID)
        _draft = State(initialValue: initial)
    }
    private var candidates: [NewChatMachine] { machines.filter { $0.connection == draft.connection } }
    private var directDestination: String? { draft.connection == .direct ? draft.machineID : nil }
    private var directCatalog: NewChatModelCatalog {
        guard let directCatalogs else { return NewChatModelCatalog(models: directModels) }
        guard let id = directDestination else { return NewChatModelCatalog() }
        return directCatalogs[id] ?? NewChatModelCatalog(isLoading: true)
    }
    private var models: [ModelInfo] { draft.connection == .direct ? directCatalog.models : relayModels }
    private var pinCatalog: [ModelInfo] {
        var seen = Set<String>()
        return (relayModels + directModels + (directCatalogs?.values.flatMap(\.models) ?? []))
            .filter { seen.insert($0.id).inserted }
    }
    private var launchDraft: NewChatDraft { draft.forLaunch(usingCustomFolder: usingCustomFolder) }
    private var validationError: String? {
        if let error = launchDraft.validationError(in: machines) { return error }
        if usingCustomFolder && draft.folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a project folder, or turn off Use another folder."
        }
        return nil
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Connection", selection: $draft.connection) {
                        Text("Relay").tag(NewChatConnection.relay).disabled(!allowsRelay)
                        Text("Direct").tag(NewChatConnection.direct)
                    }
                    .pickerStyle(.segmented).disabled(!allowsRelay).accessibilityIdentifier("NewChat.connection")
                    Picker("Mac", selection: Binding(get: { draft.machineID ?? "" }, set: { id in
                        if let machine = candidates.first(where: { $0.id == id }) { draft.select(machine) }
                    })) {
                        if draft.machineID == nil { Text("Choose a Mac").tag("") }
                        if let id = draft.machineID, !candidates.contains(where: { $0.id == id }) {
                            Text("\(draft.machineName ?? "Selected Mac") · unavailable").tag(id)
                        }
                        ForEach(candidates) { machine in
                            Text(machine.name + (machine.unavailableReason == nil ? "" : " · unavailable")).tag(machine.id)
                        }
                    }.accessibilityIdentifier("NewChat.machine")
                    if let onManageCodexAccounts, let machine = candidates.first(where: { $0.id == draft.machineID }), machine.canManageAccounts {
                        Button { onManageCodexAccounts(machine) } label: { Label("Codex accounts", systemImage: "person.2") }
                            .disabled(machine.unavailableReason != nil).accessibilityIdentifier("NewChat.codexAccounts")
                    }
                    Toggle("Use another folder", isOn: $usingCustomFolder)
                        .accessibilityIdentifier("NewChat.folderOverride")
                    if usingCustomFolder {
                        TextField("Project folder on this Mac", text: $draft.folder)
                            .autocorrectionDisabled().focused($editingFolder)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .accessibilityIdentifier("NewChat.folder")
                    }
                } footer: {
                    if let machine = candidates.first(where: { $0.id == draft.machineID }), let team = machine.teamName {
                        Text("Shared with \(team). Chats use this Mac's coding account and are visible to the team. Choose a separate working copy for independent edits. Mac-local history is available through Direct pairing.")
                    }
                    Text(usingCustomFolder
                         ? (draft.connection == .direct ? "Work uses your chosen folder. History stays on the Mac." : "Work uses your chosen folder. History stays in Ripul cloud.")
                         : (draft.connection == .direct
                            ? "Work uses the selected Mac's configured working directory. History stays on the Mac."
                            : "History stays in Ripul cloud. Coding chats use the selected Mac's configured working directory."))
                }
                .disabled(loadingID != nil)
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("NewChat.error") } }
                if let validationError { Section { Text(validationError).foregroundStyle(.secondary) } }
                if draft.connection == .direct {
                    Section { Button("Pair or manage Macs", action: onManageAccess).accessibilityIdentifier("NewChat.manageAccess") }
                        .disabled(loadingID != nil)
                }
                ModelPickerSections(models: models, pinCatalog: pinCatalog,
                    cache: cache, searchText: search, identifierPrefix: "NewChat.models",
                    isLoading: draft.connection == .relay ? modelsLoading : directCatalog.isLoading,
                    loadFailure: draft.connection == .relay ? modelsError : directCatalog.error,
                    loadingId: $loadingID, onRetry: {
                        if let id = directDestination { Task { await loadDirectModels?(id) } }
                        else { onRetryModels?() }
                    }, onPick: pick)
                    .disabled(validationError != nil || loadingID != nil)
            }
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $search, prompt: "Search models")
            .navigationTitle("New Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onDismiss).disabled(loadingID != nil).accessibilityIdentifier("NewChat.cancel")
            } }
        }
        .interactiveDismissDisabled(loadingID != nil)
        // This is a form plus a searchable model list — the widest, tallest
        // content we present modally. Declared here rather than at each call
        // site so every consumer of the shared creation sheet gets it.
        .ripulSheet(.page)
        .onChange(of: draft) { _, _ in
            if !allowsRelay { draft.connection = .direct }
            draft.selectInitial(from: machines, preferredRelayID: preferredRelayID)
            persist(); error = nil
        }
        .onChange(of: machines) { _, _ in draft.selectInitial(from: machines, preferredRelayID: preferredRelayID); persist() }
        .onChange(of: draft.machineID) { _, _ in usingCustomFolder = false }
        .onChange(of: draft.connection) { _, _ in usingCustomFolder = false }
        .onChange(of: usingCustomFolder) { _, enabled in
            error = nil
            if !enabled { editingFolder = false }
        }
        .onAppear(perform: persist)
        .task(id: directDestination) {
            if let id = directDestination { await loadDirectModels?(id) }
        }
    }
    private func persist() { if let data = draft.data { cache.set(data, forKey: Self.preferencesKey) } }
    private func pick(_ model: ModelInfo?) {
        guard loadingID == nil, validationError == nil, let model, models.contains(where: { $0.id == model.id && $0.enabled }) else { return }
        editingFolder = false; error = nil; loadingID = model.id
        let request = NewChatLaunch(draft: launchDraft, modelID: model.id, previous: previousLaunch)
        previousLaunch = request; persist()
        Task { @MainActor in
            defer { loadingID = nil }
            do { try await onLaunch(request); onDismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
