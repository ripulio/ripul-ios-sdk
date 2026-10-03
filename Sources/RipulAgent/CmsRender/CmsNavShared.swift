import SwiftUI

/// Twin of `navShared.tsx`'s NavItem — ONE recursive item model shared by
/// the Top Nav and Sidebar Nav twins, decoded from raw persisted props.
struct CmsNavItem: Identifiable {
    let id = UUID()
    var label: String
    var icon: String?
    var targetPageSlug: String?
    /// `<gridSlug>:<viewId>` — carried with the navigation; the target
    /// page's gridViewSwitcher pre-selects that view on arrival.
    var targetViewRef: String?
    var url: String?
    /// 'link' (default) navigates; 'switchGridView' runs natively;
    /// 'mutation'/'exportSheet'/'exportAllSheets' need machinery that has
    /// no native twin yet — those items render disabled.
    var actionType: String
    var targetGridId: String?
    var targetViewId: String?
    var children: [CmsNavItem]
    var align: String?
    var divider: Bool
    /// Group heading — a non-tappable label over a group (its children, or
    /// the entries after it up to the next heading). A bar shows a separator.
    var heading: Bool = false
    /// Small pill text ("New", "Due Fri", a count). May hold `@query.column`
    /// tokens — resolve with `badgeText(runtime:)`.
    var badge: String? = nil
    /// neutral | primary | warning | error | success (nil = per-context default).
    var badgeTone: String? = nil
    /// Top bar: icon-only entry (the label becomes the accessibility label).
    var iconOnly: Bool = false

    static func decode(_ json: CmsJSON) -> CmsNavItem? {
        guard let obj = json.objectValue else { return nil }
        // Authoring slot placeholders resolve via portal-shell contributions
        // on the web — no native twin, so they render as nothing.
        if obj.string("slotId") != nil { return nil }
        return CmsNavItem(
            label: obj.string("label") ?? "",
            icon: obj.string("icon"),
            targetPageSlug: obj.string("targetPageSlug").flatMap { $0.isEmpty ? nil : $0 },
            targetViewRef: obj.string("targetViewRef").flatMap { $0.isEmpty ? nil : $0 },
            url: obj.string("url").flatMap { $0.isEmpty ? nil : $0 },
            actionType: obj.string("actionType") ?? "link",
            targetGridId: obj.string("targetGridId"),
            targetViewId: obj.string("targetViewId"),
            children: decodeList(obj["children"]),
            align: obj.string("align"),
            divider: obj.bool("divider") ?? false,
            heading: obj.bool("heading") ?? false,
            badge: obj.string("badge"),
            badgeTone: obj.string("badgeTone"),
            iconOnly: obj.bool("iconOnly") ?? false
        )
    }

    static func decodeList(_ json: CmsJSON?) -> [CmsNavItem] {
        guard case .array(let raw)? = json else { return [] }
        return tidy(raw.compactMap(decode))
    }

    /// Mirror of the web's `tidyNavItems` heading rule: a heading with no
    /// children of its own whose following run (same placement zone, up to
    /// the next heading) is empty is dropped, so no label sits over nothing.
    static func tidy(_ items: [CmsNavItem]) -> [CmsNavItem] {
        items.enumerated().filter { index, item in
            guard item.heading, item.children.isEmpty else { return true }
            for sibling in items[(index + 1)...] where sibling.align == item.align {
                return !sibling.heading
            }
            return false
        }.map(\.element)
    }

    /// Menus group by `Section`, so give each flat heading (one without
    /// children) the run of entries after it, up to the next heading — the
    /// web's group rule made structural.
    static func foldHeadings(_ items: [CmsNavItem]) -> [CmsNavItem] {
        var out: [CmsNavItem] = []
        var open: CmsNavItem?
        for item in items {
            if item.heading {
                if let group = open { out.append(group) }
                if item.children.isEmpty {
                    open = item
                } else {
                    open = nil
                    out.append(item)
                }
            } else if open != nil {
                open?.children.append(item)
            } else {
                out.append(item)
            }
        }
        if let group = open { out.append(group) }
        return out
    }

    /// The badge to show: tokens resolved; nil when blank, "0", or a token
    /// still unresolved (never leak `@query.column` into a pill).
    @MainActor
    func badgeText(runtime: CmsRuntime) -> String? {
        guard let raw = badge else { return nil }
        let text = runtime.resolveTemplate(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "0" { return nil }
        if text.contains(#/@[A-Za-z_]\w*\.[A-Za-z_]\w*/#) { return nil }
        return text
    }

    var isActive: Bool { false } // active = current page; computed at render

    /// Can the native renderer act on this item today?
    var isActionable: Bool {
        switch actionType {
        case "link": return targetPageSlug != nil || url != nil || !children.isEmpty
        case "switchGridView": return targetGridId != nil && targetViewId != nil
        default: return false // mutation / exports await the mutations client
        }
    }

    /// Perform the item's action. Returns false when nothing ran.
    @MainActor
    @discardableResult
    func perform(runtime: CmsRuntime, openURL: OpenURLAction) -> Bool {
        switch actionType {
        case "switchGridView":
            guard let grid = targetGridId, let view = targetViewId else { return false }
            runtime.gridViewRequest = CmsRuntime.GridViewRequest(gridId: grid, viewId: view)
            return true
        case "link":
            if let slug = targetPageSlug {
                runtime.navigate(toPage: slug, viewRef: targetViewRef)
                return true
            }
            if let url = url.flatMap(URL.init(string:)) {
                openURL(url)
                return true
            }
            return false
        default:
            return false
        }
    }
}

/// A nav entry's badge (navShared.tsx `NavBadge`): a soft-tint pill with
/// tone-coloured text, or — `bubble` — a solid count for an icon's corner.
struct CmsNavBadge: View {
    let text: String
    let tone: String?
    var bubble: Bool = false
    @EnvironmentObject var runtime: CmsRuntime

    private var colors: (bg: Color, fg: Color) {
        let theme = runtime.theme
        let resolved = tone ?? (bubble ? "primary" : "neutral")
        let toneColor: Color? = {
            switch resolved {
            case "primary": return theme.primary
            case "warning": return theme.warning
            case "error": return theme.error
            case "success": return theme.success
            default: return nil
            }
        }()
        guard let toneColor else {
            return bubble
                ? (theme.textSecondary, theme.paper)
                : (theme.textPrimary.opacity(theme.isDark ? 0.12 : 0.07), theme.textSecondary)
        }
        if bubble {
            return (toneColor, resolved == "primary" ? theme.primaryContrast : .white)
        }
        return (toneColor.opacity(theme.isDark ? 0.22 : 0.13), toneColor)
    }

    var body: some View {
        let c = colors
        Text(text)
            .font(.system(size: bubble ? 10 : 11, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(c.fg)
            .padding(.horizontal, bubble ? 4 : 7)
            .frame(minWidth: bubble ? 16 : nil, minHeight: bubble ? 16 : 20)
            .background(Capsule().fill(c.bg))
            .cmsInspectorID(bubble ? "Cms.nav.badgeBubble" : "Cms.nav.badge")
    }
}

/// The nav icon registry (`iconRegistry.tsx` NAV_ICONS keys) mapped to SF
/// Symbols — semantic equivalents, not glyph clones. Unknown keys render
/// no icon, like an unset one.
enum CmsNavIcon {
    static let symbols: [String: String] = [
        "home": "house",
        "dashboard": "square.grid.2x2",
        "settings": "gearshape",
        "person": "person",
        "group": "person.2",
        "search": "magnifyingglass",
        "star": "star",
        "favorite": "heart",
        "notifications": "bell",
        "mail": "envelope",
        "folder": "folder",
        "document": "doc.text",
        "chart": "chart.bar",
        "table": "tablecells",
        "cart": "cart",
        "store": "bag",
        "payment": "creditcard",
        "receipt": "list.bullet.rectangle",
        "calendar": "calendar",
        "event": "calendar.badge.clock",
        "chat": "message",
        "help": "questionmark.circle",
        "info": "info.circle",
        "build": "wrench.and.screwdriver",
        "code": "chevron.left.forwardslash.chevron.right",
        "cloud": "cloud",
        "lock": "lock",
        "key": "key",
        "map": "map",
        "place": "mappin.and.ellipse",
        "phone": "phone",
        "link": "link",
        "add": "plus",
        "edit": "pencil",
        "delete": "trash",
        "download": "arrow.down.circle",
        "upload": "arrow.up.circle",
        "visibility": "eye",
        "menu": "line.3.horizontal",
        "account": "person.crop.circle",
        "logout": "rectangle.portrait.and.arrow.right",
        "login": "arrow.right.square",
        "apps": "square.grid.3x3",
        "category": "rectangle.3.group",
        "layers": "square.3.stack.3d",
        "bookmark": "bookmark",
        "flag": "flag",
        "language": "globe",
        "business": "building.2",
        "work": "briefcase",
        "school": "graduationcap",
    ]

    static func symbol(for key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return symbols[key]
    }
}
