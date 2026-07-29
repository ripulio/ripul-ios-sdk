import Foundation

// ---------------------------------------------------------------------------
// THE ONE REGISTRY OF NATIVE TOOLS IN A HOST APP (native-tool-registry phase 1).
//
// The developer registers every tool once, tagged by AUDIENCE — who the tool is
// for — and every downstream consumer reads the same registry: channel
// exposure (which tools an AgentBridge broadcasts and will invoke), the
// tool-collections editor (which surfaces exist and what belongs to each), and
// attribution (where a collection member lives).
//
// The registry DESCRIBES, it never AUTHORIZES: which tools actually reach an
// agent is decided by the channel's exposure (audience projection + the
// phase-0 marker gate) and server-side curation/security. No code path derives
// permission from "who registered a tool" — see the plan's invariant 3.
//
// Registration order is preserved; duplicate canonical names fail loudly
// (precondition) — the per-bridge era made collisions impossible by accident,
// the registry makes them impossible by contract.
//
// Ownership is explicit, not a singleton: one registry per host app, handed to
// both the console configuration and the end-user AgentView. (WAC's
// isolated-instance patterns and the tests want two registries in one
// process.) Main-thread use is assumed, matching AgentBridge.
// ---------------------------------------------------------------------------

/// Who a registered tool is for.
///
/// An audience is a fact about the TOOL (who it serves); a channel's
/// `RipulChannelAudience` is a fact about the SESSION (who is driving). The
/// names match because a channel exposes its own audience's tools.
public enum RipulToolAudience: Hashable {
    /// The host app's end-user surface — what its users' agent can call.
    case endUser
    /// The developer console's surface. SDK dev tools carry this via the
    /// SDK-internal composition paths; a host may also tag its own
    /// dev-assistant contributions (e.g. `RipulDevThemeTools.all`) with it.
    /// Tagging a tool `.developer` only ever NARROWS where it appears — it can
    /// never leak one onto an end-user channel (the phase-0 gate is
    /// structural).
    case developer
    /// An additional named surface, for hosts with more than the end-user /
    /// developer pair. Editor-visible; no channel exposes it today.
    case named(id: String, purpose: String)
}

/// One registry per host app: every native tool, registered once, tagged by
/// audience. Channels expose projections of it; the editor organises it.
public final class RipulToolRegistry {
    public struct Entry {
        public let tool: NativeTool
        public let audience: RipulToolAudience
    }

    public private(set) var allEntries: [Entry] = []
    /// SDK-internal change observation — bridges re-broadcast `mcp:tools` when
    /// the registry changes after connection.
    private var observers: [UUID: () -> Void] = [:]

    public init() {}

    /// Register tools under an audience. Duplicate canonical names FAIL LOUDLY
    /// across the whole registry, regardless of audience — a dev tool and an
    /// end-user tool sharing a name would make name-based invocation silently
    /// first-match, and this codebase's history says fail at registration
    /// instead.
    public func register(_ tools: [NativeTool], audience: RipulToolAudience) {
        var seen = Set(allEntries.map { RipulToolCollectionMatcher.canonicalName($0.tool.name) })
        for tool in tools {
            let canonical = RipulToolCollectionMatcher.canonicalName(tool.name)
            precondition(
                seen.insert(canonical).inserted,
                "RipulToolRegistry: duplicate tool name \"\(tool.name)\" (canonical \"\(canonical)\") — every tool is registered exactly once, under exactly one audience"
            )
        }
        allEntries.append(contentsOf: tools.map { Entry(tool: $0, audience: audience) })
        notifyChanged()
    }

    /// Replace ONE audience's entries wholesale — for hosts whose tool set is
    /// dynamic (the Mac app rebuilds its per-script tools whenever the script
    /// store changes). Other audiences' entries are untouched; the duplicate
    /// contract is enforced against them.
    public func setTools(_ tools: [NativeTool], audience: RipulToolAudience) {
        let kept = allEntries.filter { $0.audience != audience }
        var seen = Set(kept.map { RipulToolCollectionMatcher.canonicalName($0.tool.name) })
        for tool in tools {
            let canonical = RipulToolCollectionMatcher.canonicalName(tool.name)
            precondition(
                seen.insert(canonical).inserted,
                "RipulToolRegistry: duplicate tool name \"\(tool.name)\" (canonical \"\(canonical)\") — every tool is registered exactly once, under exactly one audience"
            )
        }
        allEntries = kept + tools.map { Entry(tool: $0, audience: audience) }
        notifyChanged()
    }

    public func entries(audience: RipulToolAudience) -> [Entry] {
        allEntries.filter { $0.audience == audience }
    }

    public func tools(audience: RipulToolAudience) -> [NativeTool] {
        entries(audience: audience).map(\.tool)
    }

    /// Every registered tool, as editor-facing summaries. Channel-bound tools
    /// (a console's own `console_logs` etc.) are NOT here — they belong to
    /// their channel; read `AgentBridge.registeredToolSummaries` for a
    /// channel's full exposed set.
    public var summaries: [RipulRegisteredTool] {
        allEntries.map {
            RipulRegisteredTool(name: $0.tool.name, description: $0.tool.description, isBuiltIn: false)
        }
    }

    /// The audience a tool name is registered under, compared canonically —
    /// this is what attribution ("in End-user tools" / "not native here")
    /// reads. Nil = not in the registry at all.
    public func audience(ofToolNamed name: String) -> RipulToolAudience? {
        let canonical = RipulToolCollectionMatcher.canonicalName(name)
        return allEntries.first {
            RipulToolCollectionMatcher.canonicalName($0.tool.name) == canonical
        }?.audience
    }

    /// The host-owned surfaces as editor catalogs — the registry's projection
    /// for the collections editor's picker. The developer surface is appended
    /// by the console from its own channel (`.developer(bridge.registeredToolSummaries)`),
    /// because channel-bound tools live on the channel, not here.
    public func editorCatalogs() -> [RipulToolCatalog] {
        var catalogs: [RipulToolCatalog] = []
        let endUserTools = tools(audience: .endUser)
        if !endUserTools.isEmpty {
            catalogs.append(.endUser(endUserTools))
        }
        for entry in allEntries {
            if case let .named(id, purpose) = entry.audience,
               !catalogs.contains(where: { $0.id == id }) {
                catalogs.append(RipulToolCatalog(
                    id: id,
                    name: id,
                    purpose: purpose,
                    nativeTools: tools(audience: entry.audience)
                ))
            }
        }
        return catalogs
    }

    // MARK: - Change observation (SDK-internal)

    internal func addObserver(_ id: UUID, _ handler: @escaping () -> Void) {
        observers[id] = handler
    }

    internal func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyChanged() {
        for handler in observers.values { handler() }
    }
}
