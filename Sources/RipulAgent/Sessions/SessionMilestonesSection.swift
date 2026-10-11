import SwiftUI

/// The chat's milestones, at the top of the metadata panel: what the chat has
/// achieved, newest first. Tapping one jumps the chat to where it was reached,
/// and opening it shows the commits and deployments that went into it.
///
/// The agent records them (the `milestone` tool). A person can add, rename,
/// delete and change the kind here, and such a change marks the milestone as
/// theirs. The page brackets the commits and deployments under each one, so
/// this view only draws what it is given.
@available(iOS 15.0, macOS 13.0, *)
struct SessionMilestonesSection: View {
    let bridge: AgentBridge
    let story: AgentBridge.ChatStory?
    /// The newest message a person typed, for placing a milestone added by hand.
    let latestAnchor: AgentBridge.HumanChatAnchor?
    @Binding var isExpanded: Bool
    let patch: ([String: Any]) -> Void

    @State private var openId: String?
    @State private var adding = false
    @State private var renamingId: String?
    @State private var draft = ""

    private static let maxTitle = 80

    private var milestones: [AgentBridge.StoryMilestone] { story?.milestones ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if let goal = story?.goal {
                goalRow(goal)
                Divider().padding(.horizontal, 16)
            }
            header
            if isExpanded {
                content
            }
        }
        .modifier(GlassPanelBackground())
        .uiKitIdentifier("SessionMetadataPanel.milestones")
    }

    // MARK: - Goal

    private func goalRow(_ goal: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Working toward")
                .font(.ripul(.caption))
                .foregroundStyle(.ripul(.textSecondary))
            Text(goal).ripulText()
                .font(.ripul(.subheadline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .uiKitIdentifier("SessionMetadataPanel.milestones.goal")
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.ripulIcon(.caption2, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
            Text("Milestones")
                .font(.ripul(.subheadline, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .textCase(.uppercase)
            if !milestones.isEmpty {
                Text("\(milestones.count)")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textTertiary))
            }
            Spacer()
            if !adding {
                Button {
                    draft = ""
                    renamingId = nil
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
                .accessibilityLabel("Add a milestone")
                .uiKitIdentifier("SessionMetadataPanel.milestones.add")
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
        VStack(spacing: 0) {
            if adding {
                draftField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if let summary = story?.openSummary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Since the last milestone").ripulText()
                        .font(.ripul(.subheadline, weight: .semibold))
                    Text(summary)
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.ripul(.separator))
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .uiKitIdentifier("SessionMetadataPanel.milestones.open")
            }

            if milestones.isEmpty && !adding {
                Text("None yet. The agent records one when the work reaches it, and you can add your own.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textTertiary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            ForEach(Array(milestones.enumerated()), id: \.element.id) { index, milestone in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                milestoneRow(milestone)
            }
        }
        .padding(.bottom, 8)
    }

    private var draftField: some View {
        HStack(spacing: 4) {
            TextField("What was achieved, in one line", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.ripul(.subheadline))
                .submitLabel(.done)
                .onSubmit(saveDraft)
                .onChange(of: draft) { _, value in
                    if value.count > Self.maxTitle { draft = String(value.prefix(Self.maxTitle)) }
                }
                .uiKitIdentifier("SessionMetadataPanel.milestones.input")
            Button {
                adding = false
                renamingId = nil
                draft = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.ripulIcon(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
            Button(action: saveDraft) {
                Image(systemName: "checkmark")
                    .font(.ripulIcon(.caption))
                    .foregroundStyle(.ripul(.info))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save")
            .uiKitIdentifier("SessionMetadataPanel.milestones.save")
        }
    }

    // MARK: - A milestone

    @ViewBuilder
    private func milestoneRow(_ milestone: AgentBridge.StoryMilestone) -> some View {
        let isOpen = openId == milestone.id
        VStack(alignment: .leading, spacing: 0) {
            if renamingId == milestone.id {
                draftField
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    Button {
                        jump(to: milestone.anchor, fallbackTime: milestone.at)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: milestone.isDecided ? "diamond.fill" : "checkmark.circle.fill")
                                    .font(.ripulIcon(.caption))
                                    .foregroundStyle(milestone.isDecided ? .ripul(.textSecondary) : .ripul(.success))
                                    .frame(width: 18)
                                    .accessibilityLabel(milestone.isDecided ? "Decided" : "Delivered")
                                Text(milestone.title).ripulText()
                                    .font(.ripul(.subheadline, weight: .semibold))
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let reached = Self.date(milestone.at) {
                                    Text(RelativeTimeText.string(for: reached, relativeTo: Date()))
                                        .font(.ripul(.caption2))
                                        .foregroundStyle(.ripul(.textSecondary))
                                }
                            }
                            if !milestone.summary.isEmpty {
                                Text(milestone.summary)
                                    .font(.ripul(.caption))
                                    .foregroundStyle(.ripul(.textSecondary))
                                    .padding(.leading, 26)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .uiKitIdentifier("SessionMetadataPanel.milestoneRow")

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { openId = isOpen ? nil : milestone.id }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.ripulIcon(.caption2, weight: .semibold))
                            .foregroundStyle(.ripul(.textTertiary))
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                            .frame(width: 32, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isOpen ? "Hide what went into it" : "Show what went into it")
                    .uiKitIdentifier("SessionMetadataPanel.milestoneRow.expand")
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }

            if isOpen && renamingId != milestone.id {
                contents(of: milestone)
                    .padding(.leading, 42)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
            }
        }
        .contextMenu { MenuIcons {
            Button {
                jump(to: milestone.anchor, fallbackTime: milestone.at)
            } label: {
                Label("Jump to Where It Was Reached", systemImage: "arrow.turn.down.right")
            }
            if let start = milestone.startAnchor {
                Button {
                    bridge.scrollToChatAnchor(start)
                } label: {
                    Label("Jump to Where the Work Began", systemImage: "arrow.up.to.line")
                }
            }
            Button {
                adding = false
                draft = milestone.title
                renamingId = milestone.id
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                patch(["updateMilestone": [
                    "id": milestone.id,
                    "kind": milestone.isDecided ? "delivered" : "decided",
                    "byPerson": true,
                ]])
            } label: {
                Label(milestone.isDecided ? "Mark as Delivered" : "Mark as Decided",
                      systemImage: milestone.isDecided ? "checkmark.circle" : "diamond")
            }
            Divider()
            Button(role: .destructive) {
                if openId == milestone.id { openId = nil }
                patch(["removeMilestoneId": milestone.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }}
    }

    @ViewBuilder
    private func contents(of milestone: AgentBridge.StoryMilestone) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let detail = milestone.detail, !detail.isEmpty {
                Text(detail).ripulText()
                    .font(.ripul(.footnote))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(milestone.commits) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(commit.sha.prefix(7)))
                        .font(.ripul(.caption2).monospacedDigit())
                        .foregroundStyle(.ripul(.textSecondary))
                    Text(commit.subject.isEmpty ? "Commit" : commit.subject).ripulText()
                        .font(.ripul(.caption))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .uiKitIdentifier("SessionMetadataPanel.milestoneRow.commit")
            }
            ForEach(milestone.deployments) { deploy in
                Text(Self.deployLabel(deploy.target))
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            if milestone.commits.isEmpty && milestone.deployments.isEmpty && (milestone.detail ?? "").isEmpty {
                Text("No commits or deploys recorded for it.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textTertiary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func jump(to anchor: AgentBridge.MilestoneAnchor?, fallbackTime: String) {
        if let anchor {
            bridge.scrollToChatAnchor(anchor)
        } else if let reached = Self.date(fallbackTime) {
            bridge.scrollToChatAnchor(correlationId: nil, ts: reached.timeIntervalSince1970 * 1000)
        }
    }

    private func saveDraft() {
        let title = draft
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let cut = String(title.prefix(Self.maxTitle))
        defer {
            adding = false
            renamingId = nil
            draft = ""
        }
        guard !cut.isEmpty else { return }
        if let renamingId {
            patch(["updateMilestone": ["id": renamingId, "title": cut, "byPerson": true]])
            return
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        var anchor: [String: Any] = ["ts": latestAnchor?.timestamp.map { $0.timeIntervalSince1970 * 1000 } ?? nowMs]
        if let id = latestAnchor?.correlationId { anchor["correlationId"] = id }
        let id = "ms_" + String(Int(nowMs), radix: 36) + "_" + UUID().uuidString.prefix(4).lowercased()
        patch(["appendMilestone": [
            "id": id,
            "title": cut,
            "kind": "delivered",
            "author": "person",
            "anchor": anchor,
        ]])
    }

    // MARK: - Helpers

    private static func deployLabel(_ target: String) -> String {
        switch target {
        case "pages": return "Web deploy"
        case "worker": return "Worker deploy"
        case "ios": return "iPhone build"
        case "macos": return "Mac build"
        default: return "Deploy"
        }
    }

    private static func date(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
