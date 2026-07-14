import SwiftUI

/// Twin of the authored half of `resolveTypography` (typographyTokens.ts):
/// reads a TypographyValue props object. CSS px and iOS points map 1:1
/// (both density-independent at the same nominal scale; rem = 16). Family,
/// lineHeight and letterSpacing are accepted degradations for now — colour
/// is resolved by callers through the theme.
enum CmsTypography {
    /// Authored `size` (CSS string or number) in points.
    static func size(_ typography: [String: CmsJSON]?) -> CGFloat? {
        guard let raw = typography?["size"] else { return nil }
        if let n = raw.doubleValue { return CGFloat(n) }
        return CmsCss.points(raw.stringValue)
    }

    /// Authored numeric CSS weight (100–900) → the nearest Font.Weight.
    static func weight(_ typography: [String: CmsJSON]?) -> Font.Weight? {
        guard let n = typography?["weight"]?.doubleValue else { return nil }
        switch n {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }
}
