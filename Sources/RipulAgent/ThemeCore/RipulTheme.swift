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

/// A colour role of the base vocabulary. Named for the job, never for the value.
public enum RipulColorRole: String, CaseIterable, Sendable {
    case accent, onAccent
    case canvas, surface, surfaceSunken
    case text, textSecondary, textTertiary, textQuaternary
    case separator
    case success, warning, danger, info, neutral

    /// The name in a theme document and in the View Explorer: `ripul.accent`.
    public var tokenName: String { RipulTheme.prefix + rawValue }

    /// What the role resolves to when no document says otherwise: today's look.
    public var defaultReference: String {
        switch self {
        case .accent: return "system:tint"
        case .onAccent: return "#FFFFFF"
        case .canvas: return "system:systemBackground"
        case .surface: return "system:secondarySystemGroupedBackground"
        case .surfaceSunken: return "system:systemGroupedBackground"
        case .text: return "system:label"
        case .textSecondary: return "system:secondaryLabel"
        case .textTertiary: return "system:tertiaryLabel"
        case .textQuaternary: return "system:quaternaryLabel"
        case .separator: return "system:separator"
        case .success: return "system:systemGreen"
        case .warning: return "system:systemOrange"
        case .danger: return "system:systemRed"
        case .info: return "system:systemBlue"
        case .neutral: return "system:systemGray"
        }
    }

    /// A label for editors.
    public var label: String {
        switch self {
        case .accent: return "Accent"
        case .onAccent: return "On accent"
        case .canvas: return "Canvas"
        case .surface: return "Surface"
        case .surfaceSunken: return "Sunken surface"
        case .text: return "Text"
        case .textSecondary: return "Secondary text"
        case .textTertiary: return "Tertiary text"
        case .textQuaternary: return "Quaternary text"
        case .separator: return "Separator"
        case .success: return "Success"
        case .warning: return "Warning"
        case .danger: return "Danger"
        case .info: return "Information"
        case .neutral: return "Neutral"
        }
    }
}

/// One side of a colour: a platform system colour by name, or fixed components.
public enum RipulColorLiteral: Equatable, Sendable {
    /// `system:label`. Live: it follows light, dark and increased contrast.
    case system(String)
    case rgba(red: Double, green: Double, blue: Double, alpha: Double)

    /// Parse `system:<name>`, `#RRGGBB`, `#RRGGBBAA` (the `#` optional). nil for anything else.
    public init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let colors: [RipulColorRole: RipulColorValue]
        let defaults: Set<RipulColorRole>
        let typography: RipulTypography

        init(palette: [String: RipulColorValue] = [:], references: [String: String] = [:],
             typography: RipulTypography = RipulTypography()) {
            var colors: [RipulColorRole: RipulColorValue] = [:]
            var defaults: Set<RipulColorRole> = []
            for role in RipulColorRole.allCases {
                let fallback = RipulColorValue(light: RipulColorLiteral(role.defaultReference)!)
                let value = Table.resolve(reference: references[role.rawValue] ?? role.defaultReference,
                                          seen: [role.rawValue], palette: palette, references: references) ?? fallback
                colors[role] = value
                if value == fallback { defaults.insert(role) }
            }
            self.colors = colors
            self.defaults = defaults
            self.typography = typography
        }

        /// A reference is, tried in this order: a palette name, another role (followed until
        /// it ends), a literal. nil when it leads nowhere or round in a circle.
        private static func resolve(reference raw: String, seen: Set<String>, palette: [String: RipulColorValue],
                                    references: [String: String]) -> RipulColorValue? {
            if let value = palette[raw] { return value }
            let name = raw.hasPrefix(RipulTheme.prefix) ? String(raw.dropFirst(RipulTheme.prefix.count)) : raw
            if let role = RipulColorRole(rawValue: name) {
                guard !seen.contains(name) else { return nil }
                return resolve(reference: references[name] ?? role.defaultReference, seen: seen.union([name]),
                               palette: palette, references: references)
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
    /// `accent` or `ripul.accent`.
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
            guard let reference = raw as? String else { continue }
            references[name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name] = reference
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
        name.hasPrefix(prefix) && RipulColorRole(rawValue: String(name.dropFirst(prefix.count))) != nil
    }

    /// The role's colour in the live theme. Total: a reference that leads nowhere, or
    /// round in a circle, gives the role's default.
    public static func color(_ role: RipulColorRole) -> RipulColorValue { table.colors[role]! }

    /// True when the role resolves to exactly what it would with no theme at all.
    public static func isDefault(_ role: RipulColorRole) -> Bool { table.defaults.contains(role) }

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
