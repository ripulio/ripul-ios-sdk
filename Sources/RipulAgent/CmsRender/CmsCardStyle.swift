import SwiftUI

// MARK: - Card styles in a site's theme (docs/plans/cms-cards.md §8)
//
// `cardStyles` and `defaultCardStyle` sit beside list styles. Three built-ins
// (`plain`, `elevated`, `outlined`, differing only in their surface) and a
// site's own styles based on one, colours as palette roles. The values and
// the merge are the web's (`packages/shared-types/src/cmsCards.ts`); the
// built-ins are its `cmsCardStyles.builtin.json`, and a test holds them equal.
// A style is kept as JSON, as the web keeps it, and read through
// `CmsResolvedCardStyle`.

enum CmsCardStyles {
    static let builtInNames = ["plain", "elevated", "outlined"]

    /// What the three built-ins share: everything but their surface.
    private static let shared = #"""
{
  "body": {
    "color": "mutedText",
    "size": 15,
    "weight": 400
  },
  "buttons": {
    "align": "start",
    "color": "primary",
    "cornerRadius": 999,
    "gap": 8,
    "iconSize": 24,
    "onColor": "paper",
    "paddingHorizontal": 16,
    "paddingVertical": 8,
    "size": 15,
    "weight": 600
  },
  "carousel": {
    "countColor": "mutedText",
    "countSize": 13,
    "dot": "divider",
    "dotActive": "primary",
    "gap": 12
  },
  "chip": {
    "borderWidth": 1,
    "color": "primary",
    "cornerRadius": 999,
    "iconSize": 14,
    "paddingHorizontal": 8,
    "paddingVertical": 3,
    "size": 12,
    "variant": "outlined",
    "weight": 600
  },
  "close": {
    "color": "mutedText",
    "size": 20
  },
  "eyebrow": {
    "color": "mutedText",
    "letterSpacing": 0.5,
    "size": 12,
    "uppercase": true,
    "weight": 600
  },
  "figures": {
    "gap": 16,
    "labelColor": "mutedText",
    "labelSize": 12,
    "valueColor": "text",
    "valueSize": 17,
    "valueWeight": 600
  },
  "inlineImage": {
    "cornerRadius": 4,
    "size": 18
  },
  "lines": {
    "color": "mutedText",
    "gap": 2,
    "size": 14,
    "weight": 400
  },
  "media": {
    "fill": "tint",
    "gap": 12,
    "shape": "roundedSquare",
    "size": 40,
    "tint": "primary",
    "topHeight": 140
  },
  "text": {
    "align": "leading",
    "gap": 4
  },
  "title": {
    "color": "text",
    "size": 17,
    "weight": 700
  },
  "tones": {
    "accent": {
      "accent": "paper",
      "fill": "accent",
      "muted": "paper",
      "text": "paper"
    },
    "error": {
      "accent": "paper",
      "fill": "error",
      "muted": "paper",
      "text": "paper"
    },
    "highlight": {
      "accent": "paper",
      "fill": "primary",
      "muted": "paper",
      "text": "paper"
    },
    "success": {
      "accent": "paper",
      "fill": "success",
      "muted": "paper",
      "text": "paper"
    },
    "tint": {
      "accent": "primary",
      "fill": "tint",
      "muted": "mutedText",
      "text": "text"
    },
    "warning": {
      "accent": "paper",
      "fill": "warning",
      "muted": "paper",
      "text": "paper"
    }
  },
  "value": {
    "color": "text",
    "size": 28,
    "weight": 700
  }
}
"""#

    private static let surfaces = #"""
{
  "elevated": {
    "border": {
      "color": "divider",
      "width": 0
    },
    "cornerRadius": 16,
    "fill": "paper",
    "gap": 12,
    "padding": 16,
    "shadow": {
      "color": "text",
      "offsetY": 2,
      "opacity": 0.1,
      "radius": 12
    }
  },
  "outlined": {
    "border": {
      "color": "divider",
      "width": 1
    },
    "cornerRadius": 12,
    "fill": "paper",
    "gap": 12,
    "padding": 16,
    "shadow": {
      "color": "text",
      "offsetY": 0,
      "opacity": 0,
      "radius": 0
    }
  },
  "plain": {
    "border": {
      "color": "divider",
      "width": 0
    },
    "cornerRadius": 12,
    "fill": "paper",
    "gap": 12,
    "padding": 16,
    "shadow": {
      "color": "text",
      "offsetY": 0,
      "opacity": 0,
      "radius": 0
    }
  }
}
"""#

    /// The three built-ins, every setting filled.
    static let builtIns: [String: [String: CmsJSON]] = {
        let common = (try? JSONDecoder().decode([String: CmsJSON].self, from: Data(shared.utf8))) ?? [:]
        let surface = (try? JSONDecoder().decode([String: CmsJSON].self, from: Data(surfaces.utf8))) ?? [:]
        var out: [String: [String: CmsJSON]] = [:]
        for name in builtInNames {
            var style = common
            style["base"] = .string(name)
            style["surface"] = surface[name] ?? .object([:])
            out[name] = style
        }
        return out
    }()

    /// The colour settings, as paths: each must name a palette role.
    static let colourPaths: [[String]] = [
        ["surface", "fill"], ["surface", "border", "color"], ["surface", "shadow", "color"],
        ["media", "fill"], ["media", "tint"],
        ["eyebrow", "color"], ["title", "color"], ["body", "color"], ["value", "color"],
        ["figures", "labelColor"], ["figures", "valueColor"], ["close", "color"],
        ["lines", "color"], ["chip", "color"],
        ["buttons", "color"], ["buttons", "onColor"],
        ["carousel", "dot"], ["carousel", "dotActive"], ["carousel", "countColor"],
    ]

    static func exists(_ name: String, config: CmsPortalThemeConfig?) -> Bool {
        builtIns[name] != nil || config?.cardStyles?[name]?.objectValue != nil
    }

    /// The block's style, else the theme's default, else `elevated`. A name
    /// that names no style is passed over.
    static func name(config: CmsPortalThemeConfig?, block: String?) -> String {
        for candidate in [block, config?.defaultCardStyle] {
            if let name = candidate, !name.isEmpty, exists(name, config: config) { return name }
        }
        return "elevated"
    }

    /// A style with every setting filled. Twin of `resolveCardStyle`: a site
    /// style merges over its base at any depth, keeping a value only where
    /// the base has one of the same kind; a colour that isn't a role, an
    /// unknown media shape or chip variant keeps the base's; tones merge by
    /// name over the base's, a new one starting from paper, text, mutedText
    /// and primary.
    static func resolve(config: CmsPortalThemeConfig?, name: String) -> (name: String, json: [String: CmsJSON]) {
        if let builtIn = builtIns[name] { return (name, builtIn) }
        guard let own = config?.cardStyles?[name]?.objectValue else { return ("elevated", builtIns["elevated"]!) }
        let baseName = own.string("base").flatMap { builtIns[$0] != nil ? $0 : nil } ?? "elevated"
        let base = builtIns[baseName]!
        var settings = own
        settings["base"] = nil
        let tones = settings.removeValue(forKey: "tones")
        var merged = overlay(base, settings)
        for path in colourPaths where !isRole(get(merged, path)) {
            set(&merged, path, get(base, path) ?? .null)
        }
        if !["circle", "roundedSquare", "square", "none"].contains(get(merged, ["media", "shape"])?.stringValue ?? "") {
            set(&merged, ["media", "shape"], get(base, ["media", "shape"]) ?? .null)
        }
        if !["leading", "center"].contains(get(merged, ["text", "align"])?.stringValue ?? "") {
            set(&merged, ["text", "align"], get(base, ["text", "align"]) ?? .null)
        }
        if !["start", "center"].contains(get(merged, ["buttons", "align"])?.stringValue ?? "") {
            set(&merged, ["buttons", "align"], get(base, ["buttons", "align"]) ?? .null)
        }
        if !["filled", "outlined", "tinted"].contains(get(merged, ["chip", "variant"])?.stringValue ?? "") {
            set(&merged, ["chip", "variant"], get(base, ["chip", "variant"]) ?? .null)
        }
        var allTones = base.object("tones") ?? [:]
        for (tone, look) in tones?.objectValue ?? [:] {
            guard let look = look.objectValue else { continue }
            let start = allTones[tone]?.objectValue ?? [
                "fill": .string("paper"), "text": .string("text"), "muted": .string("mutedText"), "accent": .string("primary"),
            ]
            var out: [String: CmsJSON] = [:]
            for key in ["fill", "text", "muted", "accent"] {
                out[key] = isRole(look[key]) ? look[key]! : start[key] ?? .null
            }
            allTones[tone] = .object(out)
        }
        merged["tones"] = .object(allTones)
        merged["base"] = .string(baseName)
        return (name, merged)
    }

    /// Twin of `overlay`: only keys the base has, objects merged at any
    /// depth, a value kept only when it is the same kind as the base's.
    static func overlay(_ base: [String: CmsJSON], _ over: [String: CmsJSON]) -> [String: CmsJSON] {
        var out = base
        for (key, value) in over {
            guard value != .null, let b = base[key] else { continue }
            if let bo = b.objectValue {
                if let vo = value.objectValue { out[key] = .object(overlay(bo, vo)) }
            } else if sameKind(b, value) {
                out[key] = value
            }
        }
        return out
    }

    private static func sameKind(_ a: CmsJSON, _ b: CmsJSON) -> Bool {
        switch (a, b) {
        case (.string, .string), (.number, .number), (.bool, .bool), (.array, .array): return true
        default: return false
        }
    }

    static func isRole(_ value: CmsJSON?) -> Bool {
        value?.stringValue.flatMap(CmsPaletteRole.init(rawValue:)) != nil
    }

    static func get(_ json: [String: CmsJSON], _ path: [String]) -> CmsJSON? {
        var current: CmsJSON? = .object(json)
        for key in path { current = current?.objectValue?[key] }
        return current
    }

    static func set(_ json: inout [String: CmsJSON], _ path: [String], _ value: CmsJSON) {
        guard let head = path.first else { return }
        if path.count == 1 { json[head] = value; return }
        var child = json[head]?.objectValue ?? [:]
        set(&child, Array(path.dropFirst()), value)
        json[head] = .object(child)
    }
}

/// A card style ready to draw: numbers and colours read from the resolved
/// style, colours from the site's palette (the dark one when dark).
struct CmsResolvedCardStyle {
    let name: String
    let json: [String: CmsJSON]
    let theme: CmsPortalTheme

    init(config: CmsPortalThemeConfig?, block: String?, theme: CmsPortalTheme) {
        let resolved = CmsCardStyles.resolve(config: config, name: CmsCardStyles.name(config: config, block: block))
        name = resolved.name
        json = resolved.json
        self.theme = theme
    }

    func number(_ path: String...) -> CGFloat {
        CGFloat(CmsCardStyles.get(json, path)?.doubleValue ?? 0)
    }

    func flag(_ path: String...) -> Bool { CmsCardStyles.get(json, path)?.boolValue ?? false }

    func string(_ path: String...) -> String? { CmsCardStyles.get(json, path)?.stringValue }

    func role(_ path: String...) -> CmsPaletteRole {
        CmsCardStyles.get(json, path)?.stringValue.flatMap(CmsPaletteRole.init(rawValue:)) ?? .text
    }

    func color(_ path: String...) -> Color {
        theme.color(role: CmsCardStyles.get(json, path)?.stringValue.flatMap(CmsPaletteRole.init(rawValue:)) ?? .text)
    }

    func rgba(_ path: String...) -> CmsRGBA {
        theme.rgba(role: CmsCardStyles.get(json, path)?.stringValue.flatMap(CmsPaletteRole.init(rawValue:)) ?? .text)
    }

    /// A tone of the style, as colours; nil for a name the style lacks.
    func tone(_ name: String?) -> Tone? {
        guard let name, let look = json.object("tones")?.object(name) else { return nil }
        func c(_ key: String) -> Color {
            theme.color(role: look.string(key).flatMap(CmsPaletteRole.init(rawValue:)) ?? .text)
        }
        return Tone(fill: c("fill"), text: c("text"), muted: c("muted"), accent: c("accent"))
    }

    struct Tone {
        var fill: Color
        var text: Color
        var muted: Color
        var accent: Color
    }

    /// The style's lines, chip and inline picture as a list style, so the
    /// list row's pieces draw them unchanged.
    var listStyle: CmsResolvedListStyle {
        func part<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            guard let value = json[key], let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        var style = CmsListStyle.cards
        style.lines = part("lines", CmsListStyle.Lines.self) ?? style.lines
        style.chip = part("chip", CmsListStyle.Chip.self) ?? style.chip
        style.inlineImage = part("inlineImage", CmsListStyle.InlineImage.self) ?? style.inlineImage
        return CmsResolvedListStyle(style: style, theme: theme)
    }
}
