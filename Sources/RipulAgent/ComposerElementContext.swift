import Foundation
#if os(iOS)
import UIKit

@MainActor
struct ComposerElementSelection {
    let view: UIView
    let highlightView: UIView
    let window: UIWindow
    let frame: CGRect
    let identifier: String?
    let className: String
    let controller: String?
    let property: String?
}
#endif

extension RipulComposerContext {
    public static var selectedElement: Self { selectedElement(configuration: .init()) }

    /// Capture the View Explorer's existing highlight, never move or activate it.
    /// Uses the same developer availability/defaults and user preview as Current screen.
    public static func selectedElement(configuration: RipulScreenContextConfiguration) -> Self {
        var option = Self(id: "ripul.selectedElement", title: "Selected element",
            subtitle: "The element highlighted in View Explorer", systemImage: "scope", kind: .screen) {
            try await ComposerScreenContext.captureSelectedElement(configuration: configuration).selectedText
        }
        option.captureScreen = { try await ComposerScreenContext.captureSelectedElement(configuration: configuration) }
        return option
    }
}
