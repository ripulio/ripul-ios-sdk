import SwiftUI

// MARK: - Machine Row (Expandable)

/// Expandable machine row: header (name, online status, active-session count,
/// default star, folded quick-launch CLI buttons) with a disclosure body
/// offering New-Agent / new-CLI-session tiles and machine settings (restart,
/// set default, set icon, enable/disable).
///
/// The app's version also hosts a "remote actions" (scripts) grid + execution
/// sheet; that quick-actions feature is deferred and is not present here.
///
/// Cache-derived values (`allowRipulAgents`, `machineIcon`, `isMachineDisabled`,
/// `defaultMachineId`) are resolved by the parent — which owns the
/// `RipulSessionCache` — and passed in, with `onSetDefault` / `onSetIcon`
/// callbacks writing back through the same cache.
public struct MachineRowExpandable: View {
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
    /// Start a machine-free API chat pinned to a catalog model id.
    var onNewApiSession: ((String) -> Void)? = nil
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
        onNewApiSession: ((String) -> Void)? = nil,
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
    @State private var showActionSheet: RemoteActionDescriptor?
    @State private var showDestructiveConfirm: RemoteActionDescriptor?
    @State private var showResultSheet: (action: RemoteActionDescriptor, result: [String: Any])?
    @State private var showSignInSheet = false
    @State private var hostAuthStatus: HostAuthStatusInfo?
    /// The machine-global active profile, so the account in use is visible on
    /// the row itself (collapsed subtitle + expanded Claude row) without
    /// drilling into the switcher sheet.
    @State private var activeAccount: ClaudeAccountProfile?
    /// Natural height of the expanded body, reported back by the body itself.
    /// Survives collapse/expand cycles, so only the first expansion of a given
    /// row ever renders against an unmeasured value.
    @State private var expandedContentHeight: CGFloat = 0

    private var isDefault: Bool { machine.machineId == defaultMachineId }

    private var primaryActions: [RemoteActionDescriptor] {
        remoteActions.filter { $0.isPrimary }
    }

    private var secondaryActions: [RemoteActionDescriptor] {
        remoteActions.filter { !$0.isPrimary }
    }

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
            // The collapsed subtitle carries the active account — a glanceable
            // answer to "which account will pay?", so it has to be fetched for
            // folded rows too, not only on expand.
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
                        // The account in use, visible without expanding: the
                        // common pre-launch check is "which account will pay
                        // for this session?", and that answer must not be a
                        // drill-down away.
                        if let account = activeAccount {
                            Label(account.isDefault ? (account.email ?? "Default") : account.name, systemImage: "person.crop.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .uiKitIdentifier("MachineRowExpandable.activeAccount")
                        }
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
        QuickLaunchStrip(
            targets: quickLaunchTargets,
            machine: machine,
            loadingId: $loadingTile,
            identifierPrefix: "MachineRowExpandable",
            onNewCliSession: onNewCliSession,
            onNewApiSession: onNewApiSession,
            allTargets: quickLaunchAllTargets,
            cache: quickLaunchCache,
            showCircles: quickLaunchShowCircles,
            // `loadingTile` covers a launch tapped on this row; `isConnecting`
            // covers the machine-level connect that follows (and any connect
            // started elsewhere), so the pill keeps pulsing until the session
            // actually exists.
            isLaunching: loadingTile != nil || isConnecting,
            // Long-press the New Session pill → the account switcher. Same
            // sheet as the expanded row's Claude account row.
            onSwitchAccount: hostAuthBridge != nil ? { showSignInSheet = true } : nil
        )
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
        !quickLaunchShowCircles && quickLaunchCache != nil && !quickLaunchAllTargets.isEmpty
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

    /// Provider tiles, then the compact settings rows.
    private var expandedContent: some View {
        VStack(spacing: 10) {
            // === Primary section: square tiles ===
            //
            // Laid out non-lazily on purpose. A LazyVGrid only materialises the
            // rows it believes are visible, so the height it reports back
            // through MachineExpandedHeightKey would depend on the clamp that is
            // derived FROM that height — a measurement loop. At most a handful
            // of tiles, so laziness buys nothing.
            if !tileRows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(Array(tileRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            ForEach(row) { tile in
                                MachineActionTile(
                                    icon: tile.icon,
                                    label: tile.label,
                                    subtitle: tile.subtitle,
                                    tint: tile.tint,
                                    isLoading: loadingTile == tile.id,
                                    action: tile.action
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

            // === Secondary section: compact rows ===
            VStack(spacing: 0) {
                // Secondary remote actions (intrinsic utilities)
                if machine.isOnline && !isMachineDisabled {
                    ForEach(secondaryActions, id: \.id) { action in
                        MachineActionRow(
                            icon: action.icon ?? "bolt",
                            label: action.displayName,
                            tint: action.destructive ? .red : .secondary,
                            isLoading: loadingTile == action.id
                        ) {
                            handleRemoteAction(action)
                        }
                    }
                }

                // Claude account — phone-driven host sign-in. The label
                // carries live status so an unauthenticated host reads as
                // needing attention without opening the sheet.
                if machine.isOnline && !isMachineDisabled && hostAuthBridge != nil {
                    MachineActionRow(
                        icon: claudeAccountIcon,
                        label: claudeAccountLabel,
                        tint: claudeAccountTint
                    ) {
                        showSignInSheet = true
                    }
                }

                // Restart Host
                if (machine.isOnline && !isMachineDisabled && onRestart != nil) || isRestarting || isRestartSucceeded {
                    MachineActionRow(
                        icon: "arrow.triangle.2.circlepath",
                        label: "Restart Host",
                        tint: .orange,
                        isLoading: isRestarting,
                        isSucceeded: isRestartSucceeded,
                        loadingLabel: "Restarting…",
                        succeededLabel: "Restarted"
                    ) {
                        onRestart?(machine)
                    }
                }

                // Set as Default
                MachineActionRow(
                    icon: isDefault ? "star.fill" : "star",
                    label: isDefault ? "Default Machine" : "Set as Default",
                    tint: .yellow
                ) {
                    onSetDefault?(isDefault ? "" : machine.machineId)
                }

                // Set Icon
                MachineActionRow(
                    icon: machineIcon ?? "photo.on.rectangle",
                    label: "Set Icon",
                    tint: .purple
                ) {
                    showIconPicker = true
                }

                // Disable / Enable
                if let onToggleDisabled {
                    MachineActionRow(
                        icon: isMachineDisabled ? "checkmark.circle" : "nosign",
                        label: isMachineDisabled ? "Enable" : "Disable",
                        tint: isMachineDisabled ? .green : .red
                    ) {
                        onToggleDisabled(machine)
                    }
                }
            }
            .modifier(GlassTileBackground())
        }
        .padding(.top, 8)
    }

    /// The square tiles, flattened from the three sources that used to feed the
    /// grid directly, so they can be chunked into rows without a lazy container.
    private var expandedTiles: [MachineTileSpec] {
        guard machine.isOnline, !isMachineDisabled else { return [] }
        var tiles: [MachineTileSpec] = []

        // New Ripul Agent
        if allowRipulAgents {
            tiles.append(MachineTileSpec(
                id: "newAgent",
                icon: "plus.message.fill",
                label: "New Agent",
                subtitle: "Start a fresh Ripul agent",
                tint: .blue
            ) {
                loadingTile = "newAgent"
                onConnect()
            })
        }

        // CLI provider tiles (driven by providers.json)
        if let newCliAction = onNewCliSession {
            for provider in ProviderConstants.cliProviders {
                guard let providerKey = provider.providerKey else { continue }
                tiles.append(MachineTileSpec(
                    id: provider.id,
                    icon: provider.sfSymbol,
                    label: provider.label,
                    subtitle: "Start a new remote \(provider.label) session",
                    tint: Color(hex: provider.color)
                ) {
                    loadingTile = provider.id
                    // Harness tile: no model named, so the provider default
                    // stands. The model-aligned shortcuts live in the folded
                    // strip.
                    newCliAction(machine, providerKey, nil)
                })
            }
        }

        // Primary remote actions (scripts, user-promoted)
        for action in primaryActions {
            tiles.append(MachineTileSpec(
                id: action.id,
                icon: action.icon ?? "bolt",
                label: action.displayName,
                subtitle: action.description,
                tint: action.destructive ? .red : .cyan
            ) {
                handleRemoteAction(action)
            })
        }

        return tiles
    }

    /// `expandedTiles` in two-column rows.
    private var tileRows: [[MachineTileSpec]] {
        let tiles = expandedTiles
        return stride(from: 0, to: tiles.count, by: 2).map { start in
            Array(tiles[start..<min(start + 2, tiles.count)])
        }
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

/// One square tile in the expanded body, resolved ahead of layout so the tiles
/// can be chunked into explicit rows.
private struct MachineTileSpec: Identifiable {
    let id: String
    let icon: String
    let label: String
    let subtitle: String
    var tint: Color = .blue
    let action: () -> Void
}

private struct MachineActionTile: View {
    let icon: String
    let label: String
    let subtitle: String
    var tint: Color = .blue
    var isLoading: Bool = false
    let action: () -> Void

    public var body: some View {
        Button {
            if !isLoading { action() }
        } label: {
            VStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(tint)
                        .frame(height: 22)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(tint)
                }
                VStack(spacing: 2) {
                    Text(isLoading ? "Connecting…" : label)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
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
        .disabled(isLoading)
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
