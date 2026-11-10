import Foundation

/// The tab bar's feature button (`tabBar.featureButton`; plan
/// docs/plans/cms-tab-bar-feature-button.md, docs/cms-app-view.md "The
/// feature button"): an outsized, branded button in a slot of the bar that
/// runs an action instead of opening a tab, as WAC's centre WAC In / WAC Out
/// button does. The rules are the web's
/// (`packages/shared-types/src/cmsTabBarFeature.ts`), held equal by
/// `cmsTabBarFeature.cases.json` (CmsTabBarFeatureTests).
///
/// Its action is a card action (open a page, tab, address or record form;
/// run a mutation) or the action button's `menu`; its conditions are the
/// cards' `CmsCardCondition`, read against its query's first row.
struct CmsTabBarFeature: Equatable {
    static let sizeRange: ClosedRange<Double> = 44...88
    static let defaultSize: Double = 64
    static let liftMax: Double = 32

    struct Look: Equatable {
        var label: String?
        var showLabel: Bool?
        var icon: String?
        var image: String?
        /// A palette role's raw value, or `gradient`.
        var fill: String?
        var size: Double?
        var lift: Double?

        init(_ o: [String: CmsJSON]) {
            label = o.string("label")
            showLabel = o.bool("showLabel")
            icon = o.string("icon").flatMap { $0.isEmpty ? nil : $0 }
            image = o.string("image").flatMap { $0.isEmpty ? nil : $0 }
            fill = o.string("fill")
            size = o.double("size")
            lift = o.double("lift")
        }
    }

    /// What it does.
    enum Act: Equatable {
        case card(CmsCardAction)
        case menu(CmsJSON)

        /// `run` first, then `open`, then `menu`, as the web reads it.
        init?(_ o: [String: CmsJSON]) {
            if let run = o.string("run"), !run.isEmpty {
                self = .card(.run(run, inputs: o.object("inputs") ?? [:], pending: nil))
            } else if o.object("open") != nil, let action = CmsCardAction(.object(["open": o["open"]!])) {
                self = .card(action)
            } else if let menu = o["menu"], menu.objectValue != nil {
                self = .menu(menu)
            } else {
                return nil
            }
        }

        var kind: String {
            switch self {
            case .card(.run): return "run"
            case .card: return "open"
            case .menu: return "menu"
            }
        }
    }

    /// Press and hold: a ring fills over `seconds`, then its action runs with
    /// no confirm (WAC's hold to WAC out).
    struct Hold: Equatable {
        static let range: ClosedRange<Double> = 0.3...3
        static let defaultSeconds = 0.7
        var seconds: Double?
        var ring: String?
        var label: String?
        var act: CmsCardAction

        init?(_ json: CmsJSON?) {
            guard let o = json?.objectValue else { return nil }
            if let run = o.string("run"), !run.isEmpty {
                act = .run(run, inputs: o.object("inputs") ?? [:], pending: nil)
            } else if o.object("open") != nil, let a = CmsCardAction(.object(["open": o["open"]!])) {
                act = a
            } else {
                return nil
            }
            seconds = o.double("seconds")
            ring = o.string("ring")
            label = o.string("label")
        }
    }

    /// A variant's hold: unset keeps the button's, `null` clears it.
    enum HoldSetting: Equatable {
        case inherit
        case none
        case hold(Hold)
    }

    struct Variant: Equatable {
        var name: String
        var when: CmsCardCondition?
        var look: Look
        var act: Act?
        var hold: HoldSetting = .inherit
    }

    /// `nil` is `center`; else how many tabs come before it.
    var slot: Int?
    var query: String?
    var look: Look
    var act: Act?
    var variants: [Variant]
    var platforms: [String]?
    var hold: Hold?

    init?(_ json: CmsJSON?) {
        guard let o = json?.objectValue else { return nil }
        if case .number(let n)? = o["slot"], n == n.rounded() { slot = Int(n) } else { slot = nil }
        query = o.string("query").flatMap { $0.isEmpty ? nil : $0 }
        look = Look(o)
        act = Act(o)
        variants = (o["variants"]?.arrayValue ?? []).compactMap { v in
            guard let vo = v.objectValue else { return nil }
            let hold: HoldSetting
            switch vo["hold"] {
            case nil: hold = .inherit
            case .null?: hold = .none
            case let h?: hold = Hold(h).map(HoldSetting.hold) ?? .none
            }
            return Variant(name: vo.string("name") ?? "", when: CmsCardCondition(vo["when"]), look: Look(vo), act: Act(vo), hold: hold)
        }
        hold = Hold(o["hold"])
        platforms = o["platforms"]?.arrayValue?.compactMap(\.stringValue)
    }

    /// Drawn on the iPhone: no `platforms`, or a list naming `native`.
    var showsNatively: Bool { platforms.map { $0.contains("native") } ?? true }

    /// The queries it reads: its own and its rows conditions'.
    var queries: [String] {
        var out: [String] = query.map { [$0] } ?? []
        for v in variants { if case .rows(let q, _)? = v.when, !out.contains(q) { out.append(q) } }
        return out
    }

    // MARK: Resolving

    struct Resolved: Equatable {
        var variant: String?
        var label: String
        var showLabel: Bool
        var icon: String?
        var image: String?
        /// nil is the brand gradient.
        var fill: CmsPaletteRole?
        var size: Double
        var lift: Double
        var act: Act?
        var hold: ResolvedHold?
        /// `unknown`: a tap checks again (`act` is nil); never drawn as "not in".
        var status: Status = .ok
    }

    /// Whether the state drawn is known (the web's `FeatureStatus`): `ok` from
    /// the query's answer, `kept` (it failed, so the last state drawn stays),
    /// `unknown` (it failed with nothing drawn yet: the own look, dimmed).
    enum Status: String { case ok, kept, unknown }

    struct ResolvedHold: Equatable {
        var seconds: Double
        var ring: CmsPaletteRole
        var label: String
        var act: CmsCardAction
        var kind: String { if case .run = act { return "run" } else { return "open" } }
    }

    /// Whether a condition holds, as the web reads it: a `rows` condition on a
    /// query still loading (nil count) does not hold; a `column` one is the cards'.
    static func holds(_ when: CmsCardCondition?, row: [String: CmsJSON]?, rowCount: (String) -> Int?) -> Bool {
        guard let when else { return false }
        if case .rows(let q, let empty) = when {
            guard let n = rowCount(q) else { return false }
            return empty ? n == 0 : n > 0
        }
        return when.holds(row: row, rowCount: rowCount)
    }

    /// The look and action to draw: the first variant whose `when` holds
    /// replaces the look fields it sets, and the action when it sets one.
    ///
    /// `failed`: a query it reads failed (its message), so its answer can't say
    /// "no running shift". `previous`: the variant last drawn from a good
    /// answer (`.some(nil)` the own look; `nil` none yet).
    func resolve(row: [String: CmsJSON]?, rowCount: (String) -> Int?, failed: String? = nil, previous: String?? = nil) -> Resolved {
        if failed != nil {
            if let previous {
                var kept = resolveWith(previous.flatMap { name in variants.first { $0.name == name } })
                kept.status = .kept
                return kept
            }
            var base = resolveWith(nil)
            base.act = nil
            base.hold = nil
            base.status = .unknown
            return base
        }
        return resolveWith(variants.first { $0.when != nil && Self.holds($0.when, row: row, rowCount: rowCount) })
    }

    private func resolveWith(_ v: Variant?) -> Resolved {
        func pick<T>(_ k: KeyPath<Look, T?>) -> T? { v?.look[keyPath: k] ?? look[keyPath: k] }
        let label = pick(\.label)?.trimmingCharacters(in: .whitespaces)
        let fillRaw = pick(\.fill)
        let shownLabel = (label?.isEmpty == false ? label : nil) ?? "Action"
        let rawHold: Hold?
        switch v?.hold ?? .inherit {
        case .inherit: rawHold = hold
        case .none: rawHold = nil
        case .hold(let h): rawHold = h
        }
        let resolvedHold = rawHold.map { h in
            ResolvedHold(seconds: min(Hold.range.upperBound, max(Hold.range.lowerBound, h.seconds ?? Hold.defaultSeconds)),
                         ring: h.ring.flatMap(CmsPaletteRole.init(rawValue:)) ?? .primary,
                         label: h.label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? shownLabel,
                         act: h.act)
        }
        return Resolved(
            variant: v?.name,
            label: shownLabel,
            showLabel: pick(\.showLabel) ?? false,
            icon: pick(\.icon),
            image: pick(\.image),
            fill: fillRaw == "gradient" ? nil : (fillRaw.flatMap(CmsPaletteRole.init(rawValue:)) ?? .primary),
            size: min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, pick(\.size) ?? Self.defaultSize)),
            lift: min(Self.liftMax, max(0, pick(\.lift) ?? 0)),
            act: v?.act ?? act,
            hold: resolvedHold
        )
    }

    /// How many tabs come before it among `tabCount`: `center` is ceil(n / 2).
    static func slotIndex(_ slot: Int?, tabCount: Int) -> Int {
        let n = max(0, tabCount)
        if let slot { return min(n, max(0, slot)) }
        return (n + 1) / 2
    }

    /// The iPhone draws no lift beside an accessory: the raised disc would cover it.
    static func lift(_ lift: Double, hasAccessory: Bool) -> Double { hasAccessory ? 0 : lift }
}
