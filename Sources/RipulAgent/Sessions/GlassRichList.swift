import SwiftUI
import UniformTypeIdentifiers

// MARK: - Row activity

/// What a row is currently busy with, as far as the LIST is concerned.
///
/// Deliberately a closure input rather than a set of typed `*Id: String?`
/// properties. The sessions list derives this from five separate inputs (three
/// in-flight ids, a `deletingFromHost` flag and the navigation store's
/// `navigatingToSessionId`); the plans list derives it from two. Modelling
/// Sessions' five as component properties would have made the component
/// Sessions-shaped and left Plans passing nils.
public enum GlassRowActivity: Equatable {
    case idle
    /// Opening / navigating — the row is on its way somewhere.
    case opening
    case archiving
    case deleting
}

// MARK: - Empty states

/// The four resting states a list can be in with no rows to show.
///
/// They are separate cases because they are separate sentences: "still
/// loading", "nothing resolves to look in", "this folder is empty" and "your
/// search excluded everything" are four different situations, and collapsing
/// them is how a list ends up telling the user nothing useful. A FETCH ERROR is
/// deliberately absent — it stays a transient alert on the owning screen rather
/// than a resting state, which is already how both screens handle it.
public enum GlassListEmptyState: Equatable {
    /// First fetch in flight and nothing cached.
    case loading
    /// Nothing resolves to read from — no folder chosen, or no machine answered.
    case unresolved(String)
    /// Resolved fine; there is genuinely nothing here.
    case empty(String)
    /// Rows exist, but the active search or filter excluded all of them.
    case noMatches(String)
}

// MARK: - Batch bar

/// One verb in the floating batch bar.
public struct GlassBatchAction: Identifiable {
    public let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let perform: () -> Void

    public init(
        id: String,
        title: String,
        systemImage: String,
        tint: Color,
        perform: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.perform = perform
    }
}

/// The floating capsule bar shown while a selection is live.
///
/// Screen chrome rather than list chrome — it floats over the whole panel
/// stack, so it is a sibling of the list, not a part of it.
///
/// Available from iOS 17 so the plans list (which is not gated at 26) can use
/// it; the liquid-glass capsule is applied only where the API exists, with the
/// documented `.ultraThinMaterial` fallback below that.
@available(iOS 17.0, macOS 14.0, *)
public struct GlassBatchBar: View {
    private let actions: [GlassBatchAction]
    private let identifierPrefix: String

    public init(actions: [GlassBatchAction], identifierPrefix: String) {
        self.actions = actions
        self.identifierPrefix = identifierPrefix
    }

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(actions) { action in
                Button(action: action.perform) {
                    HStack(spacing: 6) {
                        Image(systemName: action.systemImage)
                        Text(action.title).fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(action.tint)
                .modifier(BatchCapsuleBackground())
                .uiKitIdentifier("\(identifierPrefix).batch.\(action.id)Button")
            }
        }
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Layout

/// How the rows are stacked — a forced choice, not a style preference.
///
/// A SwiftUI `List` has no intrinsic height: it fills the space its container
/// offers. That is fine inside a greedy frame (the agents screen gives its
/// sessions panel `maxHeight: .infinity`), and it collapses to NOTHING inside a
/// `ScrollView`, which is what the plans screen is. So a list embedded in a
/// scroller has to stack its rows itself.
///
/// The only capability that genuinely requires `List` is `.swipeActions`. Plans
/// has no swipe — its one bulk verb is a destructive delete — so it loses
/// nothing by stacking.
public enum GlassRichListLayout {
    /// A real `List`. Supports swipe. REQUIRES a container that gives it
    /// height, and supplies its own pull-to-refresh.
    case list
    /// A `LazyVStack` with separators, for embedding inside a `ScrollView`.
    /// No swipe; the enclosing scroller owns pull-to-refresh.
    case stack
}

// MARK: - Rich list

/// Liquid glass where it exists, material where it does not.
@available(iOS 17.0, macOS 14.0, *)
private struct BatchCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// The list the sessions screen grew, promoted to shared vocabulary.
///
/// `GlassListSection` already covers the simple case (Files, Commits, Dock…),
/// but it frames its List at `count * 44` — a uniform-row-height model that
/// cannot carry variable-height rows, which both session and plan rows are. So
/// this is a sibling rather than an extension of it.
///
/// What the component owns: the container, row insets, tap dispatch, the
/// selection/activity tint cascade, the optimistic active-row highlight, swipe
/// and context-menu slots, the empty states, and pull-to-refresh. What it does
/// NOT own is anything in either screen's vocabulary — the row itself, the menu
/// items, and how activity is derived all arrive as closures.
///
/// iOS 17 rather than 26: nothing in here is liquid glass. The name follows the
/// `Glass*` family it sits beside, not an API requirement — and the plans list,
/// which is not gated at 26, has to be able to use it.
@available(iOS 17.0, macOS 14.0, *)
public struct GlassRichList<Item: Identifiable, Row: View, Swipe: View, RowMenu: View>: View {
    private let items: [Item]
    private let emptyState: GlassListEmptyState?
    private let layout: GlassRichListLayout
    private let activity: (Item) -> GlassRowActivity
    private let isSelecting: Bool
    private let selectedIds: Set<Item.ID>
    /// Whether this row is the CONFIRMED active row — a master-detail concept
    /// (the Mac split). A closure rather than an id because the sessions list
    /// matches on two identities (the unified row's own id and its live web
    /// tab's), and flattening that to one would silently stop highlighting
    /// half the rows. The iPhone navigates away on open and always returns
    /// false, so no row stays highlighted there.
    private let isActive: (Item) -> Bool
    /// The owner's confirmed active identifier, observed ONLY to know when to
    /// drop the optimistic override. Opaque on purpose — the component never
    /// compares it to a row, that is `isActive`'s job.
    private let activeToken: String?
    private let onTap: (Item) -> Void
    private let onToggleSelect: (Item) -> Void
    private let onRefresh: (() async -> Void)?
    private let identifierPrefix: String
    private let row: (Item) -> Row
    private let swipe: (Item) -> Swipe
    private let rowMenu: (Item) -> RowMenu
    /// Set by `draggableRows`: nil for a list whose rows stay where they are.
    private var dragging: RowDragging?

    /// What a list needs to let one row be dropped on another.
    struct RowDragging {
        /// What a row carries when it is picked up, or nil for one that stays put.
        let payload: (Item) -> String?
        /// Whether what is carried may be dropped on this row.
        let canDrop: (String, Item) -> Bool
        let onDrop: (String, Item) -> Void
    }

    /// The row a drag is over now.
    @State private var dropTargetId: Item.ID?
    /// What the drag in hand carries, when it began in this list. A drag from
    /// another window has none, and is checked when it is dropped.
    @State private var draggedPayload: String?
    /// A row of this list is being dragged, from the moment it is picked up
    /// until the drag ends, dropped or not. For that long the rows say where
    /// they are and the drop surface is over the list.
    @State private var isDragging = false
    /// Where the list and its rows are on screen while a drag is over them.
    @State private var dropGeometry = DropGeometry()

    /// Where things are, for finding the row under a drag. A class, so that
    /// writing a frame as the list scrolls redraws nothing.
    private final class DropGeometry {
        var listOrigin: CGPoint = .zero
        var rows: [Item.ID: CGRect] = [:]
        /// A row is in the air. Kept here as well as in `isDragging` because a
        /// row is asked what it carries before the view has been drawn again.
        var inTheAir = false
    }

    /// The drag is over: the drop surface comes off the list. Reached three
    /// ways, because none of them is certain alone. A drop that is taken says
    /// so. A drag let go of anywhere else is known by what it carried being
    /// released, which was seen to come late, or not at all, after a drop. And
    /// a surface that is somehow still there takes itself off at a touch.
    private func endDrag() {
        dropGeometry.inTheAir = false
        if isDragging { isDragging = false }
        if dropTargetId != nil { dropTargetId = nil }
        if draggedPayload != nil { draggedPayload = nil }
    }

    /// The row under a point of the list, as the drop delegate gives it.
    private func row(at location: CGPoint) -> Item? {
        let point = CGPoint(x: dropGeometry.listOrigin.x + location.x, y: dropGeometry.listOrigin.y + location.y)
        guard let id = dropGeometry.rows.first(where: { $0.value.contains(point) })?.key else { return nil }
        return items.first { $0.id == id }
    }

    /// Optimistic active-row override: set on tap so the highlight snaps to
    /// intent rather than waiting for the owner's async confirmation. Cleared
    /// whenever `activeId` changes — either the owner confirmed, or something
    /// else moved the selection.
    @State private var optimisticActiveId: Item.ID?

    public init(
        items: [Item],
        emptyState: GlassListEmptyState?,
        identifierPrefix: String,
        layout: GlassRichListLayout = .list,
        activity: @escaping (Item) -> GlassRowActivity = { _ in .idle },
        isSelecting: Bool = false,
        selectedIds: Set<Item.ID> = [],
        isActive: @escaping (Item) -> Bool = { _ in false },
        activeToken: String? = nil,
        onTap: @escaping (Item) -> Void,
        onToggleSelect: @escaping (Item) -> Void = { _ in },
        onRefresh: (() async -> Void)? = nil,
        // `swipe` and `rowMenu` have no defaults on purpose. A default cannot
        // drive Swift's generic inference here anyway, and making them explicit
        // means a surface with no swipe (Plans — its only bulk verb is a
        // destructive delete) states that at the call site rather than
        // inheriting it silently.
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder swipe: @escaping (Item) -> Swipe,
        @ViewBuilder rowMenu: @escaping (Item) -> RowMenu
    ) {
        self.items = items
        self.emptyState = emptyState
        self.identifierPrefix = identifierPrefix
        self.layout = layout
        self.activity = activity
        self.isSelecting = isSelecting
        self.selectedIds = selectedIds
        self.isActive = isActive
        self.activeToken = activeToken
        self.onTap = onTap
        self.onToggleSelect = onToggleSelect
        self.onRefresh = onRefresh
        self.row = row
        self.swipe = swipe
        self.rowMenu = rowMenu
    }

    /// Lets a row be picked up and dropped on another row of the list.
    ///
    /// It is the system's drag and drop, the one a long press and a move start
    /// on a phone and a click and a move start on a Mac, so it lives beside a
    /// row's tap, swipe and menu without a gesture of its own in the row. Not
    /// offered while rows are being selected: there a row's whole job is the tick.
    ///
    /// - Parameters:
    ///   - payload: What a row carries, or nil for a row that cannot be picked up.
    ///   - canDrop: Whether what is carried may be dropped on a row. A row it
    ///     may not be dropped on does not light up.
    ///   - onDrop: What was carried, and the row it was dropped on.
    public func draggableRows(
        payload: @escaping (Item) -> String?,
        canDrop: @escaping (String, Item) -> Bool = { _, _ in true },
        onDrop: @escaping (String, Item) -> Void
    ) -> GlassRichList {
        var list = self
        list.dragging = RowDragging(payload: payload, canDrop: canDrop, onDrop: onDrop)
        return list
    }

    /// Whether the drag over this row may be dropped on it.
    private func takesDrop(_ item: Item) -> Bool {
        guard let dragging, !isSelecting, dropTargetId == item.id else { return false }
        return draggedPayload.map { dragging.canDrop($0, item) } ?? true
    }

    public var body: some View {
        if let emptyState {
            emptyView(emptyState)
        } else {
            switch layout {
            case .list: list
            case .stack: stack
            }
        }
    }

    @ViewBuilder
    private func emptyView(_ state: GlassListEmptyState) -> some View {
        switch state {
        case .loading:
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                    .uiKitIdentifier("\(identifierPrefix).loadingSpinner")
                Text("Loading…")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        case .unresolved(let message):
            emptyText(message, identifier: "unresolvedText")
        case .empty(let message):
            emptyText(message, identifier: "emptyText")
        case .noMatches(let message):
            emptyText(message, identifier: "noMatchesText")
        }
    }

    private func emptyText(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(.ripul(.caption))
            .foregroundStyle(.ripul(.textSecondary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .uiKitIdentifier("\(identifierPrefix).\(identifier)")
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                row(item)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelecting {
                            onToggleSelect(item)
                        } else {
                            optimisticActiveId = item.id
                            onTap(item)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !isSelecting { swipe(item) }
                    }
                    .contextMenu { MenuIcons { if !isSelecting { DeferredRowMenu { rowMenu(item) } } }}
                    .modifier(RowDrag(
                        payload: isSelecting ? nil : dragging?.payload(item),
                        enabled: dragging != nil && !isSelecting,
                        pickedUp: { carried in
                            // One row is in the air at a time. As it passes over
                            // other rows the system asks them what they carry
                            // too (seen 11 October 2026: the answer of the row
                            // it was held over replaced what was being carried,
                            // and the drop was refused as a chat under itself).
                            guard !dropGeometry.inTheAir else { return false }
                            dropGeometry.inTheAir = true
                            draggedPayload = carried
                            isDragging = true
                            return true
                        },
                        ended: { endDrag() }))
                    // Only while a row is being dragged: a row that says where
                    // it is on every frame of a scroll would cost the scroll.
                    .background {
                        if isDragging {
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear { dropGeometry.rows[item.id] = geometry.frame(in: .global) }
                                    .onChange(of: geometry.frame(in: .global)) { _, frame in dropGeometry.rows[item.id] = frame }
                                    .onDisappear { dropGeometry.rows[item.id] = nil }
                            }
                        }
                    }
                    .listRowBackground(background(for: item))
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onChange(of: activeToken) { _, _ in
            // The owner confirmed (or something else moved the active row);
            // drop the override so the highlight follows the real value.
            optimisticActiveId = nil
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .animation(.easeInOut(duration: 0.3), value: items.map(\.id))
        .refreshable {
            if let onRefresh { await onRefresh() }
        }
        .overlay {
            // The drop surface. A `List` takes a drag for itself and offers it
            // to nothing: not to a row (found for the tool collections screen,
            // and again here), and not to a drop target on the list as a
            // whole, which was tried on 11 October 2026 and never called. A
            // plain view over the list is offered it. It is only there while
            // a row of this list is in the air, so it never takes a touch
            // meant for the list.
            if isDragging, dragging != nil {
                ListDropSurface(delegate: dropDelegate, origin: { dropGeometry.listOrigin = $0 },
                                touched: { endDrag() })
            }
        }
    }

    private var dropDelegate: ListDropDelegate {
        ListDropDelegate(
            moved: { location in
                let target = row(at: location)
                if dropTargetId != target?.id { dropTargetId = target?.id }
                guard let target, let dragging else { return false }
                return draggedPayload.map { dragging.canDrop($0, target) } ?? true
            },
            exited: { dropTargetId = nil },
            dropped: { location, providers in
                let target = row(at: location)
                endDrag()
                guard let target, let dragging,
                      let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { carried, _ in
                    guard let carried = carried as? String else { return }
                    Task { @MainActor in
                        if dragging.canDrop(carried, target) { dragging.onDrop(carried, target) }
                    }
                }
                return true
            })
    }

    /// Rows stacked by hand, for a container that is already scrolling.
    ///
    /// Same tap dispatch, same selection and activity tinting, same context
    /// menu as `list` — only the container and the separators differ, plus the
    /// absence of swipe (which `List` alone provides).
    private var stack: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: item))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelecting {
                            onToggleSelect(item)
                        } else {
                            optimisticActiveId = item.id
                            onTap(item)
                        }
                    }
                    .contextMenu { MenuIcons { if !isSelecting { DeferredRowMenu { rowMenu(item) } } }}

                if item.id != items.last?.id {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .onChange(of: activeToken) { _, _ in optimisticActiveId = nil }
        .animation(.easeInOut(duration: 0.3), value: items.map(\.id))
    }

    /// Selection beats activity beats rest — a row being archived while
    /// selected should read as selected, because that is the state the user is
    /// acting through.
    private func background(for item: Item) -> Color {
        if isSelecting && selectedIds.contains(item.id) {
            return Color.accentColor.opacity(0.08)
        }
        // Where what is being dragged would land.
        if takesDrop(item) {
            return Color.accentColor.opacity(0.28)
        }
        // The optimistic pick wins over the confirmed one so the highlight
        // snaps on tap instead of waiting for the round-trip.
        if optimisticActiveId == item.id || (optimisticActiveId == nil && isActive(item)) {
            return Color.accentColor.opacity(0.18)
        }
        switch activity(item) {
        case .opening: return Color.accentColor.opacity(0.12)
        case .archiving: return Color.ripul(.warning).opacity(0.12)
        case .deleting: return Color.ripul(.danger).opacity(0.12)
        case .idle: return Color.clear
        }
    }
}

/// A list row that can be picked up.
///
/// Applied to every row of a list that drags or to none of it, so a row's
/// identity does not change with what it carries.
@available(iOS 17.0, macOS 14.0, *)
private struct RowDrag: ViewModifier {
    /// What this row carries, or nil when it cannot be picked up.
    let payload: String?
    let enabled: Bool
    /// A row was picked up. False when another row is already in the air,
    /// and this one is to give the system nothing to add to it.
    let pickedUp: (String) -> Bool
    /// The drag is over, whether it was dropped or let go of.
    let ended: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                // Called as the row is picked up. A row that cannot be picked
                // up gives the system nothing to carry, and nothing is dragged.
                guard let payload, pickedUp(payload) else { return NSItemProvider() }
                let carried = DragEndItemProvider(object: payload as NSString)
                carried.onEnd = ended
                return carried
            }
        } else {
            content
        }
    }
}

/// What a dragged row carries, which says when the drag is over.
///
/// SwiftUI says when a drag begins and never when it ends. The system keeps
/// what is carried for exactly as long as the drag lasts, dropped or let go
/// of, so its release is the end of the drag.
private final class DragEndItemProvider: NSItemProvider, @unchecked Sendable {
    var onEnd: (() -> Void)?

    deinit {
        guard let onEnd else { return }
        DispatchQueue.main.async(execute: onEnd)
    }
}

/// `NSItemProvider(object: NSString)` registers `public.utf8-plain-text`, and a
/// drop has matched by the exact type and not by what it conforms to (found
/// for the tool collections screen), so all three are named.
private let listDropTypes: [UTType] = [.utf8PlainText, .plainText, .text]

/// The invisible surface over a list that takes a drop for it.
@available(iOS 17.0, macOS 14.0, *)
private struct ListDropSurface: View {
    let delegate: ListDropDelegate
    /// The list's place on screen, to turn a point of the surface into one a row can be found by.
    let origin: (CGPoint) -> Void
    /// A finger came down on the surface. While a row is in the air the finger
    /// belongs to the drag and never reaches this, so a touch here means the
    /// drag is over and the surface was left behind.
    let touched: () -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .onAppear { origin(geometry.frame(in: .global).origin) }
                .onChange(of: geometry.frame(in: .global).origin) { _, point in origin(point) }
                .onDrop(of: listDropTypes, delegate: delegate)
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in touched() })
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct ListDropDelegate: DropDelegate {
    /// Whether the row under this point of the list takes what is carried.
    let moved: (CGPoint) -> Bool
    let exited: () -> Void
    let dropped: (CGPoint, [NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: listDropTypes) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: moved(info.location) ? .move : .forbidden)
    }
    func dropExited(info: DropInfo) { exited() }
    func performDrop(info: DropInfo) -> Bool { dropped(info.location, info.itemProviders(for: listDropTypes)) }
}

/// A row's menu, built when SwiftUI asks for the menu and not when it builds
/// the row. Written inline, the menu's whole content was constructed for every
/// row on every pass of the list: a quarter of the main thread's time during a
/// tab switch with 131 rows (simulator, 11 October 2026).
private struct DeferredRowMenu<Menu: View>: View {
    @ViewBuilder let build: () -> Menu
    var body: some View { build() }
}
