import Foundation

/// How a chat shows the agent's thinking: the web's `showThinking` setting
/// (`FlowSettings`), which every chat view on the device follows.
public enum ThinkingDisplayMode: String, CaseIterable, Sendable {
    /// Not shown.
    case none
    /// A lozenge that opens the thinking when tapped.
    case folded
    /// Shown in full where it happened. The web's default.
    case open

    /// The setting as the page stores it. Anything else reads as `open`, as
    /// the web's `normalizeThinkingMode` reads it.
    public init(setting: String?) {
        self = setting.flatMap(Self.init(rawValue:)) ?? .open
    }
}

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

    /// How thinking is displayed: "none", "folded", or "open", as the page
    /// stores it. Starts at the web's default until the page (or the value
    /// the bridge remembered from it) says otherwise.
    @Published public var showThinkingMode: String = ThinkingDisplayMode.open.rawValue

    /// `showThinkingMode`, read the way the web reads it.
    public var thinkingDisplayMode: ThinkingDisplayMode { ThinkingDisplayMode(setting: showThinkingMode) }

    public init() {}
}
