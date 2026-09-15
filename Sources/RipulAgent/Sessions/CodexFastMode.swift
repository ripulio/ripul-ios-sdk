import SwiftUI
import WebKit

public struct CodexFastModeState: Decodable, Equatable {
    public var chatId: String
    public var visible: Bool
    public var enabled: Bool
    public var supported: Bool
    public var detail: String
    public var error: String?
}

/// The web preference is shared with the send path. Keep view updates local to
/// this control rather than publishing unrelated changes through AgentBridge.
@MainActor
public final class CodexFastModeSettings: ObservableObject {
    @Published public private(set) var state: CodexFastModeState?
    @Published public private(set) var saving = false
    @Published public private(set) var error: String?
    private var generation = UUID()

    public init() {}
    public var menuKey: String {
        [state?.chatId ?? "", state?.visible == true ? "visible" : "hidden",
         state?.enabled == true ? "fast" : "standard", state?.detail ?? "",
         saving ? "saving" : "", error ?? ""].joined(separator: "|")
    }

    public func refresh(bridge: AgentBridge, chatId: String?, modelId: String?) async {
        let ticket = UUID(); generation = ticket
        state = nil; error = nil; saving = false
        guard let chatId else { return }
        do {
            let next = try await bridge.codexFastMode(chatId: chatId, modelId: modelId)
            guard generation == ticket, !Task.isCancelled else { return }
            state = next
        } catch {
            guard generation == ticket, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    public func setEnabled(_ enabled: Bool, bridge: AgentBridge, modelId: String?) async {
        guard let state, !saving else { return }
        let ticket = generation
        saving = true; error = nil
        do {
            let next = try await bridge.codexFastMode(chatId: state.chatId, modelId: modelId, enabled: enabled)
            if generation == ticket { self.state = next }
        } catch {
            if generation == ticket { self.error = error.localizedDescription }
        }
        if generation == ticket { saving = false }
    }
}

extension AgentBridge {
    @MainActor
    public func codexFastMode(chatId: String, modelId: String?, enabled: Bool? = nil) async throws -> CodexFastModeState {
        let arguments: [String: Any] = ["chatId": chatId, "modelId": modelId as Any? ?? NSNull(), "enabled": enabled as Any? ?? NSNull()]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let result = try await callAsyncJavaScript("""
            const {chatId, modelId, enabled} = \(json);
            return enabled === null ? await window.__ripulGetCodexFastMode?.(chatId, modelId) : await window.__ripulSetCodexFastMode?.(chatId, enabled, modelId);
            """)
        guard let dict = result as? [String: Any], dict["chatId"] != nil else {
            let message = (result as? [String: Any])?["error"] as? String ?? "Update the chat interface to use Fast mode."
            throw NSError(domain: "CodexFastMode", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(CodexFastModeState.self, from: JSONSerialization.data(withJSONObject: dict))
    }
}

/// Shared native menu content on iPhone, Catalyst and Mac.
public struct CodexFastModeMenu: View {
    @ObservedObject var settings: CodexFastModeSettings
    let onChange: (Bool) -> Void
    public init(settings: CodexFastModeSettings, onChange: @escaping (Bool) -> Void) {
        self.settings = settings; self.onChange = onChange
    }
    public var body: some View {
        if let state = settings.state, state.visible {
            Toggle(isOn: Binding(get: { state.enabled }, set: onChange)) {
                Label("Fast mode · increased usage", systemImage: "bolt.fill")
            }
            .disabled(settings.saving || (!state.supported && !state.enabled))
            .help(state.detail)
            .accessibilityIdentifier("Codex.fastMode")
            if !state.supported || settings.error != nil {
                Text(settings.error ?? state.detail).font(.caption)
            }
        }
    }
}
