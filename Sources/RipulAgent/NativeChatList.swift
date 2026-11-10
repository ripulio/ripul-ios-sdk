#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// The native chat's list on iPhone and Catalyst: a UIKit scroll view whose layout we
/// own, hosting each row's SwiftUI view (docs/plans/native-chat-viewport-owner.md).
///
/// The SwiftUI `ScrollView` it replaces laid its rows out in its own passes and moved
/// its own offset; eight places in the chat then corrected that offset, each on its own
/// signal, and the chat nodded (Peter, 8 November 2026). Here one `layoutSubviews`
/// measures the rows it mounts, lays every row out from the height ledger, lets the one
/// viewport owner (`NativeChatViewport`) place the offset, and mounts what is on screen,
/// all before anything is drawn. Nothing else writes the offset: UIKit's finger, coast
/// and bounce move it, and the owner hears of them.
@MainActor
final class NativeChatListHandle: ObservableObject {
    fileprivate(set) weak var scroller: NativeChatListScroller?
    /// The chat follows its end: the scroll-to-bottom button hides.
    @Published private(set) var isFollowing = true
    /// The reader came within a screen of the first loaded row: load older rows.
    var onNearTop: (() -> Void)?
    /// A finger took the chat (the row toolbar closes).
    var onUserScroll: (() -> Void)?
    /// The chat came to rest after a finger or a coast.
    var onRest: (() -> Void)?
    /// Only the return-to-end button hears motion changes; the chat does not observe them.
    var onScrollActivityChanged: ((Bool) -> Void)?
    /// `[ENTRYNOD]` lines: what the list did with the offset as a chat was entered.
    var onTrace: ((String) -> Void)?
    private var latestFollowing = true
    private var publishScheduled = false
    private var latestScrolling = false
    private var activityPublishScheduled = false

    /// A glide can start inside layout. Coalesce its changes onto the next turn so the
    /// button is never published while SwiftUI is updating the list.
    fileprivate func scrollingChanged(_ scrolling: Bool) {
        guard latestScrolling != scrolling else { return }
        latestScrolling = scrolling
        guard !activityPublishScheduled else { return }
        activityPublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activityPublishScheduled = false
            self.onScrollActivityChanged?(self.latestScrolling)
        }
    }

    /// Learned in a layout pass and published a turn later: SwiftUI must not be told
    /// of a change while it is updating.
    fileprivate func followingChanged(_ following: Bool) {
        latestFollowing = following
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            if self.isFollowing != self.latestFollowing { self.isFollowing = self.latestFollowing }
        }
    }

    /// The chat follows its end now (`isFollowing` is published a turn later).
    var isFollowingNow: Bool { scroller?.isFollowingNow ?? true }

    /// A chat was entered: its end, held there while it settles.
    func enter() { scroller?.enter() }
    /// The end, at once or gliding.
    func scrollToBottom(animated: Bool) { scroller?.scrollToBottom(animated: animated) }
    /// `rowID` in the middle of the space between the bar and the composer. Asked for
    /// `chatId`'s rows, it waits a moment for them to arrive.
    func show(rowID: String, chatId: String?) { scroller?.place(.show(rowID), chatId: chatId) }
    /// `rowID` with its top `screenOffset` below the scroll view's top, as the page keeps a place.
    func hold(rowID: String, screenOffset: CGFloat, chatId: String?) {
        scroller?.place(.hold(rowID, screenOffset), chatId: chatId)
    }
    /// Where the reader is: following, or the first row below the bar and how far its
    /// top is below the scroll view's top.
    func position() -> (rowID: String?, screenOffset: CGFloat, following: Bool)? { scroller?.position() }
}

/// One mounted row: its SwiftUI view in a hosting controller, inside a container the
/// list places by frame. The name ends in "MarkerView" and it carries `rowId`, so the
/// harness's trackers find rows as they found the old row markers.
final class NativeChatListRowMarkerView: UIView {
    let rowId: String
    /// The row's SwiftUI view in a hosting controller that takes none of the window's
    /// safe area: the list places rows, and the clearances are its own. For a while rows
    /// were `UIHostingConfiguration` content views, which have no such setting. A row
    /// passing under the top bar held its content at the bar's edge, then let it go, so
    /// messages seemed to stick at the top as the chat scrolled; told to ignore the safe
    /// area at top and bottom, they still stuck on the open Duo in portrait until the
    /// phone was turned (Peter, 9 November 2026). The frame gaps once put down to these
    /// controllers were the test polling the accessibility tree. Side by side on the Duo
    /// simulator, flinging through 170 rows: one hitch in each of two rounds, against 3
    /// and 7 for the content views; the keyboard coming up, a worst frame of 45 and
    /// 56 ms against 33 and 42; a send and a streaming reply the same.
    private let host: UIHostingController<AnyView>?
    #if DEBUG
    /// `-perfOff rowController`: the row in a `UIHostingConfiguration` content view, as
    /// before, for an A/B of the two hostings.
    private let contentView: (UIView & UIContentView)?
    #endif
    /// The row revision and width its height was measured at.
    var measuredRevision: UInt64 = .max
    var measuredWidth: CGFloat = -1
    var revision: UInt64 = 0
    /// The row's state beyond its content (its toolbar open, a highlight) as last hosted.
    var state = 0

    init(rowId: String, content: AnyView) {
        self.rowId = rowId
        #if DEBUG
        if PerfSwitch.isOff("rowController") {
            self.host = nil
            self.contentView = Self.configuration(content).makeContentView()
            super.init(frame: .zero)
            clipsToBounds = false
            if let contentView {
                contentView.backgroundColor = .clear
                addSubview(contentView)
            }
            return
        }
        self.contentView = nil
        #endif
        let host = UIHostingController(rootView: content)
        self.host = host
        super.init(frame: .zero)
        host.view.backgroundColor = .clear
        // The list sizes the row; the hosting view must not size itself or take the
        // window's safe area.
        host.sizingOptions = []
        host.safeAreaRegions = []
        clipsToBounds = false
        addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    #if DEBUG
    private static func configuration(_ content: AnyView) -> UIHostingConfiguration<AnyView, EmptyView> {
        UIHostingConfiguration { AnyView(content.ignoresSafeArea(.all, edges: .vertical)) }.margins(.all, 0)
    }
    #endif

    /// The row drawn with new content (its row changed, or what all rows share).
    func setContent(_ content: AnyView) {
        #if DEBUG
        if let contentView {
            contentView.configuration = Self.configuration(content)
            return
        }
        #endif
        host?.rootView = content
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if DEBUG
        contentView?.frame = bounds
        #endif
        host?.view.frame = bounds
    }

    /// A row's sheets, popovers and menus present from a view controller in the window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let host else { return }
        if window != nil {
            guard host.parent == nil, let parent = superview.flatMap(Self.controller(of:)) else { return }
            parent.addChild(host)
            host.didMove(toParent: parent)
        } else if host.parent != nil {
            host.willMove(toParent: nil)
            host.removeFromParent()
        }
    }

    private static func controller(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// The row's height at `width`: its ideal height, as `NativeChatListRowLayout` answers
    /// a proposal with no height.
    func measure(width: CGFloat) -> CGFloat {
        var size = CGSize.zero
        #if DEBUG
        if let contentView {
            size = contentView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        }
        #endif
        if let host {
            size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
        measuredWidth = width
        measuredRevision = revision
        return size.height.isFinite ? max(0, size.height.rounded(.up)) : 0
    }
}

@MainActor
final class NativeChatListScroller: UIScrollView, UIScrollViewDelegate {
    struct Content {
        var chatId: String?
        var rows: [NativeChatRow] = []
        /// Each row's state beyond the row itself (its toolbar open, a highlight); a
        /// row whose state changes is measured again.
        var rowStates: [String: Int] = [:]
        /// The load-more banner above the first row, and a key that changes with it.
        var header: AnyView?
        var headerKey: String = ""
        /// The bar's clearance above the rows and the composer's (and keyboard's) below.
        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
        /// Side gutters: 12, or none on the side of the system's tab rail (`RailGutters`).
        var leadingGutter: CGFloat = 12
        var trailingGutter: CGFloat = 12
        /// Everything besides width and scale that sets how tall rows draw.
        var textMetrics: String = "default"
        var environment: EnvironmentValues = EnvironmentValues()
        var makeRow: (NativeChatRow) -> AnyView = { _ in AnyView(EmptyView()) }
    }

    enum Placement: Equatable {
        /// The row in the middle of the space between the bar and the composer.
        case show(String)
        /// The row's top this far below the scroll view's top.
        case hold(String, CGFloat)

        var rowID: String {
            switch self {
            case .show(let id), .hold(let id, _): return id
            }
        }
    }

    /// Space the old stack kept around its rows: its padding, spacing, the clearance less
    /// the composer gap trim, and the bottom anchor (`NativeChatView.scrollContent`).
    static let rowSpacing: CGFloat = 10
    static let edgePadding: CGFloat = 12
    static let composerGapTrim: CGFloat = 25
    static let headerID = "__header"
    /// How long a placement waits for its row to arrive.
    static let placementPatience: CFTimeInterval = 2
    /// How long after an entry the list traces what it does with the offset.
    static let traceSeconds: CFTimeInterval = 4
    /// How long a drop in the bottom clearance waits before the chat moves for it. A
    /// rise is taken at once (nothing may sit under a growing composer or keyboard), and
    /// cancels a drop still waiting: on Peter's iPhone 17 Pro Max (9 November 2026) the
    /// composer folded to its pill and unfolded 15 ms later, 195 → 106 → 195 pt.
    static let clearanceDropDelay: CFTimeInterval = 0.06
    /// Rows kept mounted: up to `mountedCap` grown at rest; past `mountedHardCap` (a fling
    /// into rows not grown yet) the farthest go back down to `mountedCap`.
    static let mountedCap = 160
    static let mountedHardCap = 200

    weak var handle: NativeChatListHandle?
    private var content = Content()
    private var viewport = NativeChatViewport()
    private var ledger = NativeChatWindowModel(layout: .init(width: 320))
    private var revisions = NativeChatRowRevisionTracker<NativeChatRow>()
    private var rowIndex: [String: Int] = [:]
    private var revisionByID: [String: UInt64] = [:]
    private var mounted: [String: NativeChatListRowMarkerView] = [:]
    private var header: NativeChatListRowMarkerView?
    private var headerHeight: CGFloat = 0
    private var isWritingOffset = false
    private var isLayingOut = false
    private var isScrollingToTop = false
    private var glideLink: CADisplayLink?
    private var lastGlideFrame: CFTimeInterval = 0
    private var growthLink: CADisplayLink?
    /// The rows within a screen of the visible area, as of the last pass.
    private var visibleRange: Range<Int> = 0..<0
    /// A row to show or hold that has not arrived yet, for the chat it was asked for.
    private var pendingPlacement: (placement: Placement, chatId: String?, asked: CFTimeInterval)?
    private var nearTopRequested = false
    private var cachedGeometry: (key: GeometryKey, value: NativeChatViewport.Geometry)?
    private var enteredAt: CFTimeInterval = 0
    private let tapFilter = NativeChatListTapFilter()
    /// The bottom clearance the layout uses: `content.bottomInset` once a drop has held.
    private var bottomInset: CGFloat = 0
    private var pendingDrop: DispatchWorkItem?
    #if DEBUG
    /// One `[LISTPERF]` line per gesture, with what the list did while it ran.
    private let frames = NativeChatScrollFrames(path: "owned")
    private struct PerfCounts {
        var layouts = 0, mounts = 0, unmounts = 0, measures = 0, rehosts = 0
        var layoutMs = 0.0, maxLayoutMs = 0.0, measureMs = 0.0, maxMeasureMs = 0.0
    }
    private var perf = PerfCounts()

    private func perfSummary() -> String {
        String(format: "layouts=%d layoutMs=%.0f maxLayoutMs=%.1f mounts=%d unmounts=%d measures=%d measureMs=%.0f maxMeasureMs=%.1f rehosts=%d mounted=%d rows=%d",
               perf.layouts, perf.layoutMs, perf.maxLayoutMs, perf.mounts, perf.unmounts, perf.measures,
               perf.measureMs, perf.maxMeasureMs, perf.rehosts, mounted.count, content.rows.count)
    }
    #endif

    /// What every hosted row is drawn with besides its own row and state. When it
    /// changes every mounted row (up to 160) is hosted again; otherwise only the rows
    /// whose row or state changed are, so a streaming reply redraws one row. Not whether
    /// the screen is shown: no row reads it, and a tab hidden and shown again would
    /// host every row again.
    private struct HostKey: Equatable {
        var textMetrics: String
        var leadingGutter: CGFloat
        var trailingGutter: CGFloat
        var themeVersion: Int
        var workingTint: Color?
        var font: Font?
        var sessionListModel: ObjectIdentifier?
        var windowContext: ObjectIdentifier?

        init(_ content: Content) {
            let environment = content.environment
            textMetrics = content.textMetrics
            leadingGutter = content.leadingGutter
            trailingGutter = content.trailingGutter
            themeVersion = environment.ripulThemeVersion
            workingTint = environment.composerWorkingTint
            font = environment.font
            sessionListModel = environment.ripulSessionListModel.map(ObjectIdentifier.init)
            windowContext = environment.ripulWindowContext.map(ObjectIdentifier.init)
        }
    }
    private var hostKey: HostKey?

    private struct GeometryKey: Equatable {
        var generation: UInt64
        var rows: Int
        var origin: CGFloat
        var headerTop: CGFloat?
        var bottom: CGFloat
        var viewport: CGFloat
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        alwaysBounceVertical = true
        showsHorizontalScrollIndicator = false
        backgroundColor = .clear
        scrollsToTop = true
        accessibilityIdentifier = "NativeChatView.scroller"
        // A tap on the chat, outside text and pages, puts the keyboard away.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = tapFilter
        addGestureRecognizer(tap)
    }

    @objc private func tapped() { window?.endEditing(true) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Content

    func update(_ new: Content) {
        let old = content
        let chatChanged = new.chatId != old.chatId
        let rowsChanged = chatChanged || new.rows != old.rows
        content = new
        if chatChanged { resetForChat() }
        if rowsChanged { updateLedger() }
        let key = HostKey(content)
        let hostAll = key != hostKey
        hostKey = key
        // A row whose row or state changed is hosted again and measured in the next
        // pass; every row is hosted again when what they share changed.
        for (id, view) in mounted {
            guard let index = rowIndex[id] else { continue }
            let revision = revisionByID[id] ?? 0
            let state = content.rowStates[id] ?? 0
            let changed = revision != view.revision || state != view.state
            if changed {
                view.revision = revision
                view.state = state
                view.measuredRevision = .max
            }
            if changed || hostAll {
                view.setContent(rowView(content.rows[index]))
                #if DEBUG
                if frames.isRecording { perf.rehosts += 1 }
                #endif
            }
        }
        if let header, let body = content.header {
            if new.headerKey != old.headerKey { header.measuredRevision = .max }
            if new.headerKey != old.headerKey || hostAll { header.setContent(headerView(body)) }
        }
        if new.topInset != old.topInset {
            viewport.clearanceMoving(now: CACurrentMediaTime())
            trace("clearance top \(Int(old.topInset))->\(Int(new.topInset))")
        }
        if new.bottomInset != old.bottomInset { bottomInsetChanged(from: old.bottomInset, to: new.bottomInset) }
        verticalScrollIndicatorInsets = UIEdgeInsets(top: content.topInset, left: 0, bottom: content.bottomInset, right: 0)
        applyPendingPlacement()
        setNeedsLayout()
    }

    /// What a hosted row takes from the chat's SwiftUI environment: the chat's own values
    /// and the theme's tint and font. Not the whole environment: handed `EnvironmentValues`
    /// whole, a row also took the accessibility state SwiftUI keeps there as it was at the
    /// list's last update, and VoiceOver and the UI tests found nothing inside a row until
    /// the next one (9 November 2026). What the system keeps (appearance, text size, layout
    /// direction) reaches each row through UIKit's traits.
    /// `-perfOff clearanceDropDelay` (Debug) takes a drop at once, for an A/B.
    private var dropDelay: CFTimeInterval {
        #if DEBUG
        if PerfSwitch.isOff("clearanceDropDelay") { return 0 }
        #endif
        return Self.clearanceDropDelay
    }

    /// A rise in the bottom clearance is laid out at once; a drop once it has held for
    /// `clearanceDropDelay`, so a fold undone within moments moves nothing.
    private func bottomInsetChanged(from old: CGFloat, to new: CGFloat) {
        if new >= bottomInset || viewport.geometry == nil || dropDelay == 0 {
            pendingDrop?.cancel()
            pendingDrop = nil
            guard new != bottomInset else {
                trace("clearance bottom \(Int(old))->\(Int(new)): a drop undone, nothing moves")
                return
            }
            trace("clearance bottom \(Int(bottomInset))->\(Int(new))")
            bottomInset = new
            viewport.clearanceMoving(now: CACurrentMediaTime())
            return
        }
        guard pendingDrop == nil else { return }
        let drop = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDrop = nil
            let settled = self.content.bottomInset
            guard settled < self.bottomInset else { return }
            self.trace("clearance bottom \(Int(self.bottomInset))->\(Int(settled)) (held \(Int(Self.clearanceDropDelay * 1000)) ms)")
            self.bottomInset = settled
            self.viewport.clearanceMoving(now: CACurrentMediaTime())
            self.setNeedsLayout()
        }
        pendingDrop = drop
        DispatchQueue.main.asyncAfter(deadline: .now() + dropDelay, execute: drop)
    }

    private func hosted(_ view: some View) -> AnyView {
        let environment = content.environment
        return AnyView(view
            .environment(\.openURL, environment.openURL)
            .environment(\.composerWorkingTint, environment.composerWorkingTint)
            .environment(\.ripulSessionListModel, environment.ripulSessionListModel)
            .environment(\.ripulWindowContext, environment.ripulWindowContext)
            .environment(\.ripulThemeVersion, environment.ripulThemeVersion)
            .font(environment.font)
            .tint(RipulTheme.accentOverride))
    }

    /// A row as hosted: at its ideal height at the top of its frame, reporting that
    /// height whenever it changes (a disclosure, an image loading, a tool group growing),
    /// so the list lays it out again.
    private func rowView(_ row: NativeChatRow) -> AnyView {
        let id = row.id
        return hosted(
            NativeChatListRowLayout {
                content.makeRow(row)
                    .padding(.leading, content.leadingGutter)
                    .padding(.trailing, content.trailingGutter)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: NativeChatListRowHeightKey.self, value: geo.size.height)
                    })
            }
            .onPreferenceChange(NativeChatListRowHeightKey.self) { [weak self] height in
                MainActor.assumeIsolated { self?.rowReportedHeight(id, height) }
            }
        )
    }

    private func headerView(_ body: AnyView) -> AnyView {
        hosted(NativeChatListRowLayout {
            body
                .padding(.leading, content.leadingGutter)
                .padding(.trailing, content.trailingGutter)
        })
    }

    /// A mounted row's content changed height by itself.
    private func rowReportedHeight(_ id: String, _ height: CGFloat) {
        guard height.isFinite, let index = rowIndex[id], index < ledger.heights.count,
              let view = mounted[id], view.measuredWidth == rowWidth,
              view.measuredRevision == view.revision else { return }
        let rounded = max(0, height.rounded(.up))
        guard abs(ledger.heights[index] - rounded) > 0.5 else { return }
        #if DEBUG
        // A row drawn at a height other than the one it was measured at: the list
        // corrects it, and a following chat glides by the difference.
        Self.debugCorrections.append("\(id):\(Int(ledger.heights[index]))->\(Int(rounded))")
        if Self.debugCorrections.count > 200 { Self.debugCorrections.removeFirst() }
        #endif
        let key = ledger.key(for: ledger.descriptors[index])
        if rounded == 0 { ledger.setNoSlot([key]) } else { ledger.measure(rounded, for: key) }
        setNeedsLayout()
    }

    #if DEBUG
    /// Every height a row reported after being measured at another, newest last.
    static var debugCorrections: [String] = []
    #endif

    private func updateLedger() {
        var seen = Set<String>()
        let rows = content.rows.filter { seen.insert($0.id).inserted }
        if rows.count != content.rows.count { content.rows = rows }
        let tokens = revisions.revisions(for: rows.map { (id: $0.id, value: $0) })
        rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        revisionByID = Dictionary(uniqueKeysWithValues: zip(rows.map(\.id), tokens).map { ($0, $1) })
        ledger.update(zip(rows, tokens).map { NativeChatScrollCoordinator.makeWindowDescriptor(for: $0, revision: $1) })
        for id in Array(mounted.keys) where rowIndex[id] == nil { unmount(id) }
    }

    private func resetForChat() {
        stopGrowth()
        for id in Array(mounted.keys) { unmount(id) }
        visibleRange = 0..<0
        nearTopRequested = false
        if let pending = pendingPlacement, pending.chatId != content.chatId { pendingPlacement = nil }
        cachedGeometry = nil
        enter()
    }

    // MARK: Commands

    var isFollowingNow: Bool { viewport.isFollowing }

    func enter() {
        stopGlide()
        viewport.enter(now: CACurrentMediaTime())
        enteredAt = CACurrentMediaTime()
        handle?.followingChanged(true)
        trace("enter chat=\(content.chatId ?? "-") rows=\(content.rows.count)")
        setNeedsLayout()
    }

    func scrollToBottom(animated: Bool) {
        pendingPlacement = nil
        viewport.follow(instantly: !animated)
        handle?.followingChanged(true)
        setNeedsLayout()
        if animated { startGlideIfNeeded() }
    }

    func place(_ placement: Placement, chatId: String?) {
        pendingPlacement = (placement, chatId, CACurrentMediaTime())
        applyPendingPlacement()
    }

    /// Places the pending row once it is among the rows of the chat it was asked for.
    private func applyPendingPlacement() {
        guard let pending = pendingPlacement else { return }
        guard CACurrentMediaTime() - pending.asked < Self.placementPatience else {
            pendingPlacement = nil
            return
        }
        guard pending.chatId == nil || pending.chatId == content.chatId,
              let index = rowIndex[pending.placement.rowID] else { return }
        pendingPlacement = nil
        stopGlide()
        switch pending.placement {
        case .show(let id):
            let height = index < ledger.heights.count ? ledger.heights[index] : 0
            let room = bounds.height - content.topInset - content.bottomInset
            let screenOffset = content.topInset + max(Self.edgePadding, (room - height) / 2)
            viewport.read(rowID: id, screenOffset: screenOffset)
        case .hold(let id, let screenOffset):
            viewport.read(rowID: id, screenOffset: screenOffset)
        }
        handle?.followingChanged(false)
        trace("place \(pending.placement)")
        setNeedsLayout()
    }

    func position() -> (rowID: String?, screenOffset: CGFloat, following: Bool)? {
        guard let geometry = viewport.geometry else { return nil }
        if viewport.isFollowing { return (nil, 0, true) }
        let line = contentOffset.y + content.topInset
        var chosen: (id: String, top: CGFloat)?
        for id in geometry.order where id != Self.headerID {
            guard let top = geometry.tops[id] else { continue }
            if top > line {
                if chosen == nil { chosen = (id, top) }
                break
            }
            chosen = (id, top)
        }
        guard let chosen else { return nil }
        return (chosen.id, chosen.top - contentOffset.y, false)
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        #if DEBUG
        let started = CACurrentMediaTime()
        defer {
            if frames.isRecording {
                let ms = (CACurrentMediaTime() - started) * 1000
                perf.layouts += 1
                perf.layoutMs += ms
                perf.maxLayoutMs = max(perf.maxLayoutMs, ms)
            }
        }
        #endif
        // Measuring a newly mounted row can change its height and so what is on screen:
        // lay out again, before anything is drawn, until nothing changes. Never inside
        // someone else's animation: the follow glide is the only thing that animates.
        UIView.performWithoutAnimation {
            for _ in 0..<6 where layoutPass() {}
        }
        growIfIdle()
    }

    /// The rows' width at the current size, on whole pixels.
    private var rowWidth: CGFloat {
        let scale = max(1, traitCollection.displayScale)
        return (max(0, bounds.width) * scale).rounded(.down) / scale
    }

    private var topClearance: CGFloat {
        Self.edgePadding + (content.topInset > 0 ? content.topInset + Self.rowSpacing : 0)
    }

    private var bottomClearance: CGFloat {
        let composer = bottomInset > 0 ? Self.rowSpacing + max(0, bottomInset - Self.composerGapTrim) : 0
        return composer + Self.rowSpacing + 1 + Self.edgePadding
    }

    /// The top of the first row: below the bar's clearance and the banner.
    private var rowsOrigin: CGFloat {
        topClearance + (header != nil ? headerHeight + Self.rowSpacing : 0)
    }

    /// The committed layout: every row's top from the ledger. Kept until the ledger,
    /// the clearances or the size change, so a scroll does not build it again.
    private func geometry() -> NativeChatViewport.Geometry {
        let origin = rowsOrigin
        let key = GeometryKey(generation: ledger.generation, rows: content.rows.count, origin: origin,
                              headerTop: header != nil ? topClearance : nil,
                              bottom: bottomClearance, viewport: bounds.height)
        if let cachedGeometry, cachedGeometry.key == key { return cachedGeometry.value }
        var g = NativeChatViewport.Geometry()
        g.order.reserveCapacity(content.rows.count + 1)
        g.tops.reserveCapacity(content.rows.count + 1)
        if header != nil {
            g.order.append(Self.headerID)
            g.tops[Self.headerID] = topClearance
        }
        for (index, row) in content.rows.enumerated() where index < ledger.prefix.count {
            g.order.append(row.id)
            g.tops[row.id] = origin + ledger.prefix[index]
        }
        g.contentHeight = content.rows.isEmpty ? (header != nil ? origin - Self.rowSpacing : topClearance)
                                               : origin + ledger.totalHeight
        g.viewportHeight = bounds.height
        g.topInset = 0
        g.bottomInset = bottomClearance
        cachedGeometry = (key, g)
        return g
    }

    /// One pass. Returns true when a height changed and the pass must run again.
    private func layoutPass() -> Bool {
        let width = rowWidth
        guard width > 0, bounds.height > 0 else { return false }
        let key = NativeChatWindowModel.LayoutKey(
            width: width, scale: max(1, traitCollection.displayScale),
            textMetrics: "\(content.textMetrics)|gutters:\(content.leadingGutter),\(content.trailingGutter)")
        if ledger.layout != key {
            ledger.changeLayoutPreservingEstimates(key)
            for view in mounted.values { view.measuredRevision = .max }
            header?.measuredRevision = .max
        }
        var changed = measureHeader(width: width)
        let g = geometry()
        let live = contentOffset.y
        let target = viewport.commit(g, liveOffset: live, now: CACurrentMediaTime())
        if abs(target - live) > 0.5 { trace("commit \(viewport.intent) \(Int(live))->\(Int(target)) end=\(Int(g.end))") }
        let size = CGSize(width: bounds.width, height: g.contentHeight + g.bottomInset)
        // The size and the offset change together, as ours: UIKit clamping the offset
        // to a new size is not a finger.
        isWritingOffset = true
        if contentSize != size { contentSize = size }
        isWritingOffset = false
        writeOffset(target)
        changed = mountAndMeasure(width: width) || changed
        place(width: width, geometry: g)
        handle?.followingChanged(viewport.isFollowing)
        startGlideIfNeeded()
        checkNearTop()
        return changed
    }

    private func measureHeader(width: CGFloat) -> Bool {
        guard let body = content.header else {
            guard let header else { return false }
            header.removeFromSuperview()
            self.header = nil
            headerHeight = 0
            return true
        }
        let view: NativeChatListRowMarkerView
        if let header {
            view = header
        } else {
            view = NativeChatListRowMarkerView(rowId: Self.headerID, content: headerView(body))
            insertSubview(view, at: 0)
            header = view
        }
        guard view.measuredWidth != width || view.measuredRevision == .max else { return false }
        view.revision = 0
        let height = view.measure(width: width)
        defer { headerHeight = height }
        return height != headerHeight
    }

    /// Mounts the rows within a screen of the visible area and measures what is new or
    /// changed. True when a row's height in the ledger changed. Rows already mounted stay
    /// (`trimMounted`), and at rest more are mounted nearest first (`growStep`), so a fling
    /// over them builds nothing: on Peter's Duo (9 November 2026) one scroll through a
    /// 77-row chat mounted 83 rows and dropped 82, 234 ms of measuring, worst frame 72 ms.
    private func mountAndMeasure(width: CGFloat) -> Bool {
        let rows = content.rows
        guard !rows.isEmpty, ledger.heights.count == rows.count else {
            for id in Array(mounted.keys) { unmount(id) }
            visibleRange = 0..<0
            return false
        }
        let overscan = bounds.height
        let low = contentOffset.y - overscan
        let high = contentOffset.y + bounds.height + overscan
        let origin = rowsOrigin
        // The first row whose bottom is below `low`.
        var lo = 0
        var hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if origin + ledger.prefix[mid] + ledger.heights[mid] < low { lo = mid + 1 } else { hi = mid }
        }
        var wanted: [Int] = []
        var index = lo
        while index < rows.count, origin + ledger.prefix[index] <= high {
            wanted.append(index)
            index += 1
        }
        visibleRange = lo..<max(lo, index)
        trimMounted(keeping: visibleRange)
        var batch: [(NativeChatWindowModel.HeightKey, CGFloat)] = []
        var empty: [NativeChatWindowModel.HeightKey] = []
        var changed = false
        for index in wanted {
            let row = rows[index]
            let view = mounted[row.id] ?? mount(row)
            guard view.measuredRevision != view.revision || view.measuredWidth != width else { continue }
            #if DEBUG
            let measureStarted = CACurrentMediaTime()
            #endif
            let height = view.measure(width: width)
            #if DEBUG
            if frames.isRecording {
                let ms = (CACurrentMediaTime() - measureStarted) * 1000
                perf.measures += 1
                perf.measureMs += ms
                perf.maxMeasureMs = max(perf.maxMeasureMs, ms)
            }
            #endif
            let key = ledger.key(for: ledger.descriptors[index])
            if height == 0 { empty.append(key) } else { batch.append((key, height)) }
            if abs(ledger.heights[index] - height) > 0.25 || (height > 0) != ledger.hasSlot(at: index) { changed = true }
        }
        if !batch.isEmpty { ledger.measure(batch) }
        if !empty.isEmpty { ledger.setNoSlot(empty) }
        return changed
    }

    private func mount(_ row: NativeChatRow) -> NativeChatListRowMarkerView {
        #if DEBUG
        if frames.isRecording { perf.mounts += 1 }
        #endif
        let view = NativeChatListRowMarkerView(rowId: row.id, content: rowView(row))
        view.revision = revisionByID[row.id] ?? 0
        view.state = content.rowStates[row.id] ?? 0
        // Below the scroll indicators.
        insertSubview(view, at: 0)
        mounted[row.id] = view
        return view
    }

    private func unmount(_ id: String) {
        guard let view = mounted.removeValue(forKey: id) else { return }
        view.removeFromSuperview()
        #if DEBUG
        if frames.isRecording { perf.unmounts += 1 }
        #endif
    }

    /// `-perfOff listGrowth` (Debug): rows within a screen only, dropped beyond it, and
    /// nothing grown at rest, as before 9 November 2026. For an A/B.
    private var keepsRows: Bool {
        #if DEBUG
        return !PerfSwitch.isOff("listGrowth")
        #else
        return true
        #endif
    }

    /// Past `mountedHardCap` mounted rows, the farthest from the screen go, down to
    /// `mountedCap`: what the old steady band kept in a quiet chat.
    private func trimMounted(keeping range: Range<Int>) {
        guard keepsRows else {
            for id in Array(mounted.keys) where !(rowIndex[id].map(range.contains) ?? false) { unmount(id) }
            return
        }
        guard mounted.count > Self.mountedHardCap else { return }
        let center = (range.lowerBound + range.upperBound) / 2
        let far = mounted.keys
            .compactMap { id -> (id: String, distance: Int)? in
                guard let index = rowIndex[id], !range.contains(index) else { return nil }
                return (id, abs(index - center))
            }
            .sorted { $0.distance > $1.distance }
        for row in far.prefix(mounted.count - Self.mountedCap) { unmount(row.id) }
    }

    // MARK: Growing at rest

    /// At rest, one more row a frame is mounted and measured, nearest the screen first
    /// and above it before below (a reader at the end reads up), until `mountedCap`. A
    /// touch, a coast or a glide stops it; the next rest starts it again.
    private func growIfIdle() {
        guard keepsRows, growthLink == nil, window != nil, !isTracking, !isDecelerating, glideLink == nil,
              rowWidth > 0, nextRowToGrow(width: rowWidth) != nil else { return }
        // Not while the chat slides in, or anything is scrolled: a row takes milliseconds to
        // build, one a frame through the chat's slide in (Peter, 9 November 2026: "when we
        // enter a chat sometimes the slide in stutters"). The building carries on after.
        if ChatSlideProbe.isHolding {
            ChatSlideProbe.afterSlide(growKey) { [weak self] in self?.growIfIdle() }
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(growStep(_:)))
        // Room to spare in each frame: a row can take several milliseconds to build.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        growthLink = link
    }

    private func stopGrowth() {
        growthLink?.invalidate()
        growthLink = nil
    }

    @objc private func growStep(_ link: CADisplayLink) {
        let width = rowWidth
        guard window != nil, !isTracking, !isDecelerating, glideLink == nil, width > 0,
              !ChatSlideProbe.isHolding, let index = nextRowToGrow(width: width) else {
            stopGrowth()
            // A slide or scroll began: carry on once it rests.
            if ChatSlideProbe.isHolding { growIfIdle() }
            return
        }
        let row = content.rows[index]
        let view = mounted[row.id] ?? mount(row)
        let height = view.measure(width: width)
        let key = ledger.key(for: ledger.descriptors[index])
        if height == 0 { ledger.setNoSlot([key]) } else { ledger.measure(height, for: key) }
        // Placed, and the offset rebased for any change of height, before it is drawn.
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The nearest row within `mountedCap / 2` of the screen that is not mounted (while
    /// there is room) or not measured at the current width and revision.
    private func nextRowToGrow(width: CGFloat) -> Int? {
        let rows = content.rows
        guard !rows.isEmpty, ledger.heights.count == rows.count else { return nil }
        let room = mounted.count < Self.mountedCap
        func wants(_ index: Int) -> Bool {
            guard let view = mounted[rows[index].id] else { return room }
            return view.measuredRevision != view.revision || view.measuredWidth != width
        }
        let reach = Self.mountedCap / 2
        for step in 0..<reach {
            let above = visibleRange.lowerBound - 1 - step
            let below = visibleRange.upperBound + step
            if above < 0 && below >= rows.count { return nil }
            if above >= 0, wants(above) { return above }
            if below < rows.count, wants(below) { return below }
        }
        return nil
    }

    private func place(width: CGFloat, geometry g: NativeChatViewport.Geometry) {
        if let header {
            let frame = CGRect(x: 0, y: g.tops[Self.headerID] ?? topClearance, width: width, height: headerHeight)
            if header.frame != frame { header.frame = frame }
        }
        for (id, view) in mounted {
            guard let index = rowIndex[id], index < ledger.heights.count, let top = g.tops[id] else { continue }
            let frame = CGRect(x: 0, y: top, width: width, height: ledger.heights[index])
            if view.frame != frame { view.frame = frame }
        }
    }

    private func writeOffset(_ y: CGFloat) {
        guard abs(contentOffset.y - y) > 0.01 else { return }
        isWritingOffset = true
        UIView.performWithoutAnimation {
            contentOffset = CGPoint(x: contentOffset.x, y: y)
        }
        isWritingOffset = false
    }

    private func checkNearTop() {
        guard !nearTopRequested, !content.rows.isEmpty, viewport.geometry != nil,
              contentOffset.y < bounds.height else { return }
        nearTopRequested = true
        DispatchQueue.main.async { [weak self] in
            self?.handle?.onNearTop?()
            // Ask again once the next page has had time to land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.nearTopRequested = false }
        }
    }

    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard let onTrace = handle?.onTrace, enteredAt > 0,
              CACurrentMediaTime() - enteredAt < Self.traceSeconds else { return }
        onTrace("LOG: [ENTRYNOD] list +\(Int((CACurrentMediaTime() - enteredAt) * 1000))ms \(message())")
        #endif
    }

    // MARK: The follow glide

    private func startGlideIfNeeded() {
        guard glideLink == nil, viewport.isGliding, !isTracking, !isDecelerating else { return }
        lastGlideFrame = 0
        let link = CADisplayLink(target: self, selector: #selector(glideFrame(_:)))
        link.add(to: .main, forMode: .common)
        glideLink = link
        updateScrollActivity()
    }

    private func stopGlide() {
        guard glideLink != nil else { return }
        glideLink?.invalidate()
        glideLink = nil
        updateScrollActivity()
    }

    @objc private func glideFrame(_ link: CADisplayLink) {
        let dt = lastGlideFrame == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - lastGlideFrame
        lastGlideFrame = link.timestamp
        guard !isTracking, !isDecelerating,
              let y = viewport.advance(by: min(max(dt, 1 / 240), 1 / 20), now: CACurrentMediaTime()) else {
            stopGlide()
            return
        }
        writeOffset(y)
        setNeedsLayout()
        if !viewport.isGliding { stopGlide() }
    }

    // MARK: Holding other screens' work

    /// While the person drives the chat (a finger and its coast), `ChatSlideProbe.afterSlide`
    /// work waits, as it does for Home's and the Agents list's own scrolls: the session
    /// list rebuilt or reordered by other chats' activity. Each redrew the list beside or
    /// behind the chat, and Home, 50 to 98 ms at a time mid-fling on Peter's Duo, with
    /// agents working in other chats (9 November 2026). Peter: "I would be happy for it to
    /// freeze that list whilst a scroll is ongoing". It lands when the chat rests.
    private var holdsScroll = false
    private lazy var scrollHoldKey = "nativeChat.\(ObjectIdentifier(self).hashValue)"
    private lazy var growKey = "nativeChat.grow.\(ObjectIdentifier(self).hashValue)"

    private func updateScrollActivity() {
        handle?.scrollingChanged(window != nil && (holdsScroll || glideLink != nil || isScrollingToTop))
    }

    private func holdScroll(_ on: Bool) {
        guard on != holdsScroll else { return }
        holdsScroll = on
        updateScrollActivity()
        ChatSlideProbe.holdForScroll(scrollHoldKey, on)
        if on { releaseHoldWhenStill() }
    }

    /// A coast stopped by a touch ends with no callback: let go once nothing moves the chat.
    private func releaseHoldWhenStill() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.holdsScroll else { return }
                if self.isTracking || self.isDragging || self.isDecelerating {
                    self.releaseHoldWhenStill()
                } else {
                    self.holdScroll(false)
                }
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { holdScroll(false) }
        updateScrollActivity()
    }

    // MARK: UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        #if DEBUG
        if !frames.isRecording {
            perf = PerfCounts()
            frames.log = handle?.onTrace
            frames.extra = { [weak self] in self?.perfSummary() ?? "" }
        }
        frames.begin(self)
        #endif
        holdScroll(true)
        isScrollingToTop = false
        stopGrowth()
        stopGlide()
        pendingPlacement = nil
        viewport.beginManual()
        handle?.onUserScroll?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isWritingOffset else { return }
        // UIKit moved it: a finger, a coast, a bounce, a tap on the status bar.
        if viewport.intent != .manual {
            #if DEBUG
            if !isTracking, !isDecelerating, !isScrollingToTop {
                handle?.onTrace?("LOG: [ENTRYNOD] list moved (not ours) to \(Int(contentOffset.y)) intent=\(viewport.intent)")
            }
            #endif
            stopGlide()
            viewport.beginManual()
        }
        viewport.noteManualOffset(contentOffset.y)
        setNeedsLayout()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        isScrollingToTop = true
        updateScrollActivity()
        return true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            settle()
            holdScroll(false)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
        holdScroll(false)
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        isScrollingToTop = false
        updateScrollActivity()
        settle()
    }

    private func settle() {
        guard viewport.intent == .manual, !isTracking, !isDecelerating else { return }
        viewport.settle()
        handle?.followingChanged(viewport.isFollowing)
        handle?.onRest?()
        setNeedsLayout()
    }
}

#if DEBUG
/// Frames while a finger or a coast moves the chat, for either list: one `[LISTPERF]`
/// line per gesture with the frames, the ones that came more than one and a half
/// intervals after the last (a dropped frame: Peter's "micro stutters"), the time they
/// lost and the longest gap, plus what the list did meanwhile (`extra`). The `[STALL]`
/// monitor only sees 50 ms and more; a dropped frame at 120 Hz is 8 to 25 ms. The link
/// runs only from a gesture's start to six still frames after it.
@MainActor
final class NativeChatScrollFrames: NSObject {
    let path: String
    var log: ((String) -> Void)?
    var extra: (() -> String)?
    private weak var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var interval: CFTimeInterval = 0
    private var still = 0
    private var frames = 0
    private var hitches = 0
    private var lostMs: Double = 0
    private var worstMs: Double = 0

    init(path: String) { self.path = path }

    var isRecording: Bool { link != nil }

    func begin(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
        guard link == nil else { return }
        frames = 0; hitches = 0; lostMs = 0; worstMs = 0; last = 0; still = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let target = link.targetTimestamp - link.timestamp
        if target > 0 { interval = target }
        if last > 0 {
            let gap = link.timestamp - last
            frames += 1
            worstMs = max(worstMs, gap * 1000)
            if gap > interval * 1.5 {
                hitches += 1
                lostMs += (gap - interval) * 1000
            }
        }
        last = link.timestamp
        let moving = scrollView.map { $0.isTracking || $0.isDragging || $0.isDecelerating } ?? false
        still = moving ? 0 : still + 1
        guard still >= 6 else { return }
        link.invalidate()
        self.link = nil
        guard frames > 10 else { return }
        log?(String(format: "LOG: [LISTPERF] %@ frames=%d hitches=%d lostMs=%.0f worstMs=%.1f hz=%.0f %@",
                    path, frames, hitches, lostMs, worstMs, interval > 0 ? 1 / interval : 0, extra?() ?? ""))
    }
}
#endif

/// A row at its ideal height for the width, at the top of the frame the list gives it.
/// Asked without a height (the list measuring), it answers the row's ideal height; given
/// a frame, it fills it and pins the row to its top, so a row that grew by itself keeps
/// its top in place until the list lays it out again.
private struct NativeChatListRowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal.width
        if let height = proposal.height, height.isFinite, height < 1_000_000 {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: width, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let row = subviews.first else { return }
        let size = row.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        row.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

private struct NativeChatListRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The chat's tap puts the keyboard away, except on text (a selection) and pages.
@MainActor
private final class NativeChatListTapFilter: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var current = touch.view
        while let view = current {
            if view is UITextField || view is UITextView || view is WKWebView { return false }
            current = view.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// The owned list in SwiftUI.
struct NativeChatList: UIViewRepresentable {
    var content: NativeChatListScroller.Content
    let handle: NativeChatListHandle

    func makeUIView(context: Context) -> NativeChatListScroller {
        let scroller = NativeChatListScroller()
        scroller.handle = handle
        handle.scroller = scroller
        scroller.update(content(in: context))
        return scroller
    }

    func updateUIView(_ scroller: NativeChatListScroller, context: Context) {
        scroller.handle = handle
        handle.scroller = scroller
        scroller.update(content(in: context))
    }

    private func content(in context: Context) -> NativeChatListScroller.Content {
        var content = self.content
        content.environment = context.environment
        return content
    }
}
#endif
