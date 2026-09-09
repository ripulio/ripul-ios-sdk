import Foundation
import CoreGraphics
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension RipulComposerContext {
    public static var currentScreen: Self { currentScreen(configuration: .init()) }

    /// Supply component defaults and optionally your own app-state description.
    /// The provider runs only when Current screen is selected, before its preview opens.
    public static func currentScreen(configuration: RipulScreenContextConfiguration,
        instrumentedText: (@MainActor () async throws -> String)? = nil) -> Self {
        var option = Self(id: "ripul.currentScreen", title: "Current screen", subtitle: "Choose a description, screenshot or recognized text",
             systemImage: "rectangle.inset.filled", kind: .screen) {
            try await ComposerScreenContext.capture(configuration: configuration, provider: instrumentedText).selectedText
        }
        option.captureScreen = { try await ComposerScreenContext.capture(configuration: configuration, provider: instrumentedText) }
        return option
    }
}

@MainActor
enum ComposerScreenContext {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "The app screen is not available. Try again when it is visible." }
    }
    private struct Semantic {
        var context: RipulAIContext
        var frame: CGRect
    }
    private struct Snapshot {
        var title: String?
        var image: CGImage?
        var semantics: [Semantic] = []
        var accessible: [ComposerScreenText] = []
        var excluded: [CGRect] = []
    }

    static func capture(configuration: RipulScreenContextConfiguration,
                        provider: (@MainActor () async throws -> String)? = nil) async throws -> RipulScreenContextSnapshot {
        let needsPixels = configuration.available.contains(.screenshot) || configuration.available.contains(.fallbackText)
        let snapshot = try snapshot(includeImage: needsPixels)
        try Task.checkCancellation()
        let bundle = Bundle.main
        let app = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "App"
        var header = ["Host app: \(app)"]
        let semantics = snapshot.semantics.filter { item in
            if item.context.role == .screen || item.context.role == .group {
                return !snapshot.excluded.contains { $0.contains(item.frame) }
            }
            return !ComposerScreenRecognition.overlaps(item.frame, regions: snapshot.excluded)
        }
        if let title = snapshot.title, !title.isEmpty { header.append("Screen: \(title)") }
        var instrumented: String?
        if configuration.available.contains(.instrumentedText) {
            if let provider { instrumented = try await provider() }
            else {
                var seen = Set<String>()
                let lines = semantics.sorted { $0.frame.minY < $1.frame.minY }.prefix(100).compactMap { item -> String? in
                    let context = item.context
                    let text = context.label + (context.value.map { ": \($0)" } ?? "")
                        + (context.hint.map { " — \($0)" } ?? "")
                    return seen.insert(context.id + text).inserted ? "- " + String(text.prefix(1500)) : nil
                }
                instrumented = lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
        }
        instrumented = instrumented?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = ComposerScreenRecognition.simpleText(snapshot.accessible.filter {
            !ComposerScreenRecognition.overlaps($0.frame, regions: snapshot.excluded)
        })
        var result = RipulScreenContextSnapshot(appDescription: header.joined(separator: "\n"),
            instrumentedText: instrumented, screenshotJPEG: snapshot.image.flatMap(ComposerScreenRecognition.jpeg),
            accessibleFallback: fallback, configuration: configuration)
        if result.selected.contains(.fallbackText) { result.fallbackText = try await result.recognizeFallback() }
        try Task.checkCancellation()
        return result
    }

    struct ElementUnavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func captureSelectedElement(configuration: RipulScreenContextConfiguration) async throws -> RipulScreenContextSnapshot {
        #if os(iOS)
        guard let selection = ViewInspectorController.live?.composerSelection() else {
            throw ElementUnavailable(message: "Open View Explorer and highlight an element first. If the screen changed, select the element again.")
        }
        let needsPixels = configuration.available.contains(.screenshot) || configuration.available.contains(.fallbackText)
        // This captures and masks the host before any asynchronous recognition.
        let snapshot = try snapshot(includeImage: needsPixels, hostWindow: selection.window)
        let scope = normalized(selection.frame, in: selection.window.bounds)
        for start in [selection.view, selection.highlightView] {
            var ancestor: UIView? = start
            while let view = ancestor {
                if view.ripulAIContext?.isExcluded == true || (view as? UITextField)?.isSecureTextEntry == true
                    || ((view is UITextField || view is UITextView) && view.ripulAIContext == nil) {
                    throw ElementUnavailable(message: "This element is excluded from context capture by the app.")
                }
                ancestor = view.superview
            }
        }
        guard !snapshot.excluded.contains(where: { $0.contains(scope) }) else {
            throw ElementUnavailable(message: "This element is excluded from context capture by the app.")
        }
        let semantics = snapshot.semantics.filter {
            scope.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) && scope.intersects($0.frame)
                && !ComposerScreenRecognition.overlaps($0.frame, regions: snapshot.excluded)
                && $0.frame.width <= scope.width * 1.1 && $0.frame.height <= scope.height * 1.1
        }
        let hasPrivateContent = ComposerScreenRecognition.overlaps(scope, regions: snapshot.excluded)
        // Read live values of the SAME element, never a new point hit or retained Copy text.
        let view = selection.view
        let label = hasPrivateContent ? nil : (view.accessibilityLabel ?? (view as? UILabel)?.text ?? (view as? UIButton)?.title(for: .normal))
        let value = hasPrivateContent ? nil : (view.ripulAIContext?.value ?? view.accessibilityValue
            ?? (view as? UITextField)?.text ?? (view as? UITextView)?.text)
        let name = semantics.first?.context.label ?? label ?? selection.identifier ?? selection.className
        let app = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "App"
        let f = selection.frame
        var lines = ["Type: \(selection.className)"]
        if let role = ScreenElementFinder.role(of: view) { lines.append("Role: \(role)") }
        if let id = selection.identifier { lines.append("Identifier: \(id)") }
        if let label, !label.isEmpty { lines.append("Label: \(String(label.prefix(1500)))") }
        if let value, !value.isEmpty { lines.append("Value: \(String(value.prefix(1500)))") }
        if let vc = selection.controller { lines.append("View controller: \(vc)") }
        if let property = selection.property { lines.append("Property: \(property)") }
        lines.append("Location in host window (points): x=\(Int(f.minX)), y=\(Int(f.minY)), width=\(Int(f.width)), height=\(Int(f.height))")
        for item in semantics.prefix(30) {
            let c = item.context
            lines.append(c.label + (c.value.map { ": " + $0 } ?? "") + (c.hint.map { " — " + $0 } ?? ""))
        }
        let image = snapshot.image.flatMap { image -> CGImage? in
            let rect = CGRect(x: scope.minX * CGFloat(image.width), y: scope.minY * CGFloat(image.height),
                width: scope.width * CGFloat(image.width), height: scope.height * CGFloat(image.height)).integral
            return image.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
        }
        let fallback = ComposerScreenRecognition.simpleText(snapshot.accessible.filter {
            scope.contains($0.frame) && !ComposerScreenRecognition.overlaps($0.frame, regions: snapshot.excluded)
        })
        var result = RipulScreenContextSnapshot(appDescription: "Host app: \(app)\nSelected View Explorer element",
            instrumentedText: configuration.available.contains(.instrumentedText) ? lines.joined(separator: "\n") : nil,
            screenshotJPEG: image.flatMap(ComposerScreenRecognition.jpeg), accessibleFallback: fallback, configuration: configuration)
        result.attachmentTitle = "Element — " + String(name.prefix(80))
        if result.selected.contains(.fallbackText) { result.fallbackText = try await result.recognizeFallback() }
        try Task.checkCancellation()
        return result
        #else
        throw ElementUnavailable(message: "Selected element context requires the iOS View Explorer.")
        #endif
    }

    private static func normalized(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: (rect.minX - bounds.minX) / bounds.width, y: (rect.minY - bounds.minY) / bounds.height,
               width: rect.width / bounds.width, height: rect.height / bounds.height)
    }

    #if os(iOS)
    private static func snapshot(includeImage: Bool, hostWindow: UIWindow? = nil) throws -> Snapshot {
        guard let window = hostWindow ?? RipulChrome.appWindow(), window.bounds.width > 0, window.bounds.height > 0 else { throw Unavailable() }
        var result = Snapshot()
        var controller = window.rootViewController
        while let current = controller {
            if let presented = current.presentedViewController { controller = presented }
            else if let nav = current as? UINavigationController { controller = nav.visibleViewController }
            else if let tabs = current as? UITabBarController { controller = tabs.selectedViewController }
            else { break }
        }
        result.title = controller?.navigationItem.title ?? controller?.title
        let bounds = window.bounds
        var visited = Set<ObjectIdentifier>()
        var count = 0
        func walkAccessibility(_ object: NSObject) {
            guard count < 2000, visited.insert(ObjectIdentifier(object)).inserted else { return }
            count += 1
            // UIView branches are traversed separately with visibility/exclusion checks.
            if !(object is UIView), object.isAccessibilityElement {
                let rect = window.convert(object.accessibilityFrame, from: nil).intersection(bounds)
                if !rect.isNull, !rect.isEmpty {
                    let label = object.accessibilityLabel ?? ""
                    let value = object.accessibilityValue ?? ""
                    let text = [label, value].filter { !$0.isEmpty }.joined(separator: ": ")
                    if !text.isEmpty { result.accessible.append(.init(text: text, frame: normalized(rect, in: bounds))) }
                }
            }
            if let elements = object.accessibilityElements as? [NSObject] {
                for element in elements where !(element is UIView) { walkAccessibility(element) }
            } else {
                let total = object.accessibilityElementCount()
                if total > 0 && total < 2000 {
                    for index in 0..<total {
                        if let element = object.accessibilityElement(at: index) as? NSObject, !(element is UIView) { walkAccessibility(element) }
                    }
                }
            }
        }
        var chrome: [UIView] = []
        func walk(_ view: UIView, clip: CGRect) {
            if view is ViewInspectorController || view.tag == ripulViewExplorerOverlayTag { chrome.append(view); return }
            guard count < 2000, !view.isHidden, view.alpha > 0.01 else { return }
            let rect = view.convert(view.bounds, to: window).intersection(clip)
            // Some SwiftUI wrappers have zero bounds but visible, non-clipped descendants.
            if rect.isNull || rect.isEmpty {
                if !view.clipsToBounds { for child in view.subviews { walk(child, clip: clip) } }
                return
            }
            let frame = normalized(rect, in: bounds)
            let context = view.ripulAIContext
            let privateField = (view as? UITextField)?.isSecureTextEntry == true
                || ((view is UITextField || view is UITextView) && context == nil)
            if context?.isExcluded == true || privateField {
                result.excluded.append(frame); return
            }
            if let context { result.semantics.append(.init(context: context, frame: frame)) }
            var label = view.accessibilityLabel
            if label?.isEmpty ?? true { label = (view as? UILabel)?.text ?? (view as? UIButton)?.title(for: .normal) }
            let text = [label, view.accessibilityValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            if !text.isEmpty { result.accessible.append(.init(text: text, frame: frame)) }
            walkAccessibility(view)
            let nextClip = view.clipsToBounds ? rect : clip
            for child in view.subviews { walk(child, clip: nextClip) }
        }
        walk(hostWindow == nil ? (controller?.viewIfLoaded ?? window) : window, clip: bounds)
        // Capture ONLY the host window, never SDK overlay windows. Mask private regions
        // in pixels before OCR, then also filter observations as defence against edge overlap.
        guard includeImage, count < 2000 else { return result }
        let hiddenStates = chrome.map { ($0, $0.isHidden) }
        chrome.forEach { $0.isHidden = true }
        defer { hiddenStates.forEach { $0.0.isHidden = $0.1 } }
        let format = UIGraphicsImageRendererFormat.default(); format.scale = min(window.screen.scale, 2)
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { context in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            context.cgContext.setFillColor(UIColor.black.cgColor)
            for region in result.excluded {
                context.cgContext.fill(CGRect(x: bounds.minX + region.minX * bounds.width, y: bounds.minY + region.minY * bounds.height,
                    width: region.width * bounds.width, height: region.height * bounds.height).insetBy(dx: -2, dy: -2))
            }
        }
        result.image = count < 2000 ? image.cgImage : nil
        return result
    }
    #elseif os(macOS)
    private static func snapshot(includeImage: Bool) throws -> Snapshot {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow, let root = window.contentView,
              root.bounds.width > 0, root.bounds.height > 0 else { throw Unavailable() }
        var result = Snapshot(); result.title = window.title
        let bounds = root.bounds
        var count = 0
        func topLeft(_ rect: CGRect) -> CGRect {
            let rect = root.isFlipped ? rect : CGRect(x: rect.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
            return normalized(rect, in: bounds)
        }
        func walk(_ view: NSView) {
            guard count < 2000, !view.isHidden, view.alphaValue > 0.01, !view.visibleRect.isEmpty else { return }
            count += 1
            let rect = view.convert(view.visibleRect, to: root).intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { return }
            let frame = topLeft(rect)
            let context = view.ripulAIContext
            let privateField = view is NSSecureTextField || (context == nil && (view is NSTextView || (view as? NSTextField)?.isEditable == true))
            if context?.isExcluded == true || privateField { result.excluded.append(frame); return }
            if let context { result.semantics.append(.init(context: context, frame: frame)) }
            let label = view.accessibilityLabel() ?? (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title
            let value = view.accessibilityValue() as? String
            let text = [label, value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            if !text.isEmpty { result.accessible.append(.init(text: text, frame: frame)) }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        guard includeImage, count < 2000 else { return result }
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: bounds) {
            root.cacheDisplay(in: bounds, to: bitmap)
            if let original = bitmap.cgImage,
               let context = CGContext(data: nil, width: original.width, height: original.height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                let width = CGFloat(original.width), height = CGFloat(original.height)
                context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                for region in result.excluded {
                    context.fill(CGRect(x: region.minX * width, y: (1 - region.maxY) * height,
                        width: region.width * width, height: region.height * height).insetBy(dx: -2, dy: -2))
                }
                result.image = count < 2000 ? context.makeImage() : nil
            }
        }
        return result
    }
    #endif
}
