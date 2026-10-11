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
//  - The canvas reaches every screen that draws no ground of its own when a window's root
//    draws it behind the tree (the start chooser, an empty state, a plain stack). Only a
//    window's root does: a sheet has a ground, and an overlay is meant to be seen through.
//  - Text colours cannot be set from a root: a root `foregroundStyle` changes what
//    `.secondary` draws even when given today's colour, and recolours button labels.
//    Text colour is an edit at the call site: `.foregroundStyle(.ripul(.textSecondary))`.
//
// With no theme every value below is nil, and a nil tint, font and window tint mean
// "inherit": the modifier changes nothing.

extension View {
    /// Make this tree follow the theme: the accent as tint, the theme's body font as the
    /// default font, and a redraw when the theme changes.
    ///
    /// A host that names its theme in Info.plist (`RipulTheme`) writes only this, and one
    /// that names none keeps the system look.
    ///
    /// - Parameter window: true on the root of a window's own tree. Under a theme that
    ///   names a canvas, that root draws it behind everything, so a screen with no ground
    ///   of its own stands on the theme's and not on the system's white or black. Leave
    ///   it false on the root of a sheet, a popover or an overlay: those have a ground
    ///   already, or are meant to be seen through.
    public func ripulThemeRoot(window: Bool = false) -> some View {
        RipulTheme.installIfNeeded()
        return modifier(RipulThemeRootModifier(drawsCanvas: window))
    }

    /// The root of a host's own tree, naming its theme: `<name>.json` in the app's
    /// bundle. This one line is the host's whole setup. The SDK finds the document,
    /// registers the bundled fonts it names, keeps a choice made with `RipulTheme.select`
    /// between launches, and falls back to this document, then to the system look, when
    /// one is missing or refused (docs/theming-for-hosts.md).
    public func ripulThemeRoot(theme name: String) -> some View {
        // Here and not in the modifier's body: this runs when the parent's body does,
        // before any view below it reads a font or a colour.
        RipulTheme.install(theme: name)
        return modifier(RipulThemeRootModifier(drawsCanvas: true))
    }
}

private struct RipulThemeRootModifier: ViewModifier {
    let drawsCanvas: Bool
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
            // A screen that draws no ground of its own stands on the window's, which is
            // the system's white or black. Under a theme that names a canvas it stands on
            // that. With no canvas named nothing is drawn here.
            .background { if drawsCanvas, !RipulTheme.isDefault(.canvas) { Color.ripul(.canvas).ignoresSafeArea() } }
            .background(RipulWindowTint(revision: stamp))
            .onReceive(NotificationCenter.default.publisher(for: .ripulThemeDidChange)) { _ in
                revision += 1
            }
            .modifier(RipulThemeLinks())
    }
}

/// `<the app's scheme>://theme?name=<name>` switches the theme, in a Debug build of any
/// host. A store build has no such door: there the host calls `RipulTheme.select`.
private struct RipulThemeLinks: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        content.onOpenURL { RipulTheme.handleThemeLink($0) }
        #else
        content
        #endif
    }
}

#if os(iOS)
private struct RipulThemeVersionKey: EnvironmentKey {
    static let defaultValue = 0
}

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
            // A tab bar built with the window takes its labels' font from no appearance
            // setting (measured on iOS 27.0: at launch under a themed family the labels
            // were the system's, and after a change while running the theme's). Its items
            // exist a turn after the window does, so they are set then.
            guard let window, RipulTheme.hasThemedSystemText else { return }
            DispatchQueue.main.async { [weak window] in
                if let window { RipulTheme.restyleSystemText(in: window) }
            }
        }

        /// Only ever touches a window's tint while the theme has an accent of its own,
        /// and puts back what it had when it stops having one.
        func apply() {
            guard let window else { return }
            if RipulTheme.isDefault(.accent) {
                if didSet { window.tintColor = Self.appAccent; didSet = false }
            } else {
                window.tintColor = RipulTheme.platformColor(RipulTheme.color(.accent))
                didSet = true
            }
        }

        /// The app's own accent, when its asset catalogue names one. SwiftUI gives that
        /// colour to the window as its tint, so "inherit" does not bring it back: after a
        /// themed accent, a nil tint left every tinted control system blue until the next
        /// launch (measured on iOS 27.0). nil, which is "inherit", for an app with none.
        private static var appAccent: UIColor? {
            (Bundle.main.object(forInfoDictionaryKey: "NSAccentColorName") as? String).flatMap { UIColor(named: $0) }
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

// MARK: - Choosing a theme

/// A picker of the bundled themes, for a host's settings: one line where it wants the
/// choice offered. It lists every theme document in the bundle by the document's own
/// name, changes the running app, and keeps the choice.
public struct RipulThemePicker: View {
    private let title: String
    private let systemTitle: String?

    /// - Parameters:
    ///   - title: the picker's label.
    ///   - systemTitle: the row for the system look; nil to leave it out.
    public init(_ title: String = "Theme", systemTitle: String? = "System") {
        self.title = title
        self.systemTitle = systemTitle
    }

    public var body: some View {
        Picker(title, selection: Binding(get: { RipulTheme.selectedTheme }, set: { RipulTheme.select($0) })) {
            if let systemTitle { Text(systemTitle).tag(RipulTheme.systemThemeName) }
            ForEach(RipulTheme.bundledThemes) { theme in
                Text(theme.title).tag(theme.name)
            }
        }
    }
}
