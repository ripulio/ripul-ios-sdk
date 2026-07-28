import Foundation

// ---------------------------------------------------------------------------
// A tool catalog is a NAMED TOOL SURFACE BELONGING TO ONE AGENT.
//
// An app that embeds Ripul has more than one, and they are disjoint:
//
//   • End-user tools  — what the user's agent can do (receipts, rota, pickers).
//                       Registered on the agent panel's bridge.
//   • Developer tools — what the in-app dev agent can do (console logs, screen
//                       inspection, theme knobs). Registered on the console's
//                       bridge.
//
// They live in the same process on different `AgentBridge` instances, so
// "the tools this build registered" is not a single set. Reading one bridge and
// calling the result "this app" is how the collections editor first came to
// report every end-user tool as missing.
//
// Progressive discovery applies to BOTH — either agent can carry too many tools
// — so both are organisable. What must never be ambiguous is WHICH agent's
// context is being economised. Hence: catalogs are named, carry a stated
// purpose, and the editor shows exactly one at a time. Never a union.
// ---------------------------------------------------------------------------

/// A named tool surface belonging to one agent.
public struct RipulToolCatalog: Identifiable, Hashable {
    /// Stable identifier, e.g. `"endUser"` / `"developer"`.
    public let id: String
    /// Shown in the catalog picker.
    public let name: String
    /// Plain-language statement of whose context grouping here protects.
    /// This is the sentence that keeps a developer oriented — write it for
    /// someone who has never seen this screen.
    public let purpose: String
    public let tools: [RipulRegisteredTool]

    public init(id: String, name: String, purpose: String, tools: [RipulRegisteredTool]) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.tools = tools
    }

    public init(id: String, name: String, purpose: String, nativeTools: [NativeTool]) {
        self.init(
            id: id,
            name: name,
            purpose: purpose,
            tools: nativeTools.map {
                RipulRegisteredTool(name: $0.name, description: $0.description, isBuiltIn: false)
            }
        )
    }

    public var toolNames: [String] { tools.map(\.name) }

    // MARK: - Well-known catalogs

    public static let endUserId = "endUser"
    public static let developerId = "developer"

    /// The host app's end-user surface — the tools its users' agent can call.
    /// This is the catalog most worth organising: it is usually the largest,
    /// and it is the one whose context window real users pay for.
    public static func endUser(_ tools: [NativeTool]) -> RipulToolCatalog {
        RipulToolCatalog(
            id: endUserId,
            name: "End-user tools",
            purpose: "What your users' agent can do. Grouping here saves context in the app's agent panel.",
            nativeTools: tools
        )
    }

    /// The in-app developer surface. Synthesised by the SDK from the console's
    /// own bridge, so a host never declares it.
    public static func developer(_ tools: [RipulRegisteredTool]) -> RipulToolCatalog {
        RipulToolCatalog(
            id: developerId,
            name: "Developer tools",
            purpose: "What the in-app dev agent can do. Grouping here saves context in this console.",
            tools: tools
        )
    }
}

// MARK: - Attribution

/// Where a collection member lives, from the point of view of the catalog
/// currently on screen.
///
/// The flat "not in this app" this replaces was false in both directions: an
/// end-user tool IS in the app, just on another surface, and a web app tool is
/// not native to any catalog.
public enum RipulMemberOrigin: Hashable {
    /// Registered in the catalog being viewed.
    case thisCatalog
    /// Registered in a different catalog — carries its display name.
    case otherCatalog(name: String)
    /// Not registered natively anywhere in this build: a web app tool, or a
    /// tool belonging to another device.
    case notNative
}

public enum RipulMemberAttribution {
    /// Resolve a member name against every known catalog.
    ///
    /// Compares canonically, so a member stored as `device_console_logs`
    /// resolves against a catalog registering `console_logs`.
    public static func origin(
        of memberName: String,
        viewing current: RipulToolCatalog,
        allCatalogs: [RipulToolCatalog]
    ) -> RipulMemberOrigin {
        let canonical = RipulToolCollectionMatcher.canonicalName(memberName)

        if current.toolNames.contains(where: { RipulToolCollectionMatcher.canonicalName($0) == canonical }) {
            return .thisCatalog
        }
        for catalog in allCatalogs where catalog.id != current.id {
            if catalog.toolNames.contains(where: { RipulToolCollectionMatcher.canonicalName($0) == canonical }) {
                return .otherCatalog(name: catalog.name)
            }
        }
        return .notNative
    }
}
