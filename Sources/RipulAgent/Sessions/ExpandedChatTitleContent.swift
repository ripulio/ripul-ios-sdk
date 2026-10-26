import SwiftUI

// MARK: - Expanded chat title content

/// The disclosed part of the agent screen's title lozenge: the metadata block
/// and chat controls that appear BELOW the lozenge's permanent header row when
/// the pill is expanded.
///
/// This view is only the revealed content — it deliberately carries no title,
/// no glass and no background. The lozenge's header (a `UnifiedSessionRow`)
/// stays mounted across both states and the bar's pill supplies the glass, so
/// expanding is one view growing taller, not two views swapping. That is the
/// difference between a morph and a snap, and it is why there is no
/// `.transition` here: the reveal is the container's height growth alone.
///
/// The "previous user message" control exists ONLY here — the contracted bar
/// has no scroll-up accessory, which is the width this expansion grows into.
@available(iOS 15.0, macOS 13.0, *)
public struct ExpandedChatTitleContent: View {
    /// One metadata line — small icon + secondary text, leading-aligned.
    public struct MetadataRow: Identifiable, Equatable {
        public let icon: String
        public let text: String
        public var id: String { icon + "|" + text }

        public init(icon: String, text: String) {
            self.icon = icon
            self.text = text
        }
    }

    /// A key shortcut of the chat, shown with its title in the expanded pill.
    public struct Shortcut: Identifiable, Equatable {
        public let id: String
        public let title: String
        public let symbol: String
        public let url: URL

        public init(id: String, title: String, symbol: String, url: URL) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.url = url
        }
    }

    var metadata: [MetadataRow]
    var shortcuts: [Shortcut]
    var onOpenShortcut: (URL) -> Void
    var onPreviousUserMessage: () -> Void
    var onNextUserMessage: () -> Void
    var onScrollToBottom: () -> Void

    public init(
        metadata: [MetadataRow],
        shortcuts: [Shortcut] = [],
        onOpenShortcut: @escaping (URL) -> Void = { _ in },
        onPreviousUserMessage: @escaping () -> Void,
        onNextUserMessage: @escaping () -> Void,
        onScrollToBottom: @escaping () -> Void
    ) {
        self.metadata = metadata
        self.shortcuts = shortcuts
        self.onOpenShortcut = onOpenShortcut
        self.onPreviousUserMessage = onPreviousUserMessage
        self.onNextUserMessage = onNextUserMessage
        self.onScrollToBottom = onScrollToBottom
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !metadata.isEmpty {
                metadataBlock
            }
            if !shortcuts.isEmpty {
                shortcutsBlock
            }
            controlsRow
        }
        // The panel's width is pinned by its parent; fill it rather than
        // sizing to content, so metadata that rewrites itself during a tool
        // call cannot change the layout.
        .frame(maxWidth: .infinity, alignment: .leading)
        .uiKitIdentifier("ExpandedChatTitleContent.root")
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(metadata) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.icon)
                        .font(.ripulIcon(size: 10))
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 14, alignment: .center)
                    Text(row.text)
                        .font(.ripul(.caption2))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(1)
                }
                .uiKitIdentifier("ExpandedChatTitleContent.metadataRow.\(row.icon)")
            }
        }
    }

    /// One full-width capsule per key shortcut, with its title.
    private var shortcutsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shortcuts) { shortcut in
                Button {
                    onOpenShortcut(shortcut.url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: shortcut.symbol)
                            .font(.ripulIcon(size: 11, weight: .semibold))
                            .frame(width: 14, alignment: .center)
                        Text(shortcut.title)
                            .font(.ripul(.caption, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // A pinned message jumps within the chat; a link leaves it.
                        Image(systemName: AgentBridge.messageAnchor(from: shortcut.url) != nil ? "arrow.down.to.line" : "arrow.up.right")
                            .font(.ripulIcon(size: 9, weight: .semibold))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    .foregroundStyle(.ripul(.text))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Capsule())
                    // Flat, not glass, for the reason the controls give below.
                    .background(.fill.tertiary, in: Capsule())
                }
                .buttonStyle(.plain)
                .uiKitIdentifier("ExpandedChatTitleContent.shortcut")
            }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 6) {
            control(
                icon: "chevron.up",
                label: "Previous",
                identifier: "ExpandedChatTitleContent.controls.previousAsk",
                action: onPreviousUserMessage
            )
            control(
                icon: "chevron.down",
                label: "Next",
                identifier: "ExpandedChatTitleContent.controls.nextAsk",
                action: onNextUserMessage
            )
            control(
                icon: "arrow.down.to.line",
                label: "Latest",
                identifier: "ExpandedChatTitleContent.controls.latest",
                action: onScrollToBottom
            )
        }
    }

    private func control(icon: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.ripulIcon(size: 10, weight: .semibold))
                Text(label)
                    .font(.ripul(.caption2, weight: .medium))
            }
            .foregroundStyle(.ripul(.text))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // Equal shares of the pinned width — three controls that keep
            // their positions instead of reflowing as labels change.
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
            // A flat fill, NOT glass: these sit inside the panel's own glass, and
            // glass-in-glass inside one GlassEffectContainer gives the morph four
            // shapes to resolve instead of one. Apple's guidance is against
            // stacking glass anyway.
            .background(.fill.tertiary, in: Capsule())
        }
        .buttonStyle(.plain)
        // The pill is the expand/collapse toggle; a control inside it must not
        // let its own tap fall through to that gesture and collapse the panel.
        .uiKitIdentifier(identifier)
    }
}
