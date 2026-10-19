import Foundation
import Combine

/// Durable recent prompts. Attachment bytes live on disk and are loaded only on recall.
@available(iOS 16.0, macOS 14.0, *)
public class MessageHistory: ObservableObject {
    public static let shared = MessageHistory()

    public struct Entry: Identifiable, Codable, Equatable {
        public let id: String
        public let text: String
        public let chatID: String?
        public let chatTitle: String
        public let sentAt: Date
        public let modality: String
        public let attachmentNames: [String]
        public var favorite: Bool = false
    }

    @Published public private(set) var entries: [Entry] = [] // oldest first
    /// Dictation marks the next composer send; voice mode supplies its own modality.
    public var composerModality = "keyboard"
    private let directory: URL
    private let maxEntries: Int
    private var cursor = 0
    private var draft = ""
    public var recalledAttachments: [[String: String]]? {
        guard cursor < entries.count else { return nil }
        return attachments(for: entries[cursor])
    }

    public init(maxEntries: Int = 500, directory: URL? = nil) {
        self.maxEntries = max(200, maxEntries)
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ripul/PromptHistory", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let index = self.directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: index))
            } else if directory == nil {
                // Keep the person's existing text-only prompts when creating the richer index.
                let favorites = Set(UserDefaults.standard.stringArray(forKey: "ripul.messageHistory.favorites") ?? [])
                entries = (UserDefaults.standard.stringArray(forKey: "ripul.messageHistory") ?? []).map {
                    Entry(id: UUID().uuidString, text: $0, chatID: nil, chatTitle: "Earlier prompts",
                          sentAt: Date(), modality: "unknown", attachmentNames: [], favorite: favorites.contains($0))
                }
                try persist(entries)
            }
        } catch { NSLog("[PromptHistory] Could not load history: %@", error.localizedDescription) }
        resetCursor()
    }

    public func record(_ text: String, chatID: String? = nil, chatTitle: String = "Chat",
                       attachments: [[String: String]] = [], modality: String = "keyboard") {
        // Employment history belongs to the authenticated conversation API,
        // never the device-wide prompt picker (which spans accounts and jobs).
        guard chatID?.hasPrefix("ecv_") != true else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let entry = Entry(id: UUID().uuidString, text: text, chatID: chatID, chatTitle: chatTitle,
                          sentAt: Date(), modality: modality,
                          attachmentNames: attachments.map { $0["name"] ?? ($0["mediaType"]?.hasPrefix("image/") == true ? "Image" : "File") })
        do {
            if !attachments.isEmpty {
                try JSONEncoder().encode(attachments).write(to: attachmentURL(entry), options: .atomic)
            }
            var updated = entries + [entry]
            var evicted: [Entry] = []
            while updated.filter({ !$0.favorite }).count > maxEntries {
                if let index = updated.firstIndex(where: { !$0.favorite }) { evicted.append(updated.remove(at: index)) }
            }
            try persist(updated)
            entries = updated
            for old in evicted { try? FileManager.default.removeItem(at: attachmentURL(old)) }
            resetCursor()
        } catch { NSLog("[PromptHistory] Could not save prompt: %@", error.localizedDescription) }
    }

    public func attachments(for entry: Entry) -> [[String: String]] {
        guard !entry.attachmentNames.isEmpty else { return [] }
        do { return try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: attachmentURL(entry))) }
        catch { NSLog("[PromptHistory] Could not restore files: %@", error.localizedDescription); return [] }
    }

    public func remove(_ entry: Entry) {
        let updated = entries.filter { $0.id != entry.id }
        do {
            try persist(updated)
            entries = updated
            try? FileManager.default.removeItem(at: attachmentURL(entry))
            resetCursor()
        } catch { NSLog("[PromptHistory] Could not delete prompt: %@", error.localizedDescription) }
    }

    public func toggleFavorite(_ entry: Entry) {
        var updated = entries
        guard let index = updated.firstIndex(where: { $0.id == entry.id }) else { return }
        updated[index].favorite.toggle()
        do { try persist(updated); entries = updated }
        catch { NSLog("[PromptHistory] Could not save favorite: %@", error.localizedDescription) }
    }

    private func attachmentURL(_ entry: Entry) -> URL { directory.appendingPathComponent(entry.id + ".json") }
    private func persist(_ updated: [Entry]) throws {
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
    public func navigateUp(currentText: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if cursor == entries.count { draft = currentText }
        cursor = max(0, cursor - 1)
        return entries[cursor].text
    }
    public func navigateDown() -> String? {
        guard cursor < entries.count else { return nil }
        cursor += 1
        return cursor == entries.count ? draft : entries[cursor].text
    }
    public var browsingEntry: String? { cursor < entries.count ? entries[cursor].text : nil }
    public func resetCursor() { cursor = entries.count; draft = "" }
    public var recentMessages: [String] { entries.reversed().map(\.text) }
    public var hasMessages: Bool { !entries.isEmpty }
}
