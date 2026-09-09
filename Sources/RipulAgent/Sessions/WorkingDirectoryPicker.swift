import SwiftUI

/// Picker for a session's working directory, rendered as a real list rather
/// than a submenu.
///
/// It used to be a nested `Menu`, which meant every row was a single flat line
/// of `/Users/someone/Documents/repos/<repo>` — identical for the first forty
/// characters, truncated before the part that differs. A menu cannot be fixed
/// in place: `UIMenu`/`NSMenu` take a title and an image from each row and
/// discard custom layout and fonts. So the submenu became a sheet, the same
/// move `ModelPickerSheetContent` made for the model list and for the same
/// reason — the choice needed more than a menu row can show.
///
/// Rows use `DirectoryPathLabel`: parent path small above, repo name large and
/// bold below.
public struct WorkingDirectoryPicker: View {
    let title: String
    let explanation: String?
    /// Selectable directories, in the order the host reports them.
    let directories: [String]
    /// The directory currently in effect, or `nil` when the session is on the
    /// host default.
    let selection: String?
    /// Where "Default" actually resolves to, shown beneath it when known.
    let defaultPath: String?
    let identifierPrefix: String
    /// Presented as a trailing "Browse…" row when the platform can offer a file
    /// picker (macOS); omitted otherwise.
    let onBrowse: (() -> Void)?
    /// `nil` selects the host default.
    let isLoading: Bool
    let error: String?
    let onRetry: (() -> Void)?
    let dismissOnPick: Bool
    let onPick: (String?) -> Void
    let onDismiss: () -> Void

    public init(
        title: String = "Working Directory",
        explanation: String? = nil,
        directories: [String],
        selection: String?,
        defaultPath: String? = nil,
        identifierPrefix: String,
        onBrowse: (() -> Void)? = nil,
        isLoading: Bool = false,
        error: String? = nil,
        onRetry: (() -> Void)? = nil,
        dismissOnPick: Bool = true,
        onPick: @escaping (String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.explanation = explanation
        self.directories = directories
        self.selection = selection
        self.defaultPath = defaultPath
        self.identifierPrefix = identifierPrefix
        self.onBrowse = onBrowse
        self.isLoading = isLoading
        self.error = error
        self.onRetry = onRetry
        self.dismissOnPick = dismissOnPick
        self.onPick = onPick
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            List {
                if let explanation {
                    Section { Text(explanation).font(.footnote).foregroundStyle(.secondary) }
                }
                if isLoading {
                    Section { ProgressView("Loading directories…") }
                } else if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        if let onRetry { Button("Retry", action: onRetry) }
                    }
                } else {
                    Section { defaultRow }
                }

                if directories.isEmpty && !isLoading && error == nil {
                    Section {
                        Text("No favourite directories yet. Add them in the host's CLI settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .uiKitIdentifier("\(identifierPrefix).emptyState")
                    }
                } else if !isLoading && error == nil {
                    Section {
                        ForEach(directories, id: \.self) { dir in
                            directoryRow(dir)
                        }
                    } header: {
                        Text("Favourites")
                    }
                }

                if let onBrowse {
                    Section {
                        Button {
                            onBrowse()
                        } label: {
                            Label("Browse…", systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                        .uiKitIdentifier("\(identifierPrefix).browseButton")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                        .uiKitIdentifier("\(identifierPrefix).doneButton")
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        // A macOS sheet sizes to its content's minimum, which for a List of
        // short rows is unreadably narrow.
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }

    private var defaultRow: some View {
        Button {
            onPick(nil)
        } label: {
            HStack(spacing: 12) {
                icon("house")
                VStack(alignment: .leading, spacing: 1) {
                    if let defaultPath, !defaultPath.isEmpty {
                        Text(DirectoryPathDisplay.parse(defaultPath).joined)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Text("Default")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                checkmark(isSelected: selection == nil)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uiKitIdentifier("\(identifierPrefix).defaultRow")
    }

    private func directoryRow(_ dir: String) -> some View {
        Button {
            onPick(dir)
        } label: {
            HStack(spacing: 12) {
                icon("folder")
                DirectoryPathLabel(path: dir)
                checkmark(isSelected: selection == dir)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Keyed by the full path, as ModelPicker keys its rows by model id —
        // the actuation tools need one identifier per row, and two repos can
        // share a last path component.
        .uiKitIdentifier("\(identifierPrefix).directoryRow.\(dir)")
    }

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 20)
    }

    @ViewBuilder
    private func checkmark(isSelected: Bool) -> some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
        }
    }
}

// MARK: - Presentation

/// Presents `WorkingDirectoryPicker` as a sheet.
///
/// Packaged as a `ViewModifier` and applied with `.modifier(…)` rather than as
/// an inline `.sheet` because the screens that host it (`RipulAgentScreen`,
/// the macOS `AgentScreen`) have modifier chains already at the Swift type
/// checker's limit — one more inline trailing closure there fails the iOS build
/// outright. Same reason `CatalystMetadataPane` is shaped this way.
public struct WorkingDirectoryPickerSheet: ViewModifier {
    @Binding var isPresented: Bool
    let directories: [String]
    let selection: String?
    let defaultPath: String?
    let identifierPrefix: String
    let onBrowse: (() -> Void)?
    let isLoading: Bool
    let error: String?
    let onRetry: (() -> Void)?
    let dismissOnPick: Bool
    let onPick: (String?) -> Void

    public init(
        isPresented: Binding<Bool>,
        directories: [String],
        selection: String?,
        defaultPath: String? = nil,
        identifierPrefix: String,
        onBrowse: (() -> Void)? = nil,
        isLoading: Bool = false,
        error: String? = nil,
        onRetry: (() -> Void)? = nil,
        dismissOnPick: Bool = true,
        onPick: @escaping (String?) -> Void
    ) {
        self._isPresented = isPresented
        self.directories = directories
        self.selection = selection
        self.defaultPath = defaultPath
        self.identifierPrefix = identifierPrefix
        self.onBrowse = onBrowse
        self.isLoading = isLoading
        self.error = error
        self.onRetry = onRetry
        self.dismissOnPick = dismissOnPick
        self.onPick = onPick
    }

    public func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) { picker }
    }

    private var picker: some View {
        WorkingDirectoryPicker(
            directories: directories,
            selection: selection,
            defaultPath: defaultPath,
            identifierPrefix: identifierPrefix,
            onBrowse: onBrowse.map { browse in { isPresented = false; browse() } },
            isLoading: isLoading,
            error: error,
            onRetry: onRetry,
            onPick: { picked in
                if dismissOnPick { isPresented = false }
                onPick(picked)
            },
            onDismiss: { isPresented = false }
        )
    }
}
