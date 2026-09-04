import SwiftUI

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
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .font(.caption)
            .foregroundStyle(.secondary)
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
                    .contextMenu { if !isSelecting { rowMenu(item) } }
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
                    .contextMenu { if !isSelecting { rowMenu(item) } }

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
        // The optimistic pick wins over the confirmed one so the highlight
        // snaps on tap instead of waiting for the round-trip.
        if optimisticActiveId == item.id || (optimisticActiveId == nil && isActive(item)) {
            return Color.accentColor.opacity(0.18)
        }
        switch activity(item) {
        case .opening: return Color.accentColor.opacity(0.12)
        case .archiving: return Color.orange.opacity(0.12)
        case .deleting: return Color.red.opacity(0.12)
        case .idle: return Color.clear
        }
    }
}
