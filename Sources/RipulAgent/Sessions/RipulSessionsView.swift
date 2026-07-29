import SwiftUI

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
    @ObservedObject private var bridge: AgentBridge
    @StateObject private var model: RipulSessionListModel
    private let cache: RipulSessionCache
    private let onSelectSession: (ChatSession) -> Void
    private let onDismiss: () -> Void
    private let allowRipulAgents: Bool
    private let invitesSection: (() -> AnyView)?
    private let foldersSection: (() -> AnyView)?
    private let solutionManagement: RipulSolutionManagement?
    private let emptyStateOverride: (() -> AnyView)?
    private let chooseMode: RipulChooseMode?
    private let showsTitleLozenge: Bool
    private let showingSidebar: Binding<Bool>?
    private let quickActionsEnabled: Bool

    @State private var searchText = ""
    @State private var renamingSession: ChatSession?
    @State private var renameText = ""
    @State private var machineIcons: [String: String] = [:]
    /// Host-defined quick actions per machine — owned here (the app's deleted
    /// twin kept them in the list). Seeded from cache, refreshed on row expand.
    @State private var remoteActionsByMachine: [String: [RemoteActionDescriptor]] = [:]

    public init(
        bridge: AgentBridge,
        cache: RipulSessionCache,
        tokenProvider: @escaping () -> String?,
        onSelectSession: @escaping (ChatSession) -> Void,
        onDismiss: @escaping () -> Void = {},
        allowRipulAgents: Bool = false,
        invitesSection: (() -> AnyView)? = nil,
        foldersSection: (() -> AnyView)? = nil,
        solutionManagement: RipulSolutionManagement? = nil,
        emptyStateOverride: (() -> AnyView)? = nil,
        model: RipulSessionListModel? = nil,
        chooseMode: RipulChooseMode? = nil,
        showsTitleLozenge: Bool = true,
        showingSidebar: Binding<Bool>? = nil,
        quickActionsEnabled: Bool = false
    ) {
        self.bridge = bridge
        self.cache = cache
        self.onSelectSession = onSelectSession
        self.onDismiss = onDismiss
        self.allowRipulAgents = allowRipulAgents
        self.invitesSection = invitesSection
        self.foldersSection = foldersSection
        self.solutionManagement = solutionManagement
        self.emptyStateOverride = emptyStateOverride
        self.chooseMode = chooseMode
        self.showsTitleLozenge = showsTitleLozenge
        self.showingSidebar = showingSidebar
        self.quickActionsEnabled = quickActionsEnabled
        _model = StateObject(wrappedValue: model ?? RipulSessionListModel(
            bridge: bridge,
            tokenProvider: tokenProvider,
            cache: cache
        ))
    }

    private var callbacks: SessionsListCallbacks {
        SessionsListCallbacks(
            onFocusSession: { session in onSelectSession(session) },
            onConnect: { machine in
                Task { await model.connect(to: machine, onSelect: onSelectSession, onDismiss: onDismiss) }
            },
            onNewCliSession: { machine, providerKey in
                Task { await model.connectWithProvider(providerKey, to: machine, onSelect: onSelectSession, onDismiss: onDismiss) }
            },
            onRestart: { machine in
                Task { await model.restartMachine(machine) }
            },
            onToggleMachineDisabled: { machine in
                model.toggleMachineDisabled(machine)
            }
        )
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
                model.openSession(session, onSelect: onSelectSession, onDismiss: onDismiss)
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
            foldersSection: foldersSection,
            solutionManagement: solutionManagement,
            emptyStateOverride: emptyStateOverride,
            searchText: $searchText,
            renamingSession: $renamingSession,
            renameText: $renameText
        )
        .task {
            model.initialLoad()
            if quickActionsEnabled, remoteActionsByMachine.isEmpty {
                remoteActionsByMachine = RemoteActionDescriptor.loadAllCached(cache: cache)
            }
        }
        .onAppear { machineIcons = RemoteMachine.iconsByDisplayName(machines: model.machines, cache: cache) }
        .onChange(of: model.machines) { _, machines in
            machineIcons = RemoteMachine.iconsByDisplayName(machines: machines, cache: cache)
        }
        .onReceive(NotificationCenter.default.publisher(for: RemoteMachine.iconsDidChangeNotification)) { _ in
            machineIcons = RemoteMachine.iconsByDisplayName(machines: model.machines, cache: cache)
        }
        .safeAreaInset(edge: .top) {
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
                // bar, with the choose-mode banner below it when active.
                VStack(spacing: 0) {
                    Color.clear.frame(height: 52)
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
        // Open/connect failures get the classified diagnosis sheet (friendly
        // summary + hint + copyable technical details), mirroring the native
        // app's SessionListScreen.
        .connectionDiagnosis(
            Binding(get: { model.connectError }, set: { model.connectError = $0 }),
            bridge: bridge
        )
        .connectionDiagnosis(
            Binding(get: { model.openSessionError }, set: { model.openSessionError = $0 }),
            bridge: bridge
        )
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
