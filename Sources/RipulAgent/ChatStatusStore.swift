import Foundation
import Combine

/// Leaf `ObservableObject` holding the chat-status line fields.
///
/// `latestChatStatus` / `persistentChatStatus` are written on **every pipeline
/// stage** of a message turn (`sent → … → inCli → done`, ~a dozen per turn) and
/// are consumed only by the (currently unmounted) `ChatStatusBar` and, via
/// Combine, `LiveActivityManager`. Leaving them `@Published` on `AgentBridge`
/// meant each pipeline-stage push re-rendered the WKWebView host for no reason —
/// the last per-turn host churner after the SessionListStore move. Isolating
/// them here keeps the host untouched; only views observing `bridge.chatStatus`
/// (or the Combine publishers) react.
@MainActor
public final class ChatStatusStore: ObservableObject {
    /// The most recent chat status message (convenience for single-line display).
    @Published public var latestChatStatus: String?
    /// Sticky chat status (e.g. rate-limit state) — not auto-hidden by the native
    /// UI; persists until replaced or cleared.
    @Published public var persistentChatStatus: String?

    public init() {}
}
