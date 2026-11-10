#if os(iOS)
import SwiftUI

// MARK: - A host app's own screens in a site's list style
//
// Inside `CmsAppView` the site's theme reaches the host's tabs, so a host
// screen matches the site's lists with two modifiers:
//
//     List {
//         Section("Account") {
//             CmsListRow("Email", systemImage: "envelope", trailing: email)
//                 .cmsListRow()
//         }
//         Section {
//             Button(role: .destructive) { signOut() } label: {
//                 CmsListRow("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive)
//             }
//             .cmsListRow()
//         }
//     }
//     .cmsListStyle()          // the site's defaultListStyle; or .cmsListStyle("wac")
//
// Outside `CmsAppView`, give the screen a site's theme with
// `.cmsSiteTheme(config)`. With no theme, everything draws as `system`:
// iOS's own inset grouped list.

private struct CmsSiteThemeKey: EnvironmentKey {
    static let defaultValue: CmsPortalThemeConfig? = nil
}

private struct CmsListStyleKey: EnvironmentKey {
    static let defaultValue: CmsResolvedListStyle? = nil
}

extension EnvironmentValues {
    /// The CMS site's theme for a host screen. `CmsAppView` sets it on its
    /// host tabs.
    public var cmsSiteTheme: CmsPortalThemeConfig? {
        get { self[CmsSiteThemeKey.self] }
        set { self[CmsSiteThemeKey.self] = newValue }
    }

    /// The list style `cmsListStyle(_:)` resolved, for rows to read.
    public internal(set) var cmsListStyle: CmsResolvedListStyle? {
        get { self[CmsListStyleKey.self] }
        set { self[CmsListStyleKey.self] = newValue }
    }
}

extension View {
    /// Give this screen a CMS site's theme (`CmsAppView` does this for its host tabs).
    public func cmsSiteTheme(_ config: CmsPortalThemeConfig?) -> some View {
        environment(\.cmsSiteTheme, config)
    }

    /// Draw this `List` in the site's list style: `name` when given (a
    /// built-in or one of the site's own), else the site's `defaultListStyle`,
    /// else `system`. Put `cmsListRow()` on each row.
    public func cmsListStyle(_ name: String? = nil) -> some View {
        modifier(CmsListStyleModifier(name: name))
    }

    /// A row of a `List` drawn with `cmsListStyle(_:)`: its background (a
    /// card, for `cards`), separators, padding and height.
    public func cmsListRow() -> some View {
        modifier(CmsListRowModifier())
    }
}

private struct CmsListStyleModifier: ViewModifier {
    let name: String?
    @Environment(\.cmsSiteTheme) private var config
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let style = CmsResolvedListStyle(config: config, block: name, dark: colorScheme == .dark)
        let explicit = style.explicit
        Group {
            switch style.layout {
            case .system:
                // iOS's own inset grouped list. Only what the site set changes it.
                content
                    .listStyle(.insetGrouped)
                    .modifier(CmsListPageBackground(color: explicit.card?.pageBackground.flatMap(style.color)))
            case .plain:
                content
                    .listStyle(.plain)
                    .modifier(CmsListPageBackground(color: style.pageBackground))
            case .cards:
                // Grouped keeps a section's space and header; the rows draw
                // their own cards (cmsListRow), so its row look never shows.
                content
                    .listStyle(.grouped)
                    .listRowSpacing(style.gap)
                    .listSectionSpacing(.custom(max(style.gap * 2, 20)))
                    .modifier(CmsListPageBackground(color: style.pageBackground))
            }
        }
        .environment(\.defaultMinListRowHeight, style.layout == .system && explicit.row?.minHeight == nil
                     ? 44 : style.minHeight)
        .environment(\.cmsListStyle, style)
    }
}

private struct CmsListPageBackground: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color {
            content.scrollContentBackground(.hidden).background(color)
        } else {
            content
        }
    }
}

private struct CmsListRowModifier: ViewModifier {
    @Environment(\.cmsListStyle) private var style

    func body(content: Content) -> some View {
        if let style {
            switch style.layout {
            case .system:
                let explicit = style.explicit
                content
                    .modifier(CmsOptionalRowBackground(color: explicit.card?.fill.flatMap(style.color)))
                    .listRowSeparator(explicit.row?.separators == false ? .hidden : .automatic)
                    .modifier(CmsOptionalRowInsets(insets: explicit.row?.paddingVertical == nil
                        && explicit.row?.paddingHorizontal == nil ? nil : insets(style, outer: 0)))
            case .plain:
                content
                    .listRowBackground(style.fill)
                    .listRowSeparator(style.separators ? .visible : .hidden)
                    .listRowInsets(insets(style, outer: 0))
            case .cards:
                content
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                            .fill(style.fill)
                            .overlay {
                                if style.borderWidth > 0 {
                                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                                        .strokeBorder(style.borderColor, lineWidth: style.borderWidth)
                                }
                            }
                            .shadow(color: style.hasShadow ? style.shadowColor : .clear,
                                    radius: style.shadowRadius, y: style.shadowOffsetY)
                            .padding(.horizontal, CmsListHostMetrics.cardMargin)
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(insets(style, outer: CmsListHostMetrics.cardMargin))
            }
        } else {
            content
        }
    }

    private func insets(_ style: CmsResolvedListStyle, outer: CGFloat) -> EdgeInsets {
        EdgeInsets(top: style.paddingVertical, leading: outer + style.paddingHorizontal,
                   bottom: style.paddingVertical, trailing: outer + style.paddingHorizontal)
    }
}

enum CmsListHostMetrics {
    /// The space between a card and the screen's edge: the inset grouped margin.
    static let cardMargin: CGFloat = 16
}

private struct CmsOptionalRowBackground: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color { content.listRowBackground(color) } else { content }
    }
}

private struct CmsOptionalRowInsets: ViewModifier {
    let insets: EdgeInsets?
    func body(content: Content) -> some View {
        if let insets { content.listRowInsets(insets) } else { content }
    }
}

/// A row's content in the site's list style: a picture (an SF Symbol) in the
/// style's badge, a title, a subtitle, a trailing value and, for a row that
/// opens something, the chevron. Inside a `NavigationLink` leave `navigates`
/// off: the list draws the link's own chevron.
public struct CmsListRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let trailing: String?
    let navigates: Bool
    let role: ButtonRole?
    @Environment(\.cmsListStyle) private var listStyle
    @Environment(\.cmsSiteTheme) private var config
    @Environment(\.colorScheme) private var colorScheme

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = nil,
                trailing: String? = nil, navigates: Bool = false, role: ButtonRole? = nil) {
        self.title = title; self.subtitle = subtitle; self.systemImage = systemImage
        self.trailing = trailing; self.navigates = navigates; self.role = role
    }

    public var body: some View {
        let style = listStyle ?? CmsResolvedListStyle(config: config, block: nil, dark: colorScheme == .dark)
        CmsListRowContent(
            style: style,
            title: title,
            titleColor: role == .destructive ? style.color(.error) : nil,
            subtitle: subtitle,
            picture: systemImage.map(CmsListPicture.symbol),
            trailing: trailing,
            navigates: navigates
        )
        // The List row (cmsListRow) already pads; the content adds none of its own.
        .environment(\.cmsListRowInList, true)
    }
}

#endif
