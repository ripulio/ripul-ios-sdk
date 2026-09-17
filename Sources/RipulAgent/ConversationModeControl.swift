import SwiftUI

/// Shared conversation audience control for iPhone and Mac.
@available(iOS 16.0, macOS 14.0, *)
public struct RipulConversationModeControl: View {
    let mode: String
    let pending: Bool
    let onChange: (String) -> Void
    let onMention: () -> Void
    private var isGroupMode: Bool { mode == "group" }

    public init(mode: String, pending: Bool = false, onChange: @escaping (String) -> Void, onMention: @escaping () -> Void) {
        self.mode = mode; self.pending = pending; self.onChange = onChange; self.onMention = onMention
    }

    public var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button { onChange("agent") } label: {
                    Label("Agent — replies by default", systemImage: isGroupMode ? "circle" : "checkmark.circle.fill")
                }
                Button { onChange("group") } label: {
                    Label("Group — agents reply when @mentioned", systemImage: isGroupMode ? "checkmark.circle.fill" : "circle")
                }
                Text("Mentioned agents can read the preceding group discussion. This mode applies to everyone.")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isGroupMode ? "person.2" : "sparkles")
                    Text(isGroupMode ? "Group" : "Agent")
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).frame(minHeight: 36)
                .background(.regularMaterial, in: Capsule())
            }
            .disabled(pending)
            .accessibilityLabel("Conversation mode: " + (isGroupMode ? "Group" : "Agent"))
            .accessibilityIdentifier("conversation.mode")
            if isGroupMode {
                Button(action: onMention) {
                    Label("Agent", systemImage: "at").font(.subheadline)
                        .padding(.horizontal, 10).frame(minHeight: 36)
                }
                .accessibilityLabel("Mention the current agent")
                .accessibilityIdentifier("conversation.mentionAgent")
            }
            Spacer(minLength: 0)
            if pending { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.plain)
    }

}
