import SwiftUI

/// Resolved by the shared web policy. Native renders actions without provider
/// names or a second copy of provider/turn eligibility rules.
public struct RipulComposerAction: Codable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let description: String
    public let sfSymbol: String
}

struct RipulComposerState: Codable, Equatable {
    let actions: [RipulComposerAction]
    let runningSendLabel: String
}

@MainActor
public final class RipulComposerActionStore: ObservableObject {
    @Published private var byChat: [String: RipulComposerState] = [:]
    public func actions(for chatId: String?) -> [RipulComposerAction] {
        guard let chatId else { return [] }
        return byChat[chatId]?.actions ?? []
    }
    public func runningSendLabel(for chatId: String?) -> String {
        guard let chatId else { return "Send" }
        return byChat[chatId]?.runningSendLabel ?? "Send"
    }
    func update(chatId: String, state: RipulComposerState) {
        guard byChat[chatId] != state else { return }
        byChat[chatId] = state
    }
    func clear() { byChat = [:] }
}

/// Shared by all native composer layouts and platforms.
struct ComposerActionButtons: View {
    let actions: [RipulComposerAction]
    let pending: Bool
    let onAction: ((String) -> Void)?
    var body: some View {
        ForEach(actions) { action in
            Button { onAction?(action.id) } label: {
                Image(systemName: action.sfSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .modifier(GlassCircleModifier(glassStyle: "clear"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(pending || onAction == nil)
            .accessibilityLabel(action.label)
            .accessibilityHint(action.description)
            .help(action.description)
        }
    }
}

/// The message a person is replying to. The web transcript sets it (swipe or
/// Reply), mirrors it here, and attaches it on send; native only shows and
/// cancels it, so the two composers can never disagree about what is quoted.
public struct RipulReplyTarget: Codable, Equatable {
    public let correlationId: String
    public let senderDisplayName: String?
    public let excerpt: String
    public let role: String

    public init(correlationId: String, senderDisplayName: String?, excerpt: String, role: String) {
        self.correlationId = correlationId
        self.senderDisplayName = senderDisplayName
        self.excerpt = excerpt
        self.role = role
    }

    public var label: String {
        senderDisplayName ?? (role == "assistant" ? "Agent" : "Message")
    }
}

/// Quote strip above the native text field while a reply is pending.
struct ReplyTargetStrip: View {
    let target: RipulReplyTarget
    let onCancel: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Text(target.excerpt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                onCancel?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
            .accessibilityIdentifier("ReplyTargetStrip.cancel")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityIdentifier("ReplyTargetStrip")
    }
}
