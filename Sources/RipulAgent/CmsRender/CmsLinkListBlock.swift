import SwiftUI

/// The `linkList` block ("Link list"): rows that each open a page, like a
/// settings screen. Built from the nav item model (`items: NavItem[]`): the
/// icon in the style's badge (or a picture from the item's `image.chain`,
/// falling back to the icon), the label, `description` as the subtitle, the
/// badge, and the chevron as the list style says. A row opens its page through
/// the runtime (inside `CmsAppView`, pushed on the tab's stack) or its url.
/// An item with `heading: true` starts a section under that heading. Who sees
/// a row is the nav blocks' rule (`visibility`, `requiredRoles`). Children,
/// actions other than links and slots are ignored.
struct CmsLinkListBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.openURL) private var openURL
    /// Runs a row's swipe actions (an item's `swipe`, CmsSwipe).
    @StateObject private var swipeRunner = CmsRowActionRunner()

    var body: some View {
        let style = runtime.listStyle(for: block)
        let sections = CmsLinkList.sections(
            CmsNavItem.visible(CmsNavItem.decodeList(block.props["items"]),
                               membership: runtime.membership, canDesign: runtime.canDesign)
        )
        VStack(alignment: .leading, spacing: style.layout == .cards ? style.gap + 8 : 20) {
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                VStack(alignment: .leading, spacing: 6) {
                    if let heading = section.heading {
                        CmsListSectionHeader(style: style, title: heading)
                            .cmsInspectorID("Cms.linkList.heading")
                    }
                    CmsStyledRows(style: style, items: section.rows,
                                  separatorInset: separatorInset(style, rows: section.rows),
                                  swipe: swipeSet) { item in
                        row(item, style: style)
                    }
                }
            }
        }
        .modifier(CmsRowActionRunnerPresenter(runner: swipeRunner, runtime: runtime))
        .cmsInspectorID("Cms.linkList")
    }

    /// An item's swipe actions, read against the item's own fields (it has no data row).
    private func swipeSet(_ item: CmsNavItem) -> GlassSwipeSet {
        guard let config = item.fields["swipe"], config.objectValue != nil else { return .none }
        return CmsSwipe.glassSet(CmsSwipe.resolve(config, row: item.fields), theme: runtime.theme,
                                 key: "linkList.\(item.label)") { action in
            swipeRunner.perform(action, row: item.fields, query: nil, runtime: runtime, openURL: { openURL($0) })
        }
    }

    private func separatorInset(_ style: CmsResolvedListStyle, rows: [CmsNavItem]) -> CGFloat {
        // Separators start under the text, as in Settings, when rows have pictures.
        guard rows.contains(where: { CmsNavIcon.symbol(for: $0.icon) != nil || !$0.pictureCandidates.isEmpty }) else {
            return style.paddingHorizontal
        }
        let picture = style.badge == .none ? style.pictureSize : style.badgeSize
        return style.paddingHorizontal + picture + 12
    }

    private func row(_ item: CmsNavItem, style: CmsResolvedListStyle) -> some View {
        Button {
            item.perform(runtime: runtime, openURL: openURL)
        } label: {
            CmsListRowContent(
                style: style,
                title: item.label,
                subtitle: item.description,
                picture: CmsNavIcon.symbol(for: item.icon).map(CmsListPicture.symbol),
                pictureCandidates: item.pictureCandidates,
                navigates: item.targetPageSlug != nil || item.url != nil
            ) {
                if let badge = item.badgeText(runtime: runtime) {
                    CmsNavBadge(text: badge, tone: item.badgeTone)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cms.linkList.\(item.targetPageSlug ?? item.label)")
        .cmsInspectorID("Cms.linkList.row")
    }
}

enum CmsLinkList {
    struct Section {
        var heading: String?
        var rows: [CmsNavItem]
    }

    /// Rows grouped under their headings. Rows before the first heading form a
    /// section with no heading; a heading with no rows after it is dropped.
    /// Only links count as rows: other actions, and children, are ignored.
    static func sections(_ items: [CmsNavItem]) -> [Section] {
        var out: [Section] = []
        var current = Section(heading: nil, rows: [])
        for item in items {
            if item.heading {
                if !current.rows.isEmpty { out.append(current) }
                current = Section(heading: item.label.isEmpty ? nil : item.label, rows: [])
            } else if item.actionType == "link" {
                var row = item
                row.children = []
                current.rows.append(row)
            }
        }
        if !current.rows.isEmpty { out.append(current) }
        return out
    }
}
