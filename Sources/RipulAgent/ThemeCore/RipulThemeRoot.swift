import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - The theme root
//
// One modifier at the top of every SwiftUI tree: both window groups, the sheet
// wrappers, and each hosting controller. It carries what a root can carry.
//
// Measured on iOS 17.2 and 27.0 (docs/theming.md, "What the root reaches"):
//  - The accent reaches `.tint`, `Color.accentColor`, `UIColor.tintColor` and control
//    tints everywhere, sheets, popovers and hosting controllers included, when it is the
//    WINDOW's tint. SwiftUI's `.tint(_:)` alone misses `Color.accentColor` in a sheet.
//  - Text colours cannot be set from a root: a root `foregroundStyle` changes what
//    `.secondary` draws even when given today's colour, and recolours button labels.
//    Text colour is an edit at the call site: `.foregroundStyle(.ripul(.textSecondary))`.
//
// With no theme every value below is nil, and a nil tint, font and window tint mean
// "inherit": the modifier changes nothing.

extension View {
    /// Make this tree follow the theme: the accent as tint, the theme's body font as the
    /// default font, and a redraw when the theme changes.
    public func ripulThemeRoot() -> some View { modifier(RipulThemeRootModifier()) }
}

private struct RipulThemeRootModifier: ViewModifier {
    @State private var revision = 0

    func body(content: Content) -> some View {
        // The theme store is read here (through the accessors and `version`), so this body
        // runs again on a theme change. `revision` counts the notification as well, which
        // a host engine posts for its own changes.
        let stamp = RipulTheme.version &+ revision
        return content
            .tint(RipulTheme.accentOverride)
            .font(RipulTheme.defaultFontOverride)
            .modifier(RipulThemeLegacyRefresh(revision: stamp))
            .background(RipulWindowTint(revision: stamp))
            .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in
                revision += 1
            }
    }
}

#if os(iOS)
/// Keeps the older contract alive below a root: views that read `ripulThemeVersion`
/// (see `refreshesOnThemeChange()`) are invalidated by the same change.
private struct RipulThemeLegacyRefresh: ViewModifier {
    let revision: Int
    func body(content: Content) -> some View { content.environment(\.ripulThemeVersion, revision) }
}

/// Sets the tint of the window this tree is in. An invisible, zero-sized view.
private struct RipulWindowTint: UIViewRepresentable {
    let revision: Int

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: UIView {
        private var didSet = false

        override init(frame: CGRect) {
            super.init(frame: .zero)
            isHidden = true
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        /// Only ever touches a window's tint while the theme has an accent of its own,
        /// and puts back "inherit" when it stops having one.
        func apply() {
            guard let window else { return }
            if RipulTheme.isDefault(.accent) {
                if didSet { window.tintColor = nil; didSet = false }
            } else {
                window.tintColor = RipulTheme.platformColor(RipulTheme.color(.accent))
                didSet = true
            }
        }
    }
}
#else
private struct RipulThemeLegacyRefresh: ViewModifier {
    let revision: Int
    func body(content: Content) -> some View { content }
}

private struct RipulWindowTint: View {
    let revision: Int
    var body: some View { EmptyView() }
}
#endif
