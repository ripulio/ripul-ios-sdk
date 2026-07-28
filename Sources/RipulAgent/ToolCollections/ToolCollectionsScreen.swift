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
    /// Latest successful write, shown transiently.
    @Published public var savedNotice: String?
    /// Sticky once anything has been written. Drag-and-drop produces a write
    /// per drop, so the restart requirement is a persistent banner rather than
    /// a modal per action — but it still has to be said, or a working save is
    /// indistinguishable from a failed one.
    @Published public var needsRestart = false
    /// In-flight writes, for a progress affordance during rapid drops.
    @Published public var savingCount = 0

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

    /// Move a tool between collections, or out of one entirely.
    ///
    /// Applied optimistically so the list reorders under the finger, then
    /// persisted. A failed write reloads from the server rather than leaving
    /// the screen showing an edit that didn't land.
    ///
    /// Only ever adjusts `explicitTools`. Pattern-derived membership is not
    /// removable this way — the pattern would just re-capture the tool — which
    /// is why the UI does not offer those rows for dragging.
    /// Internal, not public: `RipulToolDragItem` is a detail of the drag
    /// implementation and isn't part of the SDK's surface.
    func move(_ item: RipulToolDragItem, to targetId: String?) async {
        guard item.sourceCollectionId != targetId else { return }

        let snapshot = collections
        var edits: [(id: String, tools: [String])] = []

        if let sourceId = item.sourceCollectionId,
           let index = collections.firstIndex(where: { $0.id == sourceId }) {
            var tools = collections[index].explicitTools
            tools.removeAll { RipulToolCollectionMatcher.canonicalName($0) == RipulToolCollectionMatcher.canonicalName(item.toolName) }
            collections[index].explicitTools = tools
            edits.append((sourceId, tools))
        }

        if let targetId, let index = collections.firstIndex(where: { $0.id == targetId }) {
            var tools = collections[index].explicitTools
            let canonical = RipulToolCollectionMatcher.canonicalName(item.toolName)
            if !tools.contains(where: { RipulToolCollectionMatcher.canonicalName($0) == canonical }) {
                tools.append(item.toolName)
                collections[index].explicitTools = tools
                edits.append((targetId, tools))
            }
        }

        guard !edits.isEmpty else { return }

        errorMessage = nil
        savingCount += 1
        defer { savingCount -= 1 }
        do {
            for edit in edits {
                _ = try await client.update(
                    id: edit.id,
                    edit: RipulToolCollectionEdit(explicitTools: edit.tools)
                )
            }
            needsRestart = true
        } catch {
            collections = snapshot
            errorMessage = error.localizedDescription
        }
    }

    /// Runs a write, surfacing either the restart notice or the server's error.
    private func write(_ operation: @escaping () async throws -> String) async -> Bool {
        errorMessage = nil
        do {
            savedNotice = try await operation()
            needsRestart = true
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

/// Browse and reorganise tool collections against one named tool surface.
///
/// **Exactly one catalog is in view at a time, never a union.** An app has
/// several disjoint tool surfaces — its users' agent, its in-app dev agent —
/// and both can be worth grouping, but a developer must never be in doubt
/// about which agent's context they are economising. The picker and the
/// purpose line under it are what keep that unambiguous; see `RipulToolCatalog`.
///
/// Membership is edited by dragging: collections expand in place, and a tool
/// dragged onto a collection joins it, dragged to Ungrouped leaves it.
@available(iOS 16.0, *)
public struct RipulToolCollectionsScreen: View {
    @StateObject private var model: RipulToolCollectionsModel
    private let catalogs: [RipulToolCatalog]

    @State private var selectedCatalogId: String
    @State private var creating = false
    @State private var expanded: Set<String> = []
    @State private var editing: RipulToolCollection?
    /// Collection currently under the finger, for a drop highlight.
    @State private var dropTarget: String?

    /// - Parameter catalogs: the tool surfaces available to organise. The first
    ///   is selected initially — pass the end-user catalog first, since it is
    ///   usually the one worth grouping.
    public init(catalogs: [RipulToolCatalog], tokenProvider: @escaping () -> String?) {
        self.catalogs = catalogs
        _selectedCatalogId = State(initialValue: catalogs.first?.id ?? RipulToolCatalog.endUserId)
        _model = StateObject(wrappedValue: RipulToolCollectionsModel(
            client: RipulToolCollectionsClient(tokenProvider: tokenProvider)
        ))
    }

    private var catalog: RipulToolCatalog {
        catalogs.first { $0.id == selectedCatalogId } ?? catalogs.first
            ?? RipulToolCatalog(id: "empty", name: "No tools", purpose: "", tools: [])
    }

    private var tools: [RipulRegisteredTool] { catalog.tools }
    private var toolNames: [String] { catalog.toolNames }

    private func matcher(for collection: RipulToolCollection) -> RipulToolCollectionMatcher {
        RipulToolCollectionMatcher(
            explicitTools: collection.explicitTools,
            toolPatterns: collection.toolPatterns,
            toolNames: toolNames
        )
    }

    private func memberCount(_ collection: RipulToolCollection, in surface: RipulToolCatalog) -> Int {
        RipulToolCollectionMatcher(
            explicitTools: collection.explicitTools,
            toolPatterns: collection.toolPatterns,
            toolNames: surface.toolNames
        ).presentCount
    }

    /// A collection with no members at all — newly created, or emptied. Shown
    /// in every surface because it is a candidate to fill, not an irrelevance.
    private func isUnpopulated(_ collection: RipulToolCollection) -> Bool {
        collection.toolPatterns.isEmpty
            && collection.explicitTools.allSatisfy { $0.hasPrefix("group://") }
    }

    /// Collections worth showing while organising this surface: those holding
    /// at least one of its tools, plus unpopulated ones.
    private var inScopeCollections: [RipulToolCollection] {
        model.categories.filter { memberCount($0, in: catalog) > 0 || isUnpopulated($0) }
    }

    /// Everything else — collections belonging to another surface, and the
    /// Ripul platform's own seeded collections (Automation Tools, Page
    /// Interaction Tools …) which contain only web app tools and are not this
    /// app's concern. Kept behind a disclosure rather than hidden: they are
    /// real, and silently dropping them would be its own confusion.
    private var otherCollections: [RipulToolCollection] {
        let shown = Set(inScopeCollections.map(\.id))
        return model.categories.filter { !shown.contains($0.id) }
    }

    private func elsewhereReason(_ collection: RipulToolCollection) -> String {
        for surface in catalogs where surface.id != catalog.id {
            if memberCount(collection, in: surface) > 0 {
                return "in \(surface.name)"
            }
        }
        return "no tools from this app"
    }

    public var body: some View {
        List {
            catalogSection

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            if model.needsRestart {
                Section {
                    Label(
                        "Saved. Restart the app to apply — collections are read at launch.",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            if inScopeCollections.isEmpty && !model.isLoading {
                Section {
                    Text("No collections group \(catalog.name) yet. Every one of these tools is passed to the agent individually.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(inScopeCollections) { collection in
                collectionSection(collection)
            }

            ungroupedSection
            otherCollectionsSection
        }
        .navigationTitle("Tool Collections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.savingCount > 0 {
                    ProgressView()
                } else {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("ripul.toolCollections.add")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                RipulToolCollectionEditorView(model: model, tools: tools, existing: nil)
            }
        }
        .sheet(item: $editing) { collection in
            NavigationStack {
                RipulToolCollectionEditorView(model: model, tools: tools, existing: collection)
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    // MARK: - Catalog picker

    /// The context header. Without this a developer cannot tell whose tools
    /// they are looking at — which is precisely how this screen first shipped,
    /// silently scoped to the dev agent's own tools.
    @ViewBuilder
    private var catalogSection: some View {
        Section {
            if catalogs.count > 1 {
                Picker("Tool surface", selection: $selectedCatalogId) {
                    ForEach(catalogs) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("ripul.toolCollections.catalogPicker")
            } else {
                Text(catalog.name).font(.subheadline.weight(.semibold))
            }
            Text(catalog.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(catalog.tools.count) tool\(catalog.tools.count == 1 ? "" : "s") registered")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("Organising")
        }
    }

    // MARK: - Collection section

    @ViewBuilder
    private func collectionSection(_ collection: RipulToolCollection) -> some View {
        let m = matcher(for: collection)
        let isOpen = expanded.contains(collection.id)

        Section {
            if isOpen {
                ForEach(m.explicitMatches, id: \.self) { name in
                    memberRow(name, in: collection, kind: .picked)
                }
                ForEach(m.patternMatches, id: \.self) { name in
                    memberRow(name, in: collection, kind: .pattern)
                }
                ForEach(m.absentMembers, id: \.self) { name in
                    memberRow(name, in: collection, kind: .elsewhere)
                }
                if m.memberCount == 0 {
                    Text("Empty — drag a tool here, or add a name pattern.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    editing = collection
                } label: {
                    Label("Edit patterns, mode, label…", systemImage: "slider.horizontal.3")
                        .font(.footnote)
                }
            }
        } header: {
            header(collection, matcher: m, isOpen: isOpen)
        }
        // The header alone is a thin target, and List section headers pin
        // while scrolling, which moves the target mid-drag. Accepting drops on
        // the whole section means anywhere in an expanded group works.
        .dropDestination(for: String.self) { payloads, _ in
            handleDrop(payloads, into: collection.id)
        } isTargeted: { targeted in
            dropTarget = targeted ? collection.id : (dropTarget == collection.id ? nil : dropTarget)
        }
    }

    private func header(
        _ collection: RipulToolCollection,
        matcher m: RipulToolCollectionMatcher,
        isOpen: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(collection.displayLabel)
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                    if collection.isIsolate {
                        Text("isolate")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(summary(matcher: m, collection: collection))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            dropTarget == collection.id
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isOpen { expanded.remove(collection.id) } else { expanded.insert(collection.id) }
            }
        }
        .accessibilityIdentifier("ripul.toolCollections.header")
    }

    private enum MemberKind { case picked, pattern, elsewhere }

    /// One member row. Only `.picked` members are draggable: a `.pattern`
    /// member cannot be removed by editing `explicitTools` (the pattern would
    /// re-capture it immediately), and an `.elsewhere` member is not registered
    /// in the catalog on screen. Offering a drag that silently reverts is worse
    /// than offering none, so both are shown inert with the reason.
    @ViewBuilder
    private func memberRow(_ name: String, in collection: RipulToolCollection, kind: MemberKind) -> some View {
        let row = HStack {
            Image(systemName: kind == .picked ? "line.3.horizontal" : "circle.dotted")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(kind == .picked ? .primary : .secondary)
            Spacer()
            switch kind {
            case .picked:
                EmptyView()
            case .pattern:
                Text("pattern").font(.caption2).foregroundStyle(.secondary)
            case .elsewhere:
                Text(originLabel(for: name)).font(.caption2).foregroundStyle(.secondary)
            }
        }

        if kind == .picked {
            row.draggable(
                RipulToolDragItem(toolName: name, sourceCollectionId: collection.id).encoded
            )
        } else {
            row
        }
    }

    /// Says WHERE a member lives rather than merely that it is missing.
    /// "in End-user tools" is actionable; "not in this app" was false.
    private func originLabel(for name: String) -> String {
        switch RipulMemberAttribution.origin(of: name, viewing: catalog, allCatalogs: catalogs) {
        case .thisCatalog:
            return ""
        case .otherCatalog(let catalogName):
            return "in \(catalogName)"
        case .notNative:
            return "web app or other device"
        }
    }

    /// Curated size first, presence in the SELECTED catalog second. A
    /// collection can span surfaces, so one number could never be honest.
    private func summary(matcher m: RipulToolCollectionMatcher, collection: RipulToolCollection) -> String {
        var parts = ["\(m.memberCount) member\(m.memberCount == 1 ? "" : "s")"]
        parts.append("\(m.presentCount) here")
        if !collection.toolPatterns.isEmpty {
            parts.append("\(collection.toolPatterns.count) pattern\(collection.toolPatterns.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Ungrouped

    @ViewBuilder
    private var ungroupedSection: some View {
        let ungrouped = model.ungroupedTools(from: tools)
        Section {
            if ungrouped.isEmpty {
                Text("Every tool in \(catalog.name) belongs to a collection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(ungrouped) { tool in
                HStack {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                .draggable(
                    RipulToolDragItem(toolName: tool.name, sourceCollectionId: nil).encoded
                )
            }
        } header: {
            HStack {
                Text("Ungrouped in \(catalog.name) (\(ungrouped.count))").textCase(nil)
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(dropTarget == ungroupedDropId ? Color.accentColor.opacity(0.15) : Color.clear)
            .dropDestination(for: String.self) { payloads, _ in
                handleDrop(payloads, into: nil)
            } isTargeted: { targeted in
                dropTarget = targeted ? ungroupedDropId : (dropTarget == ungroupedDropId ? nil : dropTarget)
            }
        } footer: {
            Text("Passed to that agent individually, costing tokens on every turn. Drag one onto a collection above to group it.")
        }
    }

    private var ungroupedDropId: String { "__ungrouped__" }

    // MARK: - Out of scope

    /// Collections that hold none of this surface's tools, behind a disclosure.
    ///
    /// Two kinds land here, and the row says which: collections belonging to
    /// the app's OTHER surface, and Ripul's own seeded platform collections
    /// (web app tools like `automationManager`) which an SDK consumer has no
    /// reason to organise. Collapsed by default so the list stays about the
    /// surface in hand.
    @ViewBuilder
    private var otherCollectionsSection: some View {
        if !otherCollections.isEmpty {
            Section {
                DisclosureGroup("Show \(otherCollections.count)") {
                    ForEach(otherCollections) { collection in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(collection.displayLabel).font(.footnote)
                            Text(elsewhereReason(collection))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.footnote)
            } header: {
                Text("Not organising \(catalog.name)")
            } footer: {
                Text("Collections holding none of this surface's tools — the app's other surface, or Ripul's own platform collections.")
            }
        }
    }

    // MARK: - Drop handling

    /// Returns true only when at least one payload was ours — an unrecognised
    /// drop (text from another app) is rejected rather than parsed.
    private func handleDrop(_ payloads: [String], into targetId: String?) -> Bool {
        let items = payloads.compactMap(RipulToolDragItem.decode)
        guard !items.isEmpty else { return false }
        dropTarget = nil
        Task {
            for item in items {
                await model.move(item, to: targetId)
            }
            // Reveal the destination so the moved tool is visible where it landed.
            if let targetId {
                withAnimation { _ = expanded.insert(targetId) }
            }
        }
        return true
    }
}
#endif
