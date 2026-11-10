import SwiftUI

/// Alert-style rename prompt for a chat session — ported verbatim from the
/// native app (`Shared/SessionsListSections.swift`) for the M8 whole-screen
/// extraction. Drive it by binding `renamingSession`; setting a session shows
/// the alert, clearing dismisses.
@available(iOS 15.0, macOS 13.0, *)
public struct RenameSessionAlert: ViewModifier {
    @Binding var renamingSession: ChatSession?
    @Binding var renameText: String
    @Binding var iconPickerSession: ChatSession?
    var bridge: AgentBridge
    var unifiedRow: ((ChatSession) -> UnifiedSession?)?

    public init(
        renamingSession: Binding<ChatSession?>,
        renameText: Binding<String>,
        iconPickerSession: Binding<ChatSession?> = .constant(nil),
        bridge: AgentBridge,
        unifiedRow: ((ChatSession) -> UnifiedSession?)? = nil
    ) {
        self._renamingSession = renamingSession
        self._renameText = renameText
        self._iconPickerSession = iconPickerSession
        self.bridge = bridge
        self.unifiedRow = unifiedRow
    }

    public func body(content: Content) -> some View {
        content
            .alert("Rename Session", isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            ), presenting: renamingSession) { session in
                TextField("Session name", text: $renameText)
                    .uiKitIdentifier("RenameSessionAlert.textField")
                Button("Cancel", role: .cancel) { renamingSession = nil }
                Button("Rename") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    // SwiftUI may dismiss the alert (clearing the binding)
                    // before running this action. Use the presented session,
                    // not the mutable selection that dismissal just cleared.
                    if !trimmed.isEmpty {
                        bridge.renameSession(
                            id: session.id,
                            sourceChatId: session.sourceChatId,
                            displayName: trimmed
                        )
                    }
                    renamingSession = nil
                }
            } message: { _ in
                Text("Enter a new name for this session.")
            }
            .ripulSheet(item: $iconPickerSession) { session in
                let row = unifiedRow?(session)
                let keys = ([session.id, session.sourceChatId, session.hostChatId] + (row?.readStateKeys ?? [])).compactMap { $0 }
                SessionIconPicker(
                    sessionTitle: row?.title ?? session.displayName,
                    currentIcon: bridge.sessionList.customIcon(anyOf: keys)
                ) { newIcon in
                    bridge.setSessionIcon(newIcon, chatSession: session, unified: row)
                }
            }
    }
}

@available(iOS 15.0, macOS 13.0, *)
public extension View {
    func renameSessionAlert(
        renamingSession: Binding<ChatSession?>,
        renameText: Binding<String>,
        iconPickerSession: Binding<ChatSession?> = .constant(nil),
        bridge: AgentBridge,
        unifiedRow: ((ChatSession) -> UnifiedSession?)? = nil
    ) -> some View {
        modifier(RenameSessionAlert(
            renamingSession: renamingSession,
            renameText: renameText,
            iconPickerSession: iconPickerSession,
            bridge: bridge,
            unifiedRow: unifiedRow
        ))
    }
}
