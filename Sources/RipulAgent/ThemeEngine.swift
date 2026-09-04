#if os(iOS)
import UIKit

// MARK: - Theme engine (generic-over-vocabulary theme system)
//
// The SDK owns the theme ENGINE — colour resolution (3 tiers: primitives → semantic labels
// → component tokens, with aliasing + cycle protection), the style-cascade RULE (per-element
// override ?? named style ?? the kind's default tier), live apply/broadcast, and the UIKit
// repaint walker. The HOST owns the vocabulary: token names, palette, style kinds and their
// knob schemas, registered as data at launch (`RipulThemeEngine.configure`).
//
// Persistence partition: the host owns its theme BLOB (a JSON document that may carry
// host-only sections the engine never sees). The engine decodes only its slice, using the
// persisted key names declared in the spec. The engine therefore never WRITES the blob —
// `adopt(_:)` sets live state + broadcasts + repaints, and the host persists its own
// document (it has the whole picture). This keeps host extras byte-safe with zero
// migration and zero knowledge of host formats in the SDK.
//
// Colour tagging: resolved colours are tagged (`ripulTagged`) with the OUTERMOST token
// name at every chokepoint, so the View Explorer names what any element is themed with —
// the same convention the instrumentation file documents.

// MARK: Knob value (the open knob model)

/// A style-knob value. Style kinds are OPEN — the host declares knob keys per kind at
/// registration; a style is a sparse [key: value] dictionary; the cascade merges
/// dictionaries. This replaces closed per-kind structs (which would cost an SDK release
/// per new knob). JSON shape is raw (`12`, `"glass"`, `true`) for hand-editable documents.
public enum RipulKnob: Codable, Equatable {
    /// JSON-friendly unwrap for tool responses.
    public var jsonValue: Any {
        switch self {
        case .number(let n): return n
        case .string(let s): return s
        case .bool(let b): return b
        }
    }

    case number(Double)
    case string(String)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .bool(let b):   try c.encode(b)
        }
    }

    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool?     { if case .bool(let b) = self { return b }; return nil }
    public var cgFloat: CGFloat? { number.map { CGFloat($0) } }
}

// MARK: Document slice

/// The engine's slice of the host's theme document. Keys are declared in `RipulThemeSpec`
/// (the host's persisted names), so a host with an existing document — e.g. `"colors"` for
/// the palette, `"fieldButtonStyles"` for a kind's named styles — keeps its format
/// byte-compatible. Unknown top-level keys in the blob are ignored (host extras).
public struct RipulThemeDocument: Equatable {
    /// Palette name -> hex ("warmPurple" -> "6F2D80").
    public var primitives: [String: String] = [:]
    /// Semantic label -> reference (a primitive name, ANOTHER label, or a literal hex).
    public var semantic: [String: String] = [:]
    /// Component token -> reference (another component, a semantic label, a primitive, or hex).
    public var components: [String: String] = [:]
    /// kind -> style name -> sparse knobs (USER styles; built-ins come from the kind).
    public var namedStyles: [String: [String: [String: RipulKnob]]] = [:]
    /// kind -> element id -> assigned style name (missing = the kind's default tier).
    public var styleAssignments: [String: [String: String]] = [:]
    /// kind -> element id -> sparse per-element overrides (beat the named style).
    public var styleOverrides: [String: [String: [String: RipulKnob]]] = [:]

    public init() {}
}

extension CodingUserInfoKey {
    static let ripulThemeSpec = CodingUserInfoKey(rawValue: "ripulThemeSpec")!
}

extension RipulThemeDocument: Codable {
    private struct SliceKeys: CodingKey {
        var stringValue: String
        var intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let spec = decoder.userInfo[.ripulThemeSpec] as? RipulThemeSpec
        let c = try decoder.container(keyedBy: SliceKeys.self)
        let paletteKey = spec?.primitivesKey ?? "colors"
        primitives = try c.decodeIfPresent([String: String].self, forKey: SliceKeys(stringValue: paletteKey)!) ?? [:]
        let semanticKey = spec?.semanticKey ?? "semantic"
        semantic = try c.decodeIfPresent([String: String].self, forKey: SliceKeys(stringValue: semanticKey)!) ?? [:]
        let componentsKey = spec?.componentsKey ?? "components"
        components = try c.decodeIfPresent([String: String].self, forKey: SliceKeys(stringValue: componentsKey)!) ?? [:]
        for kind in spec?.styleKinds ?? [] {
            if let keys = kind.persistedKeys {
                namedStyles[kind.name] = try c.decodeIfPresent([String: [String: RipulKnob]].self,
                                                               forKey: SliceKeys(stringValue: keys.styles)!) ?? [:]
                styleAssignments[kind.name] = try c.decodeIfPresent([String: String].self,
                                                                    forKey: SliceKeys(stringValue: keys.assignments)!) ?? [:]
                styleOverrides[kind.name] = try c.decodeIfPresent([String: [String: RipulKnob]].self,
                                                                  forKey: SliceKeys(stringValue: keys.overrides)!) ?? [:]
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        let spec = encoder.userInfo[.ripulThemeSpec] as? RipulThemeSpec
        var c = encoder.container(keyedBy: SliceKeys.self)
        try c.encode(primitives, forKey: SliceKeys(stringValue: spec?.primitivesKey ?? "colors")!)
        try c.encode(semantic, forKey: SliceKeys(stringValue: spec?.semanticKey ?? "semantic")!)
        try c.encode(components, forKey: SliceKeys(stringValue: spec?.componentsKey ?? "components")!)
        for kind in spec?.styleKinds ?? [] {
            guard let keys = kind.persistedKeys else { continue }
            try c.encode(namedStyles[kind.name] ?? [:], forKey: SliceKeys(stringValue: keys.styles)!)
            try c.encode(styleAssignments[kind.name] ?? [:], forKey: SliceKeys(stringValue: keys.assignments)!)
            try c.encode(styleOverrides[kind.name] ?? [:], forKey: SliceKeys(stringValue: keys.overrides)!)
        }
    }
}

// MARK: Vocabulary + style kinds (host registration)

/// A themeable scope (one element that can carry a style assignment), for editors and the
/// View Explorer providers. `id` = the element's View-Explorer identifier. `path` = the
/// AUTHOR-declared namespace that places the component logically in the theme hierarchy
/// (["Add Shift", "Earnings panel"]) — hubs nest by it, editors breadcrumb it. Theme
/// metadata like the vocabulary paths, not a derived label.
public struct RipulThemeScope: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let path: [String]
    public init(id: String, label: String, path: [String] = []) {
        self.id = id; self.label = label; self.path = path
    }
}

public struct RipulThemeVocabulary {
    public struct Entry {
        public let name: String
        public let label: String
        /// Hierarchical placement for editors: the token AUTHOR's declared path through the
        /// theme hub ("Records" → "Row" → "Status"). The hub nests by it; adding a token (or a
        /// new path branch) needs no editor change. (Replaces the old flat `group`.)
        public let path: [String]
        /// The reference used when the document has no entry for this token.
        public let defaultReference: String
        public init(name: String, label: String, path: [String], defaultReference: String) {
            self.name = name; self.label = label; self.path = path
            self.defaultReference = defaultReference
        }
    }
    /// The primitive palette as labelled, PATHED entries — the bottom tier gets the same
    /// treatment as the tiers above it, so a generic palette screen groups and titles them
    /// from registration ("Brand", "Purples", "Status") instead of the host hand-writing a
    /// section per group. `defaultReference` is the seed hex used when the document has no
    /// entry for the primitive.
    public let primitives: [Entry]
    public let roles: [Entry]
    public let components: [Entry]
    public init(primitives: [Entry], roles: [Entry], components: [Entry]) {
        self.primitives = primitives; self.roles = roles; self.components = components
    }

    /// Palette names in registration order.
    public var primitiveOrder: [String] { primitives.map(\.name) }
}

/// One knob's editor descriptor: what it is and how to edit it. Registration data — a kind
/// declares its knobs once and every surface (style editor, future surfaces) renders them.
public struct RipulStyleKnob: Identifiable {
    public enum Kind {
        /// A numeric knob: slider in `range` when set; setting starts at `fallback`.
        case number(range: ClosedRange<Double>, fallback: Double, format: String = "%.0f")
        /// A string knob with a closed option set: Inherit (unset) or one of the options.
        case options([(raw: String, label: String)])
        /// A boolean knob: Inherit (unset), On, or Off.
        case bool
        /// A colour knob, stored as a `#RRGGBB` string. For structural colours a component
        /// TOKEN is the better home (it keeps the tier system); this is for the cases where
        /// a scope genuinely pins its own colour — a per-screen gradient, say.
        case color(fallback: String)
        /// A free-text knob, stored as a plain string. For COPY a scope owns — a tip's
        /// title and body, an empty-state line — where no closed option set exists.
        /// `multiline` picks the editor control (a field vs a small text view); it does
        /// not change the stored shape, which is always a single string.
        case text(fallback: String, multiline: Bool = false)
    }
    public let key: String
    public let label: String
    public let kind: Kind
    public var id: String { key }
    public init(_ key: String, _ label: String, _ kind: Kind) {
        self.key = key; self.label = label; self.kind = kind
    }
}

/// A named sub-part of a COMPOSITE style kind, typed by another registered kind — the
/// styles-layer analogue of a component-token alias. A disclosure panel declares
/// `card: surface` and `lozenge: lozenge`; a style of the composite kind then POINTS each
/// slot at a named style in the slot's kind (the slot's value in a style/override dict is
/// a plain string knob keyed by the slot's name — no new document shape).
///
/// Each composite scope `X` implies a child scope `X.<slot name>` in the slot's kind
/// (synthesized at `configure()`), so one panel's lozenge can be re-pointed (a child
/// assignment) or forked (child overrides) without touching the library style.
public struct RipulStyleSlot: Identifiable {
    /// Knob key in the composite's style dicts AND the child-scope id suffix.
    public let name: String
    public let label: String
    /// The target kind — the slot's type. The kind graph must be a DAG.
    public let kind: String
    /// Named style in the target kind used when nothing points anywhere; nil = the target
    /// kind's default tier alone.
    public let defaultStyle: String?
    public var id: String { name }
    public init(name: String, label: String, kind: String, defaultStyle: String? = nil) {
        self.name = name; self.label = label; self.kind = kind; self.defaultStyle = defaultStyle
    }
}

public struct RipulStyleKind {
    /// The host's persisted key names for this kind's three maps in the theme blob —
    /// legacy formats stay byte-compatible (e.g. "fieldButtonStyles" / "...Names" /
    /// "...Overrides"). nil = this kind isn't persisted (transient).
    public struct PersistedKeys {
        public let styles: String
        public let assignments: String
        public let overrides: String
        public init(styles: String, assignments: String, overrides: String) {
            self.styles = styles; self.assignments = assignments; self.overrides = overrides
        }
    }

    public let name: String
    public let scopes: [RipulThemeScope]
    /// This kind's knob schema — descriptors driving the generic style editor
    /// (`RipulStyleKindEditorView`) and any future surface. Resolution itself is open.
    public let knobs: [RipulStyleKnob]
    /// Typed sub-parts. Non-empty makes this a composite kind: `resolved(kind:element:)`
    /// nests a resolved style per slot. Slot names must not collide with knob keys.
    public let slots: [RipulStyleSlot]
    /// Built-in style LIBRARY — shipped in code, present on every theme; a user style with
    /// the same name shadows the built-in.
    public let builtIns: [String: [String: RipulKnob]]
    /// The DEFAULT TIER content — host-owned. Called per resolution with the element id;
    /// keep it fast. It may read host state (e.g. a metrics tier the engine doesn't model)
    /// — the host must have that state current BEFORE calling `RipulThemeEngine.adopt(_:)`.
    public let defaultTier: (RipulThemeDocument, _ element: String) -> [String: RipulKnob]
    public let persistedKeys: PersistedKeys?

    // MARK: presentation metadata (so generic screens need no per-kind switch)

    /// Display name for this kind's library ("Panel styles"). Generic hubs title sections
    /// with it — the same role `RipulThemeVocabulary.Entry.label` plays for tokens.
    /// Defaults to the capitalised `name`.
    public let label: String
    /// The AUTHOR-declared placement of this kind in a theme hub (["Panels"]) — hubs nest
    /// by it, exactly as they do for token paths. Empty = top level.
    public let path: [String]
    /// Label for the "no named style assigned" row in pickers ("Default (card)"). The
    /// wording is host vocabulary — what the unassigned tier actually looks like.
    public let defaultStyleLabel: String
    /// Whether a shared style LIBRARY makes sense for this kind. False for kinds that exist
    /// only to carry per-element divergence from an app-wide default (per-screen record
    /// tokens, say) — offering "named styles" there is a dead end, so screens hide it.
    public let supportsNamedStyles: Bool
    /// The element a style LIBRARY previews against when no specific element is in play
    /// (editing a named style rather than assigning one). First scope by default — for
    /// part kinds that is the first synthesized child scope, which is what a host would
    /// have hand-picked anyway.
    public var previewElement: String? { scopes.first?.id }

    public init(name: String, label: String? = nil, path: [String] = [],
                defaultStyleLabel: String = "Default",
                supportsNamedStyles: Bool = true,
                scopes: [RipulThemeScope], knobs: [RipulStyleKnob],
                slots: [RipulStyleSlot] = [],
                builtIns: [String: [String: RipulKnob]] = [:],
                defaultTier: @escaping (RipulThemeDocument, _ element: String) -> [String: RipulKnob],
                persistedKeys: PersistedKeys? = nil) {
        self.name = name
        self.label = label ?? (name.prefix(1).uppercased() + name.dropFirst())
        self.path = path
        self.defaultStyleLabel = defaultStyleLabel
        self.supportsNamedStyles = supportsNamedStyles
        self.scopes = scopes; self.knobs = knobs; self.slots = slots
        self.builtIns = builtIns; self.defaultTier = defaultTier; self.persistedKeys = persistedKeys
    }
}

/// A kind's style after full resolution. `knobs` = the kind's OWN cascade result (slot
/// references included, as string knobs); `slots` = a resolved style per declared slot.
/// Kinds without slots resolve with `slots` empty — the flat API is unchanged for them.
public struct RipulResolvedStyle {
    public let knobs: [String: RipulKnob]
    public let slots: [String: RipulResolvedStyle]
    public init(knobs: [String: RipulKnob], slots: [String: RipulResolvedStyle] = [:]) {
        self.knobs = knobs; self.slots = slots
    }
    public subscript(_ key: String) -> RipulKnob? { knobs[key] }
    /// A slot's resolved style; empty (never nil) for undeclared names, so host mapping
    /// code can read `style.slot("lozenge")["chipPadX"]` without optional gymnastics.
    public func slot(_ name: String) -> RipulResolvedStyle {
        slots[name] ?? RipulResolvedStyle(knobs: [:])
    }
}

public struct RipulThemeSpec {
    /// Host-bundle JSON resource name (without extension) holding the bundled theme.
    public let bundleResource: String
    /// UserDefaults key for the override blob. `resetToBundled()` removes this key —
    /// which must revert the WHOLE host document, so hosts keep one blob.
    public let overrideDefaultsKey: String
    public var primitivesKey: String = "colors"
    public var semanticKey: String = "semantic"
    public var componentsKey: String = "components"
    public var vocabulary: RipulThemeVocabulary
    public var styleKinds: [RipulStyleKind]

    public init(bundleResource: String, overrideDefaultsKey: String,
                vocabulary: RipulThemeVocabulary, styleKinds: [RipulStyleKind]) {
        self.bundleResource = bundleResource
        self.overrideDefaultsKey = overrideDefaultsKey
        self.vocabulary = vocabulary
        self.styleKinds = styleKinds
    }
}

// MARK: - Engine

public enum RipulThemeEngine {

    private static var spec: RipulThemeSpec?
    private static var rolesByName: [String: RipulThemeVocabulary.Entry] = [:]
    private static var componentsByName: [String: RipulThemeVocabulary.Entry] = [:]
    private static var kindsByName: [String: RipulStyleKind] = [:]
    /// The registered kinds AFTER child-scope synthesis, in spec order — what `styleKinds`
    /// and `kind(containingScope:)` read.
    private static var registeredKinds: [RipulStyleKind] = []

    /// The live document slice (override if present, else bundled). Set via `adopt(_:)`.
    public private(set) static var current = RipulThemeDocument()

    /// The bundled document slice (the host's build-time theme).
    public private(set) static var bundled = RipulThemeDocument()

    /// Configure the engine: register the vocabulary + style kinds and load the live
    /// document (override slice if persisted, else the bundled slice). Call once at launch,
    /// before any resolution (and before `RipulThemeInstrumentation.install()` consumers
    /// rely on tagged colours).
    public static func configure(_ spec: RipulThemeSpec) {
        self.spec = spec
        rolesByName = Dictionary(uniqueKeysWithValues: spec.vocabulary.roles.map { ($0.name, $0) })
        componentsByName = Dictionary(uniqueKeysWithValues: spec.vocabulary.components.map { ($0.name, $0) })
        registeredKinds = synthesizeChildScopes(validateSlots(spec.styleKinds))
        kindsByName = Dictionary(uniqueKeysWithValues: registeredKinds.map { ($0.name, $0) })
        bundled = loadBundled() ?? RipulThemeDocument()
        current = loadOverride() ?? bundled
    }

    // MARK: slot registration (validation + child-scope synthesis)

    /// Registration-time invariants for composite kinds: every slot targets a registered
    /// kind, slot names don't collide with the kind's own knob keys, and the kind → slot
    /// graph is a DAG. Violations are programmer errors — assert in debug, and drop the
    /// offending slot so release resolution stays total.
    private static func validateSlots(_ kinds: [RipulStyleKind]) -> [RipulStyleKind] {
        let byName = Dictionary(uniqueKeysWithValues: kinds.map { ($0.name, $0) })

        func reaches(_ target: String, from kindName: String, seen: inout Set<String>) -> Bool {
            guard seen.insert(kindName).inserted else { return false }
            guard let k = byName[kindName] else { return false }
            return k.slots.contains { $0.kind == target || reaches(target, from: $0.kind, seen: &seen) }
        }

        return kinds.map { kind in
            let kept = kind.slots.filter { slot in
                guard byName[slot.kind] != nil else {
                    assertionFailure("Slot '\(kind.name).\(slot.name)' targets unregistered kind '\(slot.kind)'")
                    return false
                }
                guard !kind.knobs.contains(where: { $0.key == slot.name }) else {
                    assertionFailure("Slot '\(kind.name).\(slot.name)' collides with a knob key")
                    return false
                }
                var seen: Set<String> = []
                guard slot.kind != kind.name, !reaches(kind.name, from: slot.kind, seen: &seen) else {
                    assertionFailure("Slot '\(kind.name).\(slot.name)' closes a kind cycle via '\(slot.kind)'")
                    return false
                }
                return true
            }
            guard kept.count != kind.slots.count else { return kind }
            return RipulStyleKind(name: kind.name, label: kind.label, path: kind.path,
                                  defaultStyleLabel: kind.defaultStyleLabel,
                                  supportsNamedStyles: kind.supportsNamedStyles,
                                  scopes: kind.scopes, knobs: kind.knobs,
                                  slots: kept, builtIns: kind.builtIns,
                                  defaultTier: kind.defaultTier, persistedKeys: kind.persistedKeys)
        }
    }

    /// Every composite scope `X` implies a scope `X.<slot name>` in the slot's kind — the
    /// element the child part's assignments/overrides key on, and what editors and the
    /// View Explorer resolve a tapped sub-part to. Synthesized transitively (a slot kind
    /// may itself be composite); the DAG guarantee makes the walk finite. The host never
    /// hand-registers these.
    private static func synthesizeChildScopes(_ kinds: [RipulStyleKind]) -> [RipulStyleKind] {
        let byName = Dictionary(uniqueKeysWithValues: kinds.map { ($0.name, $0) })
        var extra: [String: [RipulThemeScope]] = [:]
        var seenIds: [String: Set<String>] = Dictionary(uniqueKeysWithValues:
            kinds.map { ($0.name, Set($0.scopes.map(\.id))) })

        var queue: [(scope: RipulThemeScope, kind: String)] =
            kinds.flatMap { k in k.scopes.map { ($0, k.name) } }
        while !queue.isEmpty {
            let (scope, kindName) = queue.removeFirst()
            guard let k = byName[kindName] else { continue }
            for slot in k.slots {
                let child = RipulThemeScope(id: "\(scope.id).\(slot.name)",
                                            label: "\(scope.label) · \(slot.label)",
                                            path: scope.path + [slot.label])
                guard seenIds[slot.kind, default: []].insert(child.id).inserted else { continue }
                extra[slot.kind, default: []].append(child)
                queue.append((child, slot.kind))
            }
        }

        return kinds.map { kind in
            guard let add = extra[kind.name], !add.isEmpty else { return kind }
            return RipulStyleKind(name: kind.name, label: kind.label, path: kind.path,
                                  defaultStyleLabel: kind.defaultStyleLabel,
                                  supportsNamedStyles: kind.supportsNamedStyles,
                                  scopes: kind.scopes + add, knobs: kind.knobs,
                                  slots: kind.slots, builtIns: kind.builtIns,
                                  defaultTier: kind.defaultTier, persistedKeys: kind.persistedKeys)
        }
    }

    // MARK: persistence (read-only for the engine; the host owns blob writes)

    private static func decode(_ data: Data) -> RipulThemeDocument? {
        let d = JSONDecoder()
        if let spec { d.userInfo[.ripulThemeSpec] = spec }
        return try? d.decode(RipulThemeDocument.self, from: data)
    }

    private static func loadBundled() -> RipulThemeDocument? {
        guard let spec,
              let url = Bundle.main.url(forResource: spec.bundleResource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private static func loadOverride() -> RipulThemeDocument? {
        guard let spec,
              let json = UserDefaults.standard.string(forKey: spec.overrideDefaultsKey),
              let data = json.data(using: .utf8) else { return nil }
        return decode(data)
    }

    public static var hasOverride: Bool {
        guard let spec else { return false }
        return UserDefaults.standard.string(forKey: spec.overrideDefaultsKey) != nil
    }

    /// Adopt a new live document: set current, broadcast `.ripulThemeDidChange`, and
    /// repaint token-tagged UIKit views. The HOST persists its blob itself — it owns the
    /// whole document; the engine only ever holds its slice.
    public static func adopt(_ doc: RipulThemeDocument) {
        current = doc
        NotificationCenter.default.post(name: .ripulThemeDidChange, object: nil)
        reapplyLiveTokenColors()
    }

    /// Drop any override and revert to the bundled theme (removes the host's whole blob —
    /// the one key hosts are required to share).
    public static func resetToBundled() {
        guard let spec else { return }
        UserDefaults.standard.removeObject(forKey: spec.overrideDefaultsKey)
        adopt(bundled)
    }

    // MARK: - Mutation (agent/dev tools write path)

    /// The registered style kinds (panel/field/etc., each with scopes + knob schema),
    /// including synthesized child scopes for slots.
    public static var styleKinds: [RipulStyleKind] { registeredKinds }

    /// Resolve a scope id (View-Explorer element id) to its kind. Synthesized child scopes
    /// resolve to the SLOT's kind — tapping a panel's lozenge edits lozenge styles.
    public static func kind(containingScope element: String) -> RipulStyleKind? {
        registeredKinds.first { $0.scopes.contains { $0.id == element } }
    }

    /// Host-provided write path, called after `setOverride`/`clearOverrides` mutate the
    /// document. The host should persist the document's slice (its own blob) and run its
    /// apply path (which broadcasts via `adopt`). When nil, the engine adopts the
    /// mutation itself (still broadcasts `.ripulThemeDidChange`).
    public static var persistMutation: ((RipulThemeDocument) -> Void)?

    /// Replace an element's whole per-element override dict (empty clears it) — the write
    /// path for the generic override rows on a scope screen.
    public static func setOverrides(kind: String, element: String, knobs: [String: RipulKnob]) {
        current.styleOverrides[kind, default: [:]][element] = knobs.isEmpty ? nil : knobs
        commit()
    }

    /// Set one knob as a per-element override, beating any assigned named style.
    /// Broadcasts via the host's `persistMutation` (or `adopt` as fallback).
    public static func setOverride(element: String, knob: String, value: RipulKnob) throws {
        guard let kind = kind(containingScope: element) else {
            throw NSError(domain: "theme", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Unknown scope '\(element)'. Call list_theme_scopes for valid ids."])
        }
        current.styleOverrides[kind.name, default: [:]][element, default: [:]][knob] = value
        if let persistMutation { persistMutation(current) } else { adopt(current) }
    }

    /// Clear every per-element override on a scope (returns it to its assigned style).
    public static func clearOverrides(element: String) throws {
        guard let kind = kind(containingScope: element) else {
            throw NSError(domain: "theme", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Unknown scope '\(element)'."])
        }
        current.styleOverrides[kind.name]?[element] = nil
        if let persistMutation { persistMutation(current) } else { adopt(current) }
    }

    // MARK: - Colour-tier mutation (the SDK-owned colour screens' write path)
    //
    // Same contract as the style mutators: mutate the live document, then hand it to the
    // host's `persistMutation` (blob write + adopt + broadcast), falling back to `adopt`
    // when no host hook is set. Every colour edit is therefore live AND durable.

    /// Point a component token at a reference — another component (alias), a semantic
    /// label, a primitive name, or a literal hex.
    public static func setReference(component name: String, to reference: String) {
        current.components[name] = reference
        commit()
    }

    /// Point a semantic label at a reference — a primitive name, another label (alias), or
    /// a literal hex.
    public static func setReference(label name: String, to reference: String) {
        current.semantic[name] = reference
        commit()
    }

    /// Set a primitive's hex — the bottom tier; cascades to every role and token that
    /// references it.
    public static func setPrimitive(_ name: String, hex: String) {
        current.primitives[name] = hex
        commit()
    }

    /// Add a user-defined semantic label pointing at `reference`.
    public static func addSemanticLabel(_ name: String, reference: String) {
        current.semantic[name] = reference
        commit()
    }

    /// Remove a user-defined semantic label. Built-in roles can't be removed — they fall
    /// back to their vocabulary default, so removing the entry just resets it.
    public static func removeSemanticLabel(_ name: String) {
        current.semantic[name] = nil
        commit()
    }

    /// The hex a primitive currently holds (document entry, else its registered seed).
    public static func primitiveHex(_ name: String) -> String? {
        current.primitives[name]
            ?? spec?.vocabulary.primitives.first { $0.name == name }?.defaultReference
    }

    private static func commit() {
        if let persistMutation { persistMutation(current) } else { adopt(current) }
    }

    // MARK: colour resolution (tagged at the chokepoints)

    /// The raw reference a component token points at — the document's entry, else the
    /// vocabulary default.
    public static func reference(forComponent name: String) -> String {
        current.components[name] ?? componentsByName[name]?.defaultReference ?? name
    }

    /// The raw reference a semantic label points at — document, else vocabulary default,
    /// else the label itself (a user-added label with no mapping resolves to magenta, as
    /// documented for the host layer this replaces).
    public static func reference(forLabel label: String) -> String {
        current.semantic[label] ?? rolesByName[label]?.defaultReference ?? label
    }

    /// True if `name` is a known semantic label (a vocabulary role or a user-added key).
    public static func isSemanticLabel(_ name: String) -> Bool {
        rolesByName[name] != nil || current.semantic[name] != nil
    }

    // MARK: vocabulary access (what generic token screens read)

    /// The registered vocabulary — primitives, roles and component tokens with their
    /// labels and hub paths.
    public static var vocabulary: RipulThemeVocabulary? { spec?.vocabulary }

    /// True if `name` is a registered component token.
    public static func isComponentToken(_ name: String) -> Bool { componentsByName[name] != nil }

    /// Every semantic label: built-in roles (registration order) then user-added keys.
    public static var semanticLabels: [String] {
        (spec?.vocabulary.roles.map(\.name) ?? []) + customSemanticLabels
    }

    /// Just the user-added semantic labels (document keys that aren't registered roles).
    public static var customSemanticLabels: [String] {
        current.semantic.keys.filter { rolesByName[$0] == nil }.sorted()
    }

    /// Display label for a semantic name — the registered role's label, else the key
    /// prettified ("paymentPositive" -> "Payment positive") for user-added labels.
    public static func displayLabel(forLabel name: String) -> String {
        rolesByName[name]?.label ?? prettify(name)
    }

    /// Display label for a component token name.
    public static func displayLabel(forComponent name: String) -> String {
        componentsByName[name]?.label ?? prettify(name)
    }

    static func prettify(_ s: String) -> String {
        var out = ""
        for ch in s { if ch.isUppercase || ch.isNumber { out += " " }; out.append(ch) }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    /// True if pointing component `name` at `target` would close an alias cycle.
    public static func aliasWouldCycle(component name: String, to target: String) -> Bool {
        var seen: Set<String> = [name]
        var cursor: String? = target
        while let c = cursor {
            if seen.contains(c) { return true }
            seen.insert(c)
            cursor = componentsByName[c] != nil ? reference(forComponent: c) : nil
        }
        return false
    }

    /// True if pointing semantic `label` at `target` would close an alias cycle.
    public static func aliasWouldCycle(label name: String, to target: String) -> Bool {
        var seen: Set<String> = [name]
        var cursor: String? = target
        while let c = cursor {
            if seen.contains(c) { return true }
            seen.insert(c)
            let ref = reference(forLabel: c)
            if current.primitives[ref] != nil { return false }   // chain ends at a primitive
            cursor = isSemanticLabel(ref) ? ref : nil            // … or at a hex
        }
        return false
    }

    /// Resolve a component token to a colour. The reference crosses tiers freely: another
    /// component (alias — recurse, cycle-guarded), a semantic label, a primitive, or a
    /// literal hex. Tagged with the OUTERMOST component name — the token the UI read.
    public static func color(component name: String) -> UIColor { color(component: name, chain: [name]) }

    private static func color(component name: String, chain: Set<String>) -> UIColor {
        let ref = reference(forComponent: name)
        if componentsByName[ref] != nil, !chain.contains(ref) {
            return color(component: ref, chain: chain.union([ref])).ripulTagged(name)
        }
        if isSemanticLabel(ref) { return color(label: ref).ripulTagged(name) }
        if let hex = current.primitives[ref], let resolved = UIColor(ripulHexString: hex) {
            return resolved.ripulTagged(name)
        }
        guard let resolved = UIColor(ripulHexString: ref) else { return .magenta }
        return resolved.ripulTagged(name)
    }

    /// Resolve a semantic label to a colour: primitive (a primitive name beats a same-named
    /// label), alias to another label (cycle-guarded), or literal hex. Tagged outermost.
    public static func color(label name: String) -> UIColor { color(label: name, chain: [name]) }

    private static func color(label name: String, chain: Set<String>) -> UIColor {
        let ref = reference(forLabel: name)
        if let hex = current.primitives[ref], let resolved = UIColor(ripulHexString: hex) {
            return resolved.ripulTagged(name)
        }
        if isSemanticLabel(ref), !chain.contains(ref) {
            return color(label: ref, chain: chain.union([ref])).ripulTagged(name)
        }
        guard let resolved = UIColor(ripulHexString: ref) else { return .magenta }
        return resolved.ripulTagged(name)
    }

    /// Resolve a token NAME — a component token OR a semantic label — to its colour.
    /// The repaint walker's only entry point. nil for names that are neither (e.g. hex).
    public static func color(forTokenName token: String) -> UIColor? {
        if componentsByName[token] != nil { return color(component: token) }
        if isSemanticLabel(token) { return color(label: token) }
        return nil
    }

    // MARK: style cascade (per-element override ?? named style ?? kind default tier)

    /// The resolved style for an element of a kind — default tier filled by the kind's
    /// `defaultTier`, then the assigned named style (user styles shadow built-ins), then
    /// the element's own overrides.
    public static func resolvedStyle(kind: String, element: String) -> [String: RipulKnob] {
        resolveStyle(kind: kind, element: element,
                     styleName: current.styleAssignments[kind]?[element],
                     overrides: current.styleOverrides[kind]?[element])
    }

    /// The resolution the element WOULD get with `styleName` assigned (its own overrides
    /// still applied on top) — drives live style pickers.
    public static func previewStyle(kind: String, element: String, style: String?) -> [String: RipulKnob] {
        resolveStyle(kind: kind, element: element,
                     styleName: style,
                     overrides: current.styleOverrides[kind]?[element])
    }

    private static func resolveStyle(kind: String, element: String, styleName: String?,
                                     overrides: [String: RipulKnob]?) -> [String: RipulKnob] {
        guard let k = kindsByName[kind] else { return overrides ?? [:] }
        var merged = k.defaultTier(current, element)
        if let name = styleName, let named = current.namedStyles[kind]?[name] ?? k.builtIns[name] {
            for (key, value) in named { merged[key] = value }
        }
        if let overrides { for (key, value) in overrides { merged[key] = value } }
        return merged
    }

    // MARK: nested resolution (composite kinds)

    /// The FULL resolved style for an element: the kind's own cascade plus a resolved style
    /// per declared slot. Kinds without slots return `slots` empty — identical content to
    /// `resolvedStyle(kind:element:)`.
    ///
    /// Per slot, the pointer cascade is:
    ///   child assignment (styleAssignments[slot.kind]["<element>.<slot>"])  — re-point ONE
    ///   ?? the composite's resolved slot reference (a string knob keyed by the slot name,
    ///      so a named style, the composite's default tier, or a per-element override can
    ///      all set it)
    ///   ?? slot.defaultStyle
    /// and the child's own overrides apply on top of whichever style that names — fork ONE
    /// without touching the library.
    public static func resolved(kind: String, element: String) -> RipulResolvedStyle {
        nestedStyle(kind: kind, element: element,
                    styleName: current.styleAssignments[kind]?[element],
                    overrides: current.styleOverrides[kind]?[element],
                    chain: [kind])
    }

    /// The nested resolution the element WOULD get with `style` assigned (its overrides and
    /// its parts' own re-points/forks still applied) — drives live style pickers.
    public static func previewResolved(kind: String, element: String, style: String?) -> RipulResolvedStyle {
        nestedStyle(kind: kind, element: element, styleName: style,
                    overrides: current.styleOverrides[kind]?[element],
                    chain: [kind])
    }

    /// Nested preview while EDITING a named style of a composite kind: the working knobs
    /// merge over the kind's default tier, and slots resolve from the WORKING slot
    /// references (no element assignment/overrides — the style itself is on the bench).
    public static func mergedResolved(kind kindName: String, element: String,
                                      over working: [String: RipulKnob]) -> RipulResolvedStyle {
        let own = mergedStyle(kind: kindName, element: element, over: working)
        guard let k = kindsByName[kindName], !k.slots.isEmpty else {
            return RipulResolvedStyle(knobs: own)
        }
        var parts: [String: RipulResolvedStyle] = [:]
        for slot in k.slots {
            parts[slot.name] = nestedStyle(kind: slot.kind, element: "\(element).\(slot.name)",
                                           styleName: own[slot.name]?.string ?? slot.defaultStyle,
                                           overrides: nil,
                                           chain: [kindName, slot.kind])
        }
        return RipulResolvedStyle(knobs: own, slots: parts)
    }

    private static func nestedStyle(kind kindName: String, element: String, styleName: String?,
                                    overrides: [String: RipulKnob]?, chain: Set<String>) -> RipulResolvedStyle {
        let own = resolveStyle(kind: kindName, element: element, styleName: styleName, overrides: overrides)
        guard let k = kindsByName[kindName], !k.slots.isEmpty else {
            return RipulResolvedStyle(knobs: own)
        }
        var parts: [String: RipulResolvedStyle] = [:]
        for slot in k.slots {
            // Belt-and-braces recursion guard; `validateSlots` already enforces the DAG.
            guard !chain.contains(slot.kind) else { continue }
            let childId = "\(element).\(slot.name)"
            let ref = current.styleAssignments[slot.kind]?[childId]
                ?? own[slot.name]?.string
                ?? slot.defaultStyle
            parts[slot.name] = nestedStyle(kind: slot.kind, element: childId,
                                           styleName: ref,
                                           overrides: current.styleOverrides[slot.kind]?[childId],
                                           chain: chain.union([slot.kind]))
        }
        return RipulResolvedStyle(knobs: own, slots: parts)
    }

    /// Merge a knob dict over a kind's default tier for an element — the preview path when
    /// EDITING a named style (default tier <- working knobs; no live style lookup, no
    /// element overrides). Drives the generic style editor's live example.
    public static func mergedStyle(kind: String, element: String,
                                   over knobs: [String: RipulKnob]) -> [String: RipulKnob] {
        guard let k = kindsByName[kind] else { return knobs }
        var merged = k.defaultTier(current, element)
        for (key, value) in knobs { merged[key] = value }
        return merged
    }

    /// Every assignable style name for a kind: built-ins (in registration order is not
    /// preserved in a dict — hosts wanting order keep their own list) then user styles.
    public static func allStyleNames(kind: String) -> [String] {
        let builtInNames = kindsByName[kind]?.builtIns.keys.sorted() ?? []
        let userNames = (current.namedStyles[kind] ?? [:]).keys
            .filter { kindsByName[kind]?.builtIns[$0] == nil }.sorted()
        return builtInNames + userNames
    }

    // MARK: named-style library (the SDK-owned library screen's read/write path)

    /// A named style's sparse knobs — the user's copy shadows a same-named built-in.
    public static func namedStyle(kind: String, name: String) -> [String: RipulKnob]? {
        current.namedStyles[kind]?[name] ?? kindsByName[kind]?.builtIns[name]
    }

    /// True if `name` is a built-in of this kind (shipped in code, present on every theme).
    public static func isBuiltInStyle(kind: String, name: String) -> Bool {
        kindsByName[kind]?.builtIns[name] != nil
    }

    /// True if a USER style with this name exists — for a built-in name that means a
    /// copy-on-write copy is shadowing stock, so "Reset to built-in" is offered.
    public static func hasUserStyle(kind: String, name: String) -> Bool {
        current.namedStyles[kind]?[name] != nil
    }

    /// Create or replace a named style. Editing a BUILT-IN through this writes a user copy
    /// that shadows it (copy-on-write); `removeNamedStyle` restores stock.
    public static func setNamedStyle(kind: String, name: String, knobs: [String: RipulKnob]) {
        current.namedStyles[kind, default: [:]][name] = knobs
        commit()
    }

    /// Remove a user style. For a built-in name this restores stock; for a user-authored
    /// one it deletes the style AND drops every assignment pointing at it, so no element is
    /// left referencing a style that no longer exists.
    public static func removeNamedStyle(kind: String, name: String) {
        current.namedStyles[kind]?[name] = nil
        if !isBuiltInStyle(kind: kind, name: name) {
            current.styleAssignments[kind] = (current.styleAssignments[kind] ?? [:])
                .filter { $0.value != name }
        }
        commit()
    }

    /// Assign (or clear, with nil) the named style for an element. Routed through the
    /// host's `persistMutation` (same as `setOverride`) so an SDK-owned surface — the style
    /// picker especially — writes the host's blob rather than only applying live; adopting
    /// without persisting looked correct until relaunch, when the assignment vanished.
    public static func assign(style: String?, kind: String, element: String) {
        var map = current.styleAssignments[kind] ?? [:]
        map[element] = style
        current.styleAssignments[kind] = map
        if let persistMutation { persistMutation(current) } else { adopt(current) }
    }

    /// Clear an element's per-element overrides. Persists through the host, as above.
    public static func clearOverrides(kind: String, element: String) {
        var map = current.styleOverrides[kind] ?? [:]
        map[element] = nil
        current.styleOverrides[kind] = map
        if let persistMutation { persistMutation(current) } else { adopt(current) }
    }

    // MARK: live repaint (UIKit walker)

    /// Force every window to reflect an adoption NOW, without a leave + return: re-resolve
    /// any colour that carries a design token (backgrounds tagged via the setter swizzle,
    /// label/text-field/text-view text colours). SwiftUI views refresh off
    /// `.ripulThemeDidChange` (see `refreshesOnThemeChange`). Re-resolved colours come back
    /// tagged, so repeated adoptions keep working.
    /// Out of reach (refresh on next render, as before): untokened hex colours, CGColor
    /// borders/gradients, attributed-string runs, tint colours.
    private static func reapplyLiveTokenColors() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { reapplyLiveTokenColors(in: window) }
        }
    }

    private static func reapplyLiveTokenColors(in view: UIView) {
        if let token = view.ripulBackgroundToken, let color = color(forTokenName: token) {
            view.backgroundColor = color
        }
        if let label = view as? UILabel, let token = label.textColor?.ripulToken,
           let color = color(forTokenName: token) {
            label.textColor = color
        }
        if let field = view as? UITextField, let token = field.textColor?.ripulToken,
           let color = color(forTokenName: token) {
            field.textColor = color
        }
        if let textView = view as? UITextView, let token = textView.textColor?.ripulToken,
           let color = color(forTokenName: token) {
            textView.textColor = color
        }
        view.subviews.forEach { reapplyLiveTokenColors(in: $0) }
    }
}
#endif
