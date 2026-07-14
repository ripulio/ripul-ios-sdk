import Foundation

/// Leaf ObservableObject for navigation + model-display state.
///
/// Extracted off AgentBridge so that session-navigation gestures and
/// thinking-mode changes don't fire bridge.objectWillChange — which would
/// otherwise re-render every view that observes the full 53-field bridge,
/// including the WKWebView host (AgentView) and all session-list containers.
///
/// Same pattern as SessionListStore and ChatStatusStore.
@MainActor
public final class NavigationStore: ObservableObject {
    /// Set while a session-switch slide animation is in flight; cleared once
    /// the animation completes. Session list rows use this to keep their
    /// spinner running through the full sweep, not just until focusSession starts.
    @Published public var navigatingToSessionId: String? = nil

    /// How thinking is displayed in LLM panels: "none", "folded", or "open".
    @Published public var showThinkingMode: String = "none"

    public init() {}
}
