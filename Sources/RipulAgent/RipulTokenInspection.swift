#if os(iOS)
import UIKit

// MARK: - Design-token inspection
//
// Lets the View Explorer answer "which THEME TOKEN colours this element, and what can I change it
// to?" — so a designer/owner discovers and remaps tokens by tapping the running app, without
// knowing token names up front.
//
// The SDK stays host-agnostic: it knows nothing about the host's theme system, associated-object
// keys, or token enums. It only renders whatever bindings the host's `RipulTokenProvider` returns
// for a tapped `UIView`, and asks the provider to apply a remap. A host with no provider registered
// simply doesn't see the Design-token section — everything else in the inspector is unchanged.

/// One design token currently styling an inspected view (e.g. its text colour is `rowTitle`).
public struct RipulTokenBinding: Identifiable, Equatable {
    /// Stable within a single view — typically the styled property key ("textColor", "background").
    public let id: String
    /// Human label for the styled property: "Text colour", "Background", "Tint".
    public let property: String
    /// The token itself — the thing a designer remaps: "cardIcon", "rowTitle".
    public let tokenName: String
    /// What the token currently resolves to, display-only (e.g. the role "accent"). nil if n/a.
    public let resolvesTo: String?
    /// The current resolved colour as "#RRGGBB", for a swatch.
    public let swatchHex: String
    /// The choices this token can be remapped to.
    public let options: [RipulTokenOption]

    public init(id: String, property: String, tokenName: String,
                resolvesTo: String?, swatchHex: String, options: [RipulTokenOption]) {
        self.id = id
        self.property = property
        self.tokenName = tokenName
        self.resolvesTo = resolvesTo
        self.swatchHex = swatchHex
        self.options = options
    }
}

/// A choice a token can be remapped to — an opaque handle the provider understands, plus display.
public struct RipulTokenOption: Identifiable, Equatable {
    /// Opaque to the SDK; meaningful to the provider (e.g. a role name or a "#hex").
    public let id: String
    public let label: String
    public let swatchHex: String

    public init(id: String, label: String, swatchHex: String) {
        self.id = id
        self.label = label
        self.swatchHex = swatchHex
    }
}

/// Implemented by the host app: the bridge between a live `UIView` and the host's theme tokens.
/// Reading which token styles a view, and applying a remap, both live on the host side (the SDK
/// never touches the theme). All calls are on the main thread.
@MainActor
public protocol RipulTokenProvider: AnyObject {
    /// The tokens currently styling `view`, or `[]` when it isn't themed / carries no token metadata.
    func tokenBindings(for view: UIView) -> [RipulTokenBinding]

    /// Remap the token named in `binding` to `option`, applying it live and persisting it in the
    /// host's theme. Returns the new resolved "#RRGGBB" for the swatch, or nil if it couldn't apply.
    @discardableResult
    func remap(_ binding: RipulTokenBinding, to option: RipulTokenOption) -> String?
}

/// Registration point. The host sets `provider` once at launch; a nil provider hides the feature.
@MainActor
public enum RipulTokenInspector {
    public static weak var provider: RipulTokenProvider?

    /// Bindings for a view, or `[]` when no provider is registered. Convenience for the overlay.
    static func bindings(for view: UIView) -> [RipulTokenBinding] {
        provider?.tokenBindings(for: view) ?? []
    }
}

// MARK: - Declared token colours (SwiftUI stamps)

/// SwiftUI content draws into layers, not subviews — its colours are unreachable by the UIKit
/// reads a token provider performs (textColor / backgroundColor / tintColor). A
/// `.uiKitIdentifier(_:tokenColors:)` stamp therefore DECLARES the token-tagged colours of the
/// content it stands in for; the host's provider reads them back off the stamp view and treats
/// them exactly like colours found on a UIKit view.
public struct RipulDeclaredTokenColor {
    /// Human label for the styled property, shown in the Design-token section ("Text colour", "Icon").
    public let property: String
    /// The host's token-tagged UIColor — the same value the SwiftUI view renders with.
    public let color: UIColor

    public init(property: String, color: UIColor) {
        self.property = property
        self.color = color
    }
}

private enum RipulDeclaredTokenColorsKey { static var key: UInt8 = 0 }

public extension UIView {
    /// Token colours declared for this view by a `.uiKitIdentifier(_:tokenColors:)` stamp.
    /// Empty for views without a declaration.
    var ripulDeclaredTokenColors: [RipulDeclaredTokenColor] {
        get { objc_getAssociatedObject(self, &RipulDeclaredTokenColorsKey.key) as? [RipulDeclaredTokenColor] ?? [] }
        set { objc_setAssociatedObject(self, &RipulDeclaredTokenColorsKey.key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
#endif
