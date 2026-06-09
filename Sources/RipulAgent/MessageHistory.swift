import Foundation

/// Tracks sent message history and supports terminal-style up/down arrow cycling.
/// Messages are de-duplicated — only the most recent occurrence of each message is kept.
/// History is persisted to UserDefaults across sessions.
/// Favorites are stored separately and are never evicted by the max-entries limit.
@available(iOS 16.0, macOS 14.0, *)
public class MessageHistory: ObservableObject {
    private static let storageKey = "ripul.messageHistory"
    private static let favoritesKey = "ripul.messageHistory.favorites"

    private var messages: [String] = []
    @Published private var favorites: Set<String> = []
    /// Current position when browsing. `messages.count` means "not browsing" (at the draft).
    private var cursor: Int = 0
    /// The text the user was typing before they started browsing history.
    private var draft: String = ""
    private let maxEntries: Int

    public init(maxEntries: Int = 500) {
        self.maxEntries = maxEntries
        if let saved = UserDefaults.standard.stringArray(forKey: Self.storageKey) {
            self.messages = Array(saved.suffix(maxEntries))
        }
        if let savedFavorites = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) {
            self.favorites = Set(savedFavorites)
        }
        self.cursor = messages.count
    }

    /// Record a sent message. De-duplicates by removing any earlier occurrence.
    public func record(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.removeAll { $0 == trimmed }
        messages.append(trimmed)
        // When trimming, never evict favorites
        while messages.count > maxEntries {
            if let idx = messages.firstIndex(where: { !favorites.contains($0) }) {
                messages.remove(at: idx)
            } else {
                break // all remaining are favorites, stop evicting
            }
        }
        resetCursor()
        save()
    }

    /// Remove a message from history entirely (also unfavorites it).
    public func remove(_ message: String) {
        messages.removeAll { $0 == message }
        favorites.remove(message)
        resetCursor()
        save()
        saveFavorites()
    }

    /// Toggle whether a message is favorited.
    public func toggleFavorite(_ message: String) {
        if favorites.contains(message) {
            favorites.remove(message)
        } else {
            favorites.insert(message)
        }
        saveFavorites()
    }

    /// Check if a message is favorited.
    public func isFavorite(_ message: String) -> Bool {
        favorites.contains(message)
    }

    private func save() {
        UserDefaults.standard.set(messages, forKey: Self.storageKey)
    }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favorites), forKey: Self.favoritesKey)
    }

    /// Call when up arrow is pressed. Returns the text to display, or nil if no history.
    public func navigateUp(currentText: String) -> String? {
        guard !messages.isEmpty else { return nil }
        if cursor == messages.count {
            // Starting to browse — save the draft
            draft = currentText
        }
        if cursor > 0 {
            cursor -= 1
            return messages[cursor]
        }
        // Already at oldest — stay there
        return messages[cursor]
    }

    /// Call when down arrow is pressed. Returns the text to display, or nil if already at draft.
    public func navigateDown() -> String? {
        guard cursor < messages.count else { return nil }
        cursor += 1
        if cursor == messages.count {
            // Back to draft
            return draft
        }
        return messages[cursor]
    }

    /// Reset browsing position (e.g. after sending a message).
    public func resetCursor() {
        cursor = messages.count
        draft = ""
    }

    /// Returns recent messages in reverse chronological order (most recent first).
    public var recentMessages: [String] {
        Array(messages.reversed())
    }

    /// Returns favorited messages in reverse chronological order (most recent first).
    public var favoriteMessages: [String] {
        messages.reversed().filter { favorites.contains($0) }
    }

    /// Returns non-favorited recent messages in reverse chronological order.
    public var nonFavoriteRecentMessages: [String] {
        messages.reversed().filter { !favorites.contains($0) }
    }

    /// Whether there are any messages (favorites or recent) to show.
    public var hasMessages: Bool {
        !messages.isEmpty
    }
}
