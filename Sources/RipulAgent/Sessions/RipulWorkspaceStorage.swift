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
        write(selection, to: directory.appendingPathComponent("selection.json"))
    }

    public func draft(for chatID: String) -> Draft {
        Self.read(chatDirectory(chatID).appendingPathComponent("draft.json")) ?? Draft()
    }

    public func saveDraft(_ draft: Draft, for chatID: String) {
        let folder = chatDirectory(chatID)
        let previous: Draft? = Self.read(folder.appendingPathComponent("draft.json"))
        guard draft != previous else { return }
        // Publish the small manifest before retiring unused image files.
        guard write(draft, to: folder.appendingPathComponent("draft.json")) else { return }
        for id in previous?.imageIDs ?? [] where !draft.imageIDs.contains(id) {
            try? FileManager.default.removeItem(at: imageURL(id, chatID: chatID))
        }
    }

    public func saveImage(_ image: NativeImageAttachment, for chatID: String) {
        let url = imageURL(image.id, chatID: chatID)
        // Attachments are immutable by ID; never encode megabytes on each keystroke.
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        write(image.toDictionary(), to: url)
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
        ids.compactMap { id in
            guard let stored: [String: String] = Self.read(imageURL(id, chatID: chatID)),
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
    @discardableResult private func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
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
