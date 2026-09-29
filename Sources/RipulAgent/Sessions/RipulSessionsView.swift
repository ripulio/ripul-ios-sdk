import SwiftUI
import Combine

/// Public, drop-in native session list.
///
/// Renders the paired host machines and their sessions (via `GlassSessionsList`)
/// backed by a `RipulSessionListModel`. The host supplies:
/// - `bridge` — the `AgentBridge` that owns the relay connection + session stores,
/// - `cache` — an isolated `RipulSessionCache` suite for persisted list state,
/// - `tokenProvider` — returns the current Ripul (Clerk) token for the relay
///   machine API,
/// - `onSelectSession` — invoked with the `ChatSession` to display when a row is
///   opened / a machine is connected,
/// - `onDismiss` — invoked to dismiss the list (e.g. hand back to the chat view).
///
/// Folders / onboarding are optional injected slots; a host that does not
/// provide them simply doesn't render them (a built-in empty state is used
/// when `emptyStateOverride` is nil). Invites render from `invitesSection` if
/// injected, else — on iOS — from `inviteManager`'s SDK panel.
///
/// Embedded mode (`RipulAgentScreen`): pass `model:` to share an externally-owned
/// list model, `showsTitleLozenge: false` when the screen's unified top bar owns
/// the title (the list then reserves only the 52pt top spacer, exactly like the
/// native app's SessionListScreen), and optionally `chooseMode:` / `showingSidebar:`.
@available(iOS 26.0, macOS 26.0, *)
public struct RipulSessionsView: View {
    @Environment(\.ripulWindowContext) private var workspace
    private var bridge: AgentBridge
    /// Owned once, not observed; views track the model's reads via Observation.
    @StateObject private var modelOwner: UnobservedOwner<RipulSessionListModel>
    private var model: RipulSessionListModel { modelOwner.value }
    private let cache: RipulSessionCache
    /// The model handed in, for equality; nil when this view built its own.
    private let modelRef: RipulSessionListModel?
    /// The host's callbacks, behind a reference: see `RipulSessionsViewActions`.
    private let actions: RipulSessionsViewActions
    private var onSelectSession: @MainActor (ChatSession) async -> Void { actions.onSelectSession }
    private var onDismiss: () -> Void { actions.onDismiss }
    private var invitesSection: ((InvitesSectionActions) -> AnyView)? { actions.invitesSection }
    private var emptyStateOverride: (() -> AnyView)? { actions.emptyStateOverride }
    private var onPickUnifiedSession: ((UnifiedSession) -> Void)? { actions.onPickUnifiedSession }
    private var onListedSessionsChanged: (([RipulListedSession]) -> Void)? { actions.onListedSessionsChanged }
    /// Which optional callbacks were supplied at construction. The body
    /// branches on these, so they take part in equality.
    private let suppliedCallbacks: [Bool]
    private let allowRipulAgents: Bool
    private let inviteManager: RipulInviteManager?
    private let chooseMode: RipulChooseMode?
    private let showsTitleLozenge: Bool
    private let showingSidebar: Binding<Bool>?
    private let quickActionsEnabled: Bool
    /// Embedded mode reserves 52pt at the top for the host screen's floating
    /// unified bar. Pass `false` only where no floating bar covers the list.
    /// The shared agent workspace has a list header even with docked metadata.
    private let reservesTopBarSpace: Bool
    /// Pick mode: when set, tapping a session hands back its IDENTITY without
    /// opening it — no tab creation, no remote history import, no focus
    /// change. This is the sessions list as a picker (the link-to-plan sheet).
    /// `ripul://choose` keeps the open path: it needs an openable tab back.

    @Environment(\.createNewChat) private var createNewChat
    @Environment(\.ripulBottomBarFrame) private var bottomBar
    /// How far the bottom notice must rise to clear the host's tab bar (or
    /// the home indicator). The workspace column ignores the vertical safe
    /// area, so a plain bottom inset would put the notice under the bar.
    @State private var noticeBottomClearance: CGFloat = 0
    @State private var searchText = ""
    @State private var renamingSession: ChatSession?
    @State private var renameText = ""
    @State private var machineIcons: [String: String] = [:]
    @State private var errorDetails: String?
    /// Host-defined quick actions per machine — owned here (the app's deleted
    /// twin kept them in the list). Seeded from cache, refreshed on row expand.
    @State private var remoteActionsByMachine: [String: [RemoteActionDescriptor]] = [:]

    public init(
        bridge: AgentBridge,
        cache: RipulSessionCache,
        tokenProvider: @escaping () -> String?,
        onSelectSession: @escaping @MainActor (ChatSession) async -> Void,
        onDismiss: @escaping () -> Void = {},
        allowRipulAgents: Bool = false,
        invitesSection: ((InvitesSectionActions) -> AnyView)? = nil,
        inviteManager: RipulInviteManager? = nil,
        emptyStateOverride: (() -> AnyView)? = nil,
        model: RipulSessionListModel? = nil,
        chooseMode: RipulChooseMode? = nil,
        showsTitleLozenge: Bool = true,
        showingSidebar: Binding<Bool>? = nil,
        quickActionsEnabled: Bool = false,
        reservesTopBarSpace: Bool = true,
        onListedSessionsChanged: (([RipulListedSession]) -> Void)? = nil,
        onPickUnifiedSession: ((UnifiedSession) -> Void)? = nil
    ) {
        let actions = RipulSessionsViewActions()
        actions.update(onSelectSession: onSelectSession, onDismiss: onDismiss,
                       invitesSection: invitesSection, emptyStateOverride: emptyStateOverride,
                       onListedSessionsChanged: onListedSessionsChanged,
                       onPickUnifiedSession: onPickUnifiedSession)
        self.init(bridge: bridge, cache: cache, tokenProvider: tokenProvider, actions: actions,
                  allowRipulAgents: allowRipulAgents, inviteManager: inviteManager, model: model,
                  chooseMode: chooseMode, showsTitleLozenge: showsTitleLozenge,
                  showingSidebar: showingSidebar, quickActionsEnabled: quickActionsEnabled,
                  reservesTopBarSpace: reservesTopBarSpace)
    }

    /// For a host that re-renders often (the agent screen, on every list/chat
    /// flip): pass one `actions` box it owns and refreshes each render, and
    /// apply `.equatable()`. The list then skips re-rendering when nothing it
    /// shows has changed — the callbacks, being behind the box, are always
    /// the latest without taking part in equality.
    public init(
        bridge: AgentBridge,
        cache: RipulSessionCache,
        tokenProvider: @escaping () -> String?,
        actions: RipulSessionsViewActions,
        allowRipulAgents: Bool = false,
        inviteManager: RipulInviteManager? = nil,
        model: RipulSessionListModel? = nil,
        chooseMode: RipulChooseMode? = nil,
        showsTitleLozenge: Bool = true,
        showingSidebar: Binding<Bool>? = nil,
        quickActionsEnabled: Bool = false,
        reservesTopBarSpace: Bool = true
    ) {
        self.bridge = bridge
        self.cache = cache
        self.modelRef = model
        self.actions = actions
        self.suppliedCallbacks = [actions.invitesSection != nil, actions.emptyStateOverride != nil,
                                  actions.onListedSessionsChanged != nil, actions.onPickUnifiedSession != nil]
        self.allowRipulAgents = allowRipulAgents
        self.inviteManager = inviteManager
        self.chooseMode = chooseMode
        self.showsTitleLozenge = showsTitleLozenge
        self.showingSidebar = showingSidebar
        self.quickActionsEnabled = quickActionsEnabled
        self.reservesTopBarSpace = reservesTopBarSpace
        _modelOwner = StateObject(wrappedValue: UnobservedOwner(model ?? RipulSessionListModel(
            bridge: bridge,
            tokenProvider: tokenProvider,
            cache: cache
        )))
    }

    private var callbacks: SessionsListCallbacks {
        SessionsListCallbacks(
            onFocusSession: { session in
                // A tab handed in from outside the list (an accepted invite,
                // a machine-panel open) goes through the SAME path a row tap
                // takes when its row exists: spinner, latest-tap-wins
                // cancellation and the persistent error notice all live in
                // `openSession`. Only a tab with no row yet falls back to a
                // bare focus.
                if onPickUnifiedSession == nil,
                   let row = model.unifiedSessions.first(where: { $0.represents(session) }) {
                    model.openSession(row, onSelect: onSelectSession, onDismiss: onDismiss)
                } else {
                    Task { await onSelectSession(session) }
                }
            },
            onConnect: { machine in
                if model.usesDirectConnections { createNewChat?(machine.machineId); return }
                Task { await model.connect(to: machine, onSelect: onSelectSession, onDismiss: onDismiss) }
            },
            onNewCliSession: { machine, providerKey, modelId in
                if model.usesDirectConnections { createNewChat?(machine.machineId); return }
                Task { await model.connectWithProvider(providerKey, modelId: modelId, to: machine, onSelect: onSelectSession, onDismiss: onDismiss) }
            },
            onNewApiSession: { machine, modelId in
                if model.usesDirectConnections { createNewChat?(machine?.machineId); return }
                Task {
                    bridge.logSessionStartMarker("ios.tap", extra: "source=GlassSessionsList.quickApi")
                    if let chatId = await bridge.createNewChat(modelOverride: modelId, machineId: machine?.machineId) {
                        await bridge.focusSession(id: chatId)
                        bridge.scrollToBottom()
                    }
                    onDismiss()
                }
            },
            onRestart: model.usesDirectConnections ? nil : { machine in
                Task { await model.restartMachine(machine) }
            },
            onToggleMachineDisabled: { machine in
                model.toggleMachineDisabled(machine)
            }
        )
    }

    /// Opens the session Siri named, via the same call a tapped row makes.
    ///
    /// The latch is only cleared once a matching session is actually found. A
    /// Siri cold launch arrives here before `unifiedSessions` has loaded, and
    /// clearing on a miss would drop the request silently — which is precisely
    /// the failure this replaced. In pick mode the request is dropped
    /// deliberately: the list is on screen to return a choice to someone else,
    /// and opening a chat underneath them would be wrong.
    private func honorOpenSessionRequest() {
        guard let wanted = RipulOpenSessionRequest.pendingSessionId else { return }
        guard onPickUnifiedSession == nil else {
            RipulOpenSessionRequest.pendingSessionId = nil
            return
        }
        // By row id, or any id the chat is known by (its host chat id, a
        // `cli_` tab id): a deep link or launch argument names the chat, not
        // the list's row.
        guard let session = model.unifiedSessions.first(where: { $0.id == wanted })
            ?? model.unifiedSessions.first(where: { $0.matchKeys.contains(wanted) })
        else {
            rescanForMissingRequest(wanted)
            return
        }
        // Same readiness as a window restore: on a cold launch the cached row
        // exists long before the bridge can open it, and opening then failed
        // ("not ready") with an error notice. Re-run as readiness changes.
        guard bridge.isSessionsReady,
              model.usesDirectConnections || session.machineName == nil || model.hasCompletedAuthRefresh
        else { return }
        RipulOpenSessionRequest.pendingSessionId = nil
        // An explicit request (Siri, a share link, ripul://open-chat) beats
        // restoring the window's previous selection. Left pending, the launch
        // restore opened afterwards, superseded this open (latest tap wins)
        // and, being a restore, stayed on the list.
        if let workspace {
            workspace.pendingSessionID = nil
            workspace.restoresPendingSession = false
        }
        bridge.handleConsoleLog("LOG: [SIRI] opening session \(session.title)")
        model.openSession(session, onSelect: onSelectSession, onDismiss: onDismiss)
    }

    /// Runs Move to Machine for `ripul://move-chat`. The row is found by any id
    /// the chat is known by, including this device's own tab id. A miss
    /// rescans with backoff, since a chat just started on a Mac isn't listed
    /// until a scan lands — and one scan is not enough: it can be skipped as
    /// already in flight, and its rebuild lands after the await returns.
    private func honorMoveSessionRequest(id: String, targetMachineId: String) {
        let model = self.model
        let bridge = self.bridge
        Task { @MainActor in
            @MainActor func find() -> UnifiedSession? {
                model.unifiedSessions.first(where: { $0.id == id })
                    ?? model.unifiedSessions.first(where: { $0.matchKeys.contains(id) })
                    ?? model.unifiedSessions.first(where: { $0.ripulSession?.id == id })
            }
            var session = find()
            for delay in [0.0, 3, 8] where session == nil {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                await bridge.fetchSessions()
                await model.loadRemoteSessions(force: true)
                try? await Task.sleep(for: .seconds(1))
                session = find()
            }
            guard let session else {
                bridge.handleConsoleLog("LOG: [MOVE] request id=\(id) failed: chat not in the session list")
                return
            }
            guard let target = model.machines.first(where: { $0.machineId == targetMachineId }) else {
                bridge.handleConsoleLog("LOG: [MOVE] request id=\(id) failed: no machine \(targetMachineId)")
                return
            }
            model.moveSession(session, to: target)
        }
    }

    /// A chat named by a link or launch argument can be newer than the list:
    /// one just started on the Mac isn't listed until the next remote scan, and
    /// nothing else triggers one, so the request waited indefinitely. A miss
    /// rescans, backing off, and each scan's rebuild re-runs the request
    /// through `sessionCount`. After the last scan the request is dropped
    /// rather than left pending, where it would block the window's own restore.
    private func rescanForMissingRequest(_ wanted: String) {
        guard RipulOpenSessionRequest.rescan?.id != wanted,
              model.usesDirectConnections || model.hasCompletedAuthRefresh else { return }
        RipulOpenSessionRequest.rescan?.task.cancel()
        let model = self.model
        let bridge = self.bridge
        let task = Task { @MainActor in
            defer { if RipulOpenSessionRequest.rescan?.id == wanted { RipulOpenSessionRequest.rescan = nil } }
            for delay in [0.0, 3, 8, 20] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, RipulOpenSessionRequest.pendingSessionId == wanted else { return }
                bridge.handleConsoleLog("LOG: [SIRI] \(wanted) not listed — rescanning")
                await model.loadRemoteSessions(force: true)
            }
            // Room for the last scan's off-main rebuild to land.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, RipulOpenSessionRequest.pendingSessionId == wanted else { return }
            RipulOpenSessionRequest.pendingSessionId = nil
            bridge.handleConsoleLog("LOG: [SIRI] \(wanted) never listed — request dropped")
        }
        RipulOpenSessionRequest.rescan = (wanted, task)
    }

    private func honorWindowRequest() {
        // An explicit open request waiting for readiness takes precedence.
        guard RipulOpenSessionRequest.pendingSessionId == nil else { return }
        guard onPickUnifiedSession == nil, bridge.isSessionsReady,
              model.openingUnifiedSessionId == nil,
              let workspace, let wanted = workspace.pendingSessionID,
              let session = model.unifiedSessions.first(where: { $0.id == wanted || $0.matchKeys.contains(wanted) }) else { return }
        // The cached catalogue and JS callables precede authenticated relay setup.
        // Direct/local sessions do not depend on that web authentication path.
        guard model.usesDirectConnections || session.machineName == nil || model.hasCompletedAuthRefresh else { return }
        let restoring = workspace.restoresPendingSession
        workspace.pendingSessionID = nil
        workspace.restoresPendingSession = false
        model.openSession(session, onSelect: { selected in
            workspace.select(sessionID: session.id, title: session.title)
            workspace.isRestoringSelection = restoring
            await onSelectSession(selected)
            workspace.isRestoringSelection = false
        }, onDismiss: { if !restoring { onDismiss() } })
    }

    public var body: some View {
        // Only this subtree follows the ~2s last-active ticks of a running agent.
        LastActiveReader(model.lastActive) { lastActiveBySessionId in
        GlassSessionsList(
            bridge: bridge,
            sessionStore: bridge.sessionList,
            navigationStore: bridge.navigationStore,
            cache: cache,
            machines: model.machines,
            connectingMachineId: model.connectingMachineId,
            callbacks: callbacks,
            unifiedSessions: model.unifiedSessions,
            isLoadingRemoteSessions: model.isLoadingRemoteSessions,
            hasResolvedMachines: model.hasSuccessfulMachinesResponse,
            openingUnifiedSessionId: model.openingUnifiedSessionId,
            archivingUnifiedSessionId: model.archivingUnifiedSessionId,
            deletingUnifiedSessionId: model.deletingUnifiedSessionId,
            leavingUnifiedSessionId: model.leavingUnifiedSessionId,
            deletingFromHost: model.deletingFromHost,
            lastActiveBySessionId: lastActiveBySessionId,
            onOpenUnifiedSession: { session in
                if let onPickUnifiedSession {
                    onPickUnifiedSession(session)
                } else {
                    model.openSession(session, onSelect: onSelectSession, onDismiss: onDismiss)
                }
            },
            onArchiveUnifiedSession: { session in model.archiveSession(session) },
            onDeleteUnifiedSession: { session in model.deleteSession(session) },
            onRemoveFromRipulUnifiedSession: { session in model.deleteSession(session, keepRemote: true) },
            onRemoveInvitedUnifiedSession: { session in model.removeInvitedSession(session) },
            onLeaveInvitedUnifiedSession: { session in model.leaveInvitedSession(session) },
            onMoveUnifiedSession: { session, target in model.moveSession(session, to: target) },
            onBatchArchive: { sessions in model.batchArchiveSessions(sessions) },
            onBatchDelete: { sessions in model.batchDeleteSessions(sessions) },
            onDismissSheet: onDismiss,
            machineIcons: machineIcons,
            restartingMachineId: model.restartingMachineId,
            restartSucceededId: model.restartSucceededId,
            selectedSessionId: bridge.activeSessionId,
            onRefresh: { await model.refresh() },
            allowRipulAgents: allowRipulAgents,
            onDiscoverActions: quickActionsEnabled ? { machine in
                Task {
                    let raw = await bridge.discoverRemoteActions(machineId: machine.machineId)
                    let descriptors = raw.compactMap { RemoteActionDescriptor(from: $0) }
                    if !descriptors.isEmpty {
                        remoteActionsByMachine[machine.machineId] = descriptors
                        RemoteActionDescriptor.saveToCache(machineId: machine.machineId, actions: descriptors, cache: cache)
                    }
                }
            } : nil,
            remoteActionsByMachine: quickActionsEnabled ? remoteActionsByMachine : [:],
            onExecuteAction: quickActionsEnabled ? { machine, action, params in
                await bridge.executeRemoteAction(machineId: machine.machineId, actionId: action.id, params: params)
            } : nil,
            invitesSection: invitesSection,
            // A picker lists sessions to choose from; invites aren't choices.
            inviteManager: onPickUnifiedSession == nil ? inviteManager : nil,
            emptyStateOverride: emptyStateOverride,
            onListedSessionsChanged: onListedSessionsChanged,
            searchText: $searchText,
            renamingSession: $renamingSession,
            renameText: $renameText
        )
        }
        .task {
            // Pick mode borrows the HOST's live model — kicking initialLoad
            // there fires a publish burst on presentation that re-renders the
            // presenting subtree and knocks the just-presented sheet down
            // (tap Link -> sheet appears -> immediately falls back).
            if onPickUnifiedSession == nil {
                model.initialLoad()
            }
            if quickActionsEnabled, remoteActionsByMachine.isEmpty {
                remoteActionsByMachine = RemoteActionDescriptor.loadAllCached(cache: cache)
            }
        }
        .onReceive(workspace?.$pendingSessionID.eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()) { _ in honorWindowRequest() }
        .onChange(of: model.unifiedSessions.map(\.id)) { _ in honorWindowRequest() }
        .onChange(of: bridge.isSessionsReady) { _ in honorOpenSessionRequest(); honorWindowRequest() }
        .onChange(of: model.hasCompletedAuthRefresh) { _ in honorOpenSessionRequest(); honorWindowRequest() }
        .onRipulOpenSessionRequest(sessionCount: model.unifiedSessions.count) { honorOpenSessionRequest() }
        .onReceive(NotificationCenter.default.publisher(for: RipulMoveSessionRequest.notification)) { _ in
            if let request = RipulMoveSessionRequest.take() {
                honorMoveSessionRequest(id: request.sessionId, targetMachineId: request.targetMachineId)
            }
        }
        .onAppear {
            if let request = RipulMoveSessionRequest.take() {
                honorMoveSessionRequest(id: request.sessionId, targetMachineId: request.targetMachineId)
            }
        }
        .onAppear { machineIcons = RemoteMachine.iconsByDisplayName(machines: model.machines, cache: cache) }
        .onChange(of: model.machines) { _, machines in
            machineIcons = RemoteMachine.iconsByDisplayName(machines: machines, cache: cache)
        }
        .onReceive(NotificationCenter.default.publisher(for: RemoteMachine.iconsDidChangeNotification)) { _ in
            machineIcons = RemoteMachine.iconsByDisplayName(machines: model.machines, cache: cache)
        }
        .ripulTopBarInset {
            if showsTitleLozenge {
                // Screen title lozenge — standalone mode. Long-press opens the
                // DevTools console (ConsoleLogViewer), presented by whoever hosts
                // this view.
                Text("Sessions")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .modifier(GlassPillModifier())
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                            NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
                        }
                    )
                    .uiKitIdentifier("RipulSessions.topBar.titleLozenge")
                    .padding(.top, 4)
            } else {
                // Embedded mode — mirrors the native app's SessionListScreen: a
                // transparent 52pt spacer for the screen's floating unified top
                // bar, with the choose-mode banner below it when active. The
                // spacer is dropped where no floating bar covers the list (see
                // reservesTopBarSpace) — otherwise it reads as a stranded gap.
                VStack(spacing: 0) {
                    if reservesTopBarSpace {
                        Color.clear.frame(height: 52)
                    }
                    if let chooseMode {
                        ChooseModeBannerHost(chooseMode: chooseMode)
                    }
                }
            }
        }
        // No list-level drag to open the host's sidebar. It used to be a
        // DragGesture that flipped `showingSidebar` on release: it never
        // tracked the thumb, and because it recognised first it starved the
        // host's thumb-tracking edge recognizer (SidebarEdgeSwipeView), which
        // then never began. It was also attached with no binding at all,
        // swallowing horizontal drags for nothing. The host owns the edge.
        .renameSessionAlert(renamingSession: $renamingSession, renameText: $renameText, bridge: bridge)
        // Keep feedback on the list itself: a competing sheet/presentation
        // must not turn a failed open into a spinner that simply disappears.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if let error = model.openSessionError ?? model.connectError {
                    sessionErrorNotice(error)
                } else if let note = model.infoNotice {
                    sessionInfoNotice(note)
                }
            }
            .padding(.bottom, noticeBottomClearance)
        }
        #if os(iOS)
        // Measure the whole list, outside the inset, so the notice's own
        // height never feeds back into the clearance.
        .background(SessionsScrollBoundsReader(bottomBar: bottomBar) {
            noticeBottomClearance = $0
        })
        #endif
        .connectionDiagnosis($errorDetails, bridge: bridge)
    }

    private func sessionInfoNotice(_ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(note, systemImage: "info.circle.fill")
                .font(.subheadline)
            Spacer(minLength: 0)
            Button("Dismiss") { model.infoNotice = nil }
                .font(.subheadline)
                .uiKitIdentifier("RipulSessions.info.dismiss")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .uiKitIdentifier("RipulSessions.info.notice")
    }

    private func sessionErrorNotice(_ error: String) -> some View {
        let diagnosis = ConnectionDiagnosis.classify(rawError: error, phase: nil)
        return VStack(alignment: .leading, spacing: 8) {
            Label(diagnosis.summary, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
            if let hint = diagnosis.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Details") { errorDetails = error }
                    .uiKitIdentifier("RipulSessions.error.details")
                Spacer()
                Button("Dismiss") {
                    if model.openSessionError != nil { model.openSessionError = nil }
                    else { model.connectError = nil }
                }
                .uiKitIdentifier("RipulSessions.error.dismiss")
            }
            .font(.subheadline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .uiKitIdentifier("RipulSessions.error.notice")
    }
}

/// Observes the injected choose-mode object (an optional on the parent view, so
/// it can't be an @ObservedObject there) and renders the banner while active.
/// Mirrors the native SessionListScreen's chooseModeBanner.
private struct ChooseModeBannerHost: View {
    @ObservedObject var chooseMode: RipulChooseMode

    var body: some View {
        if chooseMode.active {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                Text("Select a session to work in \u{201C}\(chooseMode.appName ?? "the app")\u{201D}")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Button("Cancel") { chooseMode.cancel() }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor)
            .foregroundStyle(.white)
        }
    }
}

/// The session list's callbacks, held by reference.
///
/// A closure built in a parent's body is a new value on every render, so a
/// list that took its callbacks directly compared unequal on every parent
/// render and re-ran its whole body — for the agent screen, on every
/// list/chat flip, rebuilding the 206-row `GlassSessionsList` mid-slide. A
/// host that owns one of these (e.g. in `@State`) and calls `update` in its
/// body gives the list the latest callbacks while its identity stays stable.
@MainActor
public final class RipulSessionsViewActions {
    public internal(set) var onSelectSession: @MainActor (ChatSession) async -> Void = { _ in }
    public internal(set) var onDismiss: () -> Void = {}
    public internal(set) var invitesSection: ((InvitesSectionActions) -> AnyView)?
    public internal(set) var emptyStateOverride: (() -> AnyView)?
    public internal(set) var onListedSessionsChanged: (([RipulListedSession]) -> Void)?
    public internal(set) var onPickUnifiedSession: ((UnifiedSession) -> Void)?

    public init() {}

    public func update(
        onSelectSession: @escaping @MainActor (ChatSession) async -> Void,
        onDismiss: @escaping () -> Void = {},
        invitesSection: ((InvitesSectionActions) -> AnyView)? = nil,
        emptyStateOverride: (() -> AnyView)? = nil,
        onListedSessionsChanged: (([RipulListedSession]) -> Void)? = nil,
        onPickUnifiedSession: ((UnifiedSession) -> Void)? = nil
    ) {
        self.onSelectSession = onSelectSession
        self.onDismiss = onDismiss
        self.invitesSection = invitesSection
        self.emptyStateOverride = emptyStateOverride
        self.onListedSessionsChanged = onListedSessionsChanged
        self.onPickUnifiedSession = onPickUnifiedSession
    }
}

@available(iOS 26.0, macOS 26.0, *)
extension RipulSessionsView: Equatable {
    /// Everything the body renders from its inputs, by value or identity.
    /// Callbacks are excluded: they live behind `actions`, whose identity is
    /// compared. Model, environment and state changes invalidate the body
    /// through their own tracking, independent of this.
    nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.actions === rhs.actions
                && lhs.bridge === rhs.bridge
                && lhs.modelRef === rhs.modelRef
                && (lhs.cache as AnyObject) === (rhs.cache as AnyObject)
                && lhs.suppliedCallbacks == rhs.suppliedCallbacks
                && lhs.allowRipulAgents == rhs.allowRipulAgents
                && lhs.inviteManager === rhs.inviteManager
                && lhs.chooseMode === rhs.chooseMode
                && lhs.showsTitleLozenge == rhs.showsTitleLozenge
                && (lhs.showingSidebar == nil) == (rhs.showingSidebar == nil)
                && lhs.quickActionsEnabled == rhs.quickActionsEnabled
                && lhs.reservesTopBarSpace == rhs.reservesTopBarSpace
        }
    }
}
