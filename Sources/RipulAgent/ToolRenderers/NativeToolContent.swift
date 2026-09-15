import Foundation

/// The native counterpart of the web field/result renderer registries. The
/// bridge supplies the web normalizer's canonical name; aliases here also cover
/// CLI-native tools that intentionally keep their own names in the web stream.
enum NativeToolRendererKind: String {
    case terminal, read, write, edit, patch, grep, glob, logs, evaluate, todos, web, agent, http, tools, host, image, fields

    static func resolve(_ toolName: String) -> Self {
        let name = toolName.replacingOccurrences(of: "^mcp__ripul_tools_+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^functions[._]+", with: "", options: .regularExpression)
            .components(separatedBy: ":")[0].lowercased()
        switch name {
        case "bash", "exec_command", "shell_command", "shell", "run_command", "host_run_command", "write_stdin": return .terminal
        case "read", "read_file", "view_file": return .read
        case "write", "write_file", "write_to_file": return .write
        case "edit", "multiedit", "replace_file_content", "multi_replace_file_content": return .edit
        case "apply_patch": return .patch
        case "grep", "grep_search", "searchfiles": return .grep
        case "glob", "list_dir", "list_directory": return .glob
        case "host_console_logs", "device_console_logs", "searchconsolelogs": return .logs
        case "device_evaluate", "browser_run_js", "executecode", "runcode", "exec": return .evaluate
        case "todowrite", "update_plan": return .todos
        case "websearch", "webfetch", "web_search", "web_fetch", "search", "getpagesummary": return .web
        case "agent", "task", "runagent", "spawn_agent", "parallelagents": return .agent
        case "httprequest", "http_request": return .http
        case "iphone_inspect", "agentdiscovery", "device_list_targets": return .tools
        case "host_get_host_status": return .host
        case "capturepagescreenshot", "queryscreenshot", "take_screenshot", "screenshot": return .image
        default: return .fields
        }
    }
}

/// Compact input summaries can render for closed disclosures without decoding
/// their results or constructing the expensive source/output views.
struct NativeToolSummary {
    let title: String
    let subtitle: String?
    let symbol: String
    let isCode: Bool

    init(_ call: ToolCallDetail) {
        let args = call.renderArguments?.objectValue ?? ToolValue.parse(call.arguments).objectValue ?? [:]
        func first(_ keys: String...) -> String? {
            keys.compactMap { args[$0]?.stringValue.flatMap(Self.compact) }.first
        }
        let kind = NativeToolRendererKind.resolve(call.rendererName ?? call.toolName)
        let description = first("description", "Description", "reason", "title")
        let path = first("file_path", "path", "TargetFile", "AbsolutePath")
        let name = path.map { ($0 as NSString).lastPathComponent }
        var heading: String
        var detail: String?
        switch kind {
        case .terminal:
            if let presentation = call.commandPresentation {
                heading = presentation.label
                detail = description ?? presentation.summary
                symbol = presentation.symbol
            } else {
                let command = first("command", "cmd", "CommandLine", "chars")
                heading = description ?? command ?? "Read command output"
                detail = description != nil ? command : first("workdir", "cwd", "working_directory")
                symbol = "terminal"
            }
        case .read, .write, .edit:
            let action = kind == .read ? "Read" : kind == .write ? "Write" : "Edit"
            heading = "\(action) \(name ?? "file")"
            detail = path
            symbol = kind == .read ? "doc.text" : "square.and.pencil"
        case .patch:
            let paths: [String]
            if let changes = args["changes"]?.objectValue { paths = changes.keys.sorted() }
            else if let changes = args["changes"]?.toolArray { paths = changes.compactMap { $0.objectValue?.string("path") } }
            else {
                // Inspect only the start of a raw patch; never build its diffs
                // just to label a closed panel.
                let patch = args.string("input") ?? args.string("patch") ?? ""
                paths = patch.prefix(8_000).split(separator: "\n").compactMap { line in
                    for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                        return String(line.dropFirst(prefix.count))
                    }
                    return nil
                }
            }
            heading = paths.count == 1 ? "Update \((paths[0] as NSString).lastPathComponent)" : "Update files"
            detail = paths.isEmpty ? description : paths.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + (paths.count > 3 ? " +\(paths.count - 3) more" : "")
            symbol = "doc.badge.gearshape"
        case .grep, .glob:
            heading = kind == .grep ? "Search file contents" : "Find files"
            detail = [first("pattern", "query", "SearchPattern"), path].compactMap { $0 }.joined(separator: " · ")
            symbol = "doc.text.magnifyingglass"
        case .web, .http:
            let url = first("url", "URL")
            let host = url.flatMap { URL(string: $0)?.host }
            heading = first("query") != nil ? "Search the web" : "\(first("method") ?? "Fetch") \(host ?? "page")"
            detail = first("query") ?? url
            symbol = "globe"
        case .evaluate:
            heading = description ?? "Evaluate code"
            detail = first("expression", "code", "script")
            symbol = "chevron.left.forwardslash.chevron.right"
        case .agent:
            heading = description ?? "Run agent"
            detail = first("prompt", "message", "task")
            symbol = "person.crop.circle"
        case .todos:
            let tasks = args["todos"]?.toolArray ?? args["plan"]?.toolArray ?? []
            let active = tasks.first { $0.objectValue?.string("status") == "in_progress" }?.objectValue
            heading = active?.string("content") ?? active?.string("step") ?? description ?? "Update task plan"
            let completed = tasks.filter { $0.objectValue?.string("status") == "completed" }.count
            detail = tasks.isEmpty ? nil : "\(completed) of \(tasks.count) tasks complete"
            symbol = "checklist"
        case .logs:
            heading = "Read console logs"
            detail = first("query", "filter") ?? args["limit"].map { "Latest \($0.displayString) entries" }
            symbol = "text.alignleft"
        case .tools:
            heading = description ?? "Discover available tools"
            detail = first("query", "category")
            symbol = "wrench.and.screwdriver"
        case .host:
            heading = "Check host status"
            detail = first("machineName", "machineId")
            symbol = "desktopcomputer"
        case .image:
            heading = description ?? "Capture screenshot"
            detail = path
            symbol = "camera"
        case .fields:
            heading = description ?? ToolDisplayName.format(call.toolName)
            detail = args.keys.sorted().lazy.compactMap { key -> String? in
                guard !["description", "Description", "reason", "title"].contains(key),
                      let text = args[key]?.displayString, let value = Self.compact(text) else { return nil }
                return "\(ToolValue.title(key)): \(value)"
            }.prefix(2).joined(separator: " · ")
            symbol = ToolIconMap.symbol(for: call.toolName)
        }
        title = Self.compact(heading) ?? "Tool call"
        let secondary = detail.flatMap(Self.compact)
        subtitle = secondary == title ? nil : secondary
        isCode = (kind == .terminal && call.commandPresentation == nil) || kind == .evaluate
    }

    private static func compact(_ value: String) -> String? {
        let prefix = String(value.prefix(241))
        let text = prefix.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return String(text.prefix(240)) + (prefix.count > 240 ? "…" : "")
    }
}

struct NativeToolContent {
    let call: ToolCallDetail
    let kind: NativeToolRendererKind
    let args: [String: CmsJSON]
    let output: CmsJSON?

    init(_ call: ToolCallDetail) {
        self.call = call
        kind = .resolve(call.rendererName ?? call.toolName)
        args = call.renderArguments?.objectValue ?? ToolValue.parse(call.arguments).objectValue ?? ["input": .string(call.arguments)]
        output = call.result.map { ToolValue.unwrap(ToolValue.parse($0)) }
    }

    func string(_ keys: String...) -> String {
        keys.compactMap { args[$0]?.stringValue }.first ?? ""
    }
    var filePath: String { string("file_path", "path", "TargetFile", "AbsolutePath") }
    var running: Bool { call.statusTitle == "Running" }
}

enum ToolValue {
    static func parse(_ string: String) -> CmsJSON {
        guard let data = string.data(using: .utf8), let value = try? JSONDecoder().decode(CmsJSON.self, from: data) else { return .string(string) }
        return value
    }

    /// MCP text envelopes and JSON-encoded result envelopes are transport,
    /// not user content. Preserve actual objects/arrays for native field views.
    static func unwrap(_ value: CmsJSON, depth: Int = 0) -> CmsJSON {
        guard depth < 6 else { return value }
        if case .string(let string) = value {
            let parsed = parse(string)
            return parsed == value ? value : unwrap(parsed, depth: depth + 1)
        }
        guard case .object(let object) = value else { return value }
        if let structured = object["structuredContent"], structured != .null { return unwrap(structured, depth: depth + 1) }
        if let content = object["content"]?.toolArray, !content.isEmpty,
           content.allSatisfy({ ["text", "image"].contains($0.objectValue?.string("type") ?? "") }) {
            let blocks = content.map { block -> CmsJSON in
                if block.objectValue?.string("type") == "text", let text = block.objectValue?.string("text") {
                    return unwrap(parse(text), depth: depth + 1)
                }
                return block
            }
            return blocks.count == 1 ? blocks[0] : .array(blocks)
        }
        let envelopeKeys: Set<String> = ["status", "result", "resultType", "toolName", "toolInvocationId", "timestamp", "_device", "_deviceLabel"]
        if let result = object["result"], object["status"] != nil, Set(object.keys).isSubset(of: envelopeKeys) {
            return unwrap(result, depth: depth + 1)
        }
        return value
    }

    static func title(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func plainText(_ value: CmsJSON?) -> String? {
        guard let value else { return nil }
        if case .string(let text) = value { return text }
        if let array = value.toolArray, array.allSatisfy({ $0.stringValue != nil }) { return array.compactMap(\.stringValue).joined(separator: "\n") }
        if let object = value.objectValue {
            for key in ["stdout", "output", "text", "content"] {
                if let text = object.string(key) { return text }
            }
            if let file = object["file"] { return plainText(file) }
        }
        return nil
    }

    static func cleanTerminal(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\][^\u{0007}]*\u{0007}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}

extension CmsJSON {
    var toolArray: [CmsJSON]? { if case .array(let values) = self { return values }; return nil }
}

struct NativeToolDiffLine: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case context, removed, added }
    let kind: Kind
    let text: String

    static func unified(_ patch: String) -> [Self] {
        patch.components(separatedBy: "\n").map {
            .init(kind: $0.hasPrefix("+") && !$0.hasPrefix("+++") ? .added : $0.hasPrefix("-") && !$0.hasPrefix("---") ? .removed : .context, text: $0)
        }
    }

    static func compare(old: String, new: String) -> [Self] {
        let before = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let after = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let changes = after.difference(from: before)
        var removed = Set<Int>(), added = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var rows: [Self] = [], i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count && removed.contains(i) { rows.append(.init(kind: .removed, text: before[i])); i += 1 }
            else if j < after.count && added.contains(j) { rows.append(.init(kind: .added, text: after[j])); j += 1 }
            else if i < before.count && j < after.count { rows.append(.init(kind: .context, text: before[i])); i += 1; j += 1 }
            else { break }
        }
        return rows
    }
}

/// Codex's durable FileChange records carry a map of paths to edits, while
/// live app-server events can carry an array. Both differ from a raw patch.
struct NativeToolFileChange {
    let path: String
    let kind: String
    let lines: [NativeToolDiffLine]?
    let fields: [String: CmsJSON]

    static func collect(_ value: CmsJSON?) -> [Self] {
        let entries: [(String, CmsJSON)]
        if let object = value?.objectValue { entries = object.keys.sorted().map { ($0, object[$0]!) } }
        else { entries = (value?.toolArray ?? []).map { ($0.objectValue?.string("path") ?? "", $0) } }
        return entries.map { path, value in
            let fields = value.objectValue ?? [:]
            let kind = fields.string("type") ?? fields.string("kind") ?? fields["kind"]?.objectValue?.string("type") ?? "Change"
            let diff = fields.string("unified_diff") ?? fields.string("diff")
            let source = fields.string("content")
            let lines: [NativeToolDiffLine]?
            if let diff { lines = NativeToolDiffLine.unified(diff) }
            else if let source, ["add", "delete"].contains(kind.lowercased()) {
                let added = kind.lowercased() == "add"
                lines = source.components(separatedBy: "\n").map { .init(kind: added ? .added : .removed, text: (added ? "+" : "-") + $0) }
            } else { lines = nil }
            let consumed: Set<String> = ["path", "type", "unified_diff", "diff"]
            return .init(path: path, kind: ToolValue.title(kind), lines: lines,
                         fields: fields.filter { !consumed.contains($0.key) && !(lines != nil && $0.key == "content") && !($0.key == "kind" && $0.value.stringValue != nil) })
        }
    }
}

struct NativeToolLogGroup: Equatable {
    let level: String
    let message: String
    let stack: String?
    let timestamp: CmsJSON?
    var count: Int

    static func collect(_ entries: [CmsJSON]) -> [Self] {
        var groups: [Self] = []
        for entry in entries {
            let row = entry.objectValue ?? [:]
            let level = (row.string("level") ?? "LOG").uppercased()
            let message = row.string("message") ?? entry.stringValue ?? ""
            let stack = row.string("stack")
            if let last = groups.last, last.level == level && last.message == message && last.stack == stack {
                groups[groups.count - 1].count += 1
            } else { groups.append(.init(level: level, message: message, stack: stack, timestamp: row["ts"] ?? row["timestamp"], count: 1)) }
        }
        return groups
    }
}
