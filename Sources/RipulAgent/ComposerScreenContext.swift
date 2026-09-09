import Foundation
#if os(iOS)
import UIKit
import WebKit
#elseif os(macOS)
import AppKit
#endif

extension RipulComposerContext {
    /// No maintained screen library, network request or screenshot. Capture visible
    /// native labels locally, before showing the context preview. SDK overlays and
    /// editable/secure fields are excluded from the automatic description.
    public static var currentScreen: Self {
        Self(id: "ripul.currentScreen", title: "Current screen", subtitle: "Describe the app screen I'm looking at",
             systemImage: "rectangle.inset.filled", kind: .screen) {
            try ComposerScreenContext.capture()
        }
    }
}

@MainActor
enum ComposerScreenContext {
    struct Unavailable: LocalizedError { var errorDescription: String? { "The app screen is not available. Try again when it is visible." } }
    static func capture() throws -> String {
        let bundle = Bundle.main
        let app = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "App"
        var lines = ["Host app: \(app)"]
        var labels: [String] = []
        var seen = Set<String>()
        func add(_ text: String?) {
            guard let text else { return }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, labels.count < 60, seen.insert(cleaned).inserted else { return }
            labels.append(String(cleaned.prefix(300)))
        }
        #if os(iOS)
        guard let window = RipulChrome.appWindow() else { throw Unavailable() }
        var controller = window.rootViewController
        while let current = controller {
            if let presented = current.presentedViewController { controller = presented }
            else if let nav = current as? UINavigationController { controller = nav.visibleViewController }
            else if let tabs = current as? UITabBarController { controller = tabs.selectedViewController }
            else { break }
        }
        if let title = controller?.navigationItem.title ?? controller?.title { lines.append("Screen: \(title)") }
        lines.append("Platform: \(UIDevice.current.systemName)")
        func walk(_ view: UIView, clip: CGRect) {
            guard !view.isHidden, view.alpha > 0.01, labels.count < 60,
                  !(view is UITextField), !(view is UITextView), !(view is WKWebView) else { return }
            let rect = view.convert(view.bounds, to: window)
            guard rect.intersects(clip) else { return }
            if let label = view as? UILabel { add(label.text) }
            if let button = view as? UIButton { add(button.title(for: .normal) ?? button.accessibilityLabel) }
            // SwiftUI accessibility labels can live on native wrapper views.
            if view.isAccessibilityElement { add(view.accessibilityLabel) }
            let nextClip = view.clipsToBounds ? clip.intersection(rect) : clip
            for child in view.subviews { walk(child, clip: nextClip) }
        }
        walk(window, clip: window.bounds)
        #elseif os(macOS)
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow, let root = window.contentView else { throw Unavailable() }
        lines.append("Platform: macOS")
        if !window.title.isEmpty { lines.append("Screen: \(window.title)") }
        func walk(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0.01, !view.visibleRect.isEmpty, labels.count < 60,
                  !(view is NSTextView), !(view is NSSecureTextField) else { return }
            if let label = view as? NSTextField, !label.isEditable { add(label.stringValue) }
            if let button = view as? NSButton { add(button.title) }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        #endif
        lines.append("Visible text and controls:\n" + (labels.isEmpty ? "No readable native labels were found." : labels.map { "- " + $0 }.joined(separator: "\n")))
        lines.append("This is a snapshot selected by the user; the screen may have changed since capture.")
        return lines.joined(separator: "\n")
    }
}
