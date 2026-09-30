import SwiftUI

// MARK: - Remote folder picker
//
// Browse a paired Mac's folders from the phone (via
// `AgentBridge.listRemoteDirectory`) and pick one with a toolbar button.
// Shared by the Files screen ("Pin Folder", "Use This Folder"), Host
// Settings (working directory, favourites) and New Chat (its folder).

/// Root picker shown inside the "Pin Folder" sheet.
public struct RemoteFolderRootsView: View {
    var bridge: AgentBridge
    let machineId: String
    var actionTitle: String = "Pin Folder"
    let onPin: (String) -> Void

    public init(bridge: AgentBridge, machineId: String, actionTitle: String = "Pin Folder", onPin: @escaping (String) -> Void) {
        self.bridge = bridge; self.machineId = machineId; self.actionTitle = actionTitle; self.onPin = onPin
    }

    public var body: some View {
        List {
            Section {
                NavigationLink {
                    RemoteFolderBrowserView(bridge: bridge, machineId: machineId, path: "~", actionTitle: actionTitle, onPin: onPin)
                } label: {
                    rootRow(icon: "house.fill", title: "Home", subtitle: "~")
                }
                .accessibilityIdentifier("RemoteFolder.home")
                NavigationLink {
                    RemoteFolderBrowserView(bridge: bridge, machineId: machineId, path: "/", actionTitle: actionTitle, onPin: onPin)
                } label: {
                    rootRow(icon: "externaldrive.fill", title: "Root", subtitle: "/")
                }
                .accessibilityIdentifier("RemoteFolder.root")
            } header: {
                Text("Start browsing from")
            } footer: {
                Text("Navigate into a folder, then tap \(actionTitle) at the top.")
            }
        }
    }

    private func rootRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).fontWeight(.medium)
                Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

public struct RemoteFolderBrowserView: View {
    var bridge: AgentBridge
    let machineId: String
    let path: String
    var actionTitle: String = "Pin Folder"
    let onPin: (String) -> Void
    var onOpenFile: ((String) -> Void)? = nil

    public init(bridge: AgentBridge, machineId: String, path: String, actionTitle: String = "Pin Folder",
                onPin: @escaping (String) -> Void, onOpenFile: ((String) -> Void)? = nil) {
        self.bridge = bridge; self.machineId = machineId; self.path = path
        self.actionTitle = actionTitle; self.onPin = onPin; self.onOpenFile = onOpenFile
    }

    @State private var entries: [(path: String, isDirectory: Bool)] = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State private var resolvedPath: String = ""

    public var body: some View {
        List {
            Section {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if let errorMessage, entries.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.tertiary)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else if entries.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No sub-folders")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    ForEach(folders, id: \.path) { folder in
                        NavigationLink {
                            RemoteFolderBrowserView(bridge: bridge, machineId: machineId, path: folder.path, actionTitle: actionTitle, onPin: onPin, onOpenFile: onOpenFile)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)
                                Text((folder.path as NSString).lastPathComponent)
                                    .font(.body)
                                    .lineLimit(1)
                            }
                        }
                        // Keyed by name: unique within one listing, and what a
                        // test or an agent navigating by path already knows.
                        .accessibilityIdentifier("RemoteFolder.folder.\((folder.path as NSString).lastPathComponent)")
                    }
                    if let onOpenFile {
                        ForEach(entries.filter { !$0.isDirectory }, id: \.path) { file in
                            Button { onOpenFile(file.path) } label: {
                                Label((file.path as NSString).lastPathComponent, systemImage: FileTypeIcon.icon(for: file.path))
                            }
                        }
                    }
                }
            } header: {
                Text(resolvedPath.isEmpty ? path : resolvedPath)
                    .font(.caption2.monospaced())
                    .textCase(nil)
            }
        }
        .navigationTitle(displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onPin(pinTarget)
                } label: {
                    Text(actionTitle)
                }
                .accessibilityIdentifier("RemoteFolder.action")
            }
        }
        .task(id: path) { await load() }
    }

    private var folders: [(path: String, isDirectory: Bool)] {
        entries.filter { $0.isDirectory }
    }

    private var displayTitle: String {
        let candidate = resolvedPath.isEmpty ? path : resolvedPath
        let trimmed = candidate.hasSuffix("/") && candidate.count > 1
            ? String(candidate.dropLast())
            : candidate
        let name = (trimmed as NSString).lastPathComponent
        if name.isEmpty { return path == "/" ? "/" : path }
        return name
    }

    private var pinTarget: String {
        resolvedPath.isEmpty ? path : resolvedPath
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        let result = await bridge.listRemoteDirectory(path: path, machineId: machineId)
        if let first = result.entries.first {
            let parent = (first.path as NSString).deletingLastPathComponent
            if !parent.isEmpty { resolvedPath = parent }
        }
        entries = result.entries
        errorMessage = result.error
        isLoading = false
    }
}

/// The picker in a sheet of its own: browse, pick, close. For screens where
/// the folder is one field among others (Host Settings, New Chat).
public struct RemoteFolderBrowseSheet: View {
    var bridge: AgentBridge
    let machineId: String
    let actionTitle: String
    let identifierPrefix: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(bridge: AgentBridge, machineId: String, actionTitle: String, identifierPrefix: String,
                onPick: @escaping (String) -> Void) {
        self.bridge = bridge; self.machineId = machineId; self.actionTitle = actionTitle
        self.identifierPrefix = identifierPrefix; self.onPick = onPick
    }

    public var body: some View {
        NavigationStack {
            RemoteFolderRootsView(bridge: bridge, machineId: machineId, actionTitle: actionTitle) { path in
                onPick(path)
                dismiss()
            }
            .navigationTitle("Choose Folder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.uiKitIdentifier("\(identifierPrefix).cancel") } }
        }
        .ripulSheet(.page, detents: [.large])
    }
}
