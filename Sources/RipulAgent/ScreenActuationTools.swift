import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Built-in `NativeTool`s that let the dev-console agent ACT on the host app's
/// screen, closing the loop `inspect_screen` opened: tap buttons, type into
/// fields, scroll containers — addressed by the same accessibility id /
/// uiKitIdentifier / visible text the inspector returns.
///
/// Registration: `RipulAgentConsole`'s built-ins, so any host embedding the
/// console gets them. They exclude the dev-assistant overlay window exactly
/// like `InspectScreenTool` (the agent drives the HOST app, never itself).
///
/// Actuation order for taps (all public API first):
/// 1. `UIControl.sendActions(for: .touchUpInside)` — UIKit buttons/controls.
/// 2. `accessibilityActivate()` up the superview chain — the sanctioned
///    "perform the default action" hook (VoiceOver's mechanism).
/// 3. Fire an attached `UITapGestureRecognizer`'s targets via KVC on the
///    private `_targets` array — the only route that reaches SwiftUI Buttons
///    (they attach tap gestures to hosting views). DEV-ONLY: a private
///    property name as a string, used purely as a dev affordance.
#if canImport(UIKit)

// MARK: - Element lookup (shared walker)

@MainActor
private enum ScreenElementFinder {
    struct Match {
        let view: UIView
        let window: UIWindow
        let id: String?
        let text: String?
    }

    static func hostWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { $0.accessibilityIdentifier != RipulInspection.excludedOverlayWindowIdentifier && !$0.isHidden }
        return windows.first { $0.isKeyWindow }
            ?? windows.filter { $0.windowLevel == .normal }.last
            ?? windows.last
    }

    /// Find elements by accessibility id (exact, then case-insensitive) or
    /// visible text (case-insensitive substring). Returns in walk (z) order.
    static func find(id: String?, text: String?) -> [Match] {
        guard let window = hostWindow() else { return [] }
        let root: UIView = window.rootViewController?.view ?? window
        var matches: [Match] = []
        walk(root) { view in
            var vid = view.accessibilityIdentifier
            if vid?.isEmpty ?? true { vid = UIKitIdentifierRegistry.shared.identifier(for: view) }
            if vid?.isEmpty ?? true { vid = InspectedView.accessibilityIdInTree(view) }
            let vtext = InspectedView.textContent(of: view)
            if let id, !id.isEmpty, let vid, !vid.isEmpty {
                if vid == id || vid.caseInsensitiveCompare(id) == .orderedSame {
                    matches.append(Match(view: view, window: window, id: vid, text: vtext))
                }
            } else if let text, !text.isEmpty, let vtext, !vtext.isEmpty,
                      vtext.range(of: text, options: .caseInsensitive) != nil {
                matches.append(Match(view: view, window: window, id: vid, text: vtext))
            }
        }
        return matches
    }

    private static func walk(_ view: UIView, _ visit: (UIView) -> Void) {
        if view.isHidden || view.alpha < 0.01 { return }
        if let window = view as? UIWindow,
           window.accessibilityIdentifier == RipulInspection.excludedOverlayWindowIdentifier { return }
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    static func describe(_ m: Match) -> [String: Any] {
        var d: [String: Any] = ["class": String(describing: type(of: m.view))]
        if let id = m.id { d["id"] = id }
        if let text = m.text { d["text"] = text }
        let f = m.view.convert(m.view.bounds, to: m.window)
        d["frame"] = ["x": Double(f.minX), "y": Double(f.minY), "w": Double(f.width), "h": Double(f.height)]
        return d
    }
}

// MARK: - tap_element

public struct TapElementTool: NativeTool {
    public let name = "tap_element"
    public let description = "Tap an on-screen element (button, row, tab) in the host app, addressed by its "
        + "accessibility id (from inspect_screen) or visible text. Use this to DRIVE the app: navigate, "
        + "press buttons, toggle switches. Returns which actuation path fired. If several elements match "
        + "the text, the first (top-most in tree order) is tapped — refine with id when in doubt."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("id", "Accessibility id / uiKitIdentifier of the element (preferred, exact)"),
        .string("text", "Visible text to match instead (case-insensitive substring)")
    )

    public init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let id = args["id"] as? String
        let text = args["text"] as? String
        guard (id?.isEmpty == false) || (text?.isEmpty == false) else {
            return ["success": false, "error": "Provide id or text. Run inspect_screen to find elements."]
        }
        let matches = ScreenElementFinder.find(id: id, text: text)
        guard let target = matches.first else {
            return ["success": false, "error": "No element found for \(id.map { "id '\($0)'" } ?? "text '\(text ?? "")'"). Run inspect_screen and pick a live element."]
        }

        // 1. UIKit control — the clean path.
        if let control = target.view as? UIControl {
            control.sendActions(for: .touchUpInside)
            return ["success": true, "via": "uicontrol", "matched": matches.count, "element": ScreenElementFinder.describe(target)]
        }

        // 2. accessibilityActivate up the chain (VoiceOver's sanctioned hook).
        var v: UIView? = target.view
        while let cur = v {
            if cur.responds(to: #selector(UIResponder.accessibilityActivate)), cur.accessibilityActivate() {
                return ["success": true, "via": "accessibilityActivate", "matched": matches.count, "element": ScreenElementFinder.describe(target)]
            }
            v = cur.superview
        }

        // 3. Fire an attached UITapGestureRecognizer's targets (reaches SwiftUI
        //    Buttons, which attach tap gestures to hosting views). DEV-ONLY:
        //    KVC on the private `_targets` property, as a dev affordance.
        var g: UIView? = target.view
        while let cur = g {
            for gr in cur.gestureRecognizers ?? [] where gr.isEnabled {
                guard let tap = gr as? UITapGestureRecognizer else { continue }
                if Self.fireTapTargets(of: tap) {
                    return ["success": true, "via": "tapGesture", "matched": matches.count, "element": ScreenElementFinder.describe(target)]
                }
            }
            g = cur.superview
        }

        return ["success": false, "matched": matches.count, "element": ScreenElementFinder.describe(target),
                "error": "Element found but not tappable by any path (not a control, no accessibilityActivate, no tap gesture)."]
    }

    /// Invoke a tap gesture recognizer's registered target/action pairs with the
    /// recognizer as the argument — indistinguishable from a real finger tap to
    /// the receiving code. Returns false if the private introspection fails.
    private static func fireTapTargets(of gesture: UITapGestureRecognizer) -> Bool {
        guard let records = gesture.value(forKey: "_targets") as? [NSObject], !records.isEmpty else { return false }
        var fired = false
        for record in records {
            guard let target = record.value(forKey: "target") as? NSObject else { continue }
            let actionName = String(describing: record.value(forKey: "action") ?? "")
            guard !actionName.isEmpty else { continue }
            _ = target.perform(NSSelectorFromString(actionName), with: gesture)
            fired = true
        }
        return fired
    }
}

// MARK: - type_text

public struct TypeTextTool: NativeTool {
    public let name = "type_text"
    public let description = "Enter text into a text field in the host app (UITextField/UITextView, incl. the "
        + "UIKit field behind a SwiftUI TextField), addressed by accessibility id, placeholder text, or "
        + "current content. Replaces the content by default; set append to add to it. Fires editingChanged "
        + "so bindings and validation react exactly as to real typing."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("id", "Accessibility id of the text field (preferred)"),
        .string("field", "Placeholder or current text of the field to match (substring)"),
        .string("text", "The text to enter (required)"),
        .bool("append", "Append to the existing content instead of replacing it (default false)")
    )

    public init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let id = args["id"] as? String
        let field = args["field"] as? String
        guard let text = args["text"] as? String else {
            return ["success": false, "error": "text is required"]
        }
        let append = args["append"] as? Bool ?? false

        // Find candidate text inputs by id/field match.
        var candidates: [ScreenElementFinder.Match] = []
        if let id, !id.isEmpty {
            candidates = ScreenElementFinder.find(id: id, text: nil)
        } else if let field, !field.isEmpty {
            candidates = ScreenElementFinder.find(id: nil, text: field)
        } else {
            return ["success": false, "error": "Provide id or field (placeholder/current text). Run inspect_screen to find the input."]
        }

        for match in candidates {
            if let input = Self.textInput(in: match.view) {
                _ = input.view.becomeFirstResponder()
                let newText = append ? (input.currentText + text) : text
                input.setText(newText)
                return ["success": true, "appended": append, "element": ScreenElementFinder.describe(match)]
            }
        }
        return ["success": false, "error": "No text input found matching. Pass the field's accessibility id, or an element inside it."]
    }

    /// The text-input view at or below (or immediately above) the matched element.
    private static func textInput(in view: UIView) -> TextInputBox? {
        if let box = TextInputBox(view) { return box }
        for sub in view.subviews {
            if let box = textInput(in: sub) { return box }
        }
        // SwiftUI fields: the match may be a wrapper whose sibling/child chain
        // holds the real input — also check up to 2 levels of descendants.
        for sub in view.subviews {
            for sub2 in sub.subviews {
                if let box = TextInputBox(sub2) { return box }
            }
        }
        return nil
    }

    /// Uniform text set/read over UITextField / UITextView.
    private struct TextInputBox {
        let view: UIView
        let currentText: String
        let setText: (String) -> Void

        init?(_ view: UIView) {
            if let field = view as? UITextField {
                self.view = field
                currentText = field.text ?? ""
                setText = { new in
                    field.text = new
                    field.sendActions(for: .editingChanged)
                }
                return
            }
            if let tv = view as? UITextView {
                self.view = tv
                currentText = tv.text ?? ""
                setText = { new in
                    tv.text = new
                    NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: tv)
                }
                return
            }
            return nil
        }
    }
}

// MARK: - scroll_element

public struct ScrollElementTool: NativeTool {
    public let name = "scroll_element"
    public let description = "Scroll a container in the host app (list, scroll view) by a fraction of its "
        + "visible height. Address it by the id of the scroll container or of ANY element inside it "
        + "(its enclosing scroll view is used). Use inspect_screen to see what's currently visible, "
        + "scroll, then inspect again."
    public let inputSchema: [String: Any] = ToolSchema.object(
        .string("id", "Accessibility id of the scroll container or an element inside it (empty = first scroll view on screen)"),
        .string("direction", "up | down | left | right (default down; 'up' scrolls toward the top)"),
        .number("amount", "Fraction of the visible size to scroll by, 0.1–2.0 (default 0.8)")
    )

    public init() {}

    @MainActor
    public func execute(args: [String: Any]) async throws -> Any {
        let id = args["id"] as? String
        let direction = (args["direction"] as? String ?? "down").lowercased()
        let amount = min(max(args["amount"] as? Double ?? 0.8, 0.1), 2.0)

        // Resolve the scroll view: enclosing for a matched element, else the
        // first visible one on screen.
        var scrollView: UIScrollView?
        if let id, !id.isEmpty {
            for match in ScreenElementFinder.find(id: id, text: nil) {
                if let sv = match.view as? UIScrollView ?? Self.enclosingScrollView(of: match.view) {
                    scrollView = sv
                    break
                }
            }
        } else if let window = ScreenElementFinder.hostWindow() {
            scrollView = Self.firstScrollView(in: window.rootViewController?.view ?? window)
        }
        guard let sv = scrollView else {
            return ["success": false, "error": "No scroll view found. Pass the id of an element inside the list."]
        }

        let fraction: CGFloat
        switch direction {
        case "up": fraction = -1
        case "left": fraction = -1
        default: fraction = 1
        }
        let horizontal = direction == "left" || direction == "right"
        var offset = sv.contentOffset
        if horizontal {
            let step = sv.bounds.width * amount * fraction
            offset.x = max(-sv.adjustedContentInset.left,
                           min(sv.contentSize.width - sv.bounds.width + sv.adjustedContentInset.right, offset.x + step))
        } else {
            let step = sv.bounds.height * amount * fraction
            offset.y = max(-sv.adjustedContentInset.top,
                           min(sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom, offset.y + step))
        }
        sv.setContentOffset(offset, animated: true)
        return ["success": true,
                "scrolledTo": ["x": Double(offset.x), "y": Double(offset.y)],
                "contentSize": ["w": Double(sv.contentSize.width), "h": Double(sv.contentSize.height)]]
    }

    private static func enclosingScrollView(of view: UIView) -> UIScrollView? {
        var v = view.superview
        while let cur = v {
            if let sv = cur as? UIScrollView { return sv }
            v = cur.superview
        }
        return nil
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let sv = view as? UIScrollView, !sv.isHidden && sv.alpha > 0.01 { return sv }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }
}
#endif
