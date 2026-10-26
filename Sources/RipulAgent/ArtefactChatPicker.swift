import SwiftUI

/// Shares the authenticated library and host note transport with the web chat.
/// No model request, draft mutation, definition source or saved run crosses here.
struct ArtefactChatPicker: View {
    let bridge: AgentBridge
    let chatID: String
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []
    @State private var choice: Choice?
    @State private var search = ""
    @State private var surface = "widget"
    @State private var presentationID = UUID().uuidString
    @State private var busy = false
    @State private var attempted = false
    @State private var error: String?

    private struct Item: Decodable, Identifiable { let id: String; let title: String; let latestRevision: Int }
    private struct Choice: Decodable {
        let id: String; let title: String; let revision: Int; let surfaces: [String]; let canShare: Bool
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if busy { ProgressView().padding() }
                if let error { Text(error).foregroundStyle(.ripul(.danger)).font(.ripul(.callout)).padding().accessibilityIdentifier("ArtefactChat.error") }
                if let choice {
                    Form {
                        Section {
                            Text(choice.title).ripulText().font(.ripul(.headline))
                            Text("Revision \(choice.revision) · saved with this card").foregroundStyle(.ripul(.textSecondary))
                            Picker("Display", selection: $surface) {
                                ForEach(choice.surfaces, id: \.self) { value in
                                    Text(value == "widget" ? "Interactive chat card" : "Full page").tag(value)
                                }
                            }.disabled(busy || attempted)
                        } footer: { RipulSectionFooter {
                            Text("Adding a card shares nothing. Each person in this chat opens it with their own access; to give someone access, use Sharing on the artefact itself. Private scenarios and run history stay private.")
                        } }.ripulThemedListRows()
                        Section {
                            Button(attempted ? "Retry add to chat" : "Add to chat") { Task { await post(choice) } }
                                .disabled(busy).accessibilityIdentifier("ArtefactChat.add")
                            if !attempted { Button("Back to library") { self.choice = nil; error = nil }.disabled(busy) }
                        }.ripulThemedListRows()
                    }.ripulThemedList()
                } else {
                    TextField("Search artefacts", text: $search).textFieldStyle(.roundedBorder).padding()
                    List {
                        ForEach(items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { item in
                            Button { Task { await select(item) } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                    Text("Revision \(item.latestRevision)").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                                }
                            }.disabled(busy)
                        }
                        if !busy && items.filter({ search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }).isEmpty {
                            Text("No artefacts found.").foregroundStyle(.ripul(.textSecondary))
                        }
                    }.ripulThemedList()
                    if !busy && error != nil { Button("Reload library") { Task { await load() } }.padding() }
                }
            }
            .navigationTitle("Add artefact to chat")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    @MainActor private func call(_ operation: String, _ input: [String: Any] = [:]) async throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: ["chatId":chatID,"operation":operation,"input":input], options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        let result = try await bridge.callAsyncJavaScript("""
            const request = \(json);
            if (typeof window.__ripulArtefactChat !== 'function') throw new Error('Chat is still loading. Try again.');
            return await window.__ripulArtefactChat(request.chatId, request.operation, request.input);
            """)
        guard let result else { throw NSError(domain: "ArtefactChat", code: 1, userInfo: [NSLocalizedDescriptionKey:"No reply from this chat. Try again."]) }
        return result
    }
    private func decode<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    @MainActor private func load() async {
        busy = true; error = nil
        defer { busy = false }
        do { items = try decode(await call("catalog"), as: [Item].self) }
        catch { self.error = error.localizedDescription }
    }
    @MainActor private func select(_ item: Item) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let selected = try decode(await call("choose", ["id":item.id]), as: Choice.self)
            choice = selected; surface = selected.surfaces.first ?? "page"
            presentationID = UUID().uuidString; attempted = false
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func post(_ choice: Choice) async {
        guard !busy else { return }
        busy = true; error = nil; attempted = true
        defer { busy = false }
        do {
            _ = try await call("post", ["artefactId":choice.id,"revision":choice.revision,"surface":surface,"presentationId":presentationID])
            dismiss()
        } catch {
            self.error = "Adding was not confirmed: \(error.localizedDescription) Retry to confirm the same card."
        }
    }
}
