import SwiftUI

// MARK: - Lists
//
// A grouped list draws its own ground, its rows' cards and its separators in the system's
// colours, and no root reaches them (docs/theming-for-hosts.md, "Lists"). These carry the
// theme's `surfaceSunken`, `surface` and `separator` to a list. With no theme, and under
// a theme that names none of the three, each leaves the list exactly as it is.

extension View {
    /// On a `List` or a `Form`: its ground in the theme's `surfaceSunken`, and its rows
    /// and separators in `surface` and `separator`. A row that sets a background of its
    /// own keeps it.
    public func ripulThemedList() -> some View { modifier(RipulThemedListGround()) }

    /// On the content of a list, a section or a row: the rows' background in the theme's
    /// `surface` and their separators in `separator`. `ripulThemedList()` cannot reach
    /// the rows from outside the list, so a list themed by a modifier needs this inside.
    public func ripulThemedListRows() -> some View { modifier(RipulThemedListRows()) }
}

private struct RipulThemedListGround: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        // Untouched until a theme names the ground: not even the system's own values are
        // set, so a list that sets its own (a hidden background, a clear row) keeps them.
        if RipulTheme.isDefault(.surfaceSunken) {
            content
        } else {
            content
                .scrollContentBackground(.hidden)
                .background { Color.ripul(.surfaceSunken).ignoresSafeArea() }
        }
    }
}

private struct RipulThemedListRows: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        let surface = !RipulTheme.isDefault(.surface)
        let separator = !RipulTheme.isDefault(.separator)
        if !surface && !separator {
            content
        } else {
            content
                .listRowBackground(surface ? Color.ripul(.surface) : nil)
                .listRowSeparatorTint(separator ? Color.ripul(.separator) : nil)
                .listSectionSeparatorTint(separator ? Color.ripul(.separator) : nil)
        }
    }
}

// MARK: Text with no colour of its own, in source that was migrated

extension View {
    /// On a `Text` that has no colour of its own: the theme's `text` colour once a theme
    /// names one. Until then the text is left exactly as it is, so a text that takes its
    /// colour from a view round it, in this file or another, still does.
    /// `ripul-theme migrate --text` writes it; the redirect plug-in does the same with no line.
    public func ripulText() -> some View { modifier(RipulBareText()) }
}

private struct RipulBareText: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if RipulTheme.isDefault(.text) {
            content
        } else {
            content.foregroundStyle(.ripul(.text))
        }
    }
}

// MARK: Lists in source nobody edited
//
// What the redirect plug-in's generated `List`, `Form` and `Section` put round the host's
// own (tools/redirect/RipulThemeRedirect.swift.txt).

extension RipulThemeRedirect {
    /// Round a host's `List` or `Form`.
    public static func list<Content: View>(_ list: Content) -> some View { list.ripulThemedList() }

    /// Round the content of a host's `List`, `Form` or `Section`.
    public static func rows<Content: View>(_ content: Content) -> some View { content.ripulThemedListRows() }

    /// Round the header of a host's `Section`.
    public static func sectionHeader<Content: View>(_ header: Content) -> some View { header.ripulSectionHeader() }

    /// Round the footer of a host's `Section`.
    public static func sectionFooter<Content: View>(_ footer: Content) -> some View { footer.ripulSectionFooter() }
}
