import SwiftUI

/// Native `agentChat` twin. In this product, chat rendering IS the web chat
/// surface everywhere — the native app's own chat screen embeds AgentView —
/// so the block's native twin reuses that same canonical component rather
/// than growing a third chat UI. This is component reuse of the app's chat,
/// not a CMS rendering fallback.
///
/// Prop mapping: siteKey override (blank = the portal's resolved key stays
/// with the signed-in session), theme, newChat, initialPrompt, height, title
/// (rendered as a native header; the embedded chat header is hidden).
/// Degradations: `undocked` floats as a desktop overlay on the web — it
/// renders docked here; `promptCollectionId`/`viewContextId`/`toolCollection`
/// overrides ride the embedded app's own handling of the site config.
struct CmsAgentChatBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    private var height: CGFloat { CmsCss.points(block.props.string("height")) ?? 600 }
    /// Authored Size=fill stretches the chat to the container (e.g. a
    /// sidebar drawer) instead of the fixed height prop.
    private var fillsHeight: Bool {
        // Universal frame.size, or the legacy per-block convention where the
        // Size control writes props.height = "fill".
        block.frame?.size == "fill" || block.props.string("height") == "fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = block.props.string("title"), !title.isEmpty {
                Text(title)
                    .font(.headline)
            }
            if #available(iOS 16.0, macOS 14.0, *) {
                AgentView(
                    configuration: configuration,
                    topBar: { _ in EmptyView() }
                )
                .frame(height: fillsHeight ? nil : height)
                .frame(maxHeight: fillsHeight ? .infinity : nil)
                .frame(minHeight: fillsHeight ? 320 : nil)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
            } else {
                Label("Agent chat needs a newer OS", systemImage: "message")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(12)
            }
        }
    }

    private var configuration: AgentConfiguration {
        // Block siteKey override, else INHERIT the portal's site key — the
        // web block's rule. Without it the embedded app rides the app's own
        // signed-in session and shows the user's chat instead of the
        // portal-scoped agent (view context, prompts).
        let explicitSiteKey = block.props.string("siteKey")
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? runtime.client.siteKeyPublishable
        let theme = block.props.string("theme")
            .flatMap(AgentTheme.init(rawValue:)) ?? .system
        let prompt = block.props.string("initialPrompt")
            .flatMap { $0.isEmpty ? nil : $0 }
        return AgentConfiguration(
            baseURL: URL(string: RipulDomain.demoURL)!,
            siteKey: explicitSiteKey,
            sessionToken: runtime.client.visitorSessionToken,
            theme: theme,
            newChat: block.props.bool("newChat") ?? false,
            prompt: prompt,
            hideHeader: true,
            hideTabSwitcher: true
        )
    }
}
