import SwiftUI

// MARK: - Machine Row (Expandable)

/// Expandable machine row: header (name, online status, active-session count,
/// default star, folded quick-launch CLI buttons) with a disclosure body
/// offering New-Agent / new-CLI-session tiles and machine settings (restart,
/// set default, set icon, enable/disable).
///
/// Everything in the body is a `MachinePanelEntry`, and the user's per-machine
/// `MachinePanelLayout` decides its order, whether it draws as a tile or a
/// row, and whether it shows at all (Customise Panel). Host scripts — the
/// primary remote actions — are editable from here too (Edit Scripts).
///
/// Cache-derived values (`allowRipulAgents`, `machineIcon`, `isMachineDisabled`,
/// `defaultMachineId`) are resolved by the parent — which owns the
/// `RipulSessionCache` — and passed in, with `onSetDefault` / `onSetIcon`
/// callbacks writing back through the same cache.
public struct MachineRowExpandable: View {
    @Environment(\.createNewChat) private var createNewChat
    let machine: RemoteMachine
    let activeSessions: [ChatSession]
    let isConnecting: Bool
    @Binding var isExpanded: Bool
    let onConnect: () -> Void
    var onFocusSession: ((ChatSession) -> Void)? = nil
    /// (machine, providerKey, modelId). A nil `modelId` means "this harness's
    /// default" — what the expanded body's provider tiles ask for. The folded
    /// quick-start strip always names a model.
    var onNewCliSession: ((RemoteMachine, String, String?) -> Void)? = nil
    /// Start an API chat pinned to a catalog model id, on this row's machine.
    /// The machine is nil only where the strip has no row to belong to (the
    /// collapsed panel header), which means "let the web app choose".
    var onNewApiSession: ((RemoteMachine?, String) -> Void)? = nil
    /// User-configured quick-start shortcuts for the folded strip. Resolved by
    /// the parent (which owns the cache and the model catalog); empty = no strip.
    var quickLaunchTargets: [QuickLaunchTarget] = []
    /// Full offerable catalog for the strip's trailing "more models" picker,
    /// resolved by the same parent. Empty (with `quickLaunchCache` nil) = no
    /// picker, which is the default for hosts that don't wire it up.
    var quickLaunchAllTargets: [QuickLaunchTarget] = []
    /// Cache the picker writes pin/unpin through. Nil = no picker.
    var quickLaunchCache: RipulSessionCache? = nil
    /// Whether the strip draws the pinned-model circles. Resolved by the parent
    /// from `QuickLaunchPreferences.showCircles`; default true keeps hosts that
    /// never thread it on the circles they render today. False = the strip is a
    /// single "New Session" button opening the same picker.
    var quickLaunchShowCircles: Bool = true
    /// Keep the shortcut row visible even while this row is expanded. Set when
    /// the row IS the panel (the single-machine case), where there's no
    /// collapsed panel header left to carry the shortcuts — so expanding to
    /// reach restart/set-icon would otherwise hide them entirely.
    var alwaysShowQuickLaunch: Bool = false
    var onRestart: ((RemoteMachine) -> Void)? = nil
    var onToggleDisabled: ((RemoteMachine) -> Void)? = nil
    var isRestarting: Bool = false
    var isRestartSucceeded: Bool = false
    /// Ceiling for the expanded body, in points. Past it the body scrolls its
    /// own contents instead of growing. Resolved by the parent, which is the
    /// only view that knows how much room the panel stack actually has. Nil =
    /// no ceiling: the body renders at its natural height, which is correct
    /// wherever the surrounding layout can absorb it (the macOS panel).
    var maxExpandedHeight: CGFloat? = nil

    // Cache-derived, resolved by the parent.
    var allowRipulAgents: Bool = false
    var machineIcon: String? = nil
    var isMachineDisabled: Bool = false
    var defaultMachineId: String = ""
    var onSetDefault: ((String) -> Void)? = nil
    var onSetIcon: ((String?) -> Void)? = nil

    // Quick actions (host-defined, discovered over the relay). nil/empty = absent.
    var onDiscoverActions: ((RemoteMachine) -> Void)? = nil
    var remoteActions: [RemoteActionDescriptor] = []
    var onExecuteAction: ((RemoteActionDescriptor, [String: Any]) async -> [String: Any])? = nil

    /// Bridge for the phone-driven Claude sign-in row. Nil = feature absent,
    /// which is the default for embedded SDK hosts that don't wire it up.
    /// Held as a plain reference, not observed — this row only calls methods.
    var hostAuthBridge: AgentBridge? = nil

    public init(
        machine: RemoteMachine,
        activeSessions: [ChatSession],
        isConnecting: Bool,
        isExpanded: Binding<Bool>,
        onConnect: @escaping () -> Void,
        onFocusSession: ((ChatSession) -> Void)? = nil,
        onNewCliSession: ((RemoteMachine, String, String?) -> Void)? = nil,
        onNewApiSession: ((RemoteMachine?, String) -> Void)? = nil,
        quickLaunchTargets: [QuickLaunchTarget] = [],
        quickLaunchAllTargets: [QuickLaunchTarget] = [],
        quickLaunchCache: RipulSessionCache? = nil,
        quickLaunchShowCircles: Bool = true,
        alwaysShowQuickLaunch: Bool = false,
        onRestart: ((RemoteMachine) -> Void)? = nil,
        onToggleDisabled: ((RemoteMachine) -> Void)? = nil,
        isRestarting: Bool = false,
        isRestartSucceeded: Bool = false,
        maxExpandedHeight: CGFloat? = nil,
        allowRipulAgents: Bool = false,
        machineIcon: String? = nil,
        isMachineDisabled: Bool = false,
        defaultMachineId: String = "",
        onSetDefault: ((String) -> Void)? = nil,
        onSetIcon: ((String?) -> Void)? = nil,
        onDiscoverActions: ((RemoteMachine) -> Void)? = nil,
        remoteActions: [RemoteActionDescriptor] = [],
        onExecuteAction: ((RemoteActionDescriptor, [String: Any]) async -> [String: Any])? = nil,
        hostAuthBridge: AgentBridge? = nil
    ) {
        self.machine = machine
        self.activeSessions = activeSessions
        self.isConnecting = isConnecting
        self._isExpanded = isExpanded
        self.onConnect = onConnect
        self.onFocusSession = onFocusSession
        self.onNewCliSession = onNewCliSession
        self.onNewApiSession = onNewApiSession
        self.quickLaunchTargets = quickLaunchTargets
        self.quickLaunchAllTargets = quickLaunchAllTargets
        self.quickLaunchCache = quickLaunchCache
        self.quickLaunchShowCircles = quickLaunchShowCircles
        self.alwaysShowQuickLaunch = alwaysShowQuickLaunch
        self.onRestart = onRestart
        self.onToggleDisabled = onToggleDisabled
        self.isRestarting = isRestarting
        self.isRestartSucceeded = isRestartSucceeded
        self.maxExpandedHeight = maxExpandedHeight
        self.allowRipulAgents = allowRipulAgents
        self.machineIcon = machineIcon
        self.isMachineDisabled = isMachineDisabled
        self.defaultMachineId = defaultMachineId
        self.onSetDefault = onSetDefault
        self.onSetIcon = onSetIcon
        self.onDiscoverActions = onDiscoverActions
        self.remoteActions = remoteActions
        self.onExecuteAction = onExecuteAction
        self.hostAuthBridge = hostAuthBridge
    }

    @State private var loadingTile: String?
    @State private var showIconPicker = false
    @State private var showCustomiser = false
    @State private var showScripts = false
    @ObservedObject private var layoutStore = MachinePanelLayoutStore.shared
    @State private var showActionSheet: RemoteActionDescriptor?
    @State private var showDestructiveConfirm: RemoteActionDescriptor?
    @State private var showResultSheet: (action: RemoteActionDescriptor, result: [String: Any])?
    @State private var showSignInSheet = false
    @State private var hostAuthStatus: HostAuthStatusInfo?
    /// The machine-global active profile shown in the expanded Claude row.
    @State private var activeAccount: ClaudeAccountProfile?
    /// Natural height of the expanded body, reported back by the body itself.
    /// Survives collapse/expand cycles, so only the first expansion of a given
    /// row ever renders against an unmeasured value.
    @State private var expandedContentHeight: CGFloat = 0

    private var isDefault: Bool { machine.machineId == defaultMachineId }

    // Claude-account row state. Nil status = not fetched yet; keep the row
    // neutral rather than implying anything about the host's sign-in.
    private var claudeAccountIcon: String {
        guard let status = hostAuthStatus else { return "person.badge.key" }
        return status.loggedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
    }

    private var claudeAccountLabel: String {
        if let account = activeAccount {
            let email = account.email ?? hostAuthStatus?.email
            if let email, !email.isEmpty {
                return account.isDefault ? "Claude: \(email)" : "Claude: \(account.name) (\(email))"
            }
            return account.isDefault ? "Claude: signed in" : "Claude: \(account.name)"
        }
        guard let status = hostAuthStatus else { return "Claude Account" }
        if status.loggedIn {
            return status.email.map { "Claude: \($0)" } ?? "Claude: signed in"
        }
        return "Claude: not signed in"
    }

    private var claudeAccountTint: Color {
        guard let status = hostAuthStatus else { return .secondary }
        return status.loggedIn ? .green : .orange
    }

    @State private var showCodexAccounts = false
    @State private var showHostSettings = false

    private func refreshHostAuthStatus() {
        guard let hostAuthBridge, machine.isOnline, !isMachineDisabled else { return }
        Task {
            async let statusFetch = hostAuthBridge.fetchHostAuthStatus(machineId: machine.machineId)
            async let accountsFetch = hostAuthBridge.fetchClaudeAccounts(machineId: machine.machineId)
            let (status, accounts) = await (statusFetch, accountsFetch)
            hostAuthStatus = status
            activeAccount = accounts.accounts.first { $0.slug == accounts.active }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                expandedBody
            }
        }
        .onChange(of: isExpanded) { expanded in
            if expanded && machine.isOnline && !isMachineDisabled {
                onDiscoverActions?(machine)
                refreshHostAuthStatus()
            }
            if !expanded { loadingTile = nil }
        }
        .onAppear {
            refreshHostAuthStatus()
        }
        .onChange(of: activeSessions.count) { _ in
            loadingTile = nil
        }
        .onChange(of: isConnecting) { connecting in
            if !connecting { loadingTile = nil }
        }
        .sheet(isPresented: $showIconPicker) {
            MachineIconPicker(
                machineName: machine.displayName,
                currentIcon: machineIcon
            ) { icon in
                onSetIcon?(icon)
            }
        }
        .sheet(isPresented: $showCustomiser) {
            MachinePanelCustomiserSheet(
                machineId: machine.machineId,
                machineName: machine.displayName,
                entries: panelEntries
            )
        }
        .sheet(isPresented: $showScripts) {
            if let hostAuthBridge {
                // A saved or deleted script changes the tiles, so re-read the
                // catalog now rather than on the next expand.
                HostScriptsSheet(machine: machine, bridge: hostAuthBridge) {
                    onDiscoverActions?(machine)
                }
            }
        }
        .sheet(isPresented: $showCodexAccounts) {
            if let hostAuthBridge {
                CodexAccountSwitcherSheet(machineId: machine.machineId, machineName: machine.displayName,
                    direct: machine.meta?["connection"] == "direct", bridge: hostAuthBridge)
            }
        }
        .sheet(isPresented: $showHostSettings) {
            if let hostAuthBridge {
                HostSettingsSheet(machineId: machine.machineId, machineName: machine.displayName, bridge: hostAuthBridge)
            }
        }
        .sheet(isPresented: $showSignInSheet, onDismiss: { refreshHostAuthStatus() }) {
            if let hostAuthBridge {
                ClaudeAccountSwitcherSheet(machine: machine, bridge: hostAuthBridge) { _ in
                    refreshHostAuthStatus()
                }
            }
        }
        .sheet(item: $showActionSheet) { action in
            RemoteActionSheet(action: action) { params in
                guard let onExecuteAction else {
                    return ["status": "error", "error": "Execute not available"]
                }
                return await onExecuteAction(action, params)
            }
        }
        .sheet(isPresented: Binding(
            get: { showResultSheet != nil },
            set: { if !$0 { showResultSheet = nil } }
        )) {
            if let (action, result) = showResultSheet {
                RemoteActionSheet(action: action, initialResult: result) { params in
                    guard let onExecuteAction else {
                        return ["status": "error", "error": "Execute not available"]
                    }
                    return await onExecuteAction(action, params)
                }
            }
        }
        .alert("Confirm Action",
               isPresented: Binding(
                   get: { showDestructiveConfirm != nil },
                   set: { if !$0 { showDestructiveConfirm = nil } }
               )
        ) {
            Button("Cancel", role: .cancel) { showDestructiveConfirm = nil }
            Button("Execute", role: .destructive) {
                if let action = showDestructiveConfirm {
                    executeDirectAction(action)
                    showDestructiveConfirm = nil
                }
            }
        } message: {
            if let action = showDestructiveConfirm {
                Text("Are you sure you want to run \"\(action.displayName)\"?")
            }
        }
    }

    // MARK: - Header

    /// The row header — formerly the `DisclosureGroup` label.
    ///
    /// The disclosure is gone on purpose. It reported its content's ideal
    /// height as its own and never forwarded a reduced height proposal down, so
    /// wrapping its content in a scroller could not stop the body overflowing
    /// its band (and left a live scroller behind mid-collapse, so the contents
    /// lingered after the row folded). A plain header plus `if isExpanded` —
    /// the `GlassSectionPanel` idiom — makes the body a real, compressible
    /// stack child, and folding removes it from the tree outright.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: machineIcon ?? machine.defaultIconName)
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(machine.displayName)
                            .font(.body)
                            .lineLimit(1)
                            .uiKitIdentifier("MachineRowExpandable.name")
                        if machine.isOnline {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                                .uiKitIdentifier("MachineRowExpandable.onlineDot")
                        }
                    }

                    if isRestarting {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Restarting…")
                                .font(.caption)
                        }
                        .foregroundStyle(.orange)
                    } else if isRestartSucceeded {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                            Text("Restarted")
                                .font(.caption)
                        }
                        .foregroundStyle(.green)
                    } else if isMachineDisabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if !machine.isOnline {
                        Text("Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(activeSessions.isEmpty
                             ? "Online"
                             : "\(activeSessions.count) active \(activeSessions.count == 1 ? "session" : "sessions")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isDefault {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }

                if isConnecting || isRestarting, !quickLaunchAsButton {
                    // Circle mode only. In pill mode this spinner sat directly
                    // beside the "New Session" pill and squeezed its label onto
                    // two lines — the pill now animates itself instead (see
                    // isLaunching below), and a restart already reports in the
                    // subtitle's "Restarting…" row.
                    ProgressView()
                        .controlSize(.small)
                }

                // The lone "New Session" button rides the header row: one pill
                // doesn't squeeze the machine name the way the user-sized
                // circle set did (which is why the circles keep their own row
                // below). It sits inside the header's tap target, but Button
                // hit-testing takes the tap over the row's onTapGesture, so
                // launching never toggles the row.
                if showsQuickLaunch && quickLaunchAsButton {
                    quickLaunchStrip
                }

                // Same chevron vocabulary as GlassSectionPanel's header rather
                // than the system disclosure's tinted one, so the solo panel
                // and the Sessions / Folders panels read as the same control.
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    .uiKitIdentifier("MachineRowExpandable.chevron")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                #if os(iOS)
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                #endif
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }

            // The circles stay on their own row, indented to the text column:
            // the set is user-sized and would otherwise squeeze the machine
            // name to nothing. Outside the header's tap target, so launching
            // a shortcut never toggles the row.
            if showsQuickLaunch && !quickLaunchAsButton {
                quickLaunchStrip
                    .padding(.leading, 40)
            }
        }
        .padding(.vertical, 2)
        .opacity(machine.isOnline && !isMachineDisabled ? 1 : 0.5)
    }

    /// The quick-launch affordance, shared by the header-trailing pill and the
    /// circles' own row so the two placements can't drift. Same component and
    /// icon vocabulary as the collapsed panel header's strip in
    /// `GlassSessionsList`.
    private var quickLaunchStrip: some View {
        ModelLoadingReader(hostAuthBridge?.modelLoading ?? .idle) { modelsLoading in
        QuickLaunchStrip(
            targets: quickLaunchTargets,
            machine: machine,
            loadingId: $loadingTile,
            identifierPrefix: "MachineRowExpandable",
            onNewCliSession: onNewCliSession,
            onNewApiSession: onNewApiSession,
            allTargets: quickLaunchAllTargets,
            cache: quickLaunchCache,
            modelsLoading: modelsLoading,
            modelsError: hostAuthBridge?.lastModelsError,
            onRetryModels: hostAuthBridge.map { bridge in { Task { await bridge.fetchModels() } } },
            showCircles: quickLaunchShowCircles,
            // `loadingTile` covers a launch tapped on this row; `isConnecting`
            // covers the machine-level connect that follows (and any connect
            // started elsewhere), so the pill keeps pulsing until the session
            // actually exists.
            isLaunching: loadingTile != nil || isConnecting,
            // Long-press the New Session pill → the account switcher. Same
            // sheet as the expanded row's Claude account row.
            onSwitchAccount: hostAuthBridge != nil ? { showSignInSheet = true } : nil,
            onSwitchCodexAccount: hostAuthBridge != nil ? { showCodexAccounts = true } : nil
        )
        }
    }

    /// When the strip shows at all: on folded rows (or always, when the row IS
    /// the solo machine panel), and only when the row is actionable — a dimmed
    /// row must not offer live launch buttons.
    private var showsQuickLaunch: Bool {
        (!isExpanded || alwaysShowQuickLaunch) && machine.isOnline && !isMachineDisabled
    }

    /// True when the strip is the single "New Session" button rather than the
    /// circle set: the circles are gated off AND the picker exists to replace
    /// them. Mirrors `QuickLaunchStrip.effectiveShowCircles`.
    private var quickLaunchAsButton: Bool {
        !quickLaunchShowCircles && quickLaunchCache != nil
    }

    // MARK: - Expanded body

    /// The expanded body, bounded above so it can never overflow its stack.
    ///
    /// The panel stack hosting this row has no scroll container: Sessions gets
    /// away with a greedy `List` and Folders caps its own scroller, but this
    /// body is ~600-700pt of tiles and rows, and it GROWS after it opens —
    /// remote actions and the host's Claude-account status both arrive async on
    /// expand. So the height is not knowable at expand time and a body that fit
    /// a moment ago may not fit now.
    ///
    /// Hence a `maxHeight` and not a `height`. An explicit `.frame(height:)`
    /// pins the ScrollView to exactly that size and makes it INFLEXIBLE: if the
    /// number turns out to be too big for the room actually available, the
    /// stack has no way to compress it and the whole stack overflows — which is
    /// exactly how this bled into the safe area on the previous attempt. As an
    /// upper bound the ScrollView keeps its natural minimum of 0, so the stack
    /// squeezes it as much as it needs to, while the ceiling stops it from
    /// claiming room it doesn't need.
    private var expandedBody: some View {
        ScrollView {
            expandedContent
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: MachineExpandedHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .frame(maxHeight: expandedHeightCeiling)
        // Scrolling stays ENABLED at all times. Gating it on the measured
        // height (`scrollDisabled(measured <= cap)`) deadlocks against dynamic
        // content: the body grows after the measurement that turned scrolling
        // off, and there is then no way to reach the part that no longer fits.
        // `.basedOnSize` gets the same "don't rubber-band when it fits" result
        // from the live layout instead of from a stale number.
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(MachineExpandedHeightKey.self) { height in
            expandedContentHeight = height
        }
        .onChange(of: expandedContentHeight) { height in
            RipulLog.log("[SOLOPANEL] row=\(machine.displayName) content=\(Int(height)) "
                + "cap=\(maxExpandedHeight.map { String(Int($0)) } ?? "nil") "
                + "ceiling=\(expandedHeightCeiling.map { String(Int($0)) } ?? "nil")")
        }
    }

    /// Upper bound for the expanded body: its own natural height, further held
    /// to whatever ceiling the parent supplied.
    ///
    /// Nil means "don't constrain" — used while the body is still unmeasured,
    /// because binding `maxHeight` to a measurement of 0 would collapse the
    /// body to nothing and it could never measure itself back open.
    private var expandedHeightCeiling: CGFloat? {
        let natural: CGFloat? = expandedContentHeight > 0 ? expandedContentHeight : nil
        switch (natural, maxExpandedHeight) {
        case let (natural?, cap?): return min(natural, cap)
        case let (natural?, nil): return natural
        case let (nil, cap?): return cap
        case (nil, nil): return nil
        }
    }

    /// Tiles, then compact rows — whichever the layout put where, in its order.
    private var expandedContent: some View {
        let layout = layoutStore.layout(for: machine.machineId)
        let visible = panelEntries
            .filter { $0.available && !$0.isHidden(in: layout) }
            .ordered(by: layout)
        let tiles = visible.filter { $0.placement(in: layout) == .tile }
        let rows = visible.filter { $0.placement(in: layout) == .row }
        let tileRows = stride(from: 0, to: tiles.count, by: 2).map { start in
            Array(tiles[start..<min(start + 2, tiles.count)])
        }

        return VStack(spacing: 10) {
            // Laid out non-lazily on purpose. A LazyVGrid only materialises the
            // rows it believes are visible, so the height it reports back
            // through MachineExpandedHeightKey would depend on the clamp that is
            // derived FROM that height — a measurement loop. At most a handful
            // of tiles, so laziness buys nothing.
            if !tileRows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(Array(tileRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            ForEach(row) { entry in
                                MachineActionTile(
                                    icon: entry.icon,
                                    label: entry.label,
                                    subtitle: entry.subtitle,
                                    tint: entry.tint,
                                    isLoading: entry.isLoading,
                                    isSucceeded: entry.isSucceeded,
                                    loadingLabel: entry.loadingLabel,
                                    succeededLabel: entry.succeededLabel,
                                    action: entry.action
                                )
                            }
                            // Odd tile count: hold the empty half so the last
                            // tile keeps its column width instead of stretching
                            // across the whole row.
                            if row.count == 1 {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }

            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows) { entry in
                        MachineActionRow(
                            icon: entry.icon,
                            label: entry.label,
                            tint: entry.tint,
                            isLoading: entry.isLoading,
                            isSucceeded: entry.isSucceeded,
                            loadingLabel: entry.loadingLabel,
                            succeededLabel: entry.succeededLabel,
                            action: entry.action
                        )
                    }
                }
                .modifier(GlassTileBackground())
            }
        }
        .padding(.top, 8)
    }

    /// Everything the body can draw, in shipped order and placement. The
    /// layout reorders, re-places and hides these; `available` is the gate the
    /// body used to express as scattered `if`s.
    private var panelEntries: [MachinePanelEntry] {
        let actionable = machine.isOnline && !isMachineDisabled
        var entries: [MachinePanelEntry] = []

        entries.append(MachinePanelEntry(
            id: "builtin:newAgent",
            icon: "plus.message.fill",
            label: "New Agent",
            subtitle: "Start a fresh Ripul agent",
            tint: .blue,
            defaultPlacement: .tile,
            available: actionable && createNewChat == nil && allowRipulAgents,
            isLoading: loadingTile == "newAgent",
            loadingLabel: "Connecting…"
        ) {
            loadingTile = "newAgent"
            onConnect()
        })

        // CLI provider tiles (driven by providers.json)
        for provider in ProviderConstants.cliProviders {
            guard let providerKey = provider.providerKey else { continue }
            entries.append(MachinePanelEntry(
                id: "cli:\(providerKey)",
                icon: provider.sfSymbol,
                label: provider.label,
                subtitle: "Start a new remote \(provider.label) session",
                tint: Color(hex: provider.color),
                defaultPlacement: .tile,
                available: actionable && createNewChat == nil && onNewCliSession != nil,
                isLoading: loadingTile == provider.id,
                loadingLabel: "Connecting…"
            ) {
                loadingTile = provider.id
                // Harness tile: no model named, so the provider default
                // stands. The model-aligned shortcuts live in the folded strip.
                onNewCliSession?(machine, providerKey, nil)
            })
        }

        // Host-advertised actions. The host's own emphasis is the default
        // placement; a user override outranks it.
        for action in remoteActions {
            entries.append(MachinePanelEntry(
                id: "action:\(action.id)",
                icon: action.icon ?? "bolt",
                label: action.displayName,
                subtitle: action.description,
                tint: action.destructive ? .red : (action.isPrimary ? .cyan : .secondary),
                defaultPlacement: action.isPrimary ? .tile : .row,
                available: actionable,
                isLoading: loadingTile == action.id,
                loadingLabel: "Running…"
            ) {
                handleRemoteAction(action)
            })
        }

        // Claude account — phone-driven host sign-in. The label carries live
        // status so an unauthenticated host reads as needing attention.
        entries.append(MachinePanelEntry(
            id: "builtin:claudeAccount",
            icon: claudeAccountIcon,
            label: claudeAccountLabel,
            subtitle: "Sign the host in or switch account",
            tint: claudeAccountTint,
            defaultPlacement: .row,
            available: actionable && hostAuthBridge != nil
        ) {
            showSignInSheet = true
        })

        entries.append(MachinePanelEntry(
            id: "builtin:codexAccounts",
            icon: "person.2",
            label: "Codex accounts",
            subtitle: "Switch the host’s Codex account",
            tint: .secondary,
            defaultPlacement: .row,
            available: actionable && hostAuthBridge != nil
        ) {
            showCodexAccounts = true
        })

        // The Mac's own settings. Relay only: direct pairing deliberately
        // carries no settings, and a team host's settings are its owner's.
        entries.append(MachinePanelEntry(
            id: "builtin:hostSettings",
            icon: "gearshape",
            label: "Host Settings",
            subtitle: "Working folder, CLI and power settings",
            tint: .secondary,
            defaultPlacement: .row,
            available: actionable && hostAuthBridge != nil
                && machine.meta?["connection"] != "direct" && machine.teamId == nil
        ) {
            showHostSettings = true
        })

        entries.append(MachinePanelEntry(
            id: "builtin:scripts",
            icon: "chevron.left.forwardslash.chevron.right",
            label: "Edit Scripts",
            subtitle: "Write and edit this host’s scripts",
            tint: .cyan,
            defaultPlacement: .row,
            available: actionable && hostAuthBridge != nil
        ) {
            showScripts = true
        })

        entries.append(MachinePanelEntry(
            id: "builtin:restart",
            icon: "arrow.triangle.2.circlepath",
            label: "Restart Host",
            subtitle: "Relaunch the host app",
            tint: .orange,
            defaultPlacement: .row,
            // Stays through a restart so progress and result stay visible even
            // once the machine has dropped offline.
            available: (actionable && onRestart != nil) || isRestarting || isRestartSucceeded,
            isLoading: isRestarting,
            isSucceeded: isRestartSucceeded,
            loadingLabel: "Restarting…",
            succeededLabel: "Restarted"
        ) {
            onRestart?(machine)
        })

        entries.append(MachinePanelEntry(
            id: "builtin:setDefault",
            icon: isDefault ? "star.fill" : "star",
            label: isDefault ? "Default Machine" : "Set as Default",
            subtitle: "Use this machine for new sessions",
            tint: .yellow,
            defaultPlacement: .row
        ) {
            onSetDefault?(isDefault ? "" : machine.machineId)
        })

        entries.append(MachinePanelEntry(
            id: "builtin:setIcon",
            icon: machineIcon ?? "photo.on.rectangle",
            label: "Set Icon",
            subtitle: "Pick this machine’s icon",
            tint: .purple,
            defaultPlacement: .row
        ) {
            showIconPicker = true
        })

        entries.append(MachinePanelEntry(
            id: "builtin:customise",
            icon: "slider.horizontal.3",
            label: "Customise Panel",
            subtitle: "Reorder, resize and hide these",
            tint: .secondary,
            defaultPlacement: .row,
            // Hiding the way back into the editor would strand the layout.
            essential: true,
            fixedPlacement: true
        ) {
            showCustomiser = true
        })

        if let onToggleDisabled {
            entries.append(MachinePanelEntry(
                id: "builtin:toggleDisabled",
                icon: isMachineDisabled ? "checkmark.circle" : "nosign",
                label: isMachineDisabled ? "Enable" : "Disable",
                subtitle: isMachineDisabled ? "Show this machine’s actions" : "Hide this machine’s actions",
                tint: isMachineDisabled ? .green : .red,
                defaultPlacement: .row,
                // A disabled machine shows almost nothing else, so this must
                // always be there to undo it.
                essential: true
            ) {
                onToggleDisabled(machine)
            })
        }

        return entries
    }

    private func handleRemoteAction(_ action: RemoteActionDescriptor) {
        let hasParams = {
            guard let props = action.inputSchema["properties"] as? [String: Any] else { return false }
            return !props.isEmpty
        }()

        if hasParams {
            // Open parameter sheet
            showActionSheet = action
        } else if action.destructive {
            // Show confirmation
            showDestructiveConfirm = action
        } else {
            // Execute immediately
            executeDirectAction(action)
        }
    }

    private func executeDirectAction(_ action: RemoteActionDescriptor) {
        guard let onExecuteAction else { return }
        loadingTile = action.id
        Task {
            let result = await onExecuteAction(action, [:])
            loadingTile = nil
            showResultSheet = (action: action, result: result)
        }
    }
}

// MARK: - Expanded body measurement

/// Natural height of the expanded machine body, reported up from inside the
/// scroller so the row can clamp itself to the ceiling its parent handed down.
private struct MachineExpandedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Machine Action Tile

private struct MachineActionTile: View {
    let icon: String
    let label: String
    let subtitle: String
    var tint: Color = .blue
    var isLoading: Bool = false
    // Any entry can now be placed as a tile, so the tile carries the same
    // transient labels the row does: a Restart moved into the grid must still
    // say "Restarting…" and "Restarted".
    var isSucceeded: Bool = false
    var loadingLabel: String? = nil
    var succeededLabel: String? = nil
    let action: () -> Void

    private var displayLabel: String {
        if isLoading { return loadingLabel ?? label }
        if isSucceeded { return succeededLabel ?? label }
        return label
    }

    public var body: some View {
        Button {
            if !isLoading && !isSucceeded { action() }
        } label: {
            VStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(tint)
                        .frame(height: 22)
                } else if isSucceeded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(tint)
                }
                VStack(spacing: 2) {
                    Text(displayLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(isSucceeded ? .green : .primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 90)
            .opacity(isLoading ? 0.7 : 1)
            .modifier(GlassTileBackground())
        }
        .buttonStyle(.plain)
        .disabled(isLoading || isSucceeded)
    }
}

// MARK: - Machine Action Row (compact, de-emphasized)

private struct MachineActionRow: View {
    let icon: String
    let label: String
    var tint: Color = .secondary
    var isLoading: Bool = false
    var isSucceeded: Bool = false
    var loadingLabel: String? = nil
    var succeededLabel: String? = nil
    let action: () -> Void

    private var displayLabel: String {
        if isLoading, let l = loadingLabel { return l }
        if isSucceeded, let l = succeededLabel { return l }
        return label
    }

    public var body: some View {
        Button {
            if !isLoading && !isSucceeded { action() }
        } label: {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                        .frame(width: 18, height: 18)
                } else if isSucceeded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.green)
                        .frame(width: 18)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                }
                Text(displayLabel)
                    .font(.subheadline)
                    .foregroundStyle(isSucceeded ? .green : .primary)
                Spacer()
                if !isLoading && !isSucceeded {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .opacity(isLoading ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isLoading || isSucceeded)
    }
}

// MARK: - Glass Tile Background

private struct GlassTileBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 14))
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                }
        }
        #else
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 14))
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                }
        }
        #endif
    }
}
