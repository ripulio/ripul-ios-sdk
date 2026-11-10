import MarkdownUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A markdown block in the site's text styles, as the web's MarkdownBlock: its
/// text in the block's typography (else the site's body1), the source's headings
/// in the site's h1–h6 (in the block's own colour when it sets one, never its
/// alignment), and the theme's paragraph spacing after paragraphs and lists (half
/// after headings). Nil when nothing of the site's applies: the block keeps the
/// renderer's own look, as the web's does.
struct CmsSiteMarkdown {
    let body: CmsSiteText
    let headings: [Int: CmsSiteText]
    /// The block's own colour, which its headings take too.
    let ownColour: String?
    /// Points after a paragraph or list.
    let spacing: CGFloat?
    let linkColour: String?

    init?(typography: [String: CmsJSON]?, config: CmsPortalThemeConfig.Typography?, linkColour: String?, viewport: CGFloat) {
        guard let body = CmsSiteText.resolve(typography: typography, element: "p", styles: config?.styles, viewport: viewport) else { return nil }
        self.body = body
        var headings: [Int: CmsSiteText] = [:]
        for level in 1...6 where config?.styles?["h\(level)"] != nil {
            if var h = CmsSiteText.resolve(typography: ["variant": .string("h\(level)")], element: "h\(level)",
                                            styles: config?.styles, viewport: viewport) {
                h.align = nil
                headings[level] = h
            }
        }
        self.headings = headings
        ownColour = typography?.string("color")
        let size = body.size ?? 16
        spacing = CmsCssLength.points(config?.paragraphSpacing, viewport: viewport, base: size)
        self.linkColour = linkColour.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Dynamic Type: the site's points scaled as the body text style is.
    private static func scaled(_ points: CGFloat) -> CGFloat {
        #if os(iOS)
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: points)
        #else
        return points
        #endif
    }

    @MainActor
    func theme(colour: (String?) -> Color?, fallback: Color) -> Theme {
        let bodyColour = body.color.flatMap { colour($0) } ?? fallback
        let bodySize = Self.scaled(body.size ?? 16)
        let bodyFamily = CmsSiteText.installedFamily(stack: body.family)
        let bodyWeight = CmsTypography.weight(css: body.weight ?? 400)
        let italic = body.italic
        let spacing = self.spacing
        let lineExtra = body.lineHeight.map { max(0, $0 - 1.2) } ?? 0.2
        var theme = Theme.basic
            .text {
                if let bodyFamily { FontFamily(.custom(bodyFamily)) }
                FontSize(bodySize)
                FontWeight(bodyWeight)
                if italic { FontStyle(.italic) }
                ForegroundColor(bodyColour)
            }
            .strong { FontWeight(.bold) }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(lineExtra))
                    .markdownMargin(top: 0, bottom: spacing ?? 12)
            }
            .list { configuration in
                configuration.label.markdownMargin(top: 0, bottom: spacing ?? 12)
            }
        // Links underlined, as the web's (MUI's) are, in the block's linkColor when it sets one.
        if let link = linkColour.flatMap({ colour($0) }) {
            theme = theme.link {
                ForegroundColor(link)
                UnderlineStyle(.single)
            }
        } else {
            theme = theme.link { UnderlineStyle(.single) }
        }
        for (level, style) in headings {
            let headingColour = (ownColour ?? style.color).flatMap { colour($0) } ?? bodyColour
            let family = CmsSiteText.installedFamily(stack: style.family) ?? bodyFamily
            let size = Self.scaled(style.size ?? bodySize)
            let weight = CmsTypography.weight(css: style.weight ?? 600)
            let headingItalic = style.italic
            let extra = style.lineHeight.map { max(0, $0 - 1.2) } ?? 0.1
            let look = HeadingLook(family: family, size: size, weight: weight, italic: headingItalic, colour: headingColour,
                                   extra: extra, after: spacing.map { $0 / 2 } ?? 8)
            switch level {
            case 1: theme = theme.heading1 { look.view($0) }
            case 2: theme = theme.heading2 { look.view($0) }
            case 3: theme = theme.heading3 { look.view($0) }
            case 4: theme = theme.heading4 { look.view($0) }
            case 5: theme = theme.heading5 { look.view($0) }
            default: theme = theme.heading6 { look.view($0) }
            }
        }
        return theme
    }

    /// A heading in one of the site's heading styles.
    private struct HeadingLook {
        let family: String?
        let size: CGFloat
        let weight: Font.Weight
        let italic: Bool
        let colour: Color
        let extra: CGFloat
        let after: CGFloat

        func view(_ configuration: BlockConfiguration) -> some View {
            configuration.label
                .markdownTextStyle {
                    if let family { FontFamily(.custom(family)) }
                    FontSize(size)
                    FontWeight(weight)
                    if italic { FontStyle(.italic) }
                    ForegroundColor(colour)
                }
                .relativeLineSpacing(.em(extra))
                .markdownMargin(top: 0, bottom: after)
        }
    }

    var alignment: TextAlignment {
        body.align == "center" ? .center : body.align == "right" || body.align == "end" ? .trailing : .leading
    }

    var frameAlignment: Alignment {
        body.align == "center" ? .center : body.align == "right" || body.align == "end" ? .trailing : .leading
    }
}
