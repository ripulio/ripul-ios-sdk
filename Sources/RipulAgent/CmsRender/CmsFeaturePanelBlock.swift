import SwiftUI

/// Native twin of `featurePanel` (FeaturePanelBlock.tsx): a branded selling
/// panel — pill badge, heading, oversized display line ("1 month free"),
/// subheading, footnote and a marked list. Same props and defaults as the
/// web; every colour comes from the portal theme and `tone` picks the
/// surface (brand gradient / solid brand / brand tint / paper card).
///
/// Presentation is native: Dynamic-Type text styles instead of fixed px,
/// SF Symbol markers (`checkmark`) instead of a "✓" glyph, and the display
/// line scales down rather than clamping to the viewport width.
struct CmsFeaturePanelBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    /// Web: clamp(40px, 6vw, 64px) — native anchors at 44pt and follows
    /// Dynamic Type relative to the large title.
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 44

    struct Item: Equatable {
        let title: String
        let detail: String
    }

    /// Resolved colours for one `tone` — twin of the web's `surfaceFor`.
    struct Surface {
        let background: AnyShapeStyle
        let foreground: Color
        let muted: Color
        let badgeBackground: Color
        let badgeForeground: Color
        let markerBackground: AnyShapeStyle
        let markerForeground: Color
        let border: Color?
    }

    static func surface(tone: String, theme: CmsPortalTheme) -> Surface {
        if tone == "gradient" || tone == "primary" {
            return Surface(
                background: tone == "gradient" ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(theme.primary),
                foreground: theme.primaryContrast,
                muted: Color.white.opacity(0.85),
                badgeBackground: Color.white.opacity(0.18),
                badgeForeground: theme.primaryContrast,
                markerBackground: AnyShapeStyle(Color.white),
                markerForeground: theme.primary,
                border: nil
            )
        }
        return Surface(
            background: AnyShapeStyle(tone == "tint" ? theme.tint : theme.paper),
            foreground: theme.textPrimary,
            muted: theme.textSecondary,
            badgeBackground: tone == "tint" ? theme.paper : theme.tint,
            badgeForeground: theme.primary,
            markerBackground: AnyShapeStyle(theme.gradient),
            markerForeground: theme.primaryContrast,
            border: tone == "paper" ? theme.divider : nil
        )
    }

    /// `items` with the web's defaults when absent; rows with neither a
    /// title nor a detail are dropped (web: `filter(i => i.title || i.detail)`).
    static func items(from props: [String: CmsJSON]) -> [Item] {
        guard let raw = props["items"] else {
            return [Item(title: "Everything included", detail: "")]
        }
        guard case .array(let rows) = raw else { return [] }
        return rows.compactMap { row in
            guard let obj = row.objectValue else { return nil }
            let item = Item(title: obj.string("title") ?? "", detail: obj.string("detail") ?? "")
            return item.title.isEmpty && item.detail.isEmpty ? nil : item
        }
    }

    private func text(_ key: String, _ fallback: String) -> String {
        runtime.resolveString(block: block, propKey: key) ?? fallback
    }

    var body: some View {
        let theme = runtime.theme
        let tone = block.props.string("tone") ?? "gradient"
        let marker = block.props.string("marker") ?? "tick"
        let centered = block.props.string("align") == "center"
        let s = Self.surface(tone: tone, theme: theme)
        let badge = text("badge", "")
        let heading = text("heading", "Join today")
        let display = text("display", "1 month free")
        let subheading = text("subheading", "")
        let note = text("note", "")
        let items = Self.items(from: block.props)
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius + 6, style: .continuous)

        VStack(alignment: centered ? .center : .leading, spacing: 0) {
            if !badge.isEmpty {
                Text(badge)
                    .font(.caption.weight(.bold))
                    .foregroundColor(s.badgeForeground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(s.badgeBackground))
                    .padding(.bottom, 14)
            }
            if !heading.isEmpty {
                Text(heading)
                    .font(headingFont)
                    .tracking(CGFloat(theme.headingLetterSpacing ?? 0) * 22)
                    .accessibilityAddTraits(.isHeader)
            }
            if !display.isEmpty {
                Text(display)
                    .font(.system(size: displaySize, weight: .heavy))
                    .tracking(-0.03 * displaySize)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .padding(.vertical, 4)
            }
            if !subheading.isEmpty {
                Text(subheading)
                    .font(.title3.weight(.semibold))
            }
            if !note.isEmpty {
                Text(note)
                    .font(.subheadline)
                    .foregroundColor(s.muted)
                    .padding(.top, 8)
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        itemRow(item, index: index, marker: marker, surface: s)
                    }
                }
                .padding(.top, 22)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .foregroundColor(s.foreground)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .background(shape.fill(s.background))
        .overlay {
            if let border = s.border {
                shape.strokeBorder(border, lineWidth: 1)
            }
        }
    }

    /// Web: Typography h5 with fontWeight 700 — the theme's heading family
    /// and tracking still apply; the sx weight wins over headingWeight.
    private var headingFont: Font {
        let base = runtime.theme.headingFontFamily
            .map { Font.custom($0, size: 22, relativeTo: .title2) } ?? .title2
        return base.weight(.bold)
    }

    private func itemRow(_ item: Item, index: Int, marker: String, surface s: Surface) -> some View {
        HStack(alignment: .top, spacing: 12) {
            markerView(marker, index: index, surface: s)
            VStack(alignment: .leading, spacing: 2) {
                if !item.title.isEmpty {
                    Text(item.title).font(.body.weight(.bold))
                }
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundColor(s.muted)
                }
            }
            .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func markerView(_ marker: String, index: Int, surface s: Surface) -> some View {
        if marker == "dot" {
            Circle()
                .fill(s.markerBackground)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
                .accessibilityHidden(true)
        } else {
            ZStack {
                Circle().fill(s.markerBackground)
                if marker == "number" {
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .heavy))
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                }
            }
            .foregroundColor(s.markerForeground)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
        }
    }
}

/// Inspector schema — the scalar half of the web schema. The `items`
/// repeater stays on the web designer (the native inspector has no repeater
/// kind yet); edits here round-trip through the raw JSON save untouched.
enum CmsFeaturePanelInspector {
    static let schema = CmsInspectorSchema(
        groups: [
            CmsPropertyGroup(id: "content", label: "Content"),
            CmsPropertyGroup(id: "style", label: "Style", defaultExpanded: false),
        ],
        fields: [
            CmsPropertyField(key: "badge", label: "Badge", kind: .string(placeholder: "Limited places"),
                             group: "content", helperText: "Small pill above the heading. Blank hides it.",
                             default: .string("")),
            CmsPropertyField(key: "heading", label: "Heading", kind: .string(), group: "content",
                             default: .string("Join today")),
            CmsPropertyField(key: "display", label: "Display line", kind: .string(), group: "content",
                             helperText: "The oversized line, e.g. \"1 month free\". Blank hides it.",
                             default: .string("1 month free")),
            CmsPropertyField(key: "subheading", label: "Subheading", kind: .string(), group: "content",
                             default: .string("")),
            CmsPropertyField(key: "note", label: "Note", kind: .string(), group: "content",
                             helperText: "Small print under the subheading.", default: .string("")),
            CmsPropertyField(key: "tone", label: "Surface", kind: .select(options: [
                CmsPropertyOption("gradient", "Brand gradient"),
                CmsPropertyOption("primary", "Brand solid"),
                CmsPropertyOption("tint", "Brand tint"),
                CmsPropertyOption("paper", "Card"),
            ]), group: "style", default: .string("gradient")),
            CmsPropertyField(key: "marker", label: "List marker", kind: .select(options: [
                CmsPropertyOption("tick", "Tick"),
                CmsPropertyOption("number", "1 2 3"),
                CmsPropertyOption("dot", "Dot"),
            ]), group: "style", default: .string("tick")),
            CmsPropertyField(key: "align", label: "Align", kind: .select(options: [
                CmsPropertyOption("start", "Start"),
                CmsPropertyOption("center", "Center"),
            ]), group: "style", default: .string("start")),
        ]
    )
}
