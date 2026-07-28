import Foundation

/// A tool registered with `AgentBridge`, flattened for display and matching.
///
/// This is the *live* tool set of the running build — the thing a device
/// knows and a server-side view of the account does not, since the latter only
/// knows tools it has previously seen through discovery.
public struct RipulRegisteredTool: Identifiable, Hashable {
    public let name: String
    public let description: String
    /// True for tools the SDK registers itself (console_logs, inspect_screen, …)
    /// rather than ones the host app supplied. Grouping them is legal but
    /// rarely what a developer means, so the editor separates them.
    public let isBuiltIn: Bool

    public var id: String { name }

    public init(name: String, description: String, isBuiltIn: Bool) {
        self.name = name
        self.description = description
        self.isBuiltIn = isBuiltIn
    }
}
