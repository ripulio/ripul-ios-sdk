#if os(iOS)
import UIKit
import SwiftUI

// MARK: - Design-token instrumentation (runtime discovery)
//
// The host-agnostic half of a live theme system: at runtime, point at any on-screen
// element and learn which THEME TOKEN colours it — so a designer/owner can discover and
// remap tokens live (via the Ripul View Explorer) without knowing token names up front.
//
// Mechanism: the token rides on the `UIColor` object itself (an associated object),
// stamped at the ONE place a token resolves to a colour in the host's theme engine.
// Because the tag lives on the value, every EXISTING assignment transports it for free:
//     label.textColor = theme.color(.rowTitle)   // the label's textColor now knows its token
// No call-site changes, no parallel registry that can drift out of sync.
//
// Coverage notes (proven by the host that donated this machinery):
//   • textColor / tintColor / button title / attributed foreground — survive assignment + render.
//   • backgroundColor — the setter converts to CGColor and drops the tag, so it's rescued by
//     the `setBackgroundColor:` swizzle below (which stamps the VIEW instead).
//   • withAlphaComponent — mints a new, untagged colour; use `ripulAlpha(_:)` to fade a
//     token colour instead.
//   • CGColor sinks (borders/shadows/gradient layers) are out of reach — instrument the
//     central gradient/border builders directly if those need to be discoverable.

private var ripulTokenKey: UInt8 = 0

extension UIColor {

    /// The design-token label this colour was resolved from (e.g. "cardIcon", "textPrimary"),
    /// or nil for colours that didn't come through the theme engine. Set only by the host's
    /// resolution chokepoints; read by the inspector to name what a tapped element is themed with.
    public var ripulToken: String? {
        get { objc_getAssociatedObject(self, &ripulTokenKey) as? String }
        set { objc_setAssociatedObject(self, &ripulTokenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Tag `self` with `token` and return it — for chaining at the resolution site. The caller
    /// must only pass freshly-minted instances (never a shared singleton like `.clear`), so a
    /// tag can't leak onto every use of a global colour.
    public func ripulTagged(_ token: String) -> UIColor {
        ripulToken = token
        return self
    }

    /// Fade a colour while carrying its design token across. The token-preserving replacement
    /// for `withAlphaComponent`, which returns a new, untagged colour (and can't be swizzled —
    /// `UIColor` is a class cluster whose concrete subclasses override it).
    public func ripulAlpha(_ alpha: CGFloat) -> UIColor {
        let faded = withAlphaComponent(alpha)
        if let token = ripulToken { faded.ripulToken = token }
        return faded
    }
}

private var ripulBackgroundTokenKey: UInt8 = 0

extension UIView {

    /// The design token behind this view's `backgroundColor`, captured by the setter swizzle
    /// (the colour object itself can't carry it — `backgroundColor` round-trips through CGColor).
    public var ripulBackgroundToken: String? {
        get { objc_getAssociatedObject(self, &ripulBackgroundTokenKey) as? String }
        set { objc_setAssociatedObject(self, &ripulBackgroundTokenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @objc fileprivate func ripul_setBackgroundColor(_ color: UIColor?) {
        // Only touch the associated object when it's relevant: the incoming colour carries a
        // token, OR this view already had one (so a restyle to an untokened colour CLEARS it,
        // never leaving a stale tag). Keeps the swizzle off the scrolling hot path.
        if let token = color?.ripulToken {
            ripulBackgroundToken = token
        } else if ripulBackgroundToken != nil {
            ripulBackgroundToken = nil
        }
        ripul_setBackgroundColor(color)   // swizzled: this now calls the ORIGINAL setter
    }
}

/// Installs the runtime token instrumentation. Idempotent; call once at launch.
public enum RipulThemeInstrumentation {
    private static var installed = false

    public static func install() {
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(UIView.self, #selector(setter: UIView.backgroundColor)),
              let swizzled = class_getInstanceMethod(UIView.self, #selector(UIView.ripul_setBackgroundColor(_:))) else {
            assertionFailure("[RipulTheme] could not swizzle UIView.backgroundColor setter")
            return
        }
        method_exchangeImplementations(original, swizzled)
    }
}

// MARK: - Theme-change broadcast + live refresh

extension Notification.Name {
    /// Posted by the host's theme engine whenever the live theme changes. The SDK's refresh
    /// modifier and hosting factory listen for exactly this name — a host adopting live
    /// theming posts it from its apply path (one post per apply).
    public static let ripulThemeDidChange = Notification.Name("ripulThemeDidChange")
}

@available(iOS 14.0, *)
private struct RipulThemeVersionKey: EnvironmentKey {
    static let defaultValue = 0
}

@available(iOS 14.0, *)
public extension EnvironmentValues {
    /// Monotonic counter bumped at every island root (see `refreshesOnThemeChange()` /
    /// `ripulThemedHostingController`) each time the host posts `.ripulThemeDidChange`.
    ///
    /// THE GENERIC LIVE-THEME CONTRACT for theme-aware components: declare
    ///     @Environment(\.ripulThemeVersion) private var themeVersion
    /// and read it at the TOP of body (`let _ = themeVersion`) BEFORE reading theme values
    /// (`Theme.current…`, resolved styles, tokens). Environment invalidation then re-invokes
    /// THAT body on every theme change, so the theme read re-runs — at any depth below the
    /// island root, with no per-view notification plumbing. Reading the key is what registers
    /// the dependency; declaring the property alone does nothing.
    var ripulThemeVersion: Int {
        get { self[RipulThemeVersionKey.self] }
        set { self[RipulThemeVersionKey.self] = newValue }
    }
}

@available(iOS 14.0, *)
private struct RipulThemeRefreshModifier: ViewModifier {
    @State private var version = 0
    func body(content: Content) -> some View {
        // The version MUST be read in body: SwiftUI only re-invokes body for state it
        // actually read during the last evaluation (dependency tracking). Bumping an
        // unread counter in onReceive registers no dependency and re-renders nothing.
        let _ = version
        // Inject as an ENVIRONMENT value rather than relying on subtree re-render: a state
        // bump here re-runs THIS body, but values consumers already read and baked into the
        // subtree as plain values stay stale — SwiftUI does not re-invoke their bodies.
        // Environment invalidation DOES propagate to every descendant that read the key.
        return content
            .environment(\.ripulThemeVersion, version)
            .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in
                version += 1
            }
    }
}

@available(iOS 14.0, *)
extension View {
    /// Re-render this SwiftUI view whenever the host's theme changes (`.ripulThemeDidChange`),
    /// so it re-reads its theme tokens live.
    ///
    /// HOW CONSUMERS OPT IN: the modifier injects an environment counter
    /// (`EnvironmentValues.ripulThemeVersion`) that bumps on every theme change. A view that
    /// reads theme values at the top of its body MUST also read the key there:
    ///     @Environment(\.ripulThemeVersion) private var themeVersion
    ///     var body: some View { let _ = themeVersion; let style = Theme.current… }
    /// Environment invalidation re-invokes exactly the bodies that read the key, at any depth
    /// below the attachment point. Without that read, the body keeps its stale values: a state
    /// bump in an ancestor does NOT re-invoke bodies that only baked theme values into the
    /// subtree as plain lets (measured on device: legend stayed 26.67pt after legendSize 26
    /// until an unrelated state change forced the body).
    ///
    /// PLACEMENT RULE: attach at the hosting-controller root (use `ripulThemedHostingController`)
    /// or in a SwiftUI ancestor of every consumer — the environment flows DOWN, so consumers
    /// above the attachment point are never invalidated. In-body use covers only that view's
    /// descendants.
    public func refreshesOnThemeChange() -> some View { modifier(RipulThemeRefreshModifier()) }
}

/// Host a SwiftUI island with LIVE theme adoption baked in: wraps `rootView` in
/// `.refreshesOnThemeChange()` at the island root, so the `ripulThemeVersion` environment
/// counter reaches every descendant. Use for EVERY `UIHostingController` that embeds themed
/// SwiftUI inside UIKit — and note the consumer half of the contract (documented on
/// `refreshesOnThemeChange()`): a view only repaints on theme change if it READS
/// `@Environment(\.ripulThemeVersion)` in its body. Type-erased to `AnyView` so host
/// properties need no generic-parameter gymnastics:
///
///     let host = ripulThemedHostingController(rootView: ReceiptView(model: model))
@available(iOS 14.0, *)
public func ripulThemedHostingController<Content: View>(rootView: Content) -> UIHostingController<AnyView> {
    UIHostingController(rootView: AnyView(rootView.refreshesOnThemeChange()))
}
#endif
