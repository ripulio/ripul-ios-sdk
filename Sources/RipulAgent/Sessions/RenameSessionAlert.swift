import SwiftUI

/// Alert-style rename prompt for a chat session — ported verbatim from the
/// native app (`Shared/SessionsListSections.swift`) for the M8 whole-screen
/// extraction. Drive it by binding `renamingSession`; setting a session shows
/// the alert, clearing dismisses.
@available(iOS 15.0, macOS 13.0, *)
public struct RenameSessionAlert: ViewModifier {
    @Binding var renamingSession: ChatSession?
    @Binding var renameText: String
    @ObservedObject var bridge: AgentBridge

    public init(renamingSession: Binding<ChatSession?>, renameText: Binding<String>, bridge: AgentBridge) {
        self._renamingSession = renamingSession
        self._renameText = renameText
        self.bridge = bridge
    }

    public func body(content: Content) -> some View {
        content
            .alert("Rename Session", isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )) {
                TextField("Session name", text: $renameText)
                    .uiKitIdentifier("RenameSessionAlert.textField")
                Button("Cancel", role: .cancel) { renamingSession = nil }
                Button("Rename") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    if let session = renamingSession, !trimmed.isEmpty {
                        bridge.renameSession(
                            id: session.id,
                            sourceChatId: session.sourceChatId,
                            displayName: trimmed
                        )
                    }
                    renamingSession = nil
                }
            } message: {
                Text("Enter a new name for this session.")
            }
    }
}

@available(iOS 15.0, macOS 13.0, *)
public extension View {
    func renameSessionAlert(
        renamingSession: Binding<ChatSession?>,
        renameText: Binding<String>,
        bridge: AgentBridge
    ) -> some View {
        modifier(RenameSessionAlert(renamingSession: renamingSession, renameText: renameText, bridge: bridge))
    }
}
