import SwiftUI

/// Agent traffic is stored as user input in the receiving chat, but its author
/// is another chat. Keep that identity separate from a person's avatar.
public struct NativeChatAgentSender: Equatable {
    public let agentId: String
    public let model: String?
    public let runtime: String?
    let iconKeys: [String]

    init?(wire: [String: Any]) {
        guard let id = wire["agentId"] as? String, !id.isEmpty else { return nil }
        agentId = id
        model = wire["model"] as? String
        runtime = wire["runtime"] as? String
        // Cross-Mac comms qualify an id with machine-…/. The list's icons are
        // keyed by the chat itself, including its deterministic CLI UUID.
        let localId = id.split(separator: "/").last.map(String.init) ?? id
        iconKeys = [id, localId, UnifiedSession.cliUuid(for: localId)]
    }
}

@available(iOS 16.0, macOS 14.0, *)
struct NativeChatAgentAvatar: View {
    let sender: NativeChatAgentSender
    let sessionList: SessionListStore?

    var body: some View {
        let identity = ModelIdentity.resolve(modelId: sender.model ?? sender.runtime)
        Group {
            if let icon = sessionList?.customIcon(anyOf: sender.iconKeys) {
                Image(systemName: icon)
                    .font(.ripulIcon(size: 20))
            } else if let identity {
                Text(identity.glyph)
                    .font(.ripul(size: 20))
            } else {
                Image(systemName: "cpu")
                    .font(.ripulIcon(size: 20))
            }
        }
        .foregroundStyle(identity?.color ?? Color.ripul(.accent))
        .frame(width: 30, height: 30)
        .accessibilityIdentifier("NativeChat.agentAvatar.\(sender.agentId)")
    }
}
