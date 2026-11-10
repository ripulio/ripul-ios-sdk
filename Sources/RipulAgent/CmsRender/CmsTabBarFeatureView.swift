#if os(iOS)
import SwiftUI
import UIKit
import os
import Combine

// MARK: - The tab bar's feature button, drawn (docs/cms-app-view.md, "The feature button")
//
// The slot is a real tab in the system `TabView` (CmsAppView), with the
// button's label and icon, so VoiceOver, the iPad and Catalyst sidebar, More,
// Full Keyboard Access and the large-text label all treat it as the system
// does. Selecting it runs the action and leaves the selected tab as it was.
//
// The outsized disc is drawn over that tab's own button: found once in the
// window's `UITabBar` by its place among the bar's buttons (public UIKit, no
// class names) and kept weakly, its frame followed by a display link that runs only while
// something moves. Signals wake it: the bar laying out (a hidden observer view
// in the `UITabBar`), the button's layer moving or fading (KVO), and SwiftUI's
// size, trait and selection changes. Idle, nothing runs.

/// Stands in front of the tab bar controller's own delegate (SwiftUI's), passing
/// everything on, but never lets the reserved tab be selected: it runs the
/// disc's action instead. Selecting it, even for the moment before SwiftUI's
/// binding put the old tab back, took the selected tab's screens out of the
/// window and back; a page pushed then (On shift after WAC in) never got its
/// safe area and drew under the status and navigation bars.
final class CmsFeatureTabGuard: NSObject, UITabBarControllerDelegate {
    weak var original: UITabBarControllerDelegate?
    weak var tracker: CmsTabBarFeatureSlotTracker?

    init(original: UITabBarControllerDelegate?, tracker: CmsTabBarFeatureSlotTracker) {
        self.original = original
        self.tracker = tracker
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }

    private func isReserved(_ index: Int?) -> Bool {
        guard let index, let tracker, tracker.buttonCount > 0 else { return false }
        return index == tracker.slotIndex
    }

    func tabBarController(_ controller: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if isReserved(controller.viewControllers?.firstIndex(of: viewController)) {
            MainActor.assumeIsolated { tracker?.onSelect?() }
            return false
        }
        return original?.tabBarController?(controller, shouldSelect: viewController) ?? true
    }

    @available(iOS 18.0, *)
    func tabBarController(_ controller: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if isReserved(controller.tabs.firstIndex(of: tab)) {
            MainActor.assumeIsolated { tracker?.onSelect?() }
            return false
        }
        return original?.tabBarController?(controller, shouldSelectTab: tab) ?? true
    }
}

/// Where the reserved tab's button is, in the overlay's coordinates, and
/// whether the disc should show over it.
@MainActor
final class CmsTabBarFeatureSlotTracker: ObservableObject {
    struct Slot: Equatable {
        var center: CGPoint
        var size: CGSize
        /// The button's effective opacity (it fades as iOS 26's bar minimizes).
        var alpha: CGFloat
        /// A horizontal bar along the bottom of the window; else (a sidebar,
        /// iPad's top bar) the tab shows its own label and icon, no disc.
        var onBottomBar: Bool
        /// A vertical strip (the iPhone Duo's outer screen): the disc fits the strip.
        var vertical: Bool
    }

    @Published private(set) var slot: Slot?

    /// The identifier SwiftUI carries from the tab's `Label` to the bar's button
    /// (for UI tests; the tracker finds the button by its place, see `find`).
    static let identifier = "tabbar.\(CmsAppTabID.feature)"

    /// How the disc is placed, best first. Nothing here depends on a private
    /// class or on accessibility being on.
    enum Anchor: String, Comparable {
        static func < (a: Anchor, b: Anchor) -> Bool { a.rank < b.rank }
        private var rank: Int { self == .geometry ? 0 : self == .neighbours ? 1 : 2 }

        /// Over the reserved tab's own button.
        case button
        /// Midway between its neighbours' inner edges, as WAC's own app places its disc.
        case neighbours
        /// The slot's share of the bar's width (the bar's middle for a centre slot).
        case geometry
    }

    weak var host: UIView?
    private weak var button: UIView?
    private weak var left: UIView?
    private weak var right: UIView?
    private weak var bar: UITabBar?
    private(set) var anchor: Anchor?
    /// The last signal that woke the tracker (for the debug trace).
    private var lastReason = ""
    /// Holds a jump until it has lasted (`steady`).
    private var steadiness = CmsFeatureSteadiness()
    private var observers: [NSKeyValueObservation] = []
    private var link: CADisplayLink?
    private var quietUntil: CFTimeInterval = 0
    private weak var signalView: CmsLayoutSignalView?
    /// While nothing better than the bar's geometry is found (the bar's buttons
    /// draw after the site loads), look again on a timer that backs off.
    private var searchDelay: TimeInterval = 0.25
    private var searchScheduled = false
    /// Searches since the anchor was last a button; stops after a minute or so.
    private var searches = 0

    /// Counters for the idle measurement (`CmsTabBarFeatureSlotTracker.ticks`).
    static var ticks = 0

    /// Where the reserved tab sits among the bar's buttons, and how many there
    /// are (set by the overlay from CmsAppView's tabs).
    var slotIndex = 0
    var buttonCount = 0
    var slotLabel = ""
    /// The disc's action, run when the reserved tab is pressed (the guard below).
    var onSelect: (() -> Void)?
    /// Keeps the tab bar controller from ever selecting the reserved tab.
    private var tabGuard: CmsFeatureTabGuard?
    /// The buttons run down a strip (the iPhone Duo's outer screen), not across a bar.
    private var stripIsVertical = false

    /// Puts the guard in front of the controller's delegate, again if SwiftUI replaced it.
    private func guardSelection(of controller: UITabBarController) {
        if let tabGuard, controller.delegate === tabGuard { return }
        let made = CmsFeatureTabGuard(original: controller.delegate, tracker: self)
        tabGuard = made
        controller.delegate = made
        CmsFeatureLog.logger.notice("tab bar feature guards its tab from selection")
    }

    /// Something may have moved: follow the anchor for a moment.
    func wake(for seconds: CFTimeInterval = 0.8, _ reason: String = "") {
        if !reason.isEmpty { lastReason = reason }
        follow(for: seconds)
        read()
    }

    /// Run the display link for at least this long, without reading now.
    private func follow(for seconds: CFTimeInterval) {
        quietUntil = max(quietUntil, CACurrentMediaTime() + seconds)
        if link == nil {
            let link = CADisplayLink(target: CmsDisplayLinkProxy(self), selector: #selector(CmsDisplayLinkProxy.tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        observers = []
        signalView?.removeFromSuperview()
    }

    fileprivate func tick() {
        Self.ticks += 1
        let moved = read()
        let now = CACurrentMediaTime()
        if moved { quietUntil = max(quietUntil, now + 0.5) }
        if now > quietUntil {
            link?.invalidate()
            link = nil
        }
    }

    // MARK: Reading

    /// A view's frame in the window, from its presentation layer (so it follows animations).
    private func presentedFrame(_ view: UIView, in window: UIWindow) -> CGRect {
        let layer = view.layer.presentation() ?? view.layer
        guard let sv = view.superview else { return .zero }
        return (sv.layer.presentation() ?? sv.layer).convert(layer.frame, to: window.layer)
    }

    /// A view's opacity up its chain (0 when it or an ancestor is hidden).
    private func chainAlpha(_ view: UIView, in window: UIWindow) -> CGFloat {
        var alpha: CGFloat = 1
        var v: UIView? = view
        while let x = v, x !== window {
            if x.isHidden || x.layer.isHidden { return 0 }
            alpha *= CGFloat((x.layer.presentation() ?? x.layer).opacity)
            v = x.superview
        }
        return alpha
    }

    private var anchorLost: Bool {
        switch anchor {
        case .button?: return button?.window == nil
        case .neighbours?: return left?.window == nil || right?.window == nil
        case .geometry?: return false
        case nil: return true
        }
    }

    /// Read the anchor's place now. Returns whether the slot changed.
    @discardableResult
    private func read() -> Bool {
        guard let host, let window = host.window else {
            scheduleSearch()
            return publish(nil)
        }
        if anchorLost {
            // UIKit rebuilds the bar's buttons now and then (the old ones go):
            // look again from the start.
            if anchor != nil { searches = 0; searchDelay = 0.25; lastReason = "anchor lost" }
            find(in: window)
        }
        if anchor != .button { scheduleSearch() } else { searchDelay = 0.25; searches = 0 }
        let frame: CGRect
        let alpha: CGFloat
        switch anchor {
        case .button?:
            guard let button else { return publish(nil) }
            frame = presentedFrame(button, in: window)
            alpha = chainAlpha(button, in: window)
        case .neighbours?:
            guard let left, let right else { return publish(nil) }
            let l = presentedFrame(left, in: window), r = presentedFrame(right, in: window)
            // UIKit can collapse a copy of a button it keeps aside; keep the last
            // good place rather than follow it.
            guard min(l.width, l.height, r.width, r.height) >= 30 else { return false }
            frame = stripIsVertical
                ? CGRect(x: l.minX, y: l.maxY, width: l.width, height: max(1, r.minY - l.maxY))
                : CGRect(x: l.maxX, y: (l.minY + r.minY) / 2, width: max(1, r.minX - l.maxX), height: (l.height + r.height) / 2)
            alpha = min(chainAlpha(left, in: window), chainAlpha(right, in: window))
        case .geometry?:
            // The last resort, from the window alone: iOS 26's floating bar is
            // inset 25 pt from each side, with its buttons' middle 18 pt above
            // the bottom safe area (measured on the iPhone 18 Pro Max, iOS 27.0),
            // shared equally among the tabs. A centre slot is the screen's middle.
            let bottom = window.safeAreaInsets.bottom
            let inset: CGFloat = 25
            let span = CGRect(x: inset, y: window.bounds.height - max(bottom, 8) - 18 - 27,
                              width: window.bounds.width - 2 * inset, height: 54)
            let share = span.width / CGFloat(max(1, buttonCount))
            frame = CGRect(x: span.minX + share * CGFloat(slotIndex), y: span.minY, width: share, height: span.height)
            alpha = 1
        case nil:
            return publish(nil)
        }
        guard frame.width > 1, frame.height > 1 else { return publish(nil) }
        let local = window.convert(frame, to: host)
        let vertical = stripIsVertical
        // A horizontal bar along the bottom, or the Duo's strip down the side.
        let onBottomBar = vertical ? frame.minX > window.bounds.width * 0.6 : frame.midY > window.bounds.height * 0.72
        return publish(steady(Slot(center: CGPoint(x: local.midX, y: local.midY), size: local.size, alpha: alpha,
                                   onBottomBar: onBottomBar, vertical: vertical)))
    }

    /// A jump is followed only once it has held for `jumpHold`. On each tab
    /// change UIKit hands back a mid-update place for about 33 ms (x 201 → 180,
    /// and y 822 → 31, then back: measured on iOS 27.0, 31 October 2026), which
    /// made the disc flick left on Peter's phone. Movement that is smooth from
    /// frame to frame (the bar minimizing, the accessory) is followed at once;
    /// a real jump (rotation, a new size) `jumpHold` later.
    private func steady(_ new: Slot) -> Slot? {
        let decision = steadiness.next(new.center, shown: slot?.center, now: CACurrentMediaTime())
        if decision.waiting { follow(for: 0.2) }
        return decision.accept ? new : slot
    }



    /// Look again for something better than the current anchor: after 0.25,
    /// 0.5, 1, 2, 4 s, then every 8 s, twelve times in all (about a minute).
    private func scheduleSearch() {
        guard !searchScheduled, searches < 12 else { return }
        searchScheduled = true
        searches += 1
        let delay = searchDelay
        searchDelay = min(searchDelay * 2, 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.searchScheduled = false
            guard self.anchor != .button, let window = self.host?.window else { return }
            self.find(in: window)
            self.wake(for: 0.3)
        }
    }

    private func publish(_ new: Slot?) -> Bool {
        let old = slot
        let changed: Bool
        switch (old, new) {
        case (nil, nil): changed = false
        case let (a?, b?):
            changed = abs(a.center.x - b.center.x) > 0.25 || abs(a.center.y - b.center.y) > 0.25
                || abs(a.alpha - b.alpha) > 0.01 || a.onBottomBar != b.onBottomBar || a.size != b.size
        default: changed = true
        }
        if changed {
            slot = new
            #if DEBUG
            // `-RipulFeatureTrace YES`: every placement, with what placed it.
            if UserDefaults.standard.bool(forKey: "RipulFeatureTrace") {
                let c = new.map { String(format: "x=%.1f y=%.1f w=%.1f a=%.2f", $0.center.x, $0.center.y, $0.size.width, $0.alpha) } ?? "none"
                CmsFeatureLog.logger.notice("trace \(String(format: "%.3f", CACurrentMediaTime()), privacy: .public) \(self.anchor?.rawValue ?? "-", privacy: .public) \(c, privacy: .public) why=\(self.lastReason, privacy: .public)")
            }
            #endif
        }
        return changed
    }

    // MARK: Finding

    /// The anchor, with public UIKit only and without relying on accessibility
    /// (SwiftUI fills a tab button's accessibility label only while an
    /// assistive technology is on: the simulator's tools turned it on, an
    /// iPhone without VoiceOver doesn't, and the first build found nothing on
    /// Peter's phone, 30 October 2026).
    ///
    /// 1. The tab bar controller's chrome (the `UITabBar`'s controller's view,
    ///    the tabs' own screens skipped; the iPhone Duo's strip sits outside
    ///    the bar), its `UIControl`s in bar order, copies at one place merged.
    ///    Only the row most of them share counts (the selection's lens keeps a
    ///    copy of the selected tab elsewhere).
    /// 2. With as many buttons as tabs, the one at the slot's index; the
    ///    accessibility label confirms it when there is one.
    /// 3. With one fewer (the reserved tab drawn at no width), its neighbours.
    /// 4. Else the bar's own geometry.
    private func find(in window: UIWindow) {
        var bars: [UITabBar] = []
        func findBars(_ v: UIView) {
            if let bar = v as? UITabBar, !bar.isHidden, bar.bounds.width > 1 { bars.append(bar) }
            v.subviews.forEach(findBars)
        }
        findBars(window)
        guard let bar = bars.first else { return }
        var responder: UIResponder? = bar
        while let r = responder, !(r is UITabBarController) { responder = r.next }
        let controller = responder as? UITabBarController
        if let controller { guardSelection(of: controller) }
        let root: UIView = controller?.view ?? bar.superview ?? bar
        let screens = Set((controller?.viewControllers ?? []).compactMap { $0.viewIfLoaded }.map(ObjectIdentifier.init))
        var controls: [UIControl] = []
        func collect(_ v: UIView) {
            if screens.contains(ObjectIdentifier(v)) { return }
            if let c = v as? UIControl, !(c is UITabBar), !c.isHidden, c.bounds.width >= 24, c.bounds.height >= 24,
               c.bounds.width < 240, c.bounds.height < 140 {
                controls.append(c)
            }
            v.subviews.forEach(collect)
        }
        collect(root)
        let framed = controls.map { (view: $0 as UIView, frame: $0.convert($0.bounds, to: window)) }
        let xs = framed.map(\.frame.midX), ys = framed.map(\.frame.midY)
        let vertical = (ys.max() ?? 0) - (ys.min() ?? 0) > (xs.max() ?? 0) - (xs.min() ?? 0)
        // The row most of them share: the bar's (or the strip's column).
        var rows: [(cross: CGFloat, members: [(view: UIView, frame: CGRect)])] = []
        for f in framed {
            let cross = vertical ? f.frame.midX : f.frame.midY
            if let i = rows.firstIndex(where: { abs($0.cross - cross) < 6 }) { rows[i].members.append(f) }
            else { rows.append((cross, [f])) }
        }
        var row = rows.max { $0.members.count < $1.members.count }?.members ?? []
        // The bar's buttons share a size; drop the odd ones out (iOS 27.0 keeps
        // a 48 pt compact copy of the first tab on the same row, for the
        // minimized bar, beside the 85 pt buttons).
        let sizes = row.map { vertical ? $0.frame.height : $0.frame.width }.sorted()
        if !sizes.isEmpty {
            let median = sizes[sizes.count / 2]
            row = row.filter { abs((vertical ? $0.frame.height : $0.frame.width) - median) <= median * 0.15 }
        }
        var groups: [(key: CGFloat, view: UIView)] = []
        for f in row {
            let key = vertical ? f.frame.midY : f.frame.midX
            if let i = groups.firstIndex(where: { abs($0.key - key) < 8 }) {
                if f.view.alpha > groups[i].view.alpha { groups[i].view = f.view }
            } else {
                groups.append((key, f.view))
            }
        }
        groups.sort { $0.key < $1.key }
        // A search never trades a working anchor for a worse one: a bar caught
        // mid-layout (one button drawn) must not move a placed disc.
        let current = anchorLost ? nil : anchor
        func better(_ a: Anchor) -> Bool { current.map { a > $0 } ?? true }
        self.bar = bar
        // The strip's direction is learnt only from a full row of buttons.
        if groups.count >= 2 { stripIsVertical = vertical }

        let previous = anchor
        #if DEBUG
        // `-RipulFeatureIgnoreLabels YES`: find the button as a phone without VoiceOver must.
        let ignoreLabels = UserDefaults.standard.bool(forKey: "RipulFeatureIgnoreLabels")
        #else
        let ignoreLabels = false
        #endif
        let byLabel = ignoreLabels ? nil : groups.first { $0.view.accessibilityLabel == slotLabel }?.view
        #if DEBUG
        // `-RipulFeatureForceAnchor neighbours|geometry`: try a fallback on purpose.
        let forced = UserDefaults.standard.string(forKey: "RipulFeatureForceAnchor")
        #else
        let forced: String? = nil
        #endif
        if forced == "neighbours" {
            if groups.count == buttonCount, slotIndex > 0, slotIndex + 1 < groups.count, better(.neighbours) {
                left = groups[slotIndex - 1].view
                right = groups[slotIndex + 1].view
                set(.neighbours, button: nil)
            }
        } else if forced == "geometry" {
            if current == nil { set(.geometry, button: nil) }
        } else if let byLabel {
            set(.button, button: byLabel)
        } else if groups.count == buttonCount, groups.indices.contains(slotIndex) {
            set(.button, button: groups[slotIndex].view)
        } else if groups.count == buttonCount - 1, slotIndex > 0, slotIndex < groups.count, better(.neighbours) {
            left = groups[slotIndex - 1].view
            right = groups[slotIndex].view
            set(.neighbours, button: nil)
        } else if current == nil {
            set(.geometry, button: nil)
        }
        if anchor != previous {
            CmsFeatureLog.logger.notice("tab bar feature placed by \(self.anchor?.rawValue ?? "nothing", privacy: .public): \(groups.count, privacy: .public) bar buttons for \(self.buttonCount, privacy: .public) tabs, slot \(self.slotIndex, privacy: .public), labels \(groups.contains { $0.view.accessibilityLabel != nil } ? "on" : "off", privacy: .public)")
        }
    }

    private func set(_ anchor: Anchor, button: UIView?) {
        let changed = anchor != self.anchor || button !== self.button
        #if DEBUG
        if changed, UserDefaults.standard.bool(forKey: "RipulFeatureTrace") {
            let f = button.flatMap { b in b.window.map { b.convert(b.bounds, to: $0) } } ?? .zero
            CmsFeatureLog.logger.notice("trace set \(anchor.rawValue, privacy: .public) button=\(button.map { String(describing: type(of: $0)) } ?? "-", privacy: .public) frame=\(NSCoder.string(for: f), privacy: .public) why=\(self.lastReason, privacy: .public)")
        }
        #endif
        self.anchor = anchor
        self.button = button
        if changed { observe([button, left, right, bar].compactMap { $0 }.first.map { [$0] } ?? []) }
    }

    private func observe(_ views: [UIView]) {
        observers = []
        let wake: (String) -> Void = { reason in Task { @MainActor [weak self] in self?.wake(for: 0.8, reason) } }
        // Layout sets these as the bar moves, rotates, minimizes or fades. iOS 26
        // minimizes the bar on a container well above the button, so the whole
        // chain up to the window is watched (about a dozen layers).
        var seen = Set<ObjectIdentifier>()
        for start in views + [left, right].compactMap({ $0 }) {
            var v: UIView? = start
            while let view = v, !(view is UIWindow), seen.insert(ObjectIdentifier(view)).inserted {
                let layer = view.layer
                observers.append(layer.observe(\.position) { _, _ in wake("position") })
                observers.append(layer.observe(\.bounds) { _, _ in wake("bounds") })
                observers.append(layer.observe(\.opacity) { _, _ in wake("opacity") })
                observers.append(layer.observe(\.isHidden) { _, _ in wake("hidden") })
                observers.append(layer.observe(\.transform) { _, _ in wake("transform") })
                v = view.superview
            }
        }
        // The bar's own layout, through a hidden view that sizes with it.
        signalView?.removeFromSuperview()
        if let bar {
            let signal = CmsLayoutSignalView(frame: bar.bounds)
            signal.onLayout = { wake("bar layout") }
            bar.addSubview(signal)
            signalView = signal
        }
    }
}

/// `log stream --predicate 'subsystem == "io.ripul.sdk" && category == "featureButton"'`
enum CmsFeatureLog {
    static let logger = Logger(subsystem: "io.ripul.sdk", category: "featureButton")
}

/// Holds the tracker weakly, so the display link doesn't keep it alive.
private final class CmsDisplayLinkProxy: NSObject {
    weak var target: CmsTabBarFeatureSlotTracker?
    init(_ target: CmsTabBarFeatureSlotTracker) { self.target = target }
    @MainActor @objc func tick() { target?.tick() }
}

/// An invisible view that sizes with its superview and says when it lays out.
final class CmsLayoutSignalView: UIView {
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        alpha = 0
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// The overlay's own UIKit view: where the tracker measures from.
private struct CmsFeatureHostProbe: UIViewRepresentable {
    let tracker: CmsTabBarFeatureSlotTracker

    func makeUIView(context: Context) -> CmsLayoutSignalView {
        let view = CmsLayoutSignalView(frame: .zero)
        view.onLayout = { [weak tracker] in tracker?.wake(for: 0.8, "host layout") }
        tracker.host = view
        return view
    }

    func updateUIView(_ view: CmsLayoutSignalView, context: Context) {
        tracker.host = view
    }
}

// MARK: - The overlay and the disc

/// Drawn over the `TabView`: the disc at the reserved tab's button, and the
/// action's confirmation, input sheet, record form and failure alert.
struct CmsTabBarFeatureOverlay: View {
    let feature: CmsTabBarFeature
    let hasAccessory: Bool
    /// Bumped by CmsAppView when the reserved tab is selected (VoiceOver, the
    /// sidebar, More, the keyboard): runs the action.
    let selectSignal: Int
    /// Bumped by CmsAppView when VoiceOver runs the reserved tab's hold action.
    var holdSignal: Int = 0
    /// Changes when the selected tab does (the bar re-lays out).
    let selection: String
    @ObservedObject var runtime: CmsRuntime
    @StateObject private var tracker = CmsTabBarFeatureSlotTracker()
    @StateObject private var runner = CmsTabBarFeatureRunner()
    /// The reserved tab's place among the bar's buttons, and their number.
    let slotIndex: Int
    let buttonCount: Int
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL

    private var row: [String: CmsJSON]? {
        guard let q = feature.query, case .ok(let result) = runtime.state(for: q) else { return nil }
        return result.rows.first
    }

    /// The variant last drawn from a good answer: a failed or reloading check keeps it.
    @State private var lastGood: String?? = nil
    @State private var lastForeground = Date.distantPast

    /// A query the button reads that failed: its message.
    private var failed: String? {
        for q in feature.queries { if case .error(let message) = runtime.state(for: q) { return message } }
        return nil
    }

    private var loaded: Bool {
        feature.queries.allSatisfy { if case .ok = runtime.state(for: $0) { return true } else { return false } }
    }

    private var resolved: CmsTabBarFeature.Resolved {
        // Still loading: keep the state drawn (a retry, a reload), or, the first time, stay neutral
        // (dimmed) rather than draw the own look as if it were known ("WAC in" while the shift is read).
        let unsure = failed ?? (!loaded ? "loading" : nil)
        return feature.resolve(row: row, rowCount: { q in
            if case .ok(let result) = runtime.state(for: q) { return result.rows.count }
            return nil
        }, failed: unsure, previous: lastGood)
    }

    /// Why the disc shows what it shows, for the log (`featureButton`).
    private var reason: String {
        if let failed { return "check failed: \(failed)" }
        guard let q = feature.query else { return "no query" }
        switch runtime.state(for: q) {
        case .ok(let result):
            let state = result.rows.first?["state"].map { CmsCards.text($0) }
            return "\(q): \(result.rows.count) row(s)" + (state.map { ", state \($0)" } ?? "")
        default: return "\(q): loading"
        }
    }

    /// Read again at most this often when the app becomes active (WAC's app re-reads its shift on foreground).
    static let foregroundRefetch: TimeInterval = 15

    private func refetch() {
        for q in feature.queries { runtime.invalidate(q) }
    }

    var body: some View {
        let r = resolved
        let _ = configure(r)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                CmsFeatureHostProbe(tracker: tracker)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if let slot = tracker.slot, slot.onBottomBar, slot.alpha > 0.02 {
                    let size = slot.vertical ? min(r.size, max(slot.size.width, 44)) : r.size
                    let lift = slot.vertical ? 0 : CmsTabBarFeature.lift(r.lift, hasAccessory: hasAccessory)
                    disc(r, size: size)
                        // Not known (its check failed): dimmed, never drawn as "not in".
                        .opacity(Double(slot.alpha) * (r.status == .unknown ? 0.45 : 1))
                        .position(x: slot.center.x, y: slot.center.y - lift)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: geo.size) { _ in tracker.wake() }
        }
        .ignoresSafeArea()
        // The images of every variant, fetched up front so a change of state swaps at once.
        .background(preloads)
        .onAppear {
            for q in feature.queries { runtime.ensureLoaded(q) }
            tracker.wake(for: 2)
        }
        .onDisappear { tracker.stop() }
        .onReceive(tracker.$slot.map { $0 != nil }.removeDuplicates()) { placed in
            guard placed else { return }
            let ready = r.image.map { CmsFeatureImageStore.shared.image($0) != nil } ?? true
            CmsFeatureLog.logger.notice("tab bar feature disc shown, placed by \(tracker.anchor?.rawValue ?? "nothing", privacy: .public), image \(r.image == nil ? "none" : (ready ? "ready" : "loading"), privacy: .public)")
        }
        .onChange(of: selection) { _ in tracker.wake() }
        .onChange(of: sizeClass) { _ in tracker.wake(for: 1.5) }
        .onChange(of: typeSize) { _ in tracker.wake(for: 1.5) }
        .onChange(of: "\(r.variant ?? "-")|\(r.status.rawValue)|\(reason)") { _ in
            // Read now: `r` here can be the previous render's.
            let now = resolved
            if now.status == .ok && loaded { lastGood = .some(now.variant) }
            CmsFeatureLog.logger.notice("tab bar feature shows \(now.variant ?? "its own look", privacy: .public) (\(now.status.rawValue, privacy: .public)): \(reason, privacy: .public)")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard Date().timeIntervalSince(lastForeground) >= Self.foregroundRefetch else { return }
            lastForeground = Date()
            CmsFeatureLog.logger.notice("tab bar feature checks again: the app became active")
            refetch()
        }
        .onChange(of: selectSignal) { _ in run(r) }
        .onChange(of: holdSignal) { _ in runHold(r) }
        .modifier(CmsTabBarFeatureRunnerPresenter(runner: runner, runtime: runtime, label: r.label))
    }

    private func configure(_ r: CmsTabBarFeature.Resolved) {
        tracker.slotIndex = slotIndex
        tracker.buttonCount = buttonCount
        tracker.slotLabel = r.label
        tracker.onSelect = { run(r) }
    }

    private var preloads: some View {
        let images = ([feature.look.image] + feature.variants.map(\.look.image)).compactMap { $0 }
        return ZStack {
            ForEach(images, id: \.self) { CmsFeatureImage(address: $0).frame(width: 1, height: 1).opacity(0) }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func disc(_ r: CmsTabBarFeature.Resolved, size: CGFloat) -> some View {
        let face = CmsTabBarFeatureDisc(resolved: r, size: size, busy: runner.busy, theme: runtime.theme)
        Group {
            if case .menu(let json)? = r.act, let menu = CmsButtonMenu(json) {
                // The system's menu, from the disc (native-first).
                Menu {
                    ForEach(menu.items) { item in
                        Button { runMenuItem(item) } label: {
                            if let symbol = CmsButtonMenu.symbolName(item.symbol) {
                                Label(item.subtitle.map { "\(item.label)\n\($0)" } ?? item.label, systemImage: symbol)
                            } else {
                                Text(item.label)
                            }
                        }
                    }
                } label: { face }
                .menuOrder(.fixed)
            } else {
                if let hold = r.hold {
                    // Tap runs the action; press and hold fills the ring, then runs the hold's.
                    CmsFeatureHoldDisc(hold: hold, size: size, theme: runtime.theme, busy: runner.busy,
                                       onTap: { run(r) }, onHold: { runHold(r) }) { face }
                } else {
                    Button { run(r) } label: { face }
                        .buttonStyle(CmsFeaturePressStyle())
                        .disabled(runner.busy)
                }
            }
        }
        // The tab underneath is the accessible element; the disc is its picture.
        .accessibilityHidden(true)
        .accessibilityIdentifier("tabbar.feature.disc")
    }

    private func run(_ r: CmsTabBarFeature.Resolved) {
        // The state isn't known (its check failed): a tap checks again.
        if r.status == .unknown { refetch(); return }
        switch r.act {
        case .card(let action)?: runner.perform(action, row: row, runtime: runtime, openURL: { openURL($0) })
        case .menu?: break  // The disc opens the system menu itself; from the reserved tab there's no anchor.
        case nil: break
        }
    }

    /// The hold's action, with no confirm (the hold is the confirmation).
    private func runHold(_ r: CmsTabBarFeature.Resolved) {
        guard let hold = r.hold else { return }
        runner.perform(hold.act, row: row, runtime: runtime, openURL: { openURL($0) }, skipConfirm: true)
    }

    private func runMenuItem(_ item: CmsButtonMenu.Item) {
        if item.placeholder {
            runner.note = item.comingSoon
            return
        }
        if let action = CmsTabBarFeatureRunner.cardAction(menuRow: item.action ?? [:]) {
            runner.perform(action, row: row, runtime: runtime, openURL: { openURL($0) })
        }
    }
}

/// The disc's face: the image, or the fill (a role or the brand gradient) with
/// the icon; the label under it with `showLabel`.
struct CmsTabBarFeatureDisc: View {
    let resolved: CmsTabBarFeature.Resolved
    let size: CGFloat
    let busy: Bool
    let theme: CmsPortalTheme
    @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 10
    @ObservedObject private var store = CmsFeatureImageStore.shared

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if let address = resolved.image, store.image(address) != nil {
                    CmsFeatureImage(address: address)
                } else {
                    fill.clipShape(Circle())
                        .overlay(Circle().strokeBorder(theme.color(role: .paper), lineWidth: 2))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)  // theme-exempt: a drop shadow
                    // While a picture loads, its disc shows the fill alone.
                    if resolved.image == nil {
                        Image(systemName: CmsButtonMenu.symbolName(resolved.icon) ?? "plus")
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(ink)
                    }
                }
                if busy {
                    ProgressView().tint(resolved.image == nil ? ink : theme.color(role: .primary))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            if resolved.showLabel {
                Text(resolved.label)
                    .font(.system(size: min(labelSize, 16), weight: .semibold))
                    .foregroundStyle(.ripul(.text))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var fill: some View {
        if let role = resolved.fill { theme.color(role: role) } else { theme.gradient }
    }

    private var ink: Color {
        guard let role = resolved.fill else { return theme.color(role: .paper) }
        return CmsCss.contrastText(on: theme.color(role: role))
    }
}

/// The disc's pictures, kept in memory and on disk (Caches), so the disc
/// draws at once on every launch after the first and never waits on the
/// network to show (before 30 October 2026 it waited on `AsyncImage`).
@MainActor
final class CmsFeatureImageStore: ObservableObject {
    static let shared = CmsFeatureImageStore()
    @Published private(set) var images: [String: UIImage] = [:]
    private var loading: Set<String> = []

    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("io.ripul.cms.featureButton", isDirectory: true)
    }

    private static func file(for address: String) -> URL? {
        let name = address.unicodeScalars.reduce(into: UInt64(14695981039346656037)) { h, c in
            h = (h ^ UInt64(c.value)) &* 1099511628211
        }
        return folder?.appendingPathComponent(String(name, radix: 16))
    }

    func image(_ address: String) -> UIImage? {
        if let image = images[address] { return image }
        if let file = Self.file(for: address), let data = try? Data(contentsOf: file), let image = UIImage(data: data, scale: 3) {
            images[address] = image
            return image
        }
        return nil
    }

    func load(_ address: String) {
        guard image(address) == nil, !loading.contains(address), let url = URL(string: address) else { return }
        loading.insert(address)
        Task {
            defer { loading.remove(address) }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 300,
                  let image = UIImage(data: data, scale: 3) else {
                CmsFeatureLog.logger.error("tab bar feature image failed to load: \(address, privacy: .public)")
                return
            }
            if let folder = Self.folder, let file = Self.file(for: address) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            images[address] = image
        }
    }
}

/// A picture from the store; nil while it loads (the disc draws its fill meanwhile).
private struct CmsFeatureImage: View {
    let address: String
    @ObservedObject private var store = CmsFeatureImageStore.shared

    var body: some View {
        Group {
            if let image = store.image(address) {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Color.clear
            }
        }
        .onAppear { store.load(address) }
    }
}

/// The disc with press and hold: a tap runs `onTap`; held for the hold's
/// seconds, a ring in its palette role fills round the disc with a growing
/// glow (WAC's), a haptic marks the moment, and `onHold` runs. Letting go
/// early empties the ring.
private struct CmsFeatureHoldDisc<Face: View>: View {
    let hold: CmsTabBarFeature.ResolvedHold
    let size: CGFloat
    let theme: CmsPortalTheme
    let busy: Bool
    let onTap: () -> Void
    let onHold: () -> Void
    @ViewBuilder let face: () -> Face
    @State private var progress: CGFloat = 0
    @State private var pressed = false

    var body: some View {
        let ring = theme.color(role: hold.ring)
        face()
            .scaleEffect(pressed ? 0.94 : 1)
            .overlay {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ring, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size + 10, height: size + 10)
                    .shadow(color: ring.opacity(Double(progress)), radius: 4 + 14 * progress)
                    .opacity(progress > 0 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(Circle())
            .onTapGesture { if !busy { onTap() } }
            .onLongPressGesture(minimumDuration: hold.seconds, maximumDistance: 40) {
                guard !busy else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                onHold()
            } onPressingChanged: { down in
                withAnimation(.spring(duration: 0.2)) { pressed = down }
                if down {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.linear(duration: hold.seconds)) { progress = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
                }
            }
    }
}

private struct CmsFeaturePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Running the action (the cards' rules)

@MainActor
final class CmsTabBarFeatureRunner: ObservableObject {
    struct Confirm: Equatable { var slug: String; var params: [String: CmsJSON]; var message: String }
    struct Ask { var slug: String; var params: [String: CmsJSON]; var inputs: [CmsActionInputDef] }

    @Published var confirm: Confirm?
    @Published var asking: Ask?
    @Published var failure: String?
    @Published var note: String?
    @Published var recordForm: CmsRecordFormRequest?
    @Published var busy = false

    /// A menu row's action, in the action button's field names, as a card action.
    static func cardAction(menuRow o: [String: CmsJSON]) -> CmsCardAction? {
        if let spec = CmsRowFormSpec(o["form"]) { return .openForm(spec) }
        switch o.string("actionType") ?? "mutation" {
        case "navigatePage": return o.string("targetPageSlug").map { .openPage($0, params: [:]) }
        case "openUrl": return o.string("url").map { .openURL($0) }
        case "mutation": return o.string("mutationSlug").map { .run($0, inputs: [:], pending: nil) }
        default: return nil
        }
    }

    func perform(_ action: CmsCardAction, row: [String: CmsJSON]?, runtime: CmsRuntime, openURL: (URL) -> Void, skipConfirm: Bool = false) {
        switch action {
        case .openPage(let page, _), .openTab(let page):
            runtime.navigate(toPage: page)
        case .openURL(let address):
            let filled = row.flatMap { CmsListRowLayout.fill(address, row: $0) { CmsColumnPresentation(key: $0, json: [:]) } } ?? address
            if let url = URL(string: filled) { openURL(url) }
        case .openSidebar(let edge):
            runtime.openSidebar(edge: edge)
        case .openForm(let spec):
            recordForm = CmsRecordFormRequest(spec: spec, row: row ?? [:])
        case .openHost(let name):
            runtime.hostActions[name]?()
        case .openWeb(let address, let title):
            CmsWebPage.open(address, title: title, row: row, runtime: runtime)
        case .run(let slug, let inputs, _):
            let params = CmsCards.inputs(inputs, row: row)
            let def = runtime.mutationDefs[slug]
            let asked = CmsActionForm.askedInputs(def, paramMap: inputs)
            if !asked.isEmpty {
                asking = Ask(slug: slug, params: params, inputs: asked)
            } else if let message = def?.confirmMessage, !message.isEmpty, !skipConfirm {
                confirm = Confirm(slug: slug, params: params, message: message)
            } else {
                Task { await execute(slug, params: params, runtime: runtime) }
            }
        case .show, .close:
            break
        }
    }

    /// Returns a failure's message (for the input sheet, which shows it).
    @discardableResult
    func execute(_ slug: String, params: [String: CmsJSON], runtime: CmsRuntime, reportFailure: Bool = true) async -> String? {
        busy = true
        let outcome = await runtime.runMutation(slug, params: params)
        busy = false
        if case .failed(let message) = outcome {
            if reportFailure { failure = message }
            return message
        }
        if let message = runtime.mutationDefs[slug]?.successMessage, !message.isEmpty { showNote(message) }
        return nil
    }

    func showNote(_ message: String) {
        withAnimation { note = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { if note == message { note = nil } }
        }
    }
}

private struct CmsTabBarFeatureRunnerPresenter: ViewModifier {
    @ObservedObject var runner: CmsTabBarFeatureRunner
    let runtime: CmsRuntime
    let label: String

    func body(content: Content) -> some View {
        content
            .alert(label, isPresented: Binding(get: { runner.confirm != nil }, set: { if !$0 { runner.confirm = nil } })) {
                Button("Cancel", role: .cancel) {}
                Button(label) {
                    if let c = runner.confirm { Task { await runner.execute(c.slug, params: c.params, runtime: runtime) } }
                }
            } message: {
                Text(runner.confirm?.message ?? "")
            }
            .ripulSheet(isPresented: Binding(get: { runner.asking != nil }, set: { if !$0 { runner.asking = nil } })) {
                if let ask = runner.asking {
                    let def = runtime.mutationDefs[ask.slug]
                    let save: ([String: CmsJSON]) async -> String? = { form in
                        var merged = ask.params
                        merged.merge(form) { _, new in new }
                        return await runner.execute(ask.slug, params: merged, runtime: runtime, reportFailure: false)
                    }
                    if let def, def.opensRecordForm {
                        CmsRecordFormSheet(runtime: runtime, mutation: def, inputs: ask.inputs, values: ask.params, onSave: save)
                    } else {
                        CmsActionInputSheet(
                            runtime: runtime,
                            title: def?.name.flatMap { $0.isEmpty ? nil : $0 } ?? label,
                            inputs: ask.inputs,
                            confirmMessage: def?.confirmMessage,
                            confirmLabel: label,
                            onSave: save
                        )
                    }
                }
            }
            .alert("Couldn't run that", isPresented: Binding(get: { runner.failure != nil }, set: { if !$0 { runner.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(runner.failure ?? "")
            }
            .overlay(alignment: .top) {
                if let note = runner.note {
                    Text(note)
                        .font(.ripul(.subheadline))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .modifier(CmsRecordFormPresenter(runtime: runtime, request: $runner.recordForm))
            .environmentObject(runtime)
    }
}
#endif
