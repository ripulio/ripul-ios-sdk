import SwiftUI

// MARK: - Lists
//
// A grouped list draws its own ground, its rows' cards and its separators in the system's
// colours, and no root reaches them (docs/theming-for-hosts.md, "Lists"). These carry the
// theme's `surfaceSunken`, `surface` and `separator` to a list. Each is written so that
// with no theme it sets the system's own value: an automatic scroll background, no
// background view, a nil row background and a nil separator tint, which are what a list
// has when nothing is written.

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
    func body(content: Content) -> some View {
        let themed = !RipulTheme.isDefault(.surfaceSunken)
        return content
            .scrollContentBackground(themed ? .hidden : .automatic)
            .background { if themed { Color.ripul(.surfaceSunken).ignoresSafeArea() } }
    }
}

private struct RipulThemedListRows: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(RipulTheme.isDefault(.surface) ? nil : Color.ripul(.surface))
            .listRowSeparatorTint(RipulTheme.isDefault(.separator) ? nil : Color.ripul(.separator))
            .listSectionSeparatorTint(RipulTheme.isDefault(.separator) ? nil : Color.ripul(.separator))
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
