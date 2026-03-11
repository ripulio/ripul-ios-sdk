import SwiftUI

// MARK: - Console Log Viewer

/// Displays captured JavaScript console output from the WKWebView.
/// Supports level filtering (ALL/LOG/WARN/ERROR), text search,
/// copy-to-clipboard, and expandable stack traces.
///
/// Accessible via the `/rr.` debug menu → "Console Logs".
@available(iOS 16.0, macOS 13.0, *)
public struct ConsoleLogViewer: View {
    @ObservedObject var bridge: AgentBridge
    @State private var searchText = ""
    @State private var levelFilter: String = "ALL"
    @State private var autoScroll = true

    private let levels = ["ALL", "LOG", "WARN", "ERROR"]

    private var filteredLogs: [ConsoleLogEntry] {
        bridge.consoleLogs.filter { entry in
            if levelFilter != "ALL" && entry.level != levelFilter { return false }
            if !searchText.isEmpty {
                return entry.message.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }

    public init(bridge: AgentBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                // Level filter
                Picker("Level", selection: $levelFilter) {
                    ForEach(levels, id: \.self) { level in
                        Text(level == "ALL" ? "All" : level).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                // Search
                #if os(macOS)
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                #else
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                #endif

                Spacer()

                // Log count
                Text("\(filteredLogs.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    copyLogs()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy all visible logs")

                Button {
                    bridge.clearConsoleLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Log list
            ScrollViewReader { proxy in
                List(filteredLogs) { entry in
                    ConsoleLogEntryRow(entry: entry)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                        .id(entry.id)
                }
                .listStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .onChange(of: bridge.consoleLogs.count) { _ in
                    if autoScroll, let last = filteredLogs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Console Logs")
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 300)
        #endif
    }

    private func copyLogs() {
        let text = filteredLogs.map { entry in
            let ts = Self.timestampFormatter.string(from: entry.timestamp)
            var line = "[\(ts)] [\(entry.level)] \(entry.message)"
            if let stack = entry.stack {
                line += "\n" + stack.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n")
            }
            return line
        }.joined(separator: "\n")

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - Log Entry Row

@available(iOS 16.0, macOS 13.0, *)
private struct ConsoleLogEntryRow: View {
    let entry: ConsoleLogEntry
    @State private var showStack = false

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .foregroundStyle(.secondary)
                    .frame(width: 85, alignment: .leading)

                Text(entry.level)
                    .fontWeight(.medium)
                    .foregroundStyle(levelColor)
                    .frame(width: 42, alignment: .leading)

                Text(entry.message)
                    .foregroundStyle(entry.level == "ERROR" ? .red : .primary)
                    .textSelection(.enabled)

                if entry.stack != nil {
                    Image(systemName: showStack ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if showStack, let stack = entry.stack {
                Text(stack)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 135) // align with message column
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.stack != nil {
                showStack.toggle()
            }
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case "ERROR": return .red
        case "WARN": return .orange
        default: return .secondary
        }
    }
}
