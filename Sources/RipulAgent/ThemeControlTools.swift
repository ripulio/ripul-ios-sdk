#if os(iOS)
import Foundation

// DEV tools that let an agent DRIVE the host app's theme, not just read it.
//
// Lifted from WAC's `DevThemeControlTools.swift` into the SDK: the tools are
// now engine-driven (`RipulThemeEngine` owns scopes, assignments, overrides,
// resolution, and the mutation write path), so ANY host that registers a
// `RipulThemeSpec` gets theme-driving tools for free. Tool names and response
// shapes are unchanged from the WAC originals.
//
// Deliberately GENERAL rather than one tool per knob: `set_theme_knob` writes
// any knob on any registered scope by name. Registering a knob in a kind's
// `RipulStyleKind.knobs` schema makes it settable here for free.
//
// Gated by the host via `RipulDevThemeTools.all(isEnabled:)` — development
// affordances, never in a normal user's tool list.

private func ripulKnob(from value: Any) -> RipulKnob? {
    if let b = value as? Bool { return .bool(b) }
    if let n = value as? Double { return .number(n) }
    if let i = value as? Int { return .number(Double(i)) }
    if let s = value as? String { return .string(s) }
    return nil
}

// MARK: - list_theme_scopes

/// Discovery: which scopes exist and what is currently overridden on each.
public struct RipulListThemeScopesTool: NativeTool {
    public var name: String { "list_theme_scopes" }
    public var description: String {
        "List the theme scopes that can be styled live (disclosure panels and field capsules), "
        + "with their View-Explorer id, label, assigned named style, and whether they carry "
        + "per-scope overrides. Ids match those returned by inspect_screen."
    }
    public var inputSchema: [String: Any] { ["type": "object", "properties": [:], "required": []] }

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    public func execute(args: [String: Any]) async throws -> Any {
        await MainActor.run {
            let doc = RipulThemeEngine.current
            let scopes = RipulThemeEngine.styleKinds.flatMap { kind in
                kind.scopes.map { scope -> [String: Any] in
                    ["id": scope.id, "label": scope.label, "kind": kind.name,
                     "style": doc.styleAssignments[kind.name]?[scope.id] ?? "(default)",
                     "hasOverrides": doc.styleOverrides[kind.name]?[scope.id] != nil]
                }
            }
            return ["scopes": scopes]
        }
    }
}

// MARK: - get_theme_style

/// The RESOLVED values a scope is currently rendering with, plus its raw overrides —
/// so an agent can read a value before changing it, rather than guessing the baseline.
public struct RipulGetThemeStyleTool: NativeTool {
    public var name: String { "get_theme_style" }
    public var description: String {
        "Read a theme scope's currently RESOLVED knob values (what it renders with right now) "
        + "and the per-scope overrides applied on top. Use list_theme_scopes for valid ids."
    }
    public var inputSchema: [String: Any] {
        ["type": "object",
         "required": ["scope"],
         "properties": ["scope": ["type": "string",
                                  "description": "Scope id, e.g. addShift.receipt.panel"]]]
    }

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    public func execute(args: [String: Any]) async throws -> Any {
        guard let id = args["scope"] as? String else {
            throw NSError(domain: "theme", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "scope is required"])
        }
        return try await MainActor.run {
            guard let kind = RipulThemeEngine.kind(containingScope: id) else {
                throw NSError(domain: "theme", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Unknown scope '\(id)'. Call list_theme_scopes for valid ids."])
            }
            let overrides = RipulThemeEngine.current.styleOverrides[kind.name]?[id] ?? [:]
            let resolved = RipulThemeEngine.resolved(kind: kind.name, element: id)
            var payload: [String: Any] = ["scope": id, "kind": kind.name,
                                          "overrides": overrides.mapValues { $0.jsonValue },
                                          "resolved": resolved.knobs.mapValues { $0.jsonValue }]
            // Composite kinds: each part's own resolution, addressable as "<scope>.<part>"
            // (those child ids are themselves scopes — set_theme_knob works on them).
            if !resolved.slots.isEmpty {
                payload["slots"] = resolved.slots.mapValues { part in
                    ["resolved": part.knobs.mapValues { $0.jsonValue }]
                }
            }
            return payload
        }
    }
}

// MARK: - set_theme_knob

/// The write. One tool for every knob on every scope — see the file header for why this
/// is deliberately not a per-knob tool.
public struct RipulSetThemeKnobTool: NativeTool {
    public var name: String { "set_theme_knob" }
    public var description: String {
        "Set a single theme knob on a scope, applied LIVE with no rebuild "
        + "(e.g. scope 'addShift.receipt.panel', knob 'legendClearance', value 3). "
        + "Writes a per-scope override, which beats any assigned named style. "
        + "Knob names are declared by each scope's kind — read them from get_theme_style's "
        + "resolved output. Use reset_theme_scope to undo."
    }
    public var inputSchema: [String: Any] {
        ["type": "object",
         "required": ["scope", "knob", "value"],
         "properties": [
            "scope": ["type": "string", "description": "Scope id, e.g. addShift.receipt.panel"],
            "knob": ["type": "string", "description": "Knob name, e.g. legendClearance"],
            "value": ["type": ["string", "number", "boolean"],
                      "description": "New value for the knob"]]]
    }

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    public func execute(args: [String: Any]) async throws -> Any {
        guard let id = args["scope"] as? String, let knobName = args["knob"] as? String,
              let raw = args["value"] else {
            throw NSError(domain: "theme", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "scope, knob and value are required"])
        }
        // Numbers often arrive as strings over JSON; coerce so "3" and 3 both work.
        let coerced: Any = (raw as? String).flatMap { Double($0) } ?? raw
        guard let value = ripulKnob(from: coerced) else {
            throw NSError(domain: "theme", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "value must be a number, string or boolean"])
        }
        return try await MainActor.run {
            guard let kind = RipulThemeEngine.kind(containingScope: id) else {
                throw NSError(domain: "theme", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Unknown scope '\(id)'. Call list_theme_scopes for valid ids."])
            }
            try RipulThemeEngine.setOverride(element: id, knob: knobName, value: value)
            return ["ok": true, "scope": id, "kind": kind.name,
                    "knob": knobName, "value": value.jsonValue,
                    "note": "Applied live. Persisted as a per-scope override."]
        }
    }
}

// MARK: - reset_theme_scope

public struct RipulResetThemeScopeTool: NativeTool {
    public var name: String { "reset_theme_scope" }
    public var description: String {
        "Clear every per-scope override on a theme scope, returning it to its assigned "
        + "named style (or the built-in default). Applied live."
    }
    public var inputSchema: [String: Any] {
        ["type": "object",
         "required": ["scope"],
         "properties": ["scope": ["type": "string",
                                  "description": "Scope id, e.g. addShift.receipt.panel"]]]
    }

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    public func execute(args: [String: Any]) async throws -> Any {
        guard let id = args["scope"] as? String else {
            throw NSError(domain: "theme", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "scope is required"])
        }
        return try await MainActor.run {
            try RipulThemeEngine.clearOverrides(element: id)
            return ["ok": true, "scope": id, "note": "Overrides cleared, applied live."]
        }
    }
}

// MARK: - get_app_diagnostics

/// Which binary is running, plus host-provided extras (e.g. WAC's dog tags).
///
/// Exists because a build number is not discoverable from outside the app: version is the
/// same on every OTA build, and the only discriminator available during one debugging
/// session was the ABSENCE of a log line. Several fixes were written against a stale
/// binary as a result.
public struct RipulGetAppDiagnosticsTool: NativeTool {
    public var name: String { "get_app_diagnostics" }
    public var description: String {
        "Report the RUNNING build: bundle id, version, build number, plus host extras. "
        + "Call this first when a fix appears not to have worked — it distinguishes "
        + "'stale binary' from 'the fix is wrong'."
    }
    public var inputSchema: [String: Any] { ["type": "object", "properties": [:], "required": []] }

    /// SDK-internal — see `RipulDeveloperOnlyTool`.
    init() {}

    public func execute(args: [String: Any]) async throws -> Any {
        await MainActor.run {
            let info = Bundle.main.infoDictionary ?? [:]
            var out: [String: Any] = [
                "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
                "version": info["CFBundleShortVersionString"] as? String ?? "unknown",
                "build": info["CFBundleVersion"] as? String ?? "unknown",
            ]
            for (k, v) in RipulDevThemeTools.diagnosticsExtras?() ?? [:] { out[k] = v }
            return out
        }
    }
}

// MARK: - Registry

public enum RipulDevThemeTools {
    /// Optional host extras merged into `get_app_diagnostics` (e.g. WAC's DogTags).
    public static var diagnosticsExtras: (() -> [String: Any])?

    /// Development affordances — the host decides when they're offered (e.g. only
    /// when its debug-tools flag is on). Returns [] when `isEnabled()` is false.
    public static func all(isEnabled: () -> Bool) -> [NativeTool] {
        guard isEnabled() else { return [] }
        return [
            RipulListThemeScopesTool(),
            RipulGetThemeStyleTool(),
            RipulSetThemeKnobTool(),
            RipulResetThemeScopeTool(),
            RipulGetAppDiagnosticsTool(),
        ]
    }
}
#endif
