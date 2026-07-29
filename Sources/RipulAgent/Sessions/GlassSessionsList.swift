import SwiftUI
import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - Shared Callbacks

public struct SessionsListCallbacks {
    var onFocusSession: (ChatSession) -> Void = { _ in }
    var onConnect: (RemoteMachine) -> Void = { _ in }
    var onNewCliSession: ((RemoteMachine, String) -> Void)?
    var onRestart: ((RemoteMachine) -> Void)?
    var onToggleMachineDisabled: ((RemoteMachine) -> Void)?

    public init(
        onFocusSession: @escaping (ChatSession) -> Void = { _ in },
        onConnect: @escaping (RemoteMachine) -> Void = { _ in },
        onNewCliSession: ((RemoteMachine, String) -> Void)? = nil,
        onRestart: ((RemoteMachine) -> Void)? = nil,
        onToggleMachineDisabled: ((RemoteMachine) -> Void)? = nil
    ) {
        self.onFocusSession = onFocusSession
        self.onConnect = onConnect
        self.onNewCliSession = onNewCliSession
        self.onRestart = onRestart
        self.onToggleMachineDisabled = onToggleMachineDisabled
    }
}

// MARK: - Glass Sessions List (iOS 26+)

@available(iOS 26.0, macOS 26.0, *)
public struct GlassSessionsList: View {
    @ObservedObject var bridge: AgentBridge
    /// Per-chat activity/phase/action maps, observed so the list re-sorts and
    /// updates live without re-rendering the WKWebView host.
    @ObservedObject var sessionStore: SessionListStore
    /// Navigation + thinking-mode state on its own leaf so writes don't fire
    /// bridge.objectWillChange and re-render the whole list container.
    @ObservedObject var navigationStore: NavigationStore
    /// Storage abstraction backing every persisted read/write (machine icons,
    /// disabled set, cached sessions) and the @AppStorage bindings below. Injected
    /// by the parent so a third-party host can namespace these keys.
    let cache: RipulSessionCache
    let machines: [RemoteMachine]
    let connectingMachineId: String?
    let callbacks: SessionsListCallbacks
    let unifiedSessions: [UnifiedSession]
    let isLoadingRemoteSessions: Bool
    /// True once a machines fetch has succeeded at least once (iOS: persisted
    /// per install). The first-run onboarding cards require this — an empty
    /// list before the first successful fetch means "offline / not loaded
    /// yet", not "new account".
    let hasResolvedMachines: Bool
    let openingUnifiedSessionId: String?
    let archivingUnifiedSessionId: String?
    let deletingUnifiedSessionId: String?
    let deletingFromHost: Bool
    /// Resolved last-active times keyed by UnifiedSession.id — stable
    /// across restarts, used for cold-start sort and display.
    let lastActiveBySessionId: [String: Date]
    let onOpenUnifiedSession: (UnifiedSession) -> Void
    let onArchiveUnifiedSession: (UnifiedSession) -> Void
    let onDeleteUnifiedSession: (UnifiedSession) -> Void
    let onRemoveFromRipulUnifiedSession: (UnifiedSession) -> Void
    let onMoveUnifiedSession: (UnifiedSession, RemoteMachine) -> Void
    let onBatchArchive: ([UnifiedSession]) -> Void
    let onBatchDelete: ([UnifiedSession]) -> Void
    var onDismissSheet: (() -> Void)? = nil
    var machineIcons: [String: String] = [:]
    var restartingMachineId: String? = nil
    var restartSucceededId: String? = nil
    /// The session whose chat is open alongside the list (master-detail layouts
    /// like the Mac split) — its row renders persistently selected. The iPhone
    /// navigates away on open, so it passes nil and no row stays highlighted.
    var selectedSessionId: String? = nil
    var onRefresh: (() async -> Void)? = nil

    // MARK: - Injected slots (app-only pieces the host may supply)

    /// Whether new-Ripul-Agent tiles are allowed on machine rows. Injected by the
    /// host (was an app-side flag).
    var allowRipulAgents: Bool = false
    /// Quick actions (host-defined machine actions). The owner discovers them
    /// (onDiscoverActions fires on row expand) and executes them; empty/nil =
    /// no quick-action UI.
    var onDiscoverActions: ((RemoteMachine) -> Void)? = nil
    var remoteActionsByMachine: [String: [RemoteActionDescriptor]] = [:]
    var onExecuteAction: ((RemoteMachine, RemoteActionDescriptor, [String: Any]) async -> [String: Any])? = nil
    /// Optional invites panel section, rendered where the app's InviteManager UI was.
    var invitesSection: (() -> AnyView)? = nil
    /// Optional folders (file browser) section, rendered where FolderTreeSection was.
    var foldersSection: (() -> AnyView)? = nil
    /// Developer's solution-shaping controls (collections, contexts, testing
    /// mode), rendered as a disclosure directly after Folders. Nil on surfaces
    /// that shouldn't manage anything.
    var solutionManagement: RipulSolutionManagement? = nil
    /// Optional empty-state override, rendered instead of the built-in empty text.
    var emptyStateOverride: (() -> AnyView)? = nil
    /// Optional universal-link opener (was DeepLinkHandler.shared).
    var onOpenUniversalLink: ((URL) -> Void)? = nil

    @Binding var searchText: String
    @Binding var renamingSession: ChatSession?
    @Binding var renameText: String

    @AppStorage("ripulMachinesPanelExpanded") private var storedMachinesExpanded = true
    @AppStorage("ripulDefaultMachineId") private var defaultMachineId = ""
    @AppStorage("ripul.embeddedOnboardingDismissed") private var embeddedOnboardingDismissed = false
    @State private var machinesExpanded = true
    @State private var expandedMachineId: String? = nil
    @State private var sessionsExpanded = true
    @State private var isSelecting = false
    @State private var selectedSessionIds: Set<String> = []
    /// Optimistic active-row override: set immediately on tap so the selection
    /// highlight snaps to user intent instead of waiting for the async
    /// bridge.activeSessionId (selectedSessionId) round-trip. Cleared whenever
    /// selectedSessionId changes (bridge confirmed, or a remote focus moved it).
    @State private var optimisticActiveId: String?
    @State private var selectedProjectFilter: String? = nil
    @State private var selectedTagFilter: String? = nil
    @State private var showBatchArchiveConfirm = false
    @State private var showBatchDeleteConfirm = false
    @State private var quickLaunchLoading: String?
    @State private var presentedPlan: (content: String, fileName: String)? = nil
    /// Session whose tags are being edited (drives the tags editor sheet).
    @State private var taggingSession: UnifiedSession? = nil

    // Folder tree
    @State private var foldersExpanded = false

    public init(
        bridge: AgentBridge,
        sessionStore: SessionListStore,
        navigationStore: NavigationStore,
        cache: RipulSessionCache,
        machines: [RemoteMachine],
        connectingMachineId: String?,
        callbacks: SessionsListCallbacks,
        unifiedSessions: [UnifiedSession],
        isLoadingRemoteSessions: Bool,
        hasResolvedMachines: Bool,
        openingUnifiedSessionId: String?,
        archivingUnifiedSessionId: String?,
        deletingUnifiedSessionId: String?,
        deletingFromHost: Bool,
        lastActiveBySessionId: [String: Date],
        onOpenUnifiedSession: @escaping (UnifiedSession) -> Void,
        onArchiveUnifiedSession: @escaping (UnifiedSession) -> Void,
        onDeleteUnifiedSession: @escaping (UnifiedSession) -> Void,
        onRemoveFromRipulUnifiedSession: @escaping (UnifiedSession) -> Void,
        onMoveUnifiedSession: @escaping (UnifiedSession, RemoteMachine) -> Void,
        onBatchArchive: @escaping ([UnifiedSession]) -> Void,
        onBatchDelete: @escaping ([UnifiedSession]) -> Void,
        onDismissSheet: (() -> Void)? = nil,
        machineIcons: [String: String] = [:],
        restartingMachineId: String? = nil,
        restartSucceededId: String? = nil,
        selectedSessionId: String? = nil,
        onRefresh: (() async -> Void)? = nil,
        allowRipulAgents: Bool = false,
        onDiscoverActions: ((RemoteMachine) -> Void)? = nil,
        remoteActionsByMachine: [String: [RemoteActionDescriptor]] = [:],
        onExecuteAction: ((RemoteMachine, RemoteActionDescriptor, [String: Any]) async -> [String: Any])? = nil,
        invitesSection: (() -> AnyView)? = nil,
        foldersSection: (() -> AnyView)? = nil,
        solutionManagement: RipulSolutionManagement? = nil,
        emptyStateOverride: (() -> AnyView)? = nil,
        onOpenUniversalLink: ((URL) -> Void)? = nil,
        searchText: Binding<String>,
        renamingSession: Binding<ChatSession?>,
        renameText: Binding<String>
    ) {
        self.bridge = bridge
        self.sessionStore = sessionStore
        self.navigationStore = navigationStore
        self.cache = cache
        self.machines = machines
        self.connectingMachineId = connectingMachineId
        self.callbacks = callbacks
        self.unifiedSessions = unifiedSessions
        self.isLoadingRemoteSessions = isLoadingRemoteSessions
        self.hasResolvedMachines = hasResolvedMachines
        self.openingUnifiedSessionId = openingUnifiedSessionId
        self.archivingUnifiedSessionId = archivingUnifiedSessionId
        self.deletingUnifiedSessionId = deletingUnifiedSessionId
        self.deletingFromHost = deletingFromHost
        self.lastActiveBySessionId = lastActiveBySessionId
        self.onOpenUnifiedSession = onOpenUnifiedSession
        self.onArchiveUnifiedSession = onArchiveUnifiedSession
        self.onDeleteUnifiedSession = onDeleteUnifiedSession
        self.onRemoveFromRipulUnifiedSession = onRemoveFromRipulUnifiedSession
        self.onMoveUnifiedSession = onMoveUnifiedSession
        self.onBatchArchive = onBatchArchive
        self.onBatchDelete = onBatchDelete
        self.onDismissSheet = onDismissSheet
        self.machineIcons = machineIcons
        self.restartingMachineId = restartingMachineId
        self.restartSucceededId = restartSucceededId
        self.selectedSessionId = selectedSessionId
        self.onRefresh = onRefresh
        self.allowRipulAgents = allowRipulAgents
        self.onDiscoverActions = onDiscoverActions
        self.remoteActionsByMachine = remoteActionsByMachine
        self.onExecuteAction = onExecuteAction
        self.invitesSection = invitesSection
        self.foldersSection = foldersSection
        self.solutionManagement = solutionManagement
        self.emptyStateOverride = emptyStateOverride
        self.onOpenUniversalLink = onOpenUniversalLink
        self._searchText = searchText
        self._renamingSession = renamingSession
        self._renameText = renameText
        // Bind the @AppStorage stores to the injected cache so persisted keys
        // live in the host-chosen suite. Defaults + key strings preserved.
        _storedMachinesExpanded = AppStorage(wrappedValue: true, "ripulMachinesPanelExpanded", store: cache.userDefaults)
        _defaultMachineId = AppStorage(wrappedValue: "", "ripulDefaultMachineId", store: cache.userDefaults)
        _embeddedOnboardingDismissed = AppStorage(wrappedValue: false, "ripul.embeddedOnboardingDismissed", store: cache.userDefaults)
    }

    private func machineExpandedBinding(for machine: RemoteMachine) -> Binding<Bool> {
        Binding(
            get: { expandedMachineId == machine.machineId },
            set: { newValue in expandedMachineId = newValue ? machine.machineId : nil }
        )
    }

    private var machineNamesSummary: String {
        machines.map(\.displayName).joined(separator: ", ")
    }

    /// The machine used for quick-launch buttons on the collapsed panel header.
    private var quickLaunchMachine: RemoteMachine? {
        machines.first { $0.machineId == defaultMachineId && $0.isOnline && !$0.isDisabled(cache: cache) }
            ?? machines.first { $0.isOnline && !$0.isDisabled(cache: cache) }
    }

    @ViewBuilder
    private var machinesPanelSection: some View {
        GlassSectionPanel(
            title: "Remote Machines",
            subtitle: machineNamesSummary,
            isExpanded: $machinesExpanded,
            trailing: { machinesPanelTrailing }
        ) {
            ForEach(machines) { machine in
                if machine.id != machines.first?.id {
                    Divider().padding(.horizontal, 16)
                }
                MachineRowExpandable(
                    machine: machine,
                    activeSessions: bridge.sessions.filter { $0.remoteMachineName == machine.displayName },
                    isConnecting: connectingMachineId == machine.machineId,
                    isExpanded: machineExpandedBinding(for: machine),
                    onConnect: { callbacks.onConnect(machine) },
                    onFocusSession: { session in callbacks.onFocusSession(session) },
                    onNewCliSession: callbacks.onNewCliSession,
                    onRestart: callbacks.onRestart,
                    onToggleDisabled: callbacks.onToggleMachineDisabled,
                    isRestarting: restartingMachineId == machine.machineId,
                    isRestartSucceeded: restartSucceededId == machine.machineId,
                    allowRipulAgents: allowRipulAgents,
                    machineIcon: machine.icon(cache: cache),
                    isMachineDisabled: machine.isDisabled(cache: cache),
                    defaultMachineId: defaultMachineId,
                    onSetDefault: { self.defaultMachineId = $0 },
                    onSetIcon: { RemoteMachine.setIcon($0, for: machine.machineId, cache: cache) },
                    onDiscoverActions: onDiscoverActions,
                    remoteActions: remoteActionsByMachine[machine.machineId] ?? [],
                    onExecuteAction: onExecuteAction.map { exec in
                        { action, params in await exec(machine, action, params) }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .uiKitIdentifier("GlassSessionsList.machines.panel")
        .contentShape(Rectangle())
        .onTapGesture {
            #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
        }
    }

    @ViewBuilder
    private var sessionsPanelSection: some View {
        GlassSectionPanel(
            title: "Sessions",
            isExpanded: $sessionsExpanded,
            center: {
                if availableProjects.count > 1 || !availableTags.isEmpty {
                    projectFilterMenu
                }
            },
            trailing: {
                GlassSelectButton(isSelecting: isSelecting) {
                    if isSelecting {
                        isSelecting = false
                        selectedSessionIds.removeAll()
                    } else {
                        isSelecting = true
                    }
                }
                .uiKitIdentifier("GlassSessionsList.sessions.selectButton")
                .opacity(unifiedSessions.isEmpty ? 0 : 1)
                .disabled(unifiedSessions.isEmpty)
            }
        ) {
            VStack(spacing: 8) {
                // Computed once per body evaluation — the filter + O(n log n)
                // sort was previously re-run three times per re-render (the
                // isEmpty check, the ForEach, and .animation(value:)). Audit #6.
                let sessions = filteredSessions
                if unifiedSessions.count > 12 {
                    GlassSearchField("Search sessions", text: $searchText)
                        .uiKitIdentifier("GlassSessionsList.sessions.searchField")
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                } else if !searchText.isEmpty {
                    Color.clear.frame(height: 0).onAppear { searchText = "" }
                }

                if isLoadingRemoteSessions && unifiedSessions.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                            .uiKitIdentifier("GlassSessionsList.sessions.loadingSpinner")
                        Text("Loading sessions...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .uiKitIdentifier("GlassSessionsList.sessions.loadingText")
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                } else if unifiedSessions.isEmpty {
                    Text("No sessions found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .uiKitIdentifier("GlassSessionsList.sessions.emptyText")
                } else if sessions.isEmpty {
                    Text("No matches for \"\(searchText)\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .uiKitIdentifier("GlassSessionsList.sessions.noMatchesText")
                } else {
                    List {
                        ForEach(sessions) { session in
                            // Optimistic override beats the async selectedSessionId so the
                            // active highlight snaps on tap; nil falls back to the confirmed value.
                            let activeId = optimisticActiveId ?? selectedSessionId
                            let isActiveRow = activeId != nil
                                && (session.ripulSession?.id == activeId || session.id == activeId)
                            UnifiedSessionRow(
                                sessionStore: sessionStore,
                                session: session,
                                cachedLastActive: lastActiveBySessionId[session.id],
                                // Spinner runs while navigating — keyed on navigatingToSessionId
                                // (cleared after slide animation) rather than openingUnifiedSessionId
                                // (cleared before onSelect fires, too early for the sweep + animation).
                                // Guard the navigating clauses on a non-nil navigatingToSessionId:
                                // session.ripulSession?.id is nil for un-imported rows, and a bare
                                // `nil == nil` would pin the spinner ON for every such row at rest.
                                isOpening: openingUnifiedSessionId == session.id
                                    || (navigationStore.navigatingToSessionId != nil
                                        && (navigationStore.navigatingToSessionId == session.ripulSession?.id
                                            || navigationStore.navigatingToSessionId == session.id)),
                                isArchiving: archivingUnifiedSessionId == session.id,
                                isDeleting: deletingUnifiedSessionId == session.id,
                                isDeletingFromHost: deletingUnifiedSessionId == session.id && deletingFromHost,
                                machineIcon: session.machineName.flatMap { machineIcons[$0] },
                                hideProjectName: activeProjectFilter != nil,
                                isSelectMode: isSelecting,
                                isSelected: selectedSessionIds.contains(session.id),
                                onSessionAction: { action in
                                    handleSessionAction(action, session: session)
                                }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelecting {
                                    if selectedSessionIds.contains(session.id) {
                                        selectedSessionIds.remove(session.id)
                                    } else {
                                        selectedSessionIds.insert(session.id)
                                    }
                                } else {
                                    optimisticActiveId = session.id   // snap highlight to intent
                                    onOpenUnifiedSession(session)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !isSelecting {
                                    Button {
                                        onArchiveUnifiedSession(session)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox.fill")
                                    }
                                    .uiKitIdentifier("GlassSessionsList.sessions.swipeArchiveButton")
                                    .tint(.orange)
                                }
                            }
                            .contextMenu {
                                if !isSelecting {
                                    Button {
                                        onArchiveUnifiedSession(session)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .uiKitIdentifier("GlassSessionsList.contextMenu.archiveButton")
                                    if let ripulTab = session.ripulSession {
                                        Button {
                                            renameText = ""
                                            renamingSession = ripulTab
                                        } label: {
                                            Label("Rename", systemImage: "pencil")
                                        }
                                        .uiKitIdentifier("GlassSessionsList.contextMenu.renameButton")
                                    }
                                    Button {
                                        taggingSession = session
                                    } label: {
                                        Label("Tags…", systemImage: "tag")
                                    }
                                    .uiKitIdentifier("GlassSessionsList.contextMenu.tagsButton")
                                    let moveTargets = machines.filter { m in
                                        m.isOnline && m.displayName != session.machineName
                                    }
                                    if !moveTargets.isEmpty {
                                        Menu {
                                            ForEach(moveTargets) { target in
                                                Button {
                                                    onMoveUnifiedSession(session, target)
                                                } label: {
                                                    Label(target.displayName, systemImage: "desktopcomputer")
                                                }
                                                .uiKitIdentifier("GlassSessionsList.contextMenu.moveTarget")
                                            }
                                        } label: {
                                            Label("Move to Machine…", systemImage: "arrow.right.circle")
                                        }
                                        .uiKitIdentifier("GlassSessionsList.contextMenu.moveMenu")
                                    }
                                    Divider()
                                    Picker(selection: Binding(
                                        get: { navigationStore.showThinkingMode },
                                        set: { mode in Task { await bridge.setShowThinking(mode) } }
                                    ), label: Label("Thinking", systemImage: "brain.head.profile")) {
                                        Text("None").tag("none")
                                        Text("Folded").tag("folded")
                                        Text("Open").tag("open")
                                    }
                                    .pickerStyle(.palette)
                                    .uiKitIdentifier("GlassSessionsList.contextMenu.thinkingPicker")
                                    Divider()
                                    Button {
                                        onRemoveFromRipulUnifiedSession(session)
                                    } label: {
                                        Label("Remove from Ripul", systemImage: "minus.circle")
                                    }
                                    .uiKitIdentifier("GlassSessionsList.contextMenu.removeFromRipulButton")
                                }
                            }
                            .listRowBackground(
                                isSelecting && selectedSessionIds.contains(session.id)
                                    ? Color.accentColor.opacity(0.08)
                                    : isActiveRow
                                        ? Color.accentColor.opacity(0.18)   // active — snaps on tap (optimistic), then confirmed
                                        : openingUnifiedSessionId == session.id
                                            ? Color.accentColor.opacity(0.12)
                                            : archivingUnifiedSessionId == session.id
                                                ? Color.orange.opacity(0.12)
                                                : deletingUnifiedSessionId == session.id
                                                    ? Color.red.opacity(0.12)
                                                    : Color.clear
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: selectedSessionId) { _, _ in
                        // Bridge confirmed (or a remote focus moved) the active session;
                        // drop the optimistic override so the highlight follows the bridge.
                        optimisticActiveId = nil
                    }
                    #if os(iOS)
                    .scrollDismissesKeyboard(.interactively)
                    #endif
                    .animation(.easeInOut(duration: 0.3), value: sessions.map(\.id))
                    .refreshable {
                        if let onRefresh { await onRefresh() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var machinesPanelTrailing: some View {
        if !machinesExpanded, let machine = quickLaunchMachine {
            HStack(spacing: 6) {
                if let newCliAction = callbacks.onNewCliSession {
                    ForEach(ProviderConstants.cliProviders, id: \.id) { provider in
                        Button {
                            quickLaunchLoading = provider.id
                            newCliAction(machine, provider.providerKey!)
                        } label: {
                            Group {
                                if quickLaunchLoading == provider.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: provider.sfSymbol)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color(hex: provider.color))
                                }
                            }
                            .frame(width: 32, height: 32)
                        }
                        .modifier(GlassCircleModifier(glassStyle: "regular"))
                        .buttonStyle(.plain)
                        .uiKitIdentifier("GlassSessionsList.machines.quick\(provider.id)")
                    }
                }
            }
        }
    }

    /// Distinct project names across all sessions, sorted case-insensitively.
    /// Drives the project-filter dropdown in the Sessions panel header.
    private var availableProjects: [String] {
        let names = unifiedSessions.compactMap(\.projectName)
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The project filter currently in effect, or nil. Guards against a
    /// previously-selected project that has since dropped out of the list
    /// (e.g. after a refresh past the 30-session scan cap) so a stale
    /// selection silently falls back to "All Projects".
    private var activeProjectFilter: String? {
        guard let p = selectedProjectFilter, availableProjects.contains(p) else { return nil }
        return p
    }

    /// Absolute working directory for each project name (first session wins;
    /// sessions sharing a project name share its cwd). Drives the Folders re-root.
    private var projectPathsByName: [String: String] {
        var map: [String: String] = [:]
        for s in unifiedSessions {
            if let name = s.projectName, let path = s.projectPath, map[name] == nil {
                map[name] = path
            }
        }
        return map
    }

    /// Absolute path of the currently-filtered project, when its cwd is known.
    /// Nil when no project is filtered (Folders falls back to the host default cwd).
    private var selectedProjectPath: String? {
        guard let name = activeProjectFilter else { return nil }
        return projectPathsByName[name]
    }

    /// Picker binding that reads through `activeProjectFilter` so an invalid
    /// stale selection presents as "All Projects" without extra bookkeeping.
    private var projectFilterBinding: Binding<String?> {
        Binding(get: { activeProjectFilter }, set: { newValue in
            selectedProjectFilter = newValue
            // Mirror the picked project's cwd to the bridge so the NEXT new chat
            // is created there. Set imperatively in the picker's setter — SwiftUI
            // does not reliably fire onChange for the computed selectedProjectPath,
            // which left pendingNewChatWorkingDirectory nil and new sessions in the
            // default workspace.
            bridge.pendingNewChatWorkingDirectory = newValue.flatMap { projectPathsByName[$0] }
        })
    }

    /// Distinct tags across all sessions, ordered most-recent first (shared with
    /// the tags picker). Drives the tag section of the filter dropdown.
    private var availableTags: [String] { recentTags }

    /// The tag filter currently in effect, or nil — guards a stale selection
    /// that has dropped out of the list, mirroring `activeProjectFilter`.
    private var activeTagFilter: String? {
        guard let t = selectedTagFilter, availableTags.contains(t) else { return nil }
        return t
    }

    private var tagFilterBinding: Binding<String?> {
        Binding(get: { activeTagFilter }, set: { selectedTagFilter = $0 })
    }

    /// Whether any filter (project and/or tag) is narrowing the list.
    private var hasActiveFilter: Bool { activeProjectFilter != nil || activeTagFilter != nil }

    /// Summary shown on the filter pill for the current project/tag selection.
    private var filterLabel: String {
        switch (activeProjectFilter, activeTagFilter) {
        case (nil, nil): return "All Projects"
        case let (project?, nil): return project
        case let (nil, tag?): return "#\(tag)"
        case let (project?, tag?): return "\(project) · #\(tag)"
        }
    }

    /// Project filter shown centred in the Sessions panel header: a pill
    /// button displaying the active project (or "All Projects") that opens a
    /// menu to switch. The caller hides it when fewer than two projects exist.
    @ViewBuilder
    private var projectFilterMenu: some View {
        Menu {
            if availableProjects.count > 1 {
                Picker("Filter by Project", selection: projectFilterBinding) {
                    Text("All Projects").tag(String?.none)
                    ForEach(availableProjects, id: \.self) { project in
                        Text(project).tag(String?.some(project))
                    }
                }
                .pickerStyle(.inline)
                .uiKitIdentifier("GlassSessionsList.sessions.projectFilterPicker")
            }
            if !availableTags.isEmpty {
                Picker("Filter by Tag", selection: tagFilterBinding) {
                    Text("All Tags").tag(String?.none)
                    ForEach(availableTags, id: \.self) { tag in
                        Label(tag, systemImage: "tag").tag(String?.some(tag))
                    }
                }
                .pickerStyle(.inline)
                .uiKitIdentifier("GlassSessionsList.sessions.tagFilterPicker")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption2.weight(.bold))
                Text(filterLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(hasActiveFilter ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(hasActiveFilter
                        ? Color.accentColor.opacity(0.15)
                        : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(hasActiveFilter
                        ? Color.accentColor.opacity(0.4)
                        : Color.primary.opacity(0.12), lineWidth: 1)
            )
            .frame(maxWidth: 220)
            .contentShape(Capsule(style: .continuous))
        }
        .uiKitIdentifier("GlassSessionsList.sessions.projectFilterMenu")
    }

    private var filteredSessions: [UnifiedSession] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        var base = unifiedSessions
        // Project + tag filters (header dropdown) — applied before the text search.
        if let project = activeProjectFilter {
            base = base.filter { $0.projectName == project }
        }
        if let tag = activeTagFilter {
            base = base.filter { $0.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) }
        }
        if !trimmed.isEmpty {
            let q = trimmed.lowercased()
            base = base.filter { s in
                s.title.lowercased().contains(q)
                    || (s.projectName?.lowercased().contains(q) ?? false)
                    || (s.gitBranch?.lowercased().contains(q) ?? false)
            }
        }
        // Re-sort incorporating live activity timestamps from the bridge.
        // Uses quantized time (30s buckets) so two concurrently active
        // sessions don't swap on every alternating tool call.
        return base.sorted { a, b in
            let ta = sortBucket(for: a)
            let tb = sortBucket(for: b)
            if ta != tb { return ta > tb }
            // Within the same bucket, preserve scanner order (stable).
            return a.lastUsed > b.lastUsed
        }
    }

    /// Best-known "last active" time for a session. Checks (in order):
    /// 1. Live bridge events (ripulSession keys) — most current
    /// 2. Resolved session-id cache — survives cold start
    /// 3. Scanner file mtime (session.lastUsed) — fallback
    private func effectiveLastActive(for session: UnifiedSession) -> Date {
        var best = session.lastUsed
        if let ripul = session.ripulSession {
            if let t = sessionStore.lastActiveTimeByChatId[ripul.id] { best = max(best, t) }
            if let t = sessionStore.lastActiveTimeByChatId[ripul.sourceChatId] { best = max(best, t) }
        }
        for key in session.matchKeys {
            if let t = sessionStore.lastActiveTimeByChatId[key] { best = max(best, t) }
        }
        if let t = lastActiveBySessionId[session.id] { best = max(best, t) }
        return best
    }

    /// Quantize effective last active to 30-second buckets for stable sorting.
    /// Sessions active within the same 30s window won't swap positions.
    private func sortBucket(for session: UnifiedSession) -> Int {
        Int(effectiveLastActive(for: session).timeIntervalSince1970 / 30)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Folders Panel

    @ViewBuilder
    private var foldersPanelSection: some View {
        if machines.contains(where: { $0.isOnline && !$0.isDisabled(cache: cache) }) {
            if let foldersSection {
                foldersSection()
            } else {
                // Default: the same FolderTreeSection the app embeds (iOS-only).
                // The slot exists for hosts that need a custom panel; nil gets
                // the app's 1:1 files browser.
                #if os(iOS)
                FolderTreeSection(
                    bridge: bridge,
                    isExpanded: $foldersExpanded,
                    rootPathOverride: selectedProjectPath,
                    onFileOpened: onDismissSheet
                )
                #endif
            }
        }
    }

    @ViewBuilder
    private var floatingActionBars: some View {
        if isSelecting && !selectedSessionIds.isEmpty {
            HStack(spacing: 12) {
                Button {
                    showBatchArchiveConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox.fill")
                            .uiKitIdentifier("GlassSessionsList.batch.archiveIcon")
                        Text("Archive (\(selectedSessionIds.count))")
                            .fontWeight(.medium)
                            .uiKitIdentifier("GlassSessionsList.batch.archiveLabel")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(.capsule)
                }
                .uiKitIdentifier("SessionListScreen.batch.archiveButton")
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .glassEffect(.clear.interactive(), in: .capsule)

                Button {
                    showBatchDeleteConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .uiKitIdentifier("GlassSessionsList.batch.deleteIcon")
                        Text("Delete (\(selectedSessionIds.count))")
                            .fontWeight(.medium)
                            .uiKitIdentifier("GlassSessionsList.batch.deleteLabel")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(.capsule)
                }
                .uiKitIdentifier("SessionListScreen.batch.deleteButton")
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .glassEffect(.clear.interactive(), in: .capsule)
            }
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Fresh/empty account state — no machines, no sessions, nothing loading,
    /// no pending invites, AND at least one successful machines fetch behind
    /// us. The empty agent screen surfaces the first-run onboarding cards here
    /// so a new user is guided to install the Mac companion app instead of
    /// staring at "No sessions found". Cached machines and sessions hydrate
    /// synchronously in SessionManager.init, and the fetch-resolution gate
    /// keeps "server unreachable" from masquerading as "new account", so
    /// returning users never hit this state.
    private var showOnboarding: Bool {
        hasResolvedMachines
            && machines.isEmpty
            && unifiedSessions.isEmpty
            && !isLoadingRemoteSessions
            && searchText.trimmingCharacters(in: .whitespaces).isEmpty
            && !embeddedOnboardingDismissed
    }

    /// Nothing to show yet and no successful fetch this install — we're still
    /// trying to reach the server (or offline). Returning users hit this on a
    /// cold launch with a cold cache + bad connectivity; show a neutral
    /// connecting state rather than first-run marketing cards.
    private var showConnectingPlaceholder: Bool {
        !hasResolvedMachines
            && machines.isEmpty
            && unifiedSessions.isEmpty
            && searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            if showOnboarding {
                if let emptyStateOverride {
                    emptyStateOverride()
                        .transition(.opacity)
                        .uiKitIdentifier("GlassSessionsList.onboarding")
                } else {
                    Text("No machines or sessions yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .uiKitIdentifier("GlassSessionsList.onboarding")
                }
            } else if showConnectingPlaceholder {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .uiKitIdentifier("GlassSessionsList.connecting")
            } else {
                VStack(spacing: 16) {
                    if !machines.isEmpty {
                        machinesPanelSection
                    }
                    if let invitesSection {
                        invitesSection()
                    }
                    sessionsPanelSection
                        .frame(maxHeight: .infinity, alignment: .top)
                    foldersPanelSection

                    // Developer's solution-shaping controls, after Folders.
                    #if os(iOS)
                    if let solutionManagement {
                        if #available(iOS 16.0, *) {
                            SolutionManagementSection(management: solutionManagement, bridge: bridge)
                        }
                    }
                    #endif
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            floatingActionBars
        }
        .animation(.easeInOut(duration: 0.25), value: showOnboarding)
        .animation(.easeInOut(duration: 0.25), value: showConnectingPlaceholder)
        .animation(.easeInOut(duration: 0.25), value: isSelecting)
        .animation(.easeInOut(duration: 0.25), value: selectedSessionIds.count)
        .onAppear {
            machinesExpanded = storedMachinesExpanded
            // Seed the new-chat target folder from the current project filter.
            bridge.pendingNewChatWorkingDirectory = selectedProjectPath
        }
        .onChange(of: machinesExpanded) { _, new in storedMachinesExpanded = new }
        .onChange(of: bridge.sessions.count) { _, _ in quickLaunchLoading = nil }
        // Keep the new-chat target folder in sync with the project filter, and
        // with late-resolving project paths once sessions finish loading.
        .onChange(of: selectedProjectPath) { _, newPath in
            bridge.pendingNewChatWorkingDirectory = newPath
        }
        .confirmationDialog("Archive \(selectedSessionIds.count) sessions?", isPresented: $showBatchArchiveConfirm, titleVisibility: .visible) {
            Button("Archive \(selectedSessionIds.count) Sessions", role: .destructive) {
                let sessions = selectedSessions
                isSelecting = false
                selectedSessionIds.removeAll()
                onBatchArchive(sessions)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(selectedSessionIds.count) sessions?", isPresented: $showBatchDeleteConfirm, titleVisibility: .visible) {
            Button("Delete \(selectedSessionIds.count) Sessions", role: .destructive) {
                let sessions = selectedSessions
                isSelecting = false
                selectedSessionIds.removeAll()
                onBatchDelete(sessions)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(
            get: { presentedPlan != nil },
            set: { if !$0 { presentedPlan = nil } }
        )) {
            if let plan = presentedPlan {
                PlanSheetView(content: plan.content, fileName: plan.fileName)
            }
        }
        .sheet(item: $taggingSession) { session in
            SessionTagsEditor(session: session, suggestions: recentTags) { newTags in
                taggingSession = nil
                Task {
                    await bridge.setSessionTags(sessionId: session.metadataKey, tags: newTags)
                    if let onRefresh { await onRefresh() }
                }
            }
        }
    }

    /// Distinct tags the user has used, ordered by the most-recently-active
    /// session carrying each — powers the "Recent Tags" picker in the editor.
    private var recentTags: [String] {
        var recencyByTag: [String: Date] = [:]
        for s in unifiedSessions {
            for tag in s.tags {
                if let existing = recencyByTag[tag] {
                    recencyByTag[tag] = max(existing, s.lastUsed)
                } else {
                    recencyByTag[tag] = s.lastUsed
                }
            }
        }
        return recencyByTag.sorted { $0.value > $1.value }.map(\.key)
    }

    private var selectedSessions: [UnifiedSession] {
        filteredSessions.filter { selectedSessionIds.contains($0.id) }
    }

    private func handleSessionAction(_ action: SessionRowAction, session: UnifiedSession) {
        switch action.behavior {
        case .showContent:
            let content = action.data["content"] ?? ""
            let title = action.data["title"] ?? "Content"
            presentedPlan = (content: content, fileName: title)
        case .focusSession:
            onOpenUnifiedSession(session)
        case .postToWeb:
            onOpenUnifiedSession(session)
        }
    }
}
