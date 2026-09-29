#if os(iOS)
import Foundation
import QuartzCore

/// Hand-off between the two left-edge slides: the chat sliding back to the
/// session list (SDK, AgentChatDragContainer) and the host's app drawer.
///
/// The chat lands on its own state and only then flips `showingSessionList`,
/// because that flip re-renders the whole shell (see AgentChatDragContainer).
/// For that ~0.45s the host still believes the chat is showing, so an
/// immediate edge swipe for the drawer found no recognizer and was ignored.
/// The host reads `chatLandingOnList` at touch time to accept that swipe, and
/// sets `drawerInteracting` so the chat defers its flip — and the re-render it
/// causes — until the drawer has come to rest. Plain flags, deliberately not
/// observable: they are read at touch time and must not re-render anything.
@MainActor
public enum RipulSlideCoordination {
    public static var chatLandingOnList = false
    public static var drawerInteracting = false

    /// When the chat slide last moved, landed or flipped (media time).
    public private(set) static var lastSlideActivity: CFTimeInterval = 0
    public static func noteSlideActivity() { lastSlideActivity = CACurrentMediaTime() }

    /// No slide under the finger or settling, and none for `quietFor`
    /// seconds: the moment for deferred main-thread work (a thumbnail
    /// capture) that would otherwise land inside the user's next swipe.
    public static func isQuiet(for quietFor: CFTimeInterval = 0.8) -> Bool {
        !drawerInteracting && !chatLandingOnList
            && CACurrentMediaTime() - lastSlideActivity > quietFor
    }
}
#endif
