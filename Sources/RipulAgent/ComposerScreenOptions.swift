import Foundation
import ImageIO

public enum RipulScreenContextComponent: String, Codable, CaseIterable {
    case instrumentedText, screenshot, fallbackText
    public var title: String {
        switch self {
        case .instrumentedText: return "App description"
        case .screenshot: return "Screenshot"
        case .fallbackText: return "Recognized screen text"
        }
    }
}

/// Options offered in the review sheet. Nil defaults choose instrumented text when
/// available, otherwise a screenshot. Fallback text is never an automatic substitute.
public struct RipulScreenContextConfiguration {
    public var available: Set<RipulScreenContextComponent>
    public var defaults: Set<RipulScreenContextComponent>?
    public init(available: Set<RipulScreenContextComponent> = Set(RipulScreenContextComponent.allCases),
                defaults: Set<RipulScreenContextComponent>? = nil) {
        self.available = available; self.defaults = defaults
    }
}

/// Frozen local capture. Only selected components enter the outgoing message.
/// This draft is transient; it is never persisted as a conversation shortcut.
public struct RipulScreenContextSnapshot: Codable, Equatable {
    public var appDescription: String
    public var instrumentedText: String?
    public var screenshotJPEG: Data?
    public var fallbackText: String?
    public var available: Set<RipulScreenContextComponent>
    public var selected: Set<RipulScreenContextComponent>
    var accessibleFallback: String

    init(appDescription: String, instrumentedText: String?, screenshotJPEG: Data?,
         accessibleFallback: String, configuration: RipulScreenContextConfiguration) {
        self.appDescription = appDescription
        self.instrumentedText = instrumentedText
        self.screenshotJPEG = screenshotJPEG
        self.accessibleFallback = accessibleFallback
        available = configuration.available
        if instrumentedText?.isEmpty != false { available.remove(.instrumentedText) }
        if screenshotJPEG == nil { available.remove(.screenshot) }
        if let defaults = configuration.defaults { selected = defaults.intersection(available) }
        else if available.contains(.instrumentedText) { selected = [.instrumentedText] }
        else if available.contains(.screenshot) { selected = [.screenshot] }
        else { selected = [] }
    }

    var effectiveSelection: Set<RipulScreenContextComponent> { selected.intersection(available) }
    var selectedText: String {
        var parts = [appDescription]
        if effectiveSelection.contains(.instrumentedText), let text = instrumentedText { parts.append(text) }
        if effectiveSelection.contains(.fallbackText), let text = fallbackText { parts.append("Recognized screen text:\n" + text) }
        if effectiveSelection.contains(.screenshot), screenshotJPEG != nil { parts.append("The selected screen screenshot is attached as an image.") }
        return parts.joined(separator: "\n\n")
    }
    var canAttach: Bool {
        !effectiveSelection.isEmpty && (!effectiveSelection.contains(.fallbackText) || fallbackText != nil)
    }
    func recognizeFallback() async throws -> String {
        if let data = screenshotJPEG,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let items = try await ComposerScreenRecognition.recognize(image)
            let text = ComposerScreenRecognition.simpleText(items)
            if !text.isEmpty { return text }
        }
        return accessibleFallback.isEmpty ? "No readable screen text was found." : accessibleFallback
    }
}
