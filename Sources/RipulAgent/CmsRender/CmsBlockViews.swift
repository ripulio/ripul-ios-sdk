import SwiftUI
import MarkdownUI

// Native twins of the starter block set. Each mirrors the props contract of
// its web counterpart in chrome-extension/src/cms/blocks/registry/ — same
// prop names, same binding semantics, idiomatic native presentation.

// MARK: - text

struct CmsTextBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let raw = runtime.resolveString(block: block, propKey: "content") ?? ""
        let content = runtime.themeConfig?.typography?.smartQuotes == true ? CmsSiteText.typographicQuotes(raw) : raw
        let element = block.props.string("element") ?? "p"
        let style = CmsSiteText.resolve(typography: block.props.object("typography"), element: element,
                                        styles: runtime.themeConfig?.typography?.styles,
                                        viewport: CmsSiteText.viewportWidth)
        // Alignment from the block's typography, whichever way it draws.
        let align: Alignment = style?.align == "center" ? .center : style?.align == "right" || style?.align == "end" ? .trailing : .leading
        let textAlign: TextAlignment = align == .center ? .center : align == .trailing ? .trailing : .leading
        if let style, style.setsLettering {
            // The site's own text style for this element or variant (the web's siteTextStyle).
            let heading = Self.headingMetrics[element]
            Text(content)
                .modifier(CmsSiteTextModifier(style: style, fallbackSize: heading?.size ?? (element == "caption" ? 12 : 17),
                                              relativeTo: heading?.style ?? (element == "caption" ? .caption : .body),
                                              colour: runtime.textColor(style.color)))
                .frame(maxWidth: .infinity, alignment: align)
                .accessibilityAddTraits(heading != nil ? .isHeader : [])
        } else if let heading = Self.headingMetrics[element] {
            // Portal heading typography (theme v2): family / weight / tracking
            // apply to h1–h6 only, like the web's typography.h1…h6 overrides.
            // Dynamic Type sizing is kept — the family is relative to the
            // heading's text style.
            let theme = runtime.theme
            let weight = theme.headingWeight ?? heading.weight
            let font = theme.headingFontFamily
                .map { Font.custom($0, size: heading.size, relativeTo: heading.style) }
                ?? Font.system(heading.style)
            Text(content)
                .font(font.weight(weight))
                .tracking(CGFloat(theme.headingLetterSpacing ?? 0) * heading.size)
                .foregroundColor(typographyColor)
                .multilineTextAlignment(textAlign)
                .frame(maxWidth: .infinity, alignment: align)
        } else {
            Text(content)
                .font(element == "caption" ? .caption : .body)
                .foregroundColor(typographyColor)
                .multilineTextAlignment(textAlign)
                .frame(maxWidth: .infinity, alignment: align)
        }
    }

    private var typographyColor: Color {
        runtime.textColor(block.props.object("typography")?.string("color"))
    }

    /// h1–h6 → native text style, its default point size (for em tracking and
    /// custom-family sizing) and default weight.
    private static let headingMetrics: [String: (style: Font.TextStyle, size: CGFloat, weight: Font.Weight)] = [
        "h1": (.largeTitle, 34, .bold),
        "h2": (.title, 28, .bold),
        "h3": (.title2, 22, .semibold),
        "h4": (.title3, 20, .semibold),
        "h5": (.headline, 17, .semibold),
        "h6": (.subheadline, 15, .semibold),
    ]
}

// MARK: - markdown

struct CmsMarkdownBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let source = runtime.resolveString(block: block, propKey: "source") ?? ""
        if let site = CmsSiteMarkdown(typography: block.props.object("typography"), config: runtime.themeConfig?.typography,
                                      linkColour: block.props.string("linkColor"), viewport: CmsSiteText.viewportWidth) {
            // The site's text styles, as the web's MarkdownBlock lays them over its renderer.
            Markdown(source)
                .markdownTheme(site.theme(colour: { runtime.color($0) }, fallback: runtime.theme.textPrimary))
                .multilineTextAlignment(site.alignment)
                .frame(maxWidth: .infinity, alignment: site.frameAlignment)
        } else {
            Markdown(source)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - image

struct CmsImageBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let src = runtime.resolveString(block: block, propKey: "src") ?? ""
        let caption = runtime.resolveString(block: block, propKey: "caption")
        let shape = block.props.string("shape") ?? "square"

        VStack(alignment: .leading, spacing: 6) {
            if let url = URL(string: src), !src.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: block.props.string("fit") == "cover" ? .fill : .fit)
                    case .failure:
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .clipShape(imageShape(shape))
            }
            if let caption, !caption.isEmpty {
                let style = captionStyle
                Text(caption)
                    .modifier(CmsSiteTextModifier(style: style, fallbackSize: 12, relativeTo: .caption,
                                                  colour: runtime.color(style.color) ?? runtime.theme.textSecondary))
                    .frame(maxWidth: .infinity, alignment: style.align == "center" ? .center : style.align == "right" ? .trailing : .leading)
                    .padding(.top, 8)
            }
        }
    }

    /// The web: the caption style, the block's captionTypography over it.
    private var captionStyle: CmsSiteText {
        var typography = block.props.object("captionTypography") ?? [:]
        if typography["variant"] == nil { typography["variant"] = .string("caption") }
        return CmsSiteText.resolve(typography: typography, element: "caption",
                                   styles: runtime.themeConfig?.typography?.styles,
                                   viewport: CmsSiteText.viewportWidth) ?? CmsSiteText()
    }

    private func imageShape(_ shape: String) -> CmsAnyShape {
        switch shape {
        case "circle": return CmsAnyShape(Circle())
        case "rounded": return CmsAnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        default: return CmsAnyShape(Rectangle())
        }
    }
}

/// Type-erased Shape — SwiftUI.AnyShape ships in iOS 16; the SDK targets iOS 15.
struct CmsAnyShape: Shape {
    private let makePath: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        makePath = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        makePath(rect)
    }
}

// MARK: - divider

struct CmsDividerBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let label = runtime.resolveString(block: block, propKey: "label")
        if let label, !label.isEmpty {
            HStack(spacing: 12) {
                line
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize()
                line
            }
        } else {
            Divider()
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - section (container block with optional heading)

struct CmsSectionBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    /// `textAlign` (left, center, right), as the web's section sets it.
    private var align: (stack: HorizontalAlignment, frame: Alignment, text: TextAlignment) {
        switch block.props.string("textAlign") {
        case "center": return (.center, .center, .center)
        case "right": return (.trailing, .trailing, .trailing)
        default: return (.leading, .leading, .leading)
        }
    }

    var body: some View {
        let heading = runtime.resolveString(block: block, propKey: "heading").flatMap { $0.isEmpty ? nil : $0 }
        let action = block.props.object("headerAction")
        let align = align
        VStack(alignment: align.stack, spacing: 12) {
            if heading != nil || action != nil {
                HStack(alignment: .center, spacing: 8) {
                    if let heading {
                        Text(heading)
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    // `headerAction`: a button in the heading's row, in the
                    // action button's fields (`look`: pill, else plain words).
                    if let action {
                        CmsActionButtonBlockView(block: .action(id: block.id + ".headerAction", props: action),
                                                 chrome: action.string("look") == "pill" ? .pill : .plain)
                    }
                }
            }
            if let children = block.children {
                CmsBlockContainerView(container: children)
            }
        }
        .frame(maxWidth: .infinity, alignment: align.frame)
        .multilineTextAlignment(align.text)
        // The web's SectionBlock.content: `contentPadding` inside a box at most
        // `contentMaxWidth` wide, centred. Without the padding a framed section's
        // content sat on its border and was clipped by its corners (30 Oct 2026).
        .padding(CmsCss.insets(block.props.string("contentPadding")) ?? EdgeInsets())
        .frame(maxWidth: CmsCss.points(block.props.string("contentMaxWidth")) ?? .infinity)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - container (pure layout block)

struct CmsContainerBlockView: View {
    let block: CmsBlock

    var body: some View {
        if let children = block.children {
            CmsBlockContainerView(container: children)
        }
    }
}
