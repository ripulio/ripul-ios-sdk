#if os(iOS)
import SwiftUI

// Ported verbatim from the native app (`iOS/FolderTreeSection.swift`) — the
// session list's Folders panel. Rendered BY DEFAULT by GlassSessionsList on
// iOS when the host doesn't inject `foldersSection` (that slot exists for
// hosts that need a custom panel).

// MARK: - Entry model

/// A single file or directory entry in the folder tree.
private struct TreeEntry: Identifiable {
    let path: String
    let name: String
    let isDirectory: Bool
    var id: String { path }

    init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        self.name = trimmed.components(separatedBy: "/").last ?? path
    }
}

// MARK: - View Model

/// Manages lazy-loaded folder tree state independently of SwiftUI view body.
@MainActor
private final class FolderTreeModel: ObservableObject {
    @Published var rootPath: String?
    @Published var rootEntries: [TreeEntry] = []
    @Published var rootLoading = false
    @Published var rootError: String?

    @Published var childEntries: [String: [TreeEntry]] = [:]
    @Published var expandedDirs: Set<String> = []
    @Published var loadingDirs: Set<String> = []

    /// The directory argument of the most recent `loadRoot` ("." or an absolute
    /// project path). Used to avoid redundant reloads and to detect when the
    /// project filter has changed the desired root.
    @Published var loadedPath: String?

    /// Bumped on every `loadRoot` so a superseded in-flight load (the user
    /// switched projects mid-fetch) discards its stale result.
    private var loadGeneration = 0

    weak var bridge: AgentBridge?

    /// Load `path` as the tree root, resetting any previously expanded state.
    /// Pass "." for the host's default working directory, or an absolute path
    /// to re-root onto a specific project.
    func loadRoot(path: String = ".") {
        guard let bridge else { return }
        loadGeneration += 1
        let gen = loadGeneration
        loadedPath = path
        rootLoading = true
        rootError = nil
        rootEntries = []
        childEntries = [:]
        expandedDirs = []
        loadingDirs = []
        Task {
            let result = await bridge.listRemoteDirectory(path: path)
            guard gen == loadGeneration else { return } // superseded by a newer load
            rootLoading = false
            if let error = result.error {
                rootError = error
                return
            }
            var root = path
            // For ".", resolve the absolute root from the first entry's parent.
            if path == ".", let first = result.entries.first,
               let lastSlash = first.path.lastIndex(of: "/"),
               lastSlash > first.path.startIndex {
                root = String(first.path[first.path.startIndex..<lastSlash])
            }
            rootPath = root
            rootEntries = Self.sorted(result.entries.map { TreeEntry(path: $0.path, isDirectory: $0.isDirectory) })
        }
    }

    func toggle(_ path: String) {
        if expandedDirs.contains(path) {
            expandedDirs.remove(path)
        } else {
            expandedDirs.insert(path)
            if childEntries[path] == nil {
                loadDir(path)
            }
        }
    }

    func loadDir(_ path: String) {
        guard let bridge else { return }
        loadingDirs.insert(path)
        Task {
            let result = await bridge.listRemoteDirectory(path: path)
            loadingDirs.remove(path)
            if result.error == nil {
                childEntries[path] = Self.sorted(result.entries.map { TreeEntry(path: $0.path, isDirectory: $0.isDirectory) })
            }
        }
    }

    private static func sorted(_ entries: [TreeEntry]) -> [TreeEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Section View

/// Inline folder tree browser for the sessions screen, wrapped in a
/// `GlassSectionPanel`. Lazily loads directories via `AgentBridge.listRemoteDirectory`.
public struct FolderTreeSection: View {
    public init(
        bridge: AgentBridge,
        isExpanded: Binding<Bool>,
        rootPathOverride: String? = nil,
        onFileOpened: (() -> Void)? = nil
    ) {
        self.bridge = bridge
        self._isExpanded = isExpanded
        self.rootPathOverride = rootPathOverride
        self.onFileOpened = onFileOpened
    }

    let bridge: AgentBridge
    @Binding var isExpanded: Bool
    /// When set, the tree re-roots onto this absolute path (the selected
    /// project's working directory). Nil falls back to the host default cwd.
    var rootPathOverride: String? = nil
    var onFileOpened: (() -> Void)? = nil
    @StateObject private var model = FolderTreeModel()

    private var desiredRoot: String { rootPathOverride ?? "." }

    public var body: some View {
        let title = model.rootPath.map { dirName($0) } ?? "Folders"
        GlassSectionPanel(title: title, subtitle: model.rootPath, isExpanded: $isExpanded) {
            content
        }
        .onAppear {
            model.bridge = bridge
        }
        .onChange(of: isExpanded) { _, expanded in
            // Lazy first load when the panel opens.
            if expanded && model.loadedPath == nil && !model.rootLoading {
                model.loadRoot(path: desiredRoot)
            }
        }
        .onChange(of: rootPathOverride) { _, _ in
            // Project filter changed — re-root if we've already loaded once
            // (the lazy first load is handled by the isExpanded change above).
            if model.loadedPath != nil && model.loadedPath != desiredRoot {
                model.loadRoot(path: desiredRoot)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.rootLoading && model.rootPath == nil {
            loadingRow
        } else if let error = model.rootError {
            errorRow(error)
        } else if model.rootPath != nil {
            ScrollView {
                VStack(spacing: 0) {
                    entriesList(model.rootEntries, depth: 0)
                }
            }
            .frame(maxHeight: 320)
        } else {
            emptyRow
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text("Loading...").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { model.loadRoot(path: desiredRoot) }
    }

    private var emptyRow: some View {
        Text("No working directory available.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    @ViewBuilder
    private func entriesList(_ entries: [TreeEntry], depth: Int) -> some View {
        ForEach(entries) { entry in
            FolderTreeRow(entry: entry, depth: depth, model: model, bridge: bridge, onFileOpened: onFileOpened)
        }
    }

    private func dirName(_ path: String) -> String {
        if path == "." || path == "/" { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.components(separatedBy: "/").last ?? path
    }
}

// MARK: - Row View

/// A single row in the folder tree — extracted to keep type-checker complexity low.
private struct FolderTreeRow: View {
    let entry: TreeEntry
    let depth: Int
    @ObservedObject var model: FolderTreeModel
    let bridge: AgentBridge
    var onFileOpened: (() -> Void)? = nil

    private var isExpanded: Bool { model.expandedDirs.contains(entry.path) }
    private var isLoading: Bool { model.loadingDirs.contains(entry.path) }

    var body: some View {
        VStack(spacing: 0) {
            rowButton
            if entry.isDirectory && isExpanded {
                childRows
            }
        }
    }

    private var rowButton: some View {
        Button {
            if entry.isDirectory {
                model.toggle(entry.path)
            } else {
                bridge.fileViewerReturnToSessions = true
                bridge.openFavoriteFile(entry.path)
                onFileOpened?()
            }
        } label: {
            HStack(spacing: 4) {
                chevron
                icon
                Text(entry.name)
                    .font(.system(size: 15, weight: entry.isDirectory ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if entry.isDirectory && isLoading {
                    ProgressView().scaleEffect(0.5)
                }
            }
            .padding(.leading, CGFloat(12 + depth * 20))
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var chevron: some View {
        if entry.isDirectory {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.15), value: isExpanded)
                .frame(width: 16)
        } else {
            Spacer().frame(width: 16)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if entry.isDirectory {
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 15))
                .foregroundStyle(.blue)
                .frame(width: 20)
        } else {
            Image(systemName: FileTypeIcon.icon(for: entry.path))
                .font(.system(size: 15))
                .foregroundStyle(FileTypeIcon.color(for: entry.path))
                .frame(width: 20)
        }
    }

    @ViewBuilder
    private var childRows: some View {
        if let children = model.childEntries[entry.path] {
            ForEach(children) { child in
                FolderTreeRow(entry: child, depth: depth + 1, model: model, bridge: bridge, onFileOpened: onFileOpened)
            }
        }
    }
}
#endif
