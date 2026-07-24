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
    private let emptyStateOverride: (() -> AnyView)?

    @State private var searchText = ""
    @State private var renamingSession: ChatSession?
    @State private var renameText = ""
    @State private var machineIcons: [String: String] = [:]

    public init(
        bridge: AgentBridge,
        cache: RipulSessionCache,
        tokenProvider: @escaping () -> String?,
        onSelectSession: @escaping (ChatSession) -> Void,
        onDismiss: @escaping () -> Void = {},
        allowRipulAgents: Bool = false,
        invitesSection: (() -> AnyView)? = nil,
        foldersSection: (() -> AnyView)? = nil,
        emptyStateOverride: (() -> AnyView)? = nil
    ) {
        self.bridge = bridge
        self.cache = cache
        self.onSelectSession = onSelectSession
        self.onDismiss = onDismiss
        self.allowRipulAgents = allowRipulAgents
        self.invitesSection = invitesSection
        self.foldersSection = foldersSection
        self.emptyStateOverride = emptyStateOverride
        _model = StateObject(wrappedValue: RipulSessionListModel(
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
            invitesSection: invitesSection,
            foldersSection: foldersSection,
            emptyStateOverride: emptyStateOverride,
            searchText: $searchText,
            renamingSession: $renamingSession,
            renameText: $renameText
        )
        .task { model.initialLoad() }
        .onAppear { machineIcons = RemoteMachine.iconsByDisplayName(machines: model.machines, cache: cache) }
        .onChange(of: model.machines) { _, machines in
            machineIcons = RemoteMachine.iconsByDisplayName(machines: machines, cache: cache)
        }
        .onReceive(NotificationCenter.default.publisher(for: RemoteMachine.iconsDidChangeNotification)) { _ in
            machineIcons = RemoteMachine.iconsByDisplayName(machines: model.machines, cache: cache)
        }
        // Screen title lozenge — the SDK session-list equivalent of the native
        // app's AgentScreen.topBar.titleLozenge. Long-press opens the DevTools
        // console (ConsoleLogViewer), presented by whoever hosts this view.
        .safeAreaInset(edge: .top) {
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
        }
    }
}
