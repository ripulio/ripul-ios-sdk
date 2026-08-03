import Foundation

// MARK: - Automation Macros — data model
//
// A macro is a durable, named sequence of screen-actuation steps a developer
// records via the View Explorer (docs/plans/automation-macros/) and the agent
// later replays as a single tool call. Deliberately plain, UIKit-independent
// `Codable` types — no `#if canImport(UIKit)` anywhere in this file — so they
// compile and are testable on every platform, and round-trip cleanly to/from
// the `/v1/macros` backend (phase 3) with no translation layer.
//
// `MacroSelector` is structurally identical to the predicate shape the live
// actuation tools already accept (`id`/`text`/`role`/`class`/`within`/`nth` —
// see `ScreenActuationTools.swift`'s `ScreenElementFinder.Query` and
// `ToolSchema.Property.selector`). A macro step's selector should read as
// interchangeable with a live `tap_element` call's `within` argument, because
// both resolve through the same finder (`MacroElementResolving`, phase 0 §2).

/// A one-level anchor predicate — deliberately NOT recursive. The shipped
/// `within` argument on `tap_element`/`type_text`/`scroll_element`
/// (`ToolSchema.Property.selector`, `ScreenElementFinder.resolveAnchor`) never
/// nests a further `within` inside itself; a macro selector's anchor matches
/// that shape exactly rather than inventing arbitrary-depth nesting the live
/// tools don't support (and which a Swift value type can't self-contain
/// anyway — `MacroSelector` containing `MacroSelector` is a compile error).
public struct MacroAnchorSelector: Codable, Equatable {
    public var id: String?
    public var text: String?
    public var role: String?
    public var className: String?
    public var nth: Int?

    public init(id: String? = nil, text: String? = nil, role: String? = nil,
               className: String? = nil, nth: Int? = nil) {
        self.id = id
        self.text = text
        self.role = role
        self.className = className
        self.nth = nth
    }

    public var hasAnyPredicate: Bool {
        [id, text, role, className].contains { $0?.isEmpty == false }
    }
}

/// A durable element selector — never a `ScreenSnapshotStore` handle, which is
/// session-scoped by design and would not survive past the recording session.
public struct MacroSelector: Codable, Equatable {
    public var id: String?
    public var text: String?
    public var role: String?
    public var className: String?
    public var nth: Int?
    /// Scopes this selector to `within`'s subtree — the same "within" axis
    /// `tap_element`/`type_text`/`scroll_element` already expose.
    public var within: MacroAnchorSelector?

    public init(id: String? = nil, text: String? = nil, role: String? = nil,
               className: String? = nil, nth: Int? = nil, within: MacroAnchorSelector? = nil) {
        self.id = id
        self.text = text
        self.role = role
        self.className = className
        self.nth = nth
        self.within = within
    }

    /// At least one predicate must be present for a selector to mean anything —
    /// mirrors `ScreenElementFinder.Query.hasAnyPredicate`.
    public var hasAnyPredicate: Bool {
        [id, text, role, className].contains { $0?.isEmpty == false }
    }

    /// One-line summary of the predicates actually set, for replay logs:
    /// `role=control class=_UITabButton nth=1`. Pure string logic — no UIKit.
    public var compactSummary: String {
        var parts: [String] = []
        if let within, within.hasAnyPredicate {
            let anchor = [within.id.map { "id=\($0)" }, within.text.map { "text='\($0)'" },
                          within.role.map { "role=\($0)" }, within.className.map { "class=\($0)" }].compactMap { $0 }.joined(separator: " ")
            parts.append("within{\(anchor)}")
        }
        if let id { parts.append("id=\(id)") }
        if let text { parts.append("text='\(text)'") }
        if let role { parts.append("role=\(role)") }
        if let className { parts.append("class=\(className)") }
        if let nth { parts.append("nth=\(nth)") }
        return parts.joined(separator: " ")
    }
}

/// An element-relative tap point — the ONE sanctioned exception to "no
/// coordinates past resolve". Fractions of the element's own bounds, measured
/// from the LEADING edge (not left — an anchor recorded in an LTR layout lands
/// on the mirrored control under RTL) and the top edge. Resolved against the
/// element's LIVE frame at the moment of firing, never against a stored screen
/// position: the element moving or resizing between record and replay is the
/// normal case, not the edge case.
///
/// Recorded only when the point genuinely disambiguated the tap (two wired
/// controls inside one nameable container — see
/// `ScreenActuationEngine.ResolvedTarget.pointMattered`). A tap whose target
/// is fully named by its selector carries no anchor: the exception must stay
/// exceptional, or every step silently becomes a coordinate tap again.
public struct MacroAnchor: Codable, Equatable {
    /// Fraction of the element's width from its leading edge, clamped 0…1.
    public var leading: Double
    /// Fraction of the element's height from its top edge, clamped 0…1.
    public var top: Double

    public init(leading: Double, top: Double) {
        self.leading = min(max(leading, 0), 1)
        self.top = min(max(top, 0), 1)
    }

    /// Synthesize from an absolute point and the element's frame, both in the
    /// same coordinate space. Nil for a degenerate frame — a zero-area element
    /// has no interior to be a fraction of.
    public static func fraction(x: Double, y: Double,
                                frameX: Double, frameY: Double,
                                width: Double, height: Double,
                                rightToLeft: Bool) -> MacroAnchor? {
        guard width > 0, height > 0 else { return nil }
        let fromLeft = (x - frameX) / width
        return MacroAnchor(leading: rightToLeft ? 1 - fromLeft : fromLeft,
                           top: (y - frameY) / height)
    }

    /// The absolute point this anchor names inside a (live) frame, in the
    /// frame's own coordinate space.
    public func point(frameX: Double, frameY: Double,
                      width: Double, height: Double,
                      rightToLeft: Bool) -> (x: Double, y: Double) {
        let fromLeft = rightToLeft ? 1 - leading : leading
        return (x: frameX + width * fromLeft, y: frameY + height * top)
    }

    /// "80%,50%" — for step labels and replay logs.
    public var compactSummary: String {
        "\(Int((leading * 100).rounded()))%,\(Int((top * 100).rounded()))%"
    }
}

public enum MacroStepKind: String, Codable {
    case tap, type, scroll, wait
    /// Set a value-bearing control directly — a date picker, switch, slider,
    /// stepper, segmented control or picker wheel. Recorded as the VALUE
    /// rather than as a gesture: spinning a wheel cannot be replayed through
    /// public API, and the value is what the step actually means.
    case setValue
    /// A fixed-duration pause ("settle time") — not an element wait: it
    /// always succeeds after `seconds`, never fails on a condition. Inserted
    /// from the macro editor between steps (e.g. let an animation finish).
    case pause
}

/// One recorded action. Fields not relevant to `kind` are simply nil — kept as
/// a single flat type (rather than an enum with associated values) so it
/// serializes to a stable, self-describing JSON shape the backend and the
/// recording UI both read directly, with no custom `Codable` implementation.
public struct MacroStep: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: MacroStepKind
    public var selector: MacroSelector

    /// `.type` — the payload to type; may contain `{{paramName}}` tokens
    /// (see `MacroParameterSubstitution`). `.wait` uses this only if a
    /// human-authored macro wants a fixed literal wait target description;
    /// normally `.wait` steps are addressed by `selector` alone.
    public var text: String?
    /// `.type` — append to existing content instead of replacing it.
    public var append: Bool?
    /// `.scroll` — up | down | left | right.
    public var direction: String?
    /// `.scroll` — fraction of the visible size, 0.1–2.0.
    public var amount: Double?
    /// `.wait` — "visible" | "gone".
    public var state: String?
    /// `.wait` — seconds to wait before giving up.
    public var timeout: Double?
    /// `.pause` — seconds to sleep. Kept separate from `timeout`: a pause
    /// always succeeds after this long, it is not a deadline on a condition.
    public var seconds: Double?
    /// `.tap` — element-relative tap point, present only when the recorded
    /// point disambiguated between several pressable things inside the
    /// selector's element. See `MacroAnchor`.
    public var anchor: MacroAnchor?

    /// Human-readable, captured at record time (e.g. "Tap 'Clock In' (button)")
    /// — shown in the recording UI's step list and folded into the synthesized
    /// tool's description (phase 1) so the agent knows what a macro does
    /// without replaying it blind.
    public var recordedLabel: String

    public init(id: String = UUID().uuidString, kind: MacroStepKind, selector: MacroSelector,
               text: String? = nil, append: Bool? = nil, direction: String? = nil, amount: Double? = nil,
               state: String? = nil, timeout: Double? = nil, seconds: Double? = nil,
               anchor: MacroAnchor? = nil, recordedLabel: String) {
        self.id = id
        self.kind = kind
        self.selector = selector
        self.text = text
        self.append = append
        self.direction = direction
        self.amount = amount
        self.state = state
        self.timeout = timeout
        self.seconds = seconds
        self.anchor = anchor
        self.recordedLabel = recordedLabel
    }
}

/// A named, agent-invocable parameter. Declared by name; referenced inside a
/// `.type` step's `text` as `{{name}}`. The synthesized tool's `inputSchema`
/// (phase 1) has one string property per parameter.
public struct MacroParameter: Codable, Equatable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// The persisted macro. `published` gates which audience can call the
/// synthesized tool (`.developer` while false, `.endUser` once true — phase 4)
/// — a macro is never born published; only an explicit publish action sets it.
public struct RipulMacro: Codable, Equatable, Identifiable {
    public var id: String
    /// Slug; becomes the tool name suffix `run_macro_<name>` (phase 1).
    public var name: String
    /// Shown to the agent as the tool description's lead line.
    public var description: String
    public var steps: [MacroStep]
    public var parameters: [MacroParameter]
    public var published: Bool
    public var siteKeyId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String, description: String, steps: [MacroStep],
               parameters: [MacroParameter] = [], published: Bool = false, siteKeyId: String? = nil,
               createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.description = description
        self.steps = steps
        self.parameters = parameters
        self.published = published
        self.siteKeyId = siteKeyId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
