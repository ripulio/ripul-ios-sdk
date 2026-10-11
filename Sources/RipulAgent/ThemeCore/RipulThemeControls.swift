import SwiftUI

// MARK: - Controls whose text the system colours or styles by itself
//
// A root cannot reach these (docs/theming.md, "What a theme root cannot reach"), so each
// has a modifier of its own. With no theme every one of them is the system's own style,
// applied exactly as the call site applied it before.

// MARK: Prominent buttons
//
// The system draws a prominent button's label white whatever the fill is. The brand's dark
// accent is a light teal, where white is 2.3 to 1, and its `onAccent` is the ink that
// reads on it. A label given a foreground style of its own keeps it inside a prominent
// button, so under a theme that names `onAccent` the label is drawn in it.

extension View {
    /// `.buttonStyle(.borderedProminent)`, with the label in the theme's `onAccent` when a
    /// theme names one.
    public func ripulProminentButtonStyle() -> some View { modifier(RipulProminentButtonModifier(glass: false)) }

    /// `.buttonStyle(.glassProminent)`, with the label in the theme's `onAccent` when a
    /// theme names one.
    @available(iOS 26.0, macOS 26.0, *)
    public func ripulGlassProminentButtonStyle() -> some View { modifier(RipulGlassProminentButtonModifier()) }
}

private struct RipulProminentButtonModifier: ViewModifier {
    let glass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if RipulTheme.isDefault(.onAccent) {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(RipulOnAccentButtonStyle(glass: false))
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct RipulGlassProminentButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if RipulTheme.isDefault(.onAccent) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(RipulOnAccentButtonStyle(glass: true))
        }
    }
}

/// The system's prominent style around the same button, its label given `onAccent`.
private struct RipulOnAccentButtonStyle: PrimitiveButtonStyle {
    let glass: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role, action: configuration.trigger) {
            RipulOnAccentLabel(label: configuration.label)
        }
        if glass, #available(iOS 26.0, macOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
}

/// A disabled prominent button is drawn grey on grey by the system: that is left alone.
private struct RipulOnAccentLabel<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let label: Label

    @ViewBuilder
    var body: some View {
        if isEnabled {
            label.foregroundStyle(.ripul(.onAccent))
        } else {
            label
        }
    }
}

// MARK: Text a control styles by itself
//
// The root gives the theme's family to text with no font of its own by setting the
// environment's font. A grouped list uses the absence of that font to choose its own for a
// section's header and footer, so under a themed family they would be drawn in the body
// font. An empty state chooses its own fonts whatever the environment holds, so it would
// stay in the system's. Each is given the system's own size and weight in the theme's
// family. With the system family they are left alone.

extension RipulTheme {
    /// True when a theme names a text family other than the system's.
    public static var hasThemedTextFamily: Bool { defaultFontOverride != nil }
}

extension View {
    /// On the content of a section's `header:` in a grouped list or form.
    public func ripulSectionHeader() -> some View { modifier(RipulThemedFamilyFont(role: .headline, weight: nil)) }

    /// On the content of a section's `footer:` in a grouped list or form.
    public func ripulSectionFooter() -> some View { modifier(RipulThemedFamilyFont(role: .footnote, weight: nil)) }

    /// On the title text of a `ContentUnavailableView`.
    public func ripulEmptyStateTitle() -> some View { modifier(RipulThemedFamilyFont(role: .title3, weight: .bold)) }

    /// On the content of a `ContentUnavailableView`'s `description:`.
    public func ripulEmptyStateDescription() -> some View { modifier(RipulThemedFamilyFont(role: .body, weight: nil)) }
}

private struct RipulThemedFamilyFont: ViewModifier {
    let role: RipulTextRole
    let weight: Font.Weight?

    @ViewBuilder
    func body(content: Content) -> some View {
        if RipulTheme.hasThemedTextFamily {
            content.font(.ripul(role, weight: weight))
        } else {
            content
        }
    }
}

/// The title of an empty state: `Label(_:systemImage:)`, its text in the theme's family.
public struct RipulEmptyStateLabel: View {
    private let title: Text
    private let systemImage: String

    public init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = Text(title)
        self.systemImage = systemImage
    }

    public init<S: StringProtocol>(_ title: S, systemImage: String) {
        self.title = Text(title)
        self.systemImage = systemImage
    }

    public var body: some View {
        Label { title.ripulEmptyStateTitle() } icon: { Image(systemName: systemImage) }
    }
}

extension ContentUnavailableView where Label == RipulEmptyStateLabel, Description == Text?, Actions == EmptyView {
    /// `ContentUnavailableView(_:systemImage:description:)`, its title in the theme's family.
    public init(themed title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init { RipulEmptyStateLabel(title, systemImage: systemImage) } description: { Self.themed(description) }
    }

    /// `ContentUnavailableView(_:systemImage:description:)`, its title in the theme's family.
    public init<S: StringProtocol>(themed title: S, systemImage: String, description: Text? = nil) {
        self.init { RipulEmptyStateLabel(title, systemImage: systemImage) } description: { Self.themed(description) }
    }

    private static func themed(_ description: Text?) -> Text? {
        RipulTheme.hasThemedTextFamily ? description?.font(.ripul(.body)) : description
    }
}

/// The content of a section's `header:`, in the theme's family.
public struct RipulSectionHeader<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { content.ripulSectionHeader() }
}

/// The content of a section's `footer:`, in the theme's family.
public struct RipulSectionFooter<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { content.ripulSectionFooter() }
}

extension Section where Parent == RipulSectionHeader<Text>, Content: View, Footer == EmptyView {
    /// `Section(_:content:)`, its title in the theme's family.
    public init(themed title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content) { RipulSectionHeader { Text(title) } }
    }

    /// `Section(_:content:)`, its title in the theme's family.
    public init<S: StringProtocol>(themed title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content) { RipulSectionHeader { Text(title) } }
    }
}
