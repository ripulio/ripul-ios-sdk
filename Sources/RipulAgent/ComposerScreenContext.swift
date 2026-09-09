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

    private static func normalized(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: (rect.minX - bounds.minX) / bounds.width, y: (rect.minY - bounds.minY) / bounds.height,
               width: rect.width / bounds.width, height: rect.height / bounds.height)
    }

    #if os(iOS)
    private static func snapshot(includeImage: Bool) throws -> Snapshot {
        guard let window = RipulChrome.appWindow(), window.bounds.width > 0, window.bounds.height > 0 else { throw Unavailable() }
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
        func walk(_ view: UIView, clip: CGRect) {
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
        walk(controller?.viewIfLoaded ?? window, clip: bounds)
        // Capture ONLY the host window, never SDK overlay windows. Mask private regions
        // in pixels before OCR, then also filter observations as defence against edge overlap.
        guard includeImage, count < 2000 else { return result }
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
