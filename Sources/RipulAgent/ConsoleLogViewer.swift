import Combine
import SwiftUI

// MARK: - Console Log Viewer

/// Displays captured JavaScript console output and network requests from the WKWebView.
/// Top-level tab picker switches between Console and Network views.
///
/// Accessible via the `/rr.` debug menu → "Console Logs".
@available(iOS 16.0, macOS 13.0, *)
public struct ConsoleLogViewer: View {
    @ObservedObject var bridge: AgentBridge
    @State private var activeTab: Tab = .console

    enum Tab: String, CaseIterable {
        case console = "Console"
        case network = "Network"
        case tools = "Tools"
    }

    public init(bridge: AgentBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Tab", selection: $activeTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch activeTab {
            case .console:
                ConsoleTabView(bridge: bridge)
            case .network:
                NetworkTabView(bridge: bridge)
            case .tools:
                ToolsTabView(bridge: bridge)
            }
        }
        .navigationTitle("Console Logs")
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 300)
        #endif
    }
}

// MARK: - Console Filter Chips

/// A single filter selection in the console tab. Levels are the historical
/// ALL/LOG/WARN/ERROR set; tags are contributed by typed log renderers via
/// `ConsoleLogRendererRegistry.filterTags`. One chip is active at a time —
/// the user can flip between "show only warnings" and "show only ripul/sync
/// rows" with the same interaction.
@available(iOS 16.0, macOS 13.0, *)
private enum ConsoleFilterChip: Hashable {
    case level(String)
    case tag(String)
}

@available(iOS 16.0, macOS 13.0, *)
private struct ConsoleFilterChipButton: View {
    let chip: ConsoleFilterChip
    let label: String
    let isSelected: Bool
    let action: () -> Void

    private var isTag: Bool {
        if case .tag = chip { return true }
        return false
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.caption, design: isTag ? .monospaced : .default))
                .fontWeight(.medium)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        isSelected
                            ? Color.accentColor.opacity(0.18)
                            : Color.secondary.opacity(0.12)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Console Tab

@available(iOS 16.0, macOS 13.0, *)
private struct ConsoleTabView: View {
    @ObservedObject var bridge: AgentBridge
    @State private var searchText = ""
    @State private var filter: ConsoleFilterChip = .level("ALL")
    @State private var selectedIDs: Set<UUID> = []
    /// Rows the user has tapped to fold out their renderer's detail panel
    /// and/or stack trace. Independent of `selectedIDs` so the existing
    /// "select a subset to copy" flow keeps working alongside the new
    /// master/detail expand.
    @State private var expandedIDs: Set<UUID> = []
    @State private var logVersion = 0

    /// Standard level chips, always shown first. Tag chips come from the
    /// renderer registry so adding a typed renderer with a `filterTag`
    /// automatically grows this bar — no UI changes needed.
    private static let levelChips: [ConsoleFilterChip] = [
        .level("ALL"), .level("LOG"), .level("WARN"), .level("ERROR"),
    ]

    private var availableFilters: [ConsoleFilterChip] {
        Self.levelChips + ConsoleLogRendererRegistry.filterTags.map { .tag($0.tag) }
    }

    private func chipLabel(_ chip: ConsoleFilterChip) -> String {
        switch chip {
        case .level("ALL"): return "All"
        case .level(let l): return l.capitalized
        case .tag(let t):
            return ConsoleLogRendererRegistry.filterTags
                .first(where: { $0.tag == t })?.label ?? t
        }
    }

    private var filteredLogs: [ConsoleLogEntry] {
        bridge.consoleLogs.filter { entry in
            switch filter {
            case .level("ALL"):
                break
            case .level(let level):
                if entry.level != level { return false }
            case .tag(let tag):
                // Cheap prefix check — avoids a full JSON parse just to filter.
                if !entry.message.hasPrefix("[\(tag)]") { return false }
            }
            if !searchText.isEmpty {
                return entry.message.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter chips — horizontally scrollable so new tag chips can
            // grow the bar without overflowing on narrow phones.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(availableFilters, id: \.self) { chip in
                        ConsoleFilterChipButton(
                            chip: chip,
                            label: chipLabel(chip),
                            isSelected: filter == chip,
                            action: { filter = chip }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Toolbar
            HStack(spacing: 12) {
                #if os(macOS)
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                #else
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                #endif

                Spacer()

                if selectedIDs.isEmpty {
                    Text("\(filteredLogs.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(selectedIDs.count) selected")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }

                Button {
                    copyLogs()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help(selectedIDs.isEmpty
                      ? "Copy all visible logs"
                      : "Copy \(selectedIDs.count) selected log\(selectedIDs.count == 1 ? "" : "s")")

                Button {
                    selectedIDs.removeAll()
                    bridge.clearConsoleLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Log list
            ScrollViewReader { proxy in
                List(filteredLogs) { entry in
                    ConsoleLogEntryRow(
                        entry: entry,
                        isExpanded: expandedIDs.contains(entry.id),
                        isSelected: selectedIDs.contains(entry.id),
                        onToggleExpand: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if expandedIDs.contains(entry.id) {
                                    expandedIDs.remove(entry.id)
                                } else {
                                    expandedIDs.insert(entry.id)
                                }
                            }
                        },
                        onToggleSelect: {
                            if selectedIDs.contains(entry.id) {
                                selectedIDs.remove(entry.id)
                            } else {
                                selectedIDs.insert(entry.id)
                            }
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(
                        selectedIDs.contains(entry.id)
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .id(entry.id)
                }
                .listStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .onChange(of: logVersion) { _ in
                    if selectedIDs.isEmpty, let last = filteredLogs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .onReceive(bridge.consoleLogsSubject) { _ in logVersion += 1 }
    }

    private func copyLogs() {
        let logsToCopy = selectedIDs.isEmpty
            ? filteredLogs
            : filteredLogs.filter { selectedIDs.contains($0.id) }

        let text = logsToCopy.map { entry in
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

// MARK: - Network Tab

@available(iOS 16.0, macOS 13.0, *)
private struct NetworkTabView: View {
    @ObservedObject var bridge: AgentBridge
    @State private var searchText = ""
    @State private var methodFilter: String = "ALL"
    @State private var expandedIDs: Set<UUID> = []
    @State private var logVersion = 0
    @State private var captureEnabled: Bool

    private let methods = ["ALL", "GET", "POST", "PUT", "PATCH", "DELETE", "LONG"]

    init(bridge: AgentBridge) {
        self.bridge = bridge
        _captureEnabled = State(initialValue: bridge.isNetworkCaptureEnabled)
    }

    private var filteredLogs: [NetworkLogEntry] {
        bridge.networkLogs.filter { entry in
            if methodFilter == "LONG" {
                if entry.durationMs < 5000 { return false }
            } else if methodFilter != "ALL" && entry.method.uppercased() != methodFilter { return false }
            if !searchText.isEmpty {
                return entry.url.localizedCaseInsensitiveContains(searchText)
                    || entry.method.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Method filter
            ScrollView(.horizontal, showsIndicators: false) {
                Picker("Method", selection: $methodFilter) {
                    ForEach(methods, id: \.self) { method in
                        Text(method == "ALL" ? "All" : method).tag(method)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 4)

            // Toolbar
            HStack(spacing: 12) {
                Toggle("Capture", isOn: $captureEnabled)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .onChange(of: captureEnabled) { newValue in
                        bridge.isNetworkCaptureEnabled = newValue
                    }

                #if os(macOS)
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                #else
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                #endif

                Spacer()

                Text("\(filteredLogs.count) requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    copyNetworkLogs()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy network logs")

                Button {
                    expandedIDs.removeAll()
                    bridge.clearNetworkLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear network logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if !captureEnabled && bridge.networkLogs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "network")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Network capture is off")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Toggle Capture to start recording requests")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section(header: networkColumnHeader) {
                                ForEach(filteredLogs) { entry in
                                    NetworkLogEntryRow(
                                        entry: entry,
                                        isExpanded: expandedIDs.contains(entry.id)
                                    )
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            if expandedIDs.contains(entry.id) {
                                                expandedIDs.remove(entry.id)
                                            } else {
                                                expandedIDs.insert(entry.id)
                                            }
                                        }
                                    }
                                    .id(entry.id)
                                    Divider()
                                }
                            }
                        }
                        .frame(minWidth: 620, maxHeight: .infinity, alignment: .top)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: logVersion) { _ in
                        if expandedIDs.isEmpty, let last = filteredLogs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onReceive(bridge.networkLogsSubject) { _ in logVersion += 1 }
    }

    private var networkColumnHeader: some View {
        HStack(spacing: 8) {
            Text("")
                .frame(width: 10)
            Text("Time")
                .frame(width: 85, alignment: .leading)
            Text("M")
                .frame(width: 36, alignment: .leading)
            Text("S")
                .frame(width: 32, alignment: .trailing)
            Text("D")
                .frame(width: 52, alignment: .trailing)
            Text("Req")
                .frame(width: 52, alignment: .trailing)
            Text("Res")
                .frame(width: 52, alignment: .trailing)
            Text("URL")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption2, design: .monospaced))
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func copyNetworkLogs() {
        let text = filteredLogs.map { entry in
            let ts = Self.timestampFormatter.string(from: entry.timestamp)
            let status = entry.status == 0 ? "ERR" : "\(entry.status)"
            let dur = entry.durationMs >= 0 ? "\(entry.durationMs)ms" : "?"
            let size = entry.responseSize >= 0 ? formatBytes(entry.responseSize) : "?"
            var line = "[\(ts)] \(entry.method) \(status) \(dur) \(size) \(entry.url)"
            if let error = entry.error {
                line += " error=\(error)"
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

// MARK: - Tools Tab

@available(iOS 16.0, macOS 13.0, *)
private struct ToolsTabView: View {
    @ObservedObject var bridge: AgentBridge
    @Environment(\.dismiss) private var dismiss

    @State private var scrollHudOn = false
    @State private var elementInspectorOn = false
    @State private var wsDebugOn = false
    @State private var perfHudOn = false
    // Native, reactive gate for the chat "Rebuild from JSONL" menu items —
    // flipping this updates the native menus live (no web round-trip). Also
    // mirrored to the web `enableChatRebuild` setting for the web header menu.
    @AppStorage("ripulChatRebuildMenu") private var chatRebuildOn = false

    var body: some View {
        List {
            Section {
                #if os(iOS)
                Button {
                    bridge.wantsShowViewInspector = true
                    dismiss()
                } label: {
                    Label("View Explorer", systemImage: "viewfinder")
                }
                #endif
            } header: {
                Text("Native")
            } footer: {
                #if os(iOS)
                Text("Inspect any UIView in the running app — tap to pick, drag the HUD to move it.")
                #else
                Text("View Explorer is iOS-only.")
                #endif
            }

            Section {
                Toggle(isOn: webHudBinding($scrollHudOn, key: "enableScrollHud")) {
                    Label("Scroll HUD", systemImage: "scroll")
                }
                Toggle(isOn: webHudBinding($elementInspectorOn, key: "enableElementDebugger")) {
                    Label("Element Inspector", systemImage: "cursorarrow.and.square.on.square.dashed")
                }
                Toggle(isOn: webHudBinding($wsDebugOn, key: "enableSessionChannelDebug")) {
                    Label("WS Debug Panel", systemImage: "network")
                }
                Toggle(isOn: webHudBinding($perfHudOn, key: "enablePerfHud")) {
                    Label("Perf HUD", systemImage: "speedometer")
                }
                Toggle(isOn: Binding(
                    get: { chatRebuildOn },
                    set: { v in
                        chatRebuildOn = v
                        Task {
                            try? await bridge.callAsyncJavaScript("window.__ripulUpdateUserSettings?.({ enableChatRebuild: \(v) })")
                        }
                    }
                )) {
                    Label("Chat Rebuild Menu", systemImage: "arrow.triangle.2.circlepath")
                }
            } header: {
                Text("Web HUDs")
            } footer: {
                Text("Toggles the floating debug overlays in the web app. Changes take effect immediately.")
            }
        }
        .task {
            do {
                let result = try await bridge.callAsyncJavaScript(
                    "return window.__ripulGetUserSettings?.()"
                )
                if let dict = result as? [String: Any] {
                    scrollHudOn = dict["enableScrollHud"] as? Bool ?? false
                    elementInspectorOn = dict["enableElementDebugger"] as? Bool ?? false
                    wsDebugOn = dict["enableSessionChannelDebug"] as? Bool ?? false
                    perfHudOn = dict["enablePerfHud"] as? Bool ?? false
                }
            } catch {}
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func webHudBinding(_ state: Binding<Bool>, key: String) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue },
            set: { newValue in
                state.wrappedValue = newValue
                Task {
                    try? await bridge.callAsyncJavaScript(
                        "window.__ripulUpdateUserSettings?.({ \(key): \(newValue) })"
                    )
                }
            }
        )
    }
}

// MARK: - Console Log Entry Row

@available(iOS 16.0, macOS 13.0, *)
private struct ConsoleLogEntryRow: View {
    let entry: ConsoleLogEntry
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleExpand: () -> Void
    let onToggleSelect: () -> Void

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        let parsed = ParsedConsoleLog.parse(entry.message)
        let descriptor = ConsoleLogRendererRegistry.renderer(for: parsed, level: entry.level)
        let canFoldOut = descriptor != nil || entry.stack != nil

        VStack(alignment: .leading, spacing: 4) {
            // Master row — compact summary, never wraps the message column.
            HStack(alignment: .top, spacing: 8) {
                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .foregroundStyle(.secondary)
                    .frame(width: 85, alignment: .leading)

                Text(entry.level)
                    .fontWeight(.medium)
                    .foregroundStyle(levelColor)
                    .frame(width: 42, alignment: .leading)

                summaryContent(parsed: parsed, descriptor: descriptor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if canFoldOut {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if canFoldOut {
                    onToggleExpand()
                } else {
                    onToggleSelect()
                }
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                onToggleSelect()
            }

            // Detail panel — full-width fold-out, unconstrained by the
            // message column. Renderer detail and stack both surface here
            // so a single expand exposes everything available for the row.
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let descriptor {
                        descriptor.renderDetail(parsed, entry.level)
                    }
                    if let stack = entry.stack {
                        RendererDetailPanel {
                            Text("Stack")
                                .font(.system(.caption2, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(stack)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 135) // align with message column
                .padding(.trailing, 4)
                .padding(.top, 2)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 1)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .contextMenu { copyMenuItems(parsed: parsed) }
    }

    @ViewBuilder
    private func summaryContent(
        parsed: ParsedConsoleLog,
        descriptor: ConsoleLogRendererDescriptor?
    ) -> some View {
        if let descriptor {
            descriptor.renderSummary(parsed, entry.level)
        } else {
            Text(firstLine(of: entry.message))
                .foregroundStyle(entry.level == "ERROR" ? .red : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
    }

    private func firstLine(of message: String) -> String {
        if let nl = message.firstIndex(of: "\n") {
            return String(message[..<nl])
        }
        return message
    }

    @ViewBuilder
    private func copyMenuItems(parsed: ParsedConsoleLog) -> some View {
        if let jsonText = parsed.jsonText {
            Button {
                copyToPasteboard(jsonText)
            } label: {
                Label("Copy JSON", systemImage: "curlybraces")
            }
        }
        Button {
            copyToPasteboard(entry.message)
        } label: {
            Label("Copy message", systemImage: "doc.on.doc")
        }
        if let stack = entry.stack {
            Button {
                copyToPasteboard(stack)
            } label: {
                Label("Copy stack", systemImage: "list.bullet.indent")
            }
        }
        Button {
            let ts = Self.timestampFormatter.string(from: entry.timestamp)
            var text = "[\(ts)] [\(entry.level)] \(entry.message)"
            if let stack = entry.stack {
                text += "\n" + stack
            }
            copyToPasteboard(text)
        } label: {
            Label("Copy entry", systemImage: "square.on.square")
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private var levelColor: Color {
        switch entry.level {
        case "ERROR": return .red
        case "WARN": return .orange
        default: return .secondary
        }
    }
}

// MARK: - Network Log Entry Row

@available(iOS 16.0, macOS 13.0, *)
private struct NetworkLogEntryRow: View {
    let entry: NetworkLogEntry
    let isExpanded: Bool

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Summary row
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .foregroundStyle(.secondary)
                    .frame(width: 85, alignment: .leading)

                Text(entry.method)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .frame(width: 36, alignment: .leading)

                Text(statusText)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)
                    .frame(width: 32, alignment: .trailing)

                if entry.durationMs >= 0 {
                    Text("\(entry.durationMs)ms")
                        .foregroundStyle(durationColor)
                        .frame(width: 52, alignment: .trailing)
                } else {
                    Text("?")
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                if entry.requestSize >= 0 {
                    Text(formatBytes(entry.requestSize))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                } else {
                    Text("-")
                        .foregroundStyle(.tertiary)
                        .frame(width: 52, alignment: .trailing)
                }

                if entry.responseSize >= 0 {
                    Text(formatBytes(entry.responseSize))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                } else {
                    Text("-")
                        .foregroundStyle(.tertiary)
                        .frame(width: 52, alignment: .trailing)
                }

                Text(shortURL)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            // Expanded detail panel
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // General
                    DetailSection(title: "General") {
                        DetailRow(label: "URL", value: entry.url)
                        DetailRow(label: "Method", value: entry.method)
                        DetailRow(label: "Status", value: entry.status == 0
                                  ? "Failed" : "\(entry.status) \(entry.statusText)")
                        if entry.durationMs >= 0 {
                            DetailRow(label: "Duration", value: "\(entry.durationMs)ms")
                        }
                        if entry.requestSize >= 0 {
                            DetailRow(label: "Request Size", value: formatBytes(entry.requestSize))
                        }
                        if entry.responseSize >= 0 {
                            DetailRow(label: "Response Size", value: formatBytes(entry.responseSize))
                        }
                        if let error = entry.error {
                            DetailRow(label: "Error", value: error, valueColor: .red)
                        }
                    }

                    // Request Headers
                    if !entry.requestHeaders.isEmpty {
                        DetailSection(title: "Request Headers") {
                            ForEach(entry.requestHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                DetailRow(label: key, value: value)
                            }
                        }
                    }

                    // Response Headers
                    if !entry.responseHeaders.isEmpty {
                        DetailSection(title: "Response Headers") {
                            ForEach(entry.responseHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                DetailRow(label: key, value: value)
                            }
                        }
                    }
                }
                .padding(.leading, 18)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 1)
    }

    private var statusText: String {
        entry.status == 0 ? "ERR" : "\(entry.status)"
    }

    private var statusColor: Color {
        if entry.status == 0 || entry.error != nil { return .red }
        if entry.status >= 400 { return .red }
        if entry.status >= 300 { return .orange }
        return .green
    }

    private var durationColor: Color {
        if entry.durationMs > 2000 { return .red }
        if entry.durationMs > 500 { return .orange }
        return .secondary
    }

    private var shortURL: String {
        guard let url = URL(string: entry.url) else { return entry.url }
        let path = url.path
        if path.isEmpty || path == "/" {
            return url.host ?? entry.url
        }
        return path + (url.query.map { "?\($0)" } ?? "")
    }
}

// MARK: - Detail Panel Components

@available(iOS 16.0, macOS 13.0, *)
private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
        }
        .font(.system(.caption2, design: .monospaced))
    }
}

// MARK: - Helpers

private func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes)B" }
    if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
    return String(format: "%.1fMB", Double(bytes) / (1024 * 1024))
}
