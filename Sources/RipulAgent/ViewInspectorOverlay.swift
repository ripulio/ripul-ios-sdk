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
    let enclosingControl: String?      // nearest UIControl up the tree + its id ("UIButton [addShift.save]")
                                       // — a tap lands on a button's gradient/image subview, not the button
    let hitLeafClass: String?          // the actual view under the finger when it differs from the
                                       // inspected element (i.e. selection was promoted to a control)

    struct LayerInfo {
        let cornerRadius: CGFloat
        let borderWidth: CGFloat
        let borderColor: UIColor?
        let shadowRadius: CGFloat
        let shadowOpacity: Float
    }

    static func inspect(_ view: UIView, depth: Int = 0, resolvedIdentifier: String? = nil, hitLeaf: UIView? = nil) -> InspectedView {
        let className = String(describing: type(of: view))
        let frameInWindow = view.convert(view.bounds, to: nil)
        // The leaf's OWN identifier first (a UIKit accessibilityIdentifier set in code), then the
        // SwiftUI spatial-registry match. Previously only the latter was used, so UIKit identifiers
        // never surfaced.
        let resolvedId = nonEmpty(view.accessibilityIdentifier) ?? resolvedIdentifier
        let vcChain = viewControllerChain(of: view)
        return InspectedView(
            view: view,
            className: className,
            accessibilityId: resolvedId,
            accessibilityLabel: view.accessibilityLabel ?? nearestControlLabel(of: view),
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
            propertyRef: propertyReference(of: view),
            enclosingControl: nearestControl(of: view, excluding: className),
            hitLeafClass: hitLeaf.map { String(describing: type(of: $0)) }
        )
    }

    /// The nearest `UIControl` at or above `view` (its own class if `view` is one), with its
    /// accessibilityIdentifier — so a tap on a button's internal gradient/image subview still
    /// reports the button (e.g. "UIButton [addShift.save]"). nil when nothing above is a control,
    /// or when the control IS `view` itself (already the class shown).
    static func nearestControl(of view: UIView, excluding ownClassName: String) -> String? {
        var v: UIView? = view
        while let cur = v {
            if let control = cur as? UIControl {
                let cls = String(describing: type(of: control))
                if cur === view && cls == ownClassName { return nil }   // the leaf already IS the control
                if let id = nonEmpty(control.accessibilityIdentifier) { return "\(cls) [\(id)]" }
                return cls
            }
            v = cur.superview
        }
        return nil
    }

    /// The accessibilityLabel of the nearest enclosing control — so a tapped subview inherits the
    /// button's VoiceOver label as a hint.
    static func nearestControlLabel(of view: UIView) -> String? {
        var v: UIView? = view.superview
        while let cur = v {
            if cur is UIControl, let label = nonEmpty(cur.accessibilityLabel) { return label }
            v = cur.superview
        }
        return nil
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

    /// Live-set the text of a text-bearing view — backs the inspector's inline edit
    /// so a trial copy change is visible in-context before it's handed off.
    static func applyText(_ s: String, to v: UIView) {
        if let l = v as? UILabel { l.text = s }
        else if let f = v as? UITextField { f.text = s }
        else if let t = v as? UITextView { t.text = s }
        else if let b = v as? UIButton { b.setTitle(s, for: .normal) }
    }

    // MARK: Live property editing (backs the Edit tab)

    /// The view's foreground/text colour, where it has one.
    static func currentTextColor(_ v: UIView) -> UIColor? {
        if let l = v as? UILabel { return l.textColor }
        if let f = v as? UITextField { return f.textColor }
        if let t = v as? UITextView { return t.textColor }
        if let b = v as? UIButton { return b.titleColor(for: .normal) }
        return nil
    }
    static func applyTextColor(_ c: UIColor, to v: UIView) {
        if let l = v as? UILabel { l.textColor = c }
        else if let f = v as? UITextField { f.textColor = c }
        else if let t = v as? UITextView { t.textColor = c }
        else if let b = v as? UIButton { b.setTitleColor(c, for: .normal) }
    }

    /// The view's font, where it has one.
    static func currentFont(_ v: UIView) -> UIFont? {
        if let l = v as? UILabel { return l.font }
        if let f = v as? UITextField { return f.font }
        if let t = v as? UITextView { return t.font }
        if let b = v as? UIButton { return b.titleLabel?.font }
        return nil
    }
    static func applyFontSize(_ size: CGFloat, to v: UIView) {
        if let l = v as? UILabel { l.font = l.font.withSize(size) }
        else if let f = v as? UITextField { f.font = (f.font ?? .systemFont(ofSize: size)).withSize(size) }
        else if let t = v as? UITextView { t.font = (t.font ?? .systemFont(ofSize: size)).withSize(size) }
        else if let b = v as? UIButton { b.titleLabel?.font = (b.titleLabel?.font ?? .systemFont(ofSize: size)).withSize(size) }
    }

    static func applyCornerRadius(_ r: CGFloat, to v: UIView) {
        v.layer.cornerRadius = r
        if r > 0 { v.clipsToBounds = true }
    }

    /// A comparable string for a colour (hex), used for change detection + from/to.
    static func hex(_ c: UIColor?) -> String { c?.hexString ?? "—" }

    /// A compact, greppable one-paste reference for finding this element in source.
    func sourceReference() -> String {
        // Headline carries the identity inline so a control reads "class: UIButton [addSick.save]"
        // at a glance, not a bare class with the id buried further down.
        let idBadge = (accessibilityId?.isEmpty == false) ? " [\(accessibilityId!)]" : ""
        var lines = ["class: \(className)\(idBadge)"]
        if let leaf = hitLeafClass { lines.append("tapped: \(leaf)") }   // actual view under the finger
        if let p = propertyRef { lines.append("property: \(p)") }
        if let c = container { lines.append("container: \(c)") }
        if let vc = owningViewController { lines.append("controller: \(vc)") }
        if let ctrl = enclosingControl { lines.append("control: \(ctrl)") }
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
        let leaf = deepestDescendant(of: hitView, at: windowPoint)

        // Promote a decorative leaf to its enclosing control: a tap on a button's gradient image or
        // its title label should inspect the BUTTON (headline "UIButton [addSick.save]"), not the
        // internal UIImageView/UIButtonLabel. Standalone labels — not inside a control — stay
        // themselves. `hitLeaf` records what was actually under the finger.
        let target = controlToInspect(for: leaf)
        let hitLeaf = (target !== leaf) ? leaf : nil

        // Spatial lookup: find the tightest .uiKitIdentifier() match at this point
        let match = UIKitIdentifierRegistry.shared.bestMatch(at: windowPoint)

        // Highlight the registry match's frame if available, otherwise the inspected element
        let highlightView = match?.view ?? target
        let frameInWindow = highlightView.convert(highlightView.bounds, to: nil)
        let frameInSelf = convert(frameInWindow, from: nil)
        highlightLayer.path = UIBezierPath(roundedRect: frameInSelf, cornerRadius: highlightView.layer.cornerRadius).cgPath

        // Inspect — pass the resolved identifier from spatial lookup
        let info = InspectedView.inspect(target, depth: viewDepth(target), resolvedIdentifier: match?.identifier, hitLeaf: hitLeaf)
        onInspect?(info)
    }

    /// The element to inspect for a tapped `leaf`: the nearest enclosing `UIControl` (so a tap on a
    /// button's gradient/title subview reports the button), else the leaf itself when it isn't inside
    /// a control. Already-a-control leaves are returned unchanged.
    private func controlToInspect(for leaf: UIView) -> UIView {
        if leaf is UIControl { return leaf }
        var v = leaf.superview
        while let cur = v {
            if isInspectorOwnView(cur) { break }
            if cur is UIControl { return cur }
            v = cur.superview
        }
        return leaf
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

// MARK: - Design-token section

/// The Design-token block at the top of the Edit tab: the tokens the host reports as styling the
/// tapped view, each remappable in place. Empty (renders nothing) when no provider is registered or
/// the view carries no token metadata — so it's invisible in hosts that don't opt in.
@available(iOS 16.0, *)
struct InspectorTokenSection: View {
    let view: UIView
    /// Bumped after a remap to force `body` to recompute the bindings against the new theme.
    @State private var refresh = 0

    var body: some View {
        // Compute the bindings EAGERLY in body — never via @State + .onAppear. A `Group` whose
        // content is initially empty has no child for `.onAppear` to attach to, so the previous
        // version's reload never fired and the section stayed permanently blank. Reading `refresh`
        // here ties a remap's state bump to a recompute.
        _ = refresh
        let provider = RipulTokenInspector.provider
        let bindings = provider?.tokenBindings(for: view) ?? []

        return VStack(alignment: .leading, spacing: 6) {
            Text("Design token")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.pink).textCase(.uppercase).tracking(0.5)

            if !bindings.isEmpty {
                ForEach(bindings) { binding in row(binding) }
            } else {
                // Always render the header so the section can never be silently invisible again.
                // This line tells us WHY it's empty: no host provider vs. provider found no token.
                Text(provider == nil ? "no token provider registered"
                                     : "no token reported for this view")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.pink.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ binding: RipulTokenBinding) -> some View {
        HStack(spacing: 8) {
            swatch(binding.swatchHex)
            VStack(alignment: .leading, spacing: 1) {
                Text(binding.tokenName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(binding.property + (binding.resolvesTo.map { " → \($0)" } ?? ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.gray)
            }
            Spacer(minLength: 6)
            Menu {
                ForEach(binding.options) { option in
                    // Label icon → the menu item's image. A colour swatch so you can see what each
                    // option maps to. .alwaysOriginal (in swatchImage) keeps the true colour rather
                    // than letting the menu tint it.
                    Button { remap(binding, option) } label: {
                        Label { Text(option.label) } icon: { Image(uiImage: Self.swatchImage(option.swatchHex)) }
                    }
                }
            } label: {
                Text("remap")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.pink.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(ripulHex: hex) ?? .clear)
            .frame(width: 18, height: 18)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
    }

    /// A small solid-colour swatch image for a menu item. `.alwaysOriginal` so UIMenu shows the real
    /// colour instead of tinting it.
    private static func swatchImage(_ hex: String) -> UIImage {
        let color = UIColor(Color(ripulHex: hex) ?? .clear)
        let size = CGSize(width: 16, height: 16)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    private func remap(_ binding: RipulTokenBinding, _ option: RipulTokenOption) {
        RipulTokenInspector.provider?.remap(binding, to: option)
        // A remap changes the mapping, which can move OTHER bindings that share the token — bump
        // refresh so body recomputes the whole set against the new theme.
        refresh += 1
    }
}

// MARK: - Properties Tab

/// Dedicated element editor (the "Edit" tab): trial changes to the inspected
/// view's properties live — text plus common visual props — then hand the whole
/// change set to Ripul via the adaptive "Discuss in <chat>" button. Keyed by the
/// selected view's identity (via `.id`) so its state resets per selection.
@available(iOS 16.0, *)
struct InspectorEditTab: View {
    let info: InspectedView

    // Editable state, seeded from the live view.
    @State private var text: String
    @State private var bg: Color
    @State private var tint: Color
    @State private var textColor: Color
    @State private var alpha: Double
    @State private var corner: Double
    @State private var fontSize: Double
    @State private var isHidden: Bool
    @State private var sent = false
    @State private var targetTick = 0

    // Originals (for change detection + reset), captured once.
    private let hasText: Bool, hasTextColor: Bool, hasFont: Bool
    private let origText: String
    private let origBg: Color, origTint: Color, origTextColor: Color
    private let origAlpha: Double, origCorner: Double, origFontSize: Double
    private let origHidden: Bool

    init(info: InspectedView) {
        self.info = info
        let v = info.view
        let tc = InspectedView.currentTextColor(v)
        let font = InspectedView.currentFont(v)
        hasText = info.text != nil
        hasTextColor = tc != nil
        hasFont = font != nil
        origText = info.text ?? ""
        origBg = Color(uiColor: v.backgroundColor ?? .clear)
        origTint = Color(uiColor: v.tintColor ?? .clear)
        origTextColor = Color(uiColor: tc ?? .clear)
        origAlpha = Double(v.alpha)
        origCorner = Double(v.layer.cornerRadius)
        origFontSize = Double(font?.pointSize ?? 14)
        origHidden = v.isHidden
        _text = State(initialValue: info.text ?? "")
        _bg = State(initialValue: Color(uiColor: v.backgroundColor ?? .clear))
        _tint = State(initialValue: Color(uiColor: v.tintColor ?? .clear))
        _textColor = State(initialValue: Color(uiColor: tc ?? .clear))
        _alpha = State(initialValue: Double(v.alpha))
        _corner = State(initialValue: Double(v.layer.cornerRadius))
        _fontSize = State(initialValue: Double(font?.pointSize ?? 14))
        _isHidden = State(initialValue: v.isHidden)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Design tokens styling this element, when the host registered a token provider. Sits
            // above the raw property editors — it's the "what do I change to retheme this" answer.
            InspectorTokenSection(view: info.view)

            if hasText {
                labeled("Text") {
                    TextField("text", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .onChange(of: text) { v in InspectedView.applyText(v, to: info.view); sent = false }
                }
            }

            colorRow("Background", $bg) { info.view.backgroundColor = UIColor($0) }
            if hasTextColor {
                colorRow("Text colour", $textColor) { InspectedView.applyTextColor(UIColor($0), to: info.view) }
            }
            colorRow("Tint", $tint) { info.view.tintColor = UIColor($0) }

            sliderRow("Alpha", $alpha, 0...1, "%.2f") { info.view.alpha = CGFloat($0) }
            sliderRow("Corner", $corner, 0...40, "%.0f") { InspectedView.applyCornerRadius(CGFloat($0), to: info.view) }
            if hasFont {
                sliderRow("Font size", $fontSize, 8...40, "%.0f") { InspectedView.applyFontSize(CGFloat($0), to: info.view) }
            }

            Toggle(isOn: $isHidden) {
                Text("Hidden").font(.system(size: 11, design: .monospaced)).foregroundStyle(.gray)
            }
            .tint(.pink)
            .onChange(of: isHidden) { info.view.isHidden = $0; sent = false }

            HStack(spacing: 10) {
                // No target → "Discuss in Ripul" opens the chooser; set → sends the edits.
                Button { primaryAction() } label: {
                    Label(primaryTitle, systemImage: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.pink.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                if RipulEditHandoff.targetSessionId != nil {
                    Button("clear") { RipulEditHandoff.clearSession() }
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.gray).buttonStyle(.plain)
                }
                Button("reset") { resetAll() }
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.gray).buttonStyle(.plain)
                Spacer()
            }
            .id(targetTick)
        }
        .onReceive(NotificationCenter.default.publisher(for: RipulEditHandoff.targetChangedNotification)) { _ in
            targetTick &+= 1
        }
    }

    // MARK: rows

    @ViewBuilder private func labeled(_ title: String, @ViewBuilder _ control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.pink).textCase(.uppercase).tracking(0.5)
            control()
        }
    }

    private func colorRow(_ title: String, _ binding: Binding<Color>, apply: @escaping (Color) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, design: .monospaced)).foregroundStyle(.gray)
                .frame(width: 92, alignment: .leading)
            ColorPicker("", selection: binding, supportsOpacity: true).labelsHidden()
            Spacer()
        }
        .onChange(of: binding.wrappedValue) { v in apply(v); sent = false }
    }

    private func sliderRow(_ title: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String, apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, design: .monospaced)).foregroundStyle(.gray)
                .frame(width: 92, alignment: .leading)
            Slider(value: binding, in: range).tint(.pink)
            Text(String(format: fmt, binding.wrappedValue))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white).frame(width: 36, alignment: .trailing)
        }
        .onChange(of: binding.wrappedValue) { v in apply(v); sent = false }
    }

    // MARK: send

    private var primaryTitle: String {
        if sent { return "Sent ✓" }
        if let name = RipulEditHandoff.targetSessionTitle ?? RipulEditHandoff.targetSessionId {
            return "Discuss in \(name)"
        }
        return "Discuss in Ripul"
    }

    private func primaryAction() {
        if RipulEditHandoff.targetSessionId == nil { RipulEditHandoff.chooseSession() }
        else { send() }
    }

    private func currentEdits() -> [RipulEditIntent.Edit] {
        var e: [RipulEditIntent.Edit] = []
        func add(_ p: String, _ from: String, _ to: String) {
            if from != to { e.append(.init(property: p, from: from, to: to)) }
        }
        if hasText { add("text", origText, text) }
        add("backgroundColor", InspectedView.hex(UIColor(origBg)), InspectedView.hex(UIColor(bg)))
        add("tintColor", InspectedView.hex(UIColor(origTint)), InspectedView.hex(UIColor(tint)))
        if hasTextColor { add("textColor", InspectedView.hex(UIColor(origTextColor)), InspectedView.hex(UIColor(textColor))) }
        add("alpha", String(format: "%.2f", origAlpha), String(format: "%.2f", alpha))
        add("cornerRadius", String(format: "%.0f", origCorner), String(format: "%.0f", corner))
        if hasFont { add("fontSize", String(format: "%.0f", origFontSize), String(format: "%.0f", fontSize)) }
        add("hidden", "\(origHidden)", "\(isHidden)")
        return e
    }

    private func send() {
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String
        let edits = currentEdits()
        let intent = RipulEditIntent(
            target: .init(
                app: appName,
                controller: info.owningViewController,
                container: info.container,
                property: info.propertyRef,
                className: info.className,
                text: info.text,
                accessibilityId: info.accessibilityId,
                storyboard: nil,
                vcChain: info.viewControllerChain),
            edits: edits.isEmpty ? nil : edits,
            sessionId: RipulEditHandoff.targetSessionId,
            callback: RipulEditHandoff.callbackURLString)
        RipulEditHandoff.send(intent)
        withAnimation { sent = true }
    }

    private func resetAll() {
        text = origText; InspectedView.applyText(origText, to: info.view)
        bg = origBg; info.view.backgroundColor = UIColor(origBg)
        tint = origTint; info.view.tintColor = UIColor(origTint)
        if hasTextColor { textColor = origTextColor; InspectedView.applyTextColor(UIColor(origTextColor), to: info.view) }
        alpha = origAlpha; info.view.alpha = CGFloat(origAlpha)
        corner = origCorner; InspectedView.applyCornerRadius(CGFloat(origCorner), to: info.view)
        if hasFont { fontSize = origFontSize; InspectedView.applyFontSize(CGFloat(origFontSize), to: info.view) }
        isHidden = origHidden; info.view.isHidden = origHidden
        sent = false
    }
}

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
class DraggableHUDContainerVC<Content: View>: UIViewController, UIGestureRecognizerDelegate {
    private let posXKey: String
    private let posYKey: String
    private let store: UserDefaults
    private var hostingController: UIHostingController<Content>!
    private var dragStartTransform: CGAffineTransform = .identity
    private var hasRestoredPosition = false
    private var isDragging = false

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
        pan.delegate = self
        hostingController.view.addGestureRecognizer(pan)

        // Saved position is restored + clamped in viewDidLayoutSubviews, once
        // the view has a window and the HUD has an intrinsic size — that's the
        // first point at which safe-area insets are real. Clamping here (in
        // viewDidLoad) would run against zero insets and let the HUD strand
        // itself under the notch or home indicator.

        // Tell passthrough root which subview to allow hits on
        (view as? PassthroughRootView)?.contentView = hostingController.view
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Need a real HUD size before we can keep it fully inside the safe area.
        guard hostingController.view.bounds.width > 0 else { return }

        let proposed: CGPoint
        if !hasRestoredPosition {
            // Wait for a window so safe-area insets are real before first place.
            guard view.window != nil else { return }
            hasRestoredPosition = true
            proposed = CGPoint(x: store.double(forKey: posXKey),
                               y: store.double(forKey: posYKey))
        } else if !isDragging {
            // Rotation / content-size change (e.g. unfolding the HUD near an
            // edge): re-clamp so it can never be stranded inside a safe area.
            proposed = CGPoint(x: hostingController.view.transform.tx,
                               y: hostingController.view.transform.ty)
        } else {
            return
        }
        applyPosition(clampedTranslation(proposed))
    }

    /// Set the HUD's translation and persist it, skipping redundant writes.
    private func applyPosition(_ p: CGPoint) {
        hostingController.view.transform = CGAffineTransform(translationX: p.x, y: p.y)
        if store.double(forKey: posXKey) != p.x { store.set(p.x, forKey: posXKey) }
        if store.double(forKey: posYKey) != p.y { store.set(p.y, forKey: posYKey) }
    }

    /// Clamp a proposed top-left translation so the HUD stays fully within the
    /// safe area — never under the notch, status bar, home indicator, or a
    /// landscape sensor housing. The hosting view is pinned to the container's
    /// top-leading corner and the container fills the whole screen (the wrapper
    /// uses `.ignoresSafeArea()`), so a translation of (x, y) places the HUD's
    /// top-left at screen point (x, y). We read the window's safe-area insets
    /// because SwiftUI can zero out the child controller's own insets under
    /// `.ignoresSafeArea()`.
    private func clampedTranslation(_ proposed: CGPoint) -> CGPoint {
        let margin: CGFloat = 8
        let insets = view.window?.safeAreaInsets ?? view.safeAreaInsets
        let bounds = view.bounds.size
        let hud = hostingController.view.bounds.size

        let minX = insets.left + margin
        let minY = insets.top + margin
        // max(minX, …) guards the case where the HUD is wider/taller than the
        // safe region — keep the top-left anchored just inside it.
        let maxX = max(minX, bounds.width - insets.right - margin - hud.width)
        let maxY = max(minY, bounds.height - insets.bottom - margin - hud.height)

        return CGPoint(x: min(max(proposed.x, minX), maxX),
                       y: min(max(proposed.y, minY), maxY))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let hv = hostingController.view!
        switch gesture.state {
        case .began:
            isDragging = true
            dragStartTransform = hv.transform
        case .changed:
            // Clamp live so the HUD hard-stops at the safe-area edge and can't
            // be dragged under the notch / home indicator in the first place.
            let t = gesture.translation(in: view)
            let clamped = clampedTranslation(CGPoint(x: dragStartTransform.tx + t.x,
                                                     y: dragStartTransform.ty + t.y))
            hv.transform = CGAffineTransform(translationX: clamped.x, y: clamped.y)
        case .ended, .cancelled:
            let t = gesture.translation(in: view)
            let clamped = clampedTranslation(CGPoint(x: dragStartTransform.tx + t.x,
                                                     y: dragStartTransform.ty + t.y))
            hv.transform = CGAffineTransform(translationX: clamped.x, y: clamped.y)
            store.set(clamped.x, forKey: posXKey)
            store.set(clamped.y, forKey: posYKey)
            isDragging = false
        default:
            isDragging = false
        }
    }

    // Let the SwiftUI resize grip (bottom-right corner of the HUD) win over the
    // move pan: ignore touches that start in that corner so dragging it resizes
    // the panel instead of repositioning it.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let hv = hostingController.view!
        let p = touch.location(in: hv)
        let grip: CGFloat = 44
        let inResizeCorner = p.x > hv.bounds.width - grip && p.y > hv.bounds.height - grip
        return !inResizeCorner
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
    @State private var resizeBase: CGSize? = nil   // size captured when a resize drag starts

    enum InspectorTab: String, CaseIterable {
        case properties = "Properties"
        case edit = "Edit"
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
        // Bottom-right resize grip. The UIKit move-pan ignores this corner (see
        // DraggableHUDContainerVC.gestureRecognizer(_:shouldReceive:)) so dragging
        // it resizes the panel instead of repositioning it.
        .overlay(alignment: .bottomTrailing) {
            if !folded { resizeGrip }
        }
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .fixedSize()
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if resizeBase == nil { resizeBase = size }
                        let base = resizeBase ?? size
                        let screen = UIScreen.main.bounds
                        size.width = min(max(220, base.width + g.translation.width), screen.width - 12)
                        size.height = min(max(180, base.height + g.translation.height), screen.height - 40)
                    }
                    .onEnded { _ in resizeBase = nil }
            )
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
            case .edit:
                InspectorEditTab(info: info)
                    .id(ObjectIdentifier(info.view))   // reset editor state per selection
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

// MARK: - Edit hand-off (View Explorer → coding agent)

/// A structured "make this change" intent produced by the View Explorer and
/// carried to the Ripul app over a `ripul://edit?p=<base64url(JSON)>` deep link.
/// Lives in the SDK so the sender (any consuming app's explorer) and the receiver
/// (the Ripul app, which imports RipulAgent) share one definition — URL-only, no
/// app-group/shared-team coupling, so it works for any third-party consumer.
public struct RipulEditIntent: Codable {
    public struct Target: Codable {
        public var app: String?
        public var controller: String?
        public var container: String?
        public var property: String?
        public var className: String
        public var text: String?
        public var accessibilityId: String?
        public var storyboard: String?
        public var vcChain: [String]?
    }
    /// One property change. `property` is a stable key ("text", "backgroundColor",
    /// "textColor", "tintColor", "alpha", "cornerRadius", "fontSize", "hidden").
    public struct Edit: Codable {
        public var property: String
        public var from: String?
        public var to: String?
        public init(property: String, from: String?, to: String?) {
            self.property = property; self.from = from; self.to = to
        }
    }
    public var v: Int = 1
    public var target: Target
    public var edits: [Edit]?        // nil/empty = "discuss this element", no concrete change yet
    public var sessionId: String?    // target an existing Ripul chat; nil = Ripul decides/asks
    public var callback: String?     // consuming app's back-channel URL (e.g. "WAC://ripul-session")

    public init(v: Int = 1, target: Target, edits: [Edit]? = nil,
                sessionId: String? = nil, callback: String? = nil) {
        self.v = v; self.target = target; self.edits = edits
        self.sessionId = sessionId; self.callback = callback
    }

    /// A ready-to-run instruction for the coding CLI on the developer's machine.
    public func prompt() -> String {
        let loc: String = {
            if let p = target.property { return " (held by `\(p)`)" }
            if let c = target.container { return " inside `\(c)`" }
            if let vc = target.controller { return " in `\(vc)`" }
            return ""
        }()
        let appPart = target.app.map { " in the \($0) codebase" } ?? ""
        let element = "the \(target.className)\(loc)\(appPart)"
        if let edits, !edits.isEmpty {
            let lines = edits
                .map { "- \($0.property): \"\($0.from ?? "?")\" → \"\($0.to ?? "?")\"" }
                .joined(separator: "\n")
            return "Apply these changes to \(element) and update the source to match — text is "
                + "usually a storyboard/code literal; visual properties may be set in code or a "
                + "shared style, so locate them via the property/controller:\n\(lines)"
        }
        // No concrete change yet — anchor a discussion to this element; the
        // developer completes the request in the composer before sending.
        let current = target.text.map { " Its current text is \"\($0)\"." } ?? ""
        return "I'm looking at \(element).\(current) "
            + "Find it in source via the property/controller, then make this change: "
    }
}

public enum RipulEditHandoff {
    public static let scheme = "ripul"
    public static let host = "edit"
    public static let chooseHost = "choose"

    /// The consuming app sets this to its own callback URL (e.g.
    /// "WAC://ripul-session") so Ripul can report back which chat the user picked.
    /// nil → no chooser/callback flow (Ripul just starts a new chat).
    public static var callbackURLString: String?

    // Remembered target chat — SDK-owned, UserDefaults-backed. The explorer puts
    // `targetSessionId` on every intent; the host's callback handler calls
    // `rememberSession(...)` once the user picks a chat in Ripul. "Until cleared".
    private static let targetIdKey = "ripul.edit.targetSessionId"
    private static let targetTitleKey = "ripul.edit.targetSessionTitle"
    public static var targetSessionId: String? { UserDefaults.standard.string(forKey: targetIdKey) }
    public static var targetSessionTitle: String? { UserDefaults.standard.string(forKey: targetTitleKey) }
    /// Posted when the remembered target changes, so the explorer button can refresh
    /// (e.g. after the user picks a chat in Ripul and returns to the consuming app).
    public static let targetChangedNotification = Notification.Name("ripul.edit.targetSessionChanged")
    public static func rememberSession(id: String, title: String?) {
        UserDefaults.standard.set(id, forKey: targetIdKey)
        if let title { UserDefaults.standard.set(title, forKey: targetTitleKey) }
        else { UserDefaults.standard.removeObject(forKey: targetTitleKey) }
        NotificationCenter.default.post(name: targetChangedNotification, object: nil)
    }
    public static func clearSession() {
        UserDefaults.standard.removeObject(forKey: targetIdKey)
        UserDefaults.standard.removeObject(forKey: targetTitleKey)
        NotificationCenter.default.post(name: targetChangedNotification, object: nil)
    }

    /// Parse a callback URL (`<scheme>://…?id=…&title=…`) into (id, title).
    public static func sessionFromCallback(_ url: URL) -> (id: String, title: String?)? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty
        else { return nil }
        return (id, comps.queryItems?.first(where: { $0.name == "title" })?.value)
    }

    /// Ask Ripul to present its chat chooser; it calls back to `callbackURLString`
    /// with the chosen chat. No-op if the host hasn't set a callback URL.
    @MainActor
    public static func chooseSession() {
        guard let cb = callbackURLString,
              var comps = URLComponents(string: "\(scheme)://\(chooseHost)") else { return }
        comps.queryItems = [URLQueryItem(name: "cb", value: cb)]
        guard let url = comps.url else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Build the `ripul://edit?p=…` deep link (base64url-encoded JSON).
    public static func makeURL(_ intent: RipulEditIntent) -> URL? {
        guard let data = try? JSONEncoder().encode(intent) else { return nil }
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.queryItems = [URLQueryItem(name: "p", value: b64)]
        return comps.url
    }

    /// Decode an intent from an incoming `ripul://edit` URL (receiver side).
    public static func decode(from url: URL) -> RipulEditIntent? {
        guard url.scheme == scheme, url.host == host,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let p = comps.queryItems?.first(where: { $0.name == "p" })?.value else { return nil }
        var b64 = p.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(RipulEditIntent.self, from: data)
    }

    /// Open the Ripul app with the intent. Falls back to copying the URL to the
    /// pasteboard if the Ripul app isn't installed to handle the scheme.
    @MainActor
    public static func send(_ intent: RipulEditIntent, fallbackToPasteboard: Bool = true) {
        guard let url = makeURL(intent) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok && fallbackToPasteboard { UIPasteboard.general.string = url.absoluteString }
        }
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

extension Color {
    /// Parse a `#RRGGBB` / `RRGGBB` hex into a SwiftUI Color for token swatches. nil on malformed
    /// input (any trailing "(NN%)" alpha suffix from `hexString` is tolerated — only the 6 hex
    /// digits are read).
    init?(ripulHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        s = String(s.prefix(6))
        guard s.count == 6, let rgb = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((rgb & 0xFF0000) >> 16) / 255,
                  green: Double((rgb & 0x00FF00) >> 8) / 255,
                  blue: Double(rgb & 0x0000FF) / 255)
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
