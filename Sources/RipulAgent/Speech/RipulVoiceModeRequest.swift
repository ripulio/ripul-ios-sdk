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

    /// Whether the waiting request is for a command session.
    public static var pendingCommands = false

    /// Whether the waiting request is for the full-screen conversation, not the
    /// panel beside the chat. A request by voice is for the panel; a test that
    /// measures the full-screen orb asks for this (`ripul://voice-mode?screen=full`).
    public static var pendingFullScreen = false

    /// `commands` opens a command session: every finished sentence is offered
    /// to `commandRouter` before it is sent to the agent, and a sentence ends
    /// on a pause alone. See `CommandOutcome`.
    public static func start(commands: Bool = false, fullScreen: Bool = false) {
        pendingCommands = commands
        pendingFullScreen = fullScreen
        pending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }

    // MARK: Command sessions
    //
    // Voice mode as a way of operating the app, not only of talking to an
    // agent. The words are recognised by voice mode's own transcription
    // instead of Siri's, and the host decides what each sentence was for.

    /// What the host made of one finished sentence.
    public enum CommandOutcome: Sendable {
        /// It was a command for the app, and the app ran it. A notice, if
        /// there is one to show, says what went wrong. Listening resumes.
        case ran(notice: String?)
        /// The host sent it to an agent itself, in a chat it chose. Voice mode
        /// waits for the reply and speaks it, as if it had sent the message.
        case sent
        /// Not a command: send it to the agent in the current chat, as voice
        /// mode always does.
        case forAgent
        /// The person has finished. Voice mode ends.
        case finished
    }

    /// Set once by the host. Without one a command session is ordinary voice
    /// mode.
    @MainActor public static var commandRouter: ((String) async -> CommandOutcome)?
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
