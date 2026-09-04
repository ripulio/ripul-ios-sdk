import SwiftUI

/// A request to open a specific session that did not come from tapping a row —
/// today, Siri's "Ripul session" intent.
///
/// Opening a `UnifiedSession` is not one action but three, chosen by what the
/// session currently is: focus an already-open web tab, wait for a cached-open
/// tab to be restored, or seed a remote one over the relay. That logic lives in
/// `RipulSessionListModel.openSession`, and duplicating it anywhere else is how
/// the three cases drift apart.
///
/// So callers outside the list don't open anything. They name a session and the
/// list opens it, through exactly the path a tap would take. Same
/// notification-plus-latch shape as the voice-mode request.
///
/// Note this is emphatically NOT `bridge.focusSession(id:)`. That takes a LIVE
/// tab id and silently does nothing for a session that isn't currently open —
/// which looks like the app accepting the request and then ignoring it.
public enum RipulOpenSessionRequest {
    public static let notification = Notification.Name("ripulOpenUnifiedSession")

    /// The `UnifiedSession.id` waiting to be opened.
    public static var pendingSessionId: String?

    public static func open(sessionId: String) {
        pendingSessionId = sessionId
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

/// Delivers the request from whichever side lands first, and retries as the
/// session list fills in — on a cold launch the request arrives long before
/// `unifiedSessions` has anything in it.
struct RipulOpenSessionRequestObserver: ViewModifier {
    let sessionCount: Int
    let perform: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: RipulOpenSessionRequest.notification)) { _ in
                perform()
            }
            .onAppear { perform() }
            .onChange(of: sessionCount) { _ in perform() }
    }
}

extension View {
    func onRipulOpenSessionRequest(sessionCount: Int, perform: @escaping () -> Void) -> some View {
        modifier(RipulOpenSessionRequestObserver(sessionCount: sessionCount, perform: perform))
    }
}
