import Foundation

// ---------------------------------------------------------------------------
// A Swift mirror of the web app's `CategoryToolMatcher`
// (chrome-extension/src/LLM/Tools/CategoryToolMatcher.ts).
//
// This is the one place the SDK duplicates matching logic that the web app
// actually runs at request time. It exists so the editor can show a developer
// which tools a pattern captures BEFORE they save — the whole point of
// authoring on-device, where the live tool set is known.
//
// Because it is a mirror, it must not drift. The rules, in full:
//   • A tool joins if its name is in `explicitTools` OR matches any
//     `toolPatterns` regex. Membership is a union, never first-match-wins.
//   • Patterns are unanchored (JS `RegExp.test`), so `calendar_` matches
//     anywhere in the name; write `^calendar_` to anchor.
//   • An uncompilable pattern is skipped, not fatal.
//   • Names are canonical — the interceptor strips `host_` / `web_tool_`
//     before matching, and `AgentBridge` holds them unprefixed already.
// ---------------------------------------------------------------------------

public struct RipulToolCollectionMatcher {
    /// Tools captured by `explicitTools`, in registration order.
    public let explicitMatches: [String]
    /// Tools captured only by a pattern — i.e. what the pattern earns you
    /// over hand-picking. Shown separately so the split is visible.
    public let patternMatches: [String]
    /// Patterns that failed to compile, with the reason.
    public let invalidPatterns: [(pattern: String, reason: String)]

    /// Every matched tool, deduplicated, explicit first.
    public var allMatches: [String] { explicitMatches + patternMatches }
    public var matchCount: Int { allMatches.count }

    /// Match `toolNames` against one collection's membership rules.
    public init(
        explicitTools: [String],
        toolPatterns: [String],
        toolNames: [String]
    ) {
        // Dedupe, mirroring the TS matcher — repeated names have leaked a
        // duplicate CategoryTool into persisted state before now.
        var seen = Set<String>()
        let unique = toolNames.filter { seen.insert($0).inserted }

        // `group://` entries are references resolved server-side, not tool
        // names; they can never match a locally registered tool.
        let explicitSet = Set(explicitTools.filter { !$0.hasPrefix("group://") })

        var compiled: [NSRegularExpression] = []
        var invalid: [(pattern: String, reason: String)] = []
        for pattern in toolPatterns {
            do {
                compiled.append(try NSRegularExpression(pattern: pattern))
            } catch {
                invalid.append((pattern, error.localizedDescription))
            }
        }

        var explicitHits: [String] = []
        var patternHits: [String] = []
        for name in unique {
            if explicitSet.contains(name) {
                explicitHits.append(name)
            } else if compiled.contains(where: { $0.matches(name) }) {
                patternHits.append(name)
            }
        }

        self.explicitMatches = explicitHits
        self.patternMatches = patternHits
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
