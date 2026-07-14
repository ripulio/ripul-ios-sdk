import SwiftUI

/// Native twin of the web `kpiStrip` block (KpiStripBlock.tsx). A row or
/// column of KPI tiles: uppercase label, bold value (format pattern applied
/// after `@slug.column` token resolution), optional subtitle, dividers.
///
/// Typography is the web's, literally: `responsiveText`'s container-query
/// clamps are computed from each tile's measured width (label
/// clamp(9, 8 + 1%w, 11), value clamp(16, 8.8 + 5%w, 32), subtitle
/// clamp(10, 8 + 1.2%w, 12) — px ≡ pt), authored TypographyValue
/// size/weight overrides them, and sizes are FIXED (authored content does
/// not track Dynamic Type). Row + wrap uses an adaptive grid.
struct CmsKpiStripBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    fileprivate struct KpiItem {
        var label: String
        var value: String
        var subtitle: String
    }

    private var isRow: Bool { (block.props.string("direction") ?? "row") == "row" }
    private var wraps: Bool { (block.props.string("wrap") ?? "wrap") == "wrap" }
    private var showDivider: Bool { (block.props.string("divider") ?? "line") == "line" }
    private var shrinkToFit: Bool { block.props.bool("responsiveText") ?? true }
    /// MUI spacing units (×8 px), default 2.
    private var gap: CGFloat { CGFloat(block.props.double("gap") ?? 2) * 8 }

    private var alignment: HorizontalAlignment {
        switch block.props.string("align") ?? "left" {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    /// Items with direct bindings applied (dot-path `items.N.value` entries —
    /// how KPI values bind to grid aggregate outputs), then inline tokens
    /// resolved and format patterns applied — the twin of the web's upstream
    /// resolveBlockProps + `applyFormatPattern` in render.
    private var items: [KpiItem] {
        let props = runtime.resolvedProps(for: block)
        guard case .array(let raw) = props["items"] ?? .null else { return [] }
        return raw.compactMap { entry in
            guard let obj = entry.objectValue else { return nil }
            // A dot-path binding replaces the whole prop value — often with a
            // NUMBER (grid aggregate), so read via displayString, never the
            // string-only accessor. (Closure, not a nested func — a func
            // would drop the enclosing MainActor isolation.)
            let text: (String) -> String = { key in
                guard let v = obj[key], v != .null else { return "" }
                return runtime.resolveTemplate(v.displayString)
            }
            var value = text("value")
            if let format = obj.string("format"), !format.isEmpty {
                value = CmsFormatValue.apply(value, pattern: format)
            }
            return KpiItem(label: text("label"), value: value, subtitle: text("subtitle"))
        }
    }

    var body: some View {
        let items = self.items
        Group {
            if !isRow {
                VStack(alignment: alignment, spacing: gap) {
                    tiles(items, verticalDividers: false)
                }
            } else if wraps {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: gap)], spacing: gap) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        tile(item)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: gap) {
                    tiles(items, verticalDividers: true)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func tiles(_ items: [KpiItem], verticalDividers: Bool) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            if showDivider && index > 0 {
                if verticalDividers {
                    Divider().frame(maxHeight: 60)
                } else {
                    Divider()
                }
            }
            tile(item)
        }
    }

    private func tile(_ item: KpiItem) -> some View {
        KpiTileView(
            item: item,
            alignment: alignment,
            frameAlignment: frameAlignment,
            responsive: shrinkToFit,
            labelTypography: block.props.object("labelTypography"),
            valueTypography: block.props.object("valueTypography"),
            subtitleTypography: block.props.object("subtitleTypography"),
            labelColor: typographyColor("labelTypography"),
            valueColor: typographyColor("valueTypography"),
            subtitleColor: typographyColor("subtitleTypography")
        )
    }

    private var frameAlignment: Alignment {
        switch block.props.string("align") ?? "left" {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private func typographyColor(_ key: String) -> Color? {
        runtime.color(block.props.object(key)?.string("color"))
    }
}

/// One KPI tile. Measures its own width so the web's container-query
/// clamps resolve against the SAME box they do in CSS (each cell is its
/// own container). Web cells stretch to the strip/grid column in every
/// direction mode, so the tile always fills — that also keeps the
/// measurement independent of the font size (no feedback loop).
private struct KpiTileView: View {
    let item: CmsKpiStripBlockView.KpiItem
    let alignment: HorizontalAlignment
    let frameAlignment: Alignment
    let responsive: Bool
    let labelTypography: [String: CmsJSON]?
    let valueTypography: [String: CmsJSON]?
    let subtitleTypography: [String: CmsJSON]?
    let labelColor: Color?
    let valueColor: Color?
    let subtitleColor: Color?

    @State private var width: CGFloat = 0

    /// clamp(floor, base + coeff·width, cap) — cqi twin (1cqi = 1% width).
    private func fluid(_ floor: CGFloat, _ base: CGFloat, _ coeff: CGFloat, _ cap: CGFloat) -> CGFloat {
        guard width > 0 else { return floor }
        return min(max(base + coeff * width, floor), cap)
    }

    // Authored size wins; else the fluid clamp; responsiveText off = the
    // web's static defaults (label 11, value h4 = 34, subtitle 12).
    private var labelFont: Font {
        .system(size: CmsTypography.size(labelTypography) ?? (responsive ? fluid(9, 8, 0.01, 11) : 11),
                weight: CmsTypography.weight(labelTypography) ?? .semibold)
    }
    private var valueFont: Font {
        .system(size: CmsTypography.size(valueTypography) ?? (responsive ? fluid(16, 8.8, 0.05, 32) : 34),
                weight: CmsTypography.weight(valueTypography) ?? .bold)
    }
    private var subtitleFont: Font {
        .system(size: CmsTypography.size(subtitleTypography) ?? (responsive ? fluid(10, 8, 0.012, 12) : 12),
                weight: CmsTypography.weight(subtitleTypography) ?? .regular)
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            if !item.label.isEmpty {
                Text(item.label.uppercased())
                    .font(labelFont)
                    .kerning(0.5)
                    .foregroundColor(labelColor ?? .secondary)
            }
            Text(item.value)
                .font(valueFont)
                .lineLimit(responsive ? 1 : nil)
                .minimumScaleFactor(responsive ? 0.5 : 1)
                .foregroundColor(valueColor ?? .primary)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(subtitleFont)
                    .foregroundColor(subtitleColor ?? .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .background(GeometryReader { g in
            Color.clear.preference(key: KpiTileWidthKey.self, value: g.size.width)
        })
        .onPreferenceChange(KpiTileWidthKey.self) { new in
            if abs(new - width) > 0.5 { width = new }
        }
        .cmsInspectorID("Cms.kpiStrip.tile")
    }
}

private struct KpiTileWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
