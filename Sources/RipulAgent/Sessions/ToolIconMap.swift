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
        "KillBash": "xmark.octagon",

        // Plans / todos
        "TodoWrite": "checklist",
        "TodoRead": "checklist",
        "ExitPlanMode": "list.bullet.clipboard",
        "EnterPlanMode": "list.bullet.clipboard",

        // Agents / skills / MCP
        "Agent": "sparkles",
        "Skill": "wand.and.stars",
        "Task": "sparkles",

        // Web
        "WebFetch": "globe",
        "WebSearch": "safari",

        // Questions / interaction (keyed bare; MCP-served forms reach these
        // entries via the prefix strip in symbol(for:))
        "AskUserQuestion": "questionmark.bubble",
        "ask_user": "questionmark.bubble",

        // Misc / lifecycle
        "completion": "checkmark.circle",

        // Repo tools (host-run file/command access)
        "repoReadFile": "eye",
        "repoGrep": "magnifyingglass",
        "repoListDirectory": "folder",
        "repoGlob": "doc.text.magnifyingglass",
        "repoWriteFile": "square.and.pencil",
        "repoEditFile": "pencil.line",
        "repoRunCommand": "terminal",
        "repoJobOutput": "doc.plaintext",
        "repoJobStop": "stop.circle",
        "repoJobList": "list.bullet",

        // CMS grid tools
        "list_grids": "square.grid.3x3",
        "set_grid_filter": "line.3.horizontal.decrease.circle",
        "clear_grid_filters": "line.3.horizontal.decrease.circle.fill",
        "group_grid": "rectangle.3.group",
        "clear_grid_grouping": "rectangle.3.group.fill",
        "read_grid_rows": "tablecells",
        "count_grid_rows": "sum",
        "highlight_grid": "highlighter",
        "clear_grid_highlights": "pencil.slash",

        // CMS block tools
        "create_block": "plus.square",
        "get_block": "square.stack.3d.up",
        "update_block": "square.and.pencil",
        "delete_block": "trash",
        "describe_block_type": "info.circle",
        "list_page_blocks": "list.bullet.rectangle",

        // CMS page tools
        "list_pages": "doc.on.doc",
        "create_page": "doc.badge.plus",
        "update_page": "pencil",
        "delete_page": "trash.fill",

        // CMS query/data tools
        "list_queries": "list.bullet",
        "create_query": "plus.circle",
        "update_query": "pencil",
        "delete_query": "trash",
        "dry_run_query": "testtube.2",
        "preview_data": "tablecells.badge.ellipsis",
        "list_mutations": "list.bullet",
        "create_mutation": "arrow.triangle.2.circlepath",
        "update_mutation": "arrow.triangle.2.circlepath",
        "delete_mutation": "trash",

        // CMS table/admin tools
        "list_cms_tables": "cabinet",
        "list_tables": "cabinet",
        "describe_table": "info.circle",
        "create_cms_table": "plus.rectangle",
        "update_cms_table": "pencil",
        "set_table_relationship": "link",
        "set_table_rls": "lock.shield",
        "list_connections": "cable.connector",
        "list_datasets": "cylinder",
        "resolve_datetime": "calendar.badge.clock",

        // CLI stream tools not covered above
        "LS": "folder",
        "SlashCommand": "command",

        // Ask-user interaction variants
        "askUserChoice": "checkmark.circle.badge.questionmark",
        "askUserMultiChoice": "checklist.checked",
        "askUserText": "textformat",
        "askUserDateTime": "calendar",
        "notifyUser": "bell.badge",

        // Theme learning
        "saveLearnedTheme": "paintpalette",
        "listLearnedThemes": "paintbrush.pointed",
        "getLearnedTheme": "eyedropper",
        "deleteLearnedTheme": "paintpalette.fill",
        "themeLearnFromPage": "paintpalette",

        // Website docs & page structure
        "findDocs": "doc.text.magnifyingglass",
        "saveWebsiteDocs": "bookmark",
        "getWebsiteDocs": "book",
        "grepWebsiteDocs": "magnifyingglass",
        "searchPageStructures": "map",
        "getPageStructure": "square.3.layers.3d",
        "navigationBuildSitemap": "map",
        "documentationBuildDocs": "book",

        // Orchestration & sub-agents
        "parallelAgents": "arrow.triangle.branch",
        "sequentialChain": "link",
        "parallelSequentialComparison": "arrow.left.arrow.right",
        "agentDiscovery": "person.crop.circle.badge.magnifyingglass",
        "runAgent": "sparkles",
        "composeTools": "puzzlepiece.extension",
        "subagentExecute": "person.2",
        "orchestratorBegin": "paperplane",
        "initStart": "play",

        // Admin / management
        "manageToolCollection": "square.grid.2x2",
        "previewCategorization": "square.3.layers.3d.down.right",
        "organiseTools": "square.stack.3d.up",
        "listDiscoveredTools": "puzzlepiece.extension",
        "listModels": "list.bullet.rectangle",
        "manageSiteKey": "key",
        "manageViewContext": "macwindow",
        "manageSolutionContext": "square.3.layers.3d",
        "manageRider": "person",
        "manageRiders": "person.2",
        "onboardCustomer": "person.badge.plus",

        // Debug, meta & misc web tools
        "debugToolsMetaCommand": "ladybug",
        "debugEnvMetaCommand": "ladybug",
        "debugSolutionMetaCommand": "ladybug",
        "debugDebugEnv": "ladybug",
        "inject_api_watcher": "arrow.left.arrow.right",
        "resolveSelector": "location",
        "analyzePageTool": "chart.bar.doc.horizontal",
        "createRegex": "textformat.abc.dottedunderline",
        "testPickIndustry": "testtube.2",
        "testPickJob": "testtube.2",
        "builtinHelp": "questionmark.circle",
        "compactConversation": "arrow.up.and.down.text.horizontal",
        "clearContext": "trash.slash",
        "updateDeployedTool": "icloud.and.arrow.up",
        "toolsDeployTools": "paperplane",
        "toolsRefineTools": "wand.and.stars",
        "webAnalysisCreateToolsFromInteraction": "hand.tap",
        "webAnalysisSummarizePageStructure": "doc.text",
        "animateMouse": "cursorarrow.motionlines",

        // Host machine tools (served as mcp__ripul_tools__host_*; keyed bare so
        // the prefix strip in symbol(for:) reaches them)
        "host_console_logs": "terminal",
        "host_network_logs": "arrow.left.arrow.right",
        "host_deploy_pages": "paperplane",
        "host_dock_action": "dock.rectangle",
        "host_dock_list": "dock.rectangle",
        "host_create_script": "doc.badge.plus",
        "host_amend_script": "pencil.line",
        "host_read_script": "doc.text",
        "host_list_scripts": "list.bullet.rectangle",
        "host_search_scripts": "magnifyingglass",
        "host_forget_chat": "trash",
        "host_get_host_status": "heart.text.square",
        "host_get_host_diagnostics": "stethoscope",
        "host_get_host_settings": "gearshape",
        "host_get_host_preferences": "slider.horizontal.3",
        "host_set_host_enabled": "power",
        "host_set_host_setting": "gearshape",
        "host_set_machine_name": "tag",
        "host_set_native_console_logging": "terminal",
        "host_session_size_check": "externaldrive",
        "git_commit": "point.topleft.down.to.point.bottomright.curvepath",
        "resume_from_commit": "clock.arrow.circlepath",
        "consult_agent": "bubble.left.and.bubble.right",

        // Device tools (iPhone inspection + voice)
        "iphone_inspect": "iphone",
        "device_console_logs": "ladybug",
        "device_network_logs": "arrow.left.arrow.right",
        "device_query_elements": "magnifyingglass",
        "device_page_info": "doc.text",
        "device_evaluate": "testtube.2",
        "host_speak": "person.wave.2",
        "device_speak": "person.wave.2",

        // MCP-served web tools common in CLI sessions (bare forms of
        // mcp__ripul_tools__* — reached via the prefix strip)
        "runCode": "chevron.left.forwardslash.chevron.right",
        "generateCode": "chevron.left.forwardslash.chevron.right",
        "executeCode": "chevron.left.forwardslash.chevron.right",
        "httpRequest": "network",
        "waitForCommand": "keyboard",
        "interactWithUser": "person",
        "apiMonitor": "arrow.left.arrow.right",
        "helpTool": "questionmark.circle",
        "promptDiscoveryTool": "questionmark.bubble",
    ]

    /// Returns the SF Symbol name for a tool, or `fallback` if unmapped.
    static func symbol(for toolName: String?) -> String {
        guard let name = toolName, !name.isEmpty else { return fallback }
        // MCP-served tools arrive prefixed (`mcp__ripul_tools__host_speak`).
        // Match on the bare tool name so a served tool inherits the same icon
        // as a direct call — server names contain no `__`, so the second `__`
        // ends the prefix. Mirrors the strip in the web ToolIconRegistry.
        var bare = name
        if bare.hasPrefix("mcp__"),
           let range = bare.range(of: "__", range: bare.index(bare.startIndex, offsetBy: 5)..<bare.endIndex) {
            bare = String(bare[range.upperBound...])
        }
        return symbols[bare] ?? fallback
    }
}
