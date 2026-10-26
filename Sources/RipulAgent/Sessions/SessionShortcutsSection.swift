import SwiftUI

/// The chat's shortcuts, under its milestones in the metadata panel: links it
/// keeps to hand, key ones first. A tap opens one; the pin puts it in the
/// chat's header lozenge or takes it out.
///
/// The agent keeps them (the `shortcut` tool). A person can add, pin and
/// delete them here, and pinning marks the shortcut as theirs. A message
/// pinned from its bubble is listed too: a tap jumps the chat to it.
///
/// In a chat that is someone else's the list is the chat's: its links are
/// the owner's, and a member unpins only the messages they pinned. The page's
/// `ShortcutsSection` is the web twin. Docs: chatShortcuts.md.
@available(iOS 15.0, macOS 13.0, *)
struct SessionShortcutsSection: View {
    let shortcuts: [AgentBridge.ChatShortcut]
    @Binding var isExpanded: Bool
    let patch: ([String: Any]) -> Void
    /// False in a chat that is someone else's.
    var canEditLinks = true
    var canUnpin: (AgentBridge.ChatShortcut) -> Bool = { _ in true }
    var onJump: (AgentBridge.MessageAnchor) -> Void = { _ in }

    @Environment(\.openURL) private var openURL
    @State private var adding = false
    @State private var title = ""
    @State private var address = ""

    private static let maxTitle = 60

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                content
            }
        }
        .modifier(GlassPanelBackground())
        .uiKitIdentifier("SessionMetadataPanel.shortcuts")
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.ripulIcon(.caption2, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
            Text("Shortcuts")
                .font(.ripul(.subheadline, weight: .semibold))
                .foregroundStyle(.ripul(.textSecondary))
                .textCase(.uppercase)
            if !shortcuts.isEmpty {
                Text("\(shortcuts.count)")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textTertiary))
            }
            Spacer()
            if !adding && canEditLinks {
                Button {
                    title = ""
                    address = ""
                    adding = true
                    isExpanded = true
                } label: {
                    Image(systemName: "plus")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 32, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a shortcut")
                .uiKitIdentifier("SessionMetadataPanel.shortcuts.add")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if adding {
                draftFields
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if shortcuts.isEmpty && !adding {
                Text("None yet. The agent keeps a link here when it makes an artefact or a page you will want again. Add your own, or pin a message from its bubble.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textTertiary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                shortcutRow(shortcut)
            }
        }
        .padding(.bottom, 8)
    }

    private var draftFields: some View {
        VStack(spacing: 6) {
            TextField("Name", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.ripul(.subheadline))
                .onChange(of: title) { _, value in
                    if value.count > Self.maxTitle { title = String(value.prefix(Self.maxTitle)) }
                }
                .uiKitIdentifier("SessionMetadataPanel.shortcuts.title")
            HStack(spacing: 4) {
                TextField("https://", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.ripul(.subheadline))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .submitLabel(.done)
                    .onSubmit(save)
                    .uiKitIdentifier("SessionMetadataPanel.shortcuts.url")
                Button {
                    adding = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.textSecondary))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                Button(action: save) {
                    Image(systemName: "checkmark")
                        .font(.ripulIcon(.caption))
                        .foregroundStyle(.ripul(.info))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(Self.typedURL(address) == nil || cleanTitle.isEmpty)
                .accessibilityLabel("Save")
                .uiKitIdentifier("SessionMetadataPanel.shortcuts.save")
            }
        }
    }

    // MARK: - A shortcut

    private func open(_ shortcut: AgentBridge.ChatShortcut) {
        if let anchor = shortcut.anchor { onJump(anchor); return }
        if !RipulSecureConnection.open(shortcut.url) { openURL(shortcut.url) }
    }

    @ViewBuilder
    private func shortcutRow(_ shortcut: AgentBridge.ChatShortcut) -> some View {
        if shortcut.isMessage {
            messageRow(shortcut)
        } else {
            linkRow(shortcut)
        }
    }

    private func label(_ shortcut: AgentBridge.ChatShortcut) -> some View {
        HStack(spacing: 10) {
            Image(systemName: shortcut.symbol)
                .font(.ripulIcon(.subheadline))
                .foregroundStyle(shortcut.isArtefact || shortcut.isMessage ? .ripul(.info) : .ripul(.textSecondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(shortcut.title).ripulText()
                    .font(.ripul(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Text(shortcut.subtitle)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func headerPin(_ shortcut: AgentBridge.ChatShortcut) -> some View {
        Button {
            patch(["updateShortcut": ["id": shortcut.id, "key": !shortcut.key, "byPerson": true]])
        } label: {
            Image(systemName: shortcut.key ? "pin.fill" : "pin")
                .font(.ripulIcon(.caption))
                .foregroundStyle(shortcut.key ? .ripul(.info) : .ripul(.textTertiary))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shortcut.key ? "Take out of the chat's header" : "Show in the chat's header")
        .uiKitIdentifier("SessionMetadataPanel.shortcutRow.pin")
    }

    /// A pinned message: a tap jumps the chat to it.
    private func messageRow(_ shortcut: AgentBridge.ChatShortcut) -> some View {
        HStack(spacing: 4) {
            Button { open(shortcut) } label: { label(shortcut) }
                .buttonStyle(.plain)
                .accessibilityHint("Jumps to the message")
                .uiKitIdentifier("SessionMetadataPanel.pinnedMessageRow")
            if canEditLinks { headerPin(shortcut) }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .contextMenu { MenuIcons {
            Button { open(shortcut) } label: {
                Label("Jump to Message", systemImage: "arrow.down.to.line")
            }
            if canUnpin(shortcut) {
                Divider()
                Button(role: .destructive) {
                    patch(["removeShortcutId": shortcut.id])
                } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
            }
        }}
    }

    private func linkRow(_ shortcut: AgentBridge.ChatShortcut) -> some View {
        HStack(spacing: 4) {
            Button { open(shortcut) } label: { label(shortcut) }
                .buttonStyle(.plain)
                .uiKitIdentifier("SessionMetadataPanel.shortcutRow")
            if canEditLinks { headerPin(shortcut) }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .contextMenu { MenuIcons {
            Button {
                if !RipulSecureConnection.open(shortcut.url) { openURL(shortcut.url) }
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            Button {
                #if os(iOS)
                UIPasteboard.general.string = shortcut.url.absoluteString
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shortcut.url.absoluteString, forType: .string)
                #endif
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            if canEditLinks {
                Divider()
                Button(role: .destructive) {
                    patch(["removeShortcutId": shortcut.id])
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }}
    }


    // MARK: - Actions

    private var cleanTitle: String {
        String(title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(Self.maxTitle))
    }

    /// An address as typed: a bare host gains https. Nil when it is not a web address.
    static func typedURL(_ value: String) -> URL? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = raw.lowercased()
        let full = lower.hasPrefix("http://") || lower.hasPrefix("https://") ? raw : "https://" + raw
        guard let url = URL(string: full), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    private func save() {
        defer { adding = false }
        guard let url = Self.typedURL(address), !cleanTitle.isEmpty else { return }
        let id = "sc_" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + "_" + UUID().uuidString.prefix(4).lowercased()
        patch(["addShortcut": [
            "id": id,
            "title": cleanTitle,
            "url": url.absoluteString,
            "kind": "url",
            "key": true,
            "author": "person",
        ]])
    }
}
