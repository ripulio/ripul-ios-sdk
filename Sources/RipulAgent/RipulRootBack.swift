import SwiftUI

/// The way back to the screen a root screen was opened from.
///
/// The Ripul app's Home pushes the screens it opens (Peter, 4 November 2026:
/// "When we navigate down from the home screen it's important to maintain the
/// navigation context so we can go back to the place we came from"). Those
/// screens are otherwise roots, whose leading button opens the app's sidebar.
/// With this in the environment that button goes back instead: `GlassTopBar`
/// draws a back chevron where it would draw its sidebar button, and the agent
/// screen does the same for its list. With `includesChat`, the open chat is
/// one the host opened itself, so the chat's back button goes back too, and
/// its swipe back is handed to the host, which carries the whole screen.
@MainActor
public protocol RipulRootBackHandling: AnyObject {
    /// The back button: go back to where the screen was opened from.
    func goBack()
    /// The chat's swipe back, while `includesChat`: how far the finger has
    /// carried it from the left edge.
    func backSwipeChanged(_ offset: CGFloat)
    func backSwipeEnded(offset: CGFloat, velocity: CGFloat)
    func backSwipeCancelled()
}

public struct RipulRootBack: Equatable {
    /// What the back goes to, for its label: "Back to Home".
    public let title: String
    /// The open chat was opened from there too: its back goes there rather
    /// than to the chat list.
    public let includesChat: Bool
    public let handler: any RipulRootBackHandling

    public init(title: String, includesChat: Bool = false, handler: any RipulRootBackHandling) {
        self.title = title
        self.includesChat = includesChat
        self.handler = handler
    }

    /// The symbol a root's sidebar button shows. A bar showing it is a root.
    public static let sidebarSymbol = "line.3.horizontal"

    /// Compared without the handler's state: the environment re-renders the
    /// screens that read it only when where the back goes has changed.
    public static func == (lhs: RipulRootBack, rhs: RipulRootBack) -> Bool {
        lhs.title == rhs.title && lhs.includesChat == rhs.includesChat && lhs.handler === rhs.handler
    }
}

private struct RipulRootBackKey: EnvironmentKey {
    static let defaultValue: RipulRootBack? = nil
}

extension EnvironmentValues {
    /// Where this root screen goes back to, when it was opened from another
    /// screen rather than from the sidebar or the tab bar (see `RipulRootBack`).
    public var ripulRootBack: RipulRootBack? {
        get { self[RipulRootBackKey.self] }
        set { self[RipulRootBackKey.self] = newValue }
    }
}
