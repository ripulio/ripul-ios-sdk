#if os(iOS)
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
    private static let maxMountWaits = 6
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

    init(webView: WKWebView, label: String) {
        self.webView = webView
        self.label = label
        container.backgroundColor = .clear
        container.onLeftWindow = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.unmounting, self.scroller != nil, self.container.window == nil else { return }
                #if DEBUG
                NSLog("[SLOT] %@ dropped by WebKit; placing again", self.label)
                #endif
                self.slotView = nil
                self.onDropped?()
            }
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
        if slot == nil, g.layered, !isMounted, mountWaits < Self.maxMountWaits {
            mountWaits += 1
            return nil
        }
        mountWaits = 0
        let parent: UIView = slot ?? placed.scroller
        #if DEBUG
        if slot !== slotView || container.superview == nil || placed.scroller !== scroller {
            NSLog("[SLOT] %@ parent=%@", label, slot == nil ? "scroller" : "layer")
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
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { onLeftWindow?() }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
#endif
