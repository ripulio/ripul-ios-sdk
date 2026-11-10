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
    public static let allowsDirectSwitchingKey = "ripul.newChat.allowsDirectSwitching"
    let machines: [NewChatMachine]
    let relayModels: [ModelInfo]
    let directModels: [ModelInfo]
    let directCatalogs: [String: NewChatModelCatalog]?
    let loadDirectModels: ((String) async -> Void)?
    let cache: RipulSessionCache
    /// Browses the selected Mac's folders; `nil` leaves the recents only.
    let bridge: AgentBridge?
    let allowsRelay: Bool
    let allowsDirectSwitching: Bool
    let preferredRelayID: String?
    let preferredDirectID: String?
    let modelsLoading: Bool
    let modelsError: String?
    let onRetryModels: (() -> Void)?
    let onManageAccess: () -> Void
    let onDismiss: () -> Void
    /// Set when the sheet was opened from a machine row: the Mac is already
    /// chosen, so the transport and Mac pickers are hidden, not repeated.
    let lockedMachineID: String?
    let onLaunch: (NewChatLaunch) async throws -> Void
    /// Starts a room with this name (docs/plans/rooms.md): a chat with no
    /// model, where people talk and ask agents by name. `nil` offers none.
    let onStartRoom: ((String) async throws -> Void)?
    @State private var draft: NewChatDraft
    @State private var search = ""
    @State private var loadingID: String?
    @State private var error: String?
    @State private var previousLaunch: NewChatLaunch?
    @State private var usingCustomFolder = false
    @State private var recents: NewChatRecentFolders
    @State private var browsing = false
    @State private var title = ""
    /// Whether a Claude chat on the chosen Mac could reply (NewChatClaudeCheck), read when a Mac is chosen.
    @State private var claudeCheck: NewChatClaudeCheck?
    @Environment(\.openURL) private var openURL

    public init(machines: [NewChatMachine], relayModels: [ModelInfo], directModels: [ModelInfo],
                cache: RipulSessionCache, bridge: AgentBridge? = nil, allowsRelay: Bool = true,
                allowsDirectSwitching: Bool? = nil, requestedRelayID: String? = nil,
                preferredRelayID: String? = nil, preferredDirectID: String? = nil,
                directCatalogs: [String: NewChatModelCatalog]? = nil,
                loadDirectModels: ((String) async -> Void)? = nil,
                modelsLoading: Bool = false, modelsError: String? = nil,
                onRetryModels: (() -> Void)? = nil, onManageAccess: @escaping () -> Void,
                onDismiss: @escaping () -> Void, onLaunch: @escaping (NewChatLaunch) async throws -> Void,
                onStartRoom: ((String) async throws -> Void)? = nil) {
        self.onStartRoom = onStartRoom
        self.machines = machines; self.relayModels = relayModels; self.directModels = directModels
        self.directCatalogs = directCatalogs; self.loadDirectModels = loadDirectModels
        self.cache = cache; self.bridge = bridge; self.allowsRelay = allowsRelay
        let directSwitching = allowsDirectSwitching ?? (cache.object(forKey: Self.allowsDirectSwitchingKey) as? Bool ?? false)
        self.allowsDirectSwitching = directSwitching
        self.preferredRelayID = preferredRelayID; self.preferredDirectID = preferredDirectID
        self.modelsLoading = modelsLoading; self.modelsError = modelsError; self.onRetryModels = onRetryModels
        self.lockedMachineID = allowsRelay ? machines.first(where: { $0.connection == .relay && $0.id == requestedRelayID })?.id : nil
        self.onManageAccess = onManageAccess; self.onDismiss = onDismiss; self.onLaunch = onLaunch
        let forced = NewChatDraft.resolvedConnection(
            for: machines,
            allowsRelay: allowsRelay,
            allowsDirectSwitching: directSwitching,
            preferredDirectID: preferredDirectID
        )
        var initial = NewChatDraft(data: cache.object(forKey: Self.preferencesKey) as? Data,
                                   forcedConnection: forced)
        if let preferredDirectID {
            initial.select(machines.first(where: { $0.connection == .direct && $0.id == preferredDirectID })
                ?? NewChatMachine(id: preferredDirectID, name: "The selected Mac", connection: .direct))
        }
        if let requestedRelayID, allowsRelay { initial.selectRequested(relayID: requestedRelayID, from: machines) }
        initial.selectInitial(from: machines, preferredRelayID: preferredRelayID)
        _draft = State(initialValue: initial)
        _recents = State(initialValue: NewChatRecentFolders(data: cache.object(forKey: NewChatRecentFolders.preferencesKey) as? Data))
    }
    private var showsConnectionToggle: Bool { allowsRelay && allowsDirectSwitching }
    private var lockedMachine: NewChatMachine? { machines.first(where: { $0.connection == .relay && $0.id == lockedMachineID }) }
    private var destination: NewChatMachine? { candidates.first(where: { $0.id == draft.machineID }) }
    /// Automatic leads the Relay Macs when the account has two or more of its own.
    private var offersAutomatic: Bool { allowsRelay && draft.connection == .relay && NewChatMachine.offersAutomatic(machines) }
    private var candidates: [NewChatMachine] {
        (offersAutomatic ? [NewChatMachine.automatic] : []) + machines.filter { $0.connection == draft.connection }
    }
    /// The Mac the chat goes to, when one is chosen: not Automatic, which chooses at launch.
    private var chosenMac: NewChatMachine? { destination.flatMap { $0.isAutomatic ? nil : $0 } }
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
    /// The Mac whose Claude accounts are read: one chosen over the relay, when Claude models are offered.
    private var claudeCheckTarget: String? {
        guard bridge != nil, draft.connection == .relay, let mac = chosenMac, mac.unavailableReason == nil,
              models.contains(where: { $0.type == "claude-cli" }) else { return nil }
        return mac.id
    }
    private var recentFolders: [String] {
        guard let id = draft.machineID else { return [] }
        guard draft.isAutomatic else { return recents.folders(connection: draft.connection, machineID: id) }
        // Automatic: the folders used on any of the account's Macs, newest per Mac first.
        var seen = Set<String>()
        let ids = [id] + NewChatMachine.automaticCandidates(machines).map(\.id)
        return Array(ids.flatMap { recents.folders(connection: .relay, machineID: $0) }
            .filter { seen.insert($0).inserted }.prefix(NewChatRecentFolders.limit))
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
                } footer: { RipulSectionFooter {
                    Text("Leave it blank to name the chat from its first message.")
                } }.ripulThemedListRows()
                .disabled(loadingID != nil)
                if onStartRoom != nil { roomSection }
                if lockedMachine == nil {
                    Section {
                        if showsConnectionToggle {
                            Picker("Connection", selection: $draft.connection) {
                                Text("Relay").tag(NewChatConnection.relay).disabled(!allowsRelay)
                                Text("Direct").tag(NewChatConnection.direct)
                            }
                            .pickerStyle(.segmented).disabled(!allowsRelay).accessibilityIdentifier("NewChat.connection")
                        }
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
                    }.ripulThemedListRows()
                    .disabled(loadingID != nil)
                }
                if let check = claudeCheck, let mac = chosenMac, let message = check.message(mac: mac.name) {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.ripul(.warning)) // theme-mapping: a new warning row, no literal replaced
                            .accessibilityIdentifier("NewChat.claudeCheck")
                        if check.blocksStart {
                            Button("Sign In…") { signIn(on: mac, check) }
                                .accessibilityIdentifier("NewChat.claudeSignIn")
                        }
                    }.ripulThemedListRows()
                }
                Section {
                    folderRow(nil)
                    ForEach(folderRows, id: \.self) { folderRow($0) }
                    if bridge != nil, let machine = chosenMac, machine.unavailableReason == nil {
                        Button { browsing = true } label: { Label("Browse…", systemImage: "folder.badge.plus") }
                            .accessibilityIdentifier("NewChat.browseFolder")
                    }
                } header: { RipulSectionHeader {
                    Text("Folder")
                } } footer: { RipulSectionFooter {
                    if draft.isAutomatic {
                        Text("Automatic starts the chat on whichever of your Macs has the most room and this folder's repository, so its builds and tests run there too.")
                    }
                    if let machine = chosenMac, let team = machine.teamName {
                        Text("Shared with \(team). Chats use this Mac's coding account and stay private to you until you share one with the team. Colleagues work in the same folders, so choose a separate working copy for independent edits. Mac-local history is available through Direct pairing.")
                    }
                    Text(usingCustomFolder
                         ? (draft.connection == .direct ? "Work uses your chosen folder. History stays on the Mac." : "Work uses your chosen folder. History stays in Ripul cloud.")
                         : (draft.connection == .direct
                            ? "Work uses the selected Mac's configured working directory. History stays on the Mac."
                            : "History stays in Ripul cloud. Coding chats use the selected Mac's configured working directory."))
                } }.ripulThemedListRows()
                .disabled(loadingID != nil)
                if let error { Section { Text(error).foregroundStyle(.ripul(.danger)).textSelection(.enabled).accessibilityIdentifier("NewChat.error") }.ripulThemedListRows() }
                if let validationError { Section { Text(validationError).foregroundStyle(.ripul(.textSecondary)) }.ripulThemedListRows() }
                if draft.connection == .direct {
                    Section { Button("Pair or manage Macs", action: onManageAccess).accessibilityIdentifier("NewChat.manageAccess") }.ripulThemedListRows()
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
            }.ripulThemedList()
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
            .ripulSheet(isPresented: $browsing) {
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
            if let forced = NewChatDraft.resolvedConnection(for: machines, allowsRelay: allowsRelay, allowsDirectSwitching: allowsDirectSwitching, preferredDirectID: preferredDirectID) {
                draft.connection = forced
            }
            draft.selectInitial(from: machines, preferredRelayID: preferredRelayID)
            persist(); error = nil
        }
        .onChange(of: machines) { _, _ in
            if let forced = NewChatDraft.resolvedConnection(for: machines, allowsRelay: allowsRelay, allowsDirectSwitching: allowsDirectSwitching, preferredDirectID: preferredDirectID) {
                draft.connection = forced
            }
            draft.selectInitial(from: machines, preferredRelayID: preferredRelayID); persist()
        }
        .onChange(of: draft.machineID) { _, _ in usingCustomFolder = false }
        .onChange(of: draft.connection) { _, _ in usingCustomFolder = false }
        .onChange(of: usingCustomFolder) { _, _ in error = nil }
        .onAppear(perform: persist)
        .task(id: directDestination) {
            if let id = directDestination { await loadDirectModels?(id) }
        }
        .task(id: claudeCheckTarget) {
            claudeCheck = nil
            guard let id = claudeCheckTarget, let bridge else { return }
            let info = await bridge.fetchClaudeAccounts(machineId: id)
            guard !Task.isCancelled, id == claudeCheckTarget else { return }
            claudeCheck = NewChatClaudeCheck.from(info)
        }
    }
    private func persist() { if let data = draft.data { cache.set(data, forKey: Self.preferencesKey) } }
    /// The loading id while a room is being made, so the model rows wait.
    private static let roomLoadingID = "ripul.newChat.room"
    /// A room has no model, Mac or folder: one row, named with the title above.
    private var roomSection: some View {
        Section {
            Button(action: startRoom) {
                HStack(spacing: 12) {
                    Image(systemName: "person.3")
                        .font(.ripulIcon(size: 15)).foregroundStyle(.tint).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Room").ripulText().font(.ripul(.headline))
                        Text("No model of its own. People talk here, and agents you @ answer from their own chats.")
                            .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if loadingID == Self.roomLoadingID { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NewChat.room")
        } footer: { RipulSectionFooter {
            Text("Named with the title above, or \"Room\".")
        } }.ripulThemedListRows()
        .disabled(loadingID != nil)
    }
    private func startRoom() {
        guard loadingID == nil, let onStartRoom else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        error = nil; loadingID = Self.roomLoadingID
        Task { @MainActor in
            defer { loadingID = nil }
            do { try await onStartRoom(name.isEmpty ? "Room" : name); onDismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
    private var destinationLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: destination?.icon ?? "desktopcomputer")
                .font(.ripulIcon(.subheadline, weight: .semibold))
                .foregroundStyle(destination == nil ? AnyShapeStyle(.ripul(.textSecondary)) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 0) {
                Text("New Chat").ripulText().font(.ripul(.subheadline, weight: .semibold)).foregroundStyle(.ripul(.text))
                HStack(spacing: 3) {
                    Text(destination?.name ?? draft.machineName ?? "Choose a Mac")
                        .lineLimit(1)
                    if !candidates.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.ripulIcon(size: 8, weight: .bold))
                    }
                }
                .font(.ripul(.caption2))
                .foregroundStyle(.ripul(.textSecondary))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .modifier(GlassPillModifier(glassStyle: "clear"))
    }
    /// The Mac the chat will be created on, as a lozenge button that switches
    /// the destination Mac directly from the title bar.
    @ViewBuilder
    private var destinationTitle: some View {
        if candidates.isEmpty {
            destinationLabel
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("NewChat.destination")
        } else {
            Menu {
                MenuIcons {
                    ForEach(candidates) { machine in
                        Button {
                            draft.select(machine)
                        } label: {
                            Label(
                                machine.name + (machine.unavailableReason == nil ? "" : " · unavailable"),
                                systemImage: draft.machineID == machine.id ? "checkmark" : (machine.icon ?? "desktopcomputer")
                            )
                        }
                    }
                }
            } label: {
                destinationLabel
            }
            .buttonStyle(.plain)
            .disabled(loadingID != nil)
            .accessibilityLabel("New Chat, \(destination?.name ?? draft.machineName ?? "Choose a Mac")")
            .accessibilityIdentifier("NewChat.destination")
        }
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
                    .font(.ripulIcon(size: 15)).foregroundStyle(.ripul(.textSecondary)).frame(width: 20)
                if let folder {
                    DirectoryPathLabel(path: folder)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("The Mac's working directory").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                        Text("Default").ripulText().font(.ripul(.headline))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if selected {
                    Image(systemName: "checkmark").font(.ripulIcon(size: 14, weight: .semibold)).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Keyed by the full path: two repos can share a last path component.
        .accessibilityIdentifier(folder.map { "NewChat.folderRow.\($0)" } ?? "NewChat.folderDefault")
    }
    /// Closes this sheet and opens the sign-in for the account on that Mac, as the sign-in alert does
    /// (the app's `ripul://claude-account`). After a moment: a sheet opened while this one closes is lost.
    private func signIn(on mac: NewChatMachine, _ check: NewChatClaudeCheck) {
        guard let link = check.signInLink(machineID: mac.id) else { return }
        let open = openURL
        onDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { open(link) }
    }
    private func remember(_ launch: NewChatLaunch) {
        guard !launch.folder.isEmpty else { return }
        recents.record(launch.folder, connection: launch.connection, machineID: launch.machineID)
        if let data = recents.data { cache.set(data, forKey: NewChatRecentFolders.preferencesKey) }
    }
    private func pick(_ model: ModelInfo?) {
        guard loadingID == nil, validationError == nil, let model, models.contains(where: { $0.id == model.id && $0.enabled }) else { return }
        // A Claude chat that could not reply there is not started: the sheet says why and offers the sign-in.
        if model.type == "claude-cli", let check = claudeCheck, check.blocksStart, let mac = chosenMac {
            error = check.message(mac: mac.name)
            return
        }
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
