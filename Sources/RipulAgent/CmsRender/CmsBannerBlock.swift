import SwiftUI

/// Native twin of `banner` (BannerBlock.tsx): a slim call-to-action row, a
/// message and a pill, the whole row a link to a page or an address. Text takes
/// the usual `@query.column` tokens. The tone colours the leading edge and the
/// pill, as on the web.
struct CmsBannerBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime
    @Environment(\.openURL) private var openURL

    private var props: [String: CmsJSON] { runtime.resolvedProps(for: block) }
    private var text: String { runtime.resolveString(block: block, propKey: "text") ?? "Something needs your attention" }
    private var icon: String { props.string("icon") ?? "" }
    private var ctaLabel: String { props.string("ctaLabel") ?? "Open" }
    private var targetPage: String? { props.string("targetPageSlug").flatMap { $0.isEmpty ? nil : $0 } }
    private var address: URL? {
        props.string("url").flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    private var tone: String { props.string("tone") ?? "brand" }

    private var accent: Color {
        switch tone {
        case "warning": return runtime.theme.color(role: .warning)
        case "error": return runtime.theme.color(role: .error)
        case "success": return runtime.theme.color(role: .success)
        case "neutral": return runtime.theme.color(role: .divider)
        default: return runtime.theme.color(role: .primary)
        }
    }

    private var linked: Bool { targetPage != nil || address != nil }

    var body: some View {
        Button(action: open) { row }
            .buttonStyle(.plain)
            .disabled(!linked || runtime.isDesignMode)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(linked ? .isLink : [])
    }

    private var row: some View {
        let radius = max(runtime.theme.inputRadius, 8)
        return HStack(spacing: 10) {
            Text(icon.isEmpty ? text : "\(icon) \(text)")
                .modifier(CmsScaledFont(theme: runtime.theme, size: 14, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(runtime.theme.color(role: .text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !ctaLabel.isEmpty {
                Text(ctaLabel)
                    .modifier(CmsScaledFont(theme: runtime.theme, size: 12, weight: .bold, relativeTo: .caption))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .foregroundStyle(tone == "neutral" ? runtime.theme.color(role: .text) : runtime.theme.color(role: .paper))
                    .background(Capsule().fill(accent))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(runtime.theme.color(role: .paper))
        )
        .overlay(alignment: .leading) {
            // The tone's edge, inside the rounded corners.
            UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, style: .continuous)
                .fill(accent)
                .frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(runtime.theme.color(role: .divider), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func open() {
        if let targetPage {
            runtime.navigate(toPage: targetPage)
        } else if let address {
            openURL(address)
        }
    }
}
