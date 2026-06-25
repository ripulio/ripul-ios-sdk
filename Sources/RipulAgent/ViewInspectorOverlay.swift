#if os(iOS)
import SwiftUI
import UIKit
import ObjectiveC

/// Tag stamped by `RipulViewExplorer` on its overlay host view so the inspector's
/// hit-walks can recognise and skip their own subtree (arbitrary, collision-unlikely).
let ripulViewExplorerOverlayTag = 0x5249_5055   // "RIPU"

// MARK: - View Inspector Overlay
//
// Native equivalent of the web ElementDebuggerOverlay. When active, a
// transparent full-screen layer captures touches. A virtual cursor (crosshair)
// tracks relative finger movement (Jump-Desktop style) so the target is never
// occluded by the thumb. The UIView under the cursor is highlighted and its
// properties are shown in a draggable HUD.

// MARK: - UIKit Identifier Registry
//
// SwiftUI views ≠ UIKit views. There's no reliable way to map from the UIKit
// view that hitTest returns to the SwiftUI view that had .uiKitIdentifier().
//
// Simple approach: each .uiKitIdentifier() modifier inserts a tiny background
// UIView that registers itself (with its window-space frame) in a global registry.
// When the inspector needs to resolve an identifier at a point, it iterates all
// registered views and picks the smallest frame containing that point — like the
// web inspector's elementsFromPoint() finding the tightest data-ui match.

public final class UIKitIdentifierRegistry {
    public static let shared = UIKitIdentifierRegistry()
    private let map = NSMapTable<UIView, NSString>.weakToStrongObjects()

    public func register(_ view: UIView, identifier: String) {
        map.setObject(identifier as NSString, forKey: view)
    }

    public func identifier(for view: UIView) -> String? {
        map.object(forKey: view) as String?
    }

    /// Find the identifier whose registered view best matches `windowPoint`.
    ///
    /// Two-pass algorithm:
    /// 1. Collect all stamper views whose frame contains the point.
    /// 2. Compare by **Z-order first** (frontmost wins), then by **area**
    ///    (smallest wins among views at the same Z-level).
    ///
    /// Z-order is determined by walking each view's superview chain to the
    /// window root and recording the subview index at each level. Comparing
    /// these index-paths lexicographically (from root to leaf) tells us which
    /// view is rendered in front — exactly like comparing layer order in a
    /// depth-first traversal.
    func bestMatch(at windowPoint: CGPoint) -> (identifier: String, view: UIView)? {
        struct Candidate {
            let view: UIView
            let identifier: String
            let area: CGFloat
            let zPath: [Int]   // root-to-leaf subview indices
        }

        var candidates: [Candidate] = []
        let enumerator = map.keyEnumerator()
        while let view = enumerator.nextObject() as? UIView {
            guard view.window != nil, !view.isHidden else { continue }
            guard !Self.isOccludedByAncestor(view) else { continue }
            let frame = view.convert(view.bounds, to: nil)
            guard frame.contains(windowPoint) else { continue }
            guard let id = map.object(forKey: view) as? String else { continue }
            let area = frame.width * frame.height
            let zPath = Self.zOrderPath(of: view)
            candidates.append(Candidate(view: view, identifier: id, area: area, zPath: zPath))
        }

        guard !candidates.isEmpty else { return nil }

        // Sort: higher z-order first, then smaller area first
        candidates.sort { a, b in
            let cmp = Self.compareZPaths(a.zPath, b.zPath)
            if cmp != 0 { return cmp > 0 }  // higher z-order wins
            return a.area < b.area           // smaller area wins as tiebreaker
        }

        let best = candidates[0]
        return (best.identifier, best.view)
    }

    /// Build a root-to-leaf array of subview indices for Z-order comparison.
    private static func zOrderPath(of view: UIView) -> [Int] {
        var path: [Int] = []
        var current = view
        while let parent = current.superview {
            let idx = parent.subviews.firstIndex(of: current) ?? 0
            path.append(idx)
            current = parent
        }
        path.reverse()
        return path
    }

    /// Compare two z-order paths lexicographically.
    /// Returns >0 if `a` is in front, <0 if `b` is in front, 0 if equal.
    private static func compareZPaths(_ a: [Int], _ b: [Int]) -> Int {
        let len = min(a.count, b.count)
        for i in 0..<len {
            if a[i] != b[i] { return a[i] - b[i] }
        }
        // Deeper view is "inside" the shallower one — treat deeper as in front
        return a.count - b.count
    }

    /// Returns true if any ancestor of `view` is effectively invisible
    /// (hidden or alpha ≈ 0). This filters out views inside always-mounted
    /// but invisible layers (e.g. `.opacity(0)` screens in a ZStack).
    private static func isOccludedByAncestor(_ view: UIView) -> Bool {
        var current = view.superview
        while let v = current {
            if v.isHidden || v.alpha < 0.01 { return true }
            current = v.superview
        }
        return false
    }
}

private struct UIKitIdentifierStamper: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        // Not hidden — needs a valid frame for spatial lookup.
        // Fully transparent so it's invisible.
        v.backgroundColor = .clear
        v.alpha = 0.01
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Register ourselves. Our frame matches the content's frame
        // because .background() sizes us to fit.
        UIKitIdentifierRegistry.shared.register(uiView, identifier: identifier)
    }
}

public extension View {
    /// Assigns a logical identifier visible to the View Inspector.
    /// Uses a background UIView registered in a spatial lookup — the inspector
    /// finds the tightest match at the cursor point, no tree walking needed.
    func uiKitIdentifier(_ identifier: String) -> some View {
        self
            .accessibilityIdentifier(identifier)
            .background(UIKitIdentifierStamper(identifier: identifier))
    }
}

// MARK: - Inspected View Model

struct InspectedView {
    let view: UIView
    let className: String
    let accessibilityId: String?
    let accessibilityLabel: String?
    let frame: CGRect
    let frameInWindow: CGRect
    let backgroundColor: UIColor?
    let alpha: CGFloat
    let isHidden: Bool
    let clipsToBounds: Bool
    let tag: Int
    let layer: LayerInfo
    let childCount: Int
    let depth: Int

    // Source-finding hints. UIKit screens rarely set accessibilityIdentifier, so
    // these give other ways to locate the element in code.
    let text: String?                  // UILabel / UIButton / UITextField / UITextView
    let imageName: String?             // SF Symbol or asset name (best-effort)
    let owningViewController: String?  // nearest VC up the responder chain → the file
    let viewControllerChain: [String]  // full VC chain, nearest first
    let controlActions: [String]       // "TargetClass.selector" for UIControl targets
    let restorationIdentifier: String?
    let container: String?             // nearest app-defined ancestor view (e.g. a cell)
    let propertyRef: String?           // "Owner.property" if a VC/cell holds this view (IBOutlet or stored prop)

    struct LayerInfo {
        let cornerRadius: CGFloat
        let borderWidth: CGFloat
        let borderColor: UIColor?
        let shadowRadius: CGFloat
        let shadowOpacity: Float
    }

    static func inspect(_ view: UIView, depth: Int = 0, resolvedIdentifier: String? = nil) -> InspectedView {
        let className = String(describing: type(of: view))
        let frameInWindow = view.convert(view.bounds, to: nil)
        let resolvedId = resolvedIdentifier
        let vcChain = viewControllerChain(of: view)
        return InspectedView(
            view: view,
            className: className,
            accessibilityId: resolvedId,
            accessibilityLabel: view.accessibilityLabel,
            frame: view.frame,
            frameInWindow: frameInWindow,
            backgroundColor: view.backgroundColor,
            alpha: view.alpha,
            isHidden: view.isHidden,
            clipsToBounds: view.clipsToBounds,
            tag: view.tag,
            layer: LayerInfo(
                cornerRadius: view.layer.cornerRadius,
                borderWidth: view.layer.borderWidth,
                borderColor: view.layer.borderColor.map { UIColor(cgColor: $0) },
                shadowRadius: view.layer.shadowRadius,
                shadowOpacity: view.layer.shadowOpacity
            ),
            childCount: view.subviews.count,
            depth: depth,
            text: textContent(of: view),
            imageName: imageName(of: view),
            owningViewController: vcChain.first,
            viewControllerChain: vcChain,
            controlActions: controlActions(of: view),
            restorationIdentifier: nonEmpty(view.restorationIdentifier),
            container: nearestAppView(of: view, excluding: className),
            propertyRef: propertyReference(of: view)
        )
    }

    // MARK: Source-finding extractors

    /// Visible text of the common text-bearing controls.
    static func textContent(of v: UIView) -> String? {
        if let l = v as? UILabel { return nonEmpty(l.text) }
        if let f = v as? UITextField { return nonEmpty(f.text) ?? nonEmpty(f.placeholder) }
        if let t = v as? UITextView { return nonEmpty(t.text) }
        if let b = v as? UIButton { return nonEmpty(b.title(for: .normal)) ?? nonEmpty(b.titleLabel?.text) }
        return nil
    }

    /// SF Symbol or asset name for image-bearing views, best-effort.
    static func imageName(of v: UIView) -> String? {
        let image: UIImage?
        if let iv = v as? UIImageView { image = iv.image }
        else if let b = v as? UIButton { image = b.image(for: .normal) ?? b.currentImage }
        else { image = nil }
        guard let img = image else { return nil }
        return symbolOrAssetName(from: img)
    }

    /// Crash-safe: parse `UIImage.description` (string ops only — no private KVC)
    /// for an SF Symbol or asset name. Returns nil when the description carries
    /// none. Only the precise markers are trusted (the loose "name = " form
    /// false-matched non-name tokens in configuration dumps), and the result is
    /// validated so structural noise never leaks through as a fake asset name.
    static func symbolOrAssetName(from image: UIImage) -> String? {
        let desc = image.description
        for marker in ["named(", "name: '", "systemName: "] {
            guard let r = desc.range(of: marker) else { continue }
            let stop = CharacterSet(charactersIn: "',)>= \n\t")
            let scalars = desc[r.upperBound...].unicodeScalars.prefix { !stop.contains($0) }
            let name = String(String.UnicodeScalarView(scalars))
            if isPlausibleAssetName(name) { return name }
        }
        return nil
    }

    /// Guards against `UIImage.description` noise being shown as a real name.
    static func isPlausibleAssetName(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 64 else { return false }
        if s.rangeOfCharacter(from: CharacterSet(charactersIn: ":=(){}<>,;")) != nil { return false }
        return s.rangeOfCharacter(from: .letters) != nil   // reject pure numbers / hex
    }

    /// Nearest ancestor (or the view itself) whose class is defined in the app
    /// bundle — typically a UITableViewCell / UICollectionViewCell subclass or a
    /// custom view. That class name is the most greppable handle for views that
    /// carry no text/identifier. `excluding` skips it when it equals the leaf's
    /// own class (already shown as Class).
    static func nearestAppView(of v: UIView, excluding ownClass: String) -> String? {
        var cur: UIView? = v
        while let c = cur {
            if Bundle(for: type(of: c)) == Bundle.main {
                let name = String(describing: type(of: c))
                if name != ownClass { return name }
            }
            cur = c.superview
        }
        return nil
    }

    /// "TargetClass.selector" for every target/action wired on a UIControl — the
    /// most direct way to jump to the handler in source.
    static func controlActions(of v: UIView) -> [String] {
        guard let c = v as? UIControl else { return [] }
        let events: [UIControl.Event] = [.touchUpInside, .primaryActionTriggered, .valueChanged,
                                         .editingChanged, .editingDidBegin, .editingDidEnd,
                                         .editingDidEndOnExit, .touchDown, .touchUpOutside]
        var out: [String] = []
        for target in c.allTargets {
            let tName = String(describing: type(of: target))
            for ev in events {
                for sel in c.actions(forTarget: target, forControlEvent: ev) ?? [] {
                    let entry = "\(tName).\(sel)"
                    if !out.contains(entry) { out.append(entry) }
                }
            }
        }
        return out
    }

    /// View-controller classes up the responder chain, nearest first. The first
    /// entry is the controller whose view hosts this element — i.e. the file.
    static func viewControllerChain(of v: UIView) -> [String] {
        var out: [String] = []
        var responder: UIResponder? = v
        while let r = responder {
            if let vc = r as? UIViewController {
                out.append(String(describing: type(of: vc)))
            }
            responder = r.next
        }
        return out
    }

    /// "Owner.property" when a view controller or app-defined ancestor view holds
    /// this view in a stored property (almost always an @IBOutlet, occasionally a
    /// plain stored var). Pure runtime reflection over the app's own class layers —
    /// no annotation, no build step. An outlet name is unique within its owner and
    /// directly greppable, so this is usually the most precise source handle.
    static func propertyReference(of view: UIView) -> String? {
        var owners: [NSObject] = []
        // App-defined ancestor views (cells, custom views) — nearest first.
        var v: UIView? = view.superview
        while let cur = v {
            if Bundle(for: type(of: cur)) == .main { owners.append(cur) }
            v = cur.superview
        }
        // Owning view controllers, via the responder chain.
        var r: UIResponder? = view
        while let resp = r {
            if let vc = resp as? UIViewController, Bundle(for: type(of: vc)) == .main {
                owners.append(vc)
            }
            r = resp.next
        }
        for owner in owners {
            if let name = storedPropertyName(on: owner, pointingTo: view) {
                return "\(String(describing: type(of: owner))).\(name)"
            }
        }
        return nil
    }

    /// Scan the owner's own class layers (app bundle only — never UIKit internals)
    /// for a stored object property/ivar whose value is `target`, and return its name.
    private static func storedPropertyName(on owner: NSObject, pointingTo target: UIView) -> String? {
        // Pass 0 — Swift Mirror. Reflects Swift stored properties directly, so it
        // catches what the Obj-C runtime misses: `private`/`let`/non-@objc
        // programmatic views (e.g. `private let logoImageView = UIImageView()`),
        // as well as weak outlets. Walk superclass mirrors for inherited props.
        var mirror: Mirror? = Mirror(reflecting: owner)
        while let m = mirror {
            for child in m.children {
                if let label = child.label, (child.value as? UIView) === target {
                    return label
                }
            }
            mirror = m.superclassMirror
        }

        var cls: AnyClass? = type(of: owner)
        while let c = cls, Bundle(for: c) == Bundle.main {
            // Pass 1 — @objc stored object properties, read via KVC. KVC resolves
            // WEAK references correctly (object_getIvar does not), and almost every
            // @IBOutlet is `weak`, so this is the case that actually matters.
            var pCount: UInt32 = 0
            if let props = class_copyPropertyList(c, &pCount) {
                defer { free(props) }
                for i in 0..<Int(pCount) {
                    let name = String(cString: property_getName(props[i]))
                    guard let attrsC = property_getAttributes(props[i]) else { continue }
                    let attrs = String(cString: attrsC)
                    // Object type ("T@…") and ivar-backed (",V…") → a stored property.
                    // Skips scalars and computed props (no side effects on read).
                    guard attrs.hasPrefix("T@"), attrs.contains(",V") else { continue }
                    // Only the default getter (== property name); guard avoids any
                    // KVC "not compliant" exception and rare custom-getter accessors.
                    guard owner.responds(to: NSSelectorFromString(name)) else { continue }
                    if (owner.value(forKey: name) as AnyObject?) === target { return name }
                }
            }
            // Pass 2 — strong, non-@objc Swift stored properties (object_getIvar is
            // reliable for strong refs; weak ones were handled in pass 1).
            var iCount: UInt32 = 0
            if let ivars = class_copyIvarList(c, &iCount) {
                defer { free(ivars) }
                for i in 0..<Int(iCount) {
                    let ivar = ivars[i]
                    guard let enc = ivar_getTypeEncoding(ivar), enc.pointee == 64 else { continue }
                    if (object_getIvar(owner, ivar) as AnyObject?) === target,
                       let namePtr = ivar_getName(ivar) {
                        var name = String(cString: namePtr)
                        if name.hasPrefix("_") { name.removeFirst() }
                        return name
                    }
                }
            }
            cls = class_getSuperclass(c)
        }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// A compact, greppable one-paste reference for finding this element in source.
    func sourceReference() -> String {
        var lines = ["class: \(className)"]
        if let p = propertyRef { lines.append("property: \(p)") }
        if let c = container { lines.append("container: \(c)") }
        if let vc = owningViewController { lines.append("controller: \(vc)") }
        if let t = text { lines.append("text: \"\(t)\"") }
        if let img = imageName { lines.append("image: \(img)") }
        if let aid = accessibilityId, !aid.isEmpty { lines.append("a11yId: \(aid)") }
        if let label = accessibilityLabel, !label.isEmpty { lines.append("a11yLabel: \(label)") }
        if let rid = restorationIdentifier { lines.append("restorationId: \(rid)") }
        if tag != 0 { lines.append("tag: \(tag)") }
        for a in controlActions { lines.append("action: \(a)") }
        if viewControllerChain.count > 1 {
            lines.append("vcChain: \(viewControllerChain.joined(separator: " ← "))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Tree Node

struct ViewTreeNode: Identifiable {
    let id = UUID()
    let view: UIView
    let label: String
    let depth: Int
    var children: [ViewTreeNode]

    static func build(from view: UIView, depth: Int = 0, maxDepth: Int = 12) -> ViewTreeNode {
        let label = Self.nodeLabel(view)
        let children: [ViewTreeNode]
        if depth < maxDepth {
            children = view.subviews.map { build(from: $0, depth: depth + 1, maxDepth: maxDepth) }
        } else {
            children = []
        }
        return ViewTreeNode(view: view, label: label, depth: depth, children: children)
    }

    static func nodeLabel(_ view: UIView) -> String {
        var s = String(describing: type(of: view))
        // Shorten SwiftUI hosting prefixes
        if s.hasPrefix("_") { s = String(s.dropFirst()) }
        if let regId = UIKitIdentifierRegistry.shared.identifier(for: view) {
            s += " [\(regId)]"
        } else if let aid = view.accessibilityIdentifier, !aid.isEmpty {
            s += " [\(aid)]"
        }
        return s
    }
}

// MARK: - Inspector Controller (UIKit)

/// Transparent UIView installed over the key window that captures all touches
/// and implements the virtual cursor + hit testing.
class ViewInspectorController: UIView {
    var onInspect: ((InspectedView) -> Void)?
    var onCursorMoved: ((CGPoint) -> Void)?
    var onDismiss: (() -> Void)?

    private let cursorAccel: CGFloat = 1.4
    private var cursorPos: CGPoint
    private var lastTouch: CGPoint?

    // Highlight layer drawn around the selected view
    private let highlightLayer = CAShapeLayer()

    override init(frame: CGRect) {
        cursorPos = CGPoint(x: frame.width / 2, y: frame.height / 2)
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false

        highlightLayer.fillColor = UIColor.systemPink.withAlphaComponent(0.12).cgColor
        highlightLayer.strokeColor = UIColor.systemPink.cgColor
        highlightLayer.lineWidth = 2
        layer.addSublayer(highlightLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func resetCursor() {
        cursorPos = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        onCursorMoved?(cursorPos)
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let loc = t.location(in: self)
        lastTouch = loc
        pickAt(cursorPos)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let last = lastTouch else { return }
        let loc = t.location(in: self)
        let dx = (loc.x - last.x) * cursorAccel
        let dy = (loc.y - last.y) * cursorAccel
        lastTouch = loc

        cursorPos.x = max(0, min(bounds.width - 1, cursorPos.x + dx))
        cursorPos.y = max(0, min(bounds.height - 1, cursorPos.y + dy))
        onCursorMoved?(cursorPos)
        pickAt(cursorPos)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastTouch = nil
    }

    // MARK: Hit testing

    private func pickAt(_ point: CGPoint) {
        guard let window = self.window else { highlightLayer.path = nil; return }
        let windowPoint = convert(point, to: nil)

        // Probe what's under the cursor. We must make the ENTIRE inspector overlay
        // transparent to hitTest, not just the touch layer: a launcher-presented
        // overlay's full-screen UIHostingController view has default user
        // interaction, so it claims the probe and hitTest never reaches the app.
        // Disabling the tagged overlay root lets hitTest resolve through every
        // passthrough layer — ours AND the system floating tab-bar host
        // (FloatingBarHostingView) — to the real top-most app view at the point.
        let overlayRoot = inspectorOverlayRoot()
        let savedRootInteraction = overlayRoot?.isUserInteractionEnabled ?? true
        isUserInteractionEnabled = false
        isHidden = true
        overlayRoot?.isUserInteractionEnabled = false
        var hit = window.hitTest(windowPoint, with: nil)
        overlayRoot?.isUserInteractionEnabled = savedRootInteraction
        isHidden = false
        isUserInteractionEnabled = true

        // Belt-and-suspenders: if hitTest still gave nothing usable (or our own
        // overlay), fall back to a geometric walk of the window that ignores
        // interactivity and excludes our overlay subtree.
        if hit == nil || hit === self.window || isInspectorOwnView(hit!) {
            hit = deepestView(in: window, at: windowPoint)
        }

        guard let hitView = hit, !isInspectorOwnView(hitView) else {
            highlightLayer.path = nil
            return
        }

        // `hitTest` only returns user-interaction-enabled views, so on a UIKit
        // screen it lands on the nearest interactive container (cell, button,
        // scroll view) and skips the labels / image views / decorative subviews
        // that make up most of the UI. Refine downward through the hit view's own
        // subtree — a geometric walk that ignores `isUserInteractionEnabled` (and
        // our own overlay) — to reach the deepest leaf under the cursor.
        let target = deepestDescendant(of: hitView, at: windowPoint)

        // Spatial lookup: find the tightest .uiKitIdentifier() match at this point
        let match = UIKitIdentifierRegistry.shared.bestMatch(at: windowPoint)

        // Highlight the registry match's frame if available, otherwise the hit view
        let highlightView = match?.view ?? target
        let frameInWindow = highlightView.convert(highlightView.bounds, to: nil)
        let frameInSelf = convert(frameInWindow, from: nil)
        highlightLayer.path = UIBezierPath(roundedRect: frameInSelf, cornerRadius: highlightView.layer.cornerRadius).cgPath

        // Inspect — pass the resolved identifier from spatial lookup
        let info = InspectedView.inspect(target, depth: viewDepth(target), resolvedIdentifier: match?.identifier)
        onInspect?(info)
    }

    /// True if `v` is part of the inspector's own overlay (the touch layer, the
    /// crosshair, the draggable HUD's PassthroughRootView, or — for a
    /// launcher-presented overlay — the tagged host view). Checks `v` and its
    /// ancestor chain, so any descendant of the overlay is caught too. App views
    /// are never inside this subtree, so their ancestor walk returns false.
    private func isInspectorOwnView(_ v: UIView) -> Bool {
        var cur: UIView? = v
        while let c = cur {
            if c === self { return true }
            if c.tag == ripulViewExplorerOverlayTag { return true }
            if c is PassthroughRootView { return true }
            cur = c.superview
        }
        return false
    }

    /// The launcher's tagged overlay host (walking up from the touch layer), or
    /// nil for the SwiftUI `.overlay` mount where the overlay shares the host's
    /// hosting view and there's no separate full-screen container to neutralise.
    private func inspectorOverlayRoot() -> UIView? {
        var cur: UIView? = self
        while let c = cur {
            if c.tag == ripulViewExplorerOverlayTag { return c }
            cur = c.superview
        }
        return nil
    }

    /// Deepest, frontmost view at `windowPoint` across the whole window tree,
    /// ignoring `isUserInteractionEnabled` and excluding the inspector's own
    /// overlay. Used when hitTest gives nothing usable.
    private func deepestView(in root: UIView, at windowPoint: CGPoint) -> UIView? {
        var best: UIView? = nil
        func walk(_ v: UIView) {
            for sub in v.subviews {
                guard !sub.isHidden, sub.alpha > 0.01, !isInspectorOwnView(sub) else { continue }
                let local = sub.convert(windowPoint, from: nil)
                if sub.bounds.contains(local) {
                    best = sub
                    walk(sub)
                }
            }
        }
        walk(root)
        return best
    }

    /// Walk `view`'s subtree (ignoring `isUserInteractionEnabled`, which
    /// `hitTest` respects) and return the deepest, frontmost subview whose
    /// bounds contain `windowPoint`. Lets the inspector reach non-interactive
    /// leaves — labels, image views, decorative subviews — that hitTest skips.
    /// Excludes the inspector's own overlay so a hit on a container that also
    /// hosts the overlay (e.g. the top view controller's view) can't re-enter it.
    private func deepestDescendant(of view: UIView, at windowPoint: CGPoint) -> UIView {
        var best = view
        func walk(_ v: UIView) {
            for sub in v.subviews {
                guard !sub.isHidden, sub.alpha > 0.01, !isInspectorOwnView(sub) else { continue }
                let local = sub.convert(windowPoint, from: nil)
                if sub.bounds.contains(local) {
                    best = sub
                    walk(sub)
                }
            }
        }
        walk(view)
        return best
    }

    private func viewDepth(_ view: UIView) -> Int {
        var d = 0
        var v: UIView? = view.superview
        while v != nil { d += 1; v = v?.superview }
        return d
    }
}

// MARK: - UIKit Representable

struct ViewInspectorTouchLayer: UIViewRepresentable {
    let onInspect: (InspectedView) -> Void
    let onCursorMoved: (CGPoint) -> Void

    func makeUIView(context: Context) -> ViewInspectorController {
        let v = ViewInspectorController(frame: UIScreen.main.bounds)
        v.onInspect = onInspect
        v.onCursorMoved = onCursorMoved
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return v
    }

    func updateUIView(_ uiView: ViewInspectorController, context: Context) {
        uiView.onInspect = onInspect
        uiView.onCursorMoved = onCursorMoved
    }
}

// MARK: - Crosshair Reticle

struct CrosshairReticle: View {
    let position: CGPoint
    let size: CGFloat = 28

    var body: some View {
        ZStack {
            // Circle
            Circle()
                .stroke(Color.pink, lineWidth: 2)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)

            // Horizontal line
            Rectangle()
                .fill(Color.pink.opacity(0.75))
                .frame(width: size + 8, height: 2)

            // Vertical line
            Rectangle()
                .fill(Color.pink.opacity(0.75))
                .frame(width: 2, height: size + 8)

            // Center dot
            Circle()
                .fill(.white)
                .frame(width: 3, height: 3)
        }
        .position(position)
        .allowsHitTesting(false)
    }
}

// MARK: - Properties Tab

@available(iOS 16.0, *)
struct InspectorPropertiesTab: View {
    let info: InspectedView

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            section("Identity") {
                if let aid = info.accessibilityId, !aid.isEmpty {
                    // Orange pill badge — prominent, like web ElementDebuggerOverlay data-ui
                    Button {
                        UIPasteboard.general.string = aid
                    } label: {
                        Text(aid)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.7))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.orange, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 2)
                }
                copyableRow("Class", info.className, valueColor: .green)
                if let label = info.accessibilityLabel, !label.isEmpty {
                    row("a11y Label", label)
                }
                if info.tag != 0 {
                    row("Tag", "\(info.tag)")
                }
            }

            section("Find in source") {
                if let p = info.propertyRef {
                    copyableRow("Property", p, valueColor: .orange)
                }
                if let c = info.container {
                    copyableRow("Container", c, valueColor: .mint)
                }
                if let vc = info.owningViewController {
                    copyableRow("Controller", vc, valueColor: .cyan)
                }
                if let t = info.text {
                    copyableRow("Text", "\"\(t)\"", valueColor: .yellow)
                }
                if let img = info.imageName {
                    copyableRow("Image", img, valueColor: .yellow)
                }
                ForEach(info.controlActions, id: \.self) { action in
                    copyableRow("Action", action, valueColor: .orange)
                }
                if let rid = info.restorationIdentifier {
                    copyableRow("Restoration", rid)
                }
                Button {
                    UIPasteboard.general.string = info.sourceReference()
                } label: {
                    Text("⧉ Copy reference")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.pink.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
            }

            section("Geometry") {
                row("Frame", String(format: "%.0f, %.0f  %.0f x %.0f",
                    info.frame.origin.x, info.frame.origin.y,
                    info.frame.width, info.frame.height))
                row("Window", String(format: "%.0f, %.0f  %.0f x %.0f",
                    info.frameInWindow.origin.x, info.frameInWindow.origin.y,
                    info.frameInWindow.width, info.frameInWindow.height))
            }

            section("Appearance") {
                row("Alpha", String(format: "%.2f", info.alpha))
                row("Hidden", info.isHidden ? "YES" : "NO")
                row("Clips", info.clipsToBounds ? "YES" : "NO")
                if let bg = info.backgroundColor {
                    HStack(spacing: 8) {
                        Text("Background")
                            .foregroundStyle(.gray)
                            .frame(width: 90, alignment: .leading)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(bg))
                            .frame(width: 16, height: 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(.white.opacity(0.3), lineWidth: 0.5)
                            )
                        Text(bg.hexString)
                            .foregroundStyle(.white)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }

            section("Layer") {
                row("Corner R", String(format: "%.1f", info.layer.cornerRadius))
                if info.layer.borderWidth > 0 {
                    row("Border", String(format: "%.1f", info.layer.borderWidth))
                }
                if info.layer.shadowOpacity > 0 {
                    row("Shadow R", String(format: "%.1f", info.layer.shadowRadius))
                    row("Shadow α", String(format: "%.2f", info.layer.shadowOpacity))
                }
            }

            section("Hierarchy") {
                row("Children", "\(info.childCount)")
                row("Depth", "\(info.depth)")
            }

            // Diagnostic: show ancestor chain with identifiers
            section("Ancestors") {
                let ancestors = Self.ancestorChain(info.view, maxDepth: 12)
                ForEach(Array(ancestors.enumerated()), id: \.offset) { idx, entry in
                    HStack(spacing: 4) {
                        Text("↑\(idx)")
                            .foregroundStyle(.gray)
                            .frame(width: 24, alignment: .trailing)
                        Text(entry.className)
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                        if let aid = entry.identifier {
                            Text("[\(aid)]")
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
    }

    private struct AncestorEntry {
        let className: String
        let identifier: String?
    }

    private static func ancestorChain(_ view: UIView, maxDepth: Int) -> [AncestorEntry] {
        var result: [AncestorEntry] = []
        let registry = UIKitIdentifierRegistry.shared
        var current: UIView? = view.superview
        while let v = current, result.count < maxDepth {
            let name = String(describing: type(of: v))
            let regId = registry.identifier(for: v)
            let aid = v.accessibilityIdentifier
            let displayId = regId ?? ((aid != nil && !aid!.isEmpty) ? aid : nil)
            result.append(AncestorEntry(className: name, identifier: displayId))
            current = v.superview
        }
        return result
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.pink)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
        .padding(.bottom, 4)
    }

    private func row(_ key: String, _ value: String, valueColor: Color = .white) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .foregroundStyle(.gray)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .foregroundStyle(valueColor)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func copyableRow(_ key: String, _ value: String, valueColor: Color = .white) -> some View {
        Button {
            UIPasteboard.general.string = value
        } label: {
            HStack(spacing: 8) {
                Text(key)
                    .foregroundStyle(.gray)
                    .frame(width: 90, alignment: .leading)
                Text(value)
                    .foregroundStyle(valueColor)
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tree Tab

@available(iOS 16.0, *)
struct InspectorTreeTab: View {
    let selectedView: UIView
    let onSelect: (UIView) -> Void

    var body: some View {
        // Build tree from the window root so we always show the full hierarchy.
        // Auto-expand the path to the selected view.
        let root = windowRoot(for: selectedView)
        let ancestorSet = ancestors(of: selectedView)
        let tree = ViewTreeNode.build(from: root, maxDepth: 10)
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                TreeNodeRow(node: tree, selectedView: selectedView, expandedAncestors: ancestorSet, onSelect: onSelect)
            }
        }
    }

    private func windowRoot(for view: UIView) -> UIView {
        var v = view
        while let parent = v.superview { v = parent }
        return v
    }

    private func ancestors(of view: UIView) -> Set<ObjectIdentifier> {
        var set = Set<ObjectIdentifier>()
        var v: UIView? = view
        while let current = v {
            set.insert(ObjectIdentifier(current))
            v = current.superview
        }
        return set
    }
}

@available(iOS 16.0, *)
struct TreeNodeRow: View {
    let node: ViewTreeNode
    let selectedView: UIView
    let expandedAncestors: Set<ObjectIdentifier>
    let onSelect: (UIView) -> Void
    @State private var isExpanded: Bool

    init(node: ViewTreeNode, selectedView: UIView, expandedAncestors: Set<ObjectIdentifier>, onSelect: @escaping (UIView) -> Void) {
        self.node = node
        self.selectedView = selectedView
        self.expandedAncestors = expandedAncestors
        self.onSelect = onSelect
        // Auto-expand if this node is an ancestor of the selected view
        _isExpanded = State(initialValue: expandedAncestors.contains(ObjectIdentifier(node.view)))
    }

    private var isSelected: Bool {
        node.view === selectedView
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if !node.children.isEmpty {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.pink)
                        .frame(width: 14)
                        .onTapGesture { isExpanded.toggle() }
                } else {
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.gray.opacity(0.3))
                        .frame(width: 14)
                }

                Text(node.label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? .pink : .cyan)
                    .fontWeight(isSelected ? .bold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture { onSelect(node.view) }
            }
            .padding(.leading, CGFloat(node.depth) * 10)
            .frame(minHeight: 28)
            .padding(.vertical, 2)
            .background(isSelected ? Color.pink.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            if isExpanded {
                ForEach(node.children) { child in
                    TreeNodeRow(node: child, selectedView: selectedView, expandedAncestors: expandedAncestors, onSelect: onSelect)
                }
            }
        }
    }
}

// MARK: - Draggable HUD Container (UIKit)

/// Wraps any SwiftUI content in a UIKit container with a UIPanGestureRecognizer.
/// The pan directly applies `transform` on the hosted content view for 60fps 1:1
/// tracking, completely bypassing SwiftUI's state/render pipeline during the drag.
/// On gesture end, persists the final position to UserDefaults.
///
/// The container VC uses a PassthroughRootView as its root. This view overrides
/// `hitTest` so that touches landing outside the actual HUD content fall through
/// to sibling views below in the ZStack (i.e. the ViewInspectorTouchLayer).
private struct DraggableHUDWrapper<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let posXKey: String
    let posYKey: String
    let store: UserDefaults

    func makeUIViewController(context: Context) -> DraggableHUDContainerVC<Content> {
        DraggableHUDContainerVC(
            content: content,
            posXKey: posXKey,
            posYKey: posYKey,
            store: store
        )
    }

    func updateUIViewController(_ vc: DraggableHUDContainerVC<Content>, context: Context) {
        vc.updateContent(content)
    }
}

/// Pan gesture that requires a minimum translation before activating,
/// so taps pass through to underlying SwiftUI buttons.
private class ThresholdPanGesture: UIPanGestureRecognizer {
    private let threshold: CGFloat = 8
    private var initialPoint: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        initialPoint = touches.first?.location(in: view) ?? .zero
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard state == .possible, let touch = touches.first else { return }
        let loc = touch.location(in: view)
        let dx = abs(loc.x - initialPoint.x)
        let dy = abs(loc.y - initialPoint.y)
        if dx + dy < threshold {
            // Not enough movement — don't transition to .began yet
            // (UIPanGestureRecognizer handles this internally, but we
            // need to explicitly fail if the touch ends before threshold)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible {
            // Never reached threshold — fail so the tap can fire
            state = .failed
        }
        super.touchesEnded(touches, with: event)
    }
}

/// A UIView that only claims touches landing within `contentView`'s bounds.
/// Touches outside pass through (hitTest returns nil), allowing views below
/// in the SwiftUI ZStack to receive them.
private class PassthroughRootView: UIView {
    weak var contentView: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let cv = contentView, !cv.isHidden, cv.alpha > 0.01 else { return nil }
        let cvPoint = cv.convert(point, from: self)
        guard cv.bounds.contains(cvPoint) else { return nil }
        return cv.hitTest(cvPoint, with: event)
    }
}

/// Container VC with a passthrough root view. Embeds a UIHostingController as
/// a child VC, sized to its intrinsic content, with a pan gesture for dragging.
class DraggableHUDContainerVC<Content: View>: UIViewController {
    private let posXKey: String
    private let posYKey: String
    private let store: UserDefaults
    private var hostingController: UIHostingController<Content>!
    private var dragStartTransform: CGAffineTransform = .identity

    init(content: Content, posXKey: String, posYKey: String, store: UserDefaults) {
        self.posXKey = posXKey
        self.posYKey = posYKey
        self.store = store
        super.init(nibName: nil, bundle: nil)
        self.hostingController = UIHostingController(rootView: content)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        self.view = PassthroughRootView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = false

        // Add hosting controller as proper child VC
        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        hostingController.view.clipsToBounds = false
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        // Size hosting view to its SwiftUI content
        if #available(iOS 16.0, *) {
            hostingController.sizingOptions = .intrinsicContentSize
        }
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
        ])

        // Pan gesture on the content-sized hosting view
        let pan = ThresholdPanGesture(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        hostingController.view.addGestureRecognizer(pan)

        // Apply saved position, clamped to visible bounds so a HUD dragged
        // off-screen in a previous session can't strand itself.
        let savedX = store.double(forKey: posXKey)
        let savedY = store.double(forKey: posYKey)
        let screen = UIScreen.main.bounds
        // Keep at least 80pt of the HUD visible from each edge.
        let minX = -(screen.width - 80)
        let maxX = screen.width - 80
        let minY: CGFloat = 0
        let maxY = screen.height - 80
        let x = min(max(savedX, minX), maxX)
        let y = min(max(savedY, minY), maxY)
        hostingController.view.transform = CGAffineTransform(translationX: x, y: y)
        if x != savedX { store.set(x, forKey: posXKey) }
        if y != savedY { store.set(y, forKey: posYKey) }

        // Tell passthrough root which subview to allow hits on
        (view as? PassthroughRootView)?.contentView = hostingController.view
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let hv = hostingController.view!
        switch gesture.state {
        case .began:
            dragStartTransform = hv.transform
        case .changed:
            let t = gesture.translation(in: view)
            hv.transform = CGAffineTransform(
                translationX: dragStartTransform.tx + t.x,
                y: dragStartTransform.ty + t.y
            )
        case .ended, .cancelled:
            let t = gesture.translation(in: view)
            let finalX = dragStartTransform.tx + t.x
            let finalY = dragStartTransform.ty + t.y
            hv.transform = CGAffineTransform(translationX: finalX, y: finalY)
            store.set(finalX, forKey: posXKey)
            store.set(finalY, forKey: posYKey)
        default:
            break
        }
    }

    func updateContent(_ content: Content) {
        hostingController.rootView = content
    }
}

// MARK: - HUD Panel

@available(iOS 16.0, *)
struct InspectorHUD: View {
    let inspected: InspectedView?
    let history: [UIView]
    @Binding var folded: Bool
    let onUp: () -> Void
    let onBack: () -> Void
    let onExit: () -> Void
    let onSelectView: (UIView) -> Void

    @State private var tab: InspectorTab = .properties
    @State private var size: CGSize = CGSize(
        width: min(360, UIScreen.main.bounds.width - 16),
        height: UIScreen.main.bounds.height * 0.3
    )

    enum InspectorTab: String, CaseIterable {
        case properties = "Properties"
        case tree = "Tree"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            if !folded {
                // Tab bar
                tabBar

                // Body
                ScrollView {
                    bodyContent
                        .padding(10)
                }
                .frame(maxHeight: size.height - 70)
            }
        }
        .frame(width: size.width)
        .background(.black.opacity(0.88))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .fixedSize()
    }

    private var header: some View {
        HStack(spacing: 6) {
            // Title — tap to fold
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { folded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(folded ? "▸" : "▾")
                    Text("View Inspector")
                        .fontWeight(.bold)
                    if folded, let info = inspected {
                        let summary = {
                            if let aid = info.accessibilityId, !aid.isEmpty {
                                return aid
                            }
                            if let t = info.text, !t.isEmpty {
                                return "\(info.className) \u{201C}\(t)\u{201D}"
                            }
                            return info.className
                        }()
                        let hasA11yId = info.accessibilityId != nil && !(info.accessibilityId?.isEmpty ?? true)
                        Text("— \(summary)")
                            .fontWeight(.regular)
                            .foregroundStyle(hasA11yId ? Color.orange : .white)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pink.opacity(0.8))
            }
            .buttonStyle(.plain)

            Spacer()

            hudButton("← Back", disabled: history.isEmpty, action: onBack)
                .uiKitIdentifier("InspectorHUD.backButton")
            hudButton("↑ Up", disabled: inspected?.view.superview == nil, action: onUp)
                .uiKitIdentifier("InspectorHUD.upButton")
            hudButton("Exit", tone: .red, action: onExit)
                .uiKitIdentifier("InspectorHUD.exitButton")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.pink.opacity(0.2))
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    Text(t.rawValue)
                        .font(.system(size: 11, weight: tab == t ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(tab == t ? Color.pink.opacity(0.8) : .gray)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            if tab == t {
                                Rectangle()
                                    .fill(Color.pink)
                                    .frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .background(.white.opacity(0.04))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let info = inspected {
            switch tab {
            case .properties:
                InspectorPropertiesTab(info: info)
            case .tree:
                InspectorTreeTab(selectedView: info.view, onSelect: onSelectView)
            }
        } else {
            Text("Drag your finger to inspect views")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.gray)
                .italic()
        }
    }

    private func hudButton(_ label: String, disabled: Bool = false, tone: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(disabled ? .gray.opacity(0.4) : tone)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    tone == .red
                        ? Color.red.opacity(0.25)
                        : Color.white.opacity(0.12)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            tone == .red
                                ? Color.red.opacity(0.4)
                                : Color.white.opacity(0.2),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Main Overlay View

@available(iOS 16.0, *)
public struct ViewInspectorOverlay: View {
    @Binding var isActive: Bool
    @State private var inspected: InspectedView?
    @State private var cursorPosition: CGPoint = CGPoint(
        x: UIScreen.main.bounds.width / 2,
        y: UIScreen.main.bounds.height / 2
    )
    @State private var history: [UIView] = []
    @State private var currentView: UIView?
    /// When folded, the HUD header stays visible but touch capture and
    /// crosshair are removed so normal app interaction resumes.
    @AppStorage("viewInspector.folded") private var folded = false

    public init(isActive: Binding<Bool>) {
        self._isActive = isActive
    }

    public var body: some View {
        if isActive {
            ZStack {
                // Touch capture layer — only when unfolded
                if !folded {
                    ViewInspectorTouchLayer(
                        onInspect: { info in
                            if info.view !== currentView {
                                if let old = currentView {
                                    history.append(old)
                                    if history.count > 50 { history.removeFirst() }
                                }
                                currentView = info.view
                            }
                            inspected = info
                        },
                        onCursorMoved: { pos in
                            cursorPosition = pos
                        }
                    )
                    .ignoresSafeArea()

                    // Crosshair — only when unfolded
                    CrosshairReticle(position: cursorPosition)
                        .ignoresSafeArea()
                }

                // HUD — always visible, wrapped in UIKit container for smooth dragging
                DraggableHUDWrapper(
                    content: InspectorHUD(
                        inspected: inspected,
                        history: history,
                        folded: $folded,
                        onUp: navigateUp,
                        onBack: navigateBack,
                        onExit: { isActive = false },
                        onSelectView: selectView
                    ),
                    posXKey: "viewInspector.posX",
                    posYKey: "viewInspector.posY",
                    store: .standard
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
            }
            .transition(.opacity)
        }
    }

    private func navigateUp() {
        guard let current = currentView, let parent = current.superview else { return }
        selectView(parent)
    }

    private func navigateBack() {
        guard let prev = history.popLast() else { return }
        currentView = prev
        inspected = InspectedView.inspect(prev)
    }

    private func selectView(_ view: UIView) {
        if let old = currentView {
            history.append(old)
            if history.count > 50 { history.removeFirst() }
        }
        currentView = view
        inspected = InspectedView.inspect(view)
    }
}

// MARK: - UIColor hex helper

extension UIColor {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        if a < 1 {
            return String(format: "#%02X%02X%02X (%.0f%%)", Int(r * 255), Int(g * 255), Int(b * 255), a * 100)
        }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

#else
// macOS no-op — uiKitIdentifier is used in Shared/ code but the UIKit-based
// implementation only compiles on iOS. On macOS we just pass through.
import SwiftUI

public extension View {
    func uiKitIdentifier(_ identifier: String) -> some View {
        self.accessibilityIdentifier(identifier)
    }
}
#endif
