import SwiftUI

/// One observation: severity dot, title and a line of facts; a tap opens its
/// detail and the person's actions (start, finish, drop, reopen, delete).
/// Used by the chat panel's section and the repository's Observations pane.
@available(iOS 15.0, macOS 13.0, *)
public struct ObservationRow: View {
    let observation: AgentBridge.RepoObservation
    /// The chat this row is shown from, so its own work reads "this chat".
    let thisChatId: String?
    var showRepository = false
    @Binding var isOpen: Bool
    let onPatch: ([String: Any]) -> Void
    let onDelete: () -> Void
    /// Set when a tap on the raising chat should open it.
    var onOpenChat: ((String) -> Void)?

    @State private var closing: String?
    @State private var resolution = ""

    public init(observation: AgentBridge.RepoObservation, thisChatId: String?, isOpen: Binding<Bool>,
                onPatch: @escaping ([String: Any]) -> Void, onDelete: @escaping () -> Void,
                onOpenChat: ((String) -> Void)? = nil, showRepository: Bool = false) {
        self.observation = observation
        self.thisChatId = thisChatId
        self._isOpen = isOpen
        self.onPatch = onPatch
        self.onDelete = onDelete
        self.onOpenChat = onOpenChat
        self.showRepository = showRepository
    }

    public static func severityColor(_ severity: String) -> Color {
        switch severity {
        case "critical": return .ripul(.danger)
        case "high": return .ripul(.warning)
        case "medium": return .ripul(.info)
        default: return .ripul(.textTertiary)
        }
    }

    private var o: AgentBridge.RepoObservation { observation }

    private var facts: String {
        var bits = [o.category, o.kindLabel]
        if showRepository { bits.insert(o.repoKey.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? o.repoKey, at: 0) }
        if o.status != "open" { bits.append(o.statusLabel) }
        if !o.sightings.isEmpty { bits.append("seen \(o.sightings.count + 1)×") }
        if let created = o.createdAt { bits.append(Self.age(created)) }
        return bits.joined(separator: " · ")
    }

    static func age(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return days == 1 ? "yesterday" : "\(days)d"
    }

    private func chatName(_ id: String?, _ title: String?) -> String {
        if let id, id == thisChatId { return "this chat" }
        return title ?? "another chat"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(Self.severityColor(o.severity))
                        .frame(width: 9, height: 9)
                        .accessibilityLabel("\(o.severity) severity")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(o.title).ripulText()
                            .font(.ripul(.subheadline, weight: .semibold))
                            .strikethrough(o.status == "done")
                            .fixedSize(horizontal: false, vertical: true)
                        Text(facts)
                            .font(.ripul(.caption))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.ripulIcon(.caption2, weight: .semibold))
                        .foregroundStyle(.ripul(.textTertiary))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .opacity(o.isClosed ? 0.6 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .uiKitIdentifier("ObservationRow.toggle")

            if isOpen {
                detail
                    .padding(.leading, 19)
            }
        }
        .padding(.vertical, 8)
        .uiKitIdentifier("ObservationRow")
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(o.repoKey)
                .font(.ripul(.caption))
                .foregroundStyle(.ripul(.textSecondary))
                .textSelection(.enabled)
                .uiKitIdentifier("ObservationRow.repository")
            ForEach(Array(o.repositoryMoves.enumerated()), id: \.offset) { _, move in
                Text("Moved \(move.fromRepoKey) → \(move.toRepoKey) by \(move.chatTitle)\(move.at.map { ", \(Self.age($0))" } ?? ""): \(move.note)")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .uiKitIdentifier("ObservationRow.move")
            }
            if !o.detail.isEmpty {
                Text(o.detail).ripulText()
                    .font(.ripul(.subheadline))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !o.files.isEmpty {
                Text(o.files.joined(separator: ", "))
                    .font(.ripul(.caption, family: .code))
                    .foregroundStyle(.ripul(.textSecondary))
                    .textSelection(.enabled)
            }
            raisedLine
            if let resolution = o.resolution {
                Text("\(o.statusLabel): \(resolution)").ripulText()
                    .font(.ripul(.caption))
            }
            ForEach(o.sightings, id: \.chatId) { s in
                Text("Seen again by \(chatName(s.chatId, s.chatTitle))\(s.note.map { ": \($0)" } ?? "")")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            if let closing {
                closeField(closing)
            } else {
                actions
            }
        }
    }

    @ViewBuilder
    private var raisedLine: some View {
        let raised = "Raised by \(chatName(o.raisedByChatId, o.raisedByTitle))"
            + (o.raisedOn.map { " on \($0)" } ?? "")
            + (o.branch.map { ", \($0)" } ?? "")
            + (o.status == "doing" ? " · in hand: \(chatName(o.claimedByChatId, o.claimedByTitle))" : "")
        if let onOpenChat, !o.raisedByChatId.isEmpty, o.raisedByChatId != thisChatId, o.raisedByChatId != "person" {
            Button { onOpenChat(o.raisedByChatId) } label: {
                Text(raised).font(.ripul(.caption)).foregroundStyle(.ripul(.info))
            }
            .buttonStyle(.plain)
            .uiKitIdentifier("ObservationRow.openChat")
        } else {
            Text(raised).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
        }
    }

    private var actions: some View {
        HStack(spacing: 14) {
            if o.status == "open" {
                actionButton("Start", id: "start") { onPatch(["status": "doing"]) }
            }
            if !o.isClosed {
                actionButton("Done", id: "done") { resolution = ""; closing = "done" }
                actionButton("Drop", id: "drop") { resolution = ""; closing = "dropped" }
            }
            if o.isClosed || o.status == "doing" {
                actionButton("Reopen", id: "reopen") { onPatch(["status": "open"]) }
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.ripulIcon(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
            .uiKitIdentifier("ObservationRow.delete")
        }
        .padding(.top, 2)
    }

    private func actionButton(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.ripul(.subheadline, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.ripul(.info))
            .uiKitIdentifier("ObservationRow.\(id)")
    }

    private func closeField(_ status: String) -> some View {
        HStack(spacing: 4) {
            TextField(status == "done" ? "How it was done (optional)" : "Why it no longer applies (optional)", text: $resolution)
                .textFieldStyle(.roundedBorder)
                .font(.ripul(.subheadline))
                .submitLabel(.done)
                .onSubmit { finish(status) }
                .uiKitIdentifier("ObservationRow.resolution")
            Button { closing = nil } label: {
                Image(systemName: "xmark")
                    .font(.ripulIcon(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
            Button { finish(status) } label: {
                Image(systemName: "checkmark")
                    .font(.ripulIcon(.caption))
                    .foregroundStyle(.ripul(.info))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save")
            .uiKitIdentifier("ObservationRow.resolution.save")
        }
    }

    private func finish(_ status: String) {
        var patch: [String: Any] = ["status": status]
        let line = resolution.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { patch["resolution"] = String(line.prefix(200)) }
        onPatch(patch)
        closing = nil
    }
}
