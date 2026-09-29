import SwiftUI

/// Whether the bridge is fetching the model catalogue. Split off `AgentBridge`
/// so the flag's per-fetch flips re-render only the views that draw a spinner,
/// not everything observing the bridge.
@MainActor
public final class RipulModelLoadingState: ObservableObject {
    @Published public internal(set) var isLoading = false
    /// Never loads; stands in when there is no bridge to observe.
    public static let idle = RipulModelLoadingState()
    public init() {}
}

/// Re-renders only its content when the model-loading flag flips.
public struct ModelLoadingReader<Content: View>: View {
    @ObservedObject private var state: RipulModelLoadingState
    private let content: (Bool) -> Content

    public init(_ state: RipulModelLoadingState, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.state = state
        self.content = content
    }

    public var body: some View { content(state.isLoading) }
}
