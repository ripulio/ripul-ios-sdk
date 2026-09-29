import Foundation
import CryptoKit
import Combine

/// Durable UI state is private to a window. Account data stays in the shared store.
/// This deliberately isn't observable: typing must not invalidate the web-view host.
public final class RipulWorkspaceStorage {
    struct Acknowledgement { let chatID: String; let text: String; let imageIDs: [String] }
    // Only the composer subscribes. An acknowledgement can outlive a temporarily
    // unmounted composer (for example while a file viewer covers the chat).
    let acknowledgements = PassthroughSubject<Acknowledgement, Never>()
    public struct Selection: Codable, Equatable {
        public var sessionID: String?
        public var machineID: String?
        public var tab: String?
        public var showingSessions: Bool?
        public init() {}
    }

    public struct Draft: Codable, Equatable {
        public var text: String
        public var participants: [String]
        public var imageIDs: [String]
        public init(text: String = "", participants: [String] = [], imageIDs: [String] = []) {
            self.text = text; self.participants = participants; self.imageIDs = imageIDs
        }
    }

    private let directory: URL
    /// All file I/O, in order. Writes are async: they ran on the main thread
    /// inside SwiftUI onChange actions — the list/chat flip's selection save
    /// was 87-92% of that flip's 62-90ms stall, and every keystroke re-read
    /// and rewrote the draft. Reads are sync through the same queue, so they
    /// always see every write issued before them.
    private let io = DispatchQueue(label: "io.ripul.workspaceStorage", qos: .utility)
    /// The last draft saved or read per chat, so a keystroke compares in
    /// memory instead of reading the previous draft back from disk.
    private var drafts: [String: Draft] = [:]
    public private(set) var selection: Selection
    public let hasSavedSelection: Bool

    public init(id: UUID, root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RipulWorkspaces", isDirectory: true)
        directory = base.appendingPathComponent(id.uuidString, isDirectory: true)
        let saved: Selection? = Self.read(directory.appendingPathComponent("selection.json"))
        selection = saved ?? Selection()
        hasSavedSelection = saved != nil
    }

    public func updateSelection(_ update: (inout Selection) -> Void) {
        let previous = selection
        update(&selection)
        guard previous != selection else { return }
        let value = selection, url = directory.appendingPathComponent("selection.json")
        io.async { [directory] in Self.write(value, to: url, directory: directory) }
    }

    public func draft(for chatID: String) -> Draft {
        if let cached = drafts[chatID] { return cached }
        let url = chatDirectory(chatID).appendingPathComponent("draft.json")
        let saved: Draft = io.sync { Self.read(url) } ?? Draft()
        drafts[chatID] = saved
        return saved
    }

    public func saveDraft(_ draft: Draft, for chatID: String) {
        let previous = self.draft(for: chatID)
        guard draft != previous else { return }
        drafts[chatID] = draft
        let url = chatDirectory(chatID).appendingPathComponent("draft.json")
        let retired = previous.imageIDs.filter { !draft.imageIDs.contains($0) }.map { imageURL($0, chatID: chatID) }
        io.async { [directory] in
            // Publish the small manifest before retiring unused image files.
            guard Self.write(draft, to: url, directory: directory) else { return }
            for file in retired { try? FileManager.default.removeItem(at: file) }
        }
    }

    public func saveImage(_ image: NativeImageAttachment, for chatID: String) {
        let url = imageURL(image.id, chatID: chatID)
        io.async { [directory] in
            // Attachments are immutable by ID; never encode megabytes on each keystroke.
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            Self.write(image.toDictionary(), to: url, directory: directory)
        }
    }

    /// An acknowledgement may arrive after navigating to another chat. Retire
    /// only what was submitted, retaining anything typed or attached meanwhile.
    public func acknowledgeDraft(text: String, imageIDs: [String], for chatID: String) {
        var saved = draft(for: chatID)
        if saved.text == text { saved.text = ""; saved.participants = [] }
        saved.imageIDs.removeAll { imageIDs.contains($0) }
        saveDraft(saved, for: chatID)
        acknowledgements.send(.init(chatID: chatID, text: text, imageIDs: imageIDs))
    }

    public func images(for chatID: String, ids: [String]) -> [NativeImageAttachment] {
        let stored: [String: [String: String]] = io.sync {
            var found: [String: [String: String]] = [:]
            for id in ids { found[id] = Self.read(imageURL(id, chatID: chatID)) }
            return found
        }
        return ids.compactMap { id in
            guard let stored = stored[id],
                  let encoded = stored["data"], let mediaType = stored["mediaType"],
                  let data = Data(base64Encoded: encoded), let thumbnail = PlatformImage(data: data) else { return nil }
            return NativeImageAttachment(id: id, mediaType: mediaType, data: encoded, thumbnail: thumbnail)
        }
    }

    private func chatDirectory(_ chatID: String) -> URL {
        directory.appendingPathComponent(Self.key(chatID), isDirectory: true)
    }
    private func imageURL(_ id: String, chatID: String) -> URL {
        chatDirectory(chatID).appendingPathComponent("image-" + Self.key(id) + ".json")
    }
    private static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    @discardableResult private static func write<T: Encodable>(_ value: T, to url: URL, directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var directory = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let data = try JSONEncoder().encode(value)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            return true
        } catch {
            NSLog("[RipulWorkspace] Could not save local window state: %@", error.localizedDescription)
            return false
        }
    }
}
