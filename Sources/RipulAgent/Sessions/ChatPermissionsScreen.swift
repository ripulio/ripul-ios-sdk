import SwiftUI

// Permissions: who is in a group chat, and what each person's requests may use
// of the chat owner's.
//
// It is opened from "Permissions", the first item of a group chat's menu, which
// only the chat's owner is shown. Each row opens that person's
// MemberAuthorityScreen. Before 12 October 2026 the only way there was a
// member's row in the Invite by Email sheet, which nobody looking for
// permissions would open.
//
// Who is in the chat comes from the server (the same people the composer's @
// menu lists). What each one holds comes from the chat's Mac, which keeps the
// record. The rules: chrome-extension/docs/architecture/chatMemberAuthority.md.

public extension Notification.Name {
    /// Posted with the bridge as `object` to open a chat's Permissions. userInfo: chatId.
    static let ripulShowChatPermissions = Notification.Name("ripulShowChatPermissions")
    /// Posted when someone is invited to a chat or removed from one, so a
    /// screen that shows whether a chat is a group chat can ask again.
    static let ripulChatMembershipChanged = Notification.Name("ripulChatMembershipChanged")
}

/// Presents a chat's Permissions when its menu item asks.
public struct ChatPermissionsSheet: ViewModifier {
    let bridge: AgentBridge
    @State private var request: Request?

    private struct Request: Identifiable {
        let chatId: String
        var id: String { chatId }
    }

    public init(bridge: AgentBridge) { self.bridge = bridge }

    public func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ripulShowChatPermissions)) { notification in
                guard let source = notification.object as? AgentBridge, source === bridge,
                      let chatId = notification.userInfo?["chatId"] as? String else { return }
                request = Request(chatId: chatId)
            }
            .ripulSheet(item: $request) { request in
                ChatPermissionsScreen(bridge: bridge, chatId: request.chatId)
            }
    }
}

struct ChatPermissionsScreen: View {
    let bridge: AgentBridge
    let chatId: String

    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []
    @State private var former: [Person] = []
    @State private var loaded = false
    @State private var error: String?

    struct Person: Identifiable {
        /// The user id, as the chat's Mac knows them.
        let id: String
        let name: String
        var holds: String
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.ripul(.warning)) }.ripulThemedListRows()
                }
                if !loaded {
                    Section { ProgressView("Asking the chat's Mac…") }.ripulThemedListRows()
                } else if people.isEmpty {
                    Section {
                        Text("Nobody has joined this chat yet.").foregroundStyle(.ripul(.textSecondary))
                    } footer: {
                        RipulSectionFooter { Text("When someone you invited joins, set here what their requests to the agent may use of yours.") }
                    }.ripulThemedListRows()
                } else {
                    Section {
                        ForEach(people) { row(for: $0) }
                    } header: {
                        RipulSectionHeader { Text("People in this chat") }
                    } footer: {
                        RipulSectionFooter {
                            Text("What each person's requests to the agent may use of yours without asking you: your devices, folders on your Mac and your browsers. This is for this chat only.")
                        }
                    }.ripulThemedListRows()
                }
                if !former.isEmpty {
                    Section {
                        ForEach(former) { row(for: $0) }
                    } header: {
                        RipulSectionHeader { Text("No longer in this chat") }
                    } footer: {
                        RipulSectionFooter { Text("They keep this if you invite them again within 30 days.") }
                    }.ripulThemedListRows()
                }
            }.ripulThemedList()
            .navigationTitle("Permissions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .uiKitIdentifier("ChatPermissions.doneButton")
                }
            }
            .refreshable { await load() }
            // Runs again on the way back from a person, so their row says what was just set.
            .task { await load() }
        }
    }

    private func row(for person: Person) -> some View {
        NavigationLink {
            MemberAuthorityScreen(bridge: bridge, chatId: chatId, userId: person.id, name: person.name)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).ripulText()
                Text(person.holds)
                    .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
            }
        }
        .uiKitIdentifier("ChatPermissions.memberRow")
    }

    private func load() async {
        // The server lists a person as `human-<user id>`; the chat's Mac knows them by the id alone.
        let joined: [(id: String, name: String)] = await bridge.queryParticipants(chatId: chatId).compactMap { entry in
            guard entry["kind"] as? String == "human", let raw = entry["id"] as? String, !raw.isEmpty else { return nil }
            let id = raw.hasPrefix("human-") ? String(raw.dropFirst("human-".count)) : raw
            return (id, (entry["name"] as? String) ?? "An invited member")
        }
        var held: [MemberAuthorityState.Member] = []
        do {
            let state = try await bridge.memberAuthority(chatId: chatId)
            held = state.members ?? []
            error = state.error
        } catch {
            self.error = error.localizedDescription
        }
        let byId = Dictionary(held.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        let inChat = joined.map { Person(id: $0.id, name: $0.name, holds: Self.holds(byId[$0.id])) }
        let others = held.filter { member in !joined.contains { $0.id == member.userId } }
            .map { Person(id: $0.userId, name: $0.name, holds: Self.holds($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if inChat.isEmpty {
            // The server could not be asked, or lists nobody: show who the Mac has heard from.
            people = others
            former = []
        } else {
            people = inChat
            former = held.filter { member in member.level != "ask" && !joined.contains { $0.id == member.userId } }
                .map { Person(id: $0.userId, name: $0.name, holds: Self.holds($0)) }
        }
        loaded = true
    }

    /// One line for what a person holds, in the words of their own screen.
    static func holds(_ member: MemberAuthorityState.Member?) -> String {
        let refuses = member?.whenNotHeld == "refuse"
        switch member?.level {
        case "acts-as-me":
            return "Everything, as you"
        case "named" where member?.permissions.isEmpty == false:
            let count = member?.permissions.count ?? 0
            return "\(count) \(count == 1 ? "thing" : "things") you chose. Anything else is \(refuses ? "refused" : "asked")."
        default:
            return refuses ? "Nothing of yours. Their requests for it are refused." : "Nothing standing. You are asked each time."
        }
    }
}
