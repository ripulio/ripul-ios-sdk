import SwiftUI

/// The chat's observations, under its milestones and shortcuts: what agents in
/// this chat noticed and someone should act on later (tangents), and what they
/// left unfinished (loose ends). The footer opens the repository's whole open
/// list, which every chat and Mac in the repository shares.
///
/// Agents record them (the `observation` tool). A person can add one, start,
/// finish, drop, reopen and delete them here. The page's `ObservationsSection`
/// is the web twin. Plan: docs/plans/observations.md.
@available(iOS 15.0, macOS 13.0, *)
struct SessionObservationsSection: View {
    let bridge: AgentBridge
    let chatId: String
    /// Changes when a turn starts or ends, when the agent may have recorded one.
    let turnRunning: Bool
    @Binding var isExpanded: Bool

    @State private var data: AgentBridge.ChatObservations?
    @State private var openId: String?
    @State private var showRepo = false
    @State private var adding = false
    @State private var draft = ""
    @State private var severity = "medium"
    @State private var category = "enhancement"

    private static let maxTitle = 80

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                content
            }
        }
        .modifier(GlassPanelBackground())
        .uiKitIdentifier("SessionMetadataPanel.observations")
        .task(id: chatId) {
            data = nil
            openId = nil
            await reload()
        }
        .onChange(of: turnRunning) {
            Task { await reload() }
        }
    }

    private func reload() async {
        let id = chatId
        guard let loaded = await bridge.getChatObservations(chatId: id) else { return }
        guard !Task.isCancelled, id == chatId else { return }
        data = loaded
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
        adding = false
        Task {
            await bridge.createObservation(chatId: chatId, repoKey: data?.repoKey, title: String(title.prefix(Self.maxTitle)),
                                           severity: severity, category: category)
            draft = ""
            await reload()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.ripulIcon(.caption2, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
            Text("Observations")
                .font(.ripul(.subheadline, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .textCase(.uppercase)
            if let count = data?.chat.count, count > 0 {
                Text("\(count)")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textTertiary))
            }
            Spacer()
            if !adding, data?.repoKey != nil {
                Button {
                    draft = ""
                    adding = true
                    isExpanded = true
                } label: {
                    Image(systemName: "plus")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 32, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add an observation")
                .uiKitIdentifier("SessionMetadataPanel.observations.add")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if adding {
                addFields
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if let data, data.chat.isEmpty, !adding {
                Text(data.repoKey == nil
                     ? (data.reason ?? "This chat is not in a git repository.")
                     : "None from this chat. Agents record what they notice but are not fixing, and what they leave unfinished.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textTertiary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            rows(data?.chat ?? [])

            if let data, let repoName = data.repoName {
                Divider().padding(.horizontal, 16)
                repoFooter(repoName, data)
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func rows(_ list: [AgentBridge.RepoObservation]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, observation in
            if index > 0 {
                Divider().padding(.leading, 35)
            }
            ObservationRow(
                observation: observation,
                thisChatId: chatId,
                isOpen: Binding(get: { openId == observation.id }, set: { openId = $0 ? observation.id : nil }),
                onPatch: { patch(observation.id, $0) },
                onDelete: { delete(observation.id) },
                showRepository: observation.repoKey != data?.repoKey
            )
            .padding(.horizontal, 16)
        }
    }

    private func repoFooter(_ repoName: String, _ data: AgentBridge.ChatObservations) -> some View {
        let mine = Set(data.chat.map(\.id))
        let others = data.open.filter { !mine.contains($0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showRepo.toggle() }
            } label: {
                HStack {
                    Text("\(data.open.count) open in \(repoName)")
                        .font(.ripul(.subheadline))
                        .foregroundStyle(.ripul(.textSecondary))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.ripulIcon(.caption2, weight: .semibold))
                        .foregroundStyle(.ripul(.textTertiary))
                        .rotationEffect(.degrees(showRepo ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .uiKitIdentifier("SessionMetadataPanel.observations.repo")

            if showRepo {
                if others.isEmpty {
                    Text("No others open.")
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textTertiary))
                        .padding(.horizontal, 16)
                } else {
                    rows(others)
                }
            }
        }
    }

    private var addFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What should someone act on later?", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.ripul(.subheadline))
                .submitLabel(.done)
                .onSubmit(save)
                .onChange(of: draft) { _, value in
                    if value.count > Self.maxTitle { draft = String(value.prefix(Self.maxTitle)) }
                }
                .uiKitIdentifier("SessionMetadataPanel.observations.title")
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
    }
}
