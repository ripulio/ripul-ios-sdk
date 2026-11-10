import SwiftUI

/// Resolves `AgentCommsPresentation.SessionItem` entries against the host's
/// live `RipulSessionListModel` and `AgentBridge.sessions` so in-chat session
/// lists (`present_chats`, `search_chats`, `list_agents`) reuse `UnifiedSessionRow`
/// with live turn phase, tool lozenges, unread dots, and tap-to-open navigation.
enum NativeChatSessionListResolver {
    @MainActor static let fallbackSessionStore = SessionListStore()

    static func bareSessionId(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        if let colonRange = value.range(of: #"^[a-z0-9-]+-cli:"#, options: [.regularExpression, .caseInsensitive]) {
            value = String(value[colonRange.upperBound...])
        }
        if value.hasPrefix("cli_") {
            value = String(value.dropFirst(4))
        }
        return value
    }

    static func decodeReference(_ encoded: String?) -> [String: String]? {
        guard let encoded = encoded?.trimmingCharacters(in: .whitespacesAndNewlines), !encoded.isEmpty else {
            return nil
        }
        var b64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder > 0 {
            b64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var result: [String: String] = [:]
        for (k, v) in obj {
            if let str = v as? String, !str.isEmpty {
                result[k] = str
            }
        }
        return result
    }

    static func candidateKeys(for item: AgentCommsPresentation.SessionItem, ref: [String: String]? = nil) -> Set<String> {
        let resolvedRef = ref ?? decodeReference(item.reference)
        var keys: Set<String> = []
        for raw in [item.chatId, item.agentId, item.sessionId, resolvedRef?["chatId"], resolvedRef?["sessionId"]].compactMap({ $0 }) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            keys.insert(trimmed)
            let bare = bareSessionId(trimmed)
            if !bare.isEmpty {
                keys.insert(bare)
                keys.insert("cli_\(bare)")
                keys.insert(UnifiedSession.cliUuid(for: bare))
            }
        }
        return keys
    }

    private static func providerInfo(for harness: String?, refProvider: String?) -> (provider: String?, label: String?) {
        let raw = (harness ?? refProvider ?? "").lowercased()
        if raw.contains("claude") {
            return ("claude-cli", "Claude Code")
        }
        if raw.contains("codex") {
            return ("codex-shared-cli", "Codex")
        }
        if raw.contains("antigravity") {
            return ("antigravity-cli", "Antigravity")
        }
        guard let harness, !harness.isEmpty else { return (refProvider, nil) }
        return (refProvider ?? harness, harness.prefix(1).uppercased() + harness.dropFirst())
    }

    private static func parseDate(_ iso: String?) -> Date? {
        guard let iso = iso?.trimmingCharacters(in: .whitespacesAndNewlines), !iso.isEmpty else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso))
            ?? (try? Date.ISO8601FormatStyle().parse(iso))
    }

    @MainActor
    static func resolveUnifiedSession(
        for item: AgentCommsPresentation.SessionItem,
        listModel: RipulSessionListModel?,
        bridge: AgentBridge?
    ) -> UnifiedSession {
        let ref = decodeReference(item.reference)
        let keys = candidateKeys(for: item, ref: ref)
        let wantedMachineId = item.machineId ?? ref?["directHostId"] ?? ref?["machineId"]
        let wantedMachineName = item.machine ?? ref?["machineName"]

        if let unified = listModel?.unifiedSessions, !unified.isEmpty {
            let matching = unified.filter { session in
                !keys.isDisjoint(with: session.mergeKeys)
            }
            let best = matching.first(where: { session in
                if let wantedMachineId, !wantedMachineId.isEmpty, session.machineId == wantedMachineId { return true }
                if let wantedMachineName, !wantedMachineName.isEmpty,
                   session.machineName?.caseInsensitiveCompare(wantedMachineName) == .orderedSame { return true }
                return false
            }) ?? matching.first

            if let best {
                if let explicitTitle = item.title ?? ref?["title"],
                   !explicitTitle.isEmpty,
                   (best.title.isEmpty || best.title.hasPrefix("cli_") || best.title == best.id) {
                    return best.withRipulSession(best.ripulSession, title: explicitTitle)
                }
                return best
            }
        }

        let matchedTab = bridge?.sessions.first(where: { tab in
            keys.contains(tab.id) || keys.contains(tab.sourceChatId)
        })
        let bare = bareSessionId(item.sessionId ?? item.agentId ?? item.chatId)
        let id = bare.isEmpty ? item.chatId : bare
        let resolvedTitle = item.title
            ?? ref?["title"]
            ?? matchedTab?.displayName
            ?? "Chat \(String(id.prefix(8)))"
        let lastUsed = parseDate(item.lastActive) ?? Date()
        let projectPath = item.cwd
        let projectName = projectPath.map { ($0 as NSString).lastPathComponent }
        let (provider, providerLabel) = providerInfo(for: item.harness, refProvider: ref?["provider"])
        let resolvedMachineId = wantedMachineId ?? (listModel?.machines.count == 1 ? listModel?.machines.first?.machineId : nil)
        let resolvedMachineName = wantedMachineName ?? listModel?.machines.first(where: { $0.machineId == resolvedMachineId })?.displayName

        return UnifiedSession(
            id: id,
            title: resolvedTitle,
            lastUsed: lastUsed,
            hasKnownActivity: item.lastActive != nil,
            gitBranch: item.gitBranch,
            messageCount: nil,
            projectName: projectName,
            projectPath: projectPath,
            provider: provider ?? matchedTab?.provider,
            providerLabel: providerLabel,
            model: item.model,
            machineName: resolvedMachineName,
            machineId: resolvedMachineId,
            matchKeys: Array(keys),
            titleFromScan: item.title != nil,
            runningOnHost: item.status == "running",
            ripulSession: matchedTab
        )
    }

    @MainActor
    static func openSession(
        item: AgentCommsPresentation.SessionItem,
        resolved: UnifiedSession,
        listModel: RipulSessionListModel?,
        bridge: AgentBridge?,
        sourceChatId: String?
    ) {
        if listModel != nil {
            RipulOpenSessionRequest.open(
                sessionId: resolved.id,
                machineId: resolved.machineId,
                fallback: resolved
            )
            return
        }
        guard let bridge else { return }
        if let ref = item.reference, !ref.isEmpty {
            bridge.send([
                "type": "agent-framework:nativeChat:action",
                "op": "openChatReference",
                "chatId": sourceChatId ?? "",
                "ref": ref,
            ])
            return
        }
        bridge.send([
            "type": "agent-framework:nativeChat:action",
            "op": "openChatSession",
            "chatId": sourceChatId ?? "",
            "targetChatId": item.chatId,
            "sessionId": resolved.id,
            "machineId": resolved.machineId ?? "",
            "machine": resolved.machineName ?? "",
            "title": resolved.title,
        ])
    }

    /// Extracts session items from a `NativeToolContent` for `ToolCallDetailsSheet`
    /// (`present_chats`, `search_chats`, `list_agents`).
    static func extractItems(from content: NativeToolContent) -> [AgentCommsPresentation.SessionItem] {
        if let existing = content.call.agentComms?.sessions, !existing.isEmpty {
            return existing
        }
        let defaultMachine = content.output?.objectValue?.string("machine") ?? content.args.string("machine")
        if let object = content.output?.objectValue {
            if let chats = object["chats"]?.toolArray {
                return chats.compactMap { parseSessionItem($0, defaultMachine: defaultMachine) }
            }
            if let matches = object["matches"]?.toolArray {
                return matches.compactMap { parseSessionItem($0, defaultMachine: defaultMachine) }
            }
            if let agents = object["agents"]?.toolArray {
                return agents.compactMap { parseSessionItem($0, defaultMachine: defaultMachine) }
            }
        }
        if let chats = content.args["chats"]?.toolArray {
            return chats.compactMap { parseSessionItem($0, defaultMachine: defaultMachine) }
        }
        if let chatIds = content.args["chatIds"]?.toolArray {
            return chatIds.compactMap { parseSessionItem($0, defaultMachine: defaultMachine) }
        }
        return []
    }

    private static func parseSessionItem(_ json: CmsJSON, defaultMachine: String?) -> AgentCommsPresentation.SessionItem? {
        if let str = json.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            return AgentCommsPresentation.SessionItem(chatId: str, machine: defaultMachine)
        }
        guard let obj = json.objectValue else { return nil }
        let ref = decodeReference(obj.string("reference"))
        guard let chatId = obj.string("chatId")
            ?? obj.string("agentId")
            ?? obj.string("sessionId")
            ?? obj.string("id")
            ?? ref?["chatId"]
            ?? ref?["sessionId"] else {
            return nil
        }
        let snippets: [AgentCommsPresentation.Snippet]? = obj["snippets"]?.toolArray?.compactMap { item in
            guard let sObj = item.objectValue, let text = sObj.string("text"), !text.isEmpty else { return nil }
            let line = sObj.double("line").map { Int($0) }
            return AgentCommsPresentation.Snippet(
                line: line,
                role: sObj.string("role"),
                at: sObj.string("at"),
                text: text
            )
        }
        return AgentCommsPresentation.SessionItem(
            chatId: chatId,
            agentId: obj.string("agentId"),
            sessionId: obj.string("sessionId") ?? ref?["sessionId"],
            title: obj.string("title") ?? ref?["title"],
            harness: obj.string("harness") ?? ref?["provider"]?.replacingOccurrences(of: "-cli", with: ""),
            model: obj.string("model"),
            machine: obj.string("machine") ?? obj.string("machineName") ?? ref?["machineName"] ?? defaultMachine,
            machineId: obj.string("machineId") ?? ref?["directHostId"] ?? ref?["machineId"],
            cwd: obj.string("cwd"),
            gitBranch: obj.string("gitBranch"),
            status: obj.string("status"),
            lastActive: obj.string("lastActive"),
            archived: obj.bool("archived"),
            reference: obj.string("reference"),
            note: obj.string("note"),
            currentTask: obj.string("currentTask"),
            lastReply: obj.string("lastReply"),
            snippets: snippets?.isEmpty == false ? snippets : nil
        )
    }
}

/// In-chat session list view used by `NativeChatView` and `ToolCallDetailsSheet`
/// for `present_chats`, `search_chats`, and `list_agents`.
///
/// Reuses `UnifiedSessionRow` directly so every row shows live turn phase,
/// tool lozenge, model glyph, unread state, and opens the session on tap.
@available(iOS 16.0, macOS 14.0, *)
struct NativeChatSessionListView: View {
    let items: [AgentCommsPresentation.SessionItem]
    var title: String? = nil
    var emptyText: String = "No matching chats."
    var framed: Bool = false
    var bridge: AgentBridge? = nil
    var sourceChatId: String? = nil

    @Environment(\.ripulSessionListModel) private var listModel

    private struct ResolvedItem: Identifiable {
        let id: String
        let item: AgentCommsPresentation.SessionItem
        let session: UnifiedSession
        let groupMachine: String?
    }

    private struct MachineSection: Identifiable {
        let id: String
        let machineName: String?
        let rows: [ResolvedItem]
    }

    private var sections: [MachineSection] {
        let resolved: [ResolvedItem] = items.enumerated().map { idx, item in
            let session = NativeChatSessionListResolver.resolveUnifiedSession(
                for: item,
                listModel: listModel,
                bridge: bridge
            )
            let machineLabel = item.machine ?? session.machineName
            return ResolvedItem(
                id: "\(item.id)-\(idx)",
                item: item,
                session: session,
                groupMachine: machineLabel
            )
        }
        let distinctMachines = Set(resolved.compactMap(\.groupMachine))
        let shouldShowHeaders = distinctMachines.count > 1 || resolved.contains(where: { $0.item.machine != nil })
        guard shouldShowHeaders else {
            return [MachineSection(id: "all", machineName: nil, rows: resolved)]
        }
        var order: [String] = []
        var grouped: [String: [ResolvedItem]] = [:]
        for row in resolved {
            let key = row.groupMachine ?? ""
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(row)
        }
        return order.map { key in
            MachineSection(
                id: key.isEmpty ? "local" : key,
                machineName: key.isEmpty ? nil : key,
                rows: grouped[key] ?? []
            )
        }
    }

    var body: some View {
        if framed {
            VStack(alignment: .leading, spacing: 0) {
                headerBar
                Divider()
                listBody
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.ripul(.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.ripul(.separator), lineWidth: 1)
            )
            .accessibilityIdentifier("NativeChatSessionList.container")
        } else {
            listBody
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.ripulIcon(size: 13, weight: .semibold))
                .foregroundStyle(.ripul(.info))
            Text(title ?? "Chats")
                .font(.ripul(.subheadline, weight: .semibold))
                .foregroundStyle(.ripul(.text))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(items.count)")
                .font(.ripul(.caption2, weight: .bold, family: .code))
                .foregroundStyle(.ripul(.info))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.ripul(.info).opacity(0.14), in: Capsule())
                .accessibilityIdentifier("NativeChatSessionList.header.count")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.ripul(.info).opacity(0.06))
        .accessibilityIdentifier("NativeChatSessionList.header")
    }

    private var listBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text(emptyText)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("NativeChatSessionList.empty")
            } else {
                ForEach(sections) { section in
                    if let machineName = section.machineName {
                        HStack(spacing: 6) {
                            Image(systemName: "desktopcomputer")
                                .font(.ripulIcon(.caption2, weight: .semibold))
                                .foregroundStyle(.ripul(.textSecondary))
                            Text(machineName)
                                .font(.ripul(.caption2, weight: .semibold))
                                .foregroundStyle(.ripul(.textSecondary))
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                        .accessibilityIdentifier("NativeChatSessionList.machine.\(machineName)")
                    }
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row: row, index: index, isLast: index == section.rows.count - 1)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NativeChatSessionList")
    }

    @ViewBuilder
    private func rowView(row: ResolvedItem, index: Int, isLast: Bool) -> some View {
        let item = row.item
        let session = row.session
        let hasAnnotations = (item.note?.isEmpty == false)
            || (item.currentTask?.isEmpty == false)
            || (item.lastReply?.isEmpty == false)
            || (item.snippets?.isEmpty == false)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                NativeChatSessionListResolver.openSession(
                    item: item,
                    resolved: session,
                    listModel: listModel,
                    bridge: bridge,
                    sourceChatId: sourceChatId
                )
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        UnifiedSessionRow(
                            sessionStore: bridge?.sessionList ?? NativeChatSessionListResolver.fallbackSessionStore,
                            session: session,
                            isOpening: listModel?.openingUnifiedSessionId == session.id
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    } else {
                        fallbackRow(session: session)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }

                    if hasAnnotations {
                        annotationsView(item: item)
                            .padding(.leading, 48)
                            .padding(.trailing, 12)
                            .padding(.bottom, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NativeChatSessionList.row.\(index)")

            if !isLast {
                Divider()
                    .padding(.leading, 48)
                    .padding(.trailing, 12)
            }
        }
    }

    private func fallbackRow(session: UnifiedSession) -> some View {
        let identity = ModelIdentity.resolve(modelId: session.model ?? session.provider)
        let glyphColor = identity?.color ?? Color.ripul(.textSecondary)
        return HStack(alignment: .center, spacing: 10) {
            Text(identity?.glyph ?? "◆")
                .font(.ripul(size: 14, weight: .semibold))
                .foregroundStyle(glyphColor)
                .frame(width: 28, height: 28)
                .background(glyphColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.ripul(.subheadline, weight: .semibold))
                    .foregroundStyle(.ripul(.text))
                    .lineLimit(1)
                let subtitle = [session.providerLabel, session.projectName, session.gitBranch].compactMap { $0 }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
    }

    @ViewBuilder
    private func annotationsView(item: AgentCommsPresentation.SessionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = item.note, !note.isEmpty {
                Text(note)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier("NativeChatSessionList.note")
            }
            if let task = item.currentTask, !task.isEmpty {
                (Text("Task: ").font(.ripul(.caption, weight: .semibold)).foregroundColor(Color.ripul(.text))
                 + Text(task).font(.ripul(.caption)).foregroundColor(Color.ripul(.textSecondary)))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier("NativeChatSessionList.task")
            }
            if let reply = item.lastReply, !reply.isEmpty {
                (Text("Reply: ").font(.ripul(.caption, weight: .semibold)).foregroundColor(Color.ripul(.text))
                 + Text(reply).font(.ripul(.caption)).foregroundColor(Color.ripul(.textSecondary)))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier("NativeChatSessionList.reply")
            }
            if let snippets = item.snippets, !snippets.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(snippets.prefix(3).enumerated()), id: \.offset) { _, snippet in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let line = snippet.line {
                                Text("L\(line)")
                                    .font(.ripul(.caption2, family: .code))
                                    .foregroundStyle(.ripul(.textTertiary))
                            }
                            Text(snippet.text)
                                .font(.ripul(.caption))
                                .foregroundStyle(.ripul(.textSecondary))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.ripul(.separator))
                                .frame(width: 2)
                        }
                        .accessibilityIdentifier("NativeChatSessionList.snippet")
                    }
                }
            }
        }
    }
}
