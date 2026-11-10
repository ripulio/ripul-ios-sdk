import SwiftUI

// MARK: - Page and block levers (docs/plans/cms-home-records-levers.md)
//
// A page whose title is hidden, blocks that bleed edge to edge, a floating
// action button, and the built-in `{today}` and `{timeOfDay}` slots. Each is
// usable by any site; nothing here knows WAC.

/// How a bleeding block draws: whether it runs under the top safe area (its
/// content kept inside it) and which corners lose their radius.
struct CmsBleed: Equatable {
    /// Extra room at the top of the block's surface, so its content stays
    /// below the status bar while its surface runs under it.
    var underTop: CGFloat = 0
    var squareTop: Bool = true
    var squareBottom: Bool = true

    /// A sideways bleed in mid-page: every corner meets a side of the screen.
    static let sideways = CmsBleed()

    /// The first block of a title-hidden page, under the status bar. A block
    /// that bleeds is square at all four corners, wherever it is (the plan's
    /// rule, 9c15ebbcc): there is no special case for a header.
    static func underStatusBar(_ inset: CGFloat) -> CmsBleed {
        CmsBleed(underTop: inset, squareTop: true, squareBottom: true)
    }

    /// The block's shape with the corners that meet the screen squared.
    func shape(radius: CGFloat) -> UnevenRoundedRectangle {
        let top = squareTop ? 0 : radius
        let bottom = squareBottom ? 0 : radius
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                      bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
    }
}

private struct CmsPageMarginKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct CmsBleedKey: EnvironmentKey { static let defaultValue: CmsBleed? = nil }
private struct CmsTopBleedKey: EnvironmentKey { static let defaultValue: CmsTopBleed? = nil }
private struct CmsFloatingHostKey: EnvironmentKey { static let defaultValue = false }
private struct CmsOverlapKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct CmsStackGapKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct CmsPinnedFlowKey: EnvironmentKey { static let defaultValue: String? = nil }

/// Which block of a page bleeds under the status bar, and by how much.
struct CmsTopBleed: Equatable {
    var blockId: String
    var inset: CGFloat
}

extension EnvironmentValues {
    /// The page's side margin, which a bleeding block gives back.
    var cmsPageMargin: CGFloat {
        get { self[CmsPageMarginKey.self] }
        set { self[CmsPageMarginKey.self] = newValue }
    }

    /// Set on a bleeding block: how its own surface draws.
    var cmsBleed: CmsBleed? {
        get { self[CmsBleedKey.self] }
        set { self[CmsBleedKey.self] = newValue }
    }

    /// The page's first block when it bleeds on a title-hidden page.
    var cmsTopBleed: CmsTopBleed? {
        get { self[CmsTopBleedKey.self] }
        set { self[CmsTopBleedKey.self] = newValue }
    }

    /// True where the page draws its floating action button (its overlay).
    var cmsFloatingHost: Bool {
        get { self[CmsFloatingHostKey.self] }
        set { self[CmsFloatingHostKey.self] = newValue }
    }

    /// `overlap`: the empty surface a block's own surface adds at its bottom.
    var cmsOverlap: CGFloat {
        get { self[CmsOverlapKey.self] }
        set { self[CmsOverlapKey.self] = newValue }
    }

    /// The gap of the stack a block sits in (an overlap absorbs it).
    var cmsStackGap: CGFloat {
        get { self[CmsStackGapKey.self] }
        set { self[CmsStackGapKey.self] = newValue }
    }

    /// The pinned block (`pin: 'behind'`) whose place in the scroll content
    /// is held by an invisible copy; the page draws it fixed behind.
    var cmsPinnedFlowId: String? {
        get { self[CmsPinnedFlowKey.self] }
        set { self[CmsPinnedFlowKey.self] = newValue }
    }
}

/// Applies a block frame's `bleed`: the page's side margins given back, and
/// for the first block of a title-hidden page, the room under the status
/// bar. The block's own surface reads `cmsBleed` for its corners and inset.
struct CmsBleedModifier: ViewModifier {
    let block: CmsBlock
    @Environment(\.cmsPageMargin) private var margin
    @Environment(\.cmsTopBleed) private var topBleed

    func body(content: Content) -> some View {
        if block.frame?.bleed == true {
            if let top = topBleed, top.blockId == block.id {
                content
                    .environment(\.cmsBleed, .underStatusBar(top.inset))
                    .padding(.horizontal, -margin)
                    .padding(.top, -(margin + top.inset))
            } else {
                content
                    .environment(\.cmsBleed, .sideways)
                    .padding(.horizontal, -margin)
            }
        } else {
            content
        }
    }
}

/// Applies a block frame's `overlap: N`: its surface grows by N at the
/// bottom (the surface reads `cmsOverlap`), and the block gives back N plus
/// the stack's gap, so the next block's top sits exactly N above the
/// surface's bottom, drawn over it. The block's own content is never covered.
struct CmsOverlapModifier: ViewModifier {
    let block: CmsBlock
    @Environment(\.cmsStackGap) private var gap

    func body(content: Content) -> some View {
        if let n = block.frame?.overlap.map({ CGFloat($0) }) {
            if CmsLevers.overlapGrowsSurface(block) {
                content
                    .environment(\.cmsOverlap, n)
                    .padding(.bottom, -(n + gap))
            } else {
                // No surface to grow: the frame grows, transparent.
                content
                    .padding(.bottom, n)
                    .padding(.bottom, -(n + gap))
            }
        } else {
            content
        }
    }
}

/// `pin: 'behind'`: in the page's list the pinned block is an invisible copy
/// that holds its place and reports where its content starts and where its
/// surface ends; the page draws the real one beneath the list
/// (`CmsPinnedLayers`).
struct CmsPinnedPlaceModifier: ViewModifier {
    let block: CmsBlock
    @Environment(\.cmsPinnedFlowId) private var pinnedId
    @Environment(\.cmsTopBleed) private var topBleed
    @Environment(\.cmsStackGap) private var gap
    @Environment(\.cmsPageMargin) private var margin
    @Environment(\.cmsPinnedHeight) private var pinnedHeight
    @Environment(\.cmsPinnedGeometryReport) private var report

    func body(content: Content) -> some View {
        if pinnedId == block.id {
            // A top bleed's negative padding leaves its frame where the block
            // would have started; its content starts a margin above, at the
            // top of the page's content, below the status bar.
            let raised = topBleed?.blockId == block.id && block.frame?.bleed == true ? margin : 0
            // The overlap modifier gave back the overlap and the gap below.
            let given = block.frame?.overlap.map { CGFloat($0) + gap } ?? 0
            CmsPinnedPlace(height: pinnedHeight ?? CmsPinnedPlaceHeight(), raised: raised, given: given, report: report)
        } else {
            content
        }
    }
}

/// The held place: an empty frame the real block's height, not a copy (a
/// copy kept its own state, a calendar's month, and so its own height). It
/// alone follows the height, so a block whose height follows a gesture
/// redraws this and not the list.
private struct CmsPinnedPlace: View {
    @ObservedObject var height: CmsPinnedPlaceHeight
    let raised: CGFloat
    let given: CGFloat
    let report: CmsPinnedGeometryReport?

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height.value ?? 0)
            .accessibilityHidden(true)
            // Measured and handed straight to the layers, not as a preference: one
            // changed in the frame that read it, SwiftUI dropped the later values,
            // and a stale place hid WAC Next's Home cards (3 November 2026).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CmsPinnedSpace.name)) } action: { frame in
                report?.send(CmsPinnedGeometry(contentTop: frame.minY - raised, surfaceBottom: frame.maxY + given))
            }
    }
}

/// The pinned block's height for its place, as an object the place observes.
/// Not the height itself in the environment: a value that changed every frame
/// (a calendar's height following a swipe) reached every UIKit view in the
/// list, each one's traits updated every frame.
final class CmsPinnedPlaceHeight: ObservableObject {
    @Published var value: CGFloat?
}

private struct CmsPinnedHeightEnvKey: EnvironmentKey { static let defaultValue: CmsPinnedPlaceHeight? = nil }

extension EnvironmentValues {
    var cmsPinnedHeight: CmsPinnedPlaceHeight? {
        get { self[CmsPinnedHeightEnvKey.self] }
        set { self[CmsPinnedHeightEnvKey.self] = newValue }
    }
}

/// The pinned page content's coordinate space.
enum CmsPinnedSpace { static let name = "cms.page.content" }

/// Where the page starts covering its pinned block, in scroll content
/// points: the top of what follows (the surface's bottom less the overlap),
/// and the kept line (`pinKeep`), which moves down the content as it scrolls.
struct CmsPinnedCover: Equatable {
    var coverTop: CGFloat
    var keepTop: CGFloat?
}

private struct CmsPinnedCoverKey: EnvironmentKey { static let defaultValue: CmsPinnedCover? = nil }

extension EnvironmentValues {
    /// Set inside the pinned block: a pager there takes only drags that
    /// start where the page doesn't cover it.
    var cmsPinnedCover: CmsPinnedCover? {
        get { self[CmsPinnedCoverKey.self] }
        set { self[CmsPinnedCoverKey.self] = newValue }
    }
}

/// Set by a pinned block while its height follows a gesture frame by frame
/// (a calendar growing a week as a six-week month slides in): what follows
/// then takes each height at once, as easing it would leave it behind.
final class CmsPinnedLiveResize: ObservableObject {
    @Published var active = false
}

private struct CmsPinnedLiveResizeKey: EnvironmentKey { static let defaultValue: CmsPinnedLiveResize? = nil }

extension EnvironmentValues {
    /// Set inside the pinned block (`CmsPinnedLayers`).
    var cmsPinnedLiveResize: CmsPinnedLiveResize? {
        get { self[CmsPinnedLiveResizeKey.self] }
        set { self[CmsPinnedLiveResizeKey.self] = newValue }
    }
}

/// Where the pinned block sits in the page's scroll content, at rest.
struct CmsPinnedGeometry: Equatable {
    /// The top of its content: below the status bar's area for a top bleed.
    var contentTop: CGFloat
    /// The bottom of its surface, overlap included: where a sheet starts.
    var surfaceBottom: CGFloat
}

/// Where the place hands its geometry to the layers that draw the block.
struct CmsPinnedGeometryReport {
    let send: (CmsPinnedGeometry) -> Void
}

private struct CmsPinnedGeometryReportKey: EnvironmentKey { static let defaultValue: CmsPinnedGeometryReport? = nil }

extension EnvironmentValues {
    /// Set on the list by `CmsPinnedLayers`.
    var cmsPinnedGeometryReport: CmsPinnedGeometryReport? {
        get { self[CmsPinnedGeometryReportKey.self] }
        set { self[CmsPinnedGeometryReportKey.self] = newValue }
    }
}

/// How far the page has scrolled from its top (negative while pulled down),
/// read from the scroll view itself.
@MainActor
final class CmsScrollTracker: ObservableObject {
    @Published var scrolled: CGFloat = 0
}

#if os(iOS)
/// Watches the scroll view it sits in and publishes how far it has scrolled.
struct CmsScrollTrackerProbe: UIViewRepresentable {
    let tracker: CmsScrollTracker

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = false
        probe.tracker = tracker
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) { probe.tracker = tracker }

    final class Probe: UIView {
        weak var tracker: CmsScrollTracker?
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard let found = view as? UIScrollView, found !== scrollView else { return }
            scrollView = found
            observation = found.observe(\.contentOffset, options: [.initial, .new]) { [weak self] scroll, _ in
                let scrolled = scroll.contentOffset.y + scroll.adjustedContentInset.top
                MainActor.assumeIsolated {
                    if self?.tracker?.scrolled != scrolled { self?.tracker?.scrolled = scrolled }
                }
            }
        }
    }
}
#endif

/// The page's scroll content with a pinned block (`pin: 'behind'`):
/// - the real block drawn beneath the page's list, moved by the scroll so it
///   stays where it is (never shrinking, fading or stretching), and taking
///   taps wherever nothing covers it;
/// - `pinCover: 'sheet'`: the list rides on one sheet of the page's
///   background, from the bottom of the block's surface (overlap included)
///   to the end of the page, and at least a screen further;
/// - `pinKeep: K`: the top K points of the block's content are never covered;
///   the list is clipped there, and taps there reach the block.
struct CmsPinnedLayers<Pinned: View, List: View>: View {
    let frame: CmsBlockFrame?
    let viewportHeight: CGFloat
    let tracker: CmsScrollTracker
    /// `pinUnder: rounded`: the corners kept at the cut, and how far in from the sides the cards start.
    var cutRadius: CGFloat = 0
    var cutInset: CGFloat = 16
    @ViewBuilder let pinned: () -> Pinned
    @ViewBuilder let list: () -> List
    @State private var geometry: CmsPinnedGeometry?
    /// The geometry for the cover and the list's taps: held while the
    /// block's height is live and caught up when it ends, as the cover is an
    /// environment value and one that changed every frame reached every
    /// UIKit view in the block.
    @State private var restingGeometry: CmsPinnedGeometry?
    /// Held, not observed: the place observes it.
    @State private var placeHeight = CmsPinnedPlaceHeight()
    @State private var liveResize = CmsPinnedLiveResize()

    var body: some View {
        // Only these two modifiers read the scroll, so a scroll redraws them
        // alone and not the page's blocks.
        // pinUnder: what follows is cut at the cover line (the surface's bottom less the overlap),
        // so it goes under the block there, as WAC's screens do; else at pinKeep from the top.
        let keepTop: CGFloat? = frame?.pinUnder != nil
            ? geometry.map { $0.surfaceBottom - CGFloat(frame?.overlap ?? 0) }
            : frame?.pinKeep.flatMap { k in geometry.map { $0.contentTop + CGFloat(k) } }
        let rounded = frame?.pinUnder == "rounded" 
        ZStack(alignment: .top) {
            pinned()
                .modifier(CmsFollowScroll(tracker: tracker))
                .environment(\.cmsPinnedCover, restingGeometry.map {
                    CmsPinnedCover(coverTop: $0.surfaceBottom - CGFloat(frame?.overlap ?? 0), keepTop: keepTop)
                })
                .environment(\.cmsPinnedLiveResize, liveResize)
                // CmsPinnedHeightReport writes the block's height here; the place observes it.
                .environment(\.cmsPinnedHeight, placeHeight)
            list()
                .environment(\.cmsPinnedHeight, placeHeight)
                .environment(\.cmsPinnedGeometryReport, CmsPinnedGeometryReport { take($0) })
                .background(alignment: .top) {
                    if frame?.pinCover == "sheet", let top = geometry?.surfaceBottom {
                        CmsPageSheet()
                            .padding(.top, top)
                            .padding(.bottom, -viewportHeight)
                            .padding(.horizontal, -1)
                    }
                }
                // A sheet or a kept strip: the list takes taps only where it
                // covers the block. Clear without a strip: the list's own
                // shapes decide, so the block shows and takes taps between cards.
                .modifier(CmsPinnedListClip(tracker: tracker, keepTop: keepTop,
                                            radius: rounded ? cutRadius : 0, inset: cutInset,
                                            hitTop: frame?.pinCover == "sheet" || keepTop != nil
                                                ? restingGeometry.map { $0.surfaceBottom - CGFloat(frame?.overlap ?? 0) } : nil))
        }
        .coordinateSpace(name: CmsPinnedSpace.name)
        // Once known, a change eases with the block (a calendar switching to
        // its slim row eases `.snappy`), so what follows and the sheet move
        // with it rather than jumping ahead of it. A height following a
        // gesture (a calendar's swipe between months of five and six weeks)
        // is taken at once, frame by frame.
        .onReceive(liveResize.$active.removeDuplicates()) { active in
            if !active { restingGeometry = geometry }
        }
    }

    /// The place's geometry, whenever it changes.
    private func take(_ new: CmsPinnedGeometry) {
        guard new != geometry else { return }
        if geometry == nil || liveResize.active { geometry = new } else { withAnimation(.snappy) { geometry = new } }
        if restingGeometry == nil || !liveResize.active { restingGeometry = new }
    }
}

/// A pinned block's sheet: the site's page background, else the system's.
/// It observes the runtime, so it follows a live switch to dark mode.
struct CmsPageSheet: View {
    @EnvironmentObject private var runtime: CmsRuntime

    var body: some View {
        runtime.theme.setsPageBackground ? runtime.theme.background : Color.ripul(system: .systemBackground)
    }
}

/// Moves the pinned block by the scroll, so it stays where it is on screen.
struct CmsFollowScroll: ViewModifier {
    @ObservedObject var tracker: CmsScrollTracker
    func body(content: Content) -> some View { content.offset(y: tracker.scrolled) }
}

/// Where the list (and its sheet) can be drawn and tapped:
/// - `pinKeep` clips the drawing at the kept line, which moves down the list
///   as it scrolls;
/// - taps are limited to below both the kept line and the top of what
///   follows the pinned block (`hitTop`). A clip alone doesn't stop taps
///   (rows hidden under the strip still took them), and a hit shape that
///   started higher would make the list's empty space catch taps meant for
///   the block's uncovered part. Above `hitTop` there is only the block and
///   the overlap's empty surface, so nothing of the list is lost.
struct CmsPinnedListClip: ViewModifier {
    @ObservedObject var tracker: CmsScrollTracker
    let keepTop: CGFloat?
    var radius: CGFloat = 0
    var inset: CGFloat = 0
    let hitTop: CGFloat?

    func body(content: Content) -> some View {
        let cut = keepTop.map { $0 + tracker.scrolled }
        if let hit = CmsPinnedListClip.hitLine(cut: cut, hitTop: hitTop) {
            content
                .clipShape(CmsBelowLine(cut: cut, radius: radius, inset: inset))
                .contentShape(CmsBelowLine(cut: hit))
        } else {
            content
        }
    }

    /// The line the list takes taps below, in its own points; nil = no limit.
    static func hitLine(cut: CGFloat?, hitTop: CGFloat?) -> CGFloat? {
        switch (cut, hitTop) {
        case let (c?, h?): return max(c, h)
        case let (c?, nil): return c
        case let (nil, h?): return h
        default: return nil
        }
    }
}

/// Everything below a line (all of it when there is none), reaching well past
/// the sides and bottom so bleeding blocks and the sheet aren't cut.
struct CmsBelowLine: Shape {
    var cut: CGFloat?
    /// `pinUnder: rounded`: a card's top corners kept at the line, the cards `inset`
    /// from the sides; below the corners the full width again, so shadows aren't cut.
    var radius: CGFloat = 0
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let top = cut ?? rect.minY - 10_000
        guard radius > 0, cut != nil else {
            return Path(CGRect(x: rect.minX - 1_000, y: top, width: rect.width + 2_000,
                               height: max(0, rect.maxY + 20_000 - top)))
        }
        var path = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: radius, style: .continuous)
            .path(in: CGRect(x: rect.minX + inset, y: top, width: max(0, rect.width - inset * 2), height: radius * 2))
        path.addRect(CGRect(x: rect.minX - 1_000, y: top + radius, width: rect.width + 2_000,
                            height: max(0, rect.maxY + 20_000 - top - radius)))
        return path
    }
}

enum CmsLevers {
    /// Out of the page's flow: hidden, not on phones, the tab bar (drawn as
    /// the system's bar) or a floating action button (drawn over the page).
    /// Such a block takes no place in its list.
    static func outOfFlow(_ block: CmsBlock) -> Bool {
        if block.hidden == true { return true }
        if let on = block.visibleOn, !on.isEmpty, !on.contains("mobile") { return true }
        if block.type == CmsTabBarConfig.blockType { return true }
        return isFloatingButton(block)
    }

    /// The page's pinned block: its first, when its frame has `pin: 'behind'`.
    /// Any other block with `pin` scrolls normally.
    static func pinnedBlock(_ blocks: CmsPageBlocks?) -> CmsBlock? {
        firstBlock(blocks).flatMap { $0.frame?.pin == "behind" ? $0 : nil }
    }

    /// Whether `overlap` grows a surface of the block: the frame's own fill,
    /// or the face of a cards block or a calendar. Any other block grows its
    /// frame, transparent (the plan's settled rule).
    static func overlapGrowsSurface(_ block: CmsBlock) -> Bool {
        block.frame?.background != nil || block.type == "cards" || block.type == "simpleCalendar" || block.type == "masthead"
    }

    static func isFloatingButton(_ block: CmsBlock) -> Bool {
        block.type == "actionButton" && block.props.string("placement") == "floating"
    }

    /// The page's first block in reading order that takes room: a bleeding
    /// one reaches the top only when nothing sits above it.
    static func firstBlock(_ blocks: CmsPageBlocks?) -> CmsBlock? {
        switch blocks {
        case .list(let items, _)?, .canvas(let items, _, _, _)?, .carousel(let items, _)?:
            return items.first { !outOfFlow($0) }
        case .template(_, let slots, _)?, .sidebar(_, let slots, _)?:
            return firstBlock(slots["main"] ?? slots.values.first)
        default:
            return nil
        }
    }

    /// The page's floating action button: the first action button with
    /// `placement: 'floating'`, anywhere in the page (one per page).
    static func floatingButton(_ blocks: CmsPageBlocks?) -> CmsBlock? {
        func search(_ container: CmsPageBlocks?) -> CmsBlock? {
            switch container {
            case .list(let items, _)?, .canvas(let items, _, _, _)?, .carousel(let items, _)?:
                for item in items where item.hidden != true {
                    if isFloatingButton(item) { return item }
                    if let found = search(item.children) { return found }
                }
                return nil
            case .template(_, let slots, _)?, .sidebar(_, let slots, _)?:
                // The main region first: on a sidebar page the page's levers are its.
                for key in slots.keys.sorted(by: { ($0 == "main" ? 0 : 1, $0) < ($1 == "main" ? 0 : 1, $1) }) {
                    if let found = search(slots[key]) { return found }
                }
                return nil
            default:
                return nil
            }
        }
        return search(blocks)
    }

    // MARK: Built-in slots

    /// The device's clock, replaceable in tests.
    static var now: () -> Date = { Date() }

    /// `{today}` and `{timeOfDay}`: today's date (formatted with the slot's
    /// own format, unset = `d MMM yyyy`) and "morning" before 12:00,
    /// "afternoon" before 18:00, else "evening", on the viewer's clock and
    /// calendar. nil for any other name.
    static func builtIn(_ name: String, format: String?, now: Date = CmsLevers.now(),
                        calendar: Calendar = .current) -> String? {
        switch name {
        case "today":
            // Formatted directly as a date, not through the column format
            // engine, which reads a pattern with no y, M, d or H (`EEEE`) as
            // a number pattern. Double quotes are literal text, as in formats.
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = (format ?? "d MMM yyyy")
                .replacingOccurrences(of: #""([^"]*)""#, with: "'$1'", options: .regularExpression)
            return f.string(from: now)
        case "timeOfDay":
            let hour = calendar.component(.hour, from: now)
            return hour < 12 ? "morning" : hour < 18 ? "afternoon" : "evening"
        default:
            return nil
        }
    }

    /// `groupDefaultExpanded`: AG Grid's depth. The iPhone list has one level
    /// of groups, so any depth but 0 starts them open.
    static func groupsStartOpen(_ depth: Double?) -> Bool {
        guard let depth else { return false }
        return depth != 0
    }
}
