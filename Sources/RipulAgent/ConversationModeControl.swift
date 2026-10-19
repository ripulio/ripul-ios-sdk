import SwiftUI

/// Shared conversation audience control for iPhone and Mac.
@available(iOS 16.0, macOS 14.0, *)
public struct RipulConversationModeControl: View {
    let mode: String
    let pending: Bool
    let typingLabel: String
    let onChange: (String) -> Void
    let onMention: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isGroupMode: Bool { mode == "group" }

    public init(mode: String, pending: Bool = false, typingLabel: String = "", onChange: @escaping (String) -> Void, onMention: @escaping () -> Void) {
        self.mode = mode; self.pending = pending; self.onChange = onChange; self.onMention = onMention
        self.typingLabel = typingLabel
    }

    public var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                modeMenu
                    .fixedSize()
                if !typingLabel.isEmpty {
                    Text(typingLabel)
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.trailing, 12)
                        .accessibilityIdentifier("conversation.typing")
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 36)
            .background(.regularMaterial, in: Capsule())
            if isGroupMode {
                Button(action: onMention) {
                    Label("Agent", systemImage: "at").font(.ripul(.subheadline))
                        .padding(.horizontal, 10).frame(minHeight: 36)
                }
                .fixedSize()
                .accessibilityLabel("Mention the current agent")
                .accessibilityIdentifier("conversation.mentionAgent")
            }
            Spacer(minLength: 0)
            if pending { ProgressView().controlSize(.small).frame(height: 36) }
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: typingLabel.isEmpty)
    }

    private var modeMenu: some View {
        Menu { MenuIcons {
            Button { onChange("agent") } label: {
                Label("Agent — replies by default", systemImage: isGroupMode ? "circle" : "checkmark.circle.fill")
            }
            Button { onChange("group") } label: {
                Label("Group — agents reply when @mentioned", systemImage: isGroupMode ? "checkmark.circle.fill" : "circle")
            }
            Text("Mentioned agents can read the preceding group discussion. This mode applies to everyone.")
        }} label: {
            HStack(spacing: 5) {
                Image(systemName: isGroupMode ? "person.2" : "sparkles")
                Text(isGroupMode ? "Group" : "Agent")
                Image(systemName: "chevron.down").font(.ripulIcon(.caption2))
            }
            .font(.ripul(.subheadline, weight: .medium))
            .padding(.horizontal, 12).frame(minHeight: 36)
        }
        .disabled(pending)
        .accessibilityLabel("Conversation mode: " + (isGroupMode ? "Group" : "Agent"))
        .accessibilityIdentifier("conversation.mode")
    }

}
