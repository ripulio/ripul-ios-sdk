import Foundation

/// Substitutes `{{name}}` tokens in a recorded `.type` step's text with the
/// agent-supplied parameter values (phase 1's `MacroTool.execute`), and finds
/// the distinct token names present in a step's text (phase 2's recording UI,
/// to auto-populate `RipulMacro.parameters` from what the developer typed).
/// Pure string logic — no UIKit — so it's testable everywhere.
public enum MacroParameterSubstitution {
    private static let tokenPattern = try! NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_]+)\\s*\\}\\}")

    /// Replaces every `{{name}}` with `parameters[name]`. A token with no
    /// matching parameter is left LITERAL — not stripped, not an error — so a
    /// malformed macro fails loudly later, at the point of use (the literal
    /// `{{typo}}` ends up typed into a field, visibly wrong), rather than
    /// silently at substitution time.
    public static func apply(_ text: String, parameters: [String: String]) -> String {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = tokenPattern.matches(in: text, range: full)
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text) else { continue }
            result += text[cursor..<matchRange.lowerBound]
            let name = String(text[nameRange])
            result += parameters[name] ?? String(text[matchRange])
            cursor = matchRange.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Distinct `{{name}}` token names in `text`, in order of first appearance.
    public static func tokenNames(in text: String) -> [String] {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        var ordered: [String] = []
        for match in tokenPattern.matches(in: text, range: full) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            if seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }

    /// Distinct `{{name}}` tokens across every `.type` step's text, in order of
    /// first appearance across the WHOLE macro (not just within one step) —
    /// what the phase-2 recording UI's save sheet uses to auto-populate
    /// `RipulMacro.parameters` without a separate "add a parameter" step.
    public static func detectParameters(in steps: [MacroStep]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for step in steps where step.kind == .type {
            for name in tokenNames(in: step.text ?? "") where seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }
}
