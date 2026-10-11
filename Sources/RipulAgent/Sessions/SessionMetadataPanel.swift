import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Native session metadata panel — shown by swiping left from the chat view.
/// Mirrors the web MetadataPanel with glass styling and inline editing.
///
/// Ported verbatim from the native app (`Shared/SessionMetadataPanel.swift`)
/// for the M8 whole-screen extraction — keep semantics identical to the app.
@available(iOS 15.0, macOS 13.0, *)
public struct SessionMetadataPanel: View {
    // Plain `let`, not @ObservedObject: the body reads no @Published field, and
    // observing the whole bridge re-rendered the docked panel on every publish.
    let bridge: AgentBridge
    let session: ChatSession?

    @State private var metadata: AgentBridge.SessionMetadata?
    @State private var loading = false
    @State private var storage: AgentBridge.SessionStorageBreakdown?
    @State private var anchorList: (chatId: String, anchors: [AgentBridge.HumanChatAnchor])?

    // Section expansion
    @State private var messagesExpanded = true
    @State private var messagesSearch = ""
    @State private var filesExpanded = true
    @State private var deploysExpanded = true
    @State private var participantsExpanded = true
    @State private var notesExpanded = true
    @State private var cliToolsExpanded = false
    @State private var debugExpanded = false

    // Description editing
    @State private var editingDescription = false
    @State private var descriptionDraft = ""

    // Note adding
    @State private var addingNote = false
    @State private var noteDraft = ""

    public init(bridge: AgentBridge, session: ChatSession?) {
        self.bridge = bridge
        self.session = session
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                descriptionSection
                messagesSection
                modelSection
                filesSection
                deploymentsSection
                participantsSection
                notesSection
                cliToolsSection
                debugSection

                if !loading && metadata == nil {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .uiKitIdentifier("SessionMetadataPanel")
        // Keyed on the chat, so a switch cancels the old load and starts one
        // for the new chat. (The old one-argument `onChange` ran its closure
        // with the view from BEFORE the change, so a switch reloaded the chat
        // just left.)
        .task(id: session?.sourceChatId) {
            guard let chatId = session?.sourceChatId else { return }
            metadata = nil
            storage = nil
            messagesSearch = ""
            if debugExpanded { Task { await loadStorage() } }
            await loadMetadata(chatId)
        }
        .task(id: session?.sourceChatId) {
            guard let chatId = session?.sourceChatId else { return }
            await loadAnchors(chatId, waitForChat: true)
        }
        // A turn starting means a message was just sent; ending means the
        // chat settled. Either way the anchor list may have grown.
        .onChange(of: bridge.isAgentRunning) {
            guard let chatId = session?.sourceChatId else { return }
            Task { await loadAnchors(chatId) }
        }
        .onChange(of: debugExpanded) { _, expanded in
            if expanded && storage == nil {
                Task { await loadStorage() }
            }
        }
    }

    // MARK: - Data Loading

    private func loadMetadata(_ chatId: String) async {
        loading = true
        let loaded = await bridge.getSessionMetadata(sessionId: chatId)
        guard !Task.isCancelled else { return }
        metadata = loaded
        loading = false
    }

    /// `waitForChat`: a chat just switched to may not be in the page's memory
    /// yet and answers empty, so try again for a few seconds before settling.
    private func loadAnchors(_ chatId: String, waitForChat: Bool = false) async {
        for attempt in 0..<(waitForChat ? 5 : 1) {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard !Task.isCancelled else { return }
            guard let loaded = await bridge.getHumanChatAnchors(sessionId: chatId) else { continue }
            if anchorList?.chatId != chatId || anchorList?.anchors != loaded {
                anchorList = (chatId, loaded)
            }
            if !loaded.isEmpty { return }
        }
    }

    /// The anchors for the chat on screen. A reply that lands for a chat
    /// already left is stored under that chat's id and never shown here.
    private var anchors: [AgentBridge.HumanChatAnchor] {
        guard let list = anchorList, list.chatId == session?.sourceChatId else { return [] }
        return list.anchors
    }

    private func loadStorage() async {
        guard let sessionId = session?.sourceChatId else { return }
        storage = await bridge.getSessionStorageBreakdown(sessionId: sessionId)
    }

    private func patch(_ patch: [String: Any]) {
        guard let sessionId = session?.sourceChatId else { return }
        Task {
            if let updated = await bridge.patchSessionMetadata(sessionId: sessionId, patch: patch) {
                metadata = updated
            }
        }
    }

    // MARK: - Description

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DESCRIPTION")
                    .font(.ripul(.caption, weight: .semibold))
                    .foregroundStyle(.ripul(.textSecondary))
                Spacer()
                if !editingDescription {
                    Button {
                        descriptionDraft = metadata?.description ?? ""
                        editingDescription = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.ripulIcon(.caption))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    .buttonStyle(.plain)
                    .uiKitIdentifier("SessionMetadataPanel.description.edit")
                }
            }

            if editingDescription {
                TextField("What is this session about?", text: $descriptionDraft, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                    .font(.ripul(.subheadline))
                    .uiKitIdentifier("SessionMetadataPanel.description.input")

                HStack {
                    Spacer()
                    Button {
                        editingDescription = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.ripulIcon(.caption))
                            .foregroundStyle(.ripul(.textSecondary))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    Button {
                        patch(["description": descriptionDraft])
                        editingDescription = false
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.ripulIcon(.caption))
                            .foregroundStyle(.ripul(.info))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .uiKitIdentifier("SessionMetadataPanel.description.save")
                }
            } else {
                Text(metadata?.description?.isEmpty == false ? metadata!.description! : "Tap to add a description...")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(metadata?.description?.isEmpty == false ? .ripul(.text) : .ripul(.textTertiary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        descriptionDraft = metadata?.description ?? ""
                        editingDescription = true
                    }
                    .uiKitIdentifier("SessionMetadataPanel.description.text")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .modifier(GlassPanelBackground())
    }

    // MARK: - Messages

    /// Every message a person typed, as anchors into the chat: tap one to
    /// jump there; hover (pointer) or long-press shows the whole message.
    @ViewBuilder
    private var messagesSection: some View {
        if !anchors.isEmpty {
            let numbered = Array(anchors.enumerated()).map { NumberedAnchor(number: $0.offset + 1, anchor: $0.element) }
            let query = messagesSearch.trimmingCharacters(in: .whitespaces)
            let shown = query.isEmpty ? numbered : numbered.filter { $0.anchor.text.localizedCaseInsensitiveContains(query) }
            GlassListSection(
                title: "Messages",
                subtitle: "\(anchors.count)",
                isExpanded: $messagesExpanded,
                data: shown,
                id: \.anchor.correlationId,
                searchPlaceholder: anchors.count > 8 ? "Search messages" : nil,
                searchText: anchors.count > 8 ? $messagesSearch : nil,
                maxVisibleItems: 6
            ) { item in
                messageRow(item)
            }
            .uiKitIdentifier("SessionMetadataPanel.messages")
        }
    }

    private struct NumberedAnchor {
        let number: Int
        let anchor: AgentBridge.HumanChatAnchor
    }

    @ViewBuilder
    private func messageRow(_ item: NumberedAnchor) -> some View {
        let anchor = item.anchor
        Button {
            bridge.scrollToChatMessage(correlationId: anchor.correlationId)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(item.number)")
                    .font(.ripul(.caption2).monospacedDigit().weight(.semibold))
                    .foregroundStyle(.ripul(.textTertiary))
                    .frame(width: 28, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(anchor.text)
                        .font(.ripul(.subheadline))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let sender = anchor.senderDisplayName, !sender.isEmpty {
                        Text(sender)
                            .font(.ripul(.caption2))
                            .foregroundStyle(.ripul(.textTertiary))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let ts = anchor.timestamp {
                    Text(RelativeTimeText.string(for: ts, relativeTo: Date()))
                        .font(.ripul(.caption2))
                        .foregroundStyle(.ripul(.textSecondary))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(anchor.text)
        .contextMenu { MenuIcons {
            Button {
                bridge.scrollToChatMessage(correlationId: anchor.correlationId)
            } label: {
                Label("Jump to Message", systemImage: "arrow.turn.down.right")
            }
            Button {
                #if os(iOS)
                UIPasteboard.general.string = anchor.text
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(anchor.text, forType: .string)
                #endif
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }} preview: {
            ScrollView {
                Text(anchor.text)
                    .font(.ripul(.body))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(idealWidth: 320, maxHeight: 400)
        }
        .uiKitIdentifier("SessionMetadataPanel.messageRow")
    }

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        if let model = metadata?.model, !model.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("MODEL")
                    .font(.ripul(.caption, weight: .semibold))
                    .foregroundStyle(.ripul(.textSecondary))
                Text(model)
                    .font(.ripul(.subheadline, weight: .semibold))
                    .uiKitIdentifier("SessionMetadataPanel.model.name")
                if let history = metadata?.modelHistory, history.count > 1 {
                    let others = history.filter { $0 != model }
                    if !others.isEmpty {
                        Text("Also used: \(others.joined(separator: ", "))")
                            .font(.ripul(.caption2))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassPanelBackground())
            .uiKitIdentifier("SessionMetadataPanel.model")
        }
    }

    // MARK: - Files Edited

    @ViewBuilder
    private var filesSection: some View {
        if let files = metadata?.filesEdited, !files.isEmpty {
            GlassListSection(
                title: "Files Edited",
                subtitle: "\(files.count)",
                isExpanded: $filesExpanded,
                data: files.sorted { ($0.lastSeenAt ?? "") > ($1.lastSeenAt ?? "") },
                id: \.fileName,
                maxVisibleItems: 8
            ) { file in
                HStack(spacing: 8) {
                    Image(systemName: FileTypeIcon.icon(for: file.filePath ?? file.fileName))
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(FileTypeIcon.color(for: file.filePath ?? file.fileName))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.fileName)
                            .font(.ripul(.subheadline))
                            .lineLimit(1)
                        if let path = file.filePath {
                            Text(shortenPath(path))
                                .font(.ripul(.caption2))
                                .foregroundStyle(.ripul(.textTertiary))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if file.editCount > 1 {
                        Text("\(file.editCount)x")
                            .font(.ripul(.caption2).monospacedDigit().weight(.semibold))
                            .foregroundStyle(.ripul(.textSecondary))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.ripul(.textQuaternary), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let ts = file.lastSeenAt {
                        Text(relativeTime(ts))
                            .font(.ripul(.caption2))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                }
                .uiKitIdentifier("SessionMetadataPanel.fileRow")
            }
        }
    }

    // MARK: - Deployments

    @ViewBuilder
    private var deploymentsSection: some View {
        if let deploys = metadata?.deployments, !deploys.isEmpty {
            GlassListSection(
                title: "Deployments",
                subtitle: "\(deploys.count)",
                isExpanded: $deploysExpanded,
                data: deploys,
                id: \.id,
                maxVisibleItems: 5
            ) { deploy in
                HStack(spacing: 8) {
                    Image(systemName: deploy.target == "pages" ? "globe" : "desktopcomputer")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.info))
                        .frame(width: 28)
                    Text(deploy.target.uppercased())
                        .font(.ripul(.caption, weight: .semibold))
                        .foregroundStyle(.ripul(.textSecondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ripul(.textQuaternary), in: RoundedRectangle(cornerRadius: 6))
                    Spacer()
                    if let ts = deploy.timestamp {
                        Text(relativeTime(ts))
                            .font(.ripul(.caption2))
                            .foregroundStyle(.ripul(.textTertiary))
                    }
                }
                .uiKitIdentifier("SessionMetadataPanel.deployRow")
            }
        }
    }

    // MARK: - Participants

    /// Collapse legacy nonce-bearing human participant ids
    /// (`controller-USERID-NONCE`) onto the stable `human-USERID` key so dupes
    /// from earlier sessions don't render separately. Keep the most recently
    /// seen entry per stable id. Mirrors the web React MetadataPanel dedupe.
    /// Also drops host bridge endpoints (`host-<machineId>`) — they're infra,
    /// not humans, and shouldn't appear in the participants list.
    private var dedupedParticipants: [AgentBridge.ParticipantEntry] {
        guard let participants = metadata?.participants else { return [] }
        var byStableId: [String: AgentBridge.ParticipantEntry] = [:]
        for p in participants {
            if p.id.hasPrefix("host-") { continue }
            let stableId = p.kind == "human" ? Self.stableParticipantId(fromClientId: p.id) : p.id
            let existing = byStableId[stableId]
            let pTime = p.lastSeenAt ?? ""
            let existingTime = existing?.lastSeenAt ?? ""
            if existing == nil || pTime > existingTime {
                byStableId[stableId] = AgentBridge.ParticipantEntry(
                    id: stableId,
                    kind: p.kind,
                    displayName: p.displayName,
                    group: p.group,
                    firstSeenAt: p.firstSeenAt,
                    lastSeenAt: p.lastSeenAt
                )
            }
        }
        return Array(byStableId.values).sorted { ($0.lastSeenAt ?? "") > ($1.lastSeenAt ?? "") }
    }

    private static func stableParticipantId(fromClientId clientId: String) -> String {
        if clientId.hasPrefix("controller-") {
            let parts = clientId.split(separator: "-")
            if parts.count >= 3 {
                let userId = parts.dropFirst().dropLast().joined(separator: "-")
                if !userId.isEmpty {
                    return "human-\(userId)"
                }
            }
        }
        return clientId
    }

    @ViewBuilder
    private var participantsSection: some View {
        let participants = dedupedParticipants
        if !participants.isEmpty {
            GlassListSection(
                title: "Participants",
                subtitle: "\(participants.count)",
                isExpanded: $participantsExpanded,
                data: participants,
                id: \.id
            ) { participant in
                HStack(spacing: 8) {
                    Image(systemName: participant.kind == "agent" ? "cpu" : "person")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(participant.displayName ?? participant.id)
                            .font(.ripul(.subheadline))
                            .lineLimit(1)
                        if let group = participant.group, !group.isEmpty {
                            Text(group)
                                .font(.ripul(.caption2))
                                .foregroundStyle(.ripul(.textTertiary))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(participant.kind.uppercased())
                        .font(.ripul(.caption2, weight: .semibold))
                        .foregroundStyle(.ripul(.textSecondary))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.ripul(.textQuaternary), in: RoundedRectangle(cornerRadius: 6))
                    if let ts = participant.lastSeenAt {
                        Text(relativeTime(ts))
                            .font(.ripul(.caption2))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                }
                .uiKitIdentifier("SessionMetadataPanel.participantRow")
            }
        }
    }

    // MARK: - Notes

    @ViewBuilder
    private var notesSection: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chevron.right")
                    .font(.ripulIcon(.caption2, weight: .semibold))
                    .foregroundStyle(.ripul(.textSecondary))
                    .rotationEffect(.degrees(notesExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: notesExpanded)
                Text("Notes")
                    .font(.ripul(.subheadline, weight: .semibold))
                    .foregroundStyle(.ripul(.textSecondary))
                    .textCase(.uppercase)
                if let notes = metadata?.notes, !notes.isEmpty, !notesExpanded {
                    Text("\(notes.count)")
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textTertiary))
                }
                Spacer()
                if !addingNote {
                    Button {
                        addingNote = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.ripulIcon(.caption))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    .buttonStyle(.plain)
                    .uiKitIdentifier("SessionMetadataPanel.notes.add")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { notesExpanded.toggle() }
            }

            if notesExpanded {
                VStack(spacing: 8) {
                    // Add note form
                    if addingNote {
                        VStack(spacing: 8) {
                            TextField("Add a note...", text: $noteDraft, axis: .vertical)
                                .lineLimit(2...4)
                                .textFieldStyle(.roundedBorder)
                                .font(.ripul(.subheadline))
                                .uiKitIdentifier("SessionMetadataPanel.notes.input")
                            HStack {
                                Spacer()
                                Button {
                                    addingNote = false
                                    noteDraft = ""
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.ripulIcon(.caption))
                                        .foregroundStyle(.ripul(.textSecondary))
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    guard !noteDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                                    let noteId = "note_" + String(Date().timeIntervalSince1970, radix: 16) + "_" + UUID().uuidString.prefix(6)
                                    patch(["appendNote": ["id": noteId, "text": noteDraft.trimmingCharacters(in: .whitespaces)]])
                                    noteDraft = ""
                                    addingNote = false
                                } label: {
                                    Image(systemName: "checkmark")
                                        .font(.ripulIcon(.caption))
                                        .foregroundStyle(.ripul(.info))
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .uiKitIdentifier("SessionMetadataPanel.notes.save")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }

                    // Existing notes
                    if let notes = metadata?.notes.sorted(by: { ($0.createdAt ?? $0.timestamp ?? "") > ($1.createdAt ?? $1.timestamp ?? "") }), !notes.isEmpty {
                        ForEach(notes) { note in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(note.text)
                                        .font(.ripul(.subheadline))
                                    if let ts = note.createdAt ?? note.timestamp {
                                        Text(relativeTime(ts))
                                            .font(.ripul(.caption2))
                                            .foregroundStyle(.ripul(.textSecondary))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    patch(["removeNoteId": note.id])
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.ripulIcon(.caption2))
                                        .foregroundStyle(.ripul(.textSecondary))
                                }
                                .buttonStyle(.plain)
                                .uiKitIdentifier("SessionMetadataPanel.notes.delete")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ripul(.textQuaternary).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 12)
                        }
                    } else if !addingNote {
                        Text("No notes yet. Tap + to add one.")
                            .font(.ripul(.caption))
                            .foregroundStyle(.ripul(.textTertiary))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .modifier(GlassPanelBackground())
        .uiKitIdentifier("SessionMetadataPanel.notes")
    }

    // MARK: - CLI Tools

    /// The chat's tool browser — categories with per-chat switches, the member
    /// tools underneath, and a drill-in per tool. `RipulToolBrowser` owns
    /// loading and the switch write-back; this section is only the collapsible
    /// frame around it, so the browser can move elsewhere without touching it.
    @ViewBuilder
    private var cliToolsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.ripulIcon(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                Text("CLI Tools")
                    .font(.ripul(.subheadline, weight: .semibold))
                    .foregroundStyle(.ripul(.textSecondary))
                    .textCase(.uppercase)
                Spacer()
                Image(systemName: cliToolsExpanded ? "chevron.up" : "chevron.down")
                    .font(.ripulIcon(.caption2))
                    .foregroundStyle(.ripul(.textTertiary))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { cliToolsExpanded.toggle() }
            }

            if cliToolsExpanded {
                if let chatId = session?.sourceChatId {
                    RipulToolBrowser(bridge: bridge, chatId: chatId)
                        .padding(.bottom, 8)
                } else {
                    Text("No session selected.")
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textTertiary))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
        }
        .modifier(GlassPanelBackground())
        .uiKitIdentifier("SessionMetadataPanel.cliTools")
    }

    // MARK: - Debug

    @ViewBuilder
    private var debugSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "ant")
                    .font(.ripulIcon(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                Text("Debug")
                    .font(.ripul(.subheadline, weight: .semibold))
                    .foregroundStyle(.ripul(.textSecondary))
                    .textCase(.uppercase)
                Spacer()
                Image(systemName: debugExpanded ? "chevron.up" : "chevron.down")
                    .font(.ripulIcon(.caption2))
                    .foregroundStyle(.ripul(.textTertiary))
                if debugExpanded {
                    Button {
                        #if os(iOS)
                        UIPasteboard.general.string = debugText
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(debugText, forType: .string)
                        #endif
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.ripulIcon(.caption))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    .buttonStyle(.plain)
                    .uiKitIdentifier("SessionMetadataPanel.debug.copy")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { debugExpanded.toggle() }
            }

            if debugExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let s = session {
                        debugRow("Tab ID", s.id)
                        debugRow("Source Chat ID", s.sourceChatId)
                        if let hc = s.hostChatId { debugRow("Host Chat ID", hc) }
                        if let rm = s.remoteMachineName { debugRow("Machine", rm) }
                        if let p = s.provider { debugRow("Provider", p) }
                        if let pl = s.providerLabel { debugRow("Provider Label", pl) }
                        if let sz = s.sizeBytes { debugRow("Size", ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .memory)) }
                    }
                    if let m = metadata {
                        if let model = m.model { debugRow("Model", model) }
                        if let created = m.createdAt { debugRow("Created", created) }
                        if let updated = m.updatedAt { debugRow("Updated", updated) }
                    }
                    if let storage {
                        Text("STORAGE")
                            .font(.ripul(.caption2, weight: .semibold, family: .code))
                            .foregroundStyle(.ripul(.textTertiary))
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                        debugRow("Total", "\(Self.formatBytes(storage.totalBytes)) / \(storage.count)")
                        ForEach(storage.buckets, id: \.name) { b in
                            debugRow(
                                Swift.String(b.name.prefix(14)),
                                "\(Self.formatBytes(b.bytes)) / \(b.count)"
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .modifier(GlassPanelBackground())
        .uiKitIdentifier("SessionMetadataPanel.debug")
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.ripul(.caption2, weight: .semibold, family: .code))
                .foregroundStyle(.ripul(.textTertiary))
                .frame(width: 95, alignment: .leading)
            Text(value)
                .font(.ripul(.caption2, family: .code))
                .foregroundStyle(.ripul(.textSecondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var debugText: String {
        var lines: [String] = []
        if let s = session {
            lines.append("Tab ID: \(s.id)")
            lines.append("Source Chat ID: \(s.sourceChatId)")
            if let hc = s.hostChatId { lines.append("Host Chat ID: \(hc)") }
            if let rm = s.remoteMachineName { lines.append("Machine: \(rm)") }
            if let p = s.provider { lines.append("Provider: \(p)") }
        }
        if let m = metadata {
            if let model = m.model { lines.append("Model: \(model)") }
            if let created = m.createdAt { lines.append("Created: \(created)") }
            if let updated = m.updatedAt { lines.append("Updated: \(updated)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Text("Session milestones will appear here as you work \u{2014} files edited, deployments, and more.")
            .font(.ripul(.subheadline))
            .foregroundStyle(.ripul(.textTertiary))
            .multilineTextAlignment(.center)
            .padding(.vertical, 32)
            .uiKitIdentifier("SessionMetadataPanel.empty")
    }

    // MARK: - Helpers

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return Swift.String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return Swift.String(format: "%.2f MB", Double(bytes) / (1024.0 * 1024.0))
    }

    private func shortenPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 3 { return path }
        return "\u{2026}/" + components.suffix(3).joined(separator: "/")
    }

    private func relativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: iso)
        }()
        guard let date else { return iso }
        return RelativeTimeText.string(for: date, relativeTo: Date())
    }

    private func String(_ value: Double, radix: Int) -> String {
        Swift.String(Int(value), radix: radix)
    }
}
