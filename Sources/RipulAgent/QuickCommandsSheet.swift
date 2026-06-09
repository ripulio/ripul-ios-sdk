import SwiftUI

// MARK: - Quick Commands Sheet

/// A sheet presenting available slash commands from the web app.
/// Pass `debugMode: true` to show hidden debug commands (triggered by `/rr.`).
@available(iOS 16.0, macOS 13.0, *)
public struct QuickCommandsSheet: View {
    @ObservedObject var bridge: AgentBridge
    var debugMode: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var commands: [SlashCommandInfo] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var showEvictConfirm = false
    @State private var evictStatus: String?
    @State private var isEvicting = false

    public init(bridge: AgentBridge, debugMode: Bool = false) {
        self.bridge = bridge
        self.debugMode = debugMode
    }

    private var filteredCommands: [SlashCommandInfo] {
        if searchText.isEmpty { return commands }
        let query = searchText.lowercased()
        return commands.filter {
            $0.command.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if commands.isEmpty && !debugMode {
                    if #available(iOS 17.0, macOS 14.0, *) {
                        ContentUnavailableView {
                            Label("No Commands", systemImage: "bolt.slash")
                        } description: {
                            Text("No slash commands available.")
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "bolt.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No slash commands available.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    List {
                        // Native debug tools (only in /rr. menu)
                        if debugMode {
                            Section("Native") {
                                NavigationLink {
                                    ConsoleLogViewer(bridge: bridge)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "terminal")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.tint)
                                            .frame(width: 28)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Console Logs")
                                                .font(.body)
                                                .fontWeight(.medium)
                                            Text("View JavaScript console output")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        let errorCount = bridge.consoleLogs.filter { $0.level == "ERROR" }.count
                                        if errorCount > 0 {
                                            Text("\(errorCount)")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.red, in: Capsule())
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }

                                NavigationLink {
                                    RelayHostStatsView(bridge: bridge)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "waveform.path.ecg")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.tint)
                                            .frame(width: 28)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Relay Host Stats")
                                                .font(.body)
                                                .fontWeight(.medium)
                                            Text("Live ping/pong + frame vs command diagnostics")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }

                                Button(role: .destructive) {
                                    showEvictConfirm = true
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "bolt.trianglebadge.exclamationmark")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.red)
                                            .frame(width: 28)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Evict Session DO")
                                                .font(.body)
                                                .fontWeight(.medium)
                                                .foregroundStyle(.red)
                                            Text(evictSubtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }

                                        Spacer()

                                        if isEvicting {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .disabled(isEvicting || bridge.activeSession?.sourceChatId == nil)
                            }
                        }

                        // Web-defined commands
                        if !filteredCommands.isEmpty {
                            Section(debugMode ? "Web" : "") {
                                ForEach(filteredCommands) { cmd in
                                    if cmd.options.isEmpty {
                                        CommandRow(command: cmd)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                Task { await bridge.submitMessage("/\(cmd.command)") }
                                                dismiss()
                                            }
                                    } else {
                                        NavigationLink {
                                            CommandOptionsView(
                                                command: cmd,
                                                onSelect: { value in
                                                    Task { await bridge.submitMessage("/\(cmd.command) \(value)") }
                                                    dismiss()
                                                }
                                            )
                                        } label: {
                                            CommandRow(command: cmd)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.plain)
                    #endif
                }
            }
            .searchable(text: $searchText, prompt: "Search commands")
            .navigationTitle(debugMode ? "Debug Commands" : "Quick Commands")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 360, height: 450)
        #endif
        .task {
            commands = await bridge.getSlashCommands(showHidden: debugMode)
            isLoading = false
        }
        .alert("Evict Session DO?", isPresented: $showEvictConfirm, presenting: bridge.activeSession?.sourceChatId) { chatId in
            Button("Evict", role: .destructive) {
                Task { await performEvict(chatId: chatId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { chatId in
            Text("Force-restart the SessionChannel DO for \(chatId.suffix(8)). Open clients will drop and reconnect.")
        }
        .alert("Eviction result", isPresented: Binding(get: { evictStatus != nil }, set: { if !$0 { evictStatus = nil } })) {
            Button("OK", role: .cancel) { evictStatus = nil }
        } message: {
            Text(evictStatus ?? "")
        }
    }

    private var evictSubtitle: String {
        if let chatId = bridge.activeSession?.sourceChatId {
            return "Force-restart DO for ...\(chatId.suffix(8))"
        }
        return "No active chat"
    }

    @MainActor
    private func performEvict(chatId: String) async {
        isEvicting = true
        defer { isEvicting = false }
        let result = await bridge.evictSessionChannel(chatId: chatId)
        if result.success {
            evictStatus = "Evicted DO for ...\(chatId.suffix(8)). Reconnect should pick up the new code."
        } else {
            evictStatus = "Failed: \(result.error ?? "unknown error")"
        }
    }
}

// MARK: - Debug Command Trigger

/// The prefix that triggers the debug commands sheet.
/// Type "/rr." into the chat input to activate.
public let debugCommandTrigger = "/rr."

// MARK: - Command Options View

@available(iOS 16.0, macOS 13.0, *)
private struct CommandOptionsView: View {
    let command: SlashCommandInfo
    let onSelect: (String) -> Void

    var body: some View {
        List(command.options) { option in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.body)
                    if let desc = option.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect(option.value) }
            .padding(.vertical, 2)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .listStyle(.plain)
        #endif
        .navigationTitle(command.command.prefix(1).uppercased() + command.command.dropFirst())
    }
}

// MARK: - Command Row

@available(iOS 16.0, macOS 13.0, *)
private struct CommandRow: View {
    let command: SlashCommandInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sfSymbol(for: command.icon))
                .font(.system(size: 16))
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(command.command.prefix(1).uppercased() + command.command.dropFirst())
                    .font(.body)
                    .fontWeight(.medium)

                Text(command.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if !command.options.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func sfSymbol(for faIcon: String?) -> String {
        guard let fa = faIcon else { return "terminal" }
        switch fa {
        case "fa-magnifying-glass-chart": return "magnifyingglass"
        case "fa-sitemap": return "map"
        case "fa-book": return "book"
        case "fa-asterisk": return "asterisk"
        case "fa-code": return "chevron.left.forwardslash.chevron.right"
        case "fa-camera": return "camera"
        case "fa-cloud-arrow-up": return "icloud.and.arrow.up"
        case "fa-wrench": return "wrench"
        case "fa-circle-question": return "questionmark.circle"
        case "fa-palette": return "paintpalette"
        case "fa-trash-can": return "trash"
        case "fa-layer-group": return "square.3.layers.3d"
        case "fa-rotate-right": return "arrow.clockwise"
        case "fa-flask": return "flask"
        case "fa-plug": return "link"
        case "fa-file-lines": return "doc.text"
        case "fa-bug": return "ant"
        case "fa-globe": return "globe"
        case "fa-gear": return "gear"
        case "fa-timeline": return "timeline.selection"
        case "fa-window-restore": return "macwindow"
        case "fa-database": return "cylinder"
        case "fa-arrows-rotate": return "arrow.triangle.2.circlepath"
        default: return "terminal"
        }
    }
}
