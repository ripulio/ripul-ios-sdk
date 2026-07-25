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

    // Section expansion
    @State private var filesExpanded = true
    @State private var deploysExpanded = true
    @State private var participantsExpanded = true
    @State private var notesExpanded = true
    @State private var cliToolsExpanded = false
    @State private var debugExpanded = false

    // CLI Tools
    @State private var cliTools: [AgentBridge.CliToolEntry]? = nil
    @State private var cliToolsLoading = false
    @State private var cliToolsError: String? = nil
    @State private var cliToolsSearch = ""

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
        .task { await loadMetadata() }
        .onChange(of: session?.sourceChatId) { _ in
            metadata = nil
            storage = nil
            Task { await loadMetadata() }
        }
        .onChange(of: debugExpanded) { expanded in
            if expanded && storage == nil {
                Task { await loadStorage() }
            }
        }
    }

    // MARK: - Data Loading

    private func loadMetadata() async {
        guard let sessionId = session?.sourceChatId else { return }
        loading = true
        metadata = await bridge.getSessionMetadata(sessionId: sessionId)
        loading = false
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !editingDescription {
                    Button {
                        descriptionDraft = metadata?.description ?? ""
                        editingDescription = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .uiKitIdentifier("SessionMetadataPanel.description.edit")
                }
            }

            if editingDescription {
                TextField("What is this session about?", text: $descriptionDraft, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .uiKitIdentifier("SessionMetadataPanel.description.input")

                HStack {
                    Spacer()
                    Button {
                        editingDescription = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    Button {
                        patch(["description": descriptionDraft])
                        editingDescription = false
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .uiKitIdentifier("SessionMetadataPanel.description.save")
                }
            } else {
                Text(metadata?.description?.isEmpty == false ? metadata!.description! : "Tap to add a description...")
                    .font(.subheadline)
                    .foregroundStyle(metadata?.description?.isEmpty == false ? .primary : .tertiary)
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

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        if let model = metadata?.model, !model.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("MODEL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model)
                    .font(.subheadline.weight(.semibold))
                    .uiKitIdentifier("SessionMetadataPanel.model.name")
                if let history = metadata?.modelHistory, history.count > 1 {
                    let others = history.filter { $0 != model }
                    if !others.isEmpty {
                        Text("Also used: \(others.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(FileTypeIcon.color(for: file.filePath ?? file.fileName))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.fileName)
                            .font(.subheadline)
                            .lineLimit(1)
                        if let path = file.filePath {
                            Text(shortenPath(path))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if file.editCount > 1 {
                        Text("\(file.editCount)x")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let ts = file.lastSeenAt {
                        Text(relativeTime(ts))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .frame(width: 28)
                    Text(deploy.target.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Spacer()
                    if let ts = deploy.timestamp {
                        Text(relativeTime(ts))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(participant.displayName ?? participant.id)
                            .font(.subheadline)
                            .lineLimit(1)
                        if let group = participant.group, !group.isEmpty {
                            Text(group)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(participant.kind.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    if let ts = participant.lastSeenAt {
                        Text(relativeTime(ts))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(notesExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: notesExpanded)
                Text("Notes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let notes = metadata?.notes, !notes.isEmpty, !notesExpanded {
                    Text("\(notes.count)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !addingNote {
                    Button {
                        addingNote = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                                .font(.subheadline)
                                .uiKitIdentifier("SessionMetadataPanel.notes.input")
                            HStack {
                                Spacer()
                                Button {
                                    addingNote = false
                                    noteDraft = ""
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
                                        .font(.caption)
                                        .foregroundStyle(.blue)
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
                                        .font(.subheadline)
                                    if let ts = note.createdAt ?? note.timestamp {
                                        Text(relativeTime(ts))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    patch(["removeNoteId": note.id])
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .uiKitIdentifier("SessionMetadataPanel.notes.delete")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 12)
                        }
                    } else if !addingNote {
                        Text("No notes yet. Tap + to add one.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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

    private var filteredCliTools: [AgentBridge.CliToolEntry] {
        guard let tools = cliTools else { return [] }
        let q = cliToolsSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tools }
        return tools.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    @ViewBuilder
    private var cliToolsSection: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("CLI Tools")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if cliToolsExpanded && cliTools != nil {
                    // inline search
                    TextField("Search…", text: $cliToolsSearch)
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                }

                Spacer()

                // count badge
                if let tools = cliTools {
                    let filtered = filteredCliTools
                    let label = cliToolsSearch.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "\(tools.count)"
                        : "\(filtered.count)/\(tools.count)"
                    Text(label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                // refresh button
                Button {
                    Task { await loadCliTools() }
                } label: {
                    if cliToolsLoading {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(cliToolsLoading)
                .uiKitIdentifier("SessionMetadataPanel.cliTools.refresh")

                Image(systemName: cliToolsExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { cliToolsExpanded.toggle() }
                if cliToolsExpanded && cliTools == nil && !cliToolsLoading {
                    Task { await loadCliTools() }
                }
            }

            if cliToolsExpanded {
                if let error = cliToolsError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                } else if cliTools == nil && !cliToolsLoading {
                    Text("Tap ↺ to probe the CLI tool list.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                } else {
                    let tools = filteredCliTools
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(tools, id: \.name) { tool in
                                HStack(spacing: 8) {
                                    Text(tool.name)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(toolGroupLabel(tool.name))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                if tool.name != tools.last?.name {
                                    Divider().padding(.leading, 16)
                                }
                            }
                            if tools.isEmpty {
                                Text("No tools match.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .padding(.bottom, 8)
                }
            }
        }
        .modifier(GlassPanelBackground())
        .uiKitIdentifier("SessionMetadataPanel.cliTools")
    }

    private func loadCliTools() async {
        guard let sessionId = session?.sourceChatId else { return }
        cliToolsLoading = true
        cliToolsError = nil
        let result = await bridge.getResolvedCliTools(sessionId: sessionId)
        if let result {
            cliTools = result.sorted { $0.name < $1.name }
        } else {
            cliToolsError = "Failed to load — page may not be ready."
        }
        cliToolsLoading = false
    }

    private func toolGroupLabel(_ name: String) -> String {
        if name.hasPrefix("host_") { return "macOS" }
        if name.hasPrefix("device_") { return "iPhone" }
        return "web"
    }

    // MARK: - Debug

    @ViewBuilder
    private var debugSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "ant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Debug")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Image(systemName: debugExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                            .font(.caption2.weight(.semibold).monospaced())
                            .foregroundStyle(.tertiary)
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
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 95, alignment: .leading)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
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
            .font(.subheadline)
            .foregroundStyle(.tertiary)
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
