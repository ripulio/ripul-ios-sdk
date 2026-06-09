import SwiftUI

// MARK: - Relay Host Stats View

/// Live diagnostics view for the relay host-bridge.
///
/// Polls `bridge.getRelayDiagnostics(roomId: nil)` once per second and renders
/// the freshest pong sample per room. Surfaces the signals needed to tell
/// "host is online" apart from "host is accepting messages":
///
/// - Frames in vs messages dispatched — gap means React path is starved.
/// - Age of the last messages-effect run — stale while frames arrive means
///   the effect is wedged.
/// - Per-chat chain breadcrumbs — names the `await` a stuck chain is hung on.
///
/// Accessible via the `/rr.` debug menu → "Relay Host Stats".
@available(iOS 16.0, macOS 13.0, *)
public struct RelayHostStatsView: View {
    @ObservedObject var bridge: AgentBridge
    @State private var rooms: [RoomStats] = []
    @State private var selfHost: RoomStats?
    @State private var lastFetchedAt: Date?
    @State private var fetchError: String?
    @State private var bridgeDiagnostics: BridgeDiagnostics = BridgeDiagnostics()
    @State private var commsEntries: [CommsEntry] = []

    public init(bridge: AgentBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                // Always-visible diagnostics so the user can see WHY the
                // host bridge is or isn't running, independent of whether
                // there's any room data to render below.
                sectionLabel("Bridge diagnostics")
                bridgeDiagnosticsCard

                if let selfHost {
                    sectionLabel("This machine (host self-metrics)")
                    roomCard(selfHost, isSelf: true)
                }

                if !rooms.isEmpty {
                    sectionLabel("Controller-side pings (this app → remote hosts)")
                    ForEach(rooms) { room in
                        roomCard(room)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    sectionLabel("Comms warnings & errors")
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

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                diagRow("getHostStatus.available", value: bridgeDiagnostics.hostStatusAvailable.map { $0 ? "true" : "false" } ?? "—",
                        color: (bridgeDiagnostics.hostStatusAvailable == false) ? .red : nil)
                if let err = bridgeDiagnostics.hostStatusError {
                    diagRow("getHostStatus.error", value: err, color: .red, mono: true)
                }
                diagRow("hostEnabled", value: bridgeDiagnostics.hostEnabled.map { $0 ? "true" : "false" } ?? "—",
                        color: (bridgeDiagnostics.hostEnabled == false) ? .orange : nil)
                diagRow("registered", value: bridgeDiagnostics.registered.map { $0 ? "true" : "false" } ?? "—",
                        color: (bridgeDiagnostics.registered == false) ? .orange : nil)
                diagRow("relayState", value: bridgeDiagnostics.relayState ?? "—",
                        color: (bridgeDiagnostics.relayState != nil && bridgeDiagnostics.relayState != "connected") ? .orange : nil)
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
                Text(room.roomId)
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
                inFlightList(room.inFlight, now: room.sampleAt)
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
            HEALTHY — frames and commands advancing in step, effect ran recently.

            WEDGED — frames kept arriving between polls but commands drained stayed flat. The React messages-effect isn't running even though the WebSocket is. This is the 'host looks online but won't accept messages' failure.

            EFFECT STALE — the messages-effect hasn't run in >10s while frames kept arriving. Same underlying class of failure as WEDGED, caught via a different signal.

            OFFLINE — the last ping failed (timeout, send error, disconnected). The WebSocket itself is down.
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

                Includes every inbound message: real agent commands, liveness pings, self-echo of your own outbound events, peer join/leave frames, and schema-invalid payloads.

                Compared against 'Commands drained' below: when Frames in keeps climbing but Commands drained stalls, the React path is starved — that's the 'host looks online but won't accept messages' signature.
                """
            )
            statRow(
                "Commands drained",
                value: "\(room.messagesReceived)",
                detail: room.messagesSinceLastSample.map { "+\($0) since last" },
                tooltip: """
                Lifetime count of agent commands that actually reached handleCommand — i.e. frames that passed every filter (not self-clientId, not a ping handled by the imperative fast-path, valid RelayAgentPayload, isAgentCommand true) and were dispatched to the executor.

                Under healthy load this climbs in step with Frames in minus pings/self-echo. If this stops climbing while Frames in keeps climbing, the host's React messages-effect has stopped running — the wedge we're hunting.
                """
            )
            statRow(
                "Lifetime skipped frames",
                value: "\(room.frameGap)",
                detail: "frames − commands drained (cumulative)",
                tooltip: """
                Simple derived number: framesReceivedCount − messagesReceivedCount. 'Skipped' not in a queue sense — both counters are monotonic lifetime totals, neither decreases, this gap never drains to zero.

                Represents every frame that arrived but was intentionally not dispatched as a command: self-echo of your own outbound events (same clientId), host:ping answered by the imperative fast-path, peer:queryResponse handled separately, peer roster frames, and anything that fails the agent-command type guards.

                Stable or slowly-climbing = normal. What matters for the wedge is the per-poll delta on 'Frames in' vs 'Commands drained', NOT this lifetime gap.
                """
            )
            statRow(
                "Effect last ran",
                value: ageString(room.lastMessagesEffectRanTs, now: room.sampleAt),
                valueColor: room.effectStale ? .orange : nil,
                tooltip: """
                Time since the host's messages-handling useEffect body last executed. Stamped unconditionally at the top of the effect on every run — even when gated off — so it proves the React hook is being re-invoked regardless of whether messages are being drained.

                Under healthy load this refreshes every time React renders the bridge, typically sub-second. Turns orange when it's been >10s since the effect ran AND frames were still arriving in that window — meaning the React render queue is starved (long task, infinite render loop, etc.).
                """
            )
            statRow(
                "Command last received",
                value: ageString(room.lastCommandReceivedTs, now: room.sampleAt),
                tooltip: """
                Time since the host last entered handleCommand for ANY command kind — including a host:ping answered imperatively. Stamped in both the imperative fast-path and the React-effect path.

                Proves the WebSocket itself is still delivering frames to the bridge. If this goes stale while Frames in keeps climbing, the imperative handler has stopped running — which would be very unusual (pings would stop returning). More commonly it stays fresh due to pings even when the real command flow is wedged.
                """
            )
            statRow(
                "Command last completed",
                value: ageString(room.lastCommandCompletedTs, now: room.sampleAt),
                tooltip: """
                Time since the last agent:start or agent:resume execution chain finished — either success or caught error. 'null' means no agent turn has completed since the host bridge mounted.

                A long age here while 'Pending chains' > 0 is the 'chain is hung' signature: a turn started but its finally block has not fired. Cross-reference with the 'Chain breadcrumbs' list below to see the exact await it's stuck on.
                """
            )
            statRow(
                "Pending chains",
                value: "\(room.pendingCommandCount)",
                tooltip: """
                Count of distinct chatIds that currently have an active per-chat execution chain. Each chat queues sequentially but different chats run in parallel, so this is NOT the total queue depth — it's the number of chats with any in-flight work.

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
    private func inFlightList(_ cmds: [InFlightRow], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("In-flight commands")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                infoIcon("""
                Per-chat list of agent commands currently being executed on the host. An entry appears when a command (agent:start or agent:resume) enters its execution chain and is removed when the chain's finally block fires.

                Age shown per row is how long the command has been running. Rows turn orange at >45s — well past a normal turn. The SAME chatId + kind appearing across many polls without the age resetting is a hung chain; cross-reference with 'Chain breadcrumbs' for the exact await.
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
                    Text(ageString(cmd.startedAt, now: now))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(cmd.startedAt != nil && now.timeIntervalSince1970 * 1000 - cmd.startedAt! > 45_000 ? .orange : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func chainStepList(_ steps: [ChainStepRow], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Chain breadcrumbs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                infoIcon("""
                Per-chat breadcrumb of the most recent await boundary inside the agent:start execution chain. Stamped at: queued, chain-entered, ensureChatLoaded, initializeChatActions, saveUserMessage, ensureChatTab, getModelById, executeAgentWithPrompt. Cleared when the chain's finally fires.

                If an entry persists at the same step across many polls with a growing age, that specific await is hung — names the exact failure point (e.g. 'stuck 47s at ensureChatLoaded' points at IndexedDB; 'stuck at getModelById' points at model API; etc.). Rows turn orange at >45s.
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
                        .foregroundStyle(step.ts != nil && now.timeIntervalSince1970 * 1000 - step.ts! > 45_000 ? .orange : .secondary)
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
                    .foregroundStyle(total > 0 ? .orange : .secondary)
                infoIcon("""
                Commands currently QUEUED behind the running turn on a chat — they cannot start until the in-flight turn on that same chat completes. Each chat has its own serial chain, so a backlog on one chat does not hold up others.

                This is the live count; the worst value is captured in 'Peaks → Max queue backlog' so a backlog that has since drained is still visible after the fact.
                """)
                Spacer()
                Text("\(total) waiting")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.orange)
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
                Text("No notable peaks — clean since reset.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                peakRow(
                    "Max queue backlog",
                    value: "\(peaks.maxQueueBacklog)",
                    detail: peaks.maxQueueBacklog > 0
                        ? "\(shortChat(peaks.maxQueueBacklogChatId)) · \(absTime(peaks.maxQueueBacklogAt))"
                        : nil,
                    warn: peaks.maxQueueBacklog > 0
                )
                peakRow(
                    "Longest in-flight turn",
                    value: fmtDuration(peaks.maxInFlightAgeMs),
                    detail: peaks.maxInFlightAgeMs >= 1
                        ? "\(peaks.maxInFlightAgeKind ?? "?") at '\(peaks.maxInFlightAgeStep ?? "?")' · \(absTime(peaks.maxInFlightAgeAt))"
                        : nil,
                    warn: peaks.maxInFlightAgeMs > 45_000
                )
                peakRow(
                    "Max concurrent chains",
                    value: "\(peaks.maxPendingChains)",
                    detail: peaks.maxPendingChains > 0 ? absTime(peaks.maxPendingChainsAt) : nil,
                    warn: false
                )
                HStack(spacing: 10) {
                    incidentCount("queue-block", peaks.queueBlockCount)
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
    private func incidentCount(_ label: String, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(count > 0 ? .orange : .secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var commsLogCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if commsEntries.isEmpty {
                Text("No comms warnings or errors recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(commsEntries.count) recent · newest first · persists across relaunch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(commsEntries.prefix(40)) { e in
                    commsRow(e)
                }
            }
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
            Text(Self.timestampFormatter.string(from: Date(timeIntervalSince1970: e.ts / 1000)))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(e.source)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(e.isError ? .red : .orange)
                .frame(width: 86, alignment: .leading)
                .lineLimit(1)
            Text(e.message)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    /// Copy ALL comms entries (newest-first) to the clipboard as plain text.
    private func copyCommsLog() {
        let text = commsEntries.map { e -> String in
            let ts = Self.timestampFormatter.string(from: Date(timeIntervalSince1970: e.ts / 1000))
            return "\(ts)  [\(e.isError ? "ERROR" : "WARN")]  \(e.source)  \(e.message)"
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
        while !Task.isCancelled {
            let (nextRooms, nextSelf, diag, comms) = await fetch(previousRooms: previousRooms, previousSelf: previousSelf)
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
        previousSelf: RoomStats?
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
                    guard let last = pings.last else { continue }
                    tmp.append(RoomStats(roomId: roomId, ping: last, previous: previousRooms[roomId]))
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
                selfOut = RoomStats(
                    roomId: "\(machineName) — \(relayState)",
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
                    chatId: e["chatId"] as? String
                )
            }
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
    let lastMessagesEffectRanTs: Double?
    let lastCommandReceivedTs: Double?
    let lastCommandCompletedTs: Double?
    let pendingCommandCount: Int
    let mountEpoch: Double?
    let inFlight: [InFlightRow]
    let chainSteps: [ChainStepRow]
    let peaks: PeaksData?
    let queueDepth: [QueueDepthRow]

    var id: String { roomId }

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

    /// Effect stale = messages effect has not run in > 10s while frames kept arriving.
    var effectStale: Bool {
        guard let ts = lastMessagesEffectRanTs, ts > 0 else { return false }
        let age = sampleAt.timeIntervalSince1970 * 1000 - ts
        return age > 10_000 && (framesSinceLastSample ?? 0) > 0
    }

    var health: HealthStatus {
        if let error {
            return HealthStatus(label: "OFFLINE", color: .red, detail: error)
        }
        // Frames climbing but commands not → React path wedged.
        if let framesDelta = framesSinceLastSample,
           let msgsDelta = messagesSinceLastSample,
           framesDelta > 2 && msgsDelta == 0 {
            return HealthStatus(
                label: "WEDGED",
                color: .orange,
                detail: "Frames arriving (+\(framesDelta)) but no commands drained — React path starved."
            )
        }
        if effectStale {
            return HealthStatus(
                label: "EFFECT STALE",
                color: .orange,
                detail: "Messages effect has not run recently while frames were arriving."
            )
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

        if let previous {
            self.framesSinceLastSample = frames - previous.framesReceived
            self.messagesSinceLastSample = msgs - previous.messagesReceived
        } else {
            self.framesSinceLastSample = nil
            self.messagesSinceLastSample = nil
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
                startedAt: c["startedAt"] as? Double
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
    }

    init(roomId: String, ping: [String: Any], previous: RoomStats?) {
        self.roomId = roomId
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

        // "since last" is relative to the previous POLL (this view), not the
        // previous pong. That's what we actually want to show on a live view.
        if let previous {
            self.framesSinceLastSample = frames - previous.framesReceived
            self.messagesSinceLastSample = msgs - previous.messagesReceived
        } else {
            self.framesSinceLastSample = nil
            self.messagesSinceLastSample = nil
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
                startedAt: c["startedAt"] as? Double
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

    /// True when every watermark is at rest — nothing notable has happened.
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

    var isError: Bool { severity == "error" }
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
            // The serverHostBridge singleton has no provider — the React
            // tree that mounts RemoteHostBridgeProvider didn't run, OR
            // the JS callable itself failed.
            statusLabel = "BRIDGE NOT MOUNTED"
            statusColor = .red
            statusIcon = "exclamationmark.triangle.fill"
            if let err = hostStatusError, !err.isEmpty {
                diagnosis = "__ripulGetHostStatus reports unavailable: \(err). The host-bridge React provider has not registered with the singleton — usually a startup module-load failure. Check the Web Inspector console (Develop → Web Content) for 'Importing a module script failed' or other startup errors."
            } else {
                diagnosis = "__ripulGetHostStatus returned available=false. The RemoteHostBridgeProvider has not registered with the serverHostBridge singleton — its React subtree probably failed to mount. Check the Web Inspector console for startup errors."
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

        if let rs = relayState, rs != "connected" {
            statusLabel = "RELAY \(rs.uppercased())"
            statusColor = (rs == "connecting" || rs == "reconnecting") ? .orange : .red
            statusIcon = "wifi.exclamationmark"
            diagnosis = "Host is enabled and has roomId=\(roomId ?? "?") but the relay WebSocket reports relayState=\(rs). Either the relay endpoint is unreachable, the auth token is rejected, or the connection is mid-handshake."
            return
        }

        if relayState == "connected" {
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
