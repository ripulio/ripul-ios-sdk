import Foundation
import CoreGraphics
import Observation

// MARK: - The base theme (cross-platform core)
//
// The SDK's own vocabulary: the colour roles and type roles every first-party screen
// reads, in any host, with or without a host theme. The defaults are in code and give
// the system look exactly, so a host that supplies nothing sees no change.
//
// This file has no UIKit and no SwiftUI: it holds the names, the document grammar and
// the resolution rule, and compiles for macOS. `RipulThemeColors.swift` and
// `RipulThemeFonts.swift` turn a resolved value into something a view can use.
// It is separate from the host engine (`RipulThemeEngine`): a host's `configure` does
// not touch it, and a host's editor does not list these roles.
//
// The contract for call sites is `ripul-ios-sdk/docs/theming.md`.

extension Notification.Name {
    /// Posted by the host's theme engine whenever the live theme changes. The SDK's refresh
    /// modifier and hosting factory listen for exactly this name — a host adopting live
    /// theming posts it from its apply path (one post per apply).
    public static let ripulThemeDidChange = Notification.Name("ripulThemeDidChange")
}

/// A colour role: a name a theme document gives a colour to, with the colour it is when
/// no document names it. Named for the job, never for the value.
///
/// The SDK's own fifteen are the static members below (`.accent`, `.text` …), each with
/// the system colour it replaces as its default. A host adds its own the same way, once,
/// with the colour it uses today as the default, so that nothing changes until a theme
/// names the role:
///
///     extension RipulColorRole {
///         static let navy = RipulColorRole(asset: "BrandNavy")                    // an asset colour
///         static let cream = RipulColorRole("cream", default: "#F4EBDD", dark: "#2A2418")
///     }
///     .foregroundStyle(.ripul(.navy))        // the same accessors as the fifteen
///
/// and in the document, under `roles`, by its name: `"BrandNavy": "navy"`.
/// Two roles are the same role when their names are equal.
public struct RipulColorRole: Hashable, RawRepresentable, CaseIterable, Sendable {
    /// The name in a theme document: `accent`, or a host's own `BrandNavy`.
    public let rawValue: String
    /// What the role resolves to when no document says otherwise: today's look.
    public let defaultValue: RipulColorValue
    /// A label for editors.
    public let label: String
    /// True for the SDK's own fifteen.
    public let isBase: Bool

    private init(base name: String, _ reference: String, _ label: String) {
        self.rawValue = name
        self.defaultValue = RipulColorValue(light: RipulColorLiteral(reference)!)
        self.label = label
        self.isBase = true
    }

    /// A host's own role, with the colour it is today.
    /// - Parameters:
    ///   - name: the name in a theme document's `roles`. Not one of the SDK's fifteen.
    ///   - default: `#RRGGBB`, `#RRGGBBAA`, `system:<name>` or `asset:<name>`.
    ///   - dark: the dark value, when it differs and `default` is not already a colour
    ///     that follows the appearance.
    public init(_ name: String, default light: String, dark: String? = nil, label: String? = nil) {
        self.rawValue = name
        // A default that cannot be read is a programming error: it would silently be black.
        let value = RipulColorLiteral(light).map { RipulColorValue(light: $0, dark: dark.flatMap(RipulColorLiteral.init)) }
        assert(value != nil, "RipulColorRole(\"\(name)\"): the default \"\(light)\" is not a colour")
        self.defaultValue = value ?? RipulColorValue(light: .system("label"))
        self.label = label ?? name
        self.isBase = false
        RipulColorRole.declare(self)
    }

    /// A host's own role whose colour today is a named colour of its asset catalogue. The
    /// role's name is the asset's, so a document names it as the app does.
    public init(asset name: String, label: String? = nil) {
        self.init(name, default: "asset:" + name, label: label)
    }

    /// The role of that name: one of the fifteen, or a host's own once it has been declared.
    public init?(rawValue: String) {
        if let base = RipulColorRole.baseByName[rawValue] { self = base; return }
        RipulColorRole.lock.lock(); defer { RipulColorRole.lock.unlock() }
        guard let declared = RipulColorRole.declared[rawValue] else { return nil }
        self = declared
    }

    public static func == (a: RipulColorRole, b: RipulColorRole) -> Bool { a.rawValue == b.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    /// The name in the View Explorer: `ripul.accent` for one of the fifteen, and a host's
    /// own role by its own name.
    public var tokenName: String { isBase ? RipulTheme.prefix + rawValue : rawValue }

    /// The default as a document would write it, for a role whose default is one value.
    public var defaultReference: String { defaultValue.light.reference }

    public static let accent = RipulColorRole(base: "accent", "system:tint", "Accent")
    public static let onAccent = RipulColorRole(base: "onAccent", "#FFFFFF", "On accent")
    public static let canvas = RipulColorRole(base: "canvas", "system:systemBackground", "Canvas")
    public static let surface = RipulColorRole(base: "surface", "system:secondarySystemGroupedBackground", "Surface")
    public static let surfaceSunken = RipulColorRole(base: "surfaceSunken", "system:systemGroupedBackground", "Sunken surface")
    public static let text = RipulColorRole(base: "text", "system:label", "Text")
    public static let textSecondary = RipulColorRole(base: "textSecondary", "system:secondaryLabel", "Secondary text")
    public static let textTertiary = RipulColorRole(base: "textTertiary", "system:tertiaryLabel", "Tertiary text")
    public static let textQuaternary = RipulColorRole(base: "textQuaternary", "system:quaternaryLabel", "Quaternary text")
    public static let separator = RipulColorRole(base: "separator", "system:separator", "Separator")
    public static let success = RipulColorRole(base: "success", "system:systemGreen", "Success")
    public static let warning = RipulColorRole(base: "warning", "system:systemOrange", "Warning")
    public static let danger = RipulColorRole(base: "danger", "system:systemRed", "Danger")
    public static let info = RipulColorRole(base: "info", "system:systemBlue", "Information")
    public static let neutral = RipulColorRole(base: "neutral", "system:systemGray", "Neutral")

    /// The SDK's own fifteen, in their order. A host's roles are in `hostRoles`.
    public static let allCases: [RipulColorRole] = [
        .accent, .onAccent, .canvas, .surface, .surfaceSunken, .text, .textSecondary, .textTertiary,
        .textQuaternary, .separator, .success, .warning, .danger, .info, .neutral,
    ]

    /// The host's own roles declared so far, in name order. A role is declared when its
    /// `static let` is first read, so this is complete only once the app has drawn with each.
    public static var hostRoles: [RipulColorRole] {
        lock.lock(); defer { lock.unlock() }
        return declared.values.sorted { $0.rawValue < $1.rawValue }
    }

    private static let baseByName: [String: RipulColorRole] = Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0) })
    private static let lock = NSLock()
    private static var declared: [String: RipulColorRole] = [:]

    /// The first declaration of a name is kept, and one of the fifteen's names is never
    /// taken: such a role reads what the document says of the SDK's, with its own default.
    private static func declare(_ role: RipulColorRole) {
        guard baseByName[role.rawValue] == nil else {
            NSLog("[RipulTheme] a host role is named %@, which is one of the SDK's own roles", role.rawValue)
            return
        }
        lock.lock(); defer { lock.unlock() }
        if declared[role.rawValue] == nil { declared[role.rawValue] = role }
    }
}

/// One side of a colour: a platform system colour by name, or fixed components.
public enum RipulColorLiteral: Equatable, Sendable {
    /// `system:label`. Live: it follows light, dark and increased contrast.
    case system(String)
    case rgba(red: Double, green: Double, blue: Double, alpha: Double)
    /// `asset:BrandNavy`: a named colour of the app's asset catalogue. Live, like a system
    /// colour. For the default of a host's own role; a document writes values.
    case asset(String)

    /// Parse `system:<name>`, `asset:<name>`, `#RRGGBB`, `#RRGGBBAA` (the `#` optional). nil
    /// for anything else.
    public init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("asset:") {
            let name = String(s.dropFirst(6))
            guard !name.isEmpty else { return nil }
            self = .asset(name); return
        }
        if s.hasPrefix("system:") {
            let name = String(s.dropFirst(7))
            guard RipulTheme.systemColorNames.contains(name) else { return nil }
            self = .system(name); return
        }
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? (value << 8) | 0xFF : value
        self = .rgba(red: Double((rgba >> 24) & 0xFF) / 255, green: Double((rgba >> 16) & 0xFF) / 255,
                     blue: Double((rgba >> 8) & 0xFF) / 255, alpha: Double(rgba & 0xFF) / 255)
    }
}

extension RipulColorLiteral {
    /// The literal as a document writes it.
    public var reference: String {
        switch self {
        case .system(let name): return "system:" + name
        case .asset(let name): return "asset:" + name
        case .rgba(let r, let g, let b, let a):
            let byte = { (v: Double) in Int((max(0, min(1, v)) * 255).rounded()) }
            let hex = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
            return a < 0.999 ? hex + String(format: "%02X", byte(a)) : hex
        }
    }
}

/// A resolved colour: a light value and, when the theme gives one, a different dark value.
public struct RipulColorValue: Equatable, Sendable {
    public var light: RipulColorLiteral
    public var dark: RipulColorLiteral?
    public init(light: RipulColorLiteral, dark: RipulColorLiteral? = nil) { self.light = light; self.dark = dark }

    /// The system colour's name when this is one system colour for both appearances.
    public var systemName: String? {
        guard case .system(let name) = light, dark == nil || dark == light else { return nil }
        return name
    }

    /// The asset's name when this is one asset colour for both appearances.
    public var assetName: String? {
        guard case .asset(let name) = light, dark == nil || dark == light else { return nil }
        return name
    }
}

/// The three families a theme names. A type role belongs to one.
public enum RipulFontFamily: String, CaseIterable, Sendable {
    case text, display, code

    var defaultFace: String { self == .code ? "system-monospaced" : "system" }
}

/// A type role of the base vocabulary.
public enum RipulTextRole: String, CaseIterable, Sendable {
    case largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote, caption, caption2
    /// A display moment. `title` by default; a brand theme gives it the display family.
    case display
    /// A section header: `subheadline`, semibold.
    case eyebrow
    /// Code and other fixed-width text: `body` in the code family.
    case code

    /// The system text style this role is, and scales with, by default.
    public var defaultRelativeTo: RipulTextRole {
        switch self {
        case .display: return .title
        case .eyebrow: return .subheadline
        case .code: return .body
        default: return self
        }
    }

    public var defaultFamily: RipulFontFamily {
        switch self {
        case .display: return .display
        case .code: return .code
        default: return .text
        }
    }

    /// The weight the role adds to its system style by default; nil leaves the style's own.
    var defaultWeight: String? { self == .eyebrow ? "semibold" : nil }

    /// The weight the system's own style carries, which a custom face must be given.
    var intrinsicWeight: String? { defaultRelativeTo == .headline ? "semibold" : nil }

    /// Point size of the system style at the default Dynamic Type size.
    var systemPointSize: CGFloat {
        switch defaultRelativeTo {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        default: return 11
        }
    }
}

/// What a theme document says about one type role. Every field is optional; an empty
/// spec is the role's default.
public struct RipulTextRoleSpec: Equatable, Codable, Sendable {
    public var family: String?
    public var size: Double?
    public var weight: String?
    public var relativeTo: String?
    public var tracking: Double?
    public var uppercase: Bool?
    public var catalystSize: Double?
    public init() {}

    var isEmpty: Bool { self == RipulTextRoleSpec() }
}

/// The `typography` section of a theme document.
public struct RipulTypography: Equatable, Codable, Sendable {
    /// `text`, `display`, `code` to `system`, `system-serif`, `system-rounded`,
    /// `system-monospaced` or a bundled family's name.
    public var families: [String: String] = [:]
    public var roles: [String: RipulTextRoleSpec] = [:]
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        families = try c.decodeIfPresent([String: String].self, forKey: .families) ?? [:]
        roles = try c.decodeIfPresent([String: RipulTextRoleSpec].self, forKey: .roles) ?? [:]
    }
}

/// What SwiftUI watches. An accessor reads `revision` when it is called, and a body that
/// called one is run again when the theme changes: no view declares anything.
///
/// Written out rather than `@Observable`, so that the number itself sits behind a lock:
/// an accessor may read it off the main thread while the main thread bumps it.
final class RipulThemeStore: Observable, @unchecked Sendable {
    static let shared = RipulThemeStore()
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var stored = 0

    var revision: Int {
        registrar.access(self, keyPath: \.revision)
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    /// Main thread only: this is what tells SwiftUI to run the bodies again.
    func bump() {
        registrar.withMutation(of: self, keyPath: \.revision) {
            lock.lock(); stored += 1; lock.unlock()
        }
    }
}

public enum RipulTheme {
    /// The reserved prefix of the base vocabulary's colour roles in any theme document.
    public static let prefix = "ripul."

    /// The key of the type section in any host's theme document.
    public static let typographyKey = "typography"

    /// The names a `system:` value may carry.
    public static let systemColorNames: Set<String> = [
        "tint", "label", "secondaryLabel", "tertiaryLabel", "quaternaryLabel", "placeholderText",
        "separator", "opaqueSeparator", "link",
        "systemBackground", "secondarySystemBackground", "tertiarySystemBackground",
        "systemGroupedBackground", "secondarySystemGroupedBackground", "tertiarySystemGroupedBackground",
        "systemFill", "secondarySystemFill", "tertiarySystemFill", "quaternarySystemFill",
        "systemRed", "systemOrange", "systemYellow", "systemGreen", "systemMint", "systemTeal",
        "systemCyan", "systemBlue", "systemIndigo", "systemPurple", "systemPink", "systemBrown",
        "systemGray", "systemGray2", "systemGray3", "systemGray4", "systemGray5", "systemGray6",
    ]

    // MARK: state

    /// Everything the accessors read, resolved once per theme change and never mutated:
    /// an accessor runs in every row of a list and may be called off the main thread.
    final class Table: @unchecked Sendable {
        let typography: RipulTypography
        private let palette: [String: RipulColorValue]
        private let references: [String: String]
        /// The fifteen, resolved when the table is made.
        private let base: [RipulColorRole: (value: RipulColorValue, isDefault: Bool)]
        /// A host's own roles, each resolved when first asked for: a host declares a role
        /// by reading it, which may be after the document was adopted.
        private let hostLock = NSLock()
        private var host: [String: (value: RipulColorValue, isDefault: Bool)] = [:]

        init(palette: [String: RipulColorValue] = [:], references: [String: String] = [:],
             typography: RipulTypography = RipulTypography()) {
            self.palette = palette
            self.references = references
            self.typography = typography
            var base: [RipulColorRole: (value: RipulColorValue, isDefault: Bool)] = [:]
            for role in RipulColorRole.allCases {
                base[role] = Table.resolve(role, palette: palette, references: references)
            }
            self.base = base
        }

        func entry(_ role: RipulColorRole) -> (value: RipulColorValue, isDefault: Bool) {
            if let known = base[role] { return known }
            hostLock.lock(); defer { hostLock.unlock() }
            if let known = host[role.rawValue] { return known }
            let made = Table.resolve(role, palette: palette, references: references)
            host[role.rawValue] = made
            return made
        }

        private static func resolve(_ role: RipulColorRole, palette: [String: RipulColorValue],
                                    references: [String: String]) -> (value: RipulColorValue, isDefault: Bool) {
            let fallback = role.defaultValue
            guard let reference = references[role.rawValue] else { return (fallback, true) }
            let value = resolve(reference: reference, seen: [role.rawValue], palette: palette, references: references) ?? fallback
            return (value, value == fallback)
        }

        /// A reference is, tried in this order: a palette name, another role (followed until
        /// it ends), a literal. nil when it leads nowhere or round in a circle.
        private static func resolve(reference raw: String, seen: Set<String>, palette: [String: RipulColorValue],
                                    references: [String: String]) -> RipulColorValue? {
            if let value = palette[raw] { return value }
            let name = raw.hasPrefix(RipulTheme.prefix) ? String(raw.dropFirst(RipulTheme.prefix.count)) : raw
            if let role = RipulColorRole(rawValue: name) {
                guard !seen.contains(name) else { return nil }
                guard let next = references[name] else { return role.defaultValue }
                return resolve(reference: next, seen: seen.union([name]), palette: palette, references: references)
            }
            return RipulColorLiteral(raw).map { RipulColorValue(light: $0) }
        }
    }

    private static let lock = NSLock()
    private static var storedTable = Table()
    private static var storedDocument: Data?

    /// The SDK's part of the document in use, as JSON: what `adopt(documentData:)` last
    /// accepted (the object under the reserved key `ripul` when the document has one, else
    /// the whole document). nil when no document has been adopted, and again after
    /// `resetToDefaults()`. Written with sorted keys, so equal documents are equal bytes,
    /// and a host's own palette is never in it. May be read off the main thread.
    public static var adoptedDocumentData: Data? {
        lock.lock(); defer { lock.unlock() }
        return storedDocument
    }

    /// The live table. Reading it inside a SwiftUI body registers that body with the
    /// theme store, so the body runs again when a document is adopted (see "Live repaint"
    /// in docs/theming.md). Outside a body the read is just a read.
    static var table: Table {
        _ = RipulThemeStore.shared.revision
        lock.lock(); defer { lock.unlock() }
        return storedTable
    }

    /// The live type section.
    public static var typography: RipulTypography { table.typography }

    /// Counts every change of the theme.
    public static var version: Int { RipulThemeStore.shared.revision }

    // MARK: loading

    /// The schema number this build reads. A document with a higher one is refused whole.
    public static let schema = 1

    /// The reserved top-level key under which the SDK's part lives in another host's theme
    /// document. A host's own palette and roles are never read.
    public static let reservedKey = "ripul"

    public enum DocumentError: Error, Equatable {
        case notAnObject
        /// The document was written for a newer SDK. The theme in use is left as it is.
        case newerSchema(Int)
    }

    /// Adopt a theme document. One rule for every document: if it has an object under
    /// the reserved key `ripul`, that object is the SDK's part and the rest is the host's
    /// business; otherwise the document itself is the SDK's part (Ripul's own file).
    /// The part holds `palette`, `roles` and `typography`. A role may be written
    /// `accent` or `ripul.accent`; a host's own role by its own name. A role's value is
    /// a palette name, another role, a colour string, or a light and dark pair.
    ///
    /// Anything unreadable inside it falls back to that role's default. A document that
    /// is not an object, or has a newer `schema`, throws and changes nothing.
    public static func adopt(documentData: Data) throws {
        let (new, part) = try parse(documentData)
        lock.lock(); storedTable = new; storedDocument = part; lock.unlock()
        let announce = {
            RipulThemeStore.shared.bump()
            #if os(iOS)
            applySystemTextAppearance()
            #endif
            NotificationCenter.default.post(name: .ripulThemeDidChange, object: nil)
        }
        if Thread.isMainThread { announce() } else { DispatchQueue.main.async(execute: announce) }
    }

    static func parse(_ data: Data) throws -> (table: Table, part: Data?) {
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DocumentError.notAnObject
        }
        let part = document[reservedKey] as? [String: Any] ?? document
        if let schema = (part["schema"] as? NSNumber)?.intValue, schema > RipulTheme.schema {
            throw DocumentError.newerSchema(schema)
        }
        var palette: [String: RipulColorValue] = [:]
        for (name, raw) in part["palette"] as? [String: Any] ?? [:] {
            if let value = colorValue(fromJSON: raw) { palette[name] = value }
        }
        var references: [String: String] = [:]
        for (name, raw) in part["roles"] as? [String: Any] ?? [:] {
            let role = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
            if let reference = raw as? String {
                references[role] = reference
            } else if let value = colorValue(fromJSON: raw) {
                // A light and dark pair written in place: a palette entry nothing else names.
                let entry = "\u{0}" + role
                palette[entry] = value
                references[role] = entry
            }
        }
        var typography = RipulTypography()
        if let section = part[typographyKey], JSONSerialization.isValidJSONObject(section),
           let decoded = try? JSONDecoder().decode(RipulTypography.self, from: JSONSerialization.data(withJSONObject: section)) {
            typography = decoded
        }
        return (Table(palette: palette, references: references, typography: typography),
                try? JSONSerialization.data(withJSONObject: part, options: [.sortedKeys]))
    }

    /// Back to the defaults in code: the system look.
    public static func resetToDefaults() {
        lock.lock(); storedTable = Table(); storedDocument = nil; lock.unlock()
        let announce = {
            RipulThemeStore.shared.bump()
            #if os(iOS)
            applySystemTextAppearance()
            #endif
            NotificationCenter.default.post(name: .ripulThemeDidChange, object: nil)
        }
        if Thread.isMainThread { announce() } else { DispatchQueue.main.async(execute: announce) }
    }

    /// A palette entry: a colour string, or `{ "light": …, "dark": … }`.
    static func colorValue(fromJSON raw: Any) -> RipulColorValue? {
        if let string = raw as? String { return RipulColorLiteral(string).map { RipulColorValue(light: $0) } }
        guard let pair = raw as? [String: Any], let light = (pair["light"] as? String).flatMap(RipulColorLiteral.init) else { return nil }
        return RipulColorValue(light: light, dark: (pair["dark"] as? String).flatMap(RipulColorLiteral.init))
    }

    // MARK: colour resolution

    /// True for `ripul.accent` and the rest of the base vocabulary.
    public static func isBaseRole(_ name: String) -> Bool {
        name.hasPrefix(prefix) && RipulColorRole(rawValue: String(name.dropFirst(prefix.count)))?.isBase == true
    }

    /// The role's colour in the live theme. Total: a reference that leads nowhere, or
    /// round in a circle, gives the role's default.
    public static func color(_ role: RipulColorRole) -> RipulColorValue { table.entry(role).value }

    /// True when the role resolves to exactly what it would with no theme at all.
    public static func isDefault(_ role: RipulColorRole) -> Bool { table.entry(role).isDefault }

    // MARK: type resolution

    /// A type role as the live theme has it, with the role's defaults filled in.
    public struct ResolvedTextRole: Equatable {
        public var role: RipulTextRole
        /// `system`, `system-serif`, `system-rounded`, `system-monospaced`, or a family name.
        public var face: String
        /// nil: the system size of `relativeTo`.
        public var size: CGFloat?
        /// nil: the system weight of `relativeTo`.
        public var weight: String?
        public var relativeTo: RipulTextRole
        public var tracking: CGFloat
        public var uppercase: Bool

        /// True when the face is the system font in one of its designs.
        public var isSystemFace: Bool { face.hasPrefix("system") }
    }

    /// The face a family resolves to in the live theme.
    public static func face(_ family: RipulFontFamily) -> String {
        table.typography.families[family.rawValue] ?? family.defaultFace
    }

    public static func text(_ role: RipulTextRole, family override: RipulFontFamily? = nil) -> ResolvedTextRole {
        let spec = table.typography.roles[role.rawValue] ?? RipulTextRoleSpec()
        let family = override ?? spec.family.flatMap(RipulFontFamily.init(rawValue:)) ?? role.defaultFamily
        var size = spec.size.map { CGFloat($0) }
        #if targetEnvironment(macCatalyst)
        if let fixed = spec.catalystSize { size = CGFloat(fixed) }
        #endif
        return ResolvedTextRole(
            role: role, face: face(family), size: size,
            weight: spec.weight ?? role.defaultWeight,
            relativeTo: spec.relativeTo.flatMap(RipulTextRole.init(rawValue:))?.defaultRelativeTo ?? role.defaultRelativeTo,
            tracking: CGFloat(spec.tracking ?? 0), uppercase: spec.uppercase ?? false)
    }
}
