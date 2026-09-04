import SwiftUI

/// A request to enter hands-free voice mode that did not come from the mic
/// long-press — today, Siri's "Talk to Ripul" intent.
///
/// The controller that owns hands-free mode (`VoiceModeController`) is a
/// `@StateObject` inside `AgentView`, so nothing outside that view can reach
/// it. This is the seam: the caller sets a latch, `AgentView` acts on it. Same
/// notification-plus-latch shape as the new-session request in the app target,
/// and for the same reason — a Siri cold launch fires the intent before any
/// view exists to hear a notification.
///
/// The latch is NOT cleared by merely observing it. `AgentView` leaves it set
/// until the bridge is actually connected and the web view is ready, because
/// voice mode with nothing to send to is worse than a moment's delay.
public enum RipulVoiceModeRequest {
    public static let notification = Notification.Name("ripulStartVoiceMode")

    /// True while a request is waiting to be honoured.
    public static var pending = false

    public static func start() {
        pending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

/// Wires both delivery routes plus the readiness retry onto a view.
///
/// Three hooks rather than one because a request can arrive in three states:
/// while the chat is already on screen (notification), before it exists at all
/// (cold launch — drained on appear), or while it exists but the web view is
/// still booting (retried when the bridge connects).
struct RipulVoiceModeRequestObserver: ViewModifier {
    let isConnected: Bool
    let perform: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: RipulVoiceModeRequest.notification)) { _ in
                perform()
            }
            .onAppear { perform() }
            .onChange(of: isConnected) { _ in perform() }
    }
}

extension View {
    func onRipulVoiceModeRequest(isConnected: Bool, perform: @escaping () -> Void) -> some View {
        modifier(RipulVoiceModeRequestObserver(isConnected: isConnected, perform: perform))
    }
}
