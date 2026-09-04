import SwiftUI

// MARK: - Model Identity

/// Model identity — display label, colour and glyph keyed off the MODEL that
/// produced a turn, not the provider/harness that carried it.
///
/// Port of the web app's `chrome-extension/src/LLM/multiParticipant/modelIdentity.ts`
/// — keep the two in sync (the parity test pins the shared cases). The
/// session row's leading icon resolves from this table, so a Kimi-via-env-swap
/// session inside the Claude Code harness shows ☾ teal "Kimi K3", not the
/// harness's Claude identity. The web side additionally tracks context-window
/// sizes for its chat-stream gauge; that data isn't needed natively and is
/// intentionally omitted here.
///
/// There are no official per-model icons from Anthropic (the ✦ starburst is
/// the Claude *brand* mark; tiers have no individual glyphs), so each family
/// gets a distinct unicode glyph in the same text-glyph style the web
/// lozenges use — the glyph seen here matches the chat-stream respondent
/// lozenges for the same model.
public struct ModelIdentity: Equatable {
    /// Display label — just the model ("Kimi K3", "Opus 4.8"), never the CLI name.
    public let label: String
    /// Hex colour (e.g. "#14B8A6"), mirroring the web table.
    public let colorHex: String
    /// Unicode glyph rendered in place of an SF Symbol (e.g. "☾", "✦", "❀").
    public let glyph: String

    public var color: Color { Color(hex: colorHex) }

    // MARK: Family table

    private struct Family {
        /// Tokens that signal this family (any one match, tested in table order).
        let match: [String]
        /// Base display label.
        let label: String
        let colorHex: String
        let glyph: String
        /// Optional full-label override derived from the complete token list
        /// (families whose tiers are named, not versioned — e.g. Kimi).
        let tierLabel: (([String]) -> String)?
    }

    /// Family table — order matters: the first family whose token appears in
    /// the id wins (so `claude-cli-raw-kimi-k3` resolves Kimi even though it
    /// carries the `claude-cli-raw-` harness prefix). Mirrors MODEL_FAMILIES
    /// in modelIdentity.ts.
    private static let families: [Family] = [
        Family(match: ["kimi", "k3"], label: "Kimi", colorHex: "#14B8A6", glyph: "☾", tierLabel: { tokens in
            if tokens.contains("k3") { return "Kimi K3" }
            if tokens.contains("highspeed") { return "Kimi HighSpeed" }
            if tokens.contains("coding") { return "Kimi for Coding" }
            return "Kimi"
        }),
        Family(match: ["opus"], label: "Opus", colorHex: "#D97706", glyph: "✦", tierLabel: nil),
        Family(match: ["sonnet"], label: "Sonnet", colorHex: "#0EA5E9", glyph: "✧", tierLabel: nil),
        Family(match: ["haiku"], label: "Haiku", colorHex: "#22C55E", glyph: "❀", tierLabel: nil),
        Family(match: ["fable"], label: "Fable", colorHex: "#C026D3", glyph: "✎", tierLabel: nil),
        Family(match: ["gpt"], label: "GPT", colorHex: "#10A37F", glyph: "◈", tierLabel: nil),
        Family(match: ["codex"], label: "Codex", colorHex: "#10A37F", glyph: "◈", tierLabel: nil),
        Family(match: ["o4"], label: "o4", colorHex: "#10A37F", glyph: "◈", tierLabel: nil),
        Family(match: ["o3"], label: "o3", colorHex: "#10A37F", glyph: "◈", tierLabel: nil),
        Family(match: ["o1"], label: "o1", colorHex: "#10A37F", glyph: "◈", tierLabel: nil),
        Family(match: ["gemini"], label: "Gemini", colorHex: "#4285F4", glyph: "✦", tierLabel: nil),
        Family(match: ["grok"], label: "Grok", colorHex: "#6B7280", glyph: "◇", tierLabel: nil),
        Family(match: ["llama"], label: "Llama", colorHex: "#6B7280", glyph: "◇", tierLabel: nil),
        Family(match: ["mistral"], label: "Mistral", colorHex: "#6B7280", glyph: "◇", tierLabel: nil),
        Family(match: ["qwen"], label: "Qwen", colorHex: "#6B7280", glyph: "◇", tierLabel: nil),
        Family(match: ["deepseek"], label: "DeepSeek", colorHex: "#6B7280", glyph: "◇", tierLabel: nil),
    ]

    /// Tokens between the family match and the meaningful tail that carry no
    /// identity (harness/routing vocabulary). Mirrors SUFFIX_STOPWORDS.
    private static let suffixStopwords: Set<String> = ["for", "the", "code", "cli", "raw", "latest", "preview"]

    /// Split a model id into lowercase tokens, treating brackets/dots as
    /// separators (`k3[1m]` → `k3`,`1m`). Mirrors tokenize() in modelIdentity.ts.
    private static let tokenSeparators: CharacterSet = {
        var set = CharacterSet(charactersIn: "-_.[]()/")
        set.formUnion(.whitespacesAndNewlines)
        return set
    }()

    private static func tokenize(_ modelId: String) -> [String] {
        modelId.lowercased()
            .components(separatedBy: tokenSeparators)
            .filter { !$0.isEmpty }
    }

    /// Resolve the display identity for a concrete or catalog model id.
    /// Returns nil when no known family is present — callers should fall back
    /// to the provider persona in that case.
    ///
    /// Label construction: family base label + optional version
    /// (`claude-opus-4-8` → "Opus 4.8", date stamps like `-20251001` filtered
    /// out) + optional tier word (`gemini-2.5-pro` → "Gemini 2.5 Pro"). Kimi
    /// tiers are named, not versioned, and short-circuit via `tierLabel`.
    public static func resolve(modelId: String?) -> ModelIdentity? {
        guard let modelId, !modelId.isEmpty else { return nil }
        let tokens = tokenize(modelId)
        guard !tokens.isEmpty else { return nil }

        for fam in families {
            guard let famIdx = tokens.firstIndex(where: { fam.match.contains($0) }) else { continue }

            if let tierLabel = fam.tierLabel {
                return ModelIdentity(label: tierLabel(tokens), colorHex: fam.colorHex, glyph: fam.glyph)
            }

            // Version: up to two purely-numeric tokens after the family token,
            // skipping date stamps (8-digit groups like 20251001).
            let after = Array(tokens.dropFirst(famIdx + 1))
            var versionParts: [String] = []
            for t in after {
                if !t.allSatisfy(\.isNumber) { break }
                if t.count >= 6 { break }
                versionParts.append(t)
                if versionParts.count == 2 { break }
            }
            // Tier words: alphabetic tokens after the version run (e.g. "pro", "flash", "mini").
            let tierWords = after.dropFirst(versionParts.count)
                .filter { $0.allSatisfy(\.isLetter) && !suffixStopwords.contains($0) }
                .prefix(2)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }

            let parts: [String?] = [fam.label, versionParts.isEmpty ? nil : versionParts.joined(separator: ".")]
                + tierWords.map { $0 as String? }
            let label = parts.compactMap { $0 }.joined(separator: " ")
            return ModelIdentity(label: label, colorHex: fam.colorHex, glyph: fam.glyph)
        }

        return nil
    }
}
