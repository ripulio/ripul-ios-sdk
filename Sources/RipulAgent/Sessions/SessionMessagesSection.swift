import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The dedicated Messages tab: controls above a cell-reusing List that fills
/// the remaining space. Individual messages keep their full, self-sizing text.
@available(iOS 17.0, macOS 14.0, *)
struct SessionMessagesSection: View {
    let anchors: [AgentBridge.HumanChatAnchor]
    @Binding var searchText: String
    var isLoading = false
    var error: String? = nil
    var onReload: (() -> Void)? = nil
    let onJump: (String) -> Void

    @AppStorage("metadataMessagesNewestFirst") private var newestFirst = true
    @State private var rowState = NativeChatRowStateRegistry()

    private struct Message: Identifiable {
        let number: Int
        let anchor: AgentBridge.HumanChatAnchor
        var id: String { anchor.id }
    }

    private var shown: [Message] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: [Message] = anchors.enumerated().compactMap { index, anchor in
            guard query.isEmpty || anchor.text.localizedCaseInsensitiveContains(query)
                || anchor.senderDisplayName?.localizedCaseInsensitiveContains(query) == true else { return nil }
            return Message(number: index + 1, anchor: anchor)
        }
        return newestFirst ? Array(matches.reversed()) : matches
    }

    var body: some View {
        let messages = shown
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GlassSearchField("Search messages", text: $searchText)
                    .uiKitIdentifier("SessionMetadataPanel.messages.search")
                sortOrderMenu
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if anchors.isEmpty && isLoading {
                ProgressView("Loading messages…")
                    .font(.ripul(.subheadline))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .uiKitIdentifier("SessionMetadataPanel.messages.loading")
            } else if messages.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(anchors.isEmpty ? (error ?? "No messages loaded yet") : "No matching messages")
                    if anchors.isEmpty, let onReload {
                        Button("Reload messages", action: onReload)
                            .uiKitIdentifier("SessionMetadataPanel.messages.reload")
                    }
                }
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                List(messages) { message in
                    SessionMessageCard(number: message.number, anchor: message.anchor) {
                        onJump(message.id)
                    }
                    .nativeChatRowStateRoot(registry: rowState, rowId: message.id)
                    .padding(.bottom, 8)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, 0)
                // Start at the first message in the selected order after a toggle.
                .id(newestFirst)
            }
            if !anchors.isEmpty && isLoading {
                ProgressView("Loading messages…")
                    .font(.ripul(.subheadline))
                    .padding(12)
            } else if !anchors.isEmpty, let error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error)
                    if let onReload { Button("Reload messages", action: onReload) }
                }
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.textSecondary))
                .padding(12)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .uiKitIdentifier("SessionMetadataPanel.messages")
    }

    private var sortOrderMenu: some View {
        Menu {
            Picker("Sort order", selection: $newestFirst) {
                Text("Newest first").tag(true)
                Text("Oldest first").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.ripulIcon(.caption, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.ripulIcon(.caption2, weight: .semibold))
            }
            .foregroundStyle(.ripul(.textSecondary))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Sort order")
        .accessibilityValue(newestFirst ? "Newest first" : "Oldest first")
        .help("Sort order: \(newestFirst ? "Newest first" : "Oldest first")")
        .uiKitIdentifier("SessionMetadataPanel.messages.order")
    }
}

@available(iOS 17.0, macOS 14.0, *)
struct SessionMessageCard: View {
    let number: Int
    let anchor: AgentBridge.HumanChatAnchor
    let onJump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onJump) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(number)")
                        .font(.ripul(.caption2, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .accessibilityLabel("Message \(number)")
                    if let sender = anchor.senderDisplayName, !sender.isEmpty {
                        Text(sender)
                            .font(.ripul(.caption, weight: .semibold))
                            .foregroundStyle(.ripul(.textSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let timestamp = anchor.timestamp {
                        Text(RelativeTimeText.string(for: timestamp, relativeTo: Date()))
                            .font(.ripul(.caption2))
                            .foregroundStyle(.ripul(.textTertiary))
                            .fixedSize()
                    }
                    Image(systemName: "arrow.up.forward")
                        .font(.ripulIcon(.caption2, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Jump to message")
            .help("Jump to message")

            NativeChatMarkdownBody(content: anchor.text, contextMentions: true)
                .equatable()
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.ripul(.text).opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.ripul(.separator).opacity(0.5), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onJump)
        .contextMenu { MenuIcons {
            Button(action: onJump) {
                Label("Jump to Message", systemImage: "arrow.turn.down.right")
            }
            Button(action: copy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }}
        .uiKitIdentifier("SessionMetadataPanel.messageRow")
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = anchor.text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(anchor.text, forType: .string)
        #endif
    }
}
