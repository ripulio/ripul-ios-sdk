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
