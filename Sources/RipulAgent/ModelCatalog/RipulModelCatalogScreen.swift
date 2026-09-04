#if os(iOS)
import SwiftUI

// ---------------------------------------------------------------------------
// Native MODELS screen — the iPhone equivalent of the web "Models" tab.
//
// One List over the stored catalog: per-context defaults up top, then a
// section per display group, stats at the bottom. Row tap edits, swipe
// deletes/duplicates, leading swipe flips enabled, and the toolbar menu
// carries the gateway operations (discover, verify costs). Everything is
// plain UIKit-native presentation — no grid, no web re-skin.
// ---------------------------------------------------------------------------

@MainActor
final class RipulModelCatalogModel: ObservableObject {
    @Published private(set) var models: [RipulCatalogModel] = []
    @Published private(set) var defaults: RipulModelCatalogDefaults?
    @Published private(set) var stats: RipulModelCatalogStats?
    @Published var loading = false
    @Published var errorMessage: String?

    let client: RipulModelCatalogClient

    init(client: RipulModelCatalogClient) {
        self.client = client
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            let admin = try await client.fetchCatalog()
            models = admin.catalog.models
            defaults = admin.catalog.defaults
            stats = admin.stats
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func setEnabled(_ model: RipulCatalogModel, _ enabled: Bool) async {
        do {
            try await client.setEnabled(id: model.id, enabled)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ model: RipulCatalogModel) async {
        do {
            try await client.delete(id: model.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setDefault(slot: String, modelId: String) async {
        do {
            try await client.updateDefaults([slot: modelId])
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@available(iOS 16.0, *)
public struct RipulModelCatalogScreen: View {
    @StateObject private var model: RipulModelCatalogModel
    @State private var search = ""
    @State private var editorTarget: EditorTarget?
    @State private var showingDiscovery = false
    @State private var showingCostCheck = false
    @State private var deleting: RipulCatalogModel?

    /// Sheet driver: create (blank), create-prefilled (duplicate) or edit.
    private struct EditorTarget: Identifiable {
        let id: String
        let seed: RipulCatalogModel?
        let isNew: Bool
    }

    public init(client: RipulModelCatalogClient) {
        _model = StateObject(wrappedValue: RipulModelCatalogModel(client: client))
    }

    private struct Group: Identifiable {
        let name: String
        let models: [RipulCatalogModel]
        var id: String { name }
    }

    private var filtered: [RipulCatalogModel] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.models }
        return model.models.filter {
            $0.name.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
                || $0.modelId.lowercased().contains(q)
        }
    }

    private var groups: [Group] {
        Dictionary(grouping: filtered, by: \.displayGroup)
            .map { name, members in
                Group(name: name, models: members.sorted {
                    ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name)
                })
            }
            .sorted { $0.name < $1.name }
    }

    public var body: some View {
        List {
            if let defaults = model.defaults, !model.models.isEmpty {
                defaultsSection(defaults)
            }
            ForEach(groups) { group in
                Section(group.name) {
                    ForEach(group.models) { row($0) }
                }
            }
            if let stats = model.stats {
                Section {
                    Text("\(stats.totalModels) models · \(stats.enabledModels) enabled")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .searchable(text: $search, prompt: "Name or model id")
        .overlay {
            if model.loading && model.models.isEmpty {
                ProgressView("Loading catalog…")
            } else if !model.loading && model.models.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cube")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(model.errorMessage ?? "No models in the catalog")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await model.load() } }
                        .buttonStyle(.bordered)
                }
                .padding()
            }
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        Task { await model.load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showingDiscovery = true
                    } label: {
                        Label("Discover from gateway", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button {
                        showingCostCheck = true
                    } label: {
                        Label("Verify costs", systemImage: "dollarsign.arrow.circlepath")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .uiKitIdentifier("ModelCatalog.menu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = EditorTarget(id: "new", seed: nil, isNew: true)
                } label: {
                    Image(systemName: "plus")
                }
                .uiKitIdentifier("ModelCatalog.add")
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(item: $editorTarget) { target in
            RipulModelCatalogEditorSheet(
                client: model.client,
                seed: target.seed,
                isNew: target.isNew
            ) {
                Task { await model.load() }
            }
        }
        .sheet(isPresented: $showingDiscovery) {
            RipulModelDiscoverySheet(client: model.client) {
                Task { await model.load() }
            }
        }
        .sheet(isPresented: $showingCostCheck) {
            RipulModelCostVerifySheet(client: model.client) {
                Task { await model.load() }
            }
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "model")?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let m = deleting {
                    deleting = nil
                    Task { await model.delete(m) }
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Removes the catalog entry for every client. A system built-in can't be deleted — disable it instead.")
        }
        .alert(
            "Couldn't update the catalog",
            isPresented: Binding(
                get: { model.errorMessage != nil && !model.models.isEmpty },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Defaults

    private func defaultsSection(_ defaults: RipulModelCatalogDefaults) -> some View {
        Section {
            defaultRow("Free tier", slot: "free", current: defaults.free)
            defaultRow("Pro tier", slot: "pro", current: defaults.pro)
            defaultRow("Enterprise", slot: "enterprise", current: defaults.enterprise)
            defaultRow("Site keys", slot: "siteKey", current: defaults.siteKey)
        } header: {
            Text("Default models")
        } footer: {
            Text("What each context gets when no model is chosen.")
        }
    }

    private func defaultRow(_ label: String, slot: String, current: String) -> some View {
        let candidates = model.models.filter(\.enabled).sorted { $0.name < $1.name }
        return Picker(label, selection: Binding(
            get: { current },
            set: { picked in
                guard picked != current else { return }
                Task { await model.setDefault(slot: slot, modelId: picked) }
            }
        )) {
            // A default pointing at a disabled/vanished id still has to render.
            if !current.isEmpty && !candidates.contains(where: { $0.id == current }) {
                Text(current).tag(current)
            }
            ForEach(candidates) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.menu)
        .uiKitIdentifier("ModelCatalog.default.\(slot)")
    }

    // MARK: - Rows

    private func row(_ m: RipulCatalogModel) -> some View {
        Button {
            editorTarget = EditorTarget(id: m.id, seed: m, isNew: false)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if m.tier == "premium" {
                        badge("Premium", tint: .orange)
                    }
                    if !m.enabled {
                        badge("Off", tint: .secondary)
                    }
                    Spacer()
                    badge(m.typeLabel, tint: typeTint(m))
                }
                Text(m.modelId.isEmpty ? m.id : m.modelId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if m.perMInput > 0 || m.perMOutput > 0 {
                    Text("\(price(m.perMInput)) in · \(price(m.perMOutput)) out · per M tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(m.enabled ? 1 : 0.55)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await model.setEnabled(m, !m.enabled) }
            } label: {
                Label(
                    m.enabled ? "Disable" : "Enable",
                    systemImage: m.enabled ? "pause.circle" : "checkmark.circle"
                )
            }
            .tint(m.enabled ? .gray : .green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = m
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editorTarget = EditorTarget(id: "\(m.id)-copy", seed: duplicate(of: m), isNew: true)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .tint(.blue)
        }
        .uiKitIdentifier("ModelCatalog.row")
    }

    private func duplicate(of m: RipulCatalogModel) -> RipulCatalogModel {
        var copy = m
        copy.id = "\(m.id)-copy"
        copy.name = "\(m.name) (Copy)"
        return copy
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func typeTint(_ m: RipulCatalogModel) -> Color {
        if m.isCli { return .teal }
        switch m.provider {
        case "anthropic": return .orange
        case "openai": return .green
        case "openrouter": return .purple
        default: return .blue
        }
    }

    private func price(_ value: Double) -> String {
        "$" + String(format: "%g", value)
    }
}
#endif
