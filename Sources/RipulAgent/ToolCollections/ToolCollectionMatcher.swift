import Foundation

// ---------------------------------------------------------------------------
// A Swift mirror of the web app's `CategoryToolMatcher`
// (chrome-extension/src/LLM/Tools/CategoryToolMatcher.ts).
//
// This is the one place the SDK duplicates matching logic that the web app
// actually runs at request time. It exists so the editor can show a developer
// which tools a rule captures BEFORE they save.
//
// DRIFT NOW CARRIES ENFORCEMENT WEIGHT: since native-tool-registry phase 4, a
// solution context may include a collection by reference (`group://<name>` in
// `includedTools`), so membership determines tool AVAILABILITY, not just the
// editor preview. Parity is pinned by a shared fixture in
// `ToolCollectionMatcherParityTests.swift` and the web side's
// `packages/api/src/toolCollections/__tests__/matcherParity.test.ts` — change
// matching semantics on either side only together with both tests.
// (Enforcement expansion itself resolves `explicitTools` only — a regex has no
// finite expansion into a name whitelist; see
// `packages/api/src/toolCollections/groupRefs.ts`.)
//
// The rules, in full:
//   • A tool joins if its name is in `explicitTools` OR matches any
//     `toolPatterns` regex. Membership is a union, never first-match-wins.
//   • Patterns are unanchored (JS `RegExp.test`), so `calendar_` matches
//     anywhere in the name; write `^calendar_` to anchor.
//   • An uncompilable pattern is skipped, not fatal.
//   • Names are compared CANONICALLY — see `canonicalName`.
//
// A collection's membership is NOT the same as what this build registers. The
// account's collections span web app tools, other devices' tools, and this
// app's native tools; a collection can be fully populated and still match
// nothing here. The two counts are reported separately so a well-formed
// collection is never displayed as empty.
// ---------------------------------------------------------------------------

public struct RipulToolCollectionMatcher {
    /// Curated picks that ARE registered in this build (bridge names).
    public let explicitMatches: [String]
    /// Registered tools captured by a pattern rather than a pick.
    public let patternMatches: [String]
    /// Curated picks NOT registered in this build, as stored. These are
    /// ordinary — a web app tool, another device's tool — not errors.
    public let absentMembers: [String]
    /// Patterns that failed to compile, with the reason.
    public let invalidPatterns: [(pattern: String, reason: String)]

    /// Members present in this build, explicit first.
    public var presentMatches: [String] { explicitMatches + patternMatches }
    public var presentCount: Int { presentMatches.count }
    /// Everything the collection curates, whether registered here or not.
    public var memberCount: Int { presentCount + absentMembers.count }

    /// Reduce a tool name to the form membership is compared in.
    ///
    /// Two transformations, both mirroring the web interceptor:
    ///  1. Strip a leading authority (`example.com/get_events` → `get_events`),
    ///     which server-side expansion of `discovered://` URIs can introduce.
    ///     Entries containing `://` are full URIs and pass through untouched.
    ///  2. Strip a transport prefix. `host_` and `device_` are added by the
    ///     layer that relays a tool to the agent — the Mac host and the phone
    ///     peer respectively — and are NOT part of the name the app registered.
    ///     A category curated against a CLI session stores `device_console_logs`
    ///     for what this bridge calls `console_logs`.
    public static func canonicalName(_ raw: String) -> String {
        var name = raw
        if !name.contains("://"), let slash = name.firstIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        for prefix in ["host_", "device_", "web_tool_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name
    }

    /// Match `toolNames` (as registered with `AgentBridge`) against one
    /// collection's membership rules.
    public init(
        explicitTools: [String],
        toolPatterns: [String],
        toolNames: [String]
    ) {
        // Dedupe, mirroring the TS matcher — repeated names have leaked a
        // duplicate CategoryTool into persisted state before now.
        var seen = Set<String>()
        let uniqueNames = toolNames.filter { seen.insert($0).inserted }

        // canonical → the name this build actually registered, so results are
        // reported in terms the developer recognises.
        var byCanonical: [String: String] = [:]
        for name in uniqueNames {
            byCanonical[Self.canonicalName(name)] = name
        }

        var compiled: [NSRegularExpression] = []
        var invalid: [(pattern: String, reason: String)] = []
        for pattern in toolPatterns {
            do {
                compiled.append(try NSRegularExpression(pattern: pattern))
            } catch {
                invalid.append((pattern, error.localizedDescription))
            }
        }

        // Explicit picks, split by whether this build has them.
        var explicitHits: [String] = []
        var absent: [String] = []
        var claimed = Set<String>()
        for entry in explicitTools {
            // `group://` entries are references resolved server-side, not tool
            // names — neither present nor missing here.
            guard !entry.hasPrefix("group://") else { continue }
            if let registered = byCanonical[Self.canonicalName(entry)] {
                if claimed.insert(registered).inserted {
                    explicitHits.append(registered)
                }
            } else {
                absent.append(entry)
            }
        }

        // Patterns apply only to what this build registers, and are tested
        // against the canonical name for the same reason the web does.
        var patternHits: [String] = []
        for name in uniqueNames where !claimed.contains(name) {
            if compiled.contains(where: { $0.matches(Self.canonicalName(name)) }) {
                patternHits.append(name)
                claimed.insert(name)
            }
        }

        self.explicitMatches = explicitHits
        self.patternMatches = patternHits
        self.absentMembers = absent
        self.invalidPatterns = invalid
    }
}

extension NSRegularExpression {
    /// JS `RegExp.test` semantics: does the pattern match anywhere in `value`?
    func matches(_ value: String) -> Bool {
        firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

/// Validate a pattern the way the API will, so the editor can reject it inline
/// instead of round-tripping to a 400.
public enum RipulToolPatternValidator {
    /// Nil when the pattern compiles, otherwise the reason it doesn't.
    public static func reasonInvalid(_ pattern: String) -> String? {
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
