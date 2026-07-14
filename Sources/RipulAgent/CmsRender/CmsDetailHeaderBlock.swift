import SwiftUI

/// Native twin of `detailHeader` (DetailHeaderBlock.tsx): a banner for a
/// detail view — back chevron plus title/subtitle whose `@query.column`
/// tokens resolve against the selected row. Auto-hides on the list (no
/// selection on the watched query). The back chevron clears the watched
/// selection (returning to the list) or navigates to a fixed page.
struct CmsDetailHeaderBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    private var watchSlug: String { block.props.string("watchQuerySlug") ?? "" }

    var body: some View {
        let hasSelection = !(runtime.selections[watchSlug] ?? []).isEmpty
        let autoHidden = (block.props.bool("autoHide") ?? true) && !watchSlug.isEmpty && !hasSelection
        if !autoHidden {
            banner
        }
    }

    private var banner: some View {
        // Web defaults: banner = theme primary; text = a readable colour for
        // the banner (primary contrast, or contrast of a custom background).
        let bg = runtime.color(block.props.string("bgColor")) ?? runtime.theme.primary
        let fg = runtime.color(block.props.string("textColor")) ?? CmsCss.contrastText(on: bg)
        let titleTypo = block.props.object("titleTypography")
        let subtitleTypo = block.props.object("subtitleTypography")
        let subtitle = runtime.resolveTemplate(block.props.string("subtitle") ?? "")

        return HStack(spacing: 12) {
            if block.props.bool("showBack") ?? true {
                Button {
                    back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.resolveTemplate(block.props.string("title") ?? "Details"))
                    .font(.system(size: CmsTypography.size(titleTypo) ?? 20,
                                  weight: CmsTypography.weight(titleTypo) ?? .bold))
                    .foregroundColor(runtime.color(titleTypo?.string("color")) ?? fg)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: CmsTypography.size(subtitleTypo) ?? 13,
                                      weight: CmsTypography.weight(subtitleTypo) ?? .regular))
                        .foregroundColor(runtime.color(subtitleTypo?.string("color")) ?? fg.opacity(0.78))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(fg)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
        .cmsInspectorID("Cms.detailHeader.banner")
    }

    private func back() {
        if (block.props.string("backBehavior") ?? "clearSelection") == "navigatePage" {
            if let slug = block.props.string("backTargetPageSlug"), !slug.isEmpty {
                runtime.navigate(toPage: slug)
            }
        } else if !watchSlug.isEmpty {
            runtime.setSelectedRows(watchSlug, rows: [])
        }
    }
}
