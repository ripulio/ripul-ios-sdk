import Foundation

@main struct Checks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = MessageHistory(maxEntries: 200, directory: directory)
        history.record("private job message", chatID: "ecv_123", chatTitle: "Private job")
        precondition(history.entries.isEmpty, "Employment messages never enter the device-wide prompt history")
        precondition(MessageHistory(maxEntries: 200, directory: directory).entries.isEmpty, "Employment prompts are not persisted for another account")
        let files = [["id": "file", "name": "notes.txt", "mediaType": "text/plain", "data": Data("keep me".utf8).base64EncodedString()]]
        history.record("", chatID: "a", chatTitle: "Chat A", attachments: files, modality: "voice")
        let attached = history.entries[0]
        history.toggleFavorite(attached)
        for i in 0..<205 { history.record("Prompt \(i)", chatID: "b", chatTitle: "Chat B") }
        precondition(history.entries.count == 201, "200 recent prompts plus favorites")
        precondition(history.entries.first?.id == attached.id)
        let loaded = MessageHistory(maxEntries: 200, directory: directory)
        precondition(loaded.entries.count == 201)
        precondition(loaded.attachments(for: attached) == files, "Attachment-only voice prompt survives restart and eviction")
        precondition(loaded.entries.first?.modality == "voice")
        loaded.record("same", chatID: "a", chatTitle: "Chat A")
        loaded.record("same", chatID: "b", chatTitle: "Chat B")
        precondition(loaded.entries.suffix(2).map(\.chatID) == ["a", "b"], "Same text in different chats retained")
        precondition(loaded.navigateUp(currentText: "draft") == "same")
        precondition(loaded.navigateDown() == "draft")
        loaded.record("with file", attachments: files)
        precondition(loaded.navigateUp(currentText: "draft") == "with file")
        precondition(loaded.recalledAttachments == files)
        loaded.remove(attached)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(attached.id + ".json").path))
        print("PASS: retention, restart, favorites, chat identity, voice, attachment-only sends, recall and deletion")
    }
}
