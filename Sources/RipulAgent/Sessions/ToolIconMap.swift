import Foundation

/// Maps agent tool names to SF Symbol icons for native-side rendering
/// (session-list subtitles, Dynamic Island, etc.).
///
/// Mirrors `chrome-extension/src/logging/panels/components/ToolIconRegistry.tsx`
/// — keep in sync when adding or changing a tool icon on the web side. React
/// icons use MUI material icons; this table picks the closest SF Symbol.
enum ToolIconMap {
    /// Fallback icon shown when a tool name isn't in the table. Matches the
    /// previous generic wrench-and-screwdriver glyph so unknown tools still
    /// render something meaningful.
    static let fallback = "wrench.and.screwdriver"

    private static let symbols: [String: String] = [
        // File operations
        "Read": "eye",
        "Write": "square.and.pencil",
        "Edit": "pencil",
        "MultiEdit": "pencil.line",
        "NotebookEdit": "pencil",

        // Search
        "Glob": "doc.text.magnifyingglass",
        "Grep": "magnifyingglass",

        // Shell / scripts
        "Bash": "terminal",
        "BashOutput": "terminal",
        "KillShell": "xmark.octagon",

        // Plans / todos
        "TodoWrite": "checklist",
        "ExitPlanMode": "list.bullet.clipboard",
        "EnterPlanMode": "list.bullet.clipboard",

        // Agents / skills / MCP
        "Agent": "sparkles",
        "Skill": "wand.and.stars",
        "Task": "sparkles",

        // Web
        "WebFetch": "globe",
        "WebSearch": "safari",

        // Questions / interaction
        "AskUserQuestion": "questionmark.bubble",
        "mcp__ripul_permissions__ask_user": "questionmark.bubble",

        // Misc / lifecycle
        "completion": "checkmark.circle",
    ]

    /// Returns the SF Symbol name for a tool, or `fallback` if unmapped.
    static func symbol(for toolName: String?) -> String {
        guard let name = toolName, !name.isEmpty else { return fallback }
        return symbols[name] ?? fallback
    }
}
