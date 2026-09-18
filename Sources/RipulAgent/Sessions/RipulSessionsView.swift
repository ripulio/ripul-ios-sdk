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
/// Invites / folders / onboarding are optional injected slots; a host that does
/// not provide them simply doesn't render them (a built-in empty state is used
/// when `emptyStateOverride` is nil).
///
/// Embedded mode (`RipulAgentScreen`): pass `model:` to share an externally-owned
/// list model, `showsTitleLozenge: false` when the screen's unified top bar owns
/// the title (the list then reserves only the 52pt top spacer, exactly like the
/// native app's SessionListScreen), and optionally `chooseMode:` / `showingSidebar:`.
@available(iOS 26.0, macOS 26.0, *)
public struct RipulSessionsView: View {
    @Environment(\.ripulWindowContext) private var workspace
    @ObservedObject private var bridge: AgentBridge
    @StateObject private var model: RipulSessionListModel
    private let cache: RipulSessionCache
    private let onSelectSession: @MainActor (ChatSession) async -> Void
    private let onDismiss: () -> Void
    private let allowRipulAgents: Bool
    private let invitesSection: ((InvitesSectionActions) -> AnyView)?
    private let emptyStateOverride: (() -> AnyView)?
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
    private let onPickUnifiedSession: ((UnifiedSession) -> Void)?
    private let onListedSessionsChanged: (([RipulListedSession]) -> Void)?

    @Environment(\.createNewChat) private var createNewChat
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
        self.bridge = bridge
        self.cache = cache
        self.onSelectSession = onSelectSession
        self.onDismiss = onDismiss
        self.allowRipulAgents = allowRipulAgents
        self.invitesSection = invitesSection
        self.emptyStateOverride = emptyStateOverride
        self.chooseMode = chooseMode
        self.showsTitleLozenge = showsTitleLozenge
        self.showingSidebar = showingSidebar
        self.quickActionsEnabled = quickActionsEnabled
        self.reservesTopBarSpace = reservesTopBarSpace
        self.onPickUnifiedSession = onPickUnifiedSession
        self.onListedSessionsChanged = onListedSessionsChanged
        _model = StateObject(wrappedValue: model ?? RipulSessionListModel(
            bridge: bridge,
            tokenProvider: tokenProvider,
            cache: cache
        ))
    }

    private var callbacks: SessionsListCallbacks {
        SessionsListCallbacks(
            onFocusSession: { session in Task { await onSelectSession(session) } },
            onConnect: { machine in
                if model.usesDirectConnections { createNewChat?(machine.machineId); return }
                Task { await model.connect(to: machine, onSelect: onSelectSession, onDismiss: onDismiss) }
            },
            onNewCliSession: { machine, providerKey, modelId in
                if model.usesDirectConnections { createNewChat?(machine.machineId); return }
                Task { await model.connectWithProvider(providerKey, modelId: modelId, to: machine, onSelect: onSelectSession, onDismiss: onDismiss) }
            },
            onNewApiSession: { modelId in
                if model.usesDirectConnections { createNewChat?(nil); return }
                Task {
                    bridge.logSessionStartMarker("ios.tap", extra: "source=GlassSessionsList.quickApi")
                    if let chatId = await bridge.createNewChat(modelOverride: modelId) {
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
        guard let session = model.unifiedSessions.first(where: { $0.id == wanted }) else { return }
        RipulOpenSessionRequest.pendingSessionId = nil
        bridge.handleConsoleLog("LOG: [SIRI] opening session \(session.title)")
        model.openSession(session, onSelect: onSelectSession, onDismiss: onDismiss)
    }

    private func honorWindowRequest() {
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
            workspace.selectedSessionID = session.id
            workspace.title = session.title
            workspace.isRestoringSelection = restoring
            await onSelectSession(selected)
            workspace.isRestoringSelection = false
        }, onDismiss: { if !restoring { onDismiss() } })
    }

    public var body: some View {
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
            deletingFromHost: model.deletingFromHost,
            lastActiveBySessionId: model.lastActiveBySessionId,
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
            emptyStateOverride: emptyStateOverride,
            onListedSessionsChanged: onListedSessionsChanged,
            searchText: $searchText,
            renamingSession: $renamingSession,
            renameText: $renameText
        )
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
        .onChange(of: bridge.isSessionsReady) { _ in honorWindowRequest() }
        .onChange(of: model.hasCompletedAuthRefresh) { _ in honorWindowRequest() }
        .onRipulOpenSessionRequest(sessionCount: model.unifiedSessions.count) { honorOpenSessionRequest() }
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
        // Right-drag on the list opens the host's sidebar (native app chrome).
        // Only attached when the host supplied a sidebar binding.
        .gesture(
            DragGesture()
                .onEnded { value in
                    guard let showingSidebar else { return }
                    if value.translation.width > 60 {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { showingSidebar.wrappedValue = true }
                    }
                }
        )
        .renameSessionAlert(renamingSession: $renamingSession, renameText: $renameText, bridge: bridge)
        // Keep feedback on the list itself: a competing sheet/presentation
        // must not turn a failed open into a spinner that simply disappears.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = model.openSessionError ?? model.connectError {
                sessionErrorNotice(error)
            }
        }
        .connectionDiagnosis($errorDetails, bridge: bridge)
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
