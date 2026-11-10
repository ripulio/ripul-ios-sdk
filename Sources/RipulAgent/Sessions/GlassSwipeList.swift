import SwiftUI

// MARK: - Swipe actions, shared by every list (GlassListSection, GlassSwipeList)

/// One button a row shows when it is swiped: the system's own swipe action.
public struct GlassSwipeAction: Identifiable {
    public let id: String
    public let label: String
    public let systemImage: String?
    public let tint: Color
    /// Destructive: said so to VoiceOver. The row isn't removed by the system;
    /// the action decides (it may ask first), and the data refetch removes it.
    public let destructive: Bool
    public let run: () -> Void

    public init(id: String, label: String, systemImage: String? = nil, tint: Color, destructive: Bool = false, run: @escaping () -> Void) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.destructive = destructive
        self.run = run
    }
}

/// A row's swipe actions: the leading set (swipe right) and the trailing set
/// (swipe left), each listed from the row's edge inwards, and whether a full
/// swipe runs a set's first action.
public struct GlassSwipeSet {
    public var leading: [GlassSwipeAction]
    public var trailing: [GlassSwipeAction]
    public var fullSwipeLeading: Bool
    public var fullSwipeTrailing: Bool

    public init(leading: [GlassSwipeAction] = [], trailing: [GlassSwipeAction] = [], fullSwipeLeading: Bool = false, fullSwipeTrailing: Bool = false) {
        self.leading = leading
        self.trailing = trailing
        self.fullSwipeLeading = fullSwipeLeading
        self.fullSwipeTrailing = fullSwipeTrailing
    }

    public static let none = GlassSwipeSet()
    public var isEmpty: Bool { leading.isEmpty && trailing.isEmpty }
    /// Every action, trailing set first: what VoiceOver offers.
    public var all: [GlassSwipeAction] { trailing + leading }
}

private struct GlassSwipeActionsModifier: ViewModifier {
    let set: GlassSwipeSet

    func body(content: Content) -> some View {
        if set.isEmpty {
            content
        } else {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: set.fullSwipeTrailing) {
                    ForEach(set.trailing) { button($0) }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: set.fullSwipeLeading) {
                    ForEach(set.leading) { button($0) }
                }
                // VoiceOver's actions rotor: every swipe action, without swiping.
                .accessibilityActions {
                    ForEach(set.all) { action in
                        Button(action.label, action: action.run)
                    }
                }
        }
    }

    private func button(_ action: GlassSwipeAction) -> some View {
        Button(action: action.run) {
            if let symbol = action.systemImage {
                Label(action.label, systemImage: symbol)
            } else {
                Text(action.label)
            }
        }
        .tint(action.tint)
        .accessibilityLabel(action.label)
    }
}

public extension View {
    /// The system's swipe actions for a row of a `List`, and the same actions
    /// as VoiceOver's actions. Rows of every shared list take them through this.
    func glassSwipeActions(_ set: GlassSwipeSet) -> some View {
        modifier(GlassSwipeActionsModifier(set: set))
    }
}

// MARK: - A list of rows of any height that swipe, inside a scrolling page

/// Rows of any height in a real `List` (so they take the system's
/// `.swipeActions`), for a page that scrolls itself: the list doesn't scroll,
/// and is exactly as tall as its rows, measured.
///
/// `GlassListSection` frames its list at 44 points a row inside a titled
/// panel; this is its sibling for variable-height rows (CMS list rows and
/// cards), sharing the same swipe vocabulary (`GlassSwipeSet`,
/// `glassSwipeActions`). The row draws its own surface; `rowBackground` is
/// behind the whole row (the swipe buttons sit on it).
public struct GlassSwipeList<Data: RandomAccessCollection, ID: Hashable, Row: View>: View {
    let data: Data
    let id: KeyPath<Data.Element, ID>
    var spacing: CGFloat
    var separators: Bool
    var separatorColor: Color?
    var separatorInset: CGFloat
    var swipe: (Data.Element) -> GlassSwipeSet
    let row: (Data.Element) -> Row

    @State private var heights: [ID: CGFloat] = [:]

    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        spacing: CGFloat = 0,
        separators: Bool = false,
        separatorColor: Color? = nil,
        separatorInset: CGFloat = 0,
        swipe: @escaping (Data.Element) -> GlassSwipeSet,
        @ViewBuilder row: @escaping (Data.Element) -> Row
    ) {
        self.data = data
        self.id = id
        self.spacing = spacing
        self.separators = separators
        self.separatorColor = separatorColor
        self.separatorInset = separatorInset
        self.swipe = swipe
        self.row = row
    }

    /// The rows' measured heights and the gaps between them; a row not yet
    /// measured counts as 60 points until it is.
    private var totalHeight: CGFloat {
        let items = Array(data)
        guard !items.isEmpty else { return 0 }
        let rows = items.reduce(CGFloat(0)) { $0 + (heights[$1[keyPath: id]] ?? 60) }
        return rows + spacing * CGFloat(items.count - 1)
    }

    public var body: some View {
        List {
            ForEach(data, id: id) { item in
                let key = item[keyPath: id]
                row(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs((heights[key] ?? -1) - height) > 0.5 { heights[key] = height }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(separators ? .visible : .hidden)
                    .listRowSeparatorTint(separatorColor)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in separatorInset }
                    .glassSwipeActions(swipe(item))
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 0)
        #if os(iOS)
        .listRowSpacing(spacing)
        #endif
        .frame(height: totalHeight)
    }
}
