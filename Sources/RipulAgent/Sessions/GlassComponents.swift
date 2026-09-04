import SwiftUI

// Glass container components used by the session list. The app has its own
// copies of these (Shared/GlassComponents.swift) which stay until the M7 rewire;
// these are the SDK-owned versions the extracted session list compiles against.
// Names are chosen to not collide with the SDK's existing glass modifiers
// (GlassButton.swift / GlassMastheadView.swift).

// MARK: - Glass Section Panel

/// Collapsible container with a header row (chevron, title, optional
/// subtitle, optional trailing actions) and a content slot.
/// On iOS 26+ renders with `.glassEffect`; on older versions uses
/// `.ultraThinMaterial` with a rounded rect. Works on all iOS versions
/// so call sites don't need `if #available` branching.
public struct GlassSectionPanel<Content: View, Trailing: View, Center: View, CollapsedAccessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    let center: Center
    let trailing: Trailing
    /// Rendered on its own row beneath the header while COLLAPSED. Use this for
    /// controls that are too wide or too numerous to sit in `trailing` without
    /// squeezing the title — it sits outside the header's tap target, so
    /// tapping it doesn't toggle the panel.
    let collapsedAccessory: CollapsedAccessory
    let content: Content

    public init(
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder center: () -> Center = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder collapsedAccessory: () -> CollapsedAccessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self._isExpanded = isExpanded
        self.center = center()
        self.trailing = trailing()
        self.collapsedAccessory = collapsedAccessory()
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let subtitle, !subtitle.isEmpty, !isExpanded {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                center
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                #if os(iOS)
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                #endif
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }

            if !isExpanded {
                collapsedAccessory
            }

            if isExpanded {
                VStack(spacing: 0) {
                    content
                }
                .padding(.bottom, 8)
            }
        }
        .modifier(GlassPanelBackground())
    }
}

// MARK: - Glass Search Field

/// Search text field with magnifying glass icon, clear button, and
/// material background.
public struct GlassSearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    public init(_ placeholder: String = "Search", text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($isFocused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .uiKitIdentifier("GlassSearchField.clearButton")
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
    }
}

// MARK: - Glass Select Button

/// Small pill button for toggling selection mode.
public struct GlassSelectButton: View {
    let isSelecting: Bool
    let action: () -> Void

    public init(isSelecting: Bool, action: @escaping () -> Void) {
        self.isSelecting = isSelecting
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSelecting ? "xmark" : "checkmark.circle")
                    .font(.caption2.weight(.semibold))
                Text(isSelecting ? "Cancel" : "Select")
                    .font(.caption.weight(.medium))
            }
            .textCase(nil)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .modifier(GlassCapsuleBackground())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Background modifiers

public struct GlassPanelBackground: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear, in: .rect(cornerRadius: 16))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        #else
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear, in: .rect(cornerRadius: 16))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        #endif
    }
}

public struct GlassCapsuleBackground: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
        #else
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
        #endif
    }
}

// MARK: - Glass List Section (ported from native Shared/GlassComponents.swift for M8)

/// Expandable glass panel hosting a List of rows — used by the metadata
/// panel's Files/Deployments/Participants sections.
public struct GlassListSection<Data: RandomAccessCollection, ID: Hashable, RowContent: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    let data: Data
    let id: KeyPath<Data.Element, ID>
    var searchPlaceholder: String? = nil
    var searchText: Binding<String>? = nil
    var scrollable: Bool = false
    var maxVisibleItems: Int? = nil
    var onRefresh: (() async -> Void)? = nil
    /// Supplying this turns on drag-to-reorder. Offsets are into `data` as
    /// given, so a caller that filters or searches its collection must either
    /// pass `nil` while a query is active or map the offsets back itself.
    var onMove: ((IndexSet, Int) -> Void)? = nil
    /// Per-row veto for reordering — rows answering `true` won't lift. Lets a
    /// partly-reorderable list (a pinned prefix followed by a read-only tail)
    /// refuse the drag up front rather than animating it and snapping back.
    var moveDisabled: ((Data.Element) -> Bool)? = nil
    let trailing: Trailing
    let rowContent: (Data.Element) -> RowContent

    /// Approximate height per row (content padding + divider).
    private let rowHeight: CGFloat = 44

    public init(
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>,
        data: Data,
        id: KeyPath<Data.Element, ID>,
        searchPlaceholder: String? = nil,
        searchText: Binding<String>? = nil,
        scrollable: Bool = false,
        maxVisibleItems: Int? = nil,
        onRefresh: (() async -> Void)? = nil,
        onMove: ((IndexSet, Int) -> Void)? = nil,
        moveDisabled: ((Data.Element) -> Bool)? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder row: @escaping (Data.Element) -> RowContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self._isExpanded = isExpanded
        self.data = data
        self.id = id
        self.searchPlaceholder = searchPlaceholder
        self.searchText = searchText
        self.scrollable = scrollable
        self.maxVisibleItems = maxVisibleItems
        self.onRefresh = onRefresh
        self.onMove = onMove
        self.moveDisabled = moveDisabled
        self.trailing = trailing()
        self.rowContent = row
    }

    private var needsScroll: Bool {
        if let max = maxVisibleItems, data.count > max { return true }
        return scrollable
    }

    public var body: some View {
        let panel = GlassSectionPanel(title: title, subtitle: subtitle ?? "\(data.count)", isExpanded: $isExpanded, trailing: { trailing }) {
            if let searchText, let placeholder = searchPlaceholder {
                GlassSearchField(placeholder, text: searchText)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }

            let items = Array(data)
            let list = List {
                // `onMove` is attached unconditionally so the ForEach keeps one
                // concrete type (wrapping it in _ConditionalContent stops List
                // recognising it as reorderable). Sections that didn't ask for
                // reordering disable every row instead, which is inert.
                ForEach(items, id: id) { item in
                    rowContent(item)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.visible)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 44 }
                        .listRowBackground(Color.clear)
                        .moveDisabled(onMove == nil || moveDisabled?(item) == true)
                }
                .onMove { offsets, destination in onMove?(offsets, destination) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)

            if needsScroll {
                if let max = maxVisibleItems {
                    if let onRefresh {
                        list.frame(height: CGFloat(min(data.count, max)) * rowHeight)
                            .refreshable { await onRefresh() }
                    } else {
                        list.frame(height: CGFloat(min(data.count, max)) * rowHeight)
                    }
                } else {
                    if let onRefresh {
                        list.refreshable { await onRefresh() }
                    } else {
                        list
                    }
                }
            } else {
                list.frame(height: CGFloat(items.count) * rowHeight)
            }
        }

        if scrollable {
            panel.frame(maxHeight: .infinity, alignment: .top)
        } else {
            panel
        }
    }
}

// Convenience for Identifiable data (no explicit id: needed)
public extension GlassListSection where ID == Data.Element.ID, Data.Element: Identifiable {
    public init(
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>,
        data: Data,
        searchPlaceholder: String? = nil,
        searchText: Binding<String>? = nil,
        scrollable: Bool = false,
        maxVisibleItems: Int? = nil,
        onRefresh: (() async -> Void)? = nil,
        onMove: ((IndexSet, Int) -> Void)? = nil,
        moveDisabled: ((Data.Element) -> Bool)? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder row: @escaping (Data.Element) -> RowContent
    ) {
        self.init(title: title, subtitle: subtitle, isExpanded: isExpanded, data: data, id: \.id, searchPlaceholder: searchPlaceholder, searchText: searchText, scrollable: scrollable, maxVisibleItems: maxVisibleItems, onRefresh: onRefresh, onMove: onMove, moveDisabled: moveDisabled, trailing: trailing, row: row)
    }
}

// MARK: - File Type Icons (ported from native Shared/GlassComponents.swift for M8)

/// Shared SF Symbol name and colour for file extensions, used in FilesScreen and CommitsScreen.
public enum FileTypeIcon {
    public static func icon(for path: String) -> String {
        let ext = pathExtension(path)
        switch ext {
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "chevron.left.forwardslash.chevron.right"
        case "py": return "text.word.spacing"
        case "json", "yaml", "yml", "toml": return "doc.text"
        case "md", "txt", "rtf": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "css", "scss", "less": return "paintbrush"
        case "html": return "globe"
        case "sh", "bash", "zsh": return "terminal"
        default: return "doc"
        }
    }

    public static func color(for path: String) -> Color {
        let ext = pathExtension(path)
        switch ext {
        case "swift": return .orange
        case "js", "jsx": return .yellow
        case "ts", "tsx": return .blue
        case "py": return .green
        case "json": return .yellow
        case "yaml", "yml", "toml": return .purple
        case "md", "txt", "rtf": return .gray
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return .pink
        case "css", "scss", "less": return .cyan
        case "html": return .orange
        case "sh", "bash", "zsh": return .green
        default: return .secondary
        }
    }

    private static func pathExtension(_ path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }
}
