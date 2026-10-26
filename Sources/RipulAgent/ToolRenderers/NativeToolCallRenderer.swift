import SwiftUI
import MarkdownUI

/// Tool-specific layouts compose the shared native components. New families
/// register in NativeToolRendererKind and add one view here; raw diagnostics
/// remain owned by the surrounding sheet, never by a content renderer.
struct NativeToolCallRenderer: View {
    let call: ToolCallDetail
    var summaryTitle: String? = nil
    var body: some View {
        let content = NativeToolContent(call)
        VStack(alignment: .leading, spacing: 20) {
            switch content.kind {
            case .terminal: NativeTerminalToolView(content: content, summaryTitle: summaryTitle)
            case .read, .write: NativeFileToolView(content: content)
            case .edit, .patch: NativeEditToolView(content: content)
            case .grep, .glob: NativeSearchToolView(content: content)
            case .logs: NativeConsoleToolView(content: content)
            case .todos: NativeTodoToolView(content: content)
            case .evaluate:
                let reason = content.string("reason", "description")
                if !reason.isEmpty { Label(reason, systemImage: "text.magnifyingglass") }
                NativeToolCodeBlock(text: content.string("expression", "code", "script"), title: "JavaScript", numbered: true, syntax: .javascript, identifier: "NativeTool.expression")
                NativeToolParameters(args: content.args, excluding: ["reason", "description", "expression", "code", "script"])
                NativeToolResultView(content: content, textSyntax: .automatic)
            case .web, .http: NativeWebToolView(content: content)
            case .agent:
                let description = content.string("description", "subagent_type", "agent_type", "family")
                if !description.isEmpty { Label(description, systemImage: "person.crop.circle") }
                NativeToolSection(title: "Task") { NativeToolProse(text: content.string("prompt", "message", "task")) }
                NativeToolParameters(args: content.args, excluding: ["description", "subagent_type", "agent_type", "family", "prompt", "message", "task"])
                NativeToolResultView(content: content, title: "Response")
            case .agentComms: NativeAgentCommsToolView(content: content)
            case .agentList: NativeAgentListToolView(content: content)
            case .tools: NativeDiscoveredToolsView(content: content)
            case .secureConnection: NativeSecureConnectionToolView(content: content)
            case .host:
                if let object = content.output?.objectValue {
                    Label(object.string("machineName") ?? "Host", systemImage: "desktopcomputer").font(.ripul(.headline))
                    if let state = object.string("relayState") { Text("Relay: \(state)").foregroundStyle(.ripul(.textSecondary)) }
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
    let summaryTitle: String?
    var body: some View {
        let presentation = content.call.commandPresentation
        let command = presentation?.command ?? content.string("command", "cmd", "CommandLine", "chars")
        let description = content.string("description", "Description")
        if !description.isEmpty, description != summaryTitle { Text(description).font(.ripul(.subheadline)) }
        if command.isEmpty {
            NativeToolSection(title: "Running command") {
                Text("Read output from the running command").foregroundStyle(.ripul(.textSecondary))
            }
        } else if let source = presentation?.source, let language = presentation?.language {
            NativeToolCodeBlock(text: source, title: "Script", numbered: true, syntax: .language(language), identifier: "NativeTool.command")
        } else {
            NativeToolCodeBlock(text: command, title: "Command", syntax: .shell, commandBreakLines: presentation?.commandBreakLines ?? [], commandPipeLines: presentation?.commandPipeLines ?? [], identifier: "NativeTool.command")
        }
        let directory = content.string("workdir", "cwd", "working_directory")
        if !directory.isEmpty { Label(directory, systemImage: "folder").font(.ripul(.caption)).textSelection(.enabled) }
        NativeToolParameters(args: content.args, excluding: ["command", "cmd", "CommandLine", "chars", "description", "Description", "workdir", "cwd", "working_directory"])
        NativeToolResultView(content: content, title: "Output", textSyntax: .automatic)
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
            NativeToolCodeBlock(text: source, title: write ? "File contents" : "Contents", numbered: !alreadyNumbered, firstLine: first, syntax: .file(content.filePath), readLineNumbers: alreadyNumbered, identifier: "NativeTool.fileContents")
            if write { NativeToolResultView(content: content) }
        } else { NativeToolResultView(content: content, title: "Contents", textSyntax: .automatic) }
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
            if !patch.isEmpty { NativeToolDiffView(lines: NativeToolDiffLine.unified(patch), path: content.filePath, includesPrefix: true) }
            else if !files.isEmpty {
                ForEach(Array(files.enumerated()), id: \.offset) { fileIndex, file in
                    Group {
                        NativeToolPath(path: file.path)
                        Text(file.kind).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                        if let lines = file.lines { NativeToolDiffView(lines: lines, path: file.path, includesPrefix: true) }
                        else { Text("No diff was recorded for this file.").foregroundStyle(.ripul(.textSecondary)) }
                        NativeToolParameters(args: file.fields)
                    }
                    .nativeChatRowStateScope("file:\(fileIndex)")
                }
            } else { Text(content.running ? "Waiting for file changes…" : "No patch was recorded.").foregroundStyle(.ripul(.textSecondary)) }
        } else if let chunks = content.args["_chunks"]?.toolArray ?? content.args["edits"]?.toolArray {
            ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                let fields = chunk.objectValue ?? [:]
                NativeToolSection(title: "Change \(index + 1)") {
                    NativeToolDiffView(lines: NativeToolDiffLine.compare(
                        old: fields.string("old_string") ?? fields.string("TargetContent") ?? "",
                        new: fields.string("new_string") ?? fields.string("ReplacementContent") ?? ""), path: content.filePath)
                        .nativeChatRowStateScope("chunk:\(index)")
                }
            }
        } else {
            NativeToolDiffView(lines: NativeToolDiffLine.compare(
                old: content.string("old_string", "TargetContent"), new: content.string("new_string", "ReplacementContent")), path: content.filePath)
        }
        if content.args.bool("replace_all") == true { Label("Replace all occurrences", systemImage: "arrow.triangle.2.circlepath").font(.ripul(.caption)) }
        NativeToolParameters(args: content.args, excluding: ["file_path", "path", "TargetFile", "old_string", "new_string", "TargetContent", "ReplacementContent", "replace_all", "_chunks", "ReplacementChunks", "edits", "patch", "input", "patch_text", "changes"])
        // The durable Codex result repeats the same file map already drawn above.
        if content.args["changes"] == nil || content.output != content.args["changes"] { NativeToolResultView(content: content) }
    }
}

struct NativeToolDiffView: View {
    let lines: [NativeToolDiffLine]
    var path: String
    var includesPrefix = false
    @NativeRowState("diff.visibleLines") private var visibleLines = 100
    @State private var highlighted: [AttributedString] = []
    @State private var highlightedRequest: NativeDiffHighlightRequest?
    @Environment(\.colorScheme) private var colorScheme
    var diffScopeKey: String { path }
    var body: some View {
        let currentVisibleLines = _visibleLines.value(subscope: diffScopeKey)
        let request = NativeDiffHighlightRequest(lines: Array(lines.prefix(currentVisibleLines)), path: path, includesPrefix: includesPrefix, dark: colorScheme == .dark)
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        NativeToolSection(title: "Changes") {
            Text(added == 0 && removed == 0 ? "No changes" : "\(added) added · \(removed) removed").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(currentVisibleLines).enumerated()), id: \.offset) { index, line in
                    let color: Color = line.kind == .added ? .green : line.kind == .removed ? .red : .ripul(.textSecondary) // theme-exempt: diff colours are data
                    HStack(alignment: .top, spacing: 8) {
                        if !includesPrefix { Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").foregroundStyle(color) }
                        Text(highlightedRequest == request && index < highlighted.count && !line.text.isEmpty ? highlighted[index] : AttributedString(line.text.isEmpty ? " " : line.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.ripul(.caption, family: .code)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(line.kind == .context ? Color.clear : color.opacity(0.12))
                }
                if lines.count > currentVisibleLines {
                    Button("Show more changes") {
                        _visibleLines.setValue(currentVisibleLines + 200, subscope: diffScopeKey)
                    }.padding(8)
                }
            }.accessibilityIdentifier("NativeTool.diff")
        }
        .task(id: request) {
            let result = await NativeSourceHighlighting.shared.diff(request)
            guard !Task.isCancelled else { return }
            highlighted = result
            highlightedRequest = request
        }
    }
}

private struct NativeSearchToolView: View {
    let content: NativeToolContent
    @NativeRowState("search.visibleRows") private var visibleRows = 100
    var body: some View {
        let currentVisibleRows = _visibleRows.value(subscope: content.call.id)
        let pattern = content.string("pattern", "Query", "query")
        Label(pattern.isEmpty ? "All files" : pattern, systemImage: "magnifyingglass").font(.ripul(.body, family: .code)).textSelection(.enabled)
        let path = content.string("path", "SearchPath", "DirectoryPath")
        if !path.isEmpty { Label(path, systemImage: "folder").font(.ripul(.caption)).textSelection(.enabled) }
        let value = content.output?.objectValue?["files"] ?? content.output
        if let text = ToolValue.plainText(value) {
            let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            NativeToolSection(title: "Matches") {
                Text(lines.isEmpty ? "No matches found" : "\(lines.count) results").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(lines.prefix(currentVisibleRows).enumerated()), id: \.offset) { _, line in
                        Label { Text(line).font(.ripul(.caption, family: .code)).textSelection(.enabled) }
                            icon: { Image(systemName: content.kind == .glob ? "doc" : "text.magnifyingglass").foregroundStyle(.ripul(.textSecondary)) }
                    }
                    if lines.count > currentVisibleRows {
                        Button("Show more matches") {
                            _visibleRows.setValue(currentVisibleRows + 200, subscope: content.call.id)
                        }
                    }
                }.accessibilityIdentifier("NativeTool.matches")
            }
        } else { NativeToolResultView(content: content, title: "Matches", textSyntax: .automatic) }
        NativeToolParameters(args: content.args, excluding: ["pattern", "Query", "query", "path", "SearchPath", "DirectoryPath"])
    }
}

private struct NativeTodoToolView: View {
    let content: NativeToolContent
    var body: some View {
        let todos = content.args["todos"]?.toolArray ?? content.args["plan"]?.toolArray ?? []
        let completed = todos.filter { $0.objectValue?.string("status") == "completed" }.count
        NativeToolSection(title: "Tasks") {
            ProgressView(value: Double(completed), total: Double(max(todos.count, 1))) { Text("\(completed) of \(todos.count) completed").font(.ripul(.caption)) }
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                let fields = todo.objectValue ?? [:]
                let state = fields.string("status") ?? "pending"
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fields.string("content") ?? fields.string("step") ?? "Task").strikethrough(state == "completed")
                        if state == "in_progress", let active = fields.string("activeForm") { Text(active).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)) }
                    }
                } icon: {
                    Image(systemName: state == "completed" ? "checkmark.circle.fill" : state == "in_progress" ? "play.circle" : "circle")
                        .foregroundStyle(state == "completed" ? Color.ripul(.success) : state == "in_progress" ? Color.ripul(.info) : Color.ripul(.textSecondary))
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
        if content.kind == .http { Text(content.string("method").isEmpty ? "GET" : content.string("method").uppercased()).font(.ripul(.headline)) }
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
                            Link(fields.string("title") ?? address, destination: url).font(.ripul(.headline))
                        }
                        if let snippet = fields.string("snippet") ?? fields.string("description") { Text(snippet).font(.ripul(.callout)).textSelection(.enabled) }
                    }
                    Divider()
                }
            }
        } else if content.kind == .web, let text = ToolValue.plainText(content.output) {
            NativeToolSection(title: "Response") { NativeToolProse(text: text) }
        } else { NativeToolResultView(content: content, title: "Response") }
    }
}

private struct NativeDiscoveredToolsView: View {
    let content: NativeToolContent
    var body: some View {
        NativeToolParameters(args: content.args)
        if let tools = content.output?.objectValue?["tools"]?.toolArray {
            NativeToolSection(title: "\(tools.count) tools available") {
                if let message = content.output?.objectValue?.string("message") { Text(message).foregroundStyle(.ripul(.textSecondary)) }
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    let fields = tool.objectValue ?? [:]
                    VStack(alignment: .leading, spacing: 6) {
                        Label(ToolValue.title(fields.string("name") ?? "Tool"), systemImage: "wrench").font(.ripul(.headline))
                        if let description = fields.string("description") { Text(description).font(.ripul(.callout)).textSelection(.enabled) }
                        NativeToolParameters(args: fields, excluding: ["name", "description"], title: "Definition")
                    }
                    Divider()
                }
            }
        } else { NativeToolResultView(content: content) }
    }
}
