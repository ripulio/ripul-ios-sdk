import SwiftUI

// MARK: - Relay Host Stats View

/// Live diagnostics view for the relay host-bridge.
///
/// Polls `bridge.getRelayDiagnostics(roomId: nil)` once per second and renders
/// the freshest pong sample per room. Surfaces the signals needed to tell
/// "host is online" apart from "host is accepting messages":
///
/// - Command frames in vs commands dispatched — a gap means the host received
///   agent commands and dropped them before execution.
/// - Per-chat chain breadcrumbs — names the `await` a stuck chain is hung on.
///
/// Stall thresholds mirror the web watcher in `useHostDiagnostics.ts`: 30s at a
/// setup step, 5 min for a whole turn.
///
/// Accessible via the `/rr.` debug menu → "Relay Host Stats".
@available(iOS 16.0, macOS 13.0, *)
public struct RelayHostStatsView: View {
    var bridge: AgentBridge
    @State private var rooms: [RoomStats] = []
    @State private var selfHost: RoomStats?
    @State private var lastFetchedAt: Date?
    @State private var fetchError: String?
    @State private var bridgeDiagnostics: BridgeDiagnostics = BridgeDiagnostics()
    @State private var commsEntries: [CommsEntry] = []
    /// Routine (info) comms entries are hidden unless asked for: they explain
    /// what happened around a problem, but are not problems themselves.
    @State private var showRoutineComms = false

    /// Optional host-app section rendered right after Bridge diagnostics —
    /// the macOS app slots its persistent restart log in here.
    private let topContent: AnyView?

    public init(bridge: AgentBridge) {
        self.bridge = bridge
        self.topContent = nil
    }

    public init<TopContent: View>(bridge: AgentBridge, @ViewBuilder topContent: () -> TopContent) {
        self.bridge = bridge
        self.topContent = AnyView(topContent())
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                // The verdict first: everything below is evidence for it.
                summaryCard

                // Always-visible diagnostics so the user can see WHY the
                // host bridge is or isn't running, independent of whether
                // there's any room data to render below.
                sectionLabel("This device's relay connection")
                bridgeDiagnosticsCard

                if let topContent {
                    topContent
                }

                if let selfHost {
                    sectionLabel("Commands to this machine")
                    roomCard(selfHost, isSelf: true)
                }

                if !rooms.isEmpty {
                    sectionLabel("Other machines (pinged from here)")
                    ForEach(rooms) { room in
                        roomCard(room)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    sectionLabel("Comms log")
                    Spacer(minLength: 0)
                    if !commsEntries.isEmpty {
                        Button { copyCommsLog() } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        Button { Task { await clearCommsLog() } } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .tint(.red)
                    }
                }
                commsLogCard

                if selfHost == nil && rooms.isEmpty {
                    emptyState
                }
            }
            .padding(12)
        }
        .navigationTitle("Relay Host Stats")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await pollLoop()
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let ts = lastFetchedAt {
                Text("Updated \(Self.timestampFormatter.string(from: ts))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let err = fetchError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var findings: [Finding] {
        StatusSummary.findings(diagnostics: bridgeDiagnostics, selfHost: selfHost, rooms: rooms,
                               comms: commsEntries, now: Date())
    }

    private var summaryCard: some View {
        let all = findings
        let problems = all.filter { $0.level >= .warn }
        let worst = all.map(\.level).max()
        let verdictColor: Color = worst == .error ? .red : worst == .warn ? .orange : (bridgeDiagnostics.hostStatusAvailable == nil ? .secondary : .green)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: problems.isEmpty ? (bridgeDiagnostics.hostStatusAvailable == nil ? "hourglass" : "checkmark.seal.fill")
                                                   : "exclamationmark.triangle.fill")
                    .foregroundStyle(verdictColor)
                Text(problems.isEmpty
                     ? (bridgeDiagnostics.hostStatusAvailable == nil ? "Checking…" : "All clear")
                     : "\(problems.count) thing\(problems.count == 1 ? "" : "s") need\(problems.count == 1 ? "s" : "") attention")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(verdictColor)
            }
            if problems.isEmpty, bridgeDiagnostics.hostStatusAvailable != nil {
                Text(StatusSummary.allClearSentence(diagnostics: bridgeDiagnostics, rooms: rooms, comms: commsEntries, now: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(all) { finding in
                findingRow(finding)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(verdictColor.opacity(0.35), lineWidth: 1))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func findingRow(_ finding: Finding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(finding.level.color)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(finding.level == .info ? .secondary : .primary)
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = finding.action {
                    findingActionButton(action)
                }
            }
        }
    }

    @ViewBuilder
    private func findingActionButton(_ action: FindingAction) -> some View {
        switch action {
        case .retryRelay:
            Button {
                Task { await bridge.retryRelayNow() }
            } label: {
                Label("Retry now", systemImage: "arrow.clockwise")
            }
            .font(.caption)
            .buttonStyle(.borderless)
        case .healWebContext:
            Button {
                Task { await bridge.healWebContext(reason: "manual heal from Relay Host Stats summary", force: true) }
            } label: {
                Label("Heal now", systemImage: "bandage")
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No host bridge or controller pings visible.")
                .foregroundStyle(.secondary)
            Text(bridgeDiagnostics.diagnosis)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Always-visible card that shows the raw responses from
    /// `__ripulGetHostStatus` and `__ripulGetRelayDiagnostics`, plus a
    /// one-line diagnosis. Surfaces *why* the bridge is unhealthy when
    /// no room cards are showing.
    private var bridgeDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: bridgeDiagnostics.statusIcon)
                    .foregroundStyle(bridgeDiagnostics.statusColor)
                Text(bridgeDiagnostics.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(bridgeDiagnostics.statusColor)
            }

            if !bridgeDiagnostics.diagnosis.isEmpty {
                Text(bridgeDiagnostics.diagnosis)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Recovery is automatic now, but the ladder has a floor and a
            // backstop grace — when someone is actually looking at this panel
            // they shouldn't have to wait it out.
            if bridgeDiagnostics.hostStatusAvailable == false {
                HStack(spacing: 12) {
                    Button {
                        // force: the automatic path defers to a load in flight;
                        // someone pressing this button is overriding that.
                        Task { await bridge.healWebContext(reason: "manual heal from Relay Host Stats", force: true) }
                    } label: {
                        Label("Heal now", systemImage: "bandage")
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .help("Run the self-heal ladder (reload, escalating to a state purge). Respects the 10s floor between heals.")

                    Button {
                        bridge.purgeWebStateAndReload()
                    } label: {
                        Label("Purge + reload", systemImage: "trash")
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .tint(.red)
                    .help("Clear localStorage/IndexedDB/caches (cookies kept, so you stay signed in) and fresh-load. This is the manual recovery, unconditional — no floor.")
                }
            }

            Divider()

            if let stability = bridgeDiagnostics.stability {
                VStack(alignment: .leading, spacing: 4) {
                    if let connectedFor = stability.connectedForMs {
                        diagRow("connected for", value: RelayStability.duration(connectedFor))
                    } else if let downFor = stability.downForMs {
                        diagRow("down for", value: "\(RelayStability.duration(downFor)), \(stability.downAttempts) attempt(s)",
                                color: bridgeDiagnostics.statusColor == .secondary ? nil : bridgeDiagnostics.statusColor)
                    }
                    diagRow("drops (5 min / 1 h)", value: "\(stability.dropsLast5m) / \(stability.dropsLast1h)",
                            color: stability.dropsLast5m >= RelayStability.unstableDrops ? .orange : nil)
                    diagRow("last drop", value: stability.lastDropSummary)
                    if let build = bridgeDiagnostics.build {
                        diagRow("web build", value: build, mono: true)
                    }
                }
            }

            DisclosureGroup("Raw values") {
            VStack(alignment: .leading, spacing: 4) {
                diagRow("getHostStatus.available", value: bridgeDiagnostics.hostStatusAvailable.map { $0 ? "true" : "false" } ?? "—",
                        color: (bridgeDiagnostics.hostStatusAvailable == false) ? .red : nil)
                if let err = bridgeDiagnostics.hostStatusError {
                    diagRow("getHostStatus.error", value: err, color: .red, mono: true)
                }
                if let health = bridgeDiagnostics.probeHealth {
                    diagRow("jsContext.probe", value: health, color: health == "healthy" ? nil : .red, mono: true)
                }
                if let digest = bridgeDiagnostics.probeDigest {
                    diagRow("jsContext.detail", value: digest, mono: true)
                }
                diagRow("hostEnabled", value: bridgeDiagnostics.hostEnabled.map { $0 ? "true" : "false" } ?? "—",
                        color: (bridgeDiagnostics.hostEnabled == false) ? .orange : nil)
                diagRow("registered", value: bridgeDiagnostics.registered.map { $0 ? "true" : "false" } ?? "—",
                        color: (bridgeDiagnostics.registered == false) ? .orange : nil)
                diagRow("relayState", value: bridgeDiagnostics.relayState ?? "—",
                        color: (bridgeDiagnostics.relayState != nil && bridgeDiagnostics.relayState != "connected"
                                && bridgeDiagnostics.statusColor != .secondary) ? bridgeDiagnostics.statusColor : nil)
                diagRow("roomId", value: bridgeDiagnostics.roomId ?? "—", mono: true)
                diagRow("machineName", value: bridgeDiagnostics.machineName ?? "—", mono: true)
                diagRow("machineId", value: bridgeDiagnostics.machineId ?? "—", mono: true)

                Divider().padding(.vertical, 2)

                diagRow("getRelayDiagnostics.available", value: bridgeDiagnostics.diagAvailable.map { $0 ? "true" : "false" } ?? "—",
                        color: (bridgeDiagnostics.diagAvailable == false) ? .red : nil)
                if let err = bridgeDiagnostics.diagError {
                    diagRow("getRelayDiagnostics.error", value: err, color: .red, mono: true)
                }
                diagRow("rooms returned", value: "\(bridgeDiagnostics.diagRoomsCount)")
            }
            .padding(.top, 4)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(bridgeDiagnostics.statusColor.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func diagRow(_ label: String, value: String, color: Color? = nil, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)
            Text(value)
                .font(mono ? .system(.caption2, design: .monospaced) : .caption2)
                .foregroundStyle(color ?? .primary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
    }

    @ViewBuilder
    private func roomCard(_ room: RoomStats, isSelf: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                healthBadge(room.health)
                Text(room.title)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let rtt = room.rttMs {
                    Text("\(rtt) ms")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if let reason = room.health.detail {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(room.health.color)
            }

            Divider()

            statsGrid(room)

            if room.totalBacklog > 0 {
                Divider()
                queueBacklogList(room.queueDepth, total: room.totalBacklog)
            }

            if !room.inFlight.isEmpty {
                Divider()
                inFlightList(room.inFlight, room: room, now: room.sampleAt)
            }

            if !room.chainSteps.isEmpty {
                Divider()
                chainStepList(room.chainSteps, now: room.sampleAt)
            }

            if let peaks = room.peaks {
                Divider()
                peaksSection(peaks, isSelf: isSelf, now: room.sampleAt)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(room.health.color.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func healthBadge(_ health: HealthStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(health.color)
                .frame(width: 8, height: 8)
            Text(health.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(health.color)
            infoIcon("""
            HEALTHY — no dropped commands and no stalled turns. An idle host is healthy: pings and self-echo raise 'Frames in' without any commands, and that is expected.

            WEDGED — in the last 2 minutes, a command from another device reached the host and was dropped without running (bridge disabled, relay not connected at that moment, or background API missing). This is the 'host looks online but won't accept messages' failure. The comms log says which check dropped it.

            STALLED — a turn is stuck: 30s+ at a setup step (loading the chat, saving the message, resolving the model), or 5+ minutes without producing anything while not waiting for you. Same rules the host itself uses to log setup-stall / stuck.

            NOT ANSWERING — two or more pings in a row failed while the machine list still shows the machine online.

            OFFLINE (grey) — pings fail and the machine list agrees the machine is offline: asleep or shut down, which is not a fault.

            Hosts on an older web build don't report command frames, so WEDGED can't be detected for them.
            """)
        }
    }

    @ViewBuilder
    private func statsGrid(_ room: RoomStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statRow(
                "Frames in",
                value: "\(room.framesReceived)",
                detail: room.framesSinceLastSample.map { "+\($0) since last" },
                tooltip: """
                Lifetime count of chat frames this host's WebSocket has received since the bridge mounted. Counted imperatively in the onMessage handler BEFORE any filtering or React involvement.

                Includes every inbound message: real agent commands, liveness pings, self-echo of the host's own outbound events (every streamed turn event comes back), and control traffic.

                So this climbing while 'Commands drained' stays flat is normal — an idle host being pinged does exactly that. Compare 'Command frames in' instead.
                """
            )
            statRow(
                "Command frames in",
                value: room.commandFramesReceived.map { "\($0)" } ?? "—",
                detail: room.commandFramesSinceLastSample.map { "+\($0) since last" },
                valueColor: (room.droppedSinceLastSample ?? 0) > 0 ? .orange : nil,
                tooltip: """
                Agent commands from other devices that reached the host's inbound handler, counted BEFORE the checks that can drop them (bridge enabled, relay connected, background API present).

                Should advance in step with 'Commands drained'. When this rises and 'Commands drained' doesn't, the host is receiving commands and dropping them — that is the WEDGED state.

                '—' means the host is on a web build that doesn't report this counter.
                """
            )
            if let dropped = room.droppedTotal {
                statRow(
                    "Commands dropped",
                    value: "\(dropped)",
                    detail: room.recentlyDropped ? "latest within 2 min" : nil,
                    valueColor: dropped > 0 ? .orange : nil,
                    tooltip: """
                    Commands that reached this host and were dropped without being run or answered, since its page loaded: 'Command frames in' minus 'Commands drained'. Both are exact counters, so anything above 0 is real.

                    The comms log names the check that dropped each one (command-dropped). The card shows WEDGED for 2 minutes after the latest drop.
                    """
                )
            }
            statRow(
                "Commands drained",
                value: "\(room.messagesReceived)",
                detail: room.messagesSinceLastSample.map { "+\($0) since last" },
                tooltip: """
                Lifetime count of agent commands that were dispatched to a handler — frames that passed every filter (not the host's own clientId, not a ping, a valid agent command) and every gate (bridge enabled, relay connected, background API present).

                Climbs in step with 'Command frames in'. Pings and self-echo never count here, so an idle host sits flat.
                """
            )
            statRow(
                "Lifetime skipped frames",
                value: "\(room.frameGap)",
                detail: "frames − commands drained (cumulative)",
                tooltip: """
                Simple derived number: framesReceivedCount − messagesReceivedCount. 'Skipped' not in a queue sense — both counters are monotonic lifetime totals, neither decreases, this gap never drains to zero.

                Represents every frame that arrived but was intentionally not dispatched as a command: self-echo of your own outbound events (same clientId), host:ping answered by the imperative fast-path, peer:queryResponse handled separately, peer roster frames, and anything that fails the agent-command type guards.

                Climbing = normal (pings and streamed events echo back). It says nothing about a wedge — compare 'Command frames in' with 'Commands drained' for that.
                """
            )
            statRow(
                "Last frame in",
                value: ageString(room.lastMessagesEffectRanTs, now: room.sampleAt),
                tooltip: """
                Time since the host's inbound handler last saw ANY chat frame — pings and self-echo included. Commands are dispatched straight from that handler (no React effect in the path), so this is simply 'when did the relay last deliver something to this host'.

                A long age while other devices are connected means delivery to the host has stopped (the host rebuilds its socket itself when that happens — see 'host-self-heal' in the comms log). A long age with nobody connected is just a quiet room.
                """
            )
            statRow(
                "Command last received",
                value: ageString(room.lastCommandReceivedTs, now: room.sampleAt),
                tooltip: """
                Time since the host last received a host:ping or a dispatched agent command.

                Stays fresh from pings alone, so it proves the host answers — not that commands are getting through. Use 'Command frames in' vs 'Commands drained' for that.
                """
            )
            statRow(
                "Command last completed",
                value: ageString(room.lastCommandCompletedTs, now: room.sampleAt),
                tooltip: """
                Time since the last agent:start or agent:resume execution chain finished — either success or caught error. 'null' means no agent turn has completed since the host bridge mounted.

                A long age here while 'Pending chains' > 0 can be a hung chain, or just a long turn. The 'In-flight commands' and 'Chain breadcrumbs' lists below turn orange only past the stall thresholds.
                """
            )
            statRow(
                "Pending chains",
                value: "\(room.pendingCommandCount)",
                tooltip: """
                Count of distinct chatIds that currently have an active per-chat execution chain (running or queued). Each chat queues sequentially but different chats run in parallel, so this is NOT the total queue depth — it's the number of chats with any work.

                Grows and never drops = chain promise leak. Cross-reference with 'In-flight commands' below for the per-chat age.
                """
            )
            statRow(
                "Mount age",
                value: ageString(room.mountEpoch, now: room.sampleAt),
                tooltip: """
                Time since useRelayAgentBridge first mounted in the current document. Only changes on a full hook remount: page reload, WKWebView recreate, signed-out-and-back-in.

                Compare between polls: if this resets, the bridge was torn down and rebuilt. That masks a wedge by resetting all the lifetime counters — which is why 'pending chains stuck at N' after a remount doesn't mean the same N commands are still hung; they're gone. Useful for distinguishing 'the bridge crashed and recovered' from 'the bridge is still sick'.
                """
            )
        }
    }

    @ViewBuilder
    private func statRow(
        _ label: String,
        value: String,
        detail: String? = nil,
        valueColor: Color? = nil,
        tooltip: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            infoIcon(tooltip)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(valueColor ?? .primary)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func infoIcon(_ tooltip: String) -> some View {
        // Bare Image().help(...) inside a ScrollView often has its hover
        // swallowed by the scroller's tracking area on macOS, so .help()
        // alone can fail silently. Wrap in a plain Button so the hit region
        // belongs to an interactive view, and add a tap-driven .popover as
        // a guaranteed fallback that works on both platforms.
        InfoIcon(tooltip: tooltip)
    }

    @ViewBuilder
    private func inFlightList(_ cmds: [InFlightRow], room: RoomStats, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("In-flight commands")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                infoIcon("""
                Per-chat list of agent commands currently being executed on the host. An entry appears when a command (agent:start or agent:resume) enters its execution chain and is removed when the chain's finally block fires.

                Age shown per row is how long the command has been running. Agent turns routinely run for many minutes, so a row turns orange only when the turn is stalled: 30s+ at a setup step (see 'Chain breadcrumbs'), or 5+ minutes without producing anything while not waiting for you. 'active … ago' is its last sign of life.
                """)
            }
            ForEach(cmds) { cmd in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(cmd.kind)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 90, alignment: .leading)
                    Text(cmd.chatId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if cmd.awaitingInput {
                        Text("waiting for you")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if let last = cmd.lastActivityAt {
                        Text("active \(ageString(last, now: now)) ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(ageString(cmd.startedAt, now: now))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(room.stallReason(for: cmd) != nil ? .orange : .secondary)
                }
            }
        }
    }

    private func inFlightFor(_ chatId: String) -> InFlightRow? {
        (selfHost?.inFlight ?? []).first { $0.chatId == chatId }
            ?? rooms.lazy.flatMap(\.inFlight).first { $0.chatId == chatId }
    }

    @ViewBuilder
    private func chainStepList(_ steps: [ChainStepRow], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Chain breadcrumbs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                infoIcon("""
                Per-chat breadcrumb of the most recent await boundary inside the execution chain. Setup steps: queued, chain-entered, ensureChatLoaded, initializeChatActions, saveUserMessage, ensureChatTab, getModelById. Turn steps: executeAgentWithPrompt (agent:start), resumeWithContext (agent:resume). Cleared when the chain's finally fires. Age is time at THIS step.

                Setup steps settle in a few seconds, so a row turns orange at 30s — that await is hung ('ensureChatLoaded' points at IndexedDB, 'getModelById' at the model API). Turn steps are the agent actually working and turn orange only after 5 min with no sign of life, never while the turn waits for you.
                """)
            }
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(step.step)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 140, alignment: .leading)
                    Text(step.chatId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(ageString(step.ts, now: now))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(RoomStats.isStepStalled(step, now: now, inFlight: inFlightFor(step.chatId)) ? .orange : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func queueBacklogList(_ rows: [QueueDepthRow], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Queue backlog")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                infoIcon("""
                Commands currently QUEUED behind the running turn on a chat — they cannot start until the in-flight turn on that same chat completes. Each chat has its own serial chain, so a backlog on one chat does not hold up others.

                Sending a follow-up while a turn runs queues it here — that is normal. It only matters if the turn ahead of it is stalled (orange in 'In-flight commands').

                This is the live count; the worst value is captured in 'Peaks → Max queue backlog' so a backlog that has since drained is still visible after the fact.
                """)
                Spacer()
                Text("\(total) waiting")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.chatId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(row.depth)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private func peaksSection(_ peaks: PeaksData, isSelf: Bool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Peaks since \(absTime(peaks.since))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                infoIcon("""
                High-watermarks since the host launched (or you last reset). The live gauges above recover once a freeze clears, so these peaks are how you diagnose a stall after the fact — they record the worst the pipeline got.

                Orange = past a threshold: a turn that ran 5+ min, or any incident count. A queue backlog is a follow-up sent while a turn was running (normal); 'queue-block' counts those too, so it is shown but not flagged.

                Reset (this machine only) zeroes the watermarks so you can watch a fresh window.
                """)
                Spacer()
                if isSelf {
                    Button("Reset") {
                        Task { await bridge.resetHostPeaks() }
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if peaks.isQuiet {
                Text("Nothing has run since reset.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                peakRow(
                    "Max queue backlog",
                    value: "\(peaks.maxQueueBacklog)",
                    detail: peaks.maxQueueBacklog > 0
                        ? "\(shortChat(peaks.maxQueueBacklogChatId)) · \(absTime(peaks.maxQueueBacklogAt))"
                        : nil,
                    warn: false
                )
                peakRow(
                    "Longest in-flight turn",
                    value: fmtDuration(peaks.maxInFlightAgeMs),
                    detail: peaks.maxInFlightAgeMs >= 1
                        ? "\(peaks.maxInFlightAgeKind ?? "?") at '\(peaks.maxInFlightAgeStep ?? "?")' · \(absTime(peaks.maxInFlightAgeAt))"
                        : nil,
                    // Context, not a fault: long agent turns are normal. A turn
                    // that went silent is counted under 'stuck' below.
                    warn: false
                )
                peakRow(
                    "Max concurrent chains",
                    value: "\(peaks.maxPendingChains)",
                    detail: peaks.maxPendingChains > 0 ? absTime(peaks.maxPendingChainsAt) : nil,
                    warn: false
                )
                HStack(spacing: 10) {
                    incidentCount("queue-block", peaks.queueBlockCount, warn: false)
                    incidentCount("setup-stall", peaks.setupStallCount)
                    incidentCount("stuck", peaks.stuckCount)
                    incidentCount("fail", peaks.executeFailCount)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func peakRow(_ label: String, value: String, detail: String?, warn: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(warn ? .orange : .primary)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func incidentCount(_ label: String, _ count: Int, warn: Bool = true) -> some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(warn && count > 0 ? .orange : .secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var commsLogCard: some View {
        let routineCount = commsEntries.filter(\.isRoutine).count
        let visible = commsEntries.filter { showRoutineComms || !$0.isRoutine }.prefix(60)
        let hourAgo = Date().timeIntervalSince1970 * 1000 - 3_600_000
        let lastHour = commsEntries.filter { $0.ts >= hourAgo }
        let errors = lastHour.filter(\.isError).count
        let warnings = lastHour.filter { !$0.isError && !$0.isRoutine }.count
        // Entries older than the host page's current load describe a previous
        // run of it; they are history, not the present.
        let pageLoadedAt = selfHost?.mountEpoch
        let firstOlder = pageLoadedAt.flatMap { loaded in visible.firstIndex { $0.ts < loaded } }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(errors + warnings == 0
                     ? "No warnings or errors in the last hour"
                     : "Last hour: \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(errors > 0 ? .red : warnings > 0 ? .orange : .secondary)
                Spacer(minLength: 0)
                if routineCount > 0 {
                    Button(showRoutineComms ? "Hide routine" : "Show \(routineCount) routine") {
                        showRoutineComms.toggle()
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
            }
            if visible.isEmpty {
                Text(commsEntries.isEmpty ? "Nothing recorded." : "Only routine entries recorded.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, e in
                if index == firstOlder, let pageLoadedAt {
                    Text("Before this page loaded at \(absTime(pageLoadedAt))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                commsRow(e)
                    .opacity(firstOlder.map { index >= $0 } == true ? 0.55 : 1)
            }
            Text("Newest first · kept across relaunches · info = routine, warn = recovered but worth a look, error = failed")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(cardBackground)
        )
        // Native select-to-copy: long-press any row's text to select + copy a
        // single message, in addition to the Copy-all button in the header.
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func commsRow(_ e: CommsEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(commsTime(e.ts))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(e.source)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(e.color)
                .frame(width: 104, alignment: .leading)
                .lineLimit(1)
            Text(e.count > 1 ? "\(e.message)  ×\(e.count)" : e.message)
                .font(.caption2)
                .foregroundStyle(e.isRoutine ? .secondary : .primary)
                .lineLimit(3)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    /// Time of day for today's entries; the date too for anything older, so a
    /// warning from yesterday can't pass for one from a minute ago.
    private func commsTime(_ tsMs: Double) -> String {
        let date = Date(timeIntervalSince1970: tsMs / 1000)
        if Calendar.current.isDateInToday(date) { return Self.timestampFormatter.string(from: date) }
        return Self.olderEntryFormatter.string(from: date)
    }

    private static let olderEntryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    /// Copy ALL comms entries (newest-first) to the clipboard as plain text.
    private func copyCommsLog() {
        let text = commsEntries.map { e -> String in
            let ts = Self.timestampFormatter.string(from: Date(timeIntervalSince1970: e.ts / 1000))
            return "\(ts)  [\(e.label)]  \(e.source)  \(e.message)\(e.count > 1 ? "  ×\(e.count)" : "")"
        }.joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Clear the comms warn/error ring on the web side (source of truth, persisted
    /// to localStorage) and empty the local list immediately. If the bridge call
    /// failed, a genuine entry simply reappears on the next poll — no data loss.
    private func clearCommsLog() async {
        let ok = await bridge.clearCommsLog()
        commsEntries = []
        if !ok { NSLog("[RelayHostStats] clearCommsLog: bridge returned false (web store may not have cleared)") }
    }

    private func absTime(_ tsMs: Double?) -> String {
        guard let tsMs, tsMs > 0 else { return "—" }
        return Self.timestampFormatter.string(from: Date(timeIntervalSince1970: tsMs / 1000))
    }

    /// Format a fixed duration (not relative to now), e.g. the peak in-flight age.
    private func fmtDuration(_ ms: Double) -> String {
        if ms < 1 { return "—" }
        let total = Int(ms)
        if total < 1000 { return "\(total) ms" }
        let s = total / 1000
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m)m \(s % 60)s" }
        let h = m / 60
        return "\(h)h \(m % 60)m"
    }

    private func shortChat(_ chatId: String?) -> String {
        guard let c = chatId, !c.isEmpty else { return "?" }
        return c.count <= 10 ? c : "…\(c.suffix(8))"
    }

    private var cardBackground: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    // MARK: Polling

    /// Fetch once per second while the view is on-screen. Remembers the
    /// previous sample per room so we can render "delta since last" for
    /// frames and messages — the key wedge signal.
    private func pollLoop() async {
        var previousRooms: [String: RoomStats] = [:]
        var previousSelf: RoomStats?
        // Probe every 5th poll, not every poll: the probe is an extra eval and
        // logs a warning line each time it fails, and this view polls at 1Hz.
        var pollTick = 0
        var lastProbe: (health: String, digest: String)?
        while !Task.isCancelled {
            let shouldProbe = pollTick % 5 == 0
            pollTick += 1
            let fetched = await fetch(
                previousRooms: previousRooms,
                previousSelf: previousSelf,
                probeContext: shouldProbe
            )
            let nextRooms = fetched.0
            let nextSelf = fetched.1
            var diag = fetched.2
            let comms = fetched.3
            // Carry the last probe forward between probes so the diagnosis text
            // doesn't blink in and out on the four polls that don't probe.
            if let health = diag.probeHealth, let digest = diag.probeDigest {
                lastProbe = (health, digest)
            } else if diag.hostStatusAvailable == false, let lastProbe {
                diag.probeHealth = lastProbe.health
                diag.probeDigest = lastProbe.digest
                diag.compute()
            } else if diag.hostStatusAvailable == true {
                lastProbe = nil
            }
            if let nextRooms {
                previousRooms = Dictionary(uniqueKeysWithValues: nextRooms.map { ($0.roomId, $0) })
            }
            if let nextSelf {
                previousSelf = nextSelf
            }
            await MainActor.run {
                if let nextRooms { self.rooms = nextRooms }
                self.selfHost = nextSelf
                self.bridgeDiagnostics = diag
                self.commsEntries = comms
                self.lastFetchedAt = Date()
                self.fetchError = nil
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Race a callable against a timer so a hung JS callable can't lock the
    /// view in 'Initialising…' forever. WKWebView.callAsyncJavaScript has no
    /// built-in timeout — if the JS function never returns (e.g. its dynamic
    /// import is hung, or the page hasn't yet wired up window-level
    /// callables), the await would block indefinitely.
    ///
    /// Implementation note: do NOT use withTaskGroup here. callAsyncJavaScript
    /// does not honour Swift Task cancellation, so withTaskGroup's implicit
    /// wait-for-all-children-on-body-exit will block on the still-running op
    /// task even after the timeout wins the race — defeating the timeout.
    /// Instead, race a CheckedContinuation between two detached Tasks; the
    /// loser keeps running in the background but is no longer awaited here.
    /// One-shot latch ensuring only the first caller wins a CheckedContinuation race.
    private actor RaceTimeoutLatch {
        var resumed = false
        func claim() -> Bool {
            if resumed { return false }
            resumed = true
            return true
        }
    }

    private func raceTimeout<T: Sendable>(seconds: Double, _ op: @Sendable @escaping () async -> T?) async -> (T?, didTimeOut: Bool) {
        let latch = RaceTimeoutLatch()
        return await withCheckedContinuation { (cont: CheckedContinuation<(T?, Bool), Never>) in
            Task {
                let value = await op()
                if await latch.claim() {
                    cont.resume(returning: (value, false))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if await latch.claim() {
                    cont.resume(returning: (nil, true))
                }
            }
        }
    }

    private func fetch(
        previousRooms: [String: RoomStats],
        previousSelf: RoomStats?,
        probeContext: Bool
    ) async -> ([RoomStats]?, RoomStats?, BridgeDiagnostics, [CommsEntry]) {
        let bridge = self.bridge
        async let diagRace = raceTimeout(seconds: 5) { await bridge.getRelayDiagnostics(roomId: nil) }
        async let hostRace = raceTimeout(seconds: 5) { await bridge.getHostStatus() }
        async let commsRace = raceTimeout(seconds: 5) { await bridge.getCommsLog() }

        var diagnostics = BridgeDiagnostics()

        // Capture raw host status — even when the bridge is unhealthy.
        let (hostStatus, hostTimedOut) = await hostRace
        if hostTimedOut {
            diagnostics.hostStatusAvailable = false
            diagnostics.hostStatusError = "JS callable timed out after 5s — page may still be loading or its JS context is wedged. Open Web Inspector (Develop → Web Content) and check whether window.__ripulGetHostStatus is defined."
        } else if let hostStatus {
            diagnostics.hostStatusAvailable = (hostStatus["available"] as? Bool) ?? false
            diagnostics.hostStatusError = hostStatus["error"] as? String
            diagnostics.hostEnabled = hostStatus["hostEnabled"] as? Bool
            diagnostics.registered = hostStatus["registered"] as? Bool
            diagnostics.relayState = hostStatus["relayState"] as? String
            diagnostics.roomId = hostStatus["roomId"] as? String
            diagnostics.machineName = hostStatus["machineName"] as? String
            diagnostics.machineId = hostStatus["machineId"] as? String
            diagnostics.stability = ((hostStatus["health"] as? [String: Any])?["relayStability"] as? [String: Any])
                .map(RelayStability.init)
            diagnostics.build = hostStatus["build"] as? String
        } else {
            diagnostics.hostStatusAvailable = false
            diagnostics.hostStatusError = "callable returned nil (WKWebView eval failed or web view not ready)"
        }

        // Controller-side: rooms this app has pinged.
        var roomsOut: [RoomStats]? = nil
        let (result, diagTimedOut) = await diagRace
        if diagTimedOut {
            diagnostics.diagAvailable = false
            diagnostics.diagError = "JS callable timed out after 5s"
        } else if let result {
            diagnostics.diagAvailable = (result["available"] as? Bool) ?? false
            diagnostics.diagError = result["error"] as? String
            if diagnostics.diagAvailable == true,
               let roomsArr = result["rooms"] as? [[String: Any]] {
                diagnostics.diagRoomsCount = roomsArr.count
                var tmp: [RoomStats] = []
                for room in roomsArr {
                    guard let roomId = room["roomId"] as? String else { continue }
                    let pings = (room["pings"] as? [[String: Any]]) ?? []
                    // The newest ping can still be in flight (no reply, no error
                    // yet); judge by the newest one that has settled.
                    let settled = pings.filter { $0["receivedAt"] as? Double != nil || $0["error"] as? String != nil }
                    guard let last = settled.last ?? pings.last else { continue }
                    let failures = settled.reversed().prefix { $0["error"] as? String != nil }.count
                    tmp.append(RoomStats(roomId: roomId, ping: last, previous: previousRooms[roomId],
                                         displayName: room["displayName"] as? String,
                                         presumedOnline: room["presumedOnline"] as? Bool,
                                         consecutiveFailures: failures))
                }
                roomsOut = tmp.sorted { $0.sampleAt > $1.sampleAt }
            }
        } else {
            diagnostics.diagAvailable = false
            diagnostics.diagError = "callable returned nil (WKWebView eval failed)"
        }

        // Host-side: this machine's own bridge self-metrics.
        var selfOut: RoomStats? = nil
        if let hostStatus, let health = hostStatus["health"] as? [String: Any] {
            let hostEnabled = (hostStatus["hostEnabled"] as? Bool) ?? false
            let relayState = (hostStatus["relayState"] as? String) ?? "unknown"
            let machineName = (hostStatus["machineName"] as? String) ?? "this machine"
            let roomId = (hostStatus["roomId"] as? String) ?? "host:\(machineName)"
            if hostEnabled {
                _ = relayState
                selfOut = RoomStats(
                    roomId: machineName,
                    selfHealth: health,
                    underlyingRoomId: roomId,
                    previous: previousSelf
                )
            }
        }

        // Comms-only warn/error ring (host's own, persisted across relaunch).
        var commsOut: [CommsEntry] = []
        let (commsResult, _) = await commsRace
        if let dict = commsResult,
           (dict["available"] as? Bool) == true,
           let arr = dict["entries"] as? [[String: Any]] {
            commsOut = arr.enumerated().compactMap { idx, e in
                guard let message = e["message"] as? String,
                      let source = e["source"] as? String else { return nil }
                let ts = (e["ts"] as? Double) ?? 0
                return CommsEntry(
                    id: "\(idx)-\(ts)",
                    ts: ts,
                    severity: e["severity"] as? String ?? "warn",
                    source: source,
                    message: message,
                    chatId: e["chatId"] as? String,
                    count: (e["count"] as? NSNumber)?.intValue ?? 1
                )
            }
        }

        // Probe the JS context only when the host bridge is reporting failure —
        // it's the one datum that says whether the callables exist at all, and
        // therefore which of the two very different failures this is.
        if probeContext, diagnostics.hostStatusAvailable == false {
            let probe = await bridge.probeWebContext()
            diagnostics.probeHealth = probe.health.rawValue
            diagnostics.probeDigest = probe.digest
        }

        diagnostics.compute()
        return (roomsOut, selfOut, diagnostics, commsOut)
    }

    // MARK: Helpers

    private func ageString(_ tsMs: Double?, now: Date) -> String {
        guard let tsMs, tsMs > 0 else { return "—" }
        let ageMs = Int(now.timeIntervalSince1970 * 1000 - tsMs)
        if ageMs < 0 { return "future?" }
        if ageMs < 1000 { return "\(ageMs) ms" }
        let s = ageMs / 1000
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m)m \(s % 60)s" }
        let h = m / 60
        return "\(h)h \(m % 60)m"
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Models

@available(iOS 16.0, macOS 13.0, *)
fileprivate struct RoomStats: Identifiable {
    let roomId: String
    let sampleAt: Date
    let rttMs: Int?
    let error: String?
    let framesReceived: Int
    let messagesReceived: Int
    let framesSinceLastSample: Int?
    let messagesSinceLastSample: Int?
    let frameGap: Int
    /// Peer agent-command frames counted before the dispatch gates. nil = host
    /// on a web build that doesn't report it.
    let commandFramesReceived: Int?
    let commandFramesSinceLastSample: Int?
    let lastMessagesEffectRanTs: Double?
    let lastCommandReceivedTs: Double?
    let lastCommandCompletedTs: Double?
    let pendingCommandCount: Int
    let mountEpoch: Double?
    let inFlight: [InFlightRow]
    let chainSteps: [ChainStepRow]
    let peaks: PeaksData?
    let queueDepth: [QueueDepthRow]
    /// The machine's name from the registry (controller-side rooms only).
    var displayName: String? = nil
    /// Whether the machine registry thinks the machine is online. nil = unknown.
    var presumedOnline: Bool? = nil
    /// Settled pings in a row that failed, newest backwards.
    var consecutiveFailures: Int = 0
    /// Commands the host received and dropped since its bridge mounted
    /// (command frames − commands drained; both are exact lifetime counters).
    var droppedTotal: Int? = nil
    /// When droppedTotal last grew, carried across polls so one drop stays
    /// visible long enough to read instead of flashing for a single poll.
    var lastDropSeenAt: Date? = nil

    var id: String { roomId }
    var title: String { displayName ?? roomId }

    /// How long a dropped command keeps the card in WEDGED.
    static let dropVisibleSeconds: TimeInterval = 120
    /// Lost pings in a row before a machine counts as not answering. One lost
    /// ping is a hiccup on a phone network, not an outage.
    static let offlineAfterFailures = 2

    /// Fill in the drop bookkeeping from this sample and the previous poll.
    mutating func trackDrops(previous: RoomStats?) {
        guard let commandFramesReceived else { return }
        let total = max(0, commandFramesReceived - messagesReceived)
        droppedTotal = total
        if let before = previous?.droppedTotal, total > before {
            lastDropSeenAt = sampleAt
        } else if previous == nil, total > 0, let mountEpoch,
                  sampleAt.timeIntervalSince1970 - mountEpoch / 1000 < Self.dropVisibleSeconds {
            lastDropSeenAt = sampleAt
        } else if let before = previous?.droppedTotal, total < before {
            lastDropSeenAt = nil // the bridge remounted and its counters reset
        } else {
            lastDropSeenAt = previous?.lastDropSeenAt
        }
    }

    var recentlyDropped: Bool {
        guard let lastDropSeenAt else { return false }
        return Date().timeIntervalSince(lastDropSeenAt) < Self.dropVisibleSeconds
    }

    /// Per-poll delta, nil when either side is missing or the counter went
    /// backwards (the bridge remounted and its counters reset).
    static func delta(_ now: Int?, _ before: Int?) -> Int? {
        guard let now, let before, now >= before else { return nil }
        return now - before
    }

    /// Total current queue backlog across all chats (commands waiting to run).
    var totalBacklog: Int { queueDepth.reduce(0) { $0 + $1.depth } }

    static func parseQueueDepth(_ dict: [String: Any]) -> [QueueDepthRow] {
        let arr = (dict["queueDepthByChat"] as? [[String: Any]]) ?? []
        return arr.enumerated().compactMap { idx, e in
            guard let chatId = e["chatId"] as? String else { return nil }
            let depth = Int((e["depth"] as? Double) ?? 0)
            guard depth > 0 else { return nil }
            return QueueDepthRow(id: "\(idx)-\(chatId)", chatId: chatId, depth: depth)
        }
    }

    // Mirrors SETUP_STUCK_MS / TURN_STUCK_MS in chrome-extension useHostDiagnostics.ts.
    static let setupStallMs: Double = 30_000
    static let turnStuckMs: Double = 5 * 60_000
    /// Breadcrumbs where the agent is actually working — long waits are normal.
    static let turnSteps: Set<String> = ["executeAgentWithPrompt", "resumeWithContext"]

    static func isStepStalled(_ step: ChainStepRow, now: Date, inFlight: InFlightRow? = nil) -> Bool {
        guard let ts = step.ts else { return false }
        let nowMs = now.timeIntervalSince1970 * 1000
        guard turnSteps.contains(step.step) else { return nowMs - ts >= setupStallMs }
        // A working turn is judged by silence, not age, and never while it
        // waits on a person. Older hosts report no activity: fall back to age.
        if let inFlight {
            if inFlight.awaitingInput { return false }
            let lastSign = max(ts, inFlight.lastActivityAt ?? 0, inFlight.startedAt ?? 0)
            return nowMs - lastSign >= turnStuckMs
        }
        return nowMs - ts >= turnStuckMs
    }

    /// Commands that arrived between polls but were not dispatched. nil when the
    /// host doesn't report command frames (older web build) or on the first poll.
    var droppedSinceLastSample: Int? {
        guard let cmdDelta = commandFramesSinceLastSample,
              let msgsDelta = messagesSinceLastSample else { return nil }
        return max(0, cmdDelta - msgsDelta)
    }

    /// Why this in-flight command counts as stalled, or nil if it doesn't.
    func stallReason(for cmd: InFlightRow) -> String? {
        let now = sampleAt.timeIntervalSince1970 * 1000
        if cmd.awaitingInput { return nil }
        if let step = chainSteps.first(where: { $0.chatId == cmd.chatId }),
           let ts = step.ts,
           Self.isStepStalled(step, now: sampleAt, inFlight: cmd) {
            if Self.turnSteps.contains(step.step) {
                let lastSign = max(ts, cmd.lastActivityAt ?? 0, cmd.startedAt ?? 0)
                return "\(cmd.kind) on …\(cmd.chatId.suffix(8)) has produced nothing for \(Int((now - lastSign) / 60_000)) min and isn't waiting for input"
            }
            return "\(cmd.kind) on …\(cmd.chatId.suffix(8)) stuck \(Int((now - ts) / 1000))s at setup step '\(step.step)'"
        }
        // No breadcrumb: only an old host without activity data falls back to age.
        if cmd.lastActivityAt == nil, chainSteps.first(where: { $0.chatId == cmd.chatId }) == nil,
           let started = cmd.startedAt, now - started >= Self.turnStuckMs {
            return "\(cmd.kind) on …\(cmd.chatId.suffix(8)) running \(Int((now - started) / 60_000)) min with no breadcrumb"
        }
        return nil
    }

    var health: HealthStatus {
        if error != nil && consecutiveFailures >= Self.offlineAfterFailures {
            // An asleep or shut-down machine is not a fault of this app; only a
            // machine the registry still thinks is up is worth a warning.
            if presumedOnline == false {
                return HealthStatus(label: "OFFLINE", color: .secondary,
                                    detail: "Not answering, and the machine list agrees it's offline: probably asleep or shut down.")
            }
            return HealthStatus(label: "NOT ANSWERING", color: .orange,
                                detail: "\(consecutiveFailures) pings in a row got no answer (\(error ?? "?")), though the machine list still shows it online. Its host page may be wedged or its network down.")
        }
        // Frames alone prove nothing — pings and self-echo raise them on an idle
        // host. Only commands that arrived and were NOT dispatched are a wedge.
        if recentlyDropped, let droppedTotal {
            return HealthStatus(
                label: "WEDGED",
                color: .orange,
                detail: "Commands are arriving and being dropped unanswered (\(droppedTotal) since the page loaded). The comms log's command-dropped entries say which check dropped them."
            )
        }
        if error != nil {
            return HealthStatus(label: "HEALTHY", color: .green, detail: "One ping went unanswered (\(error ?? "?")); the next will tell.")
        }
        let stalls = inFlight.compactMap { stallReason(for: $0) }
        if let first = stalls.first {
            let more = stalls.count > 1 ? " (+\(stalls.count - 1) more)" : ""
            return HealthStatus(label: "STALLED", color: .orange, detail: first + more)
        }
        return HealthStatus(label: "HEALTHY", color: .green, detail: nil)
    }

    /// Build a stats card from a host's own HostHealthSnapshot (read on the
    /// machine that IS the host — no controller round-trip involved).
    init(roomId: String, selfHealth: [String: Any], underlyingRoomId: String, previous: RoomStats?) {
        self.roomId = roomId
        self.error = nil
        self.rttMs = nil
        self.sampleAt = Date()

        let frames = Int((selfHealth["framesReceivedCount"] as? Double) ?? 0)
        let msgs = Int((selfHealth["messagesReceivedCount"] as? Double) ?? 0)
        self.framesReceived = frames
        self.messagesReceived = msgs
        self.frameGap = frames - msgs
        let cmdFrames = (selfHealth["commandFramesReceivedCount"] as? Double).map { Int($0) }
        self.commandFramesReceived = cmdFrames

        if let previous {
            self.framesSinceLastSample = frames - previous.framesReceived
            self.messagesSinceLastSample = msgs - previous.messagesReceived
            self.commandFramesSinceLastSample = Self.delta(cmdFrames, previous.commandFramesReceived)
        } else {
            self.framesSinceLastSample = nil
            self.messagesSinceLastSample = nil
            self.commandFramesSinceLastSample = nil
        }

        self.lastMessagesEffectRanTs = selfHealth["lastMessagesEffectRanTs"] as? Double
        self.lastCommandReceivedTs = selfHealth["lastCommandReceivedTs"] as? Double
        self.lastCommandCompletedTs = selfHealth["lastCommandCompletedTs"] as? Double
        self.pendingCommandCount = Int((selfHealth["pendingCommandCount"] as? Double) ?? 0)
        self.mountEpoch = selfHealth["mountEpoch"] as? Double

        let inFlightArr = (selfHealth["inFlightCommands"] as? [[String: Any]]) ?? []
        self.inFlight = inFlightArr.enumerated().map { idx, c in
            InFlightRow(
                id: "\(idx)-\(c["chatId"] as? String ?? "")",
                chatId: c["chatId"] as? String ?? "—",
                kind: c["kind"] as? String ?? "—",
                startedAt: c["startedAt"] as? Double,
                raw: c
            )
        }

        let chainArr = (selfHealth["lastChainStepByChat"] as? [[String: Any]]) ?? []
        self.chainSteps = chainArr.enumerated().map { idx, s in
            ChainStepRow(
                id: "\(idx)-\(s["chatId"] as? String ?? "")",
                chatId: s["chatId"] as? String ?? "—",
                step: s["step"] as? String ?? "—",
                ts: s["ts"] as? Double
            )
        }
        self.peaks = PeaksData(selfHealth["peaks"] as? [String: Any])
        self.queueDepth = Self.parseQueueDepth(selfHealth)
        _ = underlyingRoomId
        trackDrops(previous: previous)
    }

    init(roomId: String, ping: [String: Any], previous: RoomStats?,
         displayName: String? = nil, presumedOnline: Bool? = nil, consecutiveFailures: Int = 0) {
        self.roomId = roomId
        self.displayName = displayName
        self.presumedOnline = presumedOnline
        self.consecutiveFailures = consecutiveFailures
        self.error = ping["error"] as? String
        self.rttMs = (ping["rttMs"] as? Double).map { Int($0) }
        let sentAtMs = ping["sentAt"] as? Double ?? 0
        let receivedAtMs = ping["receivedAt"] as? Double ?? sentAtMs
        self.sampleAt = Date(timeIntervalSince1970: receivedAtMs / 1000.0)

        let host = (ping["hostMetrics"] as? [String: Any]) ?? [:]

        let frames = Int((host["framesReceivedCount"] as? Double) ?? 0)
        let msgs = Int((host["messagesReceivedCount"] as? Double) ?? 0)
        self.framesReceived = frames
        self.messagesReceived = msgs
        self.frameGap = frames - msgs
        let cmdFrames = (host["commandFramesReceivedCount"] as? Double).map { Int($0) }
        self.commandFramesReceived = cmdFrames

        // "since last" is relative to the previous POLL (this view), not the
        // previous pong. That's what we actually want to show on a live view.
        if let previous {
            self.framesSinceLastSample = frames - previous.framesReceived
            self.messagesSinceLastSample = msgs - previous.messagesReceived
            self.commandFramesSinceLastSample = Self.delta(cmdFrames, previous.commandFramesReceived)
        } else {
            self.framesSinceLastSample = nil
            self.messagesSinceLastSample = nil
            self.commandFramesSinceLastSample = nil
        }

        self.lastMessagesEffectRanTs = host["lastMessagesEffectRanTs"] as? Double
        self.lastCommandReceivedTs = host["lastCommandReceivedTs"] as? Double
        self.lastCommandCompletedTs = host["lastCommandCompletedTs"] as? Double
        self.pendingCommandCount = Int((host["pendingCommandCount"] as? Double) ?? 0)
        self.mountEpoch = host["mountEpoch"] as? Double

        let inFlightArr = (host["inFlightCommands"] as? [[String: Any]]) ?? []
        self.inFlight = inFlightArr.enumerated().map { idx, c in
            InFlightRow(
                id: "\(idx)-\(c["chatId"] as? String ?? "")",
                chatId: c["chatId"] as? String ?? "—",
                kind: c["kind"] as? String ?? "—",
                startedAt: c["startedAt"] as? Double,
                raw: c
            )
        }

        let chainArr = (host["lastChainStepByChat"] as? [[String: Any]]) ?? []
        self.chainSteps = chainArr.enumerated().map { idx, s in
            ChainStepRow(
                id: "\(idx)-\(s["chatId"] as? String ?? "")",
                chatId: s["chatId"] as? String ?? "—",
                step: s["step"] as? String ?? "—",
                ts: s["ts"] as? Double
            )
        }
        self.peaks = PeaksData(host["peaks"] as? [String: Any])
        self.queueDepth = Self.parseQueueDepth(host)
        trackDrops(previous: previous)
    }
}

@available(iOS 16.0, macOS 13.0, *)
fileprivate struct InfoIcon: View {
    let tooltip: String
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            ScrollView {
                Text(tooltip)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 360, maxHeight: 280)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
fileprivate struct HealthStatus {
    let label: String
    let color: Color
    let detail: String?
}

@available(iOS 16.0, macOS 13.0, *)
fileprivate struct InFlightRow: Identifiable {
    let id: String
    let chatId: String
    let kind: String
    let startedAt: Double?
    /// Last sign of life from the turn; nil from hosts that don't report it.
    var lastActivityAt: Double? = nil
    var awaitingInput: Bool = false

    init(id: String, chatId: String, kind: String, startedAt: Double?, raw: [String: Any] = [:]) {
        self.id = id
        self.chatId = chatId
        self.kind = kind
        self.startedAt = startedAt
        self.lastActivityAt = (raw["lastActivityAt"] as? NSNumber)?.doubleValue
        self.awaitingInput = raw["awaitingInput"] as? Bool ?? false
    }
}

@available(iOS 16.0, macOS 13.0, *)
fileprivate struct ChainStepRow: Identifiable {
    let id: String
    let chatId: String
    let step: String
    let ts: Double?
}

@available(iOS 16.0, macOS 13.0, *)
fileprivate struct QueueDepthRow: Identifiable {
    let id: String
    let chatId: String
    let depth: Int
}

/// High-watermarks reported by the host — survive a freeze that has recovered.
@available(iOS 16.0, macOS 13.0, *)
fileprivate struct PeaksData {
    let since: Double?
    let maxQueueBacklog: Int
    let maxQueueBacklogChatId: String?
    let maxQueueBacklogAt: Double?
    let maxInFlightAgeMs: Double
    let maxInFlightAgeChatId: String?
    let maxInFlightAgeKind: String?
    let maxInFlightAgeStep: String?
    let maxInFlightAgeAt: Double?
    let maxPendingChains: Int
    let maxPendingChainsAt: Double?
    let queueBlockCount: Int
    let setupStallCount: Int
    let stuckCount: Int
    let executeFailCount: Int

    init?(_ dict: [String: Any]?) {
        guard let d = dict else { return nil }
        self.since = d["since"] as? Double
        self.maxQueueBacklog = Int((d["maxQueueBacklog"] as? Double) ?? 0)
        self.maxQueueBacklogChatId = d["maxQueueBacklogChatId"] as? String
        self.maxQueueBacklogAt = d["maxQueueBacklogAt"] as? Double
        self.maxInFlightAgeMs = (d["maxInFlightAgeMs"] as? Double) ?? 0
        self.maxInFlightAgeChatId = d["maxInFlightAgeChatId"] as? String
        self.maxInFlightAgeKind = d["maxInFlightAgeKind"] as? String
        self.maxInFlightAgeStep = d["maxInFlightAgeStep"] as? String
        self.maxInFlightAgeAt = d["maxInFlightAgeAt"] as? Double
        self.maxPendingChains = Int((d["maxPendingChains"] as? Double) ?? 0)
        self.maxPendingChainsAt = d["maxPendingChainsAt"] as? Double
        self.queueBlockCount = Int((d["queueBlockCount"] as? Double) ?? 0)
        self.setupStallCount = Int((d["setupStallCount"] as? Double) ?? 0)
        self.stuckCount = Int((d["stuckCount"] as? Double) ?? 0)
        self.executeFailCount = Int((d["executeFailCount"] as? Double) ?? 0)
    }

    /// True when nothing has run at all since reset. Ordinary turns do count —
    /// the longest-turn row is useful context even when it isn't a warning.
    var isQuiet: Bool {
        maxQueueBacklog == 0 && maxInFlightAgeMs < 1 && maxPendingChains <= 1
            && queueBlockCount == 0 && setupStallCount == 0 && stuckCount == 0 && executeFailCount == 0
    }
}

@available(iOS 16.0, macOS 13.0, *)
fileprivate struct CommsEntry: Identifiable {
    let id: String
    let ts: Double
    let severity: String
    let source: String
    let message: String
    let chatId: String?
    var count: Int = 1

    var isError: Bool { severity == "error" }
    var isRoutine: Bool { severity == "info" }
    var color: Color { isError ? .red : isRoutine ? .secondary : .orange }
    var label: String { isError ? "ERROR" : isRoutine ? "INFO" : "WARN" }
}

/// One line of the summary: something true about the relay right now, how
/// much it matters, and what to do about it.
@available(iOS 16.0, macOS 13.0, *)
fileprivate struct Finding: Identifiable {
    enum Level: Int, Comparable {
        case info, warn, error
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var color: Color { self == .error ? .red : self == .warn ? .orange : .secondary }
    }
    let id: String
    let level: Level
    let title: String
    let detail: String
    var action: FindingAction? = nil
}

fileprivate enum FindingAction {
    case retryRelay
    case healWebContext
}

/// Rolls every signal on the screen into findings. Each one is either a fault
/// with something to do, or (info) context that explains a state someone might
/// otherwise mistake for a fault. Nothing healthy produces a finding.
@available(iOS 16.0, macOS 13.0, *)
fileprivate enum StatusSummary {
    /// Comms entries this recent count towards the summary.
    static let recentCommsSeconds: Double = 15 * 60

    static func findings(diagnostics d: BridgeDiagnostics, selfHost: RoomStats?, rooms: [RoomStats],
                         comms: [CommsEntry], now: Date) -> [Finding] {
        var out: [Finding] = []

        switch d.statusLabel {
        case "NO NATIVE CALLABLES", "BRIDGE NOT MOUNTED":
            out.append(Finding(id: "bridge", level: .error, title: "The web app's host bridge isn't running",
                               detail: d.diagnosis, action: .healWebContext))
        case "HOST DISABLED":
            out.append(Finding(id: "bridge", level: .info, title: "This device isn't hosting",
                               detail: "Other devices can't send work here. That's expected on a phone; on a Mac, turn on Host in Settings → Server."))
        case "NO ROOM REGISTERED":
            out.append(Finding(id: "bridge", level: .warn, title: "Not registered with the relay yet", detail: d.diagnosis))
        case "RELAY UNSTABLE":
            out.append(Finding(id: "bridge", level: .warn,
                               title: d.stability?.replacedBy != nil ? "Another connection is hosting as this machine" : "The relay connection keeps dropping",
                               detail: d.diagnosis))
        case "RELAY DOWN":
            out.append(Finding(id: "bridge", level: .error, title: "Not connected to the relay", detail: d.diagnosis, action: .retryRelay))
        default:
            if d.statusColor == .red {
                out.append(Finding(id: "bridge", level: .error, title: d.statusLabel.capitalized, detail: d.diagnosis, action: .retryRelay))
            }
        }

        if let selfHost {
            let health = selfHost.health
            if health.label == "WEDGED" || health.label == "STALLED" {
                out.append(Finding(id: "self", level: .warn,
                                   title: health.label == "WEDGED" ? "Commands to this machine are being dropped" : "A turn on this machine is stuck",
                                   detail: health.detail ?? ""))
            }
        }

        for room in rooms {
            let health = room.health
            switch health.label {
            case "NOT ANSWERING":
                out.append(Finding(id: "room-\(room.roomId)", level: .warn, title: "\(room.title) isn't answering", detail: health.detail ?? ""))
            case "OFFLINE":
                out.append(Finding(id: "room-\(room.roomId)", level: .info, title: "\(room.title) is offline", detail: health.detail ?? ""))
            case "WEDGED", "STALLED":
                out.append(Finding(id: "room-\(room.roomId)", level: .warn,
                                   title: health.label == "WEDGED" ? "\(room.title) is dropping commands" : "A turn on \(room.title) is stuck",
                                   detail: health.detail ?? ""))
            default:
                break
            }
        }

        // Recent log entries the cards above don't already account for.
        let since = now.timeIntervalSince1970 * 1000 - recentCommsSeconds * 1000
        let covered: Set<String> = out.contains { $0.id == "bridge" } ? ["socket-unstable", "socket-down"] : []
        let recent = comms.filter { $0.ts >= since && !$0.isRoutine && !covered.contains($0.source) }
        if !recent.isEmpty {
            var counts: [(String, Int)] = []
            for entry in recent {
                if let i = counts.firstIndex(where: { $0.0 == entry.source }) { counts[i].1 += entry.count }
                else { counts.append((entry.source, entry.count)) }
            }
            let list = counts.map { "\($0.1)× \($0.0)" }.joined(separator: ", ")
            let hasError = recent.contains(where: \.isError)
            out.append(Finding(id: "comms", level: hasError ? .error : .warn,
                               title: hasError ? "Errors in the last 15 minutes" : "Warnings in the last 15 minutes",
                               detail: "\(list). Details in the comms log below; the newest says \"\(recent[0].message)\"."))
        }

        return out.sorted { $0.level > $1.level }
    }

    /// The positive statement behind "All clear": what was checked, so a green
    /// verdict is evidence rather than an absence of complaints.
    static func allClearSentence(diagnostics d: BridgeDiagnostics, rooms: [RoomStats], comms: [CommsEntry], now: Date) -> String {
        var parts: [String] = []
        if let stability = d.stability, let up = stability.connectedForMs {
            let drops = stability.dropsLast1h
            parts.append("Relay connected for \(RelayStability.duration(up)), \(drops == 0 ? "no drops" : "\(drops) brief drop\(drops == 1 ? "" : "s")") in the last hour")
        } else if d.relayState == "connected" {
            parts.append("Relay connected")
        }
        let answering = rooms.filter { $0.health.label == "HEALTHY" }.map(\.title)
        if !answering.isEmpty { parts.append("answering: \(answering.joined(separator: ", "))") }
        parts.append("no warnings in the last 15 minutes")
        return parts.joined(separator: "; ") + "."
    }
}

/// The serving relay socket's recent history, as the web app's transport
/// records it (`health.relayStability`, see transportStability.ts).
@available(iOS 16.0, macOS 13.0, *)
fileprivate struct RelayStability {
    /// Recovered drops in five minutes that make a connection unstable. One or
    /// two are ordinary; the web side logs a comms warning at the same count.
    static let unstableDrops = 3
    /// An outage shorter than this is a reconnect in progress, not a fault.
    static let briefOutageSeconds: Double = 15

    let connectedForMs: Double?
    let downForMs: Double?
    let downAttempts: Int
    let dropsLast5m: Int
    let dropsLast1h: Int
    let lastDropReason: String?
    /// The relay's close reason text when it closed the socket on purpose.
    let lastDropCloseReason: String?
    let lastDropPhase: String?
    let lastDropAgoMs: Double?
    let lastDropRecoveredInMs: Double?

    init(_ raw: [String: Any]) {
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        connectedForMs = number(raw["connectedForMs"])
        downForMs = number(raw["downForMs"])
        downAttempts = Int(number(raw["downAttempts"]) ?? 0)
        dropsLast5m = Int(number(raw["dropsLast5m"]) ?? 0)
        dropsLast1h = Int(number(raw["dropsLast1h"]) ?? 0)
        let last = raw["lastDrop"] as? [String: Any]
        lastDropReason = last?["reason"] as? String
        lastDropCloseReason = (last?["closeReason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        lastDropPhase = last?["phase"] as? String
        lastDropAgoMs = number(last?["agoMs"])
        lastDropRecoveredInMs = number(last?["recoveredInMs"])
    }

    static func duration(_ ms: Double) -> String {
        let seconds = Int((ms / 1000).rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// The other connection named by the relay when it swapped this one out,
    /// e.g. "Macbook pro, in-app browser tab, user credential".
    var replacedBy: String? {
        guard let text = lastDropCloseReason, text.hasPrefix("Replaced by new connection") else { return nil }
        let detail = text.dropFirst("Replaced by new connection".count).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return detail.isEmpty ? "another connection (no detail)" : detail
    }

    /// What a transport failure reason means, in terms of who ended the socket.
    static func explain(_ reason: String, closeReason: String? = nil) -> String {
        if let closeReason {
            if closeReason.hasPrefix("Replaced by new connection") {
                return "the relay swapped it for another connection using this machine's identity"
            }
            if closeReason.hasPrefix("Superseded") { return "the relay closed it because a newer connection owns this identity" }
            if closeReason.hasPrefix("Stale connection") {
                return "the relay closed it after hearing nothing from it for 90s: this side's heartbeats stopped arriving"
            }
            if closeReason.hasPrefix("Authorization") { return "the relay closed it because its authorization expired or was revoked" }
        }
        switch reason {
        case "close-1000":
            return "the relay closed it deliberately (code 1000). It does that when another connection joins under this machine's host identity, so look for a second page or app hosting as this machine"
        case "close-1008":
            return "the relay refused or expired its authorization (code 1008)"
        case "close-1011":
            return "the relay hit an error on this socket (code 1011)"
        case "close-1006", "socket-error":
            return "the socket was cut without a close (\(reason)): a network interruption, or the relay restarting"
        case "no-url":
            return "no relay address could be built, usually because there was no auth token"
        case "foreground", "network-change-probe":
            return "the app rebuilt it itself after \(reason)"
        default:
            if reason.contains("timeout") { return "an attempt timed out (\(reason))" }
            return reason
        }
    }

    var lastDropSentence: String? {
        guard let reason = lastDropReason else { return nil }
        var sentence = "Last drop: \(Self.explain(reason, closeReason: lastDropCloseReason))"
        if let lastDropPhase, lastDropPhase != "ready" { sentence += ", while still connecting (\(lastDropPhase))" }
        if let recovered = lastDropRecoveredInMs { sentence += ". Back after \(Self.duration(recovered))" }
        return sentence + "."
    }

    var lastDropSummary: String {
        guard let reason = lastDropReason, let ago = lastDropAgoMs else { return "none recorded" }
        let recovered = lastDropRecoveredInMs.map { ", back after \(Self.duration($0))" } ?? ", not yet recovered"
        let why = lastDropCloseReason.map { " (\($0))" } ?? ""
        return "\(Self.duration(ago)) ago: \(reason)\(why)\(recovered)"
    }
}

/// Captured raw values from the two diagnostic JS callables on each poll,
/// plus a derived one-line explanation of *why* the bridge is in whatever
/// state it's in. Used by the always-visible diagnostics card so the user
/// can distinguish "host bridge React tree didn't mount" from "host
/// disabled" from "registered but no room" from "WS not connected".
@available(iOS 16.0, macOS 13.0, *)
fileprivate struct BridgeDiagnostics {
    var hostStatusAvailable: Bool? = nil
    var hostStatusError: String? = nil
    var hostEnabled: Bool? = nil
    var registered: Bool? = nil
    var relayState: String? = nil
    var roomId: String? = nil
    var machineName: String? = nil
    var machineId: String? = nil

    var diagAvailable: Bool? = nil
    var diagError: String? = nil
    var diagRoomsCount: Int = 0

    /// JS-context probe, run only while the host bridge reports unavailable.
    /// This is what separates "no callables at all" (broken boot) from
    /// "callables present, React provider unregistered" — two states the panel
    /// used to describe with the same, usually-wrong, sentence.
    var probeHealth: String? = nil
    var probeDigest: String? = nil

    /// The serving socket's recent drop history. nil from a web build that
    /// predates it, in which case only the instantaneous state is known.
    var stability: RelayStability? = nil
    var build: String? = nil

    var diagnosis: String = ""
    var statusLabel: String = "Initialising…"
    var statusColor: Color = .secondary
    var statusIcon: String = "hourglass"

    /// Compute the single-line `diagnosis`, the status label, and a colour
    /// from the captured raw values. Run after every fetch.
    mutating func compute() {
        if hostStatusAvailable == nil {
            statusLabel = "Initialising…"
            statusColor = .secondary
            statusIcon = "hourglass"
            diagnosis = "Waiting for first poll…"
            return
        }

        if hostStatusAvailable == false {
            statusColor = .red
            statusIcon = "exclamationmark.triangle.fill"
            let probeSuffix = probeDigest.map { " Probe: \(probeHealth ?? "?") — \($0)." } ?? ""

            if hostStatusError == AgentBridge.callableMissingError {
                // window.__ripulGetHostStatus does not EXIST. This is not a
                // provider problem — registerNativeCallables() runs first in the
                // boot chain, before any await, so if the callables are absent
                // the entry bundle itself never evaluated.
                statusLabel = "NO NATIVE CALLABLES"
                diagnosis = "window.__ripulGetHostStatus does not exist, so the web app never registered its native bridge — this is a BROKEN BOOT, not an unmounted React provider. registerNativeCallables() runs before any await in the boot chain, so an absent callable means the entry bundle failed to load or evaluate (a chunk 404 from a deploy landing mid-boot is the usual cause). The native side now probes and heals this automatically; `boot=` below names the phase the chain reached.\(probeSuffix)"
            } else if let err = hostStatusError, !err.isEmpty {
                // The callable answered, so the JS bridge is installed and it is
                // the React subtree behind serverHostBridge that didn't register.
                statusLabel = "BRIDGE NOT MOUNTED"
                diagnosis = "__ripulGetHostStatus reports unavailable: \(err). The callables ARE installed, so this is the host-bridge React provider failing to register with the serverHostBridge singleton — its subtree didn't mount. A reload won't fix an accurate report; check the Web Inspector console (Develop → Web Content) for the mount error.\(probeSuffix)"
            } else {
                statusLabel = "BRIDGE NOT MOUNTED"
                diagnosis = "__ripulGetHostStatus returned available=false with no error. The RemoteHostBridgeProvider has not registered with the serverHostBridge singleton — its React subtree probably failed to mount. Check the Web Inspector console for startup errors.\(probeSuffix)"
            }
            return
        }

        // Bridge is mounted. Now drill into why it isn't operating.

        if hostEnabled == false {
            statusLabel = "HOST DISABLED"
            statusColor = .orange
            statusIcon = "power"
            diagnosis = "Host bridge is mounted but hostEnabled=false. Toggle Host Enabled in Settings → Server, or call __ripulSetHostEnabled(true) to start hosting."
            return
        }

        if registered == false && (roomId == nil || roomId?.isEmpty == true) {
            statusLabel = "NO ROOM REGISTERED"
            statusColor = .orange
            statusIcon = "house.slash"
            diagnosis = "Host is enabled but registered=false and no roomId is cached. The machine-registry call has not yet returned. Check auth state (signed-in?) and network. If this persists, the registry endpoint is failing."
            return
        }

        // One poll every few seconds sees a single instant. A socket that drops
        // and is back in a second looks "reconnecting" to an unlucky poll, and
        // one being knocked off every two seconds looks "connected" to most of
        // them. So judge by the drop history when the web build supplies it.
        let connected = relayState == "connected"
        if let stability {
            if stability.dropsLast5m >= RelayStability.unstableDrops, let other = stability.replacedBy {
                statusLabel = "RELAY UNSTABLE"
                statusColor = .orange
                statusIcon = "person.2.slash"
                diagnosis = "Two connections are taking turns as this machine: \(stability.dropsLast5m) swaps in the last 5 minutes. The relay keeps one connection per identity, and the last one to replace this page was: \(other). Close that page or app; while both run, this machine drops out for a second or two at every swap."
                return
            }
            if stability.dropsLast5m >= RelayStability.unstableDrops {
                statusLabel = "RELAY UNSTABLE"
                statusColor = .orange
                statusIcon = "exclamationmark.arrow.triangle.2.circlepath"
                diagnosis = "\(connected ? "Connected right now, but the" : "The") relay socket has dropped \(stability.dropsLast5m) times in the last 5 minutes. Each drop leaves this machine unreachable until it reconnects."
                    + (stability.lastDropSentence.map { " \($0)" } ?? "")
                return
            }
            if connected {
                statusLabel = "HEALTHY"
                statusColor = .green
                statusIcon = "checkmark.circle.fill"
                diagnosis = ""
                return
            }
            let downSeconds = (stability.downForMs ?? 0) / 1000
            if stability.downForMs != nil && downSeconds < RelayStability.briefOutageSeconds {
                // Not a warning: long-held sockets drop now and then, and this
                // one is already on its way back.
                statusLabel = "RECONNECTING"
                statusColor = .secondary
                statusIcon = "arrow.triangle.2.circlepath"
                diagnosis = "Brief drop, reconnecting (\(Int(downSeconds))s so far)."
                    + (stability.lastDropSentence.map { " \($0)" } ?? "")
                return
            }
            if stability.downForMs != nil {
                statusLabel = "RELAY DOWN"
                statusColor = .red
                statusIcon = "wifi.exclamationmark"
                diagnosis = "Not connected for \(RelayStability.duration(stability.downForMs ?? 0)), after \(stability.downAttempts) failed attempt\(stability.downAttempts == 1 ? "" : "s"). This machine is unreachable from other devices."
                    + (stability.lastDropSentence.map { " \($0)" } ?? "")
                return
            }
            // Not connected and no outage on record: the first connection is
            // still being made.
            statusLabel = "CONNECTING"
            statusColor = .secondary
            statusIcon = "arrow.triangle.2.circlepath"
            diagnosis = "Opening the first relay connection (relayState=\(relayState ?? "unknown"))."
            return
        }

        if let rs = relayState, rs != "connected" {
            statusLabel = "RELAY \(rs.uppercased())"
            statusColor = (rs == "connecting" || rs == "reconnecting") ? .secondary : .red
            statusIcon = "wifi.exclamationmark"
            diagnosis = "The relay socket is \(rs) at this instant. This web build reports no drop history, so the panel cannot tell a one-second reconnect from an outage."
            return
        }

        if connected {
            statusLabel = "HEALTHY"
            statusColor = .green
            statusIcon = "checkmark.circle.fill"
            diagnosis = ""
            return
        }

        // Fallback — shouldn't normally reach here.
        statusLabel = "UNKNOWN"
        statusColor = .secondary
        statusIcon = "questionmark.circle"
        diagnosis = "Bridge state did not match any known pattern."
    }
}
