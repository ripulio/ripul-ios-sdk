import SwiftUI
import MarkdownUI

/// MVP native chat scroller.
///
/// Renders `NativeChatMessageStore.messages` — the messages the web app forwards
/// over the bridge — with plain SwiftUI (no markdown/syntax highlighting yet, by
/// design: this is the lightweight control for the "is the web view's render the
/// thermal cost?" experiment). Observes the leaf store only, so message/streaming
/// writes never touch the WKWebView host.
///
/// Scroller ONLY — no input. AgentView draws this over the WKWebView and reuses its
/// existing native ChatComposer for input, so we don't fork the composer.
@available(iOS 16.0, macOS 14.0, *)
public struct NativeChatView: View {
    @ObservedObject private var store: NativeChatMessageStore

    public init(store: NativeChatMessageStore) {
        self.store = store
    }

    public var body: some View {
        scroller
    }

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.messages) { message in
                            NativeChatMessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    // Bottom anchor for auto-scroll.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: store.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            // Streaming deltas mutate the last message in place (count unchanged),
            // so also re-pin when the last message's thinking length grows.
            .onChange(of: store.messages.last?.thinking) { _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private static let bottomAnchor = "native-chat-bottom-anchor"

    private var emptyState: some View {
        Text("No messages yet.\nEnable forwarding: window.__ripulSetNativeChatForwarding(true)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }
}

/// A single message row. Bare bubbles: user trailing/tinted, assistant leading.
@available(iOS 16.0, macOS 14.0, *)
private struct NativeChatMessageRow: View {
    let message: NativeChatMessage

    private var isUser: Bool { message.role == .user }

    @ViewBuilder
    var body: some View {
        if let ask = message.askUser {
            askUserCard(ask)
        } else if let tn = message.taskNotification {
            taskNotificationCard(tn)
        } else {
            bubbleRow
        }
    }

    private var bubbleRow: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            // Sender attribution lozenge — mirrors the web's top-left panel badge.
            if let label = message.senderLabel {
                HStack(spacing: 3) {
                    if isUser {
                        Spacer(minLength: 40)
                        Image(systemName: "person.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0).frame(width: 12)
                    } else {
                        Spacer(minLength: 0).frame(width: 12)
                        Image(systemName: "sparkle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 40)
                    }
                }
            }
            HStack {
                if isUser { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 4) {
                    if let thinking = message.thinking, !thinking.isEmpty {
                        Text(thinking)
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    if !message.content.isEmpty {
                        markdownBody(message.content)
                    } else if message.thinking?.isEmpty ?? true {
                        // No real content and no thinking yet — show a labeled placeholder
                        // (tool name / humanized method) so the transcript's shape is legible.
                        // Assistant prose is filled in by MessagePipeline (PR 3).
                        HStack(spacing: 6) {
                            Image(systemName: symbolName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(message.label ?? message.method ?? message.role.rawValue)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                            if let status = message.status, status == "error" {
                                Text("· error")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if !isUser { Spacer(minLength: 40) }
            }
        }
    }

    private var bubbleColor: Color {
        isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)
    }

    /// Full GFM markdown (headings, lists, tables, code blocks, blockquotes) via
    /// MarkdownUI — mirroring the web's markdown chat bubble. Syntax highlighting
    /// is intentionally deferred, so code blocks render monospaced but unstyled.
    /// Matches the theme used by the live UserInteractionSheet for consistency.
    @ViewBuilder
    private func markdownBody(_ string: String) -> some View {
        Markdown(string)
            .markdownTextStyle { FontSize(.em(1.0)) }
            .markdownTextStyle(\.link) {
                ForegroundColor(.blue)
                UnderlineStyle(.single)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Mirrors the web AskUserChoiceRenderer: an `action.hover` card with a 3px
    /// severity-coloured LEFT accent border, the message, then option rows (leading
    /// radio/checkbox icon, label + description, trailing outlined value chip).
    /// Read-only — live answering still flows through the native question sheet.
    private func askUserCard(_ ask: NativeAskUser) -> some View {
        // Left accent bar + card body.
        HStack(spacing: 0) {
            Rectangle()
                .fill(severityColor(ask.severity))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 12) {
                if !ask.question.isEmpty {
                    markdownBody(ask.question)
                }
                ForEach(Array(ask.options.enumerated()), id: \.offset) { _, opt in
                    optionRow(opt, multiSelect: ask.multiSelect)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.06))          // ~ action.hover
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func optionRow(_ opt: NativeAskUser.Option, multiSelect: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: multiSelect ? "square" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(opt.label)
                    .font(.subheadline)
                if let desc = opt.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !opt.value.isEmpty {
                Text(opt.value)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    )
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))          // ~ background.paper over the hover card
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        )
    }

    /// Compact task-notification status row — mirrors the web TaskNotificationCard.
    @ViewBuilder
    private func taskNotificationCard(_ tn: NativeTaskNotification) -> some View {
        let isOk = tn.status == "completed"
        let isFailed = tn.status == "failed" || tn.status == "error"
        let iconName = isOk ? "checkmark.circle.fill" : isFailed ? "xmark.circle.fill" : "clock.fill"
        let iconColor: Color = isOk ? .green : isFailed ? .red : .secondary
        let displayText = tn.summary ?? tn.taskId ?? "Task completed"
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .padding(.top, 1)
            Text(displayText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.secondary.opacity(0.18), lineWidth: 0.5))
        .padding(.horizontal, 12)
    }

    /// Web severity → colour: error→red, warning→orange, else primary (accent).
    private func severityColor(_ severity: String?) -> Color {
        switch severity {
        case "error": return .red
        case "warning": return .orange
        default: return .accentColor
        }
    }

    /// SF Symbol for a content-less placeholder row, keyed off the raw method.
    private var symbolName: String {
        switch message.method {
        case "llmRequest": return "sparkle"
        case "TodoWrite": return "checklist"
        case "askUser": return "questionmark.bubble"
        case "completion": return "checkmark.circle"
        case "Read": return "doc.text"
        case "Edit", "Write": return "pencil"
        case "Bash": return "terminal"
        default: return message.method != nil ? "wrench.and.screwdriver" : "text.bubble"
        }
    }
}
