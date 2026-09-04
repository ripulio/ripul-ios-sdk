import SwiftUI
import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - Panel Stack Measurement

/// Height available to the panel stack, used to decide when the machines panel
/// must scroll its own contents instead of overflowing its band.
private struct SessionsPanelStackHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Shared Callbacks

public struct SessionsListCallbacks {
    var onFocusSession: (ChatSession) -> Void = { _ in }
    var onConnect: (RemoteMachine) -> Void = { _ in }
    /// Start a CLI session: (machine, providerKey, modelId). `modelId` is the
    /// catalog model to pin the chat to — nil means "this harness's default".
    var onNewCliSession: ((RemoteMachine, String, String?) -> Void)?
    /// Start a non-CLI API chat pinned to the given catalog model id
    /// (e.g. "backend-claude-fable-5"). No machine required.
    var onNewApiSession: ((String) -> Void)?
    var onRestart: ((RemoteMachine) -> Void)?
    var onToggleMachineDisabled: ((RemoteMachine) -> Void)?

    public init(
        onFocusSession: @escaping (ChatSession) -> Void = { _ in },
        onConnect: @escaping (RemoteMachine) -> Void = { _ in },
        onNewCliSession: ((RemoteMachine, String, String?) -> Void)? = nil,
        onNewApiSession: ((String) -> Void)? = nil,
        onRestart: ((RemoteMachine) -> Void)? = nil,
        onToggleMachineDisabled: ((RemoteMachine) -> Void)? = nil
    ) {
        self.onFocusSession = onFocusSession
        self.onConnect = onConnect
        self.onNewCliSession = onNewCliSession
        self.onNewApiSession = onNewApiSession
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
    /// Handed this list's own open/dismiss actions so accepting an invite can
    /// land the user in the joined chat.
    var invitesSection: ((InvitesSectionActions) -> AnyView)? = nil
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
    /// Height of the panel stack, measured from its own frame. Feeds the
    /// machine panel's expansion ceiling — see `machinePanelCap`.
    @State private var panelStackHeight: CGFloat = 0
    @State private var sessionsExpanded = true
    @State private var isSelecting = false
    @State private var selectedSessionIds: Set<String> = []
    // NOTE: the optimistic active-row override now lives inside GlassRichList,
    // which owns the tap that sets it and the `activeToken` change that clears
    // it. Keeping a copy here would have meant two sources for one highlight.
    @State private var selectedProjectFilter: String? = nil
    @State private var selectedTagFilter: String? = nil
    /// The shared work scope, re-read rather than cached — see `refreshWorkScope`.
    @State private var workScope: WorkScopeState? = nil
    @State private var showBatchArchiveConfirm = false
    @State private var showBatchDeleteConfirm = false
    @State private var quickLaunchLoading: String?
    /// Bumped on QuickLaunchPreferences.didChangeNotification to force the
    /// shortcut strip to re-read the cache after a Settings edit.
    @State private var quickLaunchRevision = 0
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
        invitesSection: ((InvitesSectionActions) -> AnyView)? = nil,
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

    /// Machines this panel should show: chat hosts. A browser host (Chrome +
    /// extension) is a legitimate machine in the registry, but it only serves
    /// tab mirrors — it can't run CLI sessions, so a row here would promise
    /// pairing and host actions it can't deliver. It appears where its
    /// capability lives instead (the Remote Tabs machine picker and the
    /// sidebar's per-machine sections).
    ///
    /// Display order is default-starred first, then alphabetical: the server
    /// sends most-recently-active, which reshuffled the list under the user's
    /// finger every time a machine checked in. `defaultMachineId` is an
    /// @AppStorage, so setting/clearing the star re-sorts reactively.
    private var chatHostMachines: [RemoteMachine] {
        machines
            .filter { $0.can("cli") }
            .sorted { a, b in
                let aDefault = a.machineId == defaultMachineId
                let bDefault = b.machineId == defaultMachineId
                if aDefault != bDefault { return aDefault }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
    }

    private var machineNamesSummary: String {
        chatHostMachines.map(\.displayName).joined(separator: ", ")
    }

    /// The machine used for quick-launch buttons on the collapsed panel header.
    private var quickLaunchMachine: RemoteMachine? {
        chatHostMachines.first { $0.machineId == defaultMachineId && $0.isOnline && !$0.isDisabled(cache: cache) }
            ?? chatHostMachines.first { $0.isOnline && !$0.isDisabled(cache: cache) }
    }

    /// How tall an expanded machine body may grow before it has to scroll
    /// itself, when the machine row IS the panel.
    ///
    /// The panel stack in `body` has no scroll container of its own: Sessions
    /// gets away with a greedy `List` and Folders caps its own scroller, but an
    /// expanded machine body is ~600-700pt of inflexible tiles. When the stack
    /// can't fit it, the VStack draws it at full height CENTERED on its
    /// allotted band — which is how the panel ends up bleeding upward under the
    /// top safe area. Handing the row a ceiling makes it scroll instead.
    ///
    /// Expressed as a share of the stack rather than "everything minus a
    /// reserve": the body grows on its own after it opens (remote actions and
    /// the host's Claude-account row both arrive async), so an arithmetic
    /// reserve is a guess that goes stale. Half the stack leaves room for the
    /// row's own header plus the Sessions / Folders / Solution headers on any
    /// screen size. Nil until measured, which means "no ceiling" — the row
    /// still bounds itself by its own natural height.
    private var machinePanelCap: CGFloat? {
        guard panelStackHeight > 0 else { return nil }
        return max(260, panelStackHeight * 0.5)
    }

    /// The same ceiling for a row inside the multi-machine panel, which also
    /// has to leave room for the panel's own header and the other machines'
    /// collapsed rows.
    private var machineRowCap: CGFloat? {
        guard let cap = machinePanelCap else { return nil }
        return max(220, cap - 44 - CGFloat(max(0, chatHostMachines.count - 1)) * 64)
    }

    @ViewBuilder
    private var machinesPanelSection: some View {
        // One machine needs no list around it. The "Machines" wrapper would be
        // a disclosure whose subtitle is that machine's name, containing a
        // second disclosure for the same machine — two chevrons and the name
        // twice to reach one row. Promote the row to be the panel instead; the
        // header disappears, and the machine's own disclosure still reaches
        // restart / set-default / set-icon.
        if chatHostMachines.count == 1, let machine = chatHostMachines.first {
            machineRow(for: machine, alwaysShowQuickLaunch: true, maxExpandedHeight: machinePanelCap)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .modifier(GlassPanelBackground())
                .uiKitIdentifier("GlassSessionsList.machines.soloPanel")
        } else {
            GlassSectionPanel(
                title: "Machines",
                subtitle: machineNamesSummary,
                isExpanded: $machinesExpanded,
                collapsedAccessory: { machinesPanelTrailing }
            ) {
                ForEach(chatHostMachines) { machine in
                    if machine.id != chatHostMachines.first?.id {
                        Divider().padding(.horizontal, 16)
                    }
                    machineRow(for: machine, maxExpandedHeight: machineRowCap)
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
    }

    @ViewBuilder
    private func machineRow(
        for machine: RemoteMachine,
        alwaysShowQuickLaunch: Bool = false,
        maxExpandedHeight: CGFloat? = nil
    ) -> some View {
        MachineRowExpandable(
            machine: machine,
            activeSessions: bridge.sessions.filter { $0.remoteMachineName == machine.displayName },
            isConnecting: connectingMachineId == machine.machineId,
            isExpanded: machineExpandedBinding(for: machine),
            onConnect: { callbacks.onConnect(machine) },
            onFocusSession: { session in callbacks.onFocusSession(session) },
            onNewCliSession: callbacks.onNewCliSession,
            onNewApiSession: callbacks.onNewApiSession,
            quickLaunchTargets: quickLaunchTargets,
            quickLaunchAllTargets: offerableQuickLaunchTargets,
            quickLaunchCache: cache,
            quickLaunchShowCircles: quickLaunchShowCircles,
            alwaysShowQuickLaunch: alwaysShowQuickLaunch,
            onRestart: callbacks.onRestart,
            onToggleDisabled: callbacks.onToggleMachineDisabled,
            isRestarting: restartingMachineId == machine.machineId,
            isRestartSucceeded: restartSucceededId == machine.machineId,
            maxExpandedHeight: maxExpandedHeight,
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
            },
            hostAuthBridge: bridge
        )
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
                }

                GlassRichList(
                    items: sessions,
                    emptyState: emptyState(visible: sessions.count),
                    identifierPrefix: "GlassSessionsList.sessions",
                    activity: activity(for:),
                    isSelecting: isSelecting,
                    selectedIds: selectedSessionIds,
                    // Two identities per row: the unified row's own id and its
                    // live web tab's. Collapsing them to one would stop
                    // highlighting every row that opened via a tab.
                    isActive: { session in
                        guard let activeId = selectedSessionId else { return false }
                        return session.ripulSession?.id == activeId || session.id == activeId
                    },
                    activeToken: selectedSessionId,
                    onTap: { onOpenUnifiedSession($0) },
                    onToggleSelect: { session in
                        if selectedSessionIds.contains(session.id) {
                            selectedSessionIds.remove(session.id)
                        } else {
                            selectedSessionIds.insert(session.id)
                        }
                    },
                    onRefresh: onRefresh,
                    row: { session in
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
                    },
                    swipe: { session in
                        Button {
                            onArchiveUnifiedSession(session)
                        } label: {
                            Label("Archive", systemImage: "archivebox.fill")
                        }
                        .uiKitIdentifier("GlassSessionsList.sessions.swipeArchiveButton")
                        .tint(.orange)
                    },
                    rowMenu: { session in
                        sessionContextMenu(session)
                    }
                )
            }
        }
    }

    /// Which resting state the list is in, or nil when it has rows to draw.
    ///
    /// "No machine has answered yet" is Sessions' own version of `unresolved`
    /// and has no Plans equivalent — Plans resolves against exactly one
    /// machine+folder, so its unresolved case is "no folder". Same slot,
    /// different sentence, which is why the component takes the string.
    private func emptyState(visible: Int) -> GlassListEmptyState? {
        if isLoadingRemoteSessions && unifiedSessions.isEmpty { return .loading }
        if unifiedSessions.isEmpty { return .empty("No sessions found.") }
        if visible == 0 { return .noMatches("No matches for \"\(searchText)\".") }
        return nil
    }

    /// The five in-flight inputs, reduced to the one thing the list needs.
    /// Rest is `.idle`; the row draws its own spinner from the same inputs.
    private func activity(for session: UnifiedSession) -> GlassRowActivity {
        if deletingUnifiedSessionId == session.id { return .deleting }
        if archivingUnifiedSessionId == session.id { return .archiving }
        if openingUnifiedSessionId == session.id { return .opening }
        return .idle
    }

    /// Session-vocabulary row actions. Stays here rather than in the shared
    /// component: thinking mode, move-to-machine and remove-from-Ripul mean
    /// nothing to a plan.
    @ViewBuilder
    private func sessionContextMenu(_ session: UnifiedSession) -> some View {
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

    /// The user's configured quick-start shortcuts, resolved against the live
    /// catalog. Empty when the strip is switched off in Settings. Reading
    /// `quickLaunchRevision` ties this to the preferences notification —
    /// UserDefaults writes don't invalidate a SwiftUI view on their own, so
    /// without it a Settings edit wouldn't reach an already-rendered list.
    private var quickLaunchTargets: [QuickLaunchTarget] {
        _ = quickLaunchRevision
        return QuickLaunchPreferences.targets(models: bridge.availableModels, cache: cache)
    }

    /// Everything the picker may offer — the full CLI catalog plus the API
    /// group, regardless of what the user has pinned. Unlike `quickLaunchTargets`
    /// this ignores the enabled flag and the stored selection: the picker's job
    /// is to show what exists so the user can pin it.
    private var offerableQuickLaunchTargets: [QuickLaunchTarget] {
        _ = quickLaunchRevision
        return QuickLaunchPreferences.offerableTargets(models: bridge.availableModels)
    }

    /// Whether the strips draw per-model circles or the lone "New Session"
    /// button. Same revision dependency as the targets — a Settings toggle
    /// reaches an already-rendered list only through the notification.
    private var quickLaunchShowCircles: Bool {
        _ = quickLaunchRevision
        return QuickLaunchPreferences.showCircles(cache: cache)
    }

    /// Quick-start shortcuts for the panel's default machine, on their own row
    /// beneath the header while the panel is collapsed. It used to be the
    /// header's trailing accessory, which squeezed the title and the machine-name
    /// subtitle once the set became user-sized — and matches how each machine
    /// row now carries its own strip.
    ///
    /// The panel renders this only when collapsed, so no `machinesExpanded`
    /// check is needed here.
    @ViewBuilder
    private var machinesPanelTrailing: some View {
        QuickLaunchStrip(
            targets: quickLaunchTargets,
            machine: quickLaunchMachine,
            loadingId: $quickLaunchLoading,
            identifierPrefix: "GlassSessionsList.machines",
            onNewCliSession: callbacks.onNewCliSession,
            onNewApiSession: callbacks.onNewApiSession,
            allTargets: offerableQuickLaunchTargets,
            cache: cache,
            showCircles: quickLaunchShowCircles
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    ///
    /// A pure VIEW FILTER: it narrows the rows and nothing else. It used to also
    /// set `pendingNewChatWorkingDirectory`, which quietly made "show me this
    /// project" and "put new work here" the same gesture — so you could not do
    /// either without the other. That mirror still exists (dropping it would
    /// regress new-chat placement) but is now fed by the work scope below, which
    /// is persisted and shared with Plans rather than dying with this view.
    private var projectFilterBinding: Binding<String?> {
        Binding(get: { activeProjectFilter }, set: { newValue in
            selectedProjectFilter = newValue
        })
    }

    // MARK: - Work scope

    /// The scope picker's options and provenance, re-read on every change.
    /// Nil until the first fetch answers, which simply means no scope section.
    private var scopeSubtitle: String? {
        guard let scope = workScope, let effective = scope.effective else { return nil }
        return (effective as NSString).lastPathComponent
    }

    /// Re-read the shared scope and mirror it to the bridge.
    ///
    /// The mirror is the surviving half of the old conflation: new chats must
    /// still land somewhere deliberate, and now that somewhere is the scope
    /// rather than whatever the project filter happened to be showing.
    private func refreshWorkScope() async {
        // No chatId — this surface has none. listMachineDirectories falls
        // through to the stored default machine, the same chain web Plans has
        // always used from the sidebar.
        let scope = await bridge.workScope(chatId: "")
        workScope = scope
        bridge.pendingNewChatWorkingDirectory = scope?.effective
    }

    /// Folders this list can see that the machine's favourites do not include.
    ///
    /// Restricted to sessions on the scope's own machine: scope overrides the
    /// directory and leaves the machine implicit, so offering a path from
    /// another machine would resolve against the wrong disk — failing, or worse,
    /// silently reading a different repo that happens to share the path.
    ///
    /// Known gap: a host-local bridge reports its machine as "this host", which
    /// no session's `machineName` matches, so on the Mac nothing is contributed
    /// and the picker degrades to the machine's favourites. That is the safe
    /// direction to fail in.
    private var scopeOptions: [String] {
        guard let scope = workScope else { return [] }
        guard let machine = scope.machineName else { return scope.options }
        let discovered = unifiedSessions
            .filter { $0.machineName == machine }
            .compactMap(\.projectPath)
        return scope.mergedOptions(discovered: discovered)
    }

    @ViewBuilder
    private var workScopeMenuSection: some View {
        if let scope = workScope {
            Divider()
            Section(WorkScopeState.title) {
                Button {
                    Task { _ = await bridge.setWorkScope(path: nil) }
                } label: {
                    if scope.source != "chosen" {
                        Label("Automatic", systemImage: "checkmark")
                    } else {
                        Text("Automatic")
                    }
                }
                ForEach(scopeOptions, id: \.self) { dir in
                    Button {
                        Task { _ = await bridge.setWorkScope(path: dir) }
                    } label: {
                        if scope.source == "chosen" && scope.effective == dir {
                            Label(dir, systemImage: "checkmark")
                        } else {
                            Text(dir)
                        }
                    }
                }
            }
        }
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
            // A third section in the SAME menu, not a second control — one
            // entry point, and no extra chrome on the most-used navigation
            // affordance. The sections above narrow what you see; this one
            // moves where new work goes.
            workScopeMenuSection
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
                    if !chatHostMachines.isEmpty {
                        machinesPanelSection
                            // Served before the greedy Sessions panel below.
                            // Without this the expanded body — now flexible, so
                            // that it can be compressed rather than overflow —
                            // is starved by the List's infinite appetite and
                            // opens as a sliver.
                            .layoutPriority(1)
                    }
                    if let invitesSection {
                        invitesSection(InvitesSectionActions(
                            openChat: { callbacks.onFocusSession($0) },
                            dismissList: { onDismissSheet?() }
                        ))
                    }
                    sessionsPanelSection
                        // Only greedy-fill while expanded (so a long session list
                        // gets the remaining space to grow into) — collapsed, this
                        // must NOT hold an infinite frame, or the panel's outer
                        // frame stays full-height around its now-tiny header row:
                        // a blank gap where the list used to be, with Folders /
                        // Solution management stuck below it instead of sliding up
                        // to fill the space GlassSectionPanel's own collapse
                        // (`if isExpanded { content }`) already freed.
                        .frame(maxHeight: sessionsExpanded ? .infinity : nil, alignment: .top)
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
                // Top-anchor the stack: with every disclosure collapsed,
                // nothing in the VStack is greedy, so without this the short
                // content centers in the offered height instead of hugging
                // the top. Expanded Sessions still greedy-fills exactly as
                // before (its own conditional frame above).
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Measure the space the stack actually has, so the machines
                // panel knows when it has to scroll rather than overflow (see
                // machinePanelCap). Read off the .infinity frame, not the
                // VStack: the frame's height is the container's regardless of
                // what the children do, so there is no feedback loop between
                // the ceiling and the height it is derived from. The top bar is
                // a safeAreaInset, so this is already net of it.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: SessionsPanelStackHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
                .onPreferenceChange(SessionsPanelStackHeightKey.self) { height in
                    panelStackHeight = height
                }
                .onChange(of: panelStackHeight) { _, height in
                    RipulLog.log("[SOLOPANEL] panelStack=\(Int(height)) "
                        + "cap=\(machinePanelCap.map { String(Int($0)) } ?? "nil")")
                }
            }

            floatingActionBars
        }
        .animation(.easeInOut(duration: 0.25), value: showOnboarding)
        .animation(.easeInOut(duration: 0.25), value: showConnectingPlaceholder)
        .animation(.easeInOut(duration: 0.25), value: isSelecting)
        .animation(.easeInOut(duration: 0.25), value: selectedSessionIds.count)
        .onAppear {
            machinesExpanded = storedMachinesExpanded
        }
        .task {
            // Seed the new-chat target folder from the shared work scope (it
            // used to come from the project filter — see projectFilterBinding).
            await refreshWorkScope()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulWorkScopeChanged)) { _ in
            Task { await refreshWorkScope() }
        }
        .onChange(of: machinesExpanded) { _, new in storedMachinesExpanded = new }
        // Drop a stale query when the list shrinks below the search threshold.
        // This used to be a `Color.clear.onAppear { searchText = "" }` sitting
        // in the panel body — a state write during body evaluation, which is
        // both a SwiftUI hazard and invisible at the call site.
        .onChange(of: unifiedSessions.count) { _, count in
            if count <= 12 && !searchText.isEmpty { searchText = "" }
        }
        .onChange(of: bridge.sessions.count) { _, _ in quickLaunchLoading = nil }
        .onReceive(NotificationCenter.default.publisher(for: QuickLaunchPreferences.didChangeNotification)) { _ in
            quickLaunchRevision &+= 1
        }
        // NOTE: the new-chat target folder deliberately no longer tracks
        // `selectedProjectPath`. That is the view filter; new work follows the
        // work scope (see refreshWorkScope). `selectedProjectPath` survives
        // because the Folders panel still re-roots to the filtered project,
        // which is a view concern and correctly stays one.
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
            // Machine-written plan link tags are identity, not labels — keep
            // them out of the filter menu and the editor's picker.
            for tag in s.tags where !PlanTagConvention.isPlanTag(tag) {
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
