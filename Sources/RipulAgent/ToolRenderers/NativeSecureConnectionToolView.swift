import SwiftUI

/// A human action in the tool result. No editable value or callback goes back
/// to the tool: tapping opens the fixed, private native form.
struct NativeSecureConnectionToolView: View {
    let content: NativeToolContent
    @Environment(\.openURL) private var openURL
    @NativeRowState("secureConnection.saved") private var saved = false

    private var payload: [String: CmsJSON]? {
        var value = content.output
        for _ in 0..<6 {
            if let object = value?.objectValue {
                if object["captureUrl"] != nil { return object }
                value = object["result"] ?? object["structuredContent"]
            } else if let text = value?.stringValue { value = ToolValue.parse(text) }
            else { break }
        }
        return nil
    }

    var body: some View {
        if let payload, let raw = payload.string("captureUrl"), let url = URL(string: raw),
           SecureConnectionRequest.recognizes(url) {
            let connection = payload["connection"]?.objectValue
            let connectionId = connection?.string("id") ?? content.call.id
            let isSaved = _saved.value(subscope: connectionId) || NativeChatRowStateRegistry.savedSecureConnectionIds.contains(connectionId)
            let permissions = payload.string("requestKind") == "permissions"
            VStack(alignment: .leading, spacing: 14) {
                Label(connection?.string("name") ?? "Secure connection", systemImage: isSaved ? "checkmark.shield.fill" : "lock.shield")
                    .font(.ripul(.headline))
                Text(isSaved ? (permissions ? "Your API access has been updated." : "Your key has been saved privately.") : (permissions ? "Review API access for your saved credential. No need to enter the key again." : "Save your API key privately. You can configure API access later."))
                    .font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
                if !isSaved {
                    Button(permissions ? "Review API access" : "Save credential securely") {
                        if !RipulSecureConnection.open(url) { openURL(url) }
                    }
                    .buttonStyle(.borderedProminent)
                    .uiKitIdentifier("NativeTool.secureConnection.connect")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: RipulSecureConnection.didSave)) { note in
                if let savedId = connection?.string("id"), note.object as? String == savedId {
                    NativeChatRowStateRegistry.savedSecureConnectionIds.insert(savedId)
                    _saved.setValue(true, subscope: connectionId)
                }
            }
        } else {
            Text(content.running ? "Preparing a private connection…" : "A secure connection link is not available. Request a new one in the chat.")
                .foregroundStyle(.ripul(.textSecondary))
        }
    }
}
