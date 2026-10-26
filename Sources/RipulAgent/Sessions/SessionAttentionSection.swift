import SwiftUI

/// "For your attention": messages someone replied to and @'d the viewer on,
/// first in the metadata panel while there are any. A tap jumps the chat to
/// the message; the tick clears it. Nothing else clears it, reading the chat
/// included. The page's `AttentionListSection` is the web twin.
/// Docs: chatAttentionList.md.
@available(iOS 15.0, macOS 13.0, *)
struct SessionAttentionSection: View {
    let items: [AgentBridge.ReadingItem]
    @Binding var isExpanded: Bool
    let onJump: (AgentBridge.MessageAnchor) -> Void
    /// The ids to clear, or nil for all of them.
    let onClear: ([String]?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                content
            }
        }
        .modifier(GlassPanelBackground())
        .uiKitIdentifier("SessionMetadataPanel.attention")
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.ripulIcon(.caption2, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
            Text("For your attention")
                .font(.ripul(.subheadline, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .textCase(.uppercase)
            Text("\(items.count)")
                .font(.ripul(.caption))
                .foregroundStyle(.ripul(.textTertiary))
            Spacer()
            if items.count > 1 {
                Button("Clear All") { onClear(nil) }
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .buttonStyle(.plain)
                    .uiKitIdentifier("SessionMetadataPanel.attention.clearAll")
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

    private var content: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                row(item)
            }
        }
        .padding(.bottom, 8)
    }

    private func row(_ item: AgentBridge.ReadingItem) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Button {
                onJump(item.anchor)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "flag")
                        .font(.ripulIcon(.subheadline))
                        .foregroundStyle(.ripul(.warning))
                        .frame(width: 20)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.messageSender.map { "\($0): \(item.excerpt)" } ?? item.excerpt).ripulText()
                            .font(.ripul(.subheadline, weight: .semibold))
                            .lineLimit(2)
                        if let note = item.note {
                            Text(note).ripulText()
                                .font(.ripul(.footnote))
                                .lineLimit(3)
                        }
                        HStack(spacing: 4) {
                            Text(item.flaggedBy)
                                .lineLimit(1)
                            Text("·")
                            RelativeTimeText(date: item.createdAt)
                        }
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Jumps to the message")
            .uiKitIdentifier("SessionMetadataPanel.attentionRow")

            Button {
                onClear([item.id])
            } label: {
                Image(systemName: "checkmark")
                    .font(.ripulIcon(.caption, weight: .semibold))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done: clear from my list")
            .uiKitIdentifier("SessionMetadataPanel.attentionRow.clear")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .contextMenu { MenuIcons {
            Button { onJump(item.anchor) } label: {
                Label("Jump to Message", systemImage: "arrow.down.to.line")
            }
            Button { onClear([item.id]) } label: {
                Label("Done", systemImage: "checkmark")
            }
        }}
    }
}
