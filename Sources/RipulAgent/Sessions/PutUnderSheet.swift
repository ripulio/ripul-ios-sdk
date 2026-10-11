import SwiftUI

/// Picks the chat another chat is kept under in the session list.
///
/// Any chat can hold others: one used as a container for a piece of work has
/// its notes and tags like any chat, and the chats put under it move, fold
/// and archive with it as the chats an agent started do.
@available(iOS 26.0, macOS 26.0, *)
struct PutUnderSheet: View {
    let session: UnifiedSession
    /// The chats it can go under: not itself, and nothing that is under it.
    let candidates: [UnifiedSession]
    let onPick: (UnifiedSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var matching: [UnifiedSession] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.title.lowercased().contains(query) || ($0.projectName?.lowercased().contains(query) ?? false)
        }
    }

    /// Where a chat is, to tell two of the same name apart: its Mac and its folder.
    private func detail(_ chat: UnifiedSession) -> String {
        [chat.machineName, chat.projectName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(matching) { chat in
                        Button {
                            onPick(chat)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat.title)
                                    .font(.ripul(.body))
                                    .foregroundStyle(.ripul(.text))
                                    .lineLimit(1)
                                    .uiKitIdentifier("PutUnderSheet.chat.title")
                                let where_ = detail(chat)
                                if !where_.isEmpty {
                                    Text(where_)
                                        .font(.ripul(.caption))
                                        .foregroundStyle(.ripul(.textSecondary))
                                        .lineLimit(1)
                                        .uiKitIdentifier("PutUnderSheet.chat.detail")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .uiKitIdentifier("PutUnderSheet.chat")
                    }
                } header: {
                    Text("Put “\(session.title)” under")
                        .uiKitIdentifier("PutUnderSheet.header")
                } footer: {
                    if matching.isEmpty {
                        Text(candidates.isEmpty ? "There is no other chat to put it under." : "No chat matches “\(searchText)”.")
                            .uiKitIdentifier("PutUnderSheet.empty")
                    }
                }.ripulThemedListRows()
            }.ripulThemedList()
            .searchable(text: $searchText, prompt: "Search chats")
            .navigationTitle("Put Under")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .uiKitIdentifier("PutUnderSheet.cancel")
                }
            }
        }
        .uiKitIdentifier("PutUnderSheet")
    }
}
