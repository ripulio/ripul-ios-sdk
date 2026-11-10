import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The Calendar Strip's paging rules, kept apart from UIKit so they can be
/// tested: which week or month a page shows, and what a settled scroll means.
enum CmsCalendarPaging {
    /// The page `offset` pages from `anchor`: a month or a week further on.
    static func pageDate(_ anchor: Date, offset: Int, months: Bool, calendar: Calendar) -> Date {
        guard offset != 0 else { return anchor }
        return calendar.date(byAdding: months ? .month : .weekOfYear, value: offset, to: anchor) ?? anchor
    }

    /// A page's identity: its month or its week.
    static func pageKey(_ date: Date, months: Bool, calendar: Calendar) -> String {
        if months {
            let c = calendar.dateComponents([.year, .month], from: date)
            return "m\(c.year ?? 0)-\(c.month ?? 0)"
        }
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "w\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
    }

    /// The step a scroll that came to rest at `offsetX` made: the page before
    /// (-1), the same page (0) or the page after (1). Three pages wide, the
    /// middle one at `width`.
    static func settledStep(offsetX: CGFloat, width: CGFloat) -> Int {
        guard width > 0, offsetX.isFinite else { return 0 }
        return max(-1, min(1, Int((offsetX / width).rounded()) - 1))
    }

    /// The hosts in scroll order after the scroll settled `step` pages on:
    /// the one now shown moves to the middle and keeps what it draws, and the
    /// one that fell off the far side comes round to be the new neighbour.
    static func rotated<T>(_ hosts: [T], step: Int) -> [T] {
        guard hosts.count == 3, step != 0 else { return hosts }
        return step > 0 ? Array(hosts[1...]) + [hosts[0]] : [hosts[2]] + Array(hosts[..<2])
    }

    /// A page of `rows` rows, each `rowHeight` tall, `spacing` apart, with
    /// `padding` above and below.
    static func pageHeight(rows: Int, rowHeight: CGFloat, spacing: CGFloat, padding: CGFloat) -> CGFloat {
        guard rows > 0 else { return 2 * padding }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing + 2 * padding
    }

    /// A host's height before a row has been measured: room for a neighbour
    /// a week taller to lay out whole. The scroll view clips it to the page
    /// shown, so nothing draws over what follows the calendar.
    static func hostHeight(pageHeight: CGFloat) -> CGFloat {
        pageHeight + max(64, pageHeight * 0.3)
    }

    /// How much taller than the page shown the calendar is drawn with the
    /// scroll `progress` pages on (-1 the page before, 1 the page after): the
    /// difference in rows to that neighbour, in proportion, so a month of six
    /// weeks opens its sixth as it slides in. `rows` is before, shown, after.
    static func growth(progress: CGFloat, rows: [Int], rowStep: CGFloat) -> CGFloat {
        guard rows.count == 3, rowStep > 0, progress.isFinite else { return 0 }
        let p = max(-1, min(1, progress))
        let neighbour = p < 0 ? rows[0] : rows[2]
        return CGFloat(neighbour - rows[1]) * rowStep * abs(p)
    }

    /// The first day of each week a month draws (cmsCalendarDayStyles.ts
    /// `monthGridShape`): from the week holding the 1st to the week holding
    /// the last day, or six weeks (`six`). With `hide` and weekends not shown,
    /// a first or last week whose days of the month all fall at the weekend
    /// has nothing to draw and is left out.
    static func weekStarts(ofMonth date: Date, calendar: Calendar, grid: CmsCalendarDecorations.MonthGrid,
                           showWeekends: Bool) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: month.start),
              let days = calendar.range(of: .day, in: .month, for: month.start)?.count else { return [] }
        let lead = calendar.dateComponents([.day], from: firstWeek.start, to: month.start).day ?? 0
        var start = firstWeek.start
        var weeks = (lead + days + 6) / 7
        if grid.rows == .six {
            weeks = 6
        } else if grid.outsideDays == .hide && !showWeekends {
            func drawsADay(_ weekStart: Date) -> Bool {
                (0..<7).contains { offset in
                    guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return false }
                    return day >= month.start && day < month.end && !calendar.isDateInWeekend(day)
                }
            }
            if !drawsADay(start), let next = calendar.date(byAdding: .weekOfYear, value: 1, to: start) {
                start = next
                weeks -= 1
            }
            if let last = calendar.date(byAdding: .weekOfYear, value: weeks - 1, to: start), !drawsADay(last) {
                weeks -= 1
            }
        }
        return (0..<max(0, weeks)).compactMap { calendar.date(byAdding: .weekOfYear, value: $0, to: start) }
    }
}

/// How much taller (or shorter) than the page shown the calendar is drawn
/// right now. The pager sets it frame by frame as a swipe moves towards a
/// month with more or fewer weeks (`CmsCalendarPaging.growth`); only the
/// sizer's padding reads it (`CmsCalendarGrowing`), so a frame of the swipe
/// lays the calendar out again without running its body. Back to 0 as the
/// scroll settles, in the same update as the new month, which is then as
/// tall as the calendar already is.
final class CmsCalendarGrowth: ObservableObject {
    @Published private(set) var extra: CGFloat = 0
    /// One row and the gap below it, measured by the sizer
    /// (`CmsRepeatedRowsLayout`). Not published: nothing redraws for it.
    var rowStep: CGFloat = 0

    /// Rounded to the screen's pixels, so a slow drag publishes once per
    /// pixel of height rather than every frame.
    func follow(_ value: CGFloat, scale: CGFloat) {
        let rounded = scale > 0 ? (value * scale).rounded() / scale : value
        if rounded != extra { extra = rounded }
    }
}

/// The page sizer, taller or shorter by the growth the pager publishes.
struct CmsCalendarGrowing<Content: View>: View {
    @ObservedObject var growth: CmsCalendarGrowth
    let content: Content

    init(growth: CmsCalendarGrowth, @ViewBuilder content: () -> Content) {
        self.growth = growth
        self.content = content()
    }

    var body: some View {
        content.padding(.bottom, growth.extra)
    }
}

/// A page's height from one row: every row of a calendar page is as tall
/// (markers keep their row's height whether or not a day has any), so one
/// row of cells, laid out once, measures any month: rows × its height, the
/// gaps, and the room above and below for rings.
struct CmsRepeatedRowsLayout: Layout {
    let rows: Int
    let spacing: CGFloat
    let padding: CGFloat
    /// Told the row's step, for the pager's growth.
    var growth: CmsCalendarGrowth?

    /// The row measured at a width, kept until the row's cells change: a
    /// swipe that grows the calendar lays it out every frame at one width.
    struct Cache {
        var width: CGFloat?
        var row: CGSize = .zero
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        if cache.width == nil || cache.width != proposal.width {
            cache.row = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
            cache.width = proposal.width
        }
        growth?.rowStep = cache.row.height + spacing
        return CGSize(width: proposal.width ?? cache.row.width, height: CmsCalendarPaging.pageHeight(
            rows: rows, rowHeight: cache.row.height, spacing: spacing, padding: padding))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

#if os(iOS)
/// The week or month and its two neighbours on a paging `UIScrollView`, so
/// the surface follows the finger from the first point and settles with
/// UIKit's paging physics (speed, rubber band). Each page is one hosted
/// SwiftUI view, its days and their decorations together, so they move as
/// one. The calendar hears `onPage` once the scroll has come to rest, after
/// the hosts have rotated and the offset is back on the middle page, so
/// nothing jumps or pops in. While the finger moves, the one thing that
/// changes is the growth towards a neighbour with more or fewer weeks
/// (`CmsCalendarGrowth`), which only the sizer's padding reads.
///
/// It takes the size it is offered: the calendar lays it over the page shown,
/// laid out but not drawn, so SwiftUI measures the page itself and no hosted
/// page is asked for its size inside SwiftUI's layout.
struct CmsCalendarPager: UIViewRepresentable {
    struct Page {
        let key: String
        /// Everything the page draws, hashed: a host already showing this
        /// signature keeps its views (a settle re-hosts only the new neighbour).
        let signature: Int
        /// Its weeks: 1 for a week, 4 to 6 for a month.
        var rows: Int = 1
        let view: AnyView
    }

    /// A page asked for by the header's arrows: scrolled to, then settled as a swipe is.
    struct Request: Equatable {
        let id: Int
        let step: Int
    }

    /// The page before, the page shown and the page after.
    let pages: [Page]
    var request: Request?
    /// The most rows a page can have (six for months): every host is that tall
    /// from the start, so a height that follows the finger never lays a page
    /// out again.
    var maxRows = 1
    /// The room above and below the rows (the sizer's).
    var padding: CGFloat = 0
    /// Set frame by frame as a swipe moves towards a page of other rows.
    var growth: CmsCalendarGrowth?
    /// Told while the height follows a scroll, when the calendar is pinned.
    var live: CmsPinnedLiveResize?
    let onPage: (Int) -> Void

    func makeUIView(context: Context) -> CmsCalendarPagerView {
        let view = CmsCalendarPagerView()
        update(view, context: context)
        return view
    }

    func updateUIView(_ view: CmsCalendarPagerView, context: Context) {
        update(view, context: context)
        if let request, request.id != view.handledRequest {
            view.handledRequest = request.id
            view.scroll(by: request.step)
        }
    }

    /// The size offered: the page it is laid over.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CmsCalendarPagerView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    private func update(_ view: CmsCalendarPagerView, context: Context) {
        view.onPage = onPage
        view.maxRows = maxRows
        view.padding = padding
        view.growth = growth
        view.live = live
        // The pages read the calendar's environment (its theme, colour
        // scheme and the rest), taken here rather than in the calendar's
        // body, so a change the pages don't draw doesn't run that body.
        view.show(pages, environment: context.environment)
    }
}

final class CmsCalendarPagerView: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    /// In scroll order: the page before, the page shown, the page after.
    private var hosts: [UIHostingController<AnyView>] = []
    /// What each host draws, in the same order (nil: nothing yet).
    private var signatures: [Int?] = [nil, nil, nil]
    /// Each page's weeks, in the same order.
    private var rows: [Int] = [1, 1, 1]
    var maxRows = 1
    var padding: CGFloat = 0
    weak var growth: CmsCalendarGrowth?
    weak var live: CmsPinnedLiveResize?
    var onPage: ((Int) -> Void)?
    var handledRequest: Int?
    private weak var popGesture: UIGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Each page is clipped to the page shown: a taller neighbour's last
        // week stays hidden until it settles and the calendar's height eases
        // to it, so nothing draws over the line or the card below.
        clipsToBounds = true
        scrollView.clipsToBounds = true
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.isDirectionalLockEnabled = true
        // A tap reaches a day at once; a scroll that starts cancels it, so no
        // day is picked by a swipe.
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.scrollsToTop = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        addSubview(scrollView)
        for _ in 0..<3 {
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            scrollView.addSubview(host.view)
            hosts.append(host)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Hands each host its page. A host already showing that page sees the
    /// same views again, so nothing on screen changes.
    func show(_ pages: [CmsCalendarPager.Page], environment: EnvironmentValues) {
        guard pages.count == hosts.count else { return }
        rows = pages.map(\.rows)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            for (index, page) in pages.enumerated() where signatures[index] != page.signature {
                // The calendar's environment around the page (whose runtime
                // is set inside it). Top-aligned: a host is as tall as the
                // tallest page, a page as tall as its weeks.
                hosts[index].rootView = AnyView(page.view
                    .environment(\.self, environment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
                signatures[index] = page.signature
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        // The scroll view is the calendar's frame: as the height follows a
        // swipe, the clip opens or closes with it, revealing a sixth week as
        // its month slides in and keeping it off the line and card below.
        scrollView.frame = bounds
        scrollView.contentSize = CGSize(width: width * CGFloat(hosts.count), height: height)
        let moving = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || scrolling
        UIView.performWithoutAnimation {
            // As tall as the tallest page whatever the height now, so a frame
            // of a growing swipe never lays a page out again.
            let step = growth?.rowStep ?? 0
            let hostHeight = step > 0
                ? CGFloat(maxRows) * step + 2 * padding + 8
                : CmsCalendarPaging.hostHeight(pageHeight: height)
            for (index, host) in hosts.enumerated() {
                let frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: max(hostHeight, height))
                if host.view.frame != frame { host.view.frame = frame }
            }
            if !moving, scrollView.contentOffset != CGPoint(x: width, y: 0) {
                scrollView.contentOffset = CGPoint(x: width, y: 0)
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // A back swipe from the screen's edge stays the navigation's.
        var responder: UIResponder? = self
        while let current = responder, !(current is UINavigationController) { responder = current.next }
        if let pop = (responder as? UINavigationController)?.interactivePopGestureRecognizer, pop !== popGesture {
            scrollView.panGestureRecognizer.require(toFail: pop)
            popGesture = pop
        }
    }

    // MARK: Paging

    private var scrolling = false

    /// The arrows: slide a page on, as a swipe would, then settle.
    func scroll(by step: Int) {
        let width = scrollView.bounds.width
        guard width > 0, step != 0, !scrollView.isDragging, !scrollView.isDecelerating, !scrolling else { return }
        scrolling = true
        live?.active = true
        let target = CGFloat(1 + max(-1, min(1, step))) * width
        scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: true)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        live?.active = true
    }

    /// Every frame of a scroll: the calendar's height follows it towards the
    /// neighbour's rows.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let growth else { return }
        let width = scrollView.bounds.width
        let progress = width > 0 ? (scrollView.contentOffset.x - width) / width : 0
        growth.follow(CmsCalendarPaging.growth(progress: progress, rows: rows, rowStep: growth.rowStep),
                      scale: window?.screen.scale ?? traitCollection.displayScale)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrolling = false
        settle()
    }

    /// The scroll is at rest. On a neighbour: rotate the hosts so the page
    /// shown keeps its view in the middle, put the offset back on it (the same
    /// picture, so nothing moves; the growth goes back to 0 with it), then
    /// tell the calendar, whose new page is as tall as the calendar is now.
    private func settle() {
        defer { live?.active = false }
        let width = scrollView.bounds.width
        let step = CmsCalendarPaging.settledStep(offsetX: scrollView.contentOffset.x, width: width)
        guard step != 0 else { return }
        hosts = CmsCalendarPaging.rotated(hosts, step: step)
        signatures = CmsCalendarPaging.rotated(signatures, step: step)
        rows = CmsCalendarPaging.rotated(rows, step: step)
        UIView.performWithoutAnimation {
            for (index, host) in hosts.enumerated() {
                host.view.frame.origin.x = CGFloat(index) * width
            }
            scrollView.contentOffset = CGPoint(x: width, y: 0)
        }
        onPage?(step)
    }
}
#endif
