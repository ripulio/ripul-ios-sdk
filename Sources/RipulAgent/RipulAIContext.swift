import SwiftUI
import ObjectiveC
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Semantic context attached to a live component, updated with the same state as its UI.
/// These are descriptions of app data, never agent instructions. Nothing is read or sent
/// until the user selects Current screen and reviews the resulting attachment.
public struct RipulAIContext: Equatable {
    public enum Role: String { case screen, group, value, control }
    public var id: String
    public var label: String
    public var value: String?
    public var hint: String?
    public var role: Role
    public var isExcluded: Bool

    public init(id: String, label: String, value: String? = nil, hint: String? = nil,
                role: Role = .value, isExcluded: Bool = false) {
        self.id = id; self.label = label; self.value = value; self.hint = hint
        self.role = role; self.isExcluded = isExcluded
    }
    /// Suppress the component's entire visible region in both semantic and visual capture.
    public static var excluded: Self { Self(id: "", label: "", isExcluded: true) }
}

private var aiContextKey: UInt8 = 0
private final class AIContextBox: NSObject {
    let context: RipulAIContext
    init(_ context: RipulAIContext) { self.context = context }
}

#if os(iOS)
extension UIView {
    /// Assign whenever the component's displayed state changes. Nil removes instrumentation.
    @MainActor public var ripulAIContext: RipulAIContext? {
        get { (objc_getAssociatedObject(self, &aiContextKey) as? AIContextBox)?.context }
        set { objc_setAssociatedObject(self, &aiContextKey, newValue.map(AIContextBox.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
private struct AIContextMarker: UIViewRepresentable {
    let context: RipulAIContext
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false; return view
    }
    func updateUIView(_ view: UIView, context: Context) { view.ripulAIContext = self.context }
}
#elseif os(macOS)
extension NSView {
    @MainActor public var ripulAIContext: RipulAIContext? {
        get { (objc_getAssociatedObject(self, &aiContextKey) as? AIContextBox)?.context }
        set { objc_setAssociatedObject(self, &aiContextKey, newValue.map(AIContextBox.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
private struct AIContextMarker: NSViewRepresentable {
    let context: RipulAIContext
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { view.ripulAIContext = self.context }
}
#endif

extension View {
    /// Instrument the component with its current meaning and value. Apply to the actual
    /// component (after its frame/layout modifiers), not to a separate off-screen registry.
    public func ripulAIContext(_ context: RipulAIContext) -> some View {
        background(AIContextMarker(context: context).allowsHitTesting(false).accessibilityHidden(true))
    }
    public func ripulAIContextExcluded() -> some View { ripulAIContext(.excluded) }
}
