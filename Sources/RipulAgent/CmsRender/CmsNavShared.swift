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
            divider: obj.bool("divider") ?? false
        )
    }

    static func decodeList(_ json: CmsJSON?) -> [CmsNavItem] {
        guard case .array(let raw)? = json else { return [] }
        return raw.compactMap(decode)
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
