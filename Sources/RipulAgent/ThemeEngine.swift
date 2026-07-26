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
    /// Palette names in display order (editors iterate this).
    public let primitiveOrder: [String]
    public let roles: [Entry]
    public let components: [Entry]
    public init(primitiveOrder: [String], roles: [Entry], components: [Entry]) {
        self.primitiveOrder = primitiveOrder; self.roles = roles; self.components = components
    }
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
    }
    public let key: String
    public let label: String
    public let kind: Kind
    public var id: String { key }
    public init(_ key: String, _ label: String, _ kind: Kind) {
        self.key = key; self.label = label; self.kind = kind
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
    /// Built-in style LIBRARY — shipped in code, present on every theme; a user style with
    /// the same name shadows the built-in.
    public let builtIns: [String: [String: RipulKnob]]
    /// The DEFAULT TIER content — host-owned. Called per resolution with the element id;
    /// keep it fast. It may read host state (e.g. a metrics tier the engine doesn't model)
    /// — the host must have that state current BEFORE calling `RipulThemeEngine.adopt(_:)`.
    public let defaultTier: (RipulThemeDocument, _ element: String) -> [String: RipulKnob]
    public let persistedKeys: PersistedKeys?

    public init(name: String, scopes: [RipulThemeScope], knobs: [RipulStyleKnob],
                builtIns: [String: [String: RipulKnob]] = [:],
                defaultTier: @escaping (RipulThemeDocument, _ element: String) -> [String: RipulKnob],
                persistedKeys: PersistedKeys? = nil) {
        self.name = name; self.scopes = scopes; self.knobs = knobs
        self.builtIns = builtIns; self.defaultTier = defaultTier; self.persistedKeys = persistedKeys
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
        kindsByName = Dictionary(uniqueKeysWithValues: spec.styleKinds.map { ($0.name, $0) })
        bundled = loadBundled() ?? RipulThemeDocument()
        current = loadOverride() ?? bundled
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

    /// Assign (or clear, with nil) the named style for an element. Adopts the change live;
    /// the host persists through its own document write.
    public static func assign(style: String?, kind: String, element: String) {
        var doc = current
        var map = doc.styleAssignments[kind] ?? [:]
        map[element] = style
        doc.styleAssignments[kind] = map
        adopt(doc)
    }

    /// Clear an element's per-element overrides. Adopts the change live.
    public static func clearOverrides(kind: String, element: String) {
        var doc = current
        var map = doc.styleOverrides[kind] ?? [:]
        map[element] = nil
        doc.styleOverrides[kind] = map
        adopt(doc)
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
