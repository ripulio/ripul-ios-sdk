import SwiftUI
import MarkdownUI

/// Tool-specific layouts compose the shared native components. New families
/// register in NativeToolRendererKind and add one view here; raw diagnostics
/// remain owned by the surrounding sheet, never by a content renderer.
struct NativeToolCallRenderer: View {
    let call: ToolCallDetail
    var body: some View {
        let content = NativeToolContent(call)
        VStack(alignment: .leading, spacing: 20) {
            switch content.kind {
            case .terminal: NativeTerminalToolView(content: content)
            case .read, .write: NativeFileToolView(content: content)
            case .edit, .patch: NativeEditToolView(content: content)
            case .grep, .glob: NativeSearchToolView(content: content)
            case .logs: NativeConsoleToolView(content: content)
            case .todos: NativeTodoToolView(content: content)
            case .evaluate:
                let reason = content.string("reason", "description")
                if !reason.isEmpty { Label(reason, systemImage: "text.magnifyingglass") }
                NativeToolSection(title: "JavaScript") {
                    NativeToolCodeBlock(text: content.string("expression", "code", "script"), numbered: true, identifier: "NativeTool.expression")
                }
                NativeToolParameters(args: content.args, excluding: ["reason", "description", "expression", "code", "script"])
                NativeToolResultView(content: content)
            case .web, .http: NativeWebToolView(content: content)
            case .agent:
                let description = content.string("description", "subagent_type", "agent_type", "family")
                if !description.isEmpty { Label(description, systemImage: "person.crop.circle") }
                NativeToolSection(title: "Task") { Markdown(content.string("prompt", "message", "task")) }
                NativeToolParameters(args: content.args, excluding: ["description", "subagent_type", "agent_type", "family", "prompt", "message", "task"])
                NativeToolResultView(content: content, title: "Response")
            case .tools: NativeDiscoveredToolsView(content: content)
            case .host:
                if let object = content.output?.objectValue {
                    Label(object.string("machineName") ?? "Host", systemImage: "desktopcomputer").font(.headline)
                    if let state = object.string("relayState") { Text("Relay: \(state)").foregroundStyle(.secondary) }
                    NativeToolValueView(value: .object(object.filter { !["machineName", "relayState"].contains($0.key) }))
                } else { NativeToolResultView(content: content) }
                NativeToolParameters(args: content.args)
            case .image:
                NativeToolParameters(args: content.args)
                NativeToolResultView(content: content, title: "Screenshot")
            case .fields:
                if !content.args.isEmpty { NativeToolSection(title: "Parameters") { NativeToolValueView(value: .object(content.args)) } }
                NativeToolResultView(content: content)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NativeTool.renderer.\(content.kind.rawValue)")
    }
}

private struct NativeTerminalToolView: View {
    let content: NativeToolContent
    var body: some View {
        let command = content.string("command", "cmd", "CommandLine", "chars")
        let description = content.string("description", "Description")
        if !description.isEmpty { Text(description).font(.subheadline) }
        NativeToolSection(title: command.isEmpty ? "Running command" : "Command") {
            if command.isEmpty { Text("Read output from the running command").foregroundStyle(.secondary) }
            else { NativeToolCodeBlock(text: command, identifier: "NativeTool.command") }
        }
        let directory = content.string("workdir", "cwd", "working_directory")
        if !directory.isEmpty { Label(directory, systemImage: "folder").font(.caption).textSelection(.enabled) }
        NativeToolParameters(args: content.args, excluding: ["command", "cmd", "CommandLine", "chars", "description", "Description", "workdir", "cwd", "working_directory"])
        NativeToolResultView(content: content, title: "Output")
    }
}

private struct NativeFileToolView: View {
    let content: NativeToolContent
    var body: some View {
        NativeToolPath(path: content.filePath)
        let write = content.kind == .write
        let source = write ? content.string("content", "CodeContent") : ToolValue.plainText(content.output)
        if let source {
            let offset = content.args.double("offset") ?? 1
            let first = offset.isFinite && offset > 0 && offset < 1_000_000_000 ? Int(offset) : 1
            let alreadyNumbered = source.range(of: "^\\s*\\d+[→\\t]", options: .regularExpression) != nil
            NativeToolSection(title: write ? "File contents" : "Contents") {
                NativeToolCodeBlock(text: source, numbered: !alreadyNumbered, firstLine: first, identifier: "NativeTool.fileContents")
            }
            if write { NativeToolResultView(content: content) }
        } else { NativeToolResultView(content: content, title: "Contents") }
        NativeToolParameters(args: content.args, excluding: ["file_path", "path", "TargetFile", "AbsolutePath", "content", "CodeContent"])
    }
}

private struct NativeEditToolView: View {
    let content: NativeToolContent
    var body: some View {
        NativeToolPath(path: content.filePath)
        if content.kind == .patch {
            let patch = content.string("patch", "input", "patch_text")
            let files = NativeToolFileChange.collect(content.args["changes"])
            if !patch.isEmpty { NativeToolDiffView(lines: NativeToolDiffLine.unified(patch), includesPrefix: true) }
            else if !files.isEmpty {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    NativeToolPath(path: file.path)
                    Text(file.kind).font(.caption).foregroundStyle(.secondary)
                    if let lines = file.lines { NativeToolDiffView(lines: lines, includesPrefix: true) }
                    else { Text("No diff was recorded for this file.").foregroundStyle(.secondary) }
                    NativeToolParameters(args: file.fields)
                }
            } else { Text(content.running ? "Waiting for file changes…" : "No patch was recorded.").foregroundStyle(.secondary) }
        } else if let chunks = content.args["_chunks"]?.toolArray ?? content.args["edits"]?.toolArray {
            ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                let fields = chunk.objectValue ?? [:]
                NativeToolSection(title: "Change \(index + 1)") {
                    NativeToolDiffView(lines: NativeToolDiffLine.compare(
                        old: fields.string("old_string") ?? fields.string("TargetContent") ?? "",
                        new: fields.string("new_string") ?? fields.string("ReplacementContent") ?? ""))
                }
            }
        } else {
            NativeToolDiffView(lines: NativeToolDiffLine.compare(
                old: content.string("old_string", "TargetContent"), new: content.string("new_string", "ReplacementContent")))
        }
        if content.args.bool("replace_all") == true { Label("Replace all occurrences", systemImage: "arrow.triangle.2.circlepath").font(.caption) }
        NativeToolParameters(args: content.args, excluding: ["file_path", "path", "TargetFile", "old_string", "new_string", "TargetContent", "ReplacementContent", "replace_all", "_chunks", "ReplacementChunks", "edits", "patch", "input", "patch_text", "changes"])
        // The durable Codex result repeats the same file map already drawn above.
        if content.args["changes"] == nil || content.output != content.args["changes"] { NativeToolResultView(content: content) }
    }
}

private struct NativeToolDiffView: View {
    let lines: [NativeToolDiffLine]
    var includesPrefix = false
    @State private var visibleLines = 100
    var body: some View {
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        NativeToolSection(title: "Changes") {
            Text(added == 0 && removed == 0 ? "No changes" : "\(added) added · \(removed) removed").font(.caption).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(visibleLines).enumerated()), id: \.offset) { _, line in
                    let color: Color = line.kind == .added ? .green : line.kind == .removed ? .red : .secondary
                    HStack(alignment: .top, spacing: 8) {
                        if !includesPrefix { Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").foregroundStyle(color) }
                        Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.caption, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(line.kind == .context ? Color.clear : color.opacity(0.12))
                }
                if lines.count > visibleLines { Button("Show more changes") { visibleLines += 200 }.padding(8) }
            }.accessibilityIdentifier("NativeTool.diff")
        }
    }
}

private struct NativeSearchToolView: View {
    let content: NativeToolContent
    @State private var visibleRows = 100
    var body: some View {
        let pattern = content.string("pattern", "Query", "query")
        Label(pattern.isEmpty ? "All files" : pattern, systemImage: "magnifyingglass").font(.system(.body, design: .monospaced)).textSelection(.enabled)
        let path = content.string("path", "SearchPath", "DirectoryPath")
        if !path.isEmpty { Label(path, systemImage: "folder").font(.caption).textSelection(.enabled) }
        let value = content.output?.objectValue?["files"] ?? content.output
        if let text = ToolValue.plainText(value) {
            let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            NativeToolSection(title: "Matches") {
                Text(lines.isEmpty ? "No matches found" : "\(lines.count) results").font(.caption).foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(lines.prefix(visibleRows).enumerated()), id: \.offset) { _, line in
                        Label { Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            icon: { Image(systemName: content.kind == .glob ? "doc" : "text.magnifyingglass").foregroundStyle(.secondary) }
                    }
                    if lines.count > visibleRows { Button("Show more matches") { visibleRows += 200 } }
                }.accessibilityIdentifier("NativeTool.matches")
            }
        } else { NativeToolResultView(content: content, title: "Matches") }
        NativeToolParameters(args: content.args, excluding: ["pattern", "Query", "query", "path", "SearchPath", "DirectoryPath"])
    }
}

private struct NativeConsoleToolView: View {
    let content: NativeToolContent
    @State private var visibleRows = 100
    var body: some View {
        let query = content.string("query", "filter")
        if !query.isEmpty { Label(query, systemImage: "line.3.horizontal.decrease").textSelection(.enabled) }
        NativeToolParameters(args: content.args, excluding: ["query", "filter"], title: "Filters")
        if let logs = content.output?.objectValue?["logs"]?.toolArray {
            let groups = NativeToolLogGroup.collect(logs)
            let total = content.output?.objectValue?.double("total") ?? Double(logs.count)
            let errors = logs.filter { $0.objectValue?.string("level")?.uppercased() == "ERROR" }.count
            let warnings = logs.filter { $0.objectValue?.string("level")?.uppercased().hasPrefix("WARN") == true }.count
            NativeToolSection(title: "Console") {
                Text(logs.isEmpty ? "No logs matched" : "\(logs.count) of \(CmsJSON.number(total).displayString) logs · \(errors) \(errors == 1 ? "error" : "errors") · \(warnings) \(warnings == 1 ? "warning" : "warnings")")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("NativeTool.logs.summary")
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(groups.prefix(visibleRows).enumerated()), id: \.offset) { _, group in
                        let color: Color = group.level == "ERROR" ? .red : group.level.hasPrefix("WARN") ? .orange : group.level == "INFO" ? .blue : .secondary
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(group.level).fontWeight(.semibold).foregroundStyle(color)
                                if group.count > 1 { Text("×\(group.count)").accessibilityIdentifier("NativeTool.logs.repeat") }
                                Spacer()
                                if let timestamp = group.timestamp?.doubleValue, timestamp.isFinite && timestamp > 0 {
                                    Text(Date(timeIntervalSince1970: timestamp / 1000), style: .time).foregroundStyle(.secondary)
                                }
                            }.font(.caption)
                            Text(ToolValue.cleanTerminal(group.message)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            if let stack = group.stack, !stack.isEmpty { DisclosureGroup("Stack trace") { NativeToolCodeBlock(text: stack) } }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if groups.count > visibleRows { Button("Show more logs") { visibleRows += 200 } }
                }.accessibilityIdentifier("NativeTool.logs")
            }
        } else { NativeToolResultView(content: content, title: "Console") }
    }
}

private struct NativeTodoToolView: View {
    let content: NativeToolContent
    var body: some View {
        let todos = content.args["todos"]?.toolArray ?? content.args["plan"]?.toolArray ?? []
        let completed = todos.filter { $0.objectValue?.string("status") == "completed" }.count
        NativeToolSection(title: "Tasks") {
            ProgressView(value: Double(completed), total: Double(max(todos.count, 1))) { Text("\(completed) of \(todos.count) completed").font(.caption) }
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                let fields = todo.objectValue ?? [:]
                let state = fields.string("status") ?? "pending"
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fields.string("content") ?? fields.string("step") ?? "Task").strikethrough(state == "completed")
                        if state == "in_progress", let active = fields.string("activeForm") { Text(active).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: {
                    Image(systemName: state == "completed" ? "checkmark.circle.fill" : state == "in_progress" ? "play.circle" : "circle")
                        .foregroundStyle(state == "completed" ? Color.green : state == "in_progress" ? .blue : .secondary)
                }
            }
        }.accessibilityIdentifier("NativeTool.todos")
        NativeToolParameters(args: content.args, excluding: ["todos", "plan"])
        NativeToolResultView(content: content)
    }
}

private struct NativeWebToolView: View {
    let content: NativeToolContent
    var body: some View {
        let address = content.string("url", "uri")
        let query = content.string("query", "search_term")
        if !query.isEmpty { Label(query, systemImage: "magnifyingglass").textSelection(.enabled) }
        if content.kind == .http { Text(content.string("method").isEmpty ? "GET" : content.string("method").uppercased()).font(.headline) }
        if let url = URL(string: address), ["http", "https"].contains(url.scheme) { Link(address, destination: url).textSelection(.enabled) }
        let prompt = content.string("prompt", "question")
        if !prompt.isEmpty { Text(prompt).textSelection(.enabled) }
        NativeToolParameters(args: content.args, excluding: ["url", "uri", "query", "search_term", "prompt", "question", "method"])
        if let matches = content.output?.objectValue?["results"]?.toolArray {
            NativeToolSection(title: "Search results") {
                ForEach(Array(matches.enumerated()), id: \.offset) { _, match in
                    let fields = match.objectValue ?? [:]
                    VStack(alignment: .leading, spacing: 6) {
                        if let address = fields.string("url"), let url = URL(string: address), ["http", "https"].contains(url.scheme) {
                            Link(fields.string("title") ?? address, destination: url).font(.headline)
                        }
                        if let snippet = fields.string("snippet") ?? fields.string("description") { Text(snippet).font(.callout).textSelection(.enabled) }
                    }
                    Divider()
                }
            }
        } else if content.kind == .web, let text = ToolValue.plainText(content.output) {
            NativeToolSection(title: "Response") { Markdown(text).textSelection(.enabled) }
        } else { NativeToolResultView(content: content, title: "Response") }
    }
}

private struct NativeDiscoveredToolsView: View {
    let content: NativeToolContent
    var body: some View {
        NativeToolParameters(args: content.args)
        if let tools = content.output?.objectValue?["tools"]?.toolArray {
            NativeToolSection(title: "\(tools.count) tools available") {
                if let message = content.output?.objectValue?.string("message") { Text(message).foregroundStyle(.secondary) }
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    let fields = tool.objectValue ?? [:]
                    VStack(alignment: .leading, spacing: 6) {
                        Label(ToolValue.title(fields.string("name") ?? "Tool"), systemImage: "wrench").font(.headline)
                        if let description = fields.string("description") { Text(description).font(.callout).textSelection(.enabled) }
                        NativeToolParameters(args: fields, excluding: ["name", "description"], title: "Definition")
                    }
                    Divider()
                }
            }
        } else { NativeToolResultView(content: content) }
    }
}
