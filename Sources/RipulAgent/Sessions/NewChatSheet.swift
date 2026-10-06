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
    /// Browses the selected Mac's folders; `nil` leaves the recents only.
    let bridge: AgentBridge?
    let allowsRelay: Bool
    let preferredRelayID: String?
    let modelsLoading: Bool
    let modelsError: String?
    let onRetryModels: (() -> Void)?
    let onManageAccess: () -> Void
    let onDismiss: () -> Void
    /// Set when the sheet was opened from a machine row: the Mac is already
    /// chosen, so the transport and Mac pickers are hidden, not repeated.
    let lockedMachineID: String?
    let onLaunch: (NewChatLaunch) async throws -> Void
    @State private var draft: NewChatDraft
    @State private var search = ""
    @State private var loadingID: String?
    @State private var error: String?
    @State private var previousLaunch: NewChatLaunch?
    @State private var usingCustomFolder = false
    @State private var recents: NewChatRecentFolders
    @State private var browsing = false
    @State private var title = ""

    public init(machines: [NewChatMachine], relayModels: [ModelInfo], directModels: [ModelInfo],
                cache: RipulSessionCache, bridge: AgentBridge? = nil, allowsRelay: Bool = true, requestedRelayID: String? = nil,
                preferredRelayID: String? = nil, preferredDirectID: String? = nil,
                directCatalogs: [String: NewChatModelCatalog]? = nil,
                loadDirectModels: ((String) async -> Void)? = nil,
                modelsLoading: Bool = false, modelsError: String? = nil,
                onRetryModels: (() -> Void)? = nil, onManageAccess: @escaping () -> Void,
                onDismiss: @escaping () -> Void, onLaunch: @escaping (NewChatLaunch) async throws -> Void) {
        self.machines = machines; self.relayModels = relayModels; self.directModels = directModels
        self.directCatalogs = directCatalogs; self.loadDirectModels = loadDirectModels
        self.cache = cache; self.bridge = bridge; self.allowsRelay = allowsRelay; self.preferredRelayID = preferredRelayID
        self.modelsLoading = modelsLoading; self.modelsError = modelsError; self.onRetryModels = onRetryModels
        self.lockedMachineID = allowsRelay ? machines.first(where: { $0.connection == .relay && $0.id == requestedRelayID })?.id : nil
        self.onManageAccess = onManageAccess; self.onDismiss = onDismiss; self.onLaunch = onLaunch
        var initial = NewChatDraft(data: cache.object(forKey: Self.preferencesKey) as? Data,
                                   forcedConnection: allowsRelay ? nil : .direct)
        if let preferredDirectID {
            initial.select(machines.first(where: { $0.connection == .direct && $0.id == preferredDirectID })
                ?? NewChatMachine(id: preferredDirectID, name: "The selected Mac", connection: .direct))
        }
        if let requestedRelayID, allowsRelay { initial.selectRequested(relayID: requestedRelayID, from: machines) }
        initial.selectInitial(from: machines, preferredRelayID: preferredRelayID)
        _draft = State(initialValue: initial)
        _recents = State(initialValue: NewChatRecentFolders(data: cache.object(forKey: NewChatRecentFolders.preferencesKey) as? Data))
    }
    private var lockedMachine: NewChatMachine? { machines.first(where: { $0.connection == .relay && $0.id == lockedMachineID }) }
    private var destination: NewChatMachine? { machines.first(where: { $0.connection == draft.connection && $0.id == draft.machineID }) }
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
    private var validationError: String? { launchDraft.validationError(in: machines) }
    private var recentFolders: [String] {
        guard let id = draft.machineID else { return [] }
        return recents.folders(connection: draft.connection, machineID: id)
    }
    /// A folder just browsed to leads until a chat starts in it and it joins
    /// the recents.
    private var folderRows: [String] {
        let picked = draft.folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usingCustomFolder, !picked.isEmpty, !recentFolders.contains(picked) else { return recentFolders }
        return [picked] + recentFolders
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title (optional)", text: $title)
                        .submitLabel(.done)
                        .accessibilityIdentifier("NewChat.title")
                } footer: {
                    Text("Leave it blank to name the chat from its first message.")
                }
                .disabled(loadingID != nil)
                if lockedMachine == nil {
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
                    }
                    .disabled(loadingID != nil)
                }
                Section {
                    folderRow(nil)
                    ForEach(folderRows, id: \.self) { folderRow($0) }
                    if bridge != nil, let machine = candidates.first(where: { $0.id == draft.machineID }), machine.unavailableReason == nil {
                        Button { browsing = true } label: { Label("Browse…", systemImage: "folder.badge.plus") }
                            .accessibilityIdentifier("NewChat.browseFolder")
                    }
                } header: {
                    Text("Folder")
                } footer: {
                    if let machine = candidates.first(where: { $0.id == draft.machineID }), let team = machine.teamName {
                        Text("Shared with \(team). Chats use this Mac's coding account and stay private to you until you share one with the team. Colleagues work in the same folders, so choose a separate working copy for independent edits. Mac-local history is available through Direct pairing.")
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
            .dismissesKeyboardOnTapAway()
            .searchable(text: $search, prompt: "Search models")
            .navigationTitle("New Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss).disabled(loadingID != nil).accessibilityIdentifier("NewChat.cancel")
                }
                ToolbarItem(placement: .principal) { destinationTitle }
            }
            .sheet(isPresented: $browsing) {
                if let bridge, let machineID = draft.machineID {
                    RemoteFolderBrowseSheet(bridge: bridge, machineId: machineID, actionTitle: "Use This Folder",
                                            identifierPrefix: "NewChat.browse") { choose($0) }
                }
            }
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
        .onChange(of: usingCustomFolder) { _, _ in error = nil }
        .onAppear(perform: persist)
        .task(id: directDestination) {
            if let id = directDestination { await loadDirectModels?(id) }
        }
    }
    private func persist() { if let data = draft.data { cache.set(data, forKey: Self.preferencesKey) } }
    /// The Mac the chat will be created on, as its icon and name, so the
    /// destination is never in doubt while choosing a model.
    private var destinationTitle: some View {
        HStack(spacing: 8) {
            Image(systemName: destination?.icon ?? "desktopcomputer")
                .font(.title3.weight(.semibold))
                .foregroundStyle(destination == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 0) {
                Text("New Chat").font(.headline)
                Text(destination?.name ?? draft.machineName ?? "Choose a Mac")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("NewChat.destination")
    }
    /// `nil` is the Mac's configured working directory.
    private func choose(_ folder: String?) {
        if let folder { draft.folder = folder }
        usingCustomFolder = folder != nil
    }
    private func folderRow(_ folder: String?) -> some View {
        let selected = folder.map { usingCustomFolder && draft.folder == $0 } ?? !usingCustomFolder
        return Button { choose(folder) } label: {
            HStack(spacing: 12) {
                Image(systemName: folder == nil ? "house" : "folder")
                    .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
                if let folder {
                    DirectoryPathLabel(path: folder)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("The Mac's working directory").font(.caption).foregroundStyle(.secondary)
                        Text("Default").font(.headline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Keyed by the full path: two repos can share a last path component.
        .accessibilityIdentifier(folder.map { "NewChat.folderRow.\($0)" } ?? "NewChat.folderDefault")
    }
    private func remember(_ launch: NewChatLaunch) {
        guard !launch.folder.isEmpty else { return }
        recents.record(launch.folder, connection: launch.connection, machineID: launch.machineID)
        if let data = recents.data { cache.set(data, forKey: NewChatRecentFolders.preferencesKey) }
    }
    private func pick(_ model: ModelInfo?) {
        guard loadingID == nil, validationError == nil, let model, models.contains(where: { $0.id == model.id && $0.enabled }) else { return }
        error = nil; loadingID = model.id
        var request = NewChatLaunch(draft: launchDraft, modelID: model.id, previous: previousLaunch)
        request.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        previousLaunch = request; persist()
        Task { @MainActor in
            defer { loadingID = nil }
            do { try await onLaunch(request); remember(request); onDismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
