import SwiftUI
import MarkdownUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Agent comms: one agent's calls (send, start, wait, archive) and the list of
// agents. Both lead with who and where things stand. Ids, handles and settings
// are kept, labelled, under Details: they are how the calls address each other,
// not what a person reads them for.

// MARK: - A call about one agent

/// The web's shared presentation says who the call was about and where it
/// stands, so this draws the same facts as the web card.
struct NativeAgentCommsToolView: View {
    let content: NativeToolContent

    var body: some View {
        if let shown = content.call.agentComms {
            HStack(alignment: .center, spacing: 12) {
                NativeAgentGlyph(model: shown.target.model, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.verb).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    Text(shown.target.name).font(.ripul(.headline))
                    let runtime = NativeAgentRuntime.text(harness: shown.target.harness, model: shown.target.model,
                                                          shown.target.machine.map { "on \($0)" })
                    if !runtime.isEmpty { Text(runtime).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("NativeTool.agent.who")

            NativeAgentStatusLine(status: shown.status, live: content.running)
            if let sent = shown.sent {
                NativeToolSection(title: content.args["task"] != nil ? "Task" : "Message") {
                    NativeToolProse(text: sent, identifier: "NativeTool.agent.sent")
                }
            }
            if let reply = shown.reply {
                NativeToolSection(title: "Reply") {
                    NativeToolProse(text: reply, collapsedHeight: 320, identifier: "NativeTool.agent.reply")
                }
            }
            if shown.unreadResult == true, content.output != nil { NativeToolResultView(content: content) }
            if let caption = shown.caption { Text(caption).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)) }
            if let rows = shown.details, !rows.isEmpty {
                DisclosureGroup("Details") { NativeAgentDetailRows(rows: rows).padding(.top, 8) }
            }
            NativeToolParameters(args: content.args, excluding: Self.shownArguments, title: "Other parameters")
        } else {
            // A web build from before the card sends no presentation.
            let sent = content.string("task", "message")
            if !sent.isEmpty { NativeToolSection(title: "Message") { NativeToolProse(text: sent) } }
            NativeToolParameters(args: content.args, excluding: ["task", "message"])
            NativeToolResultView(content: content)
        }
    }

    /// Arguments the card or its Details already account for.
    private static let shownArguments: Set<String> = [
        "task", "message", "agentId", "handle", "title", "harness", "model", "cwd", "effort",
        "wait", "timeoutSec", "expectReply", "device", "machine",
    ]
}

/// "Claude Code · Opus · on MacBook Pro".
enum NativeAgentRuntime {
    static func text(harness: String?, model: String?, _ more: String?...) -> String {
        let label = ModelIdentity.resolve(modelId: model)?.label
        // A CLI's default model is named after the CLI ("Codex Shared Default"): saying it twice adds nothing.
        let named = harness.map { label?.lowercased().hasPrefix($0.lowercased()) == true } == true ? nil : label
        return ([harness, named] + more).compactMap { $0 }.joined(separator: " · ")
    }
}

/// The model's own glyph and colour, as the session list shows them.
private struct NativeAgentGlyph: View {
    let model: String?
    let size: CGFloat

    var body: some View {
        let identity = ModelIdentity.resolve(modelId: model)
        let color = identity?.color ?? Color.ripul(.textSecondary)
        Text(identity?.glyph ?? "◆")
            .font(.ripul(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct NativeAgentStatusLine: View {
    let status: AgentCommsPresentation.Status
    /// The call itself is still running, not just the agent it reached.
    let live: Bool

    var body: some View {
        let failed = status.tone == "error"
        let done = status.tone == "ok"
        Label {
            Text(status.text).foregroundStyle(failed ? Color.ripul(.danger) : Color.ripul(.text))
        } icon: {
            if live && !failed && !done {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: failed ? "exclamationmark.circle.fill" : done ? "checkmark.circle.fill" : "clock")
                    .foregroundStyle(failed ? Color.ripul(.danger) : done ? Color.ripul(.success) : Color.ripul(.warning))
            }
        }
        .font(.ripul(.subheadline))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("NativeTool.agent.status")
    }
}

/// Markdown held to a few lines until asked for, so a long task does not push
/// the reply off the screen.
struct NativeToolProse: View {
    let text: String
    var collapsedHeight: CGFloat = 132
    var identifier = "NativeTool.prose"
    /// Adds a Raw button beside Copy. Off unless a caller asks: prose is shown rendered.
    var rawToggle = false
    @NativeRowState("prose.raw") private var raw = false
    @Environment(\.openURL) private var openURL
    @State private var fullHeight: CGFloat = 0
    @NativeRowState("prose.expanded") private var expanded = false
    @ScaledMetric private var scale: CGFloat = 1

    var proseScopeKey: String { identifier }

    var body: some View {
        let isRaw = _raw.value(subscope: proseScopeKey)
        let isExpanded = _expanded.value(subscope: proseScopeKey)
        let limit = collapsedHeight * scale
        // Before the first measurement, guess from the text so a long one does
        // not open at full height and then fold. A line or two hidden is not
        // worth a control.
        let overflows = fullHeight > 0 ? fullHeight > limit + 44 * scale : text.count > Int(limit) * 5
        let folded = overflows && !isExpanded
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Spacer()
                Button("Copy") {
                    #if os(iOS)
                    UIPasteboard.general.string = text
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    #endif
                }.accessibilityIdentifier("\(identifier).copy")
                if rawToggle {
                    Button(isRaw ? "Rendered" : "Raw") { _raw.setValue(!isRaw, subscope: proseScopeKey) }
                        .accessibilityIdentifier("\(identifier).raw")
                }
            }.font(.ripul(.caption))
            Group {
                if rawToggle && isRaw { Text(text).font(.ripul(.callout, family: .code)) }
                else {
                    Markdown(text)
                        .environment(\.openURL, OpenURLAction { url in
                            guard NativeToolNarrative.allowsLink(url) else { return .discarded }
                            openURL(url)
                            return .handled
                        })
                }
            }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .frame(maxWidth: .infinity, maxHeight: folded ? limit : nil, alignment: .topLeading)
                .clipped()
                .mask {
                    if folded { LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom) } // theme-exempt: a mask, only its alpha is used
                    else { Rectangle() }
                }
            if overflows {
                Button(isExpanded ? "Show less" : "Show more") { _expanded.setValue(!isExpanded, subscope: proseScopeKey) }
                    .font(.ripul(.callout))
                    .accessibilityIdentifier("\(identifier).toggle")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Labelled values in the order given.
struct NativeAgentDetailRows: View {
    let rows: [AgentCommsPresentation.Detail]

    var body: some View {
        NativeToolFieldFlowLayout(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                NativeToolFieldControl(label: row.label, isLiteral: NativeToolNarrative.isLiteralField(row.label)) {
                    Text(row.value).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NativeTool.agent.details")
    }
}

// MARK: - The list of agents

/// The recorded result of list_agents, read for display.
struct NativeAgentList {
    struct Agent: Identifiable, Equatable {
        let id: String
        let title: String
        let model: String?
        /// "Claude Code".
        let harness: String?
        /// `running`, `waiting_for_input` or `idle`.
        let status: String
        let lastActive: Date?
        /// What it is working on, or the last thing it said.
        let activity: String?
        let folder: String?
        let branch: String?
        let device: String?
        let startedByCaller: Bool
    }

    /// A message between the caller and another agent that has not settled.
    struct Delivery: Equatable {
        let summary: String
        let state: String
    }

    let agents: [Agent]
    /// The Mac that was listed, when it is not the caller's own.
    let machine: String?
    let otherMachines: [String]
    let inFlight: [Delivery]
    /// Everything the face leaves out, for Details.
    let rest: [String: CmsJSON]

    /// Nil when the output is not a list: an error, or nothing yet.
    init?(_ output: CmsJSON?) {
        guard let object = output?.objectValue, let rows = object["agents"]?.toolArray else { return nil }
        let labels = Dictionary((object["harnesses"]?.toolArray ?? []).compactMap { item -> (String, String)? in
            guard let fields = item.objectValue, let key = fields.string("harness"), let label = fields.string("label") else { return nil }
            return (key, label)
        }, uniquingKeysWith: { first, _ in first })
        agents = rows.enumerated().compactMap { index, row in
            guard let fields = row.objectValue else { return nil }
            let status = fields.string("status") ?? "idle"
            let doing = fields.string("currentTask"), said = fields.string("lastReply")
            return Agent(
                id: fields.string("agentId") ?? "agent-\(index)",
                title: fields.string("title") ?? "Untitled chat",
                model: fields.string("model"),
                harness: fields.string("harness").map { labels[$0] ?? $0.prefix(1).uppercased() + $0.dropFirst() },
                status: status,
                lastActive: fields.string("lastActive").flatMap {
                    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0)) ?? (try? Date.ISO8601FormatStyle().parse($0))
                },
                // A working agent is best told by its task; any other by what it last said.
                activity: status == "running" ? doing ?? said : said ?? doing,
                folder: fields.string("cwd").map { ($0 as NSString).lastPathComponent },
                branch: fields.string("gitBranch"),
                device: fields["device"]?.objectValue?.string("device"),
                startedByCaller: fields.bool("startedByYou") == true)
        }
        machine = object.string("machine")
        otherMachines = (object["machines"]?.toolArray ?? []).compactMap { $0.objectValue?.string("machine") }
        let caller = object["self"]?.objectValue?.string("agentId")
        let names = Dictionary(agents.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        inFlight = (object["pending"]?.toolArray ?? []).compactMap { item in
            guard let fields = item.objectValue else { return nil }
            let kind = ["task": "Task", "reply": "Reply"][fields.string("kind") ?? ""] ?? "Message"
            let outgoing = caller != nil && fields.string("from") == caller
            let other = (outgoing ? fields.string("to") : fields.string("from")).flatMap { names[$0] } ?? "another agent"
            return Delivery(summary: "\(kind) \(outgoing ? "to" : "from") \(other)", state: ToolValue.title(fields.string("status") ?? "pending"))
        }
        rest = object.filter { $0.key != "agents" }
    }

    var summary: String {
        guard !agents.isEmpty else { return "No other agents" }
        let working = agents.filter { $0.status == "running" }.count
        let waiting = agents.filter { $0.status == "waiting_for_input" }.count
        var parts = [agents.count == 1 ? "1 agent" : "\(agents.count) agents"]
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs input" : "\(waiting) need input") }
        return parts.joined(separator: " · ")
    }

    /// What Details shows as fields: the rest of the result, and what was asked for.
    func rest(filter: [String: CmsJSON]) -> [String: CmsJSON] {
        var fields = rest
        if !filter.isEmpty { fields["filter"] = .object(filter) }
        return fields
    }

    /// The ids the rows leave out, by the name each row shows.
    var ids: [AgentCommsPresentation.Detail] {
        agents.map { .init(label: $0.title, value: $0.id) }
    }

    /// How long before the list was taken an agent was last active.
    static func ago(_ date: Date, asOf: Date) -> String {
        guard asOf.timeIntervalSince(date) >= 60 else { return "just now" }
        return relative.localizedString(for: date, relativeTo: asOf)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

struct NativeAgentListToolView: View {
    let content: NativeToolContent
    @NativeRowState("agentList.visibleRows") private var visibleRows = 20

    var body: some View {
        let currentVisibleRows = _visibleRows.value(subscope: content.call.id)
        if let list = NativeAgentList(content.output) {
            // Times are told as of the call: this is a record, not a live list.
            let asOf = content.call.timestamp > 0 ? Date(timeIntervalSince1970: content.call.timestamp / 1000) : Date()
            VStack(alignment: .leading, spacing: 4) {
                if let machine = list.machine { Label("On \(machine)", systemImage: "desktopcomputer").font(.ripul(.subheadline)) }
                Text(list.summary).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                    .accessibilityIdentifier("NativeTool.agentList.summary")
            }
            if !list.agents.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(list.agents.prefix(currentVisibleRows).enumerated()), id: \.element.id) { index, agent in
                        NativeAgentRow(agent: agent, asOf: asOf)
                            .accessibilityIdentifier("NativeTool.agentList.row.\(index)")
                        if index < min(list.agents.count, currentVisibleRows) - 1 { Divider() }
                    }
                    if list.agents.count > currentVisibleRows {
                        Button("Show more (\(list.agents.count - currentVisibleRows) remaining)") {
                            _visibleRows.setValue(currentVisibleRows + 40, subscope: content.call.id)
                        }
                    }
                }
            }
            if !list.inFlight.isEmpty {
                NativeToolSection(title: "In flight") {
                    ForEach(Array(list.inFlight.enumerated()), id: \.offset) { _, delivery in
                        Label {
                            HStack(alignment: .firstTextBaseline) {
                                Text(delivery.summary)
                                Spacer(minLength: 8)
                                Text(delivery.state).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                            }
                        } icon: { Image(systemName: "paperplane").foregroundStyle(.ripul(.textSecondary)) }
                    }
                }
            }
            if !list.otherMachines.isEmpty {
                NativeToolSection(title: "Other Macs") {
                    ForEach(list.otherMachines, id: \.self) { name in
                        Label { Text(name) } icon: { Image(systemName: "desktopcomputer").foregroundStyle(.ripul(.textSecondary)) }
                    }
                }
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 12) {
                    NativeAgentDetailRows(rows: list.ids)
                    NativeToolValueView(value: .object(list.rest(filter: content.args)))
                }
                .padding(.top, 8)
            }
        } else {
            NativeToolParameters(args: content.args)
            NativeToolResultView(content: content)
        }
    }
}

private struct NativeAgentRow: View {
    let agent: NativeAgentList.Agent
    let asOf: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NativeAgentGlyph(model: agent.model, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(agent.title).font(.ripul(.subheadline, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    stateTag
                }
                let runtime = NativeAgentRuntime.text(harness: agent.harness, model: agent.model,
                                                      agent.lastActive.map { NativeAgentList.ago($0, asOf: asOf) })
                if !runtime.isEmpty { Text(runtime).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)) }
                if let activity = agent.activity { Text(activity).font(.ripul(.callout)).lineLimit(3) }
                if agent.folder != nil || agent.branch != nil || agent.device != nil || agent.startedByCaller {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { facts }
                        VStack(alignment: .leading, spacing: 2) { facts }
                    }
                    .font(.ripul(.caption2)).foregroundStyle(.ripul(.textSecondary)).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var facts: some View {
        let place = [agent.folder, agent.branch].compactMap { $0 }.joined(separator: " · ")
        if !place.isEmpty { Label(place, systemImage: "folder") }
        if let device = agent.device { Label(device, systemImage: "iphone") }
        if agent.startedByCaller { Label("Started by this chat", systemImage: "arrow.turn.down.right") }
    }

    private var stateTag: some View {
        let working = agent.status == "running"
        let waiting = agent.status == "waiting_for_input"
        let color: Color = working ? .ripul(.warning) : waiting ? .ripul(.info) : .ripul(.textSecondary)
        return Text(working ? "Working" : waiting ? "Needs input" : "Idle")
            .font(.ripul(.caption2, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.08), in: Capsule())
            .fixedSize()
    }
}
