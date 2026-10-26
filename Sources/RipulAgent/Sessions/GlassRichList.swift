import SwiftUI
import UniformTypeIdentifiers
#if targetEnvironment(macCatalyst)
import CoreGraphics
#endif
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

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

/// Where a row sits in a contiguous group of related rows (a chat and the
/// chats shown under it). Nil for a row that stands by itself.
public enum GlassRowGroupSlice: Equatable, Sendable {
    case top
    case middle
    case bottom
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
///
/// **The `.list` layout must stay a `List`, one row per item.** The sessions
/// list holds 130 chats and more on a phone, and only a List builds just the
/// rows on screen and reuses their cells. On 22 October 2026 it was put in a
/// `ScrollView` over a `VStack` to animate families opening, and the iPhone app
/// stopped: with 165 rows the first took 85 seconds to be reachable and each
/// swipe 29, against under 1 and 3. Rows that open and close are moved over the
/// List by Core Animation (`revealsRowChanges`), not by changing their heights.
/// When the List seems to fight an animation, measure the cells (their height
/// on each frame) before replacing it.
/// `SessionFamiliesUITests.testALongListBuildsOnlyTheRowsOnScreenAndStillOpensAndCloses`
/// fails on a list that builds every row.
@available(iOS 17.0, macOS 14.0, *)
public struct GlassRichList<Item: Identifiable, Row: View, Swipe: View, RowMenu: View>: View {
    private let items: [Item]
    private let emptyState: GlassListEmptyState?
    private let layout: GlassRichListLayout
    private let activity: (Item) -> GlassRowActivity
    private let isSelecting: Bool
    private let selectedIds: Set<Item.ID>
    /// Whether this row is the CONFIRMED active row: the one whose detail is on
    /// screen beside the list (a split layout). A closure rather than an id
    /// because the sessions list matches on two identities (the unified row's
    /// own id and its live web tab's), and flattening that to one would
    /// silently stop highlighting half the rows.
    ///
    /// Nil for a list whose rows open over it (an iPhone's sessions list, Plans).
    /// No row is marked there, and a tap marks none either: the mark would
    /// still be on the row when the person came back to the list, and nothing
    /// would ever clear it (Peter, 23 October 2026: on an iPhone the selected
    /// row is distracting once you have swiped back to the list).
    private let isActive: ((Item) -> Bool)?
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
    /// Set by `unhighlightedRows`: rows a tap leaves as they are.
    private var leavesUnhighlighted: ((Item) -> Bool)?
    /// Set by `groupedRows`: where a row sits in a bordered family group.
    private var groupSlice: ((Item) -> GlassRowGroupSlice?)?
    /// Set by `groupedRows`: a row that draws no divider above the row after it.
    private var joinsNext: ((Item) -> Bool)?
    /// Set by `revealsRowChanges`: moves when the owner opens or closes rows.
    private var revealToken: AnyHashable?

    /// The rows the list last drew. A class, so that keeping it up to date
    /// from the body redraws nothing.
    @State private var revealMemory = RevealMemory()
    /// Draws rows opening and closing (`revealsRowChanges`).
    @State private var drawer = RowDrawer()
    /// On an iPhone the list stays behind an open chat: nothing moves there.
    @Environment(\.ripulSessionListCanBeSeen) private var listCanBeSeen

    private final class RevealMemory {
        /// The rows' ids as the list last drew them: a change of the owner's
        /// token is drawn from these to the rows it gives now.
        var ids: [AnyHashable] = []
        /// The owner's token the rows on screen were drawn for.
        var appliedToken: AnyHashable?
        /// The list has been drawn once, so there is something to open from.
        var primed = false
    }

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
        /// Incremented each time a drag begins, so a late release of an older
        /// drag's `DragEndItemProvider` (kept on the Mac drag pasteboard until
        /// the next drag replaces it) never ends the new drag.
        var generation: Int = 0
        /// The active drag's item provider, so `endDrag()` can clear `onEnd`
        /// immediately and never fire it later on `deinit`.
        weak var activeProvider: DragEndItemProvider?
    }

    /// The drag is over: the drop surface comes off the list. Reached three
    /// ways, because none of them is certain alone. A drop that is taken says
    /// so. A drag let go of anywhere else is known by what it carried being
    /// released, which was seen to come late, or not at all, after a drop. And
    /// a surface that is somehow still there takes itself off at a touch.
    private func endDrag(generation: Int? = nil) {
        if let generation, generation != dropGeometry.generation { return }
        dropGeometry.activeProvider?.onEnd = nil
        dropGeometry.activeProvider = nil
        dropGeometry.inTheAir = false
        dropGeometry.rows.removeAll()
        if isDragging { isDragging = false }
        if dropTargetId != nil { dropTargetId = nil }
        if draggedPayload != nil { draggedPayload = nil }
    }

    /// The row under a point of the list, as the drop delegate gives it.
    private func row(at location: CGPoint) -> Item? {
        let point = CGPoint(x: dropGeometry.listOrigin.x + location.x, y: dropGeometry.listOrigin.y + location.y)
        #if canImport(UIKit)
        if let collectionView = drawer.locateList(), let window = collectionView.window,
           collectionView.numberOfSections == 1 {
            let inCollection = collectionView.convert(point, from: window)
            if let indexPath = collectionView.indexPathForItem(at: inCollection),
               items.indices.contains(indexPath.item) {
                return items[indexPath.item]
            }
        }
        #endif
        if let id = dropGeometry.rows.first(where: { $0.value.contains(point) })?.key {
            return items.first { $0.id == id }
        }
        if let id = dropGeometry.rows
            .filter({ $0.value.insetBy(dx: -16, dy: -6).contains(point) })
            .min(by: { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) })?.key {
            return items.first { $0.id == id }
        }
        return nil
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
        isActive: ((Item) -> Bool)? = nil,
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

    /// Rows that are a control rather than something a tap opens (Older Chats
    /// at the end of the sessions list): a tap does not highlight them.
    public func unhighlightedRows(_ test: @escaping (Item) -> Bool) -> GlassRichList {
        var list = self
        list.leavesUnhighlighted = test
        return list
    }

    /// Frames contiguous groups of related rows (a chat and the chats shown
    /// under it) inside a shared rounded border.
    ///
    /// - Parameter joinsNext: A row inside a group that draws no divider
    ///   between itself and the row after it (a chat and the control that
    ///   ends its family).
    public func groupedRows(_ slice: @escaping (Item) -> GlassRowGroupSlice?,
                            joinsNext: ((Item) -> Bool)? = nil) -> GlassRichList {
        var list = self
        list.groupSlice = slice
        list.joinsNext = joinsNext
        return list
    }

    /// Rows that arrive or leave when `token` moves open and close instead of
    /// appearing and vanishing: rows coming in slide down out of the row above
    /// them, rows going fold up into it, the rows below move with them, and a
    /// group's border stays whole. The owner moves `token` when the reader
    /// opens or closes something (a family, a fold); rows that change for any
    /// other reason change as before.
    ///
    /// The list takes the new rows at once and Core Animation moves its cells
    /// and pictures of it (`RowDrawer`), so no row changes height on any frame.
    /// Changing the rows' heights a frame at a time had the list measure every
    /// cell on screen again on each frame, and jittered on a phone (23 October
    /// 2026). The rows stay in a `List`, one row each: drawing them by hand in
    /// a stack cost every row of a long list at once (22 October 2026).
    public func revealsRowChanges(when token: AnyHashable) -> GlassRichList {
        var list = self
        list.revealToken = token
        return list
    }

    private var isControlClickActive: Bool {
        #if targetEnvironment(macCatalyst)
        if CGEventSource.flagsState(.combinedSessionState).contains(.maskControl) { return true }
        #endif
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if NSEvent.modifierFlags.contains(.control) { return true }
        #endif
        return false
    }

    private func tapped(_ item: Item) {
        if isControlClickActive {
            onToggleSelect(item)
        } else if isSelecting {
            onToggleSelect(item)
        } else {
            if isActive != nil, leavesUnhighlighted?(item) != true { optimisticActiveId = item.id }
            onTap(item)
        }
    }

    /// Whether the drag over this row may be dropped on it.
    private func takesDrop(_ item: Item) -> Bool {
        guard let dragging, dropTargetId == item.id else { return false }
        return draggedPayload.map { dragging.canDrop($0, item) } ?? true
    }

    public var body: some View {
        if let emptyState {
            switch layout {
            case .list:
                emptyView(emptyState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .stack:
                emptyView(emptyState)
            }
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

    private struct RowSlot: Identifiable {
        let item: Item
        let slice: GlassRowGroupSlice?
        let hidesBottomSeparator: Bool
        /// Draws its group's divider along its foot.
        var divider = true
        var id: Item.ID { item.id }
        /// A row of a group with more of the group below it, and not joined
        /// to the row after it.
        var showsGroupDivider: Bool { slice != nil && slice != .bottom && divider }
    }

    /// The owner has moved `revealToken` since the list last drew its rows.
    private var rowsOpenOrClose: Bool {
        revealToken != nil && revealMemory.primed && revealToken != revealMemory.appliedToken
    }

    private var rowSlots: [RowSlot] {
        if revealToken != nil { noteRowChanges() }
        let hiddenBottomSeparatorIds = idsBeforeOrInsideGroup
        return items.map { item in
            RowSlot(item: item, slice: groupSlice?(item), hidesBottomSeparator: hiddenBottomSeparatorIds.contains(item.id),
                    divider: joinsNext?(item) != true)
        }
    }

    /// Keeps up with the rows the list draws. When the owner has opened or
    /// closed some since, the drawer pictures the list before it changes:
    /// this runs while the body is built, and the list on screen is still the
    /// list as it was.
    private func noteRowChanges() {
        let ids = items.map { AnyHashable($0.id) }
        defer {
            revealMemory.ids = ids
            revealMemory.appliedToken = revealToken
            revealMemory.primed = true
        }
        guard revealMemory.primed else { return }
        #if canImport(UIKit)
        if revealToken != revealMemory.appliedToken {
            if layout == .list && listCanBeSeen { drawer.begin(old: revealMemory.ids, new: ids) }
        } else if drawer.isRunning && ids != revealMemory.ids {
            // Rows moved for some other reason while the drawer ran: they
            // are where they go.
            drawer.finish()
        }
        #endif
    }

    /// Rows that change places move there: a chat that has just spoken slides
    /// up to the top, and a new one comes in. Not as rows open and close,
    /// which the drawer draws: the list animating the same change again made
    /// the rows overlap (22 October 2026). Lost that day with the families'
    /// border, and missed (Peter, 23 October 2026).
    private func reorderAnimation(rowsOpenOrClose: Bool) -> Animation? {
        rowsOpenOrClose || drawer.isRunning || isSelecting ? nil : .easeInOut(duration: 0.3)
    }

    /// A `List`, and it has to stay one: see the type's note. Not a stack,
    /// lazy or not, which loses swipe actions, cell reuse and the system's
    /// drag, and builds rows the List would not.
    private var list: some View {
        let opensOrCloses = rowsOpenOrClose
        let slots = rowSlots
        return List {
            ForEach(slots) { slot in
                let item = slot.item
                let slice = slot.slice
                row(item)
                    .glassRowGroupDivider(slot.showsGroupDivider)
                    .contentShape(Rectangle())
                    .onTapGesture { tapped(item) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !isSelecting { swipe(item) }
                    }
                    .contextMenu { MenuIcons { if !isSelecting { DeferredRowMenu { rowMenu(item) } } }}
                    .modifier(RowDrag(
                        payload: dragging?.payload(item),
                        enabled: dragging != nil,
                        pickedUp: { carried in
                            // One row is in the air at a time. As it passes over
                            // other rows the system asks them what they carry
                            // too (seen 11 October 2026: the answer of the row
                            // it was held over replaced what was being carried,
                            // and the drop was refused as a chat under itself).
                            guard !dropGeometry.inTheAir else { return nil }
                            dropGeometry.generation &+= 1
                            let generation = dropGeometry.generation
                            dropGeometry.inTheAir = true
                            draggedPayload = carried
                            isDragging = true
                            return generation
                        },
                        registerProvider: { dropGeometry.activeProvider = $0 },
                        ended: { generation in endDrag(generation: generation) }))
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
                    .listRowBackground(GlassRowGroupBackground(slice: slice, rowTint: background(for: item))
                        // A family's first chat, its family folded away, lets its
                        // border go rather than dropping it. The drawer fades it
                        // itself, and the list's animations are off while it runs.
                        .animation(.easeOut(duration: 0.2), value: slice))
                    .listRowInsets(GlassRowGroupBackground.listRowInsets(for: slice))
                    .listRowSeparator(slot.hidesBottomSeparator ? .hidden : .automatic,
                                      edges: slice == .top ? .all : .bottom)
            }
        }
        #if canImport(UIKit)
        .background { RowDrawerProbe(drawer: drawer) }
        #endif
        // While the drawer moves the rows, nothing in the list animates as
        // well: a family's box is whole from the first frame, and no row is
        // drawn a frame at a time by the main thread.
        .transaction { if drawer.isRunning { $0.disablesAnimations = true } }
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
        .animationWhileSessionListSeen(reorderAnimation(rowsOpenOrClose: opensOrCloses), value: items.map(\.id))
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
                ListDropSurface(
                    delegate: dropDelegate,
                    origin: { dropGeometry.listOrigin = $0 },
                    touched: { endDrag() },
                    sessionEnded: {
                        let generation = dropGeometry.generation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                            endDrag(generation: generation)
                        }
                    }
                )
            }
            #if targetEnvironment(macCatalyst)
            if !isDragging {
                ControlClickSurface { point, view in
                    guard let collectionView = drawer.locateList(),
                          collectionView.numberOfSections == 1 else { return }
                    let inCollection = collectionView.convert(point, from: view)
                    let indexPath = collectionView.indexPathForItem(at: inCollection)
                        ?? collectionView.indexPathsForVisibleItems.first(where: { path in
                            collectionView.layoutAttributesForItem(at: path)?.frame.insetBy(dx: 0, dy: -6).contains(inCollection) == true
                        })
                    guard let indexPath, items.indices.contains(indexPath.item) else { return }
                    onToggleSelect(items[indexPath.item])
                }
            }
            #endif
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
        let opensOrCloses = rowsOpenOrClose
        let slots = rowSlots
        return LazyVStack(spacing: 0) {
            ForEach(slots) { slot in
                let item = slot.item
                let slice = slot.slice
                let bottomPadding: CGFloat = slice == .bottom ? 16 : 10
                row(item)
                    .glassRowGroupDivider(slot.showsGroupDivider, footInset: bottomPadding)
                    .padding(.horizontal, 16)
                    .padding(.top, slice == .top ? 14 : 10)
                    .padding(.bottom, bottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GlassRowGroupBackground(slice: slice, rowTint: background(for: item)))
                    .contentShape(Rectangle())
                    .onTapGesture { tapped(item) }
                    .contextMenu { MenuIcons { if !isSelecting { DeferredRowMenu { rowMenu(item) } } }}

                if item.id != items.last?.id && !slot.hidesBottomSeparator {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .animationWhileSessionListSeen(reorderAnimation(rowsOpenOrClose: opensOrCloses), value: items.map(\.id))
        .onChange(of: activeToken) { _, _ in optimisticActiveId = nil }
    }

    /// Rows whose native bottom separator is suppressed: any row inside a
    /// bordered family group (the group draws its own internal dividers and
    /// bottom border) and the standalone row immediately above a group's top.
    private var idsBeforeOrInsideGroup: Set<Item.ID> {
        Self.idsBeforeOrInsideGroup(items, groupSlice)
    }

    private static func idsBeforeOrInsideGroup(_ items: [Item], _ groupSlice: ((Item) -> GlassRowGroupSlice?)?) -> Set<Item.ID> {
        guard let groupSlice else { return [] }
        var ids = Set<Item.ID>()
        for index in items.indices {
            let item = items[index]
            if groupSlice(item) != nil {
                ids.insert(item.id)
            } else if index + 1 < items.count, groupSlice(items[index + 1]) == .top {
                ids.insert(item.id)
            }
        }
        return ids
    }

    /// Selection beats activity beats rest — a row being archived while
    /// selected should read as selected, because that is the state the user is
    /// acting through.
    private func background(for item: Item) -> Color {
        // Where what is being dragged would land.
        if takesDrop(item) {
            return Color.accentColor.opacity(0.28)
        }
        if selectedIds.contains(item.id) {
            return Color.accentColor.opacity(0.08)
        }
        // The optimistic pick wins over the confirmed one so the highlight
        // snaps on tap instead of waiting for the round-trip.
        if let isActive, optimisticActiveId == item.id || (optimisticActiveId == nil && isActive(item)) {
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

// MARK: - Group framing

/// Background and outer border segment for a row in a grouped family card, or a
/// plain fill for a row by itself. The dividers between a group's rows are the
/// rows' own (`glassRowGroupDivider`): a background cannot see where a row's
/// text starts.
@available(iOS 17.0, macOS 14.0, *)
public struct GlassRowGroupBackground: View {
    private let slice: GlassRowGroupSlice?
    private let rowTint: Color

    public init(slice: GlassRowGroupSlice?, rowTint: Color = .clear) {
        self.slice = slice
        self.rowTint = rowTint
    }

    public var body: some View {
        if let slice {
            let fillShape = GroupSliceFillShape(slice: slice)
            fillShape
                .fill(Color.ripul(.text).opacity(0.03))
                .overlay {
                    if rowTint != .clear {
                        fillShape.fill(rowTint)
                    }
                }
                .overlay {
                    GroupSliceStrokeShape(slice: slice)
                        .stroke(Color.ripul(.text).opacity(0.16), lineWidth: 1)
                }
                .accessibilityIdentifier("GlassRichList.groupSlice.\(Self.sliceName(slice))")
        } else {
            rowTint
        }
    }

    public static func listRowInsets(for slice: GlassRowGroupSlice?) -> EdgeInsets {
        EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
    }

    private static func sliceName(_ slice: GlassRowGroupSlice) -> String {
        switch slice {
        case .top: return "top"
        case .middle: return "middle"
        case .bottom: return "bottom"
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
public extension View {
    /// The divider between this row and the next in a group, along the foot
    /// of the row's cell: from where the row's text starts to its trailing edge.
    ///
    /// Where the text starts is the row's `listRowSeparatorLeading` guide, the
    /// one the list's own separator follows under a row by itself, so a row
    /// that sets it once has both start there (Peter, 23 October 2026: under
    /// the text, not under the icon). A row that sets none has its divider from
    /// its leading edge. It fades as the group's border does.
    ///
    /// - Parameters:
    ///   - shows: The row has a divider below it.
    ///   - footInset: How far below the row its cell ends.
    func glassRowGroupDivider(_ shows: Bool,
                              footInset: CGFloat = GlassRowGroupBackground.listRowInsets(for: nil).bottom) -> some View {
        GroupFootDividerLayout(footInset: footInset) {
            self
            Rectangle()
                .fill(Color.ripul(.text).opacity(0.08)) // theme-mapping: GlassRowGroupBackground's divider, moved here unchanged
                .opacity(shows ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: shows)
                .allowsHitTesting(false)
        }
    }
}

/// A row as it is, and its divider `footInset` below it, from the row's
/// `listRowSeparatorLeading` guide to its trailing edge. Only the row has a
/// size and guides, so the list still finds the row's separator and baselines.
@available(iOS 17.0, macOS 14.0, *)
private struct GroupFootDividerLayout: Layout {
    let footInset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let row = subviews.first else { return }
        let rowProposal = ProposedViewSize(bounds.size)
        row.place(at: bounds.origin, proposal: rowProposal)
        guard subviews.count > 1 else { return }
        let leading = min(bounds.width, max(0, row.dimensions(in: rowProposal)[HorizontalAlignment.listRowSeparatorLeading]))
        subviews[1].place(at: CGPoint(x: bounds.minX + leading, y: bounds.maxY + footInset), anchor: .bottomLeading,
                          proposal: ProposedViewSize(width: bounds.width - leading, height: 0.5))
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        subviews.first?.dimensions(in: ProposedViewSize(bounds.size))[explicit: guide]
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        subviews.first?.dimensions(in: ProposedViewSize(bounds.size))[explicit: guide]
    }
}

private struct GroupSliceFillShape: Shape {
    let slice: GlassRowGroupSlice

    func path(in rect: CGRect) -> Path {
        let r = GroupSliceGeometry.insetRect(in: rect, for: slice)
        let radius = min(GroupSliceGeometry.cornerRadius, min(r.width, r.height) * 0.5)
        switch slice {
        case .top:
            var path = Path()
            path.move(to: CGPoint(x: r.minX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            path.addArc(center: CGPoint(x: r.minX + radius, y: r.minY + radius),
                        radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
            path.addArc(center: CGPoint(x: r.maxX - radius, y: r.minY + radius),
                        radius: radius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            path.closeSubpath()
            return path
        case .middle:
            return Path(r)
        case .bottom:
            var path = Path()
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
            path.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius),
                        radius: radius, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
            path.addArc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius),
                        radius: radius, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            path.closeSubpath()
            return path
        }
    }
}

private struct GroupSliceStrokeShape: Shape {
    let slice: GlassRowGroupSlice

    func path(in rect: CGRect) -> Path {
        let r = GroupSliceGeometry.insetRect(in: rect, for: slice)
        let radius = min(GroupSliceGeometry.cornerRadius, min(r.width, r.height) * 0.5)
        var path = Path()
        switch slice {
        case .top:
            path.move(to: CGPoint(x: r.minX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            path.addArc(center: CGPoint(x: r.minX + radius, y: r.minY + radius),
                        radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
            path.addArc(center: CGPoint(x: r.maxX - radius, y: r.minY + radius),
                        radius: radius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        case .middle:
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            path.move(to: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        case .bottom:
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
            path.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius),
                        radius: radius, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
            path.addArc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius),
                        radius: radius, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        }
        return path
    }
}

private enum GroupSliceGeometry {
    static let horizontalInset: CGFloat = 4
    static let topMargin: CGFloat = 1
    static let bottomMargin: CGFloat = 2
    static let cornerRadius: CGFloat = 12

    static func insetRect(in rect: CGRect, for slice: GlassRowGroupSlice) -> CGRect {
        let top = slice == .top ? topMargin : 0
        let bottom = slice == .bottom ? bottomMargin : 0
        return CGRect(
            x: rect.minX + horizontalInset,
            y: rect.minY + top,
            width: max(0, rect.width - horizontalInset * 2),
            height: max(0, rect.height - top - bottom)
        )
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
    /// A row was picked up. Nil when another row is already in the air,
    /// and this one is to give the system nothing to add to it.
    let pickedUp: (String) -> Int?
    let registerProvider: (DragEndItemProvider) -> Void
    /// The drag is over, whether it was dropped or let go of.
    let ended: (Int) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                // Called as the row is picked up. A row that cannot be picked
                // up gives the system nothing to carry, and nothing is dragged.
                guard let payload, let generation = pickedUp(payload) else { return NSItemProvider() }
                let carried = DragEndItemProvider(object: payload as NSString)
                carried.onEnd = { ended(generation) }
                registerProvider(carried)
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
#if canImport(UIKit)
@available(iOS 17.0, *)
private struct ListDropSurface: UIViewRepresentable {
    let delegate: ListDropDelegate
    /// The list's place on screen, to turn a point of the surface into one a row can be found by.
    let origin: (CGPoint) -> Void
    /// A finger came down on the surface. While a row is in the air the finger
    /// belongs to the drag and never reaches this, so a touch here means the
    /// drag is over and the surface was left behind.
    let touched: () -> Void
    let sessionEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(delegate: delegate, origin: origin, touched: touched, sessionEnded: sessionEnded)
    }

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.backgroundColor = .clear
        view.onLayout = { [weak coordinator = context.coordinator] point in
            coordinator?.origin(point)
        }
        view.onTouch = { [weak coordinator = context.coordinator] in
            coordinator?.touched()
        }
        view.addInteraction(UIDropInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: SurfaceView, context: Context) {
        context.coordinator.delegate = delegate
        context.coordinator.origin = origin
        context.coordinator.touched = touched
        context.coordinator.sessionEnded = sessionEnded
        if uiView.window != nil {
            origin(uiView.convert(CGPoint.zero, to: nil))
        }
    }

    final class SurfaceView: UIView {
        var onLayout: ((CGPoint) -> Void)?
        var onTouch: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            if window != nil { onLayout?(convert(CGPoint.zero, to: nil)) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onLayout?(convert(CGPoint.zero, to: nil)) }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            onTouch?()
        }
    }

    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var delegate: ListDropDelegate
        var origin: (CGPoint) -> Void
        var touched: () -> Void
        var sessionEnded: () -> Void

        init(delegate: ListDropDelegate, origin: @escaping (CGPoint) -> Void, touched: @escaping () -> Void,
             sessionEnded: @escaping () -> Void) {
            self.delegate = delegate
            self.origin = origin
            self.touched = touched
            self.sessionEnded = sessionEnded
        }

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
            session.hasItemsConforming(toTypeIdentifiers: listDropTypes.map(\.identifier))
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
            guard let view = interaction.view else { return UIDropProposal(operation: .forbidden) }
            origin(view.convert(CGPoint.zero, to: nil))
            let allowed = delegate.moved(session.location(in: view))
            return UIDropProposal(operation: allowed ? .move : .forbidden)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
            delegate.exited()
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
            guard let view = interaction.view else { return }
            origin(view.convert(CGPoint.zero, to: nil))
            _ = delegate.dropped(session.location(in: view), session.items.map(\.itemProvider))
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
            sessionEnded()
        }
    }
}
#else
@available(macOS 14.0, *)
private struct ListDropSurface: View {
    let delegate: ListDropDelegate
    /// The list's place on screen, to turn a point of the surface into one a row can be found by.
    let origin: (CGPoint) -> Void
    /// A finger came down on the surface. While a row is in the air the finger
    /// belongs to the drag and never reaches this, so a touch here means the
    /// drag is over and the surface was left behind.
    let touched: () -> Void
    var sessionEnded: () -> Void = {}

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
#endif

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

#if targetEnvironment(macCatalyst)
/// Intercepts Control-clicks above a `List` on Mac Catalyst before
/// `UICollectionView`'s context-menu interaction can lift the row or open a
/// menu. Invisible to hit-testing unless the Control key is held.
private struct ControlClickSurface: UIViewRepresentable {
    let onControlClick: (CGPoint, UIView) -> Void

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.backgroundColor = .clear
        view.onControlClick = onControlClick
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        view.onControlClick = onControlClick
    }

    final class SurfaceView: UIView, UIContextMenuInteractionDelegate {
        var onControlClick: ((CGPoint, UIView) -> Void)?
        private var lastTriggerTime: CFTimeInterval = 0
        private var wasButtonDown = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            addInteraction(UIContextMenuInteraction(delegate: self))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard bounds.contains(point) else { return nil }
            if event?.type == .scroll || event?.type == .hover {
                if !CGEventSource.buttonState(.combinedSessionState, button: .left) {
                    wasButtonDown = false
                }
                return nil
            }
            let isLeftDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            if !isLeftDown {
                wasButtonDown = false
            }
            let controlHeld = (event?.modifierFlags.contains(.control) == true)
                || CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)
            guard controlHeld else { return nil }
            if isLeftDown {
                notePressAndTrigger(at: point)
            }
            return self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            notePressAndTrigger(at: touch.location(in: self))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            wasButtonDown = false
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            wasButtonDown = false
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            notePressAndTrigger(at: location)
            return nil
        }

        private func notePressAndTrigger(at point: CGPoint) {
            let now = CACurrentMediaTime()
            guard !wasButtonDown, now - lastTriggerTime > 0.15 else { return }
            wasButtonDown = true
            lastTriggerTime = now
            pollButtonRelease()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onControlClick?(point, self)
            }
        }

        private func pollButtonRelease() {
            guard wasButtonDown else { return }
            if !CGEventSource.buttonState(.combinedSessionState, button: .left) {
                wasButtonDown = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.pollButtonRelease()
            }
        }
    }
}
#endif

/// A row's menu, built when SwiftUI asks for the menu and not when it builds
/// the row. Written inline, the menu's whole content was constructed for every
/// row on every pass of the list: a quarter of the main thread's time during a
/// tab switch with 131 rows (simulator, 11 October 2026).
private struct DeferredRowMenu<Menu: View>: View {
    @ViewBuilder let build: () -> Menu
    var body: some View { build() }
}
