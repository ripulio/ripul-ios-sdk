#if os(iOS)
import SwiftUI

// ---------------------------------------------------------------------------
// Native SOLUTION CONTEXTS editor — the "introduce a new context" UX.
//
// A context maps 1:1 to a server-side solution context; this screen is CRUD
// over the admin API, nothing native-only. Tool membership is picked from
// three sources with different storage rules:
//   • a COLLECTION      → stored as `group://<name>` (living reference,
//                          expanded server-side per request)
//   • a NATIVE tool     → stored web-side-prefixed (`host_<name>`), because
//                          context whitelists match the web layer's names
//                          exactly, no canonicalisation
//   • anything else     → free text, stored as typed (web/deployed tools)
//
// Prompts are deliberately absent from v1: `systemPromptId` references a
// separate entity with its own CRUD; the dashboard edits it today.
// ---------------------------------------------------------------------------

@MainActor
final class RipulSolutionContextsModel: ObservableObject {
    @Published private(set) var contexts: [RipulSolutionContext] = []
    @Published var loading = false
    @Published var errorMessage: String?

    private let client: RipulSolutionContextsClient

    init(client: RipulSolutionContextsClient) {
        self.client = client
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            contexts = try await client.list()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func save(
        existing: RipulSolutionContext?,
        name: String,
        description: String?,
        includedTools: [String],
        excludedTools: [String]
    ) async -> Bool {
        do {
            if let existing {
                _ = try await client.update(
                    id: existing.id, name: name, description: description,
                    includedTools: includedTools, excludedTools: excludedTools
                )
            } else {
                _ = try await client.create(
                    name: name, description: description,
                    includedTools: includedTools, excludedTools: excludedTools
                )
            }
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(id: String) async -> Bool {
        do {
            try await client.delete(id: id)
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// The tool sources the membership picker offers. Collections come from the
/// collections API; native tools from the host's registry (via the editor
/// catalogs the console already builds).
struct RipulContextToolSources {
    let collections: () async -> [String]           // collection names
    let catalogs: () -> [RipulToolCatalog]          // native surfaces (registry + console channel)
}

@available(iOS 16.0, *)
public struct RipulSolutionContextsScreen: View {
    @StateObject private var model: RipulSolutionContextsModel
    private let sources: RipulContextToolSources

    @State private var creating = false
    @State private var editing: RipulSolutionContext?

    init(client: RipulSolutionContextsClient, sources: RipulContextToolSources) {
        _model = StateObject(wrappedValue: RipulSolutionContextsModel(client: client))
        self.sources = sources
    }

    public var body: some View {
        List {
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(model.contexts) { context in
                    Button {
                        editing = context
                    } label: {
                        contextRow(context)
                    }
                    .buttonStyle(.plain)
                    .disabled(context.isBuiltIn)
                }
            } footer: {
                Text("A context selects which tools (and prompt) a session gets. Reference a collection to curate membership once and have every referencing context follow it live. Enter one in the console chat with /context <id>.")
            }
        }
        .uiKitIdentifier("RipulSolutionContexts.list")
        .navigationTitle("Solution Contexts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
                .uiKitIdentifier("RipulSolutionContexts.add")
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                RipulSolutionContextEditorView(model: model, existing: nil, sources: sources)
            }
        }
        .sheet(item: $editing) { context in
            NavigationStack {
                RipulSolutionContextEditorView(model: model, existing: context, sources: sources)
            }
        }
    }

    @ViewBuilder
    private func contextRow(_ context: RipulSolutionContext) -> some View {
        HStack(spacing: 10) {
            Image(systemName: context.isSeeded ? "sparkles" : "square.stack.3d.up")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(context.name)
                        .font(.subheadline.weight(.semibold))
                    if context.isSeeded {
                        Text("seeded")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(membershipSummary(context))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func membershipSummary(_ context: RipulSolutionContext) -> String {
        if context.includedTools.isEmpty && context.excludedTools.isEmpty {
            return "All tools (no restrictions) · \(context.id)"
        }
        let groups = context.includedTools.filter { $0.hasPrefix("group://") }.count
        let names = context.includedTools.count - groups
        var parts: [String] = []
        if groups > 0 { parts.append("\(groups) collection\(groups == 1 ? "" : "s")") }
        if names > 0 { parts.append("\(names) tool\(names == 1 ? "" : "s")") }
        if !context.excludedTools.isEmpty { parts.append("\(context.excludedTools.count) excluded") }
        return parts.joined(separator: " · ") + " · \(context.id)"
    }
}

// MARK: - Editor

@available(iOS 16.0, *)
struct RipulSolutionContextEditorView: View {
    @ObservedObject var model: RipulSolutionContextsModel
    let existing: RipulSolutionContext?
    let sources: RipulContextToolSources

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var descriptionText = ""
    @State private var includedTools: [String] = []
    @State private var excludedTools: [String] = []
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var pickingFor: PickTarget?
    @State private var didLoad = false

    private enum PickTarget: Identifiable {
        case included, excluded
        var id: Int { self == .included ? 0 : 1 }
    }

    private var isEditing: Bool { existing != nil }
    private var canSave: Bool { !saving && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            Section("Context") {
                TextField("Records", text: $name)
                    .uiKitIdentifier("RipulSolutionContexts.editor.name")
                TextField("What sessions in this context are for", text: $descriptionText, axis: .vertical)
                    .lineLimit(2...4)
            }

            toolsSection(
                title: "Included tools",
                footer: includedTools.isEmpty
                    ? "Empty = no restrictions: every tool stays available. Add entries to make this a whitelist."
                    : "Only these tools (and collection members) are available in this context.",
                tools: $includedTools,
                target: .included
            )

            toolsSection(
                title: "Excluded tools",
                footer: "Removed even if included elsewhere — deny wins.",
                tools: $excludedTools,
                target: .excluded
            )

            if isEditing {
                Section {
                    Button("Delete context", role: .destructive) {
                        confirmingDelete = true
                    }
                } footer: {
                    if existing?.isSeeded == true {
                        Text("This is a seeded context. Deleting it is allowed — it will be re-created empty on the next seeding touch (new site key or console sign-in).")
                    }
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Context" : "New Context")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Create") { Task { await save() } }
                    .disabled(!canSave)
                    .uiKitIdentifier("RipulSolutionContexts.editor.save")
            }
        }
        .onAppear(perform: loadExisting)
        .alert("Delete context?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    if let existing, await model.delete(id: existing.id) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions using it fall back to no context. Site keys listing it must be updated separately.")
        }
        .sheet(item: $pickingFor) { target in
            NavigationStack {
                RipulContextToolPicker(sources: sources) { entry in
                    switch target {
                    case .included: if !includedTools.contains(entry) { includedTools.append(entry) }
                    case .excluded: if !excludedTools.contains(entry) { excludedTools.append(entry) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolsSection(
        title: String,
        footer: String,
        tools: Binding<[String]>,
        target: PickTarget
    ) -> some View {
        Section {
            ForEach(tools.wrappedValue, id: \.self) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.hasPrefix("group://") ? "folder.badge.gearshape" : "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(entry.hasPrefix("group://") ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(entry)
                        .font(.callout.monospaced())
                }
            }
            .onDelete { offsets in tools.wrappedValue.remove(atOffsets: offsets) }
            Button {
                pickingFor = target
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func loadExisting() {
        guard !didLoad, let existing else { didLoad = true; return }
        didLoad = true
        name = existing.name
        descriptionText = existing.description ?? ""
        includedTools = existing.includedTools
        excludedTools = existing.excludedTools
    }

    private func save() async {
        saving = true
        let ok = await model.save(
            existing: existing,
            name: name.trimmingCharacters(in: .whitespaces),
            description: descriptionText.trimmingCharacters(in: .whitespaces),
            includedTools: includedTools,
            excludedTools: excludedTools
        )
        saving = false
        if ok { dismiss() }
    }
}

// MARK: - Membership picker

@available(iOS 16.0, *)
private struct RipulContextToolPicker: View {
    let sources: RipulContextToolSources
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var collections: [String] = []
    @State private var freeText = ""

    var body: some View {
        List {
            Section {
                ForEach(collections, id: \.self) { name in
                    pickRow("group://\(name)", icon: "folder.badge.gearshape", display: name)
                }
                if collections.isEmpty {
                    Text("No collections yet — create one under Tool Collections.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Collections (by reference)")
            } footer: {
                Text("A reference stays live: edit the collection and every context using it follows on the next request.")
            }

            ForEach(sources.catalogs()) { catalog in
                Section(catalog.name) {
                    ForEach(catalog.tools, id: \.name) { tool in
                        // Context whitelists match WEB-side names exactly; a
                        // native tool's web name is host_-prefixed.
                        pickRow(webName(for: tool.name), icon: "wrench.and.screwdriver", display: tool.name)
                    }
                }
            }

            Section {
                HStack {
                    TextField("web tool name", text: $freeText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.callout.monospaced())
                    Button("Add") {
                        let trimmed = freeText.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        onPick(trimmed)
                        freeText = ""
                        dismiss()
                    }
                    .disabled(freeText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Other (exact name)")
            } footer: {
                Text("For web app or deployed tools — stored exactly as typed.")
            }
        }
        .navigationTitle("Add to context")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { collections = await sources.collections() }
    }

    private func webName(for canonical: String) -> String {
        canonical.hasPrefix("host_") || canonical.hasPrefix("web_tool_") ? canonical : "host_\(canonical)"
    }

    @ViewBuilder
    private func pickRow(_ stored: String, icon: String, display: String) -> some View {
        Button {
            onPick(stored)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(display)
                    .font(.callout.monospaced())
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
