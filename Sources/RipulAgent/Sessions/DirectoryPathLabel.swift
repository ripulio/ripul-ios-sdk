import SwiftUI

// MARK: - Display Model

/// A filesystem path split into the part you *choose by* and the part you only
/// need for orientation.
///
/// Every working directory on a developer machine shares the same long prefix
/// (`/Users/someone/Documents/repos/…`), so a list of them rendered as full
/// paths is a column of near-identical strings whose only distinguishing
/// characters sit at the far right, past where the row truncates. The last
/// component is the repo — that is what the eye is actually hunting for.
///
/// Splitting here (rather than at each call site) keeps the parse testable and
/// keeps every directory dropdown in the app reading the same way.
public struct DirectoryPathDisplay: Equatable, Sendable {
    /// The final path component — the repo or folder being chosen.
    public let name: String
    /// Everything above `name`, or `nil` when the path has no parent to show.
    public let prefix: String?

    public init(name: String, prefix: String?) {
        self.name = name
        self.prefix = prefix
    }

    /// Round-trips back to something path-shaped, for accessibility labels.
    public var joined: String {
        guard let prefix, !prefix.isEmpty else { return name }
        return prefix.hasSuffix("/") ? prefix + name : prefix + "/" + name
    }

    /// Home directories are collapsed to `~` by *pattern* (`/Users/<user>/…`,
    /// `/home/<user>/…`) rather than by comparing against `NSHomeDirectory()`.
    /// These paths usually describe a **remote** host — the Mac a phone is
    /// driving — so the local home directory is the wrong yardstick, and on iOS
    /// it is an app sandbox that would never match anyway.
    public static func parse(_ path: String) -> DirectoryPathDisplay {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return DirectoryPathDisplay(name: "", prefix: nil) }

        var working = trimmed
        while working.count > 1, working.hasSuffix("/") { working.removeLast() }
        guard working != "/" else { return DirectoryPathDisplay(name: "/", prefix: nil) }

        let isAbsolute = working.hasPrefix("/")
        var components = working.split(separator: "/").map(String.init)

        if isAbsolute, components.count >= 2, components[0] == "Users" || components[0] == "home" {
            components.replaceSubrange(0...1, with: ["~"])
        }

        guard let name = components.last else {
            return DirectoryPathDisplay(name: working, prefix: nil)
        }
        let parents = components.dropLast()
        guard !parents.isEmpty else {
            // A top-level entry still shows its root, so `/opt` doesn't render
            // identically to a relative `opt`. `~` is already a root.
            let root = (isAbsolute && components.first != "~") ? "/" : nil
            return DirectoryPathDisplay(name: name, prefix: root)
        }

        let joined = parents.joined(separator: "/")
        // A tilde already stands in for the root, so re-adding a leading slash
        // would produce `/~/…`.
        let prefix = (isAbsolute && components.first != "~") ? "/" + joined : joined
        return DirectoryPathDisplay(name: name, prefix: prefix)
    }
}

// MARK: - Label

/// Two-line rendering of a directory path: the parent path small and receded
/// above, the directory name large and bold below.
///
/// The prefix truncates from the *head* — the tail of a parent path
/// (`…/Documents/repos`) is what tells you where you are; the leading
/// `/Users/someone` is the part you can lose without losing the thread.
///
/// Note this cannot be used inside a `Menu`: SwiftUI hands menu rows to
/// `UIMenu`/`NSMenu`, which take a title and an image and drop custom layout
/// and fonts entirely. Directory pickers that want this treatment have to be
/// real views — see `WorkingDirectoryPicker`.
public struct DirectoryPathLabel: View {
    /// How loudly the name is set. `prominent` is for pickers, where the row
    /// *is* the choice; `compact` is for dense settings lists.
    public enum Prominence: Sendable {
        case prominent
        case compact

        var nameFont: Font {
            switch self {
            case .prominent: return .headline
            case .compact: return .subheadline.weight(.semibold)
            }
        }

        var prefixFont: Font {
            switch self {
            case .prominent: return .caption
            case .compact: return .caption2
            }
        }
    }

    private let display: DirectoryPathDisplay
    private let prominence: Prominence

    public init(path: String, prominence: Prominence = .prominent) {
        self.display = DirectoryPathDisplay.parse(path)
        self.prominence = prominence
    }

    public init(display: DirectoryPathDisplay, prominence: Prominence = .prominent) {
        self.display = display
        self.prominence = prominence
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let prefix = display.prefix, !prefix.isEmpty {
                Text(prefix)
                    .font(prominence.prefixFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(display.name)
                .font(prominence.nameFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // VoiceOver gets the whole path; the visual split is a sighted-reading
        // aid and reading it as two fragments would be worse, not better.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.joined)
    }
}
