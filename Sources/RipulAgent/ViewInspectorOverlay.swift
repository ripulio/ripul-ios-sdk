#if os(iOS)
import SwiftUI
import UIKit
import ObjectiveC

/// Tag stamped by `RipulViewExplorer` on its overlay host view so the inspector's
/// hit-walks can recognise and skip their own subtree (arbitrary, collision-unlikely).
let ripulViewExplorerOverlayTag = 0x5249_5055   // "RIPU"

/// Marketing version of the RipulAgent SDK, surfaced in the inspector's copy output as `sdk: …`
/// so we can always tell which build is actually running on the device. Bump on every release.
let ripulSDKVersion = "0.7.60"

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
        matches(at: windowPoint).first
    }

    /// All registered stamps containing `windowPoint`, front-to-back — the same ordering
    /// `bestMatch` resolves by (frontmost, then tightest). Surfacing the full list lets the
    /// inspector show nested stamps (a row AND its title/subtitle) from a single tap, so
    /// sub-element ids are discoverable even when the finger lands on the outer stamp.
    func matches(at windowPoint: CGPoint) -> [(identifier: String, view: UIView)] {
        struct Candidate {
            let view: UIView
            let identifier: String
            let area: CGFloat
            let zPath: [Int]   // root-to-leaf subview indices
        }

        var candidates: [Candidate] = []
        let enumerator = map.keyEnumerator()
        while let view = enumerator.nextObject() as? UIView {
            guard let window = view.window, !view.isHidden else { continue }
            // Never match the SDK's own chrome. The explorer stamps 19 of its
            // own views — the HUD, the fire pill — and the overlay window is
            // full-screen and aligned with the host's, so a point over any of
            // them matched an inspector stamp as though it were app content:
            // the reticule could select itself, name its own pill as the
            // element, and (since the tighter box wins) steal the outline from
            // whatever was actually under the cursor. Every geometric walk
            // guards this with `isInspectorOwnView`; the spatial registry never
            // did.
            guard window.accessibilityIdentifier != RipulInspection.excludedOverlayWindowIdentifier,
                  !(window is RipulChromeWindow) else { continue }
            guard !Self.isOccludedByAncestor(view) else { continue }
            let frame = view.convert(view.bounds, to: nil)
            guard frame.contains(windowPoint) else { continue }
            guard let id = map.object(forKey: view) as? String else { continue }
            let area = frame.width * frame.height
            let zPath = Self.zOrderPath(of: view)
            candidates.append(Candidate(view: view, identifier: id, area: area, zPath: zPath))
        }

        // Sort: higher z-order first, then smaller area first
        candidates.sort { a, b in
            let cmp = Self.compareZPaths(a.zPath, b.zPath)
            if cmp != 0 { return cmp > 0 }  // higher z-order wins
            return a.area < b.area           // smaller area wins as tiebreaker
        }

        return candidates.map { ($0.identifier, $0.view) }
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

    /// Whether `a` renders in front of `b` — the same lexicographic z-path
    /// comparison `matches(at:)` sorts by, exposed so the inspector can tell
    /// "the stamp is on top of what hitTest returned" from "hitTest is right
    /// and the stamp is behind it".
    static func isInFront(_ a: UIView, of b: UIView) -> Bool {
        compareZPaths(zOrderPath(of: a), zOrderPath(of: b)) > 0
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
    var tokenColors: [RipulDeclaredTokenColor] = []

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
        // Also carry the id on the view itself: the stamper is not an accessibility
        // element (VoiceOver ignores it), but the plain-UIView id makes the stamp
        // visible to hierarchy scans — the audit's descendant walk and
        // accessibilityIdInTree — not just the spatial lookup.
        uiView.accessibilityIdentifier = identifier
        // Re-stored on every update so a theme change (which re-renders SwiftUI and
        // re-runs this) refreshes the declared colours to the current resolve.
        uiView.ripulDeclaredTokenColors = tokenColors
    }
}

public extension View {
    /// Assigns a logical identifier visible to the View Inspector.
    /// Uses a background UIView registered in a spatial lookup — the inspector
    /// finds the tightest match at the cursor point, no tree walking needed.
    ///
    /// `tokenColors` optionally declares the token-tagged colours this SwiftUI content
    /// renders with (property label → the host's UIColor), so the inspector's
    /// Design-token section works for SwiftUI elements — their drawn colours live in
    /// layers the host's token provider can't otherwise reach:
    ///
    ///     Text(title)
    ///         .foregroundColor(SwiftUI.Color(Color.Component.rowTitle))
    ///         .uiKitIdentifier("screen.row.title",
    ///                          tokenColors: ["Text colour": Color.Component.rowTitle])
    func uiKitIdentifier(_ identifier: String,
                         tokenColors: KeyValuePairs<String, UIColor> = [:]) -> some View {
        self
            .accessibilityIdentifier(identifier)
            .background(UIKitIdentifierStamper(
                identifier: identifier,
                tokenColors: tokenColors.map { RipulDeclaredTokenColor(property: $0.key, color: $0.value) }))
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
    let registryStamps: [String]       // ALL .uiKitIdentifier stamps under the tap point, front-to-back
    /// The tightest thing at this point that can actually be PRESSED, when it
    /// isn't the selected element itself. Two masters, two answers: the theme
    /// tools want the closest element whether or not it is interactive, and
    /// actuation wants the closest thing a tap would drive. Collapsing those
    /// into one value is what made a panel highlight while a stamp got pressed
    /// — every attempt to satisfy one consumer quietly stole from the other.
    /// Surfaced whenever they diverge so the difference is visible rather than
    /// deduced from the aftermath.
    let actionableSummary: String?
    /// Whether `accessibilityId` was borrowed from an ancestor rather than set
    /// on this element — computed at inspect time, where the main-actor view
    /// hierarchy is available.
    let identifierIsInherited: Bool
                                       // (first = the resolved one) — makes nested sub-element ids
                                       // discoverable from a single tap on a SwiftUI row
    let registryMatchView: UIView?     // the resolved stamp's own view — carries the declared token
                                       // colours for a SwiftUI element (ripulDeclaredTokenColors)

    /// The view the Design-token section should read: the resolved stamp when a SwiftUI
    /// element was selected (its declared token colours live there), else the inspected view.
    var tokenAnchorView: UIView { registryMatchView ?? view }

    struct LayerInfo {
        let cornerRadius: CGFloat
        let borderWidth: CGFloat
        let borderColor: UIColor?
        let shadowRadius: CGFloat
        let shadowOpacity: Float
    }

    static func inspect(_ view: UIView, depth: Int = 0, resolvedIdentifier: String? = nil, hitLeaf: UIView? = nil, registryStamps: [String] = [], registryMatchView: UIView? = nil, actionableSummary: String? = nil) -> InspectedView {
        let rawClassName = String(describing: type(of: view))
        // A tap that resolves a SwiftUI stamp often lands on the stamp's own host container —
        // "UIKitPlatformViewHost<…UIKitIdentifierStamper>" is inspector plumbing, not the
        // user's element. Present it as what it semantically is.
        let className = rawClassName.contains("UIKitIdentifierStamper") ? "SwiftUI element" : rawClassName
        let frameInWindow = view.convert(view.bounds, to: nil)
        // The leaf's OWN identifier first (a UIKit accessibilityIdentifier set in code), then the
        // SwiftUI spatial-registry match (.uiKitIdentifier). Previously only the latter was used, so
        // UIKit identifiers never surfaced. Finally, for a bounded SwiftUI cell/leaf (List/Form rows
        // arrive as a bare `CellHostingView`), recover a standard SwiftUI `.accessibilityIdentifier`
        // from the accessibility tree — it lives on the row's accessibility element, not the cell's
        // own `accessibilityIdentifier`, so without this it never showed.
        let resolvedId = nonEmpty(view.accessibilityIdentifier)
            ?? resolvedIdentifier
            ?? (isSwiftUIHostedLeaf(view) ? accessibilityIdInTree(view) : nil)
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
            hitLeafClass: hitLeaf.map { String(describing: type(of: $0)) },
            registryStamps: registryStamps,
            actionableSummary: actionableSummary,
            identifierIsInherited: Self.identifierIsInherited(view),
            registryMatchView: registryMatchView
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

    // MARK: SwiftUI accessibility-tree identity

    /// A bounded SwiftUI unit the geometric leaf-walk lands on — a List/Form row's `CellHostingView`
    /// or a SwiftUI leaf-drawing view — as opposed to a whole-screen `_UIHostingView`. ONLY these get
    /// the accessibility-tree id lookup below, so inspecting a large container never borrows a child
    /// row's identifier.
    static func isSwiftUIHostedLeaf(_ view: UIView) -> Bool {
        let cls = String(describing: type(of: view))
        return cls.contains("CellHostingView")          // List / Form row (the reported case)
            || cls.hasPrefix("_UIGraphicsView")          // SwiftUI leaf drawing (text / shapes)
            || cls.contains("_UIHostingViewCell")        // collection-backed SwiftUI cell
            || cls.contains("PlatformViewHost")          // UIViewRepresentable leaf
    }

    /// SwiftUI applies `.accessibilityIdentifier` to a row's *accessibility element*, not to the
    /// backing `CellHostingView`'s own `accessibilityIdentifier` — so a tapped List/Form row inspects
    /// as a bare `CellHostingView<…>` with no id even though it IS instrumented (VoiceOver / XCUITest
    /// read it). Recover the id from the accessibility tree: this view's accessibility elements first
    /// (where a `.accessibilityElement(children: .combine)` row stores its id), then descendant views'
    /// own identifiers. Depth-bounded; callers restrict it to a bounded SwiftUI cell/leaf (see
    /// `isSwiftUIHostedLeaf`) so the id belongs to THIS element.
    /// Whether this view's `accessibilityIdentifier` was inherited from an
    /// ancestor. SwiftUI applies `.accessibilityIdentifier` to a whole subtree,
    /// so a descendant carries the island's id as its own property; an id an
    /// ancestor also has names the ANCESTOR. Mirrors
    /// `ScreenElementFinder.ownAccessibilityIdentifier`, inline here because
    /// `inspect` is not main-actor isolated.
    static func identifierIsInherited(_ view: UIView) -> Bool {
        guard let id = view.accessibilityIdentifier, !id.isEmpty else { return false }
        var ancestor = view.superview
        var hops = 0
        while let cur = ancestor, hops < 12 {
            if cur.accessibilityIdentifier == id { return true }
            ancestor = cur.superview
            hops += 1
        }
        return false
    }

    static func accessibilityIdInTree(_ view: UIView, maxDepth: Int = 6) -> String? {
        if let id = firstElementIdentifier(of: view) { return id }
        guard maxDepth > 0 else { return nil }
        for sub in view.subviews {
            if let id = nonEmpty(sub.accessibilityIdentifier) { return id }
            if let id = accessibilityIdInTree(sub, maxDepth: maxDepth - 1) { return id }
        }
        return nil
    }

    /// Read `accessibilityIdentifier` off any accessibility object. A plain
    /// `as? UIAccessibilityIdentification` cast only works when the class *declares*
    /// conformance — SwiftUI's private element classes (e.g. `AccessibilityNode`) can
    /// implement the getter without declaring the protocol, which makes the cast fail
    /// and read as nil even though an identifier is stored. So fall back to invoking
    /// the (public-selector) getter through the ObjC runtime when the object responds.
    static func objectAccessibilityIdentifier(_ obj: AnyObject) -> String? {
        if let idObj = obj as? UIAccessibilityIdentification, let id = nonEmpty(idObj.accessibilityIdentifier) {
            return id
        }
        let sel = NSSelectorFromString("accessibilityIdentifier")
        guard let nsObj = obj as? NSObject, nsObj.responds(to: sel) else { return nil }
        return nonEmpty(nsObj.perform(sel)?.takeUnretainedValue() as? String)
    }

    /// First non-empty `accessibilityIdentifier` among an object's accessibility elements — covering
    /// SwiftUI's two exposures: the `accessibilityElements` array, or the container protocol
    /// (`accessibilityElementCount()` / `accessibilityElement(at:)`).
    private static func firstElementIdentifier(of obj: NSObject) -> String? {
        if let els = obj.accessibilityElements {
            for el in els {
                if let id = objectAccessibilityIdentifier(el as AnyObject) { return id }
            }
        }
        let count = obj.accessibilityElementCount()
        if count > 0 && count != NSNotFound {
            for i in 0..<count {
                if let el = obj.accessibilityElement(at: i), let id = objectAccessibilityIdentifier(el as AnyObject) {
                    return id
                }
            }
        }
        return nil
    }

    /// The identifiers of the VoiceOver-visible accessibility elements in a hosting subtree, in tree
    /// order — nil for an element that has no identifier. This is the set the Audit tab should judge:
    /// SwiftUI Lists/Forms expose one combined element per row, and `.accessibilityHidden(true)`
    /// decoration is already absent from the tree. Depth- and size-bounded.
    static func accessibilityElementIdentifiers(in root: UIView, limit: Int = 300) -> [String?] {
        var out: [String?] = []
        func visit(_ obj: NSObject, depth: Int) {
            if out.count >= limit || depth > 60 { return }
            var children: [NSObject] = []
            if let els = obj.accessibilityElements as? [NSObject] {
                children = els
            } else {
                let n = obj.accessibilityElementCount()
                if n > 0 && n != NSNotFound {
                    for i in 0..<n { if let e = obj.accessibilityElement(at: i) as? NSObject { children.append(e) } }
                }
            }
            if !children.isEmpty {
                for c in children { visit(c, depth: depth + 1) }
                return
            }
            if obj.isAccessibilityElement {
                out.append(elementIdentifier(obj, window: root.window))
                return
            }
            if let v = obj as? UIView {
                for sub in v.subviews where !sub.isHidden && sub.alpha > 0.01 && sub.tag != ripulViewExplorerOverlayTag {
                    visit(sub, depth: depth + 1)
                }
            }
        }
        visit(root, depth: 0)
        return out
    }

    /// Identifier for one VoiceOver-visible element: its own id (declared conformance or
    /// runtime-read), else the `.uiKitIdentifier` stamp whose registered frame covers the
    /// element's on-screen centre. The spatial join is what names a combined SwiftUI row —
    /// its stamper is a background view the AX tree never exposes, so the frame is the
    /// only key connecting the element to its stamp.
    private static func elementIdentifier(_ obj: NSObject, window: UIWindow?) -> String? {
        if let id = objectAccessibilityIdentifier(obj) { return id }
        guard let window else { return nil }
        let screenFrame = obj.accessibilityFrame
        guard screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let windowRect = window.convert(screenFrame, from: window.screen.coordinateSpace)
        return UIKitIdentifierRegistry.shared.bestMatch(at: CGPoint(x: windowRect.midX, y: windowRect.midY))?.identifier
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
        var lines = ["class: \(className)\(idBadge)", "sdk: \(ripulSDKVersion)"]
        // What a tap would actually drive, when that is NOT the selected
        // element. Printed second so it reads as a warning: you have selected
        // one thing and pressing will hit another.
        if let actionable = actionableSummary { lines.append("actionable: \(actionable)") }
        if let leaf = hitLeafClass { lines.append("tapped: \(leaf)") }   // actual view under the finger
        if let p = propertyRef { lines.append("property: \(p)") }
        if let c = container { lines.append("container: \(c)") }
        if let vc = owningViewController { lines.append("controller: \(vc)") }
        if let ctrl = enclosingControl { lines.append("control: \(ctrl)") }
        if let t = text { lines.append("text: \"\(t)\"") }
        if let img = imageName { lines.append("image: \(img)") }
        if let aid = accessibilityId, !aid.isEmpty {
            // Flag a borrowed id. SwiftUI stamps a whole island's descendants
            // with the island's identifier, so an id here may name the
            // CONTAINER rather than this element — worth seeing before writing
            // a macro selector against it.
            lines.append("a11yId: \(aid)\(identifierIsInherited ? "  (inherited from an ancestor)" : "")")
        }
        // Nested stamps under the same tap (front-to-back): a SwiftUI row and the
        // title/subtitle inside it — tap the smaller region to select a sub-element
        // directly; this line makes those ids discoverable without pixel-hunting.
        if registryStamps.count > 1 {
            lines.append("stamps: \(registryStamps.joined(separator: " > "))")
        }
        if let label = accessibilityLabel, !label.isEmpty { lines.append("a11yLabel: \(label)") }
        if let rid = restorationIdentifier { lines.append("restorationId: \(rid)") }
        if tag != 0 { lines.append("tag: \(tag)") }
        for a in controlActions { lines.append("action: \(a)") }
        if viewControllerChain.count > 1 {
            lines.append("vcChain: \(viewControllerChain.joined(separator: " ← "))")
        }
        // TEMP diagnostic: when a SwiftUI hosting cell/leaf resolves NO identifier, dump the raw
        // accessibility picture so we can see WHERE SwiftUI actually stores `.accessibilityIdentifier`
        // (its private AX tree is frequently not exposed to in-process UIKit APIs). Remove once the
        // resolution path is confirmed.
        if (accessibilityId ?? "").isEmpty && className.contains("Hosting") {
            lines.append(InspectedView.accessibilityProbe(for: view))
        }
        return lines.joined(separator: "\n")
    }

    /// Dump everything the in-process UIKit accessibility APIs expose for `view` and its subtree —
    /// so we can locate a SwiftUI `.accessibilityIdentifier` that isn't surfacing.
    static func accessibilityProbe(for view: UIView) -> String {
        var out = ["probe:"]
        out.append("  self isEl=\(view.isAccessibilityElement) aid=\(q(view.accessibilityIdentifier)) lbl=\(q(view.accessibilityLabel))")

        // accessibilityElements array
        if let els = view.accessibilityElements {
            out.append("  accessibilityElements=\(els.count)")
            for (i, e) in els.prefix(8).enumerated() {
                let aid = (e as? UIAccessibilityIdentification)?.accessibilityIdentifier
                let lbl = (e as? NSObject)?.accessibilityLabel
                out.append("    el[\(i)] \(type(of: e)) aid=\(q(aid)) lbl=\(q(lbl))")
                out.append("      \(axReadDiagnostics(e as AnyObject))")
            }
        } else {
            out.append("  accessibilityElements=nil")
        }

        // container protocol (SwiftUI often implements this instead of the array)
        let n = view.accessibilityElementCount()
        out.append("  elementCount=\(n)")
        if n > 0 && n != NSNotFound {
            for i in 0..<min(n, 8) {
                if let e = view.accessibilityElement(at: i) {
                    let aid = (e as? UIAccessibilityIdentification)?.accessibilityIdentifier
                    let lbl = (e as? NSObject)?.accessibilityLabel
                    out.append("    elAt[\(i)] \(type(of: e)) aid=\(q(aid)) lbl=\(q(lbl))")
                    out.append("      \(axReadDiagnostics(e as AnyObject))")
                }
            }
        }

        // descendant views/elements carrying ANY accessibilityIdentifier
        var found: [String] = []
        var viewCount = 0
        func walk(_ v: UIView, _ d: Int) {
            for s in v.subviews {
                viewCount += 1
                if found.count < 14 {
                    if let id = nonEmpty(s.accessibilityIdentifier) { found.append("\(type(of: s))=\(id)") }
                    if let els = s.accessibilityElements {
                        for e in els {
                            if let id = objectAccessibilityIdentifier(e as AnyObject) {
                                found.append("el·\(type(of: e))=\(id)")
                            }
                        }
                    }
                }
                if d < 10 { walk(s, d + 1) }
            }
        }
        walk(view, 0)
        out.append("  subtreeViews=\(viewCount) foundIds=[\(found.joined(separator: ", "))]")

        // superview chain identifiers
        var chain: [String] = []
        var p = view.superview; var hops = 0
        while let cur = p, hops < 8 {
            if let id = nonEmpty(cur.accessibilityIdentifier) { chain.append("\(type(of: cur))=\(id)") }
            p = cur.superview; hops += 1
        }
        out.append("  superIds=[\(chain.joined(separator: ", "))]")
        return out.joined(separator: "\n")
    }

    /// How an element's identifier is (or isn't) readable in-process: declared protocol
    /// conformance vs a runtime-only getter, the value the runtime read returns, and the
    /// superclass chain. A failed read then *names* the class + missing path instead of
    /// leaving "aid=nil" ambiguous (which previously conflated "no value" with "cast failed").
    private static func axReadDiagnostics(_ obj: AnyObject) -> String {
        let conforms = obj is UIAccessibilityIdentification
        let sel = NSSelectorFromString("accessibilityIdentifier")
        let responds = (obj as? NSObject)?.responds(to: sel) ?? false
        let runtime: String? = responds
            ? nonEmpty((obj as? NSObject)?.perform(sel)?.takeUnretainedValue() as? String)
            : nil
        var chain: [String] = []
        var cls: AnyClass? = object_getClass(obj)
        var hops = 0
        while let c = cls, hops < 4 {
            chain.append(NSStringFromClass(c))
            cls = class_getSuperclass(c)
            hops += 1
        }
        return "conforms=\(conforms) responds=\(responds) rt=\(q(runtime)) chain=\(chain.joined(separator: " < "))"
    }

    private static func q(_ s: String?) -> String { (s?.isEmpty == false) ? "\"\(s!)\"" : "nil" }
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
    var onElementTap: ((RipulElementTap) -> Void)?
    /// The HOST window to hit-test when the explorer runs in its own overlay
    /// window (`RipulViewExplorer.present`). Nil for embedded mounts, where
    /// `self.window` IS the host window.
    var hostWindow: UIWindow?
    /// Fired after a single-tap actuation attempt with a one-line outcome
    /// ("via uicontrol", "via rowSelection", "not tappable") — the overlay
    /// shows it as a transient pill so a dead element reports itself instead
    /// of silently doing nothing.
    var onFireOutcome: ((String) -> Void)?

    private let cursorAccel: CGFloat = 1.4
    private var cursorPos: CGPoint
    private var lastTouch: CGPoint?

    // Highlight layer drawn around the selected view
    private let highlightLayer = CAShapeLayer()

    // Double-tap detection state
    /// The on-screen explorer, when one is up — the handle `explorer_probe`
    /// drives. Weak: the controller's lifetime is the overlay's.
    static weak var live: ViewInspectorController?
    /// The last resolution, kept so a probe can report exactly the readout a
    /// human would be looking at rather than a reconstruction of it.
    private var currentInfo: InspectedView?

    private var currentTarget: UIView?
    private var currentTokenAnchor: UIView?
    /// What a tap will actually drive — see `actionableTarget`. Distinct from
    /// `currentTarget`, which is what is selected, outlined and themed.
    private var currentActionable: UIView?
    /// Second outline, drawn only when the actionable view differs from the
    /// selected one, so a divergence is visible on screen and not just in text.
    private let actionableLayer = CAShapeLayer()
    private var lastTapTime: TimeInterval?
    private var lastTapPosition: CGPoint?
    private let doubleTapInterval: TimeInterval = 0.45
    private let doubleTapDistance: CGFloat = 60

    // Single-tap actuation state: a tap (short, no drag) FIRES the
    // highlighted element through the shared actuation engine — delayed just
    // past the double-tap window and cancelled if a second tap begins, so
    // the existing double-tap confirm/record gesture is untouched. Dragging
    // still picks live (the highlight follows the reticule) — inspection
    // needs no tap at all.
    private var touchDownTime: TimeInterval = 0
    private var touchMoved = false
    private var pendingTapFire: DispatchWorkItem?
    private var suppressNextTapFire = false
    private let tapFireDelay: TimeInterval = 0.28
    private let tapMaxDuration: TimeInterval = 0.3

    /// Settings-tab toggle ("Single tap fires the highlighted element"),
    /// read raw because this is a UIView, not a SwiftUI View.
    private var singleTapFiresEnabled: Bool {
        UserDefaults.standard.object(forKey: "viewInspector.singleTapFires") as? Bool ?? true
    }

    override init(frame: CGRect) {
        cursorPos = CGPoint(x: frame.width / 2, y: frame.height / 2)
        super.init(frame: frame)
        Self.live = self
        backgroundColor = .clear
        isMultipleTouchEnabled = false

        highlightLayer.fillColor = UIColor.systemPink.withAlphaComponent(0.12).cgColor
        highlightLayer.strokeColor = UIColor.systemPink.cgColor
        highlightLayer.lineWidth = 2
        layer.addSublayer(highlightLayer)
        // Dashed cyan, no fill: unmistakably a different statement from the
        // pink selection box. Only ever drawn when a tap would hit something
        // other than what is selected.
        actionableLayer.fillColor = UIColor.clear.cgColor
        actionableLayer.strokeColor = UIColor.systemTeal.cgColor
        actionableLayer.lineWidth = 2
        actionableLayer.lineDashPattern = [5, 3]
        layer.addSublayer(actionableLayer)
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
        NSLog("[RipulViewExplorer] touchesBegan loc=(%.1f, %.1f) lastTapTime=%.3f timestamp=%.3f", loc.x, loc.y, lastTapTime ?? -1, t.timestamp)

        // Detect a double-tap on the currently highlighted element and hand it to
        // the host app as an abstract element tap. The payload's `view` is the
        // token-anchor (the .uiKitIdentifier stamp) when one resolved, so the host
        // reads the same element the Edit tab does; `targetView` is the raw pick.
        if isDoubleTap(at: loc, time: t.timestamp) {
            lastTapTime = nil
            lastTapPosition = nil
            // The first tap of the pair scheduled a single-tap fire — cancel it
            // (this is a double-tap) and don't let this tap's end schedule another.
            pendingTapFire?.cancel()
            pendingTapFire = nil
            suppressNextTapFire = true
            if let element = currentTokenAnchor ?? currentTarget {
                // The RETICULE, not the finger. The crosshair is a relative,
                // accelerated cursor (touchesMoved integrates the delta), so
                // `loc` is wherever the hand happens to rest and has no
                // relation to what is being pointed at — it can be off the
                // target entirely. `element` was resolved from `cursorPos`, so
                // the point reported alongside it has to be `cursorPos` too or
                // the payload describes two different places.
                //
                // In the HOST window's space: the explorer lives in its own
                // overlay window, and every consumer (macro recording, the
                // actuation engine's point path) resolves this against host
                // views.
                let hostPoint = (hostWindow ?? window).map { convert(cursorPos, to: $0) } ?? cursorPos
                let tap = RipulElementTap(view: element,
                                          targetView: currentTarget ?? element,
                                          point: hostPoint,
                                          actionableView: currentActionable)
                NSLog("[RipulViewExplorer] element tap anchor=%@ target=%@ action=%d",
                      String(describing: type(of: element)),
                      String(describing: type(of: tap.targetView)), onElementTap != nil)
                UISelectionFeedbackGenerator().selectionChanged()
                onElementTap?(tap)
            }
            return
        }

        lastTapTime = t.timestamp
        lastTapPosition = loc
        lastTouch = loc
        touchDownTime = t.timestamp
        touchMoved = false
        pickAt(cursorPos)
    }

    /// Two quick taps near each other count as a double-tap on the highlighted element.
    private func isDoubleTap(at loc: CGPoint, time: TimeInterval) -> Bool {
        guard let lastTime = lastTapTime, let lastPos = lastTapPosition else {
            NSLog("[RipulViewExplorer] isDoubleTap false: no prior tap")
            return false
        }
        let dt = time - lastTime
        let dist = hypot(loc.x - lastPos.x, loc.y - lastPos.y)
        let ok = dt <= doubleTapInterval && dist <= doubleTapDistance
        NSLog("[RipulViewExplorer] isDoubleTap dt=%.3f dist=%.1f ok=%d", dt, dist, ok)
        return ok
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let last = lastTouch else { return }
        touchMoved = true
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
        guard let t = touches.first else { return }

        // A tap that completed a double-tap shouldn't ALSO fire the element.
        if suppressNextTapFire {
            suppressNextTapFire = false
            return
        }

        // Single tap = fire the highlighted element: short touch, no drag —
        // scheduled just past the double-tap window so a second tap can
        // cancel it (see touchesBegan).
        guard !touchMoved,
              t.timestamp - touchDownTime < tapMaxDuration,
              singleTapFiresEnabled else { return }
        pendingTapFire?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireHighlightedElement() }
        pendingTapFire = work
        DispatchQueue.main.asyncAfter(deadline: .now() + tapFireDelay, execute: work)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastTouch = nil
        pendingTapFire?.cancel()
        pendingTapFire = nil
        suppressNextTapFire = false
    }

    /// Fire the currently highlighted element through the shared actuation
    /// engine — the exact 4-path ladder a macro step would use, so what you
    /// drive by pointing is what a recording would replay. Pulses the
    /// highlight border around the element it actuated (pink on success, red
    /// on failure) so the user SEES which element was pressed — "the tap
    /// worked but the app ignored it" and "the tap hit the wrong element"
    /// look identical without it.
    private func fireHighlightedElement() {
        pendingTapFire = nil
        fireNow()
    }

    /// Move the reticule to a point in HOST-WINDOW coordinates — the same space
    /// `inspect_screen` reports frames in — re-resolve, and report exactly what
    /// a human at the crosshair would be looking at. `fire` presses afterwards
    /// through the identical path a tap takes.
    ///
    /// This exists because every diagnosis today has gone through a human
    /// reading a readout off a phone and retyping it. The reticule is a
    /// relative accelerated cursor with no absolute addressing, so it could not
    /// be driven from a tool, so the one path that actually fails — resolution
    /// by POINT — was the one path neither of us could test directly.
    func probe(atWindowPoint windowPoint: CGPoint, fire: Bool) -> [String: Any] {
        let local = (hostWindow ?? window).map { convert(windowPoint, from: $0) } ?? windowPoint
        cursorPos = CGPoint(x: max(0, min(bounds.width - 1, local.x)),
                            y: max(0, min(bounds.height - 1, local.y)))
        onCursorMoved?(cursorPos)
        pickAt(cursorPos)

        func describe(_ v: UIView?) -> [String: Any]? {
            guard let v else { return nil }
            let f = v.convert(v.bounds, to: nil)
            var d: [String: Any] = ["class": String(describing: type(of: v)),
                                    "frame": ["x": Double(f.minX), "y": Double(f.minY),
                                              "w": Double(f.width), "h": Double(f.height)]]
            if let id = ScreenElementFinder.identifier(of: v) { d["id"] = id }
            return d
        }

        var result: [String: Any] = [
            "success": true,
            "reticule": ["x": Double(windowPoint.x), "y": Double(windowPoint.y)],
            // The readout verbatim — the exact text the Copy button yields, so a
            // tool-driven check and a human report are the same artefact.
            "readout": currentInfo?.sourceReference() ?? "",
            "outline": currentActionable == nil ? "grey (nothing here responds to a tap)" : "pink",
        ]
        if let e = describe(currentTarget) { result["element"] = e }
        if let a = describe(currentActionable) { result["actionable"] = a }
        result["diverges"] = currentActionable != nil && currentActionable !== currentTarget

        if fire {
            if let outcome = fireNow() {
                result["fired"] = ["via": outcome.via as Any,
                                   "activated": outcome.activatedLabel as Any,
                                   "activatedId": outcome.activatedIdentifier as Any,
                                   "success": outcome.success,
                                   "trace": outcome.trace]
            } else {
                result["fired"] = ["success": false,
                                   "error": "nothing resolved under the reticule to press"]
            }
        }
        return result
    }

    /// The fire itself, callable without a touch so the reticule can be driven
    /// programmatically (`explorer_probe`). Everything a human tap does happens
    /// here — same re-pick, same target choice, same ladder, same pill — so a
    /// tool-driven test exercises the real path rather than a replica of it.
    /// Testing a replica is how several of today's "fixed" claims were wrong.
    @discardableResult
    func fireNow() -> ScreenActuationEngine.TapOutcome? {
        // Re-resolve FIRST. The stored target is whatever was under the
        // crosshair when the pick last ran, and the pick only runs when the
        // reticule MOVES — so anything that changes the app's layout without a
        // reticule move leaves it stale. Focusing a text field does exactly
        // that: the keyboard raises, the panel reflows, the keyboard dismisses
        // and it reflows back, all while the crosshair sits still. The next
        // fire then pressed an element resolved against a layout that no longer
        // existed, which is why a second tap on the notes field closed the
        // panel instead of entering it. Press what is under the cursor NOW.
        pickAt(cursorPos)
        // Press the SELECTED element, not the stamp. The token anchor is a
        // 0.01-alpha, non-interactive marker view spanning whatever it labels,
        // so preferring it handed the ladder something unpressable — every rung
        // declined, and the point derived from that marker went through the
        // coordinate conversion that silently no-ops inside a SwiftUI island.
        // "Not tappable by any path" for a field that focuses fine when it is
        // the target itself.
        // The ACTIONABLE view — what a tap drives — falling back to the
        // selection when they're the same or nothing there is pressable.
        guard let element = currentActionable ?? currentTarget ?? currentTokenAnchor else { return nil }
        UISelectionFeedbackGenerator().selectionChanged()
        let frameInSelf = convert(element.convert(element.bounds, to: nil), from: nil)
        // Where the reticule actually is, in the HOST window's space. An
        // anonymous SwiftUI leaf carries no id and no text, so the point is the
        // only thing that says WHICH element was meant (actuation path 2c).
        let firePoint = (hostWindow ?? self.window).map { convert(cursorPos, to: $0) }
        let outcome = ScreenActuationEngine.performTap(
            on: element,
            matchId: ScreenElementFinder.identifier(of: element),
            matchText: ScreenElementFinder.contentText(of: element),
            at: firePoint)
        NSLog("[RipulViewExplorer] single-tap fire via=%@ trace=%@", outcome.via ?? "none", outcome.trace)
        let headline = outcome.via.map { "via \($0)" } ?? "not tappable"
        onFireOutcome?("\(headline)  [\(outcome.trace)]")
        flashFireOutcome(at: frameInSelf, success: outcome.success)
        // The screen may navigate/re-render — re-pick shortly after so the
        // highlight reflects the new reality.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.pickAt(self.cursorPos)
        }
        return outcome
    }

    /// Two quick border pulses around the frame the fire actuated — the
    /// unmissable version of the outcome pill.
    private func flashFireOutcome(at frame: CGRect, success: Bool) {
        let pulse = CAShapeLayer()
        pulse.fillColor = UIColor.clear.cgColor
        pulse.strokeColor = (success ? UIColor.systemPink : UIColor.systemRed).cgColor
        pulse.lineWidth = 3
        pulse.path = UIBezierPath(roundedRect: frame.insetBy(dx: -2, dy: -2), cornerRadius: 8).cgPath
        layer.addSublayer(pulse)
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1
        anim.toValue = 0
        anim.duration = 0.25
        anim.autoreverses = true
        anim.repeatCount = 2
        anim.isRemovedOnCompletion = true
        pulse.add(anim, forKey: "pulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { pulse.removeFromSuperlayer() }
    }

    // MARK: Hit testing

    private func pickAt(_ point: CGPoint) {
        // Pick against the HOST window when the explorer runs in its own
        // overlay window (self.window is the overlay, not the host); for
        // embedded mounts, self.window IS the host window.
        guard let window = hostWindow ?? self.window else { highlightLayer.path = nil; return }
        let windowPoint = convert(point, to: window)

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
        var target = controlToInspect(for: leaf)

        // Spatial lookup: ALL .uiKitIdentifier() stamps at this point, tightest first —
        // the first resolves the identity, the rest are surfaced as `stamps:` so nested
        // sub-element ids are discoverable from one tap.
        let stampMatches = UIKitIdentifierRegistry.shared.matches(at: windowPoint)
        let match = stampMatches.first

        // hitTest can resolve into a DIFFERENT branch than what is visually on
        // top. SwiftUI hosting content routinely declines a probe hit-test — its
        // interactive platform views sit under zero-size layout containers — so
        // hitTest falls THROUGH the control and lands on the legacy UIKit view
        // behind it. On WAC's add-record screen that reported "class: UIStackView"
        // for a glass time field, and the fire ladder then had a UIStackView to
        // press, which is nothing: "not tappable" on a control that works fine
        // under a real finger.
        //
        // The stamp covering this point is already what we HIGHLIGHT, so when the
        // two disagree and the stamp is genuinely in front, the stamp wins. Its
        // enclosing hosting view is the reported element: `_UIHostingView<Foo>`
        // names the SwiftUI type, which is what someone needs to find it in source.
        if let stamped = match?.view,
           !stamped.isDescendant(of: target), !target.isDescendant(of: stamped),
           UIKitIdentifierRegistry.isInFront(stamped, of: target) {
            target = hostingAncestor(of: stamped) ?? stamped
        }
        // Last resort: the pick resolved something that cannot be pressed, but an
        // actuatable view sits under the cursor in a branch the refinement never
        // reached. That is the standing shape of the SwiftUI problem — the probe
        // hit-test stops at anonymous scaffolding — and it is why the notes field
        // reported a 360×93 container instead of the `UITextView` inside it.
        // Guarded on the target being unactuatable so a correct pick is never
        // second-guessed, and scoped to actuatable views so a full-screen
        // passthrough layer can't win on area.
        // TWO answers, not one compromise. `target` stays the closest ELEMENT —
        // interactivity irrelevant — because that is what the theme tools
        // select and what the outline and identity describe. Alongside it sits
        // the closest ACTIONABLE view, which is what a tap will drive. They are
        // frequently the same object; when they aren't, both are reported and
        // the user can see the discrepancy instead of discovering it by having
        // the wrong thing pressed.
        //
        // Every fix from 0.7.42 to 0.7.44 was this one value being pulled
        // between those two masters, and each one satisfied a consumer by
        // taking from another.
        currentActionable = actionableTarget(for: target, at: windowPoint)

        currentTarget = target
        let hitLeaf = (target !== leaf) ? leaf : nil

        // Outline what was SELECTED, not the stamp that helped resolve it. The
        // stamp is frequently a whole panel (`addShift.notes.panel` is 360×93
        // around a 284×44 field), so preferring it drew the box round the
        // container while the readout named the field — the reticule and the
        // text disagreeing about which element you had. Whatever is named,
        // outlined and pressed must be one element or none of them can be
        // trusted. The stamp keeps its real job: `tokenAnchorView`, which is
        // what the Design-token section reads.
        //
        // Which of the two is the truer box depends on the element, and BOTH
        // shapes occur in one panel:
        //   notes field  — target `NotesUITextView` 284×44 beats the only
        //                  stamps present, `notes.panel` 360×93 (an ancestor).
        //   attach button — stamp 44×44 beats the SwiftUI scaffolding the pick
        //                  resolves to, an `_UIInheritedView` spanning 336×44.
        // Preferring either one unconditionally is wrong for the other, so take
        // the TIGHTER. Both already contain the cursor — `matches(at:)`
        // guarantees it for the stamp — so the smaller is simply the more
        // precise statement of the same element.
        let highlightView: UIView = {
            guard let stamped = match?.view else { return target }
            let stampArea = stamped.bounds.width * stamped.bounds.height
            let targetArea = target.bounds.width * target.bounds.height
            return (stampArea > 0 && stampArea < targetArea) ? stamped : target
        }()
        let frameInWindow = highlightView.convert(highlightView.bounds, to: nil)
        let frameInSelf = convert(frameInWindow, from: nil)
        highlightLayer.path = UIBezierPath(roundedRect: frameInSelf, cornerRadius: highlightView.layer.cornerRadius).cgPath
        // Grey the selection when nothing there answers a tap, so "I can select
        // this but pressing it will do nothing" is legible at a glance rather
        // than only in the text. Theme work selects such elements constantly —
        // a label, a background — and they are perfectly valid selections.
        let inert = currentActionable == nil
        highlightLayer.strokeColor = (inert ? UIColor.systemGray : UIColor.systemPink).cgColor
        highlightLayer.fillColor = (inert ? UIColor.systemGray : UIColor.systemPink)
            .withAlphaComponent(0.12).cgColor

        // The second box, only when a tap would hit something else.
        if let actionable = currentActionable, actionable !== highlightView, actionable !== target {
            let f = convert(actionable.convert(actionable.bounds, to: nil), from: nil)
            actionableLayer.path = UIBezierPath(roundedRect: f,
                                                cornerRadius: actionable.layer.cornerRadius).cgPath
        } else {
            actionableLayer.path = nil
        }

        // Inspect — pass the resolved identifier from spatial lookup
        // ALWAYS stated, because silence used to mean two opposite things:
        // "this is pressable and it's what you selected" and "nothing here is
        // pressable at all" both rendered as no line. Three states, three
        // answers.
        let actionableSummary: String? = {
            guard let a = currentActionable else { return "none — nothing here responds to a tap" }
            if a === target { return "this element" }
            let id = ScreenElementFinder.identifier(of: a).map { " [\($0)]" } ?? ""
            return "\(type(of: a))\(id)"
        }()
        let info = InspectedView.inspect(target, depth: viewDepth(target), resolvedIdentifier: match?.identifier, hitLeaf: hitLeaf, registryStamps: stampMatches.map(\.identifier), registryMatchView: match?.view, actionableSummary: actionableSummary)
        currentTarget = target
        currentTokenAnchor = info.tokenAnchorView
        currentInfo = info
        onInspect?(info)
    }

    /// The element to inspect for a tapped `leaf`: the nearest enclosing ACTUATABLE
    /// view (so a tap on a button's gradient/title subview reports the button, and a
    /// tap on a text view's internal layout subview reports the text view), else the
    /// leaf itself. Already-actuatable leaves are returned unchanged.
    ///
    /// "Actuatable" is deliberately the same set the tap ladder can drive, not just
    /// `UIControl`: a `UITextView` is a `UIScrollView`, never a control, so promoting
    /// only to controls reported its private `_UITextLayoutView` — an anonymous
    /// class with no id — for every tap on a notes field.
    private func controlToInspect(for leaf: UIView) -> UIView {
        if isActuatable(leaf) { return leaf }
        var v = leaf.superview
        var hops = 0
        while let cur = v, hops < 8 {
            if isInspectorOwnView(cur) { break }
            if isActuatable(cur) { return cur }
            // Don't climb out through a scrolling container into unrelated UI —
            // the same boundary the actuation engine's gesture path respects.
            if cur is UIScrollView || cur is UIWindow { break }
            v = cur.superview
            hops += 1
        }
        return leaf
    }

    /// Whether a tap on this view means something the actuation ladder can perform:
    /// control actions, text focus, or a tap recognizer. Kept in step with
    /// `ScreenActuationEngine.performTap`'s rungs — a view the explorer promotes to
    /// but the engine can't press would just move the failure.
    private func isActuatable(_ v: UIView) -> Bool {
        if v is UIControl { return true }
        if v is UITextInput, v.canBecomeFirstResponder { return true }
        // A scrolling container's own tap recognizers are scroll and selection
        // machinery, not this element's semantics. Counting them made the
        // readout promise something the engine then refused: every miss inside
        // a List reported `actionable: UpdateCoalescingCollectionView` while
        // the trace said `gesture:stoppedAtBoundary`, and an inert label — the
        // one archetype whose correct answer is "nothing here responds to a
        // tap" — claimed to be pressable. `performTap` already draws this
        // boundary; drawing it in only one of the two places is what let them
        // disagree. Note a UITextView IS a UIScrollView and its caret-placing
        // recognizer IS real: the text-input rung above claims it first.
        if v is UIScrollView { return false }
        if v.gestureRecognizers?.contains(where: { $0.isEnabled && $0 is UITapGestureRecognizer }) == true { return true }
        return false
    }

    /// The view a tap at `windowPoint` would actually drive, given that
    /// `element` is what the user selected. Nil when nothing there is pressable
    /// — which is an honest answer worth reporting, not a failure to hide.
    ///
    /// SCOPED, deliberately. Searching the whole window for "the tightest
    /// actionable view" finds a view controller's full-screen keyboard-dismiss
    /// recognizer whenever nothing better exists, so every unpressable element
    /// resolved to the root view and inherited its identity. The search is the
    /// element's own subtree first — the real control usually lives inside what
    /// you pointed at — then a bounded climb, stopping before any scrolling
    /// container so it cannot escape into unrelated UI.
    private func actionableTarget(for element: UIView, at windowPoint: CGPoint) -> UIView? {
        // INSIDE first, even when the element itself is actionable. A panel can
        // carry its own disclosure gesture while containing a text field, and
        // short-circuiting on the container meant pointing anywhere in the
        // panel pressed the panel — collapsing it instead of entering the
        // field. The tightest actionable thing at the point wins; the container
        // is the answer only where nothing more specific sits under the cursor,
        // which is exactly the behaviour a finger has.
        if let inside = actuatableView(in: element, at: windowPoint) { return inside }
        if isActuatable(element) { return element }
        var cur = element.superview
        var hops = 0
        while let v = cur, hops < 6 {
            if isInspectorOwnView(v) { break }
            if v is UIScrollView || v is UIWindow { break }
            if isActuatable(v) { return v }
            cur = v.superview
            hops += 1
        }
        return nil
    }

    /// The tightest actuatable view under `windowPoint`, anywhere in the window.
    /// Used only when the pick landed on something that CANNOT be actuated: the
    /// probe hit-test stops at SwiftUI's anonymous scaffolding, and the real
    /// control can sit in a branch the downward refinement never reaches. Scoped
    /// to actuatable views so full-screen passthrough layers (the system floating
    /// bar host, `_UITouchPassthroughView`) can never win.
    private func actuatableView(in root: UIView, at windowPoint: CGPoint) -> UIView? {
        var best: UIView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        func walk(_ v: UIView, depth: Int) {
            if depth > 60 { return }
            for sub in v.subviews where !sub.isHidden && sub.alpha > 0.01 && !isInspectorOwnView(sub) {
                let local = sub.convert(windowPoint, from: nil)
                let contains = sub.bounds.contains(local)
                // Descend through DEGENERATE containers even when they don't
                // contain the point. SwiftUI routinely nests a full-size view
                // under a zero-size `_UIInheritedView` (observed directly:
                // (40,296,0,0) wrapping a 113×68 child), and such a parent
                // never "contains" anything — gating recursion on containment
                // is precisely why hitTest can't reach these controls either.
                // A zero-area view clips nothing, so it must not gate the walk.
                let degenerate = sub.bounds.width < 1 || sub.bounds.height < 1
                guard contains || degenerate else { continue }
                if contains, isActuatable(sub) {
                    let area = sub.bounds.width * sub.bounds.height
                    if area < bestArea { bestArea = area; best = sub }
                }
                walk(sub, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return best
    }

    /// The SwiftUI hosting view enclosing `view`, if any — the boundary of one
    /// SwiftUI island in a UIKit hierarchy. Everything below it is SwiftUI's own
    /// layout scaffolding (`_UIInheritedView`, platform view hosts, stamps), none
    /// of which names anything a developer wrote; the hosting view's generic
    /// parameter does. Matched by class name because the type is private to
    /// SwiftUI.
    private func hostingAncestor(of view: UIView) -> UIView? {
        var cur: UIView? = view
        var hops = 0
        while let v = cur, hops < 12 {
            if String(describing: type(of: v)).contains("HostingView") { return v }
            cur = v.superview
            hops += 1
        }
        return nil
    }

    /// True if `v` is part of the inspector's own overlay (the touch layer, the
    /// crosshair, the floating HUD panel's root view, or — for a
    /// launcher-presented overlay — the tagged host view). Checks `v` and its
    /// ancestor chain, so any descendant of the overlay is caught too. App views
    /// are never inside this subtree, so their ancestor walk returns false.
    private func isInspectorOwnView(_ v: UIView) -> Bool {
        var cur: UIView? = v
        while let c = cur {
            if c === self { return true }
            if c.tag == ripulViewExplorerOverlayTag { return true }
            if c is RipulFloatingPanelRootView { return true }
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
                let contains = sub.bounds.contains(local)
                // Zero-area containers clip nothing and must not gate the
                // descent — SwiftUI nests full-size content under them. See
                // `actuatableView`.
                guard contains || sub.bounds.width < 1 || sub.bounds.height < 1 else { continue }
                if contains { best = sub }
                walk(sub)
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
                let contains = sub.bounds.contains(local)
                // As above: a zero-area SwiftUI wrapper must be walked THROUGH,
                // not treated as a miss, or everything it contains is
                // unreachable to the refinement.
                guard contains || sub.bounds.width < 1 || sub.bounds.height < 1 else { continue }
                if contains { best = sub }
                walk(sub)
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
    var hostWindow: UIWindow? = nil
    let onInspect: (InspectedView) -> Void
    let onCursorMoved: (CGPoint) -> Void
    let onElementTap: ((RipulElementTap) -> Void)?
    let onFireOutcome: ((String) -> Void)?

    func makeUIView(context: Context) -> ViewInspectorController {
        let v = ViewInspectorController(frame: UIScreen.main.bounds)
        v.hostWindow = hostWindow
        v.onInspect = onInspect
        v.onCursorMoved = onCursorMoved
        v.onElementTap = onElementTap
        v.onFireOutcome = onFireOutcome
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return v
    }

    func updateUIView(_ uiView: ViewInspectorController, context: Context) {
        uiView.hostWindow = hostWindow ?? uiView.hostWindow
        uiView.onInspect = onInspect
        uiView.onCursorMoved = onCursorMoved
        uiView.onElementTap = onElementTap
        uiView.onFireOutcome = onFireOutcome
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

// MARK: - Ruler Guides

/// Two thin, phone-wide alignment guides — one horizontal line spanning the full
/// screen width and one vertical line spanning the full height — crossing at
/// `position` (the inspector cursor). No measurements: they're purely for eyeballing
/// whether elements line up. The lines freeze wherever the cursor was last left, so
/// you can sweep a guide onto one element's edge, lift, and compare other elements
/// against the frozen line. Non-interactive and drawn edge-to-edge (`.ignoresSafeArea`
/// is applied by the caller).
struct RulerGuides: View {
    let position: CGPoint
    /// Distinct from the pink crosshair/highlight so the guides read as a separate tool.
    private let color = Color.cyan

    var body: some View {
        GeometryReader { geo in
            // Vertical line — full height, at the cursor's x
            Rectangle()
                .fill(color.opacity(0.9))
                .frame(width: 1, height: geo.size.height)
                .position(x: position.x, y: geo.size.height / 2)
                .shadow(color: .black.opacity(0.5), radius: 0.5)

            // Horizontal line — full width, at the cursor's y
            Rectangle()
                .fill(color.opacity(0.9))
                .frame(width: geo.size.width, height: 1)
                .position(x: geo.size.width / 2, y: position.y)
                .shadow(color: .black.opacity(0.5), radius: 0.5)
        }
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
            if binding.options.count == 1, let only = binding.options.first {
                // A single option is an ACTION, not a choice (e.g. the host's "open a custom
                // picker" entry) — fire it directly instead of opening a one-item menu.
                Button { remap(binding, only) } label: { remapLozenge() }
            } else if !binding.options.isEmpty {
                Menu {
                    // Render sections when the provider has grouped the options (peers / roles /
                    // primitives); fall back to a flat list for ungrouped nil-section options.
                    ForEach(binding.optionGroups) { group in
                        if let title = group.title {
                            Section(title) {
                                ForEach(group.items) { option in
                                    Button { remap(binding, option) } label: {
                                        Label { Text(option.label) } icon: { Image(uiImage: Self.swatchImage(option.swatchHex)) }
                                    }
                                }
                            }
                        } else {
                            ForEach(group.items) { option in
                                Button { remap(binding, option) } label: {
                                    Label { Text(option.label) } icon: { Image(uiImage: Self.swatchImage(option.swatchHex)) }
                                }
                            }
                        }
                    }
                } label: { remapLozenge() }
            }
            // options.isEmpty = read-only row (diagnostic) — no remap control at all.
        }
    }

    /// The pink "remap" button label, shared by the direct-fire button and the options menu.
    private func remapLozenge() -> some View {
        Text("remap")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.black)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.pink.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 5))
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
            // Anchored on the resolved stamp for SwiftUI elements (declared token colours live
            // there), falling back to the inspected view for UIKit.
            InspectorTokenSection(view: info.tokenAnchorView)

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

// MARK: - Screen audit (completeness of runtime identity)

/// Walks a screen's live view tree and classifies every interactive/text control by whether it can
/// be identified at runtime — so "is this whole screen instrumented?" is a report you run, not a
/// claim. Runs after layout, so it sees EVERYTHING rendered (storyboard-only labels, programmatic
/// controls, outlet-less action buttons) that code-side enumeration structurally misses.
struct ScreenAudit {
    enum Bucket: Int { case anonymous = 0, auto = 1, named = 2 }

    struct Item: Identifiable {
        let id = UUID()
        let className: String
        let identity: String      // the resolved identity ("a11yId: …", "property: …", "text: …", "—")
        let bucket: Bucket
        weak var view: UIView?
    }

    let items: [Item]
    var named: Int { items.filter { $0.bucket == .named }.count }
    var auto: Int { items.filter { $0.bucket == .auto }.count }
    var anonymous: Int { items.filter { $0.bucket == .anonymous }.count }

    static func run(on root: UIView) -> ScreenAudit {
        var items: [Item] = []

        func hasControlAncestor(_ v: UIView) -> Bool {
            var s = v.superview
            while let cur = s { if cur is UIControl { return true }; s = cur.superview }
            return false
        }
        // A standalone, auditable element: a control, or a text/tappable view that ISN'T inside a
        // control (so a button's internal label/image counts as the button, not twice).
        func isAuditable(_ v: UIView) -> Bool {
            if v is UIControl { return true }
            if hasControlAncestor(v) { return false }
            if v is UILabel || v is UITextField || v is UITextView { return true }
            if (v.gestureRecognizers ?? []).contains(where: { $0 is UITapGestureRecognizer }) { return true }
            return false
        }
        func empty(_ s: String?) -> Bool { (s ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

        func classify(_ v: UIView) -> Item {
            let cls = String(describing: type(of: v))
            if let aid = v.accessibilityIdentifier, !empty(aid) {
                return Item(className: cls, identity: "a11yId: \(aid)", bucket: .named, view: v)
            }
            if let p = InspectedView.propertyReference(of: v) {
                return Item(className: cls, identity: "property: \(p)", bucket: .auto, view: v)
            }
            if let a = InspectedView.controlActions(of: v).first {
                return Item(className: cls, identity: "action: \(a)", bucket: .auto, view: v)
            }
            if let t = InspectedView.textContent(of: v), !empty(t) {
                return Item(className: cls, identity: "text: \"\(t)\"", bucket: .auto, view: v)
            }
            if let img = InspectedView.imageName(of: v) {
                return Item(className: cls, identity: "image: \(img)", bucket: .auto, view: v)
            }
            return Item(className: cls, identity: "—", bucket: .anonymous, view: v)
        }

        // A UIHostingController's root view → the hosted SwiftUI type name, else nil. Lets the audit
        // count a whole SwiftUI field (WacFieldGlassButton, …) as ONE unit instead of skipping it:
        // SwiftUI renders as internal _UIInheritedViews that match no UIKit control class.
        func hostingRootType(of v: UIView) -> String? {
            guard let vc = v.next as? UIViewController else { return nil }
            let cls = String(describing: type(of: vc))
            guard cls.contains("UIHostingController"), vc.viewIfLoaded === v else { return nil }
            if let lt = cls.firstIndex(of: "<"), let gt = cls.lastIndex(of: ">"), lt < gt {
                return String(cls[cls.index(after: lt)..<gt])
            }
            return "SwiftUI"
        }
        // Any identifier stamped inside a host subtree → the hosted field is explicitly NAMED. Covers
        // both `.uiKitIdentifier` (a stamper view's accessibilityIdentifier) and standard SwiftUI
        // `.accessibilityIdentifier` (stored on the row's accessibility element, via accessibilityIdInTree).
        func stampedIdentifier(in v: UIView) -> String? {
            if let id = v.accessibilityIdentifier, !empty(id) { return id }
            return InspectedView.accessibilityIdInTree(v)
        }

        func walk(_ v: UIView) {
            let visible = !v.isHidden && v.alpha > 0.01
            if visible {
                if v.tag == ripulViewExplorerOverlayTag { return }   // skip our own overlay subtree
                // SwiftUI hosting boundary: don't descend into SwiftUI internals.
                if let hostType = hostingRootType(of: v) {
                    let cls = "UIHostingController<\(hostType)>"
                    // A List/Form exposes one combined accessibility element PER ROW — audit each so a
                    // partially-instrumented List shows its gaps, rather than collapsing to one unit
                    // (which would read green off the first row's id and hide the rest).
                    let rowIds = InspectedView.accessibilityElementIdentifiers(in: v)
                    if rowIds.count > 1 {
                        for (i, id) in rowIds.enumerated() {
                            if let id = id {
                                items.append(Item(className: "\(hostType) ▸ element", identity: "a11yId: \(id)", bucket: .named, view: v))
                            } else {
                                items.append(Item(className: "\(hostType) ▸ element[\(i)]", identity: "—", bucket: .anonymous, view: v))
                            }
                        }
                    } else if let id = rowIds.compactMap({ $0 }).first ?? stampedIdentifier(in: v) {
                        items.append(Item(className: cls, identity: "a11yId: \(id)", bucket: .named, view: v))
                    } else {
                        items.append(Item(className: cls, identity: "SwiftUI: \(hostType)", bucket: .auto, view: v))
                    }
                    return
                }
                if isAuditable(v) { items.append(classify(v)) }
                for sub in v.subviews { walk(sub) }
            }
        }
        walk(root)
        // Anonymous first (the only bucket that needs hand-tagging), then auto, then named.
        return ScreenAudit(items: items.sorted { $0.bucket.rawValue < $1.bucket.rawValue })
    }

    /// A copy-paste summary for the whole screen.
    func report() -> String {
        var lines = ["Screen audit — \(items.count) controls  ·  named \(named)  ·  auto \(auto)  ·  anonymous \(anonymous)", ""]
        for it in items { lines.append("\(bucketMark(it.bucket)) \(it.className) — \(it.identity)") }
        return lines.joined(separator: "\n")
    }
    private func bucketMark(_ b: Bucket) -> String { b == .named ? "✓" : (b == .auto ? "·" : "✗") }
}

// MARK: - Audit tab

/// The screen-completeness report inside the explorer: counts by bucket + the full control list,
/// anonymous first. Tap a row to jump-inspect it; copy the whole report.
@available(iOS 16.0, *)
struct InspectorAuditTab: View {
    let anchorView: UIView?
    let onSelect: (UIView) -> Void
    @State private var audit: ScreenAudit?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let audit = audit {
                HStack(spacing: 10) {
                    countPill("named", audit.named, .green)
                    countPill("auto", audit.auto, .cyan)
                    countPill("anon", audit.anonymous, audit.anonymous == 0 ? .gray : .red)
                    Spacer()
                    Button { rescan() } label: { badge("rescan", .white.opacity(0.15)) }.buttonStyle(.plain)
                    Button { UIPasteboard.general.string = audit.report(); copied = true } label: {
                        badge(copied ? "copied" : "copy", .pink.opacity(0.85))
                    }.buttonStyle(.plain)
                }
                Text(audit.anonymous == 0
                     ? "Every control is identifiable."
                     : "\(audit.anonymous) control(s) have no runtime identity — hand-tag these.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(audit.anonymous == 0 ? .green : .red)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(audit.items) { item in row(item) }
                    }
                }
            } else {
                Text("Auditing…").font(.system(size: 11, design: .monospaced)).foregroundStyle(.gray)
            }
        }
        .onAppear { if audit == nil { rescan() } }
    }

    private func row(_ item: ScreenAudit.Item) -> some View {
        Button {
            if let v = item.view { onSelect(v) }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color(item.bucket)).frame(width: 6, height: 6)
                Text(item.className).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                Text(item.identity).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.gray).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func color(_ b: ScreenAudit.Bucket) -> Color {
        b == .named ? .green : (b == .auto ? .cyan : .red)
    }
    private func countPill(_ label: String, _ n: Int, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(c)
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.gray)
        }
    }
    private func badge(_ t: String, _ bg: Color) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3).background(bg).clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func rescan() {
        copied = false
        guard let root = screenRoot() else { audit = ScreenAudit(items: []); return }
        audit = ScreenAudit.run(on: root)
    }

    /// The screen to audit: the top-most view controller's view in the anchor's window (or the
    /// app's window) — the whole visible screen, independent of what's currently selected.
    /// Never the explorer's own chrome window, which is what `isKeyWindow` could hand back.
    private func screenRoot() -> UIView? {
        let window = anchorView?.window ?? RipulChrome.appWindow()
        guard var vc = window?.rootViewController else { return window }
        while let presented = vc.presentedViewController, !presented.isBeingDismissed { vc = presented }
        return vc.view
    }
}

// MARK: - Settings tab

@available(iOS 16.0, *)
struct InspectorSettingsTab: View {
    /// Whether the crosshair reticule is hidden when the HUD is folded.
    /// Off by default so the reticule remains visible while folded.
    @AppStorage("viewInspector.hideReticuleWhenFolded") private var hideReticuleWhenFolded = false
    /// Single tap fires the highlighted element (through the shared
    /// actuation engine). On by default — dragging still inspects; a tap
    /// presses.
    @AppStorage("viewInspector.singleTapFires") private var singleTapFires = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Explorer settings")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.pink).textCase(.uppercase).tracking(0.5)

            Toggle(isOn: $hideReticuleWhenFolded) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide reticule when folded")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("Hide the crosshair when the panel is folded so it doesn't overlay the app.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.gray)
                }
            }
            .tint(.pink)

            Toggle(isOn: $singleTapFires) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Single tap fires the element")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("Tap once to press what's highlighted; double-tap still records/confirms.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.gray)
                }
            }
            .tint(.pink)

            Spacer()
        }
    }
}

// MARK: - Macro tab (docs/plans/automation-macros/phase-2-recording-ui.md)

/// The Macro tab: start recording, watch the step list build live (each step
/// already live-executed by the time it appears — see `MacroRecorder`), delete
/// a bad step, Stop & Save. Screen-wide like Audit — doesn't depend on a
/// current selection, since the steps come from double-taps while recording,
/// not from `inspected`.
@available(iOS 16.0, *)
struct InspectorMacroTab: View {
    @Binding var isRecording: Bool
    /// Auto-pause between recorded steps (0 = off), persisted per device by
    /// the overlay's AppStorage.
    @Binding var autoPauseSeconds: Double
    let steps: [MacroStep]
    let onDelete: (IndexSet) -> Void
    let onStopAndSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Macro")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.pink).textCase(.uppercase).tracking(0.5)

            // Auto-pause: every recorded action after the first is preceded
            // by a fixed Pause step (see MacroRecordingAssembly for the rules).
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { autoPauseSeconds > 0 },
                    set: { autoPauseSeconds = $0 ? max(autoPauseSeconds, 1.0) : 0 }
                )) {
                    Text("Pause between steps")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .tint(.pink)
                if autoPauseSeconds > 0 {
                    TextField("1.0", value: $autoPauseSeconds, format: .number)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 44)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.gray)
                }
            }
            .uiKitIdentifier("InspectorMacroTab.autoPause")

            if isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("Recording — tap once to fire it; double-tap to record a step")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                }

                if steps.isEmpty {
                    Text("No steps yet.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.gray)
                        .italic()
                } else {
                    stepList
                }

                Button {
                    onStopAndSave()
                } label: {
                    Text(steps.isEmpty ? "Stop (nothing to save)" : "Stop & Save (\(steps.count) step\(steps.count == 1 ? "" : "s"))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(steps.isEmpty ? Color.gray.opacity(0.3) : Color.red.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(steps.isEmpty)
                .uiKitIdentifier("InspectorMacroTab.stopAndSaveButton")
            } else {
                Text("Record a sequence of taps/types/scrolls as a named macro the "
                    + "agent can later call as a single tool. Each step is live-executed "
                    + "as you record it — what works now is what replays later.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.gray)

                Button {
                    isRecording = true
                } label: {
                    Text("● Start Recording")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.pink.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .uiKitIdentifier("InspectorMacroTab.startRecordingButton")
            }

            Spacer()
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.gray)
                        .frame(width: 18, alignment: .trailing)
                    Text(step.recordedLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        onDelete(IndexSet(integer: index))
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                    .uiKitIdentifier("InspectorMacroTab.deleteStep.\(index)")
                }
                .padding(.vertical, 2)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The Stop & Save sheet: name, description, and parameters auto-detected from
/// `{{name}}` tokens already typed into any `.type` step while recording — no
/// separate "add a parameter" UI needed for the common case.
@available(iOS 16.0, *)
struct MacroSaveSheet: View {
    let steps: [MacroStep]
    let onSave: (RipulMacro) -> Void
    let onDiscard: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var parameterDescriptions: [String: String] = [:]

    private var detectedParameterNames: [String] {
        MacroParameterSubstitution.detectParameters(in: steps)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !description.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("clock_in", text: $name)
                        .autocorrectionDisabled()
                        .uiKitIdentifier("MacroSaveSheet.nameField")
                }
                Section("Description (what the agent reads to decide when to use this)") {
                    TextField("Clocks in for the current shift.", text: $description, axis: .vertical)
                        .uiKitIdentifier("MacroSaveSheet.descriptionField")
                }
                if !detectedParameterNames.isEmpty {
                    Section("Parameters") {
                        ForEach(detectedParameterNames, id: \.self) { paramName in
                            TextField("What is {{\(paramName)}}?",
                                     text: Binding(get: { parameterDescriptions[paramName] ?? "" },
                                                   set: { parameterDescriptions[paramName] = $0 }))
                        }
                    }
                }
                Section("Steps (\(steps.count))") {
                    ForEach(steps) { step in
                        Text(step.recordedLabel)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Save Macro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { onDiscard(); dismiss() }
                        .uiKitIdentifier("MacroSaveSheet.discardButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                        .uiKitIdentifier("MacroSaveSheet.saveButton")
                }
            }
        }
    }

    private func save() {
        let parameters = detectedParameterNames.map {
            MacroParameter(name: $0, description: parameterDescriptions[$0] ?? "")
        }
        let now = Date()
        let macro = RipulMacro(id: "macro_\(UUID().uuidString)", name: MacroSlug.slug(from: name), description: description,
                               steps: steps, parameters: parameters, published: false,
                               createdAt: now, updatedAt: now)
        onSave(macro)
        dismiss()
    }
}

// MARK: - HUD Panel

@available(iOS 16.0, *)
struct InspectorHUD: View {
    let inspected: InspectedView?
    let history: [UIView]
    @Binding var folded: Bool
    @Binding var showRulers: Bool
    let consoleAction: (() -> Void)?
    let onUp: () -> Void
    let onBack: () -> Void
    let onExit: () -> Void
    let onSelectView: (UIView) -> Void
    /// Panel size, owned by `RipulFloatingPanel` (which also owns the resize grip
    /// and its gesture). Width is applied directly; height bounds the scroll area,
    /// so a folded HUD hugs its header instead of stretching to the stored height.
    let size: CGSize
    /// Macro recording (docs/plans/automation-macros/phase-2-recording-ui.md) —
    /// additive to the existing params above.
    @Binding var isRecording: Bool
    /// Auto-pause between recorded steps (0 = off), persisted by the overlay.
    @Binding var autoPauseSeconds: Double
    let recordedSteps: [MacroStep]
    let onDeleteStep: (IndexSet) -> Void
    let onStopAndSave: () -> Void
    /// The tab shown on first render — `.macro` when launched straight into
    /// record mode from the library's "Record new" entry point.
    let initialTab: InspectorTab

    @State private var tab: InspectorTab

    init(inspected: InspectedView?, history: [UIView], folded: Binding<Bool>, showRulers: Binding<Bool>,
         consoleAction: (() -> Void)?, onUp: @escaping () -> Void, onBack: @escaping () -> Void,
         onExit: @escaping () -> Void, onSelectView: @escaping (UIView) -> Void, size: CGSize,
         isRecording: Binding<Bool>, autoPauseSeconds: Binding<Double>, recordedSteps: [MacroStep],
         onDeleteStep: @escaping (IndexSet) -> Void, onStopAndSave: @escaping () -> Void,
         initialTab: InspectorTab = .edit) {
        self.inspected = inspected
        self.history = history
        self._folded = folded
        self._showRulers = showRulers
        self.consoleAction = consoleAction
        self.onUp = onUp
        self.onBack = onBack
        self.onExit = onExit
        self.onSelectView = onSelectView
        self.size = size
        self._isRecording = isRecording
        self._autoPauseSeconds = autoPauseSeconds
        self.recordedSteps = recordedSteps
        self.onDeleteStep = onDeleteStep
        self.onStopAndSave = onStopAndSave
        self.initialTab = initialTab
        self._tab = State(initialValue: initialTab)
    }

    /// Declaration order is tab order.
    enum InspectorTab: String, CaseIterable {
        case edit = "Edit"
        case properties = "Properties"
        case tree = "Tree"
        case audit = "Audit"
        case macro = "Macro"
        case settings = "Settings"

        /// SF Symbol for tabs shown as an icon; nil renders the text label.
        var symbol: String? {
            switch self {
            case .properties: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            case .macro: return "record.circle"
            case .edit, .tree, .audit: return nil
            }
        }
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
                    // Icon stands in for the "View Inspector" wordmark — the header
                    // row is narrow and every point of it is wanted by the buttons.
                    Image(systemName: "scope")
                        .font(.system(size: 12, weight: .bold))
                        .accessibilityLabel("View Inspector")
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

            if let consoleAction {
                hudIconButton("terminal", label: "Console", tone: .cyan, action: consoleAction)
                    .uiKitIdentifier("InspectorHUD.consoleButton")
            }
            hudIconButton("record.circle", label: isRecording ? "Stop Recording" : "Record Macro",
                          tone: .red, active: isRecording) {
                if isRecording { onStopAndSave() } else { isRecording = true; tab = .macro }
            }
            .uiKitIdentifier("InspectorHUD.recordButton")
            hudIconButton("ruler", label: "Ruler", tone: .cyan, active: showRulers) { showRulers.toggle() }
                .uiKitIdentifier("InspectorHUD.rulersButton")
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
                    Group {
                        if let symbol = t.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: tab == t ? .bold : .medium))
                                .accessibilityLabel(t.rawValue)
                        } else {
                            Text(t.rawValue)
                                .font(.system(size: 11, weight: tab == t ? .bold : .medium, design: .monospaced))
                        }
                    }
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

    @ViewBuilder private var bodyContent: some View {
        if tab == .audit {
            // Screen-wide — works with or without a current selection.
            InspectorAuditTab(anchorView: inspected?.view, onSelect: onSelectView)
        } else if tab == .settings {
            InspectorSettingsTab()
        } else if tab == .macro {
            // Screen-wide too — recording doesn't depend on a current selection.
            InspectorMacroTab(isRecording: $isRecording, autoPauseSeconds: $autoPauseSeconds,
                              steps: recordedSteps,
                              onDelete: onDeleteStep, onStopAndSave: onStopAndSave)
        } else if let info = inspected {
            switch tab {
            case .properties:
                InspectorPropertiesTab(info: info)
            case .edit:
                InspectorEditTab(info: info)
                    .id(ObjectIdentifier(info.view))   // reset editor state per selection
            case .tree:
                InspectorTreeTab(selectedView: info.view, onSelect: onSelectView)
            case .audit, .settings, .macro:
                EmptyView()   // handled above
            }
        } else {
            Text("Drag your finger to inspect views — or open the Audit tab")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.gray)
                .italic()
        }
    }

    private func hudButton(_ label: String, disabled: Bool = false, tone: Color = .white, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .modifier(HudButtonChrome(disabled: disabled, tone: tone, active: active))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// Icon-only variant of `hudButton`, same chrome. `label` is the accessibility
    /// name — it's also what the View Explorer reports when inspecting itself.
    private func hudIconButton(_ systemName: String, label: String, disabled: Bool = false, tone: Color = .white, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 14)   // fixed so icon buttons stay optically even
                .accessibilityLabel(label)
                .modifier(HudButtonChrome(disabled: disabled, tone: tone, active: active))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Shared chrome for the HUD header buttons — the only difference between the text
/// and icon variants is what sits inside it.
@available(iOS 16.0, *)
private struct HudButtonChrome: ViewModifier {
    /// Fixed content box, so every toolbar button is the same height regardless of
    /// what it holds. Left to intrinsic sizing, an SF Symbol and a line of
    /// monospaced text report different heights and the row comes out ragged.
    static let contentHeight: CGFloat = 15

    let disabled: Bool
    let tone: Color
    let active: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(disabled ? .gray.opacity(0.4) : (active ? .black : tone))
            .frame(height: Self.contentHeight)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                active
                    ? tone.opacity(0.9)
                    : (tone == .red ? Color.red.opacity(0.25) : Color.white.opacity(0.12))
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        active
                            ? tone
                            : (tone == .red ? Color.red.opacity(0.4) : Color.white.opacity(0.2)),
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - Main Overlay View

@available(iOS 16.0, *)
public struct ViewInspectorOverlay: View {
    @Binding var isActive: Bool
    let elementTapAction: ((RipulElementTap) -> Void)?
    let consoleAction: (() -> Void)?
    let macroRecordedAction: ((RipulMacro) -> Void)?
    /// Launched straight into record mode ( the library's "Record new" entry
    /// point) — the Macro tab is armed from the start.
    let startRecording: Bool
    /// The HOST window to hit-test when picking — set when the explorer runs
    /// in its own overlay window (`RipulViewExplorer.present`); nil when the
    /// overlay is embedded in the host's own view hierarchy (pick against
    /// the enclosing window instead).
    let hostWindow: UIWindow?
    @State private var inspected: InspectedView?
    @State private var cursorPosition: CGPoint = CGPoint(
        x: UIScreen.main.bounds.width / 2,
        y: UIScreen.main.bounds.height / 2
    )
    @State private var history: [UIView] = []
    @State private var currentView: UIView?
    /// When folded, the HUD header stays visible but touch capture is removed so
    /// normal app interaction resumes. The crosshair reticule can optionally stay
    /// visible via the settings panel.
    @AppStorage("viewInspector.folded") private var folded = false
    /// Whether to hide the crosshair reticule when the HUD is folded.
    /// Off by default so the reticule remains visible when folded.
    @AppStorage("viewInspector.hideReticuleWhenFolded") private var hideReticuleWhenFolded = false
    /// Phone-wide alignment rulers — two thin lines crossing at the cursor,
    /// extending to the screen edges. Persists across sessions like `folded`.
    @AppStorage("viewInspector.rulers") private var showRulers = false

    // MARK: Macro recording state (docs/plans/automation-macros/phase-2-recording-ui.md)
    //
    // Additive to the existing state above — recording never moves ownership
    // of `inspected`/`history`/`currentView`; it only reacts to the same
    // double-tap confirm the Edit-tab flow already uses.
    @State private var isRecording = false
    @State private var recordedSteps: [MacroStep] = []
    /// The just-confirmed double-tap while recording — drives the action
    /// chooser. Cleared once an action is picked (or the dialog is dismissed).
    @State private var pendingRecordTap: RipulElementTap?
    @State private var showTypeTextAlert = false
    /// Value-entry prompt for a `.setValue` step — same deferred-alert shape as
    /// the type prompt: the chooser must dismiss before an alert can present.
    @State private var showSetValueAlert = false
    @State private var typeTextInput = ""
    /// The view a Type step targets — held separately from `pendingRecordTap`
    /// because the text-entry alert presents AFTER the chooser dialog
    /// dismisses (SwiftUI can't stack two presentations on one state change).
    @State private var typeTextTarget: UIView?
    @State private var recordingError: String?
    @State private var showSaveSheet = false
    /// Transient outcome of a single-tap fire ("via uicontrol", "not
    /// tappable") shown as a pill — auto-hides shortly after.
    @State private var fireOutcome: String?
    /// Auto-pause between recorded steps: 0 = off; otherwise each recorded
    /// action after the first is preceded by a fixed `Pause Ns` step.
    /// Persisted per device so the setting survives sessions.
    @AppStorage("viewInspector.macroAutoPauseSeconds") private var autoPauseSeconds: Double = 0

    public init(isActive: Binding<Bool>, elementTapAction: ((RipulElementTap) -> Void)? = nil,
               consoleAction: (() -> Void)? = nil, macroRecordedAction: ((RipulMacro) -> Void)? = nil,
               startRecording: Bool = false, hostWindow: UIWindow? = nil) {
        self._isActive = isActive
        self.elementTapAction = elementTapAction
        self.consoleAction = consoleAction
        self.macroRecordedAction = macroRecordedAction
        self.startRecording = startRecording
        self.hostWindow = hostWindow
        self._isRecording = State(initialValue: startRecording)
    }

    public var body: some View {
        if isActive {
            ZStack {
                // Touch capture layer — mounted whenever the explorer is active.
                // Folding only collapses the HUD; the reticule stays movable/inspectable.
                ViewInspectorTouchLayer(
                    hostWindow: hostWindow,
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
                    },
                    onElementTap: { tap in
                        if isRecording {
                            pendingRecordTap = tap
                        } else {
                            elementTapAction?(tap)
                        }
                    },
                    onFireOutcome: { outcome in
                        fireOutcome = outcome
                        Task {
                            // A successful fire is a glance; a FAILURE carries
                            // the whole trace and is the thing worth reading and
                            // copying, so it stays up long enough to tap.
                            let visible: UInt64 = outcome.hasPrefix("via ") ? 1_500_000_000 : 8_000_000_000
                            try? await Task.sleep(nanoseconds: visible)
                            if fireOutcome == outcome { fireOutcome = nil }
                        }
                    }
                )
                .ignoresSafeArea()

                // Fire-outcome pill — a dead tap reports itself ("not
                // tappable") instead of silently doing nothing.
                if let fireOutcome {
                    // Tap to copy: the pill is the ONLY place a fire's trace
                    // appears, and a trace is too long to retype off a phone.
                    Text(fireOutcome + (fireOutcome.hasPrefix("via ") ? "" : "  ⧉ tap to copy"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 60)
                        .padding(.horizontal, 16)
                        .allowsHitTesting(!fireOutcome.hasPrefix("via "))
                        .onTapGesture {
                            UIPasteboard.general.string = fireOutcome
                            self.fireOutcome = "copied"
                        }
                        .transition(.opacity)
                        .uiKitIdentifier("ViewInspectorOverlay.fireOutcomePill")
                }

                // Crosshair — shown when unfolded; when folded it stays visible
                // unless the user enables "Hide reticule when folded" in Settings.
                if !folded || !hideReticuleWhenFolded {
                    CrosshairReticle(position: cursorPosition)
                        .ignoresSafeArea()
                }

                // Phone-wide alignment rulers — shown in both folded and unfolded
                // states so you can freeze a guide on an element's edge, fold to
                // interact with the app, and still compare against the frozen line.
                if showRulers {
                    RulerGuides(position: cursorPosition)
                        .ignoresSafeArea()
                }

                // HUD — always visible. RipulFloatingPanel owns move, resize, safe-area
                // clamping and the position/size persistence (keys "viewInspector.posX",
                // ".posY", ".w", ".h"); the grip is hidden while folded.
                RipulFloatingPanel(
                    storageKey: "viewInspector",
                    defaultSize: CGSize(width: min(360, UIScreen.main.bounds.width - 16),
                                        height: UIScreen.main.bounds.height * 0.3),
                    minSize: CGSize(width: 220, height: 180),
                    showsResizeGrip: !folded
                ) { size in
                    // Broken out of the call below: the 16-argument HUD
                    // construction plus the enum ternary tipped the type
                    // checker past its limit once.
                    let hudInitialTab: InspectorHUD.InspectorTab = startRecording ? .macro : .edit
                    InspectorHUD(
                        inspected: inspected,
                        history: history,
                        folded: $folded,
                        showRulers: $showRulers,
                        consoleAction: consoleAction,
                        onUp: navigateUp,
                        onBack: navigateBack,
                        onExit: { isActive = false },
                        onSelectView: selectView,
                        size: size,
                        isRecording: $isRecording,
                        autoPauseSeconds: $autoPauseSeconds,
                        recordedSteps: recordedSteps,
                        onDeleteStep: { offsets in recordedSteps.remove(atOffsets: offsets) },
                        onStopAndSave: { isRecording = false; showSaveSheet = true },
                        initialTab: hudInitialTab
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
            }
            .transition(.opacity)
            .modifier(RecordingPresentationModifier(
                pendingRecordTap: $pendingRecordTap,
                showTypeTextAlert: $showTypeTextAlert,
                showSetValueAlert: $showSetValueAlert,
                onCommitSetValueStep: commitSetValueStep,
                typeTextInput: $typeTextInput,
                recordingError: $recordingError,
                showSaveSheet: $showSaveSheet,
                recordedSteps: recordedSteps,
                onChooseAction: chooseRecordingAction,
                onCommitTypeStep: commitTypeStep,
                onSaveMacro: { macro in macroRecordedAction?(macro); recordedSteps = [] },
                onDiscardRecording: { recordedSteps = [] }
            ))
        }
    }

    /// The macro-recording presentation stack (action chooser dialog, type
    /// alert, error alert, save sheet), lifted out of `body` — the overlay's
    /// body expression grew past the type checker's budget once recording
    /// joined it, and this split is what keeps `body` checkable.
    private struct RecordingPresentationModifier: ViewModifier {
        @Binding var pendingRecordTap: RipulElementTap?
        @Binding var showTypeTextAlert: Bool
        @Binding var showSetValueAlert: Bool
        let onCommitSetValueStep: () -> Void
        @Binding var typeTextInput: String
        @Binding var recordingError: String?
        @Binding var showSaveSheet: Bool
        let recordedSteps: [MacroStep]
        let onChooseAction: (MacroRecordingAction, RipulElementTap) -> Void
        let onCommitTypeStep: () -> Void
        let onSaveMacro: (RipulMacro) -> Void
        let onDiscardRecording: () -> Void

        func body(content: Content) -> some View {
            content
                .confirmationDialog(
                    pendingRecordTap.map { "Record a step for \(MacroRecorder.describeTarget($0.view))" } ?? "",
                    isPresented: Binding(get: { pendingRecordTap != nil }, set: { if !$0 { pendingRecordTap = nil } }),
                    titleVisibility: .visible
                ) {
                    if let tap = pendingRecordTap {
                        // Only offer actions this element can actually take.
                        // Listing "Set value" on something with no value-bearing
                        // control just produces a refusal the user has to read.
                        ForEach(MacroRecordingAction.allCases.filter {
                            $0 != .setValue
                                || ScreenActuationEngine.hasValueControl(at: tap.actionableView ?? tap.targetView)
                        }, id: \.self) { action in
                            Button(action.rawValue) { onChooseAction(action, tap) }
                        }
                    }
                    Button("Cancel", role: .cancel) { pendingRecordTap = nil }
                }
                .alert("Text to type", isPresented: $showTypeTextAlert) {
                    TextField("Use {{name}} for a value the agent fills in", text: $typeTextInput)
                    Button("Record") { onCommitTypeStep() }
                    Button("Cancel", role: .cancel) { pendingRecordTap = nil; typeTextInput = "" }
                } message: {
                    Text("This is typed into the field now, and replayed exactly the same way later.")
                }
                .alert("Value to set", isPresented: $showSetValueAlert) {
                    TextField("09:00 · 2026-08-02 09:00 · on · {{name}}", text: $typeTextInput)
                    Button("Record") { onCommitSetValueStep() }
                    Button("Cancel", role: .cancel) { pendingRecordTap = nil; typeTextInput = "" }
                } message: {
                    Text("Set on the control now, and replayed the same way later. "
                        + "Dates accept ISO8601, \"yyyy-MM-dd HH:mm\" or a bare \"HH:mm\".")
                }
                .alert("Couldn't record that step", isPresented: Binding(get: { recordingError != nil }, set: { if !$0 { recordingError = nil } })) {
                    // The message carries the actuation trace, which is the
                    // whole diagnosis and far too long to retype off a phone
                    // screen — every hand-copied report so far arrived with
                    // characters mangled.
                    Button("Copy") {
                        UIPasteboard.general.string = recordingError ?? ""
                        recordingError = nil
                    }
                    Button("OK", role: .cancel) { recordingError = nil }
                } message: {
                    Text(recordingError ?? "")
                }
                .sheet(isPresented: $showSaveSheet) {
                    MacroSaveSheet(steps: recordedSteps, onSave: onSaveMacro, onDiscard: onDiscardRecording)
                }
        }
    }

    /// Live-executes the chosen action (the dogfooding step — the developer's
    /// app actually responds) and appends the resulting step, or surfaces why
    /// it couldn't be recorded instead of silently dropping it.
    private func chooseRecordingAction(_ action: MacroRecordingAction, for tap: RipulElementTap) {
        pendingRecordTap = nil
        if action == .setValue {
            // Same deferral as `.type`: the value alert can only present after
            // the chooser dialog has dismissed, and the target has to survive
            // until then.
            typeTextTarget = tap.actionableView ?? tap.targetView
            typeTextInput = ""
            showSetValueAlert = true
            return
        }
        if action == .type {
            // Deferred: the alert needs to be presented AFTER this dialog
            // dismisses, and it needs the target view kept around.
            // The ACTIONABLE view, for the same reason the tap path uses it:
            // `tap.view` is the token anchor — a 0.01-alpha stamp with no text
            // input anywhere beneath it, which is exactly the "no text input at
            // or below it" refusal. Fixing the tap consumers and leaving this
            // one behind is how the same bug came back wearing a different hat.
            typeTextTarget = tap.actionableView ?? tap.targetView
            typeTextInput = ""
            showTypeTextAlert = true
            return
        }
        // `tap.point` is the whole reason this presses the right thing: see
        // MacroRecorder.record. Recording without it pressed the centre of the
        // island instead of the row under the finger.
        // `targetView`, not `view`: the payload's `view` is deliberately the
        // token anchor so a host's theme action reads the same element the Edit
        // tab does — that contract stays. Recording wants the element that was
        // SELECTED and can actually be pressed, which is `targetView`.
        guard let result = MacroRecorder.record(action, on: tap.actionableView ?? tap.targetView,
                                                at: tap.point) else {
            recordingError = "\(action.rawValue) isn't available for \(MacroRecorder.describeTarget(tap.targetView))."
            return
        }
        if let error = result.error {
            recordingError = error
        } else {
            recordedSteps = MacroRecordingAssembly.appending(result.step, to: recordedSteps,
                                                             autoPauseSeconds: autoPauseSeconds)
        }
    }

    private func commitSetValueStep() {
        guard let view = typeTextTarget else { return }
        defer { typeTextTarget = nil; typeTextInput = "" }
        guard let result = MacroRecorder.record(.setValue, on: view, typedText: typeTextInput) else { return }
        if let error = result.error {
            recordingError = error
        } else {
            recordedSteps = MacroRecordingAssembly.appending(result.step, to: recordedSteps,
                                                             autoPauseSeconds: autoPauseSeconds)
        }
    }

    private func commitTypeStep() {
        guard let view = typeTextTarget else { return }
        defer { typeTextTarget = nil; typeTextInput = "" }
        guard let result = MacroRecorder.record(.type, on: view, typedText: typeTextInput) else { return }
        if let error = result.error {
            recordingError = error
        } else {
            recordedSteps = MacroRecordingAssembly.appending(result.step, to: recordedSteps,
                                                             autoPauseSeconds: autoPauseSeconds)
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
