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
/// and `suggestedPrompts` overrides ride the embedded app's own handling of
/// the site config. Each opening of the floating chat starts a fresh
/// conversation (the web keeps one per page load).
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
        content
            .onAppear { if let slug = block.slug { runtime.chatBlocks[slug] = block } }
            .onDisappear { if let slug = block.slug, runtime.chatBlocks[slug]?.id == block.id { runtime.chatBlocks[slug] = nil } }
    }

    @ViewBuilder
    private var content: some View {
        if block.props.bool("fab") == true || runtime.isTabFloating(block) {
            // The web's floating button: the page draws it (CmsFloatingChatHost);
            // the block holds its place in the page only to register it.
            Color.clear.frame(width: 0, height: 0)
                .onAppear { runtime.floatingChat = block }
                .onDisappear { if runtime.floatingChat?.id == block.id { runtime.floatingChat = nil } }
        } else {
            docked
        }
    }

    private var docked: some View {
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

    var configuration: AgentConfiguration { Self.configuration(for: block, runtime: runtime) }

    @MainActor
    static func configuration(for block: CmsBlock, runtime: CmsRuntime, ask: String? = nil) -> AgentConfiguration {
        // Block siteKey override, else INHERIT the portal's site key — the
        // web block's rule. Without it the embedded app rides the app's own
        // signed-in session and shows the user's chat instead of the
        // portal-scoped agent (view context, prompts).
        let explicitSiteKey = block.props.string("siteKey")
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? runtime.client.siteKeyPublishable
        let theme = block.props.string("theme")
            .flatMap(AgentTheme.init(rawValue:)) ?? .system
        let prompt = ask ?? block.props.string("initialPrompt")
            .flatMap { $0.isEmpty ? nil : $0 }
        return AgentConfiguration(
            baseURL: URL(string: RipulDomain.demoURL)!,
            siteKey: explicitSiteKey,
            sessionToken: runtime.client.visitorSessionToken,
            theme: theme,
            // A block chat is never the account's own last chat: on the web
            // it is a fresh, local-only conversation each page load
            // (AgentChatInline `block:agent:<key>:<pageSuffix>`) whatever
            // `newChat` says. The embedded app restores the account's last
            // chat unless told to start one, which put a person's own
            // coding chat under the site's "ask wac" header.
            newChat: true,
            prompt: prompt,
            hideHeader: true,
            hideTabSwitcher: true
        )
    }
}

/// `agentChat` with `fab`: a floating button bottom-right (the brand pill
/// with `fabLabel`) opening the chat in a sheet titled like the web panel's
/// header (`title`, `headerSubtitle`). Phones on the web always use the
/// button too; `pinnable` docking is desktop-only and does not apply.
struct CmsFloatingChatHost: View {
    @ObservedObject var runtime: CmsRuntime
    @State private var open = false

    var body: some View {
        button
            .ripulSheet(item: $runtime.chatAsk) { ask in
                CmsFloatingChatSheet(block: ask.block, ask: ask.prompt, open: Binding(get: { true }, set: { if !$0 { runtime.chatAsk = nil } }))
                    .environmentObject(runtime)
            }
    }

    /// The page's own floating chat, else the shell's when the accessory
    /// doesn't already hold it.
    private var shown: CmsBlock? {
        runtime.floatingChat ?? (runtime.shellChatInAccessory ? nil : runtime.shellChat)
    }

    @ViewBuilder
    private var button: some View {
        if let block = shown {
            let label = CmsFloatingChat.label(block)
            Button {
                open = true
            } label: {
                Label(label, systemImage: "bubble.left.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(runtime.theme.primaryContrast)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(runtime.theme.gradient))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4) // theme-exempt: a drop shadow, not a colour
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.bottom, 72)
            .cmsInspectorID("Cms.agentChat.fab")
            .ripulSheet(isPresented: $open) {
                CmsFloatingChatSheet(block: block, open: $open)
                    .environmentObject(runtime)
            }
        }
    }
}

enum CmsFloatingChat {
    /// The button's words: `fabLabel`, else the chat's title, else "Chat".
    static func label(_ block: CmsBlock) -> String {
        block.props.string("fabLabel").flatMap { $0.isEmpty ? nil : $0 }
            ?? block.props.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? "Chat"
    }

    /// The shell's floating chat (the web's ShellPage: an `agentChat` with
    /// `fab`, shown on every page). One hidden, or shown on desktops only
    /// (`visibleOn: ["desktop"]`), stays hidden here, as the web hides it on a phone.
    static func find(shell: CmsPage?) -> CmsBlock? {
        shell?.blocks?.allBlocks().first { block in
            guard block.type == "agentChat", block.props.bool("fab") == true, block.hidden != true else { return false }
            if let on = block.visibleOn, !on.isEmpty, !on.contains("mobile") { return false }
            return true
        }
    }
}

#if os(iOS)
/// The shell's chat as iOS 26's tab bar bottom accessory: the system's glass
/// strip above the bar, shrinking into the minimized bar on scroll as Music's
/// player does. A tap opens the chat in a sheet.
@available(iOS 26, *)
struct CmsChatAccessory: View {
    let block: CmsBlock
    @ObservedObject var runtime: CmsRuntime
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Button { runtime.shellChatOpen = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(runtime.theme.primary)
                Text(CmsFloatingChat.label(block))
                    .font(.ripul(.subheadline).weight(.semibold))
                    .foregroundStyle(runtime.theme.textPrimary)
                if placement != .inline, let subtitle = block.props.string("headerSubtitle"), !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.ripul(.footnote))
                        .foregroundStyle(runtime.theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CmsFloatingChat.label(block))
        .accessibilityHint("Opens the chat")
        .cmsInspectorID("Cms.agentChat.accessory")
    }
}
#endif

struct CmsFloatingChatSheet: View {
    let block: CmsBlock
    var ask: String? = nil
    @Binding var open: Bool
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        NavigationStack {
            AgentView(
                configuration: CmsAgentChatBlockView.configuration(for: block, runtime: runtime, ask: ask),
                topBar: { _ in EmptyView() }
            )
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(block.props.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? "Chat")
                            .font(.system(size: 16, weight: .semibold))
                        if let subtitle = block.props.string("headerSubtitle"), !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(runtime.theme.textSecondary)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { open = false }
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .tint(runtime.theme.primary)
    }
}
