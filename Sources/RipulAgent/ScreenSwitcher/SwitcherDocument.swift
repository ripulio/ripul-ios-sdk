#if canImport(UIKit)
import Foundation

/// One open document in the switcher's MDI set.
///
/// ## Why documents and not tabs
/// A tab is a place in the app; a document is a thing you are looking at. The
/// distinction only becomes load-bearing once a place can hold many things —
/// "Agent" is one tab but N chats, and collapsing them into a single card makes
/// the switcher useless for the case it exists to serve (getting from one chat
/// straight to another). Repos and files have the same shape, so identity is
/// `kind:instance` and all three fall out of the same machinery.
///
/// ## Virtual, not true, MDI
/// Nothing here mounts anything. Each screen still holds exactly ONE live
/// instance — one focused chat, one selected repo, one open file — and switching
/// documents re-targets it. True MDI would mount every open document at once,
/// which for chats means a WKWebView apiece. The thumbnails are what make the
/// set feel simultaneously open; the shell keeps only one of each alive.
public struct SwitcherDocument: Identifiable, Equatable, Codable {
    /// `chat:<id>`, `repo:<name>`, `file:<path>` — or a bare tab name for the
    /// singletons (`settings`, `todos`), which can only ever have one instance.
    public let id: String
    /// The tab that hosts this document, as a `SidebarTab` raw value. The shell
    /// uses it to decide where to navigate; the store never interprets it.
    public let host: String
    /// The instance within that host, or nil for a singleton.
    public let instance: String?
    public var title: String
    public var subtitle: String?
    public let icon: String

    public init(
        id: String,
        host: String,
        instance: String? = nil,
        title: String,
        subtitle: String? = nil,
        icon: String
    ) {
        self.id = id
        self.host = host
        self.instance = instance
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
    }

    /// A singleton screen — one card, however many times you visit it.
    ///
    /// Closable like anything else. Singletons used to be pinned on the grounds
    /// that closing "Settings" left a gap only the launcher could refill — but
    /// the launcher is in the same overlay, lists every tab whether open or not,
    /// and already re-selects an open one rather than duplicating it. So the gap
    /// was always one tap from being refilled, and pinning only meant that
    /// glancing at a screen once put a card on the board for good.
    public static func singleton(host: String, title: String, icon: String) -> SwitcherDocument {
        SwitcherDocument(id: host, host: host, title: title, icon: icon)
    }

    /// An instance document — one of many within a host.
    public static func instance(
        host: String,
        instance: String,
        title: String,
        subtitle: String? = nil,
        icon: String
    ) -> SwitcherDocument {
        SwitcherDocument(
            id: "\(host):\(instance)",
            host: host,
            instance: instance,
            title: title,
            subtitle: subtitle,
            icon: icon
        )
    }
}
#endif
