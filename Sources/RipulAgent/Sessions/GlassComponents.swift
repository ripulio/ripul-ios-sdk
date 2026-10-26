import SwiftUI

// Glass container components used by the session list. The app has its own
// copies of these (Shared/GlassComponents.swift) which stay until the M7 rewire;
// these are the SDK-owned versions the extracted session list compiles against.
// Names are chosen to not collide with the SDK's existing glass modifiers
// (GlassButton.swift / GlassMastheadView.swift).

// MARK: - Glass Section Panel

/// Collapsible container with a header row (chevron, title, optional chip
/// beside the title, optional subtitle, optional trailing actions) and a
/// content slot.
/// On iOS 26+ renders with `.glassEffect`; on older versions uses
/// `.ultraThinMaterial` with a rounded rect. Works on all iOS versions
/// so call sites don't need `if #available` branching.
public struct GlassSectionPanel<Content: View, Trailing: View, TitleAccessory: View, CollapsedAccessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    /// Right after the title: a small chip that belongs to it, such as a count
    /// of what is waiting that also filters the panel to those.
    let titleAccessory: TitleAccessory
    let trailing: Trailing
    /// Shown only while COLLAPSED. It rides the header row's trailing edge,
    /// with the subtitle truncating to make room, or left out when too little
    /// of it would show, so a closed panel is one row. Only when even the title
    /// can't sit beside it (a long set of circles, a very narrow window) does
    /// it take its own row beneath the header. On the header row it is inside
    /// the header's tap target, but Button hit-testing takes the tap over the
    /// header's onTapGesture, so using it never toggles the panel.
    let collapsedAccessory: CollapsedAccessory
    let content: Content
    /// A panel that is the screen's whole point has nothing to collapse FOR:
    /// closing it leaves a header and an empty screen. Such a panel keeps the
    /// glass and loses the chevron and the tap.
    var collapsible: Bool = true
    var followsContainerBottomCorners: Bool = false

    public init(
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>,
        collapsible: Bool = true,
        followsContainerBottomCorners: Bool = false,
        @ViewBuilder titleAccessory: () -> TitleAccessory = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder collapsedAccessory: () -> CollapsedAccessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self._isExpanded = isExpanded
        self.collapsible = collapsible
        self.followsContainerBottomCorners = followsContainerBottomCorners
        self.titleAccessory = titleAccessory()
        self.trailing = trailing()
        self.collapsedAccessory = collapsedAccessory()
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if CollapsedAccessory.self == EmptyView.self {
                header(accessory: nil)
            } else {
                // The first view is chosen whenever it fits, open or closed, so
                // the header keeps one identity and the chevron still turns.
                ViewThatFits(in: .horizontal) {
                    header(accessory: showsCollapsedAccessory ? collapsedAccessory : nil)
                    header(accessory: showsCollapsedAccessory ? collapsedAccessory : nil, showsSubtitle: false)
                    VStack(spacing: 0) {
                        header(accessory: nil)
                        if showsCollapsedAccessory {
                            collapsedAccessory
                                .padding(.horizontal, 16)
                                .padding(.bottom, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if isExpanded || !collapsible {
                VStack(spacing: 0) {
                    content
                }
                .padding(.bottom, 8)
            }
        }
        .modifier(GlassPanelBackground(followsContainerBottomCorners: followsContainerBottomCorners))
    }

    private var showsCollapsedAccessory: Bool { !isExpanded && collapsible }

    /// How much of the subtitle the one-row header keeps beside the accessory:
    /// "Studio", or the start of a list of names. Any less and the subtitle is
    /// left out rather than shown as an ellipsis.
    private static var subtitleReserve: CGFloat { 48 }

    private func header(accessory: CollapsedAccessory?, showsSubtitle: Bool = true) -> some View {
        HStack(spacing: 8) {
            if collapsible {
                Image(systemName: "chevron.right")
                    .font(.ripulIcon(.caption2, weight: .semibold)) // theme-mapping: unchanged, moved into header()
                    .foregroundStyle(.ripul(.textSecondary)) // theme-mapping: unchanged, moved into header()
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
            Text(title)
                .font(.ripul(.subheadline, weight: .semibold)) // theme-mapping: unchanged, moved into header()
                .foregroundStyle(.ripul(.textSecondary)) // theme-mapping: unchanged, moved into header()
                .textCase(.uppercase)
            titleAccessory
            if showsSubtitle, let subtitle, !subtitle.isEmpty, !isExpanded {
                let label = Text(subtitle)
                    .font(.ripul(.caption)) // theme-mapping: unchanged, moved into header()
                    .foregroundStyle(.ripul(.textTertiary)) // theme-mapping: unchanged, moved into header()
                    .lineLimit(1)
                    .truncationMode(.tail)
                if accessory != nil {
                    // ViewThatFits measures this row at its ideal width, which
                    // counts the subtitle at no more than the reserve, so a long
                    // subtitle truncates beside the accessory instead of pushing
                    // it onto its own row. Laid out, the frame is the text's own
                    // width, or the room that is left.
                    label.frame(minWidth: 0, idealWidth: Self.subtitleReserve, alignment: .leading)
                } else {
                    label
                }
            }
            Spacer(minLength: 8)
            trailing
            if let accessory {
                accessory
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
            guard collapsible else { return }
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
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
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.ripulIcon(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.ripul(.subheadline))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($isFocused)
                    .frame(minHeight: 22)
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                }
                .uiKitIdentifier("GlassSearchField.clearButton")
                .buttonStyle(.plain)
            }
        }
        // Hold the row at 22pt minimum so UIKitTextField attaching UIFieldEditor
        // on first focus (which recalculates intrinsic height for the custom
        // theme font from 22pt to 15-18pt) never shrinks the search pill vertically.
        .frame(minHeight: 22)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
        #if os(iOS)
        .background(SearchFieldTapAwayInstaller(isFocused: $isFocused))
        #endif
    }
}

#if os(iOS)
/// Window-level tap observer scoped to a single `GlassSearchField`. While this
/// search field is focused, a tap anywhere outside its pill ends editing and
/// lowers the keyboard without swallowing or delaying the touch.
private struct SearchFieldTapAwayInstaller: UIViewRepresentable {
    @FocusState.Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        context.coordinator.installerView = view
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        context.coordinator.installerView = uiView
        context.coordinator.isFocused = isFocused
        let unfocus: () -> Void = { isFocused = false }
        context.coordinator.onDismiss = unfocus
    }

    static func dismantleUIView(_ uiView: InstallerView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    final class InstallerView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var installerView: InstallerView?
        private weak var window: UIWindow?
        var isFocused: Bool = false
        var onDismiss: (() -> Void)?

        private lazy var recognizer: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            return tap
        }()

        func attach(to window: UIWindow?) {
            guard window !== self.window else { return }
            self.window?.removeGestureRecognizer(recognizer)
            self.window = window
            window?.addGestureRecognizer(recognizer)
        }

        @objc private func tapped() {
            onDismiss?()
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            window?.endEditing(true)
        }

        private func isOwnTextFieldEditing() -> Bool {
            if isFocused { return true }
            guard let installerView, let window = installerView.window,
                  let responder = Self.findFirstResponder(in: window) as? UITextField else {
                return false
            }
            let responderCenter = responder.convert( CGPoint(x: responder.bounds.midX, y: responder.bounds.midY), to: installerView)
            return installerView.bounds.insetBy(dx: -8, dy: -8).contains(responderCenter)
        }

        private static func findFirstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for subview in view.subviews {
                if let found = findFirstResponder(in: subview) { return found }
            }
            return nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard isOwnTextFieldEditing(), let installerView else { return false }
            // Taps inside the search pill itself (text field, clear button, icon)
            // are for interacting with the search field, not leaving it.
            let point = touch.location(in: installerView)
            if installerView.bounds.contains(point) { return false }
            // Taps into another text input let UIKit move first responder directly.
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif

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
                    .font(.ripulIcon(.caption2, weight: .semibold))
                Text(isSelecting ? "Cancel" : "Select").ripulText()
                    .font(.ripul(.caption, weight: .medium))
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

/// How a panel that is glass by default is drawn. Offered in the app's UX Settings and
/// kept in the standard defaults. Under a theme that names no `surface`, which is every
/// app that has not chosen one, `.automatic` is the clear glass every panel drew before
/// the choice existed.
public enum GlassPanelStyle: String, CaseIterable, Identifiable, Sendable {
    /// Tinted glass in dark mode and clear glass in light, where the theme names a
    /// `surface` to tint with; clear glass otherwise. Measured under paper and navy:
    /// clear glass lifts a dark panel's ground and costs a title a third of its contrast
    /// (10.0 to 1 against 15.0), and costs nothing in light.
    case automatic
    /// Clear glass: the ground shows through, lifted by the glass.
    case glass
    /// Glass carrying the theme's `surface`, so text stands on the card's own colour.
    case tintedGlass
    /// The theme's `surface` with no glass, as a grouped list's rows are drawn.
    case solid

    public static let defaultsKey = "ripul.panelStyle"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .glass: "Glass"
        case .tintedGlass: "Tinted Glass"
        case .solid: "Solid Card"
        }
    }

    /// How much of the theme's `surface` a tinted panel carries.
    static let tintOpacity = 0.85

    /// The style to draw: this one, or what `.automatic` stands for now.
    func resolved(dark: Bool) -> GlassPanelStyle {
        guard self == .automatic else { return self }
        return dark && !RipulTheme.isDefault(.surface) ? .tintedGlass : .glass
    }
}

public struct GlassPanelBackground: ViewModifier {
    var followsContainerBottomCorners: Bool
    @AppStorage(GlassPanelStyle.defaultsKey) private var chosen = GlassPanelStyle.automatic
    @Environment(\.colorScheme) private var colorScheme

    public init(followsContainerBottomCorners: Bool = false) {
        self.followsContainerBottomCorners = followsContainerBottomCorners
    }
    public func body(content: Content) -> some View {
        let style = chosen.resolved(dark: colorScheme == .dark)
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if followsContainerBottomCorners, SessionsPanelLayout.hasConcentricShapes {
                // Only the screen-bottom panel follows the display. Its top
                // stays rounded, and corners away from a display edge (split
                // columns, sheets) retain a 16pt minimum instead of squaring off.
                // AnyView, so this body's type doesn't name ConcentricRectangle:
                // SwiftUI resolves a body's whole type whichever branch runs,
                // and on a 26.0 beta that type is missing (see hasConcentricShapes).
                let shape = SessionsPanelLayout.shape
                switch style {
                case .glass, .automatic:
                    AnyView(content.clipShape(shape).glassEffect(.clear, in: shape))
                case .tintedGlass:
                    AnyView(content.clipShape(shape).glassEffect(.clear.tint(Self.tint), in: shape))
                case .solid:
                    AnyView(content.clipShape(shape).background { shape.fill(Self.card) })
                }
            } else {
                switch style {
                case .glass, .automatic:
                    content.glassEffect(.clear, in: .rect(cornerRadius: 16))
                case .tintedGlass:
                    content.glassEffect(.clear.tint(Self.tint), in: .rect(cornerRadius: 16))
                case .solid:
                    content.background(Self.card, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        } else {
            switch style {
            case .glass, .automatic:
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            case .tintedGlass:
                content
                    .background(Self.tint, in: RoundedRectangle(cornerRadius: 16))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            case .solid:
                content
                    .background(Self.card, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        #else
        if #available(macOS 26.0, *) {
            switch style {
            case .glass, .automatic:
                content
                    .background(.clear)
                    .glassEffect(.clear, in: .rect(cornerRadius: 16))
            case .tintedGlass:
                content
                    .background(.clear)
                    .glassEffect(.clear.tint(Self.tint), in: .rect(cornerRadius: 16))
            case .solid:
                content
                    .background(Self.card, in: RoundedRectangle(cornerRadius: 16))
            }
        } else {
            switch style {
            case .glass, .automatic:
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            case .tintedGlass:
                content
                    .background(Self.tint, in: RoundedRectangle(cornerRadius: 16))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            case .solid:
                content
                    .background(Self.card, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        #endif
    }

    /// The card a solid panel stands on, and the colour a tinted one carries.
    private static var card: Color { Color.ripul(.surface) } // theme-mapping: new with the panel styles; a glass panel draws no colour of its own
    private static var tint: Color { card.opacity(GlassPanelStyle.tintOpacity) }
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
        case "swift": return .orange  // theme-exempt: a file type's colour is data
        case "js", "jsx": return .yellow  // theme-exempt: a file type's colour is data
        case "ts", "tsx": return .blue  // theme-exempt: a file type's colour is data
        case "py": return .green  // theme-exempt: a file type's colour is data
        case "json": return .yellow  // theme-exempt: a file type's colour is data
        case "yaml", "yml", "toml": return .purple  // theme-exempt: a file type's colour is data
        case "md", "txt", "rtf": return .gray  // theme-exempt: a file type's colour is data
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return .pink  // theme-exempt: a file type's colour is data
        case "css", "scss", "less": return .cyan  // theme-exempt: a file type's colour is data
        case "html": return .orange  // theme-exempt: a file type's colour is data
        case "sh", "bash", "zsh": return .green  // theme-exempt: a file type's colour is data
        default: return .secondary  // theme-exempt: a file type's colour is data
        }
    }

    private static func pathExtension(_ path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }
}
