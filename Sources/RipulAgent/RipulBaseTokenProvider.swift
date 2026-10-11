#if os(iOS)
import UIKit

// MARK: - The base vocabulary's answer in the View Explorer
//
// Answers "which theme tokens style this element?" for any app whose views read the base
// vocabulary (the theme accessors of docs/theming.md). Nothing registers
// it and no call site declares anything:
//
//  - A SwiftUI element is looked up by its identifier in the build's theme usage map
//    (`RipulThemeUsage.swift`; written by `tools/ripul-theme usage-map` in the app's build).
//  - A view with no identifier of its own gets the nearest identified element around it,
//    and the answer says so.
//  - A UIKit view holds its font and colour, so they are read off it and compared with
//    the roles' values. A match is reported as a match, not as what the code wrote.
//
// It never takes over a host's own provider (`RipulTokenInspector.provider`): the host is
// asked first, and this answers only where the host has nothing to say.
//
// Reading only. `remap` changes nothing: the theme editor cannot yet write these tokens
// without flattening a light and dark pair (docs/theming.md, "Limits").

/// What the explorer shows for a selected view: the tokens, and a sentence when there is
/// less to say than a person would expect.
public struct RipulAppearanceReadout {
    public let bindings: [RipulTokenBinding]
    /// Why nothing, or less than everything, could be named. A sentence a person can act on.
    public let note: String?
    /// The provider that answered, for opening a binding's detail. nil when none did.
    public let provider: RipulTokenProvider?

    /// The readout as text, one line a binding: what `explorer_probe` and Copy return.
    public var lines: [String] {
        var out = bindings.map { binding -> String in
            let name = binding.tokenName.replacingOccurrences(of: "\n", with: ", ")
            return "\(binding.property): \(name)" + (binding.kind == .colourToken ? " [\(binding.swatchHex)]" : "")
        }
        if let note { out.append("note: \(note)") }
        return out
    }
}

@MainActor
public final class RipulBaseTokenProvider: RipulTokenProvider {
    public static let shared = RipulBaseTokenProvider()

    /// The map in the app's bundle, read once. nil when the build carries none.
    private lazy var map: RipulThemeUsageMap? = {
        guard let url = Bundle.main.url(forResource: RipulThemeUsageMap.resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return RipulThemeRedirect.usageMap }
        return RipulThemeUsageMap(data: data)
    }()

    /// For tests and for a host that keeps its map somewhere else.
    public func use(map: RipulThemeUsageMap?) { self.map = map }

    public func tokenBindings(for view: UIView) -> [RipulTokenBinding] { readout(for: view, uiKitMatches: true).bindings }

    /// Reading only: see the head of this file.
    public func remap(_ binding: RipulTokenBinding, to option: RipulTokenOption) -> String? { nil }

    public func remapSections(for binding: RipulTokenBinding, view: UIView) -> [RipulThemeRemapSection] { [] }

    // MARK: the answer

    /// - Parameter uiKitMatches: compare a UIKit view's own font and colours with the roles.
    ///   Off inside a host with its own provider, where a host's label that happens to be
    ///   the system's label colour is not a use of this vocabulary.
    /// - Parameter selected: the view the person picked, when the explorer resolved it to the
    ///   identifier stamp `view`. A picked view much smaller than its stamp is a part of that
    ///   element with no identifier of its own, and the answer says so.
    func readout(for view: UIView, selected: UIView? = nil, uiKitMatches: Bool) -> RipulAppearanceReadout {
        var bindings: [RipulTokenBinding] = []
        var notes: [String] = []

        let picked = selected ?? view
        let drawn = uiKitMatches ? uiKitBindings(for: picked) : []
        bindings += drawn
        // Text in a navigation bar, a segmented control or a tab bar is UIKit's: what the
        // view holds is the whole answer, and no SwiftUI element's tokens are its own.
        if !drawn.isEmpty, Self.systemText(around: picked) != nil {
            return RipulAppearanceReadout(bindings: bindings, note: nil, provider: self)
        }

        let own = Self.ownIdentifier(of: view)
        if let map {
            if let own, let answer = map.answer(for: own), !answer.lines.isEmpty {
                if Self.isPart(selected, of: view), Self.coversMostOfItsWindow(view) {
                    // The nearest identifier is the whole screen's: its tokens are every
                    // element's on it, and listing them says nothing about this one.
                    notes.append("The nearest identified element is \(own), which is the whole screen, so its tokens are not listed: they are every element's on it. "
                        + "This view has no identifier of its own that the explorer could resolve.")
                    return RipulAppearanceReadout(bindings: bindings, note: notes.joined(separator: " "), provider: self)
                }
                if Self.isPart(selected, of: view) {
                    bindings.append(Self.information("shownFor", "Tokens shown for", "\(own)\nthe identified element this view is a part of: the part has no identifier of its own, so which of these it uses is not known"))
                }
                bindings += self.bindings(answer, view: view)
                notes += Self.notes(answer, nearest: false)
            } else if let near = nearestAnswer(around: view, in: map, excluding: own) {
                bindings.append(Self.information("shownFor", "Tokens shown for", "\(near.identifier)\nthe nearest identified element around this view"))
                bindings += self.bindings(near, view: view)
                notes += Self.notes(near, nearest: true)
                if let own {
                    notes.append(map.answer(for: own) == nil
                        ? "\(own) is not in this build's theme usage map."
                        : "\(own) names no theme token in its own source.")
                }
            } else if drawn.isEmpty {
                notes.append(Self.nothing(own: own, map: map))
            }
        } else if drawn.isEmpty {
            notes.append("This build carries no theme usage map, so the tokens of a SwiftUI element cannot be named. "
                + "The app's build writes it with one Run Script phase: \"<the RipulAgent package>/tools/ripul-theme\" usage-map (docs/theming-for-hosts.md).")
        }
        return RipulAppearanceReadout(bindings: bindings, note: notes.isEmpty ? nil : notes.joined(separator: " "), provider: self)
    }

    private static func notes(_ answer: RipulThemeUsageAnswer, nearest: Bool) -> [String] {
        var notes: [String] = []
        if answer.textWithNoFont {
            notes.append("No font is written on this element: its text takes the font of the view around it, which under a theme root is the body role.")
        }
        if !answer.parts.isEmpty {
            notes.append("Parts with tokens of their own: \(answer.parts.prefix(6).joined(separator: ", "))\(answer.parts.count > 6 ? " and more" : "").")
        }
        if answer.truncated { notes.append("The list is cut short: the element is built from many views.") }
        return notes
    }

    private static func nothing(own: String?, map: RipulThemeUsageMap) -> String {
        guard let own else {
            return "This view has no identifier and nothing identified is around it, so there is nothing to look its tokens up by. "
                + "Give the element .uiKitIdentifier(\"Screen.part\") and rebuild."
        }
        if let known = map.sites(for: own) {
            let place = known.sites.first.map { " (\(($0.file as NSString).lastPathComponent):\($0.line))" } ?? ""
            return "\(own)\(place) names no theme token in its own source: its colours and fonts come from a parameter, "
                + "from the view that contains it, or from the system."
        }
        return "\(own) is not in this build's theme usage map: the identifier is set outside the sources the map reads "
            + "(in UIKit, from a variable, or in another package), so its tokens cannot be named."
    }

    // MARK: identity

    private static func coversMostOfItsWindow(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        let frame = view.convert(view.bounds, to: nil)
        return frame.width * frame.height > 0.5 * window.bounds.width * window.bounds.height
    }

    /// True when the picked view covers well under half of the stamp it resolved to.
    private static func isPart(_ selected: UIView?, of stamp: UIView) -> Bool {
        guard let selected, selected !== stamp, selected.window != nil, stamp.window != nil else { return false }
        let a = selected.convert(selected.bounds, to: nil), b = stamp.convert(stamp.bounds, to: nil)
        return a.width * a.height < 0.4 * b.width * b.height
    }

    private static func ownIdentifier(of view: UIView) -> String? {
        if let id = UIKitIdentifierRegistry.shared.identifier(for: view) { return id }
        guard let id = view.accessibilityIdentifier, !id.isEmpty else { return nil }
        return id
    }

    /// The tightest identified element around `view` that the map has tokens for: the
    /// stamps under the view's centre, front to back, then the views above it.
    private func nearestAnswer(around view: UIView, in map: RipulThemeUsageMap, excluding own: String?) -> RipulThemeUsageAnswer? {
        var candidates: [String] = []
        if view.window != nil {
            let centre = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let frame = view.convert(view.bounds, to: nil)
            for match in UIKitIdentifierRegistry.shared.matches(at: centre) {
                // Around the view, not a smaller thing that merely sits on its centre.
                let stamp = match.view.convert(match.view.bounds, to: nil).insetBy(dx: -1, dy: -1)
                if stamp.contains(frame) || frame.width * frame.height <= 1 { candidates.append(match.identifier) }
            }
        }
        var ancestor = view.superview
        while let current = ancestor {
            if let id = Self.ownIdentifier(of: current) { candidates.append(id) }
            ancestor = current.superview
        }
        for id in candidates where id != own {
            if let answer = map.answer(for: id), !answer.lines.isEmpty { return answer }
        }
        return nil
    }

    // MARK: bindings

    private static func information(_ id: String, _ property: String, _ text: String) -> RipulTokenBinding {
        RipulTokenBinding(id: "ripul.base." + id, property: property, tokenName: text, resolvesTo: nil,
                          swatchHex: "", options: [], kind: .information, isReadOnly: true)
    }

    private func bindings(_ answer: RipulThemeUsageAnswer, view: UIView) -> [RipulTokenBinding] {
        var out = answer.lines.enumerated().map { index, line in
            binding(line, id: "\(answer.identifier).\(index)", view: view)
        }
        out.append(Self.information("where." + answer.identifier, "Written in", answer.places.joined(separator: ", ")))
        return out
    }

    private func binding(_ line: RipulThemeUsageLine, id: String, view: UIView) -> RipulTokenBinding {
        let text = "\(line.token)\n\(line.value) · \(line.origin)"
        guard let value = line.colour else { return Self.information(id, line.property, text) }
        let colour = line.isWindowTint ? (view.tintColor ?? .tintColor) : RipulTheme.platformColor(value)
        return RipulTokenBinding(id: "ripul.base." + id, property: line.property, tokenName: text,
                                 resolvesTo: line.value, swatchHex: Self.hex(colour, in: view),
                                 options: [], kind: .colourToken, isReadOnly: true)
    }

    // MARK: UIKit views

    /// A UIKit view holds what it is drawn with. Each value is compared with the roles'.
    private func uiKitBindings(for view: UIView) -> [RipulTokenBinding] {
        var font: UIFont?
        var textColour: UIColor?
        // The explorer selects a bar's title control or a segment, and the label is inside it.
        var view = view
        if !(view is UILabel), Self.systemText(around: view) != nil, let label = Self.onlyLabel(in: view) { view = label }
        switch view {
        case let label as UILabel: font = label.font; textColour = label.textColor
        case let field as UITextField: font = field.font; textColour = field.textColor
        case let text as UITextView: font = text.font; textColour = text.textColor
        case let button as UIButton:
            // A button with no title has a title label all the same: its font says nothing.
            guard let title = button.titleLabel?.text, !title.isEmpty else { break }
            font = button.titleLabel?.font; textColour = button.currentTitleColor
        default: break
        }
        var out: [RipulTokenBinding] = []
        if let font {
            let face = "\(font.familyName) \(RipulTheme.number(font.pointSize)) pt"
            if let match = Self.typeRole(matching: font) {
                let origin = RipulTheme.typeOrigin(role: match.role, family: match.role.defaultFamily)
                let name = match.weight.map { "\(match.role.rawValue) \($0)" } ?? match.role.rawValue
                out.append(Self.information("uikit.font", "Font (read from the view)", "\(name)\n\(face) · \(origin) · same face and size as this role"))
            } else {
                out.append(Self.information("uikit.font", "Font (read from the view)", "no type role\n\(face) · set in code or by the system: no role has this face and size"))
            }
            if let bar = Self.systemText(around: view) {
                out.append(Self.information("uikit.fontSetBy", "Font set by", RipulTheme.hasThemedTextFamily
                    ? "the theme, through UIKit's appearance settings for \(bar)"
                    : "the system: a theme that names a text family restyles \(bar)"))
            }
        }
        if let textColour, let binding = colourBinding("uikit.text", "Text colour (read from the view)", textColour, view) { out.append(binding) }
        // A container's ground says little about the element picked inside it, so a
        // background is read only off a view that draws text or is a cell.
        let drawsItself = font != nil || view is UITableViewCell || view is UICollectionViewCell
        if drawsItself, let background = view.backgroundColor, background != .clear,
           let binding = colourBinding("uikit.background", "Background (read from the view)", background, view) { out.append(binding) }
        return out
    }

    private func colourBinding(_ id: String, _ property: String, _ colour: UIColor, _ view: UIView) -> RipulTokenBinding? {
        let hex = Self.hex(colour, in: view)
        for role in RipulColorRole.allCases where role != .accent || !RipulTheme.isDefault(.accent) {
            guard colour == RipulTheme.platformColor(RipulTheme.color(role)) else { continue }
            let origin = RipulTheme.isDefault(role) ? "default" : "theme document"
            return RipulTokenBinding(id: "ripul.base." + id, property: property,
                                     tokenName: "\(role.tokenName)\n\(RipulTheme.describe(RipulTheme.color(role))) · \(origin) · the same colour as this role",
                                     resolvesTo: nil, swatchHex: hex, options: [], kind: .colourToken, isReadOnly: true)
        }
        if colour == view.tintColor {
            let origin = RipulTheme.isDefault(.accent) ? "default" : "theme document"
            return RipulTokenBinding(id: "ripul.base." + id, property: property,
                                     tokenName: "\(RipulColorRole.accent.tokenName)\n\(RipulTheme.describe(RipulTheme.color(.accent))) · \(origin) · the view's tint",
                                     resolvesTo: nil, swatchHex: hex, options: [], kind: .colourToken, isReadOnly: true)
        }
        return nil
    }

    /// The type role whose UIKit font has this face and size, trying the role's own weight first.
    private static func typeRole(matching font: UIFont) -> (role: RipulTextRole, weight: String?)? {
        let weights: [(String?, UIFont.Weight?)] = [(nil, nil), ("regular", .regular), ("medium", .medium), ("semibold", .semibold), ("bold", .bold)]
        for (name, weight) in weights {
            for role in RipulTextRole.allCases where role != .display && role != .eyebrow && role != .code {
                let candidate = roleFont(role, weight)
                if candidate.fontName == font.fontName, abs(candidate.pointSize - font.pointSize) < 0.26 { return (role, name) }
            }
        }
        return nil
    }

    /// The swatch for a colour as this view draws it.
    private static func hex(_ colour: UIColor, in view: UIView) -> String {
        // `#RRGGBB`, or `#RRGGBBAA` for a colour that is not opaque (the system's secondary
        // label is 60 per cent): an opaque swatch of a translucent colour looks nothing like it.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard colour.resolvedColor(with: view.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        let byte = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        let hex = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        return a < 0.995 ? hex + String(format: "%02X", byte(a)) : hex
    }

    /// The role's font as a UIKit view would hold it. Read to compare, not to draw.
    private static func roleFont(_ role: RipulTextRole, _ weight: UIFont.Weight?) -> UIFont {
        UIFont.ripul(role, weight: weight)  // theme-mapping: read to compare with a view's font; nothing is replaced
    }

    /// The one label under `view`, three levels down at most. nil when there are none or several.
    private static func onlyLabel(in view: UIView) -> UILabel? {
        var found: [UILabel] = []
        func walk(_ v: UIView, _ depth: Int) {
            if let label = v as? UILabel { found.append(label); return }
            guard depth < 3 else { return }
            for sub in v.subviews { walk(sub, depth + 1) }
        }
        walk(view, 0)
        return found.count == 1 ? found[0] : nil
    }

    /// The bar whose text UIKit draws and `applySystemTextAppearance` restyles, if `view` is in one.
    private static func systemText(around view: UIView) -> String? {
        var current: UIView? = view
        while let v = current {
            if v is UINavigationBar { return "navigation titles" }
            if v is UISegmentedControl { return "segmented controls" }
            if v is UITabBar { return "tab bar labels" }
            current = v.superview
        }
        return nil
    }
}

extension RipulTokenInspector {
    /// Whether the base vocabulary answers where the host's provider has nothing to say.
    /// On by default; a host that wants only its own tokens shown sets it false.
    public static var answersForBaseVocabulary = true

    /// The explorer's answer for a view. The host's provider is asked first and its answer
    /// stands alone when it has one. Otherwise the base vocabulary answers: fully in an
    /// app with no provider of its own, and from the usage map only inside a host that has
    /// one (there a UIKit view's colours are the host's business).
    /// - Parameter selected: the view the person picked, when it is not `view` itself.
    public static func readout(for view: UIView, selected: UIView? = nil) -> RipulAppearanceReadout {
        if let provider {
            let bindings = provider.tokenBindings(for: view)
            if !bindings.isEmpty { return RipulAppearanceReadout(bindings: bindings, note: nil, provider: provider) }
        }
        guard answersForBaseVocabulary else {
            return RipulAppearanceReadout(bindings: [], provider: provider, note: provider == nil
                ? "No theme provider is registered and the base vocabulary's answer is switched off."
                : "The app's theme provider reports no token for this view.")
        }
        let base = RipulBaseTokenProvider.shared.readout(for: view, selected: selected, uiKitMatches: provider == nil)
        guard provider != nil, base.bindings.isEmpty else { return base }
        return RipulAppearanceReadout(bindings: [], provider: provider,
                                      note: "The app's theme provider reports no token for this view. " + (base.note ?? ""))
    }
}

extension RipulAppearanceReadout {
    init(bindings: [RipulTokenBinding], provider: RipulTokenProvider?, note: String?) {
        self.init(bindings: bindings, note: note, provider: provider)
    }
}
#endif
