#if os(iOS)
import Combine
import UIKit
import WebKit

/// Layout a web slot reports (see chrome-extension observeNativeAnchor): the
/// slot's rect in its scroller's content, the scroller's viewport, the content
/// height and the page's CSS width — all in rendered CSS pixels.
struct NativeSlotGeometry: Equatable {
    let anchor: NativeContentRect
    let viewport: NativeContentRect
    let contentHeight: CGFloat
    let viewportWidth: CGFloat
    /// The slot carries a NativeSlotMount (its own always-empty layer): wait
    /// for WebKit to create its view rather than settling for the scroller.
    let layered: Bool

    init?(anchor: NativeContentRect?, viewport: NativeContentRect?, contentHeight: CGFloat?, viewportWidth: CGFloat?,
          layered: Bool = false) {
        guard let anchor, anchor.isValid, let viewport, viewport.isValid,
              let contentHeight, contentHeight.isFinite, contentHeight > 0,
              let viewportWidth, viewportWidth.isFinite, viewportWidth > 0 else { return nil }
        self.anchor = anchor; self.viewport = viewport
        self.contentHeight = contentHeight; self.viewportWidth = viewportWidth
        self.layered = layered
    }
}

/// Where a slot is, resolved against WebKit's native hierarchy.
struct NativeSlotPlacement {
    /// The scroll view carrying the slot.
    let scroller: UIScrollView
    /// The slot's rect in `scroller` coordinates, at its reported size.
    let rect: CGRect
    /// Native points per CSS pixel in `scroller` (for fixed-height content).
    let unit: CGFloat
    /// Native points per CSS pixel of the page (for sizes reported back to the web).
    let pageScale: CGFloat
}

/// Mounts a native view in a web slot so that WebKit carries it.
///
/// Renderer-neutral: tool lozenges and native embeds both use it. The view is
/// parented, in order of preference, to:
///
/// 1. **The slot's own WebKit view.** The web gives the slot a NativeSlotMount
///    (an always-empty child with its own compositing layer), and WebKit hosts
///    that layer in a native view. Being empty, it is never reset when the slot
///    swaps its web fallback for native content. Parented there, our view moves in the same commit as the
///    slot when content above it reflows — history backfill, virtualizer height
///    corrections — where following position reports left it behind by up to
///    13,000pt for the frames a report takes ([LZLAG], 2026-09-26). The same
///    principle as Ionic's native Google Maps; a compositing layer instead of a
///    forced overflow scroller, so no nested scroll gestures.
/// 2. **The scroller.** When no slot view matches unambiguously, the view sits
///    in the scroller's content at the reported position and follows reports.
///
/// Neither is a DOM API, so a slot view is only accepted when it is the one
/// empty view with the slot's rect (a layered slot's mount), or when exactly one
/// view (or one ancestor chain of views) has that rect. Our own mounts are
/// never searched. Moving a mounted view (`reposition`) is
/// cheap and safe mid-scroll; placing it (`place`) creates and reparents views,
/// which callers keep out of gestures. A sentinel notices WebKit rebuilding
/// the slot view and dropping ours, and asks the owner to place it again.
@MainActor
final class NativeSlotAttachment {
    private weak var webView: WKWebView?
    private let label: String
    /// Positioned by us; the content view fills it.
    let container = SlotMountView()
    private(set) weak var scroller: UIScrollView?
    private(set) weak var slotView: UIView?
    /// Called when WebKit removed the mounted view; the owner should `place` again.
    var onDropped: (() -> Void)?
    private var unmounting = false
    /// Placements declined while a layered slot's view was still missing.
    private var mountWaits = 0
    /// A report reaches native before WebKit commits the layer it describes.
    /// Declining a placement (the owner retries ~32ms later) keeps content from
    /// landing on the scroller and being reparented a frame later — the other
    /// half of the arrival flicker. After this many, the scroller will do.
    /// About half a second: a Catalyst chat entry shows the old chat's layer
    /// for ~150ms before the new panel's views exist, and six waits (~200ms)
    /// left whole chats parented to the scroller (2026-10-09).
    private static let maxMountWaits = 15
    /// Last time a scroller-parented layered slot looked for its mount's view.
    private var lastUpgradeCheck: CFTimeInterval = 0
    /// The slot's origin (scroller coordinates, from the latest report). When
    /// riding a slot view, content frames are set relative to it: WebKit owns
    /// the slot view's position, and may not have applied the latest layout
    /// yet when the report arrives.
    private var slotOrigin: CGPoint = .zero

    /// Still riding the view we attached to: our container is inside it and it
    /// is on screen. Its identity is the proof — WebKit destroying or rebuilding
    /// it drops the container (and the sentinel fires). Rect matching is only
    /// for the first attachment: a report can arrive before WebKit applies the
    /// layout it describes, and re-matching then abandoned a good parent.
    private var ridingSlotView: UIView? {
        guard let slotView, container.superview === slotView, slotView.window != nil else { return nil }
        return slotView
    }

    /// `frameInScroller` in the coordinates of `parent`.
    private func local(_ frameInScroller: CGRect, in parent: UIView, target: UIScrollView) -> CGRect {
        if parent === slotView { return frameInScroller.offsetBy(dx: -slotOrigin.x, dy: -slotOrigin.y) }
        return parent.convert(frameInScroller, from: target)
    }

    /// Waiting to see, once the app is back, whether a view that left the
    /// window in the background came back with WebKit's layers.
    private var returnCheck: AnyCancellable?
    /// Whether the app is in the background, where WebKit's layers are off the
    /// screen. Replaceable for tests.
    static var appIsInBackground: () -> Bool = { UIApplication.shared.applicationState == .background }

    init(webView: WKWebView, label: String) {
        self.webView = webView
        self.label = label
        container.backgroundColor = .clear
        container.onLeftWindow = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.unmounting, self.scroller != nil, self.container.window == nil else { return }
                // In the background WebKit takes its layers off the screen once
                // the app-switcher pictures are drawn, and every mounted view
                // leaves the window with them: nothing has been dropped yet.
                // Placing again from there failed on every try until each strip
                // gave up, on every trip away from the app (23 October 2026:
                // about 230 placements a minute on Peter's phone).
                if Self.appIsInBackground() {
                    self.checkOnReturn()
                    return
                }
                self.dropped()
            }
        }
        container.onEnteredWindow = { [weak self] in self?.returnCheck = nil }
    }

    private func dropped() {
        #if DEBUG
        NSLog("[SLOT] %@ dropped by WebKit; placing again", label)
        #endif
        slotView = nil
        onDropped?()
    }

    /// Back in the foreground, WebKit puts its layers on the screen again, and
    /// with them every view still mounted in them (`onEnteredWindow` ends the
    /// wait). One still off the screen a moment later was dropped while away.
    private func checkOnReturn() {
        guard returnCheck == nil else { return }
        returnCheck = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .first()
            .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.returnCheck = nil
                guard !self.unmounting, self.scroller != nil, self.container.window == nil else { return }
                self.dropped()
            }
    }

    var isMounted: Bool { container.superview != nil && scroller != nil }
    var ridesSlotView: Bool { slotView != nil }

    // MARK: Resolution

    /// The scroller carrying the slot: WebKit's inner scroll view for the
    /// reported viewport (matched by frame and content height), or the outer
    /// scroll view while the content fits without scrolling. `existing` stays
    /// matched while streaming grows the content ahead of a report.
    func resolve(_ g: NativeSlotGeometry, existing: UIScrollView? = nil) -> NativeSlotPlacement? {
        guard let webView else { return nil }
        let pageScale = webView.bounds.width / g.viewportWidth
        let expected = CGRect(x: g.viewport.x * pageScale, y: g.viewport.y * pageScale,
                              width: g.viewport.width * pageScale, height: g.viewport.height * pageScale)
        var candidates: [(UIScrollView, CGFloat)] = []
        func visit(_ view: UIView) {
            if view is SlotMountView { return }
            if let scroll = view as? UIScrollView, scroll !== webView.scrollView, !scroll.isHidden {
                let actual = scroll.convert(scroll.bounds, to: webView)
                let error = abs(actual.minX - expected.minX) + abs(actual.minY - expected.minY)
                    + abs(actual.width - expected.width) + abs(actual.height - expected.height)
                let contentScale = scroll.bounds.width / g.viewport.width
                if error < 8, scroll === existing
                    || abs(scroll.contentSize.height - g.contentHeight * contentScale) < max(8, g.contentHeight * contentScale * 0.01) {
                    candidates.append((scroll, error))
                }
            }
            view.subviews.forEach(visit)
        }
        visit(webView.scrollView)
        if let scroll = candidates.min(by: { $0.1 < $1.1 })?.0 {
            return placement(in: scroll, for: g)
        }
        // WebKit creates no inner scroller until CSS content overflows; a short
        // chat's slots live in the outer scroll view until it does.
        guard g.contentHeight <= g.viewport.height + 1 else { return nil }
        return placement(in: webView.scrollView, for: g)
    }

    /// The slot's rect in `target` for a report.
    func placement(in target: UIScrollView, for g: NativeSlotGeometry) -> NativeSlotPlacement? {
        guard let webView else { return nil }
        let pageScale = webView.bounds.width / g.viewportWidth
        if target === webView.scrollView {
            let inPage = CGRect(x: (g.viewport.x + g.anchor.x) * pageScale, y: (g.viewport.y + g.anchor.y) * pageScale,
                                width: g.anchor.width * pageScale, height: g.anchor.height * pageScale)
            return NativeSlotPlacement(scroller: target, rect: target.convert(inPage, from: webView),
                                       unit: pageScale, pageScale: pageScale)
        }
        let unit = target.bounds.width / g.viewport.width
        return NativeSlotPlacement(scroller: target,
                                   rect: CGRect(x: g.anchor.x * unit, y: g.anchor.y * unit,
                                                width: g.anchor.width * unit, height: g.anchor.height * unit),
                                   unit: unit, pageScale: pageScale)
    }

    #if DEBUG
    private static func describe(_ r: CGRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", r.minX, r.minY, r.width, r.height)
    }

    /// Views of the slot's size near its reported position, for the log line
    /// written when a layered slot's view was never recognised. Searched in
    /// every scroll view under the web view, so a match in another chat's
    /// scroller (or none anywhere) shows up.
    private func nearbyViews(in target: UIScrollView, around rect: CGRect) -> String {
        guard let webView else { return "no web view" }
        var lines: [String] = []
        func scan(_ scroll: UIScrollView, tag: String) {
            var total = 0, found: [String] = []
            func visit(_ view: UIView, depth: Int) {
                if view is SlotMountView { return }
                if view !== scroll {
                    if view is UIScrollView { return }
                    total += 1
                    let frame = view.convert(view.bounds, to: scroll)
                    if abs(frame.minY - rect.minY) < 80, abs(frame.height - rect.height) < 30 {
                        found.append(String(describing: type(of: view)) + Self.describe(frame)
                                     + " d\(depth) sub\(view.subviews.count)" + (view.isHidden ? " hidden" : ""))
                    }
                }
                view.subviews.forEach { visit($0, depth: depth + 1) }
            }
            visit(scroll, depth: 0)
            let box = scroll.convert(scroll.bounds, to: webView)
            lines.append("\(tag) frame=\(Self.describe(box)) content=\(Int(scroll.contentSize.height)) offset=\(Int(scroll.contentOffset.y)) views=\(total) alpha=\(scroll.alpha) hidden=\(scroll.isHidden): "
                         + (found.isEmpty ? "none" : found.prefix(4).joined(separator: " | ")))
        }
        scan(target, tag: "target")
        func visitScrolls(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll !== target, scroll !== webView.scrollView { scan(scroll, tag: "other") }
            view.subviews.forEach(visitScrolls)
        }
        visitScrolls(webView.scrollView)
        return lines.joined(separator: " || ")
    }

    /// Why content parked on the scroller cannot ride its slot's view: how many
    /// views have the slot's rect, how many of those are empty mounts, and
    /// what there is near it. For the log line written when the climb onto
    /// the slot's view is given up.
    func describeMissingSlotView(geometry g: NativeSlotGeometry) -> String {
        guard let target = scroller, let placed = placement(in: target, for: g) else { return "no scroller" }
        var matching = 0, empty = 0
        func visit(_ view: UIView) {
            if view is SlotMountView { return }
            if view !== target {
                if view is UIScrollView { return }
                if Self.matches(view.convert(view.bounds, to: target), placed.rect) {
                    matching += 1
                    if view.subviews.allSatisfy({ $0 is SlotMountView }) { empty += 1 }
                }
            }
            view.subviews.forEach(visit)
        }
        visit(target)
        // WebKit can keep a compositing layer with no view of its own. Such a
        // layer at the slot's rect is the slot's, with nothing to parent to.
        var layers = 0, layersAtSlot = 0, layersAtSlotWithoutView = 0
        var listed: [(CGFloat, String)] = []
        func walk(_ layer: CALayer, depth: Int) {
            if layer.delegate is SlotMountView { return }
            layers += 1
            if layer !== target.layer {
                let frame = layer.convert(layer.bounds, to: target.layer)
                if Self.matches(frame, placed.rect) {
                    layersAtSlot += 1
                    if !(layer.delegate is UIView) { layersAtSlotWithoutView += 1 }
                }
                listed.append((abs(frame.midY - placed.rect.midY),
                               "\(layer.delegate.map { String(describing: type(of: $0)) } ?? "layer")\(Self.describe(frame)) d\(depth)"))
            }
            layer.sublayers?.forEach { walk($0, depth: depth + 1) }
        }
        walk(target.layer, depth: 0)
        // The layers nearest the slot, whatever their size: what WebKit made of this part of the page.
        let nearest = listed.sorted { $0.0 < $1.0 }.prefix(14).map(\.1).joined(separator: " ")
        return "slot \(Self.describe(placed.rect)) matching=\(matching) empty=\(empty) layers=\(layers) layersAtSlot=\(layersAtSlot) "
            + "withoutView=\(layersAtSlotWithoutView); nearest layers: \(nearest); near: " + nearbyViews(in: target, around: placed.rect)
    }

    /// What a slot's view is, for the line logged when content is parented to one.
    private static func describe(slotView view: UIView, in target: UIScrollView) -> String {
        var views = 0
        func count(_ view: UIView) { views += 1; view.subviews.forEach(count) }
        count(target)
        var depth = 0
        var parent = view.superview
        while let current = parent, current !== target { depth += 1; parent = current.superview }
        return "\(type(of: view)) depth=\(depth) subviews=\(view.subviews.count) animations=\(view.layer.animationKeys() ?? []) scrollerViews=\(views)"
    }
    #endif

    /// Whether any view of about the slot's height sits within 80pt of it in
    /// `target`: the row layers exist, so a mismatch is timing, not absence.
    private static func hasRowViews(in target: UIScrollView, near rect: CGRect) -> Bool {
        func visit(_ view: UIView) -> Bool {
            if view is SlotMountView { return false }
            if view !== target {
                if view is UIScrollView { return false }
                let frame = view.convert(view.bounds, to: target)
                if abs(frame.minY - rect.minY) < 80, abs(frame.height - rect.height) < 30 { return true }
            }
            return view.subviews.contains(where: visit)
        }
        return visit(target)
    }

    /// Per-edge tolerance for recognising a slot view: reports are rounded to
    /// half a CSS pixel and scaled by page zoom; WebKit snaps to device pixels.
    private static let slotTolerance: CGFloat = 1.5

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= slotTolerance && abs(a.minY - b.minY) <= slotTolerance
            && abs(a.width - b.width) <= slotTolerance && abs(a.height - b.height) <= slotTolerance
    }

    /// WebKit's view for the slot's compositing layer. Accepted only when the
    /// views with the slot's rect form one ancestor chain (the deepest is the
    /// slot's own layer; a row wrapper of the same size may enclose it).
    /// Unrelated views of the same rect are ambiguous: no guess is made.
    private func slotView(in target: UIScrollView, matching rect: CGRect, layered: Bool) -> UIView? {
        var found: [UIView] = []
        func visit(_ view: UIView) {
            if view is SlotMountView { return }
            if view !== target {
                if view is UIScrollView { return }
                if Self.matches(view.convert(view.bounds, to: target), rect) { found.append(view) }
            }
            view.subviews.forEach(visit)
        }
        visit(target)
        // A layered slot's mount is defined as always empty: the one candidate
        // whose only children are our own mounts. Other views can share its
        // rect — the web fallback's clipping box once the slot has a height.
        if layered {
            let empty = found.filter { $0.subviews.allSatisfy { $0 is SlotMountView } }
            if empty.count == 1 { return empty[0] }
        }
        guard let deepest = found.first(where: { candidate in
            found.allSatisfy { $0 === candidate || candidate.isDescendant(of: $0) }
        }) else {
            #if DEBUG
            if found.count > 1 { NSLog("[SLOT] %@ ambiguous: %d views share the slot rect", label, found.count) }
            #endif
            return nil
        }
        return deepest
    }

    // MARK: Mounting

    /// Places `content` (owned by `controller`) in the slot, creating the
    /// parent relationships and reparenting as needed. `frame` maps the slot's
    /// rect to the frame to give the content, both in scroller coordinates.
    /// Not for use mid-gesture; see `reposition`.
    @discardableResult
    func place(content: UIView, controller: UIViewController, geometry g: NativeSlotGeometry,
               frame: (NativeSlotPlacement) -> CGRect) -> NativeSlotPlacement? {
        MainThreadSampler.count("slot.place")
        guard let webView, let placed = resolve(g, existing: scroller) else { return nil }
        let kept = ridingSlotView.flatMap { $0.isDescendant(of: placed.scroller) ? $0 : nil }
        let slot = kept ?? slotView(in: placed.scroller, matching: placed.rect, layered: g.layered)
        // Wait for the mount's view only while the scroller has row-sized
        // views near the slot at all: then a report has merely beaten the
        // commit. A chat shown again after being hidden has none of its rows
        // as views for seconds (Catalyst, 2026-10-09), and waiting there just
        // left the web copies showing before every strip was rebuilt.
        if slot == nil, g.layered, !isMounted, mountWaits < Self.maxMountWaits,
           Self.hasRowViews(in: placed.scroller, near: placed.rect) {
            mountWaits += 1
            return nil
        }
        #if DEBUG
        if slot == nil, g.layered, mountWaits >= Self.maxMountWaits {
            NSLog("[SLOT] %@ no slot view for %@; near: %@", label, Self.describe(placed.rect),
                  nearbyViews(in: placed.scroller, around: placed.rect))
        }
        #endif
        mountWaits = 0
        let parent: UIView = slot ?? placed.scroller
        #if DEBUG
        if slot !== slotView || container.superview == nil || placed.scroller !== scroller {
            NSLog("[SLOT] %@ parent=%@", label, slot.map { "layer " + Self.describe(slotView: $0, in: placed.scroller) } ?? "scroller")
        }
        let before = isMounted ? container.convert(container.bounds, to: placed.scroller).minY : nil
        #endif
        if content.superview !== container {
            content.frame = container.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(content)
        }
        if controller.parent == nil {
            var responder: UIResponder? = webView
            while let current = responder {
                if let owner = current as? UIViewController {
                    owner.addChild(controller)
                    parent.addSubview(container)
                    controller.didMove(toParent: owner)
                    break
                }
                responder = current.next
            }
        }
        if container.superview !== parent { parent.addSubview(container) }
        scroller = placed.scroller
        slotView = slot
        slotOrigin = placed.rect.origin
        let target = frame(placed)
        container.frame = local(target, in: parent, target: placed.scroller)
        #if DEBUG
        if let before { NativeToolStripLagProbe.shared.record(jump: abs(target.minY - before), fast: false) }
        #endif
        return placed
    }

    /// Moves the mounted content to a new report without creating, reparenting
    /// or forcing layout — safe during a scroll. When riding the slot view,
    /// WebKit has already moved it; only the size is refreshed. Returns false
    /// when a full `place` is needed: not mounted, scroller gone, the slot view
    /// no longer matching, or a short chat that now needs its inner scroller.
    func reposition(geometry g: NativeSlotGeometry, frame: (NativeSlotPlacement) -> CGRect) -> Bool {
        MainThreadSampler.count("slot.reposition")
        guard let webView, let target = scroller, container.superview != nil, target.isDescendant(of: webView),
              let placed = placement(in: target, for: g) else { return false }
        if target === webView.scrollView, g.contentHeight > g.viewport.height + 1 { return false }
        if slotView != nil {
            guard ridingSlotView != nil else { return false }
            slotOrigin = placed.rect.origin
        } else if container.superview !== target {
            return false
        } else if g.layered, CACurrentMediaTime() - lastUpgradeCheck > 0.5 {
            // Fell back to the scroller: move onto the mount's view once it exists.
            lastUpgradeCheck = CACurrentMediaTime()
            if let slot = slotView(in: target, matching: placed.rect, layered: true) {
                #if DEBUG
                NSLog("[SLOT] %@ parent=layer (upgraded from scroller)", label)
                #endif
                slot.addSubview(container)
                slotView = slot
                slotOrigin = placed.rect.origin
            }
        }
        setFrame(frame(placed))
        return true
    }

    /// For content that fell back to the scroller of a layered slot: look for
    /// the mount's view now, ignoring the report-driven throttle, and ride it
    /// when found. Returns true once riding (already or newly). The owner
    /// calls this on its own clock for a while after a scroller placement:
    /// a strip left on the scroller moves only on a report, and a chat that
    /// goes quiet after entry never sends one.
    @discardableResult
    func upgradeToSlotView(geometry g: NativeSlotGeometry, frame: (NativeSlotPlacement) -> CGRect) -> Bool {
        guard g.layered else { return false }
        if ridingSlotView != nil { return true }
        guard let webView, let target = scroller, container.superview === target, target.isDescendant(of: webView),
              let placed = placement(in: target, for: g) else { return false }
        guard let slot = slotView(in: target, matching: placed.rect, layered: true) else { return false }
        #if DEBUG
        NSLog("[SLOT] %@ parent=layer (upgraded from scroller)", label)
        #endif
        lastUpgradeCheck = CACurrentMediaTime()
        slot.addSubview(container)
        slotView = slot
        slotOrigin = placed.rect.origin
        setFrame(frame(placed))
        return true
    }

    /// Gives the mounted content an explicit frame in scroller coordinates.
    func setFrame(_ frameInScroller: CGRect) {
        guard let parent = container.superview, let target = scroller else { return }
        let next = local(frameInScroller, in: parent, target: target)
        guard container.frame != next else { return }
        #if DEBUG
        NativeToolStripLagProbe.shared.record(jump: abs(next.minY - container.frame.minY), fast: true)
        #endif
        container.frame = next
    }

    /// The mounted content's frame in scroller coordinates.
    var frameInScroller: CGRect? {
        guard let target = scroller, container.superview != nil else { return nil }
        return container.convert(container.bounds, to: target)
    }

    /// Takes the content out of WebKit's hierarchy. `controller` is also
    /// removed from its parent when given.
    func unmount(removing controller: UIViewController? = nil) {
        returnCheck = nil
        unmounting = true
        controller?.willMove(toParent: nil)
        container.removeFromSuperview()
        controller?.removeFromParent()
        unmounting = false
        scroller = nil
        slotView = nil
    }
}

/// The view a slot's native content is mounted in. Reports leaving the window
/// (WebKit rebuilt the view it sat in), and never takes a touch itself: its
/// empty area belongs to the web content beneath.
final class SlotMountView: UIView {
    var onLeftWindow: (() -> Void)?
    var onEnteredWindow: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { onLeftWindow?() } else { onEnteredWindow?() }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
#endif
