import SwiftUI

/// The session list's overflow menu: new CLI sessions on the default machine,
/// new API chats pinned to a backend model, refresh, console logs.
///
/// A public component so a host that renders its own root chrome (the
/// first-party Agents|Plans shell) can offer the SAME menu the standalone
/// agent screen offers in its bar — one implementation, two chromes.
/// Extracted verbatim from RipulAgentScreen.sessionListMenuItems.
@available(iOS 26.0, macOS 26.0, *)
public struct SessionListMenu: View {
    /// Plain refs, NOT @ObservedObject: this view renders INSIDE an open
    /// Menu, where a direct invalidation re-resolves — and visibly flashes —
    /// the presented menu on every bridge/model publish (constant during a
    /// streaming turn). Body reads still see live values whenever the menu
    /// host legitimately re-resolves; the agent screen keys that via
    /// GlassTopBar.menuKey, which includes the machines roster this menu
    /// renders from.
    let bridge: AgentBridge
    let model: RipulSessionListModel
    let cache: RipulSessionCache
    /// Collapsed when a new session opens, matching the list's own behavior.
    let showingSessionList: Binding<Bool>
    /// Raises the host's `NewSessionModelPicker`. Menu content can't present a
    /// sheet of its own, so the host owns the presentation and this only asks
    /// for it. Nil ⇒ the entry is omitted.
    let onShowModelPicker: (() -> Void)?

    public init(
        bridge: AgentBridge,
        model: RipulSessionListModel,
        cache: RipulSessionCache,
        showingSessionList: Binding<Bool>,
        onShowModelPicker: (() -> Void)? = nil
    ) {
        self.bridge = bridge
        self.model = model
        self.cache = cache
        self.showingSessionList = showingSessionList
        self.onShowModelPicker = onShowModelPicker
    }

    private var defaultMachine: RemoteMachine? {
        let defaultMachineId = (cache.object(forKey: "ripulDefaultMachineId") as? String) ?? ""
        return model.machines.first { $0.machineId == defaultMachineId && $0.isOnline && !$0.isDisabled(cache: cache) }
    }

    public var body: some View {
        if let machine = defaultMachine {
            ForEach(ProviderConstants.cliProviders, id: \.id) { provider in
                Button {
                    Task {
                        await model.connectWithProvider(provider.providerKey!, to: machine, onSelect: { session in
                            withAnimation(.easeInOut(duration: 0.28)) {
                                showingSessionList.wrappedValue = false
                            }
                            Task {
                                await bridge.focusSession(id: session.id)
                                bridge.scrollToBottom()
                            }
                        }, onDismiss: {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                showingSessionList.wrappedValue = false
                            }
                        })
                    }
                } label: {
                    Label("New \(provider.label)", systemImage: provider.sfSymbol)
                }
                .uiKitIdentifier("AgentScreen.listMenu.new\(provider.id)Button")
            }

            Divider()
        }

        // Start from any model in the catalog. This used to be one button per
        // model in the hardcoded "Anthropic API" group, which silently excluded
        // every other backend group and could say nothing about what a model
        // cost or which sign-in paid for it. The picker answers all of that, and
        // it is the same picker the chat's model menu and the strip's "…" open.
        if let onShowModelPicker {
            Button(action: onShowModelPicker) {
                Label("New session from model…", systemImage: "square.stack.3d.up")
            }
            .uiKitIdentifier("AgentScreen.listMenu.newFromModelButton")

            Divider()
        }

        Button {
            Task { await model.refresh() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .uiKitIdentifier("AgentScreen.listMenu.refreshButton")

        Button {
            NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
        } label: {
            Label("Console Logs", systemImage: "doc.text.magnifyingglass")
        }
        .uiKitIdentifier("AgentScreen.listMenu.consoleLogsButton")
    }
}

// MARK: - New Session Picker

/// "Start a session with…" — `ModelPickerList` in `.launch` mode, wired to the
/// two ways a session actually begins.
///
/// Public and self-contained because both menu hosts (the standalone agent
/// screen and the first-party shell's root bar) need the identical sheet, and
/// the routing it encodes — a CLI model launches a harness session on the
/// default machine, anything else opens a chat pinned to that model — is
/// exactly what `SessionListMenu` used to hardcode one button at a time.
@available(iOS 26.0, macOS 26.0, *)
public struct NewSessionModelPicker: View {
    @ObservedObject var bridge: AgentBridge
    @ObservedObject var model: RipulSessionListModel
    let cache: RipulSessionCache
    /// Collapsed when the new session opens, matching the list's own behavior.
    let showingSessionList: Binding<Bool>
    let onDismiss: () -> Void

    @State private var loadingId: String?

    public init(
        bridge: AgentBridge,
        model: RipulSessionListModel,
        cache: RipulSessionCache,
        showingSessionList: Binding<Bool>,
        onDismiss: @escaping () -> Void
    ) {
        self.bridge = bridge
        self.model = model
        self.cache = cache
        self.showingSessionList = showingSessionList
        self.onDismiss = onDismiss
    }

    /// The CLI destination. Same resolution the menu's per-harness entries use.
    private var defaultMachine: RemoteMachine? {
        let defaultMachineId = (cache.object(forKey: "ripulDefaultMachineId") as? String) ?? ""
        return model.machines.first { $0.machineId == defaultMachineId && $0.isOnline && !$0.isDisabled(cache: cache) }
    }

    public var body: some View {
        ModelPickerSheetContent(
            title: "New session",
            models: bridge.availableModels,
            cache: cache,
            purpose: .launch(machine: defaultMachine),
            identifierPrefix: "NewSessionModelPicker",
            isLoading: bridge.availableModels.isEmpty,
            loadFailure: bridge.lastModelsError,
            loadingId: $loadingId,
            onRetry: { Task { await bridge.fetchModels() } },
            onPick: { picked in
                guard let picked else { return }
                start(picked)
            },
            onDismiss: onDismiss
        )
        .task { if bridge.availableModels.isEmpty { await bridge.fetchModels() } }
    }

    private func start(_ picked: ModelInfo) {
        let target = QuickLaunchTarget.resolve(model: picked)
        loadingId = target.id
        if let providerKey = target.providerKey {
            guard let machine = defaultMachine else { return }
            Task {
                await model.connectWithProvider(
                    providerKey,
                    modelId: picked.id,
                    to: machine,
                    onSelect: { session in
                        collapseList()
                        Task {
                            await bridge.focusSession(id: session.id)
                            bridge.scrollToBottom()
                        }
                    },
                    onDismiss: { collapseList() }
                )
                onDismiss()
            }
        } else {
            Task {
                bridge.logSessionStartMarker("ios.tap", extra: "source=NewSessionModelPicker")
                if let chatId = await bridge.createNewChat(modelOverride: picked.id) {
                    collapseList()
                    await bridge.focusSession(id: chatId)
                    bridge.scrollToBottom()
                }
                onDismiss()
            }
        }
    }

    private func collapseList() {
        withAnimation(.easeInOut(duration: 0.28)) {
            showingSessionList.wrappedValue = false
        }
    }
}
