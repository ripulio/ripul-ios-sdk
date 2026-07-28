#if os(iOS)
import SwiftUI

// ---------------------------------------------------------------------------
// In-app editor for progressive-discovery tool collections.
//
// Lives on the signed-in console surface, where a Clerk token is guaranteed —
// see docs/tool-collections-editor.md. The value it adds over the web
// dashboard is the live tool set: it matches patterns against the tools THIS
// build just registered, so a developer sees what a rule captures before
// saving it.
//
// Saving does not take effect until the app restarts: collections reach the
// app as part of its site-key configuration, resolved at session start. That
// is accepted (regrouping is rare), which is exactly why every successful save
// says so out loud — otherwise a working write is indistinguishable from a
// failed one.
// ---------------------------------------------------------------------------

// MARK: - Model

@available(iOS 16.0, *)
@MainActor
public final class RipulToolCollectionsModel: ObservableObject {
    @Published public private(set) var collections: [RipulToolCollection] = []
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?
    /// Set after any successful write. Drives the restart notice.
    @Published public var savedNotice: String?

    private let client: RipulToolCollectionsClient

    public init(client: RipulToolCollectionsClient) {
        self.client = client
    }

    /// Categories only — groups are a different concept (`group://` references)
    /// and are not what progressive discovery collapses.
    public var categories: [RipulToolCollection] {
        collections.filter(\.isCategory).sorted { $0.displayLabel < $1.displayLabel }
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        do {
            collections = try await client.list(type: "category")
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    public func create(name: String, edit: RipulToolCollectionEdit) async -> Bool {
        await write {
            let created = try await self.client.createCategory(name: name, edit: edit)
            self.collections.append(created)
            return "Created \"\(created.displayLabel)\""
        }
    }

    public func update(id: String, edit: RipulToolCollectionEdit) async -> Bool {
        await write {
            let updated = try await self.client.update(id: id, edit: edit)
            if let index = self.collections.firstIndex(where: { $0.id == id }) {
                self.collections[index] = updated
            }
            return "Saved \"\(updated.displayLabel)\""
        }
    }

    public func delete(id: String) async -> Bool {
        let label = collections.first { $0.id == id }?.displayLabel ?? "collection"
        return await write {
            try await self.client.delete(id: id)
            self.collections.removeAll { $0.id == id }
            return "Deleted \"\(label)\" — its tools return to the agent's flat list"
        }
    }

    /// Runs a write, surfacing either the restart notice or the server's error.
    private func write(_ operation: @escaping () async throws -> String) async -> Bool {
        errorMessage = nil
        do {
            savedNotice = try await operation()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Tools matched by no category — what the agent still sees individually.
    public func ungroupedTools(from tools: [RipulRegisteredTool]) -> [RipulRegisteredTool] {
        let names = tools.map(\.name)
        var grouped = Set<String>()
        for collection in categories {
            let matcher = RipulToolCollectionMatcher(
                explicitTools: collection.explicitTools,
                toolPatterns: collection.toolPatterns,
                toolNames: names
            )
            grouped.formUnion(matcher.presentMatches)
        }
        return tools.filter { !grouped.contains($0.name) }
    }
}

// MARK: - Screen

/// Browse and edit the account's tool collections against this build's tools.
@available(iOS 16.0, *)
public struct RipulToolCollectionsScreen: View {
    @ObservedObject private var bridge: AgentBridge
    @StateObject private var model: RipulToolCollectionsModel
    @State private var creating = false

    public init(bridge: AgentBridge, tokenProvider: @escaping () -> String?) {
        self.bridge = bridge
        _model = StateObject(wrappedValue: RipulToolCollectionsModel(
            client: RipulToolCollectionsClient(tokenProvider: tokenProvider)
        ))
    }

    private var tools: [RipulRegisteredTool] { bridge.registeredToolSummaries }

    public var body: some View {
        List {
            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                if model.categories.isEmpty && !model.isLoading {
                    Text("No collections yet. Every tool is passed to the agent individually.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.categories) { collection in
                    NavigationLink {
                        RipulToolCollectionEditorView(
                            model: model,
                            tools: tools,
                            existing: collection
                        )
                    } label: {
                        row(for: collection)
                    }
                }
            } header: {
                Text("Collections")
            } footer: {
                Text("Each collection is shown to the agent as ONE tool it expands on demand.")
            }

            ungroupedSection
        }
        .navigationTitle("Tool Collections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("ripul.toolCollections.add")
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                RipulToolCollectionEditorView(model: model, tools: tools, existing: nil)
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert(
            "Restart to apply",
            isPresented: Binding(
                get: { model.savedNotice != nil },
                set: { if !$0 { model.savedNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.savedNotice = nil }
        } message: {
            // Without this the developer checks the agent, sees the old
            // grouping, and concludes the save failed.
            Text("\(model.savedNotice ?? "Saved").\n\nCollections are read when the app starts. Restart to see the new grouping take effect.")
        }
    }

    private func row(for collection: RipulToolCollection) -> some View {
        let matcher = RipulToolCollectionMatcher(
            explicitTools: collection.explicitTools,
            toolPatterns: collection.toolPatterns,
            toolNames: tools.map(\.name)
        )
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(collection.displayLabel).font(.body)
                if collection.isIsolate {
                    Text("isolate")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            Text(summary(matcher: matcher, collection: collection))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Curated size first, local presence second. A collection of web app
    /// tools is fully populated and still matches nothing in this build —
    /// reporting only the local count would render it as empty.
    private func summary(matcher: RipulToolCollectionMatcher, collection: RipulToolCollection) -> String {
        var parts = ["\(matcher.memberCount) member\(matcher.memberCount == 1 ? "" : "s")"]
        parts.append("\(matcher.presentCount) in this app")
        if !collection.toolPatterns.isEmpty {
            parts.append("\(collection.toolPatterns.count) pattern\(collection.toolPatterns.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var ungroupedSection: some View {
        let ungrouped = model.ungroupedTools(from: tools)
        Section {
            if ungrouped.isEmpty {
                Text("Every registered tool belongs to a collection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ungrouped) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.system(.footnote, design: .monospaced))
                        if !tool.description.isEmpty {
                            Text(tool.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        } header: {
            Text("Ungrouped (\(ungrouped.count))")
        } footer: {
            Text("Passed to the agent individually, costing tokens on every turn.")
        }
    }
}
#endif
