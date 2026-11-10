import SwiftUI

/// The Observations tab: what agents in this chat noticed and someone should
/// act on later (tangents) and what they left unfinished (loose ends), then the
/// rest of the repository's open list, which every chat and Mac in the
/// repository shares. Search and add above a list that fills the tab, as the
/// Messages tab has.
///
/// Agents record them (the `observation` tool). A person can add one, start,
/// finish, drop, reopen and delete them here. The page's `ObservationsSection`
/// is the web twin. Plan: docs/plans/observations.md.
@available(iOS 17.0, macOS 14.0, *)
struct SessionObservationsSection: View {
    let bridge: AgentBridge
    let chatId: String
    /// Changes when a turn starts or ends, when the agent may have recorded one.
    let turnRunning: Bool

    @State private var data: AgentBridge.ChatObservations?
    @State private var failed = false
    @State private var openId: String?
    @State private var search = ""
    @State private var adding = false
    @State private var draft = ""
    @State private var detailDraft = ""
    @State private var severity = "medium"
    @State private var category = "enhancement"
    @FocusState private var focus: Field?

    private enum Field { case title, detail }

    private static let maxTitle = 80
    private static let maxDetail = 4000

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GlassSearchField("Search observations", text: $search)
                    .uiKitIdentifier("SessionMetadataPanel.observations.search")
                if data?.repoKey != nil {
                    addButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if adding {
                addFields
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if let data {
                list(data)
            } else if failed {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Couldn’t load observations.")
                    Button("Reload") { Task { await reload() } }
                        .uiKitIdentifier("SessionMetadataPanel.observations.reload")
                }
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.textSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            } else {
                ProgressView("Loading observations…")
                    .font(.ripul(.subheadline))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .uiKitIdentifier("SessionMetadataPanel.observations.loading")
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .uiKitIdentifier("SessionMetadataPanel.observations")
        .task(id: chatId) {
            data = nil
            failed = false
            openId = nil
            await reload()
        }
        .onChange(of: turnRunning) {
            Task { await reload() }
        }
    }

    private func reload() async {
        let id = chatId
        let loaded = await bridge.getChatObservations(chatId: id)
        guard !Task.isCancelled, id == chatId else { return }
        if let loaded {
            data = loaded
            failed = false
        } else if data == nil {
            failed = true
        }
    }

    private func patch(_ id: String, _ body: [String: Any]) {
        Task {
            await bridge.patchObservation(chatId: chatId, id: id, patch: body)
            await reload()
        }
    }

    private func delete(_ id: String) {
        Task {
            await bridge.deleteObservation(id: id)
            openId = nil
            await reload()
        }
    }

    private func save() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { adding = false; return }
        let detail = detailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        adding = false
        Task {
            await bridge.createObservation(chatId: chatId, repoKey: data?.repoKey, title: String(title.prefix(Self.maxTitle)),
                                           detail: detail.isEmpty ? nil : String(detail.prefix(Self.maxDetail)),
                                           severity: severity, category: category)
            draft = ""
            detailDraft = ""
            await reload()
        }
    }

    // MARK: - The list

    private func matches(_ o: AgentBridge.RepoObservation, _ query: String) -> Bool {
        query.isEmpty
            || [o.title, o.detail, o.category, o.kindLabel, o.raisedByTitle ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
            || o.files.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// This chat's first (raised, claimed or seen again, any status), then the
    /// repository's other open ones, most severe first.
    private func list(_ data: AgentBridge.ChatObservations) -> some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let mineIds = Set(data.chat.map(\.id))
        let mine = data.chat.filter { matches($0, query) }
        let others = data.open.filter { !mineIds.contains($0.id) && matches($0, query) }
        return List {
            groupHeader("This chat", count: mine.count)
            if mine.isEmpty {
                note(!query.isEmpty ? "None from this chat match."
                     : data.repoKey == nil ? (data.reason ?? "This chat is not in a git repository.")
                     : "None from this chat. Agents record what they notice but are not fixing, and what they leave unfinished.")
            } else {
                rows(mine, repoKey: data.repoKey)
            }
            if let repoName = data.repoName {
                groupHeader("Open in \(repoName)", count: others.count)
                if others.isEmpty {
                    note(query.isEmpty ? "No others open." : "No others match.")
                } else {
                    rows(others, repoKey: data.repoKey)
                }
            } else if !mine.isEmpty, let reason = data.reason {
                note(reason)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await reload() }
    }

    @ViewBuilder
    private func rows(_ list: [AgentBridge.RepoObservation], repoKey: String?) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, observation in
            ObservationRow(
                observation: observation,
                thisChatId: chatId,
                isOpen: Binding(get: { openId == observation.id }, set: { openId = $0 ? observation.id : nil }),
                onPatch: { patch(observation.id, $0) },
                onDelete: { delete(observation.id) },
                showRepository: observation.repoKey != repoKey
            )
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            // Under the title, past the severity dot, as the rows' dividers were.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 19 }
            .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
            .listRowSeparator(index == list.count - 1 ? .hidden : .visible, edges: .bottom)
        }
    }

    /// A group's title in the panel's section style; a plain row, so it
    /// scrolls with the list rather than pinning over it.
    private func groupHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.ripul(.subheadline, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .textCase(.uppercase)
                .lineLimit(1)
            Text("\(count)")
                .font(.ripul(.caption))
                .foregroundStyle(.ripul(.textTertiary))
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(.isHeader)
        .uiKitIdentifier("SessionMetadataPanel.observations.group")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.ripul(.caption))
            .foregroundStyle(.ripul(.textTertiary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    // MARK: - Adding one

    private var addButton: some View {
        Button {
            draft = ""
            detailDraft = ""
            adding = true
        } label: {
            Image(systemName: "plus")
                .font(.ripulIcon(.caption, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(adding)
        .accessibilityLabel("Add an observation")
        .help("Add an observation")
        .uiKitIdentifier("SessionMetadataPanel.observations.add")
    }

    private var addFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What should someone act on later?", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.ripul(.subheadline))
                .focused($focus, equals: .title)
                .submitLabel(.next)
                .onSubmit { focus = .detail }
                .onChange(of: draft) { _, value in
                    if value.count > Self.maxTitle { draft = String(value.prefix(Self.maxTitle)) }
                }
                .uiKitIdentifier("SessionMetadataPanel.observations.title")
            TextField("Details (optional, Markdown)", text: $detailDraft, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .font(.ripul(.subheadline))
                .focused($focus, equals: .detail)
                .onChange(of: detailDraft) { _, value in
                    if value.count > Self.maxDetail { detailDraft = String(value.prefix(Self.maxDetail)) }
                }
                .uiKitIdentifier("SessionMetadataPanel.observations.detail")
            HStack(spacing: 8) {
                Menu {
                    Picker("Severity", selection: $severity) {
                        ForEach(AgentBridge.observationSeverities, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(ObservationRow.severityColor(severity)).frame(width: 8, height: 8)
                        Text(severity.capitalized).font(.ripul(.subheadline))
                    }
                }
                .uiKitIdentifier("SessionMetadataPanel.observations.severity")
                Menu {
                    Picker("Category", selection: $category) {
                        ForEach(AgentBridge.observationCategories, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Text(category).font(.ripul(.subheadline))
                }
                .uiKitIdentifier("SessionMetadataPanel.observations.category")
                Spacer()
                Button {
                    adding = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                Button(action: save) {
                    Image(systemName: "checkmark")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.info))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Save")
                .uiKitIdentifier("SessionMetadataPanel.observations.save")
            }
        }
        .padding(12)
        .modifier(GlassPanelBackground())
        .onAppear { focus = .title }
    }
}
