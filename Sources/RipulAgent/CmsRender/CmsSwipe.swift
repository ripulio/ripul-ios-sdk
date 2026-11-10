import SwiftUI

/// Swipe actions on a CMS row or card (the web's `cmsSwipe.ts`; docs/cms-swipe-actions.md).
///
/// A config is `{ leading?: [action], trailing?: [action], fullSwipe?: leading|trailing|both }`.
/// An action is a label, an icon, a palette role colour, `role: destructive`,
/// a `confirm` text, a `when` row condition, and a `run` (with `inputs`) or an
/// `open` (page, form or https link): the cards buttons' action shapes.
/// Resolved by the rules held to `cmsSwipe.cases.json`, then drawn by the
/// shared list (`GlassSwipeList`, `glassSwipeActions`) as the system's swipe
/// actions and VoiceOver actions.
enum CmsSwipe {
    static let maxActions = 3

    struct Action: Equatable {
        /// Its place in its set as written.
        var index: Int
        var label: String
        var icon: String?
        var color: CmsPaletteRole
        var destructive: Bool
        var confirm: String?
        var action: CmsCardAction
    }

    struct Resolved: Equatable {
        var leading: [Action] = []
        var trailing: [Action] = []
        var fullSwipeLeading = false
        var fullSwipeTrailing = false
        var isEmpty: Bool { leading.isEmpty && trailing.isEmpty }
    }

    /// The action part, when it is one a swipe can do: a run, or an open of a page, a form or an https link.
    static func action(_ o: [String: CmsJSON]) -> CmsCardAction? {
        if let run = o.string("run"), !run.trimmingCharacters(in: .whitespaces).isEmpty {
            return .run(run, inputs: o.object("inputs") ?? [:], pending: nil)
        }
        guard let open = o.object("open") else { return nil }
        if let page = open.string("page"), !page.trimmingCharacters(in: .whitespaces).isEmpty {
            return .openPage(page, params: open.object("params") ?? [:])
        }
        if let form = CmsRowFormSpec(open["form"]) { return .openForm(form) }
        if let url = open.string("url"), url.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("https://")
            || url.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://") {
            return .openURL(url)
        }
        // A page inside the app (CmsWebPage): an https address or a template whose slots fill it.
        if let web = open.string("web")?.trimmingCharacters(in: .whitespaces),
           web.lowercased().hasPrefix("https://") || web.hasPrefix("{") {
            return .openWeb(web, title: open.string("title"))
        }
        return nil
    }

    private static func set(_ json: CmsJSON?, row: [String: CmsJSON]) -> [Action] {
        guard case .array(let list)? = json else { return [] }
        var out: [Action] = []
        for (index, raw) in list.enumerated() {
            guard out.count < maxActions, let o = raw.objectValue else { continue }
            let label = (o.string("label") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, let action = action(o) else { continue }
            if o["when"] != nil {
                guard let when = CmsRowCondition(o["when"]), when.holds(row) else { continue }
            }
            let destructive = o.string("role") == "destructive"
            let own = o.string("color").flatMap(CmsPaletteRole.init(rawValue:))
            let confirm = o.string("confirm")?.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Action(index: index, label: label,
                              icon: o.string("icon").flatMap { $0.isEmpty ? nil : $0 },
                              color: own ?? (destructive ? .error : .primary),
                              destructive: destructive,
                              confirm: (confirm?.isEmpty ?? true) ? nil : confirm,
                              action: action))
        }
        return out
    }

    /// A row's swipe actions under the shared rules.
    static func resolve(_ config: CmsJSON?, row: [String: CmsJSON]) -> Resolved {
        guard let o = config?.objectValue else { return Resolved() }
        let leading = set(o["leading"], row: row)
        let trailing = set(o["trailing"], row: row)
        let full = o.string("fullSwipe")
        return Resolved(leading: leading, trailing: trailing,
                        fullSwipeLeading: !leading.isEmpty && (full == "leading" || full == "both"),
                        fullSwipeTrailing: !trailing.isEmpty && (full == "trailing" || full == "both"))
    }

    /// An action's SF Symbol: a nav icon key mapped as the nav does, else the name as written.
    static func symbol(_ icon: String?) -> String? {
        guard let icon, !icon.isEmpty else { return nil }
        return CmsNavIcon.symbol(for: icon) ?? icon
    }

    /// The resolved actions as the shared list's swipe set; `perform` runs one.
    static func glassSet(_ resolved: Resolved, theme: CmsPortalTheme, key: String,
                         perform: @escaping (Action) -> Void) -> GlassSwipeSet {
        func button(_ a: Action, side: String) -> GlassSwipeAction {
            GlassSwipeAction(id: "\(key).\(side).\(a.index)", label: a.label, systemImage: symbol(a.icon),
                             tint: theme.color(role: a.color), destructive: a.destructive) { perform(a) }
        }
        return GlassSwipeSet(leading: resolved.leading.map { button($0, side: "leading") },
                             trailing: resolved.trailing.map { button($0, side: "trailing") },
                             fullSwipeLeading: resolved.fullSwipeLeading,
                             fullSwipeTrailing: resolved.fullSwipeTrailing)
    }
}

/// A stable key for a row's swipe buttons: its id, else its values.
enum CmsSwipeRowKey {
    static func of(_ row: [String: CmsJSON]) -> String {
        for k in ["id", "uuid", "key"] { if let v = row[k], v != .null { return v.displayString } }
        return String(row.keys.sorted().map { "\($0)=\(row[$0]?.displayString ?? "")" }.joined(separator: "&").hashValue)
    }
}
