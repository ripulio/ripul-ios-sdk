import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct NativeConsoleToolView: View {
    let content: NativeToolContent

    var body: some View {
        if let logs = NativeConsoleLogs(content.output) {
            NativeConsoleBrowser(logs: logs)
            NativeToolParameters(args: content.args, title: "Captured with")
        } else {
            NativeToolParameters(args: content.args, title: "Filters")
            NativeToolResultView(content: content, title: "Console")
        }
    }
}

private struct NativeConsoleBrowser: View {
    let logs: NativeConsoleLogs
    @State private var query = ""
    @State private var level: String?
    @State private var newestFirst = true
    @State private var visibleRows = 100
    @State private var copied = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let matches = logs.matching(query: query, level: level)
        let ordered = newestFirst ? Array(matches.reversed()) : matches
        let matchingCount = matches.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Console", systemImage: "terminal").font(.headline)
                Spacer()
                Button {
                    copyConsoleText(logs.copyText(query: query, level: level, newestFirst: newestFirst))
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless).disabled(matches.isEmpty)
                .accessibilityLabel("Copy matching logs")
                .accessibilityIdentifier("NativeTool.logs.copy")
            }
            Text(summary()).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("NativeTool.logs.summary")
            search
            levelFilters
            HStack {
                Text("\(matchingCount) matching \(matchingCount == 1 ? "entry" : "entries")")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("NativeTool.logs.matchCount")
                Spacer()
                Menu {
                    Picker("Order", selection: $newestFirst) {
                        Text("Newest first").tag(true)
                        Text("Oldest first").tag(false)
                    }
                } label: {
                    Label(newestFirst ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("NativeTool.logs.order")
            }.font(.caption)
            if matches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(logs.entries.isEmpty ? "No logs were captured" : "No matching logs", systemImage: "text.magnifyingglass")
                        .font(.subheadline).accessibilityIdentifier("NativeTool.logs.empty")
                    if !logs.entries.isEmpty {
                        Text("Try another search or log level.").font(.caption).foregroundStyle(.secondary)
                        Button("Clear filters") { query = ""; level = nil; searchFocused = false }
                            .accessibilityIdentifier("NativeTool.logs.reset")
                    }
                }.padding(.vertical, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(ordered.prefix(visibleRows)) { group in NativeConsoleLogRow(group: group) }
                    if ordered.count > visibleRows {
                        Button("Show more (\(ordered.count - visibleRows) remaining)") { visibleRows += 100 }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .accessibilityIdentifier("NativeTool.logs.more")
                    }
                }.accessibilityIdentifier("NativeTool.logs")
            }
        }
        .onChange(of: query) { _, _ in resetPage() }
        .onChange(of: level) { _, _ in resetPage() }
        .onChange(of: newestFirst) { _, _ in resetPage() }
        .onChange(of: logs.entries) { _, _ in copied = false }
    }

    private func resetPage() { visibleRows = 100; copied = false }

    private func summary() -> String {
        let count = logs.entries.count
        let total = logs.total.map { $0 > count ? " of \($0)" : "" } ?? ""
        let errors = logs.entries.filter { $0.level == "ERROR" }.count
        let warnings = logs.entries.filter { $0.level == "WARN" }.count
        return "\(count)\(total) logs · \(errors) \(errors == 1 ? "error" : "errors") · \(warnings) \(warnings == 1 ? "warning" : "warnings")"
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search captured logs", text: $query).textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($searchFocused).onSubmit { searchFocused = false }
                .accessibilityIdentifier("NativeTool.logs.search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(10).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var levelFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                levelButton(nil, title: "All", count: logs.entries.count)
                ForEach(logs.levels, id: \.self) { value in
                    levelButton(value, title: logLevelTitle(value), count: logs.entries.filter { $0.level == value }.count)
                }
            }
        }
    }

    private func levelButton(_ value: String?, title: String, count: Int) -> some View {
        let selected = level == value
        let color = value.map(logLevelColor) ?? .accentColor
        return Button { level = value } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").monospacedDigit().opacity(0.75)
            }
            .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(selected ? color : .secondary)
            .background(selected ? color.opacity(0.13) : .primary.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? color.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) entries")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("NativeTool.logs.level.\(value ?? "all")")
    }
}

private struct NativeConsoleLogRow: View {
    let group: NativeToolLogGroup
    @State private var expanded = false

    var body: some View {
        let entry = group.entry
        let clean = ToolValue.cleanTerminal(entry.message)
        let long = clean.count > 320 || clean.components(separatedBy: "\n").count > 4
        let preview = String(clean.prefix(320).split(separator: "\n", omittingEmptySubsequences: false).prefix(4).joined(separator: "\n"))
        let color = logLevelColor(entry.level)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(logLevelTitle(entry.level), systemImage: logLevelSymbol(entry.level))
                    .fontWeight(.semibold).foregroundStyle(color)
                if group.count > 1 {
                    Text("×\(group.count)").fontWeight(.semibold)
                        .accessibilityLabel("Repeated \(group.count) times")
                        .accessibilityIdentifier("NativeTool.logs.repeat")
                }
                Spacer(minLength: 4)
                if let date = entry.date {
                    Text(date.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
                        .help(date.formatted(date: .complete, time: .complete))
                }
            }.font(.caption)
            if expanded {
                NativeToolCodeBlock(text: entry.message, identifier: "NativeTool.logs.message.\(group.id)")
            } else {
                Text(long ? preview + "…" : clean).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("NativeTool.logs.message.\(group.id)")
            }
            if long {
                Button(expanded ? "Show less" : "Show full message") { expanded.toggle() }
                    .font(.caption).accessibilityIdentifier("NativeTool.logs.expand.\(group.id)")
            }
            if group.count > 1, let last = group.lastEntry.date, last != entry.date {
                Text("Last repeated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let stack = entry.stack, !stack.isEmpty {
                DisclosureGroup("Stack trace") {
                    NativeToolCodeBlock(text: stack, identifier: "NativeTool.logs.stack.\(group.id)")
                }.font(.caption).accessibilityIdentifier("NativeTool.logs.stackToggle.\(group.id)")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.7)).frame(width: 3).padding(.vertical, 10) }
        .contextMenu {
            Button("Copy message", systemImage: "doc.on.doc") { copyConsoleText(entry.message) }
            if let stack = entry.stack { Button("Copy stack trace", systemImage: "text.alignleft") { copyConsoleText(stack) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NativeTool.logs.row.\(group.id)")
    }
}

private func logLevelTitle(_ level: String) -> String {
    level == "WARN" ? "Warning" : level.prefix(1) + level.dropFirst().lowercased()
}

private func logLevelColor(_ level: String) -> Color {
    switch level {
    case "ERROR": return .red
    case "WARN": return .orange
    case "INFO": return .blue
    default: return .secondary
    }
}

private func logLevelSymbol(_ level: String) -> String {
    switch level {
    case "ERROR": return "xmark.octagon.fill"
    case "WARN": return "exclamationmark.triangle.fill"
    case "INFO": return "info.circle.fill"
    default: return "text.alignleft"
    }
}

private func copyConsoleText(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}
