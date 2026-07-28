import SwiftUI

/// Carries the credential the tool-collections editor needs, injected by
/// whichever surface guarantees a signed-in developer.
///
/// This exists so the entry point can be *structurally* gated rather than
/// gated by a runtime check that someone forgets. `ConsoleLogViewer` is
/// reachable from `.ripulDevTools(bridge:)`, which carries no login at all —
/// so the editor's row only appears when a surface has put this in the
/// environment. `RipulAgentConsole` does; the bare DevTools modifier does not.
///
/// Mirrors the shape of `DevToolsAction`.
public struct RipulToolCollectionsAccess {
    public let tokenProvider: () -> String?

    public init(tokenProvider: @escaping () -> String?) {
        self.tokenProvider = tokenProvider
    }
}

private struct RipulToolCollectionsAccessKey: EnvironmentKey {
    static let defaultValue: RipulToolCollectionsAccess? = nil
}

public extension EnvironmentValues {
    /// Non-nil when the presenting surface has an authenticated Ripul session.
    var ripulToolCollectionsAccess: RipulToolCollectionsAccess? {
        get { self[RipulToolCollectionsAccessKey.self] }
        set { self[RipulToolCollectionsAccessKey.self] = newValue }
    }
}
