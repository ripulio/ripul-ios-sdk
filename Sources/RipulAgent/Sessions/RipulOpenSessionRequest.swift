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
    public static var pendingMachineId: String?

    /// The rescan chasing a request whose chat isn't listed yet.
    static var rescan: (id: String, task: Task<Void, Never>)?

    public static func open(sessionId: String, machineId: String? = nil) {
        pendingSessionId = sessionId
        pendingMachineId = machineId
        opening = (sessionId, .now)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    // MARK: Waiting for the chat to be on screen
    //
    // A request is fire-and-forget, which is right for Siri and a deep link:
    // nothing follows them. An agent's tool is different. "Send this to the
    // deploy chat" is an open and then a send, and a send that does not wait
    // goes to whichever chat was on screen before. So a caller can wait, and is
    // told when the list has put the chat in front — by the list, through the
    // same open a tapped row makes, rather than by guessing at a delay.

    /// How long a request is treated as still under way. An open that fails
    /// reports through the list's own error notice, not here, so without a
    /// limit one failure would hold every later wait.
    public static let openingLimit: Duration = .seconds(20)

    private static var opening: (sessionId: String, since: ContinuousClock.Instant)?
    private static var waiters: [UUID: (sessionId: String, continuation: CheckedContinuation<String?, Never>)] = [:]

    /// Ask for a chat and wait until it is the one on screen.
    ///
    /// `request` does the asking once the wait is in place — the app's own
    /// navigation, which lands on the list and ends in `open(sessionId:)`.
    /// Returns the open tab's id, or nil when the chat did not open in time:
    /// its machine is offline, or it is no longer listed.
    @MainActor
    public static func whenOpened(_ sessionId: String, timeout: Duration = openingLimit,
                                  request: @MainActor () -> Void) async -> String? {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            waiters[token] = (sessionId, continuation)
            request()
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                waiters.removeValue(forKey: token)?.continuation.resume(returning: nil)
            }
        }
    }

    /// Wait for an open that is under way, if there is one. For an action that
    /// works on "the current chat" — start talking, stop the agent — so that
    /// run straight after "open the deploy chat" it means the deploy chat.
    @MainActor
    public static func settled() async {
        guard let opening else { return }
        let left = openingLimit - (ContinuousClock.now - opening.since)
        guard left > .zero else { return }
        _ = await whenOpened(opening.sessionId, timeout: left) {}
    }

    /// The list reports a requested chat as on screen (`tabId`), or as one it
    /// has stopped trying to open (nil).
    @MainActor
    static func finished(_ sessionId: String, tabId: String?) {
        if opening?.sessionId == sessionId { opening = nil }
        for (token, waiter) in waiters where waiter.sessionId == sessionId {
            waiters.removeValue(forKey: token)
            waiter.continuation.resume(returning: tabId)
        }
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

/// A request to run Move to Machine on a named chat without the long-press
/// menu — `ripul://move-chat?id=<chat id>&to=<machine id>`. Automation can't
/// raise a context menu, so this is how an agent drives the move end to end.
/// The list performs it with the same `moveSession` call the menu button makes,
/// and reports the outcome as a `[MOVE]` console line.
public enum RipulMoveSessionRequest {
    public static let notification = Notification.Name("ripulMoveUnifiedSession")

    /// Latched, like the open request, so a list that mounts after the link
    /// arrives still picks it up.
    public static var pending: (sessionId: String, targetMachineId: String)?

    public static func move(sessionId: String, targetMachineId: String) {
        pending = (sessionId, targetMachineId)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// Hands the pending request to exactly one taker.
    static func take() -> (sessionId: String, targetMachineId: String)? {
        defer { pending = nil }
        return pending
    }
}
