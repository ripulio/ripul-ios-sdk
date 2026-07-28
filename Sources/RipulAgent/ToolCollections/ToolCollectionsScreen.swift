#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

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
/// **Built on ScrollView + LazyVStack, deliberately not List.** Membership is
/// edited by dragging, and `List` will not deliver drops: its rows are
/// collection-view cells, and a drop target inside one never joins the drag
/// session. Instrumentation proved it — `onDrag` fired and produced a payload,
/// while `isTargeted` and the drop handler never ran once, on any of a Section,
/// a Section header, or a row, with both the `dropDestination` and `onDrop`
/// APIs. Plain views in a ScrollView receive drops without any of that.
/// Do not "tidy" this back into a List.
@available(iOS 16.0, *)
public struct RipulToolCollectionsScreen: View {
    @StateObject private var model: RipulToolCollectionsModel
    private let catalogs: [RipulToolCatalog]

    @State private var selectedCatalogId: String
    @State private var creating = false
    @State private var expanded: Set<String> = []
    @State private var editing: RipulToolCollection?
    @State private var showingOthers = false
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

    private var inScopeCollections: [RipulToolCollection] {
        model.categories.filter { memberCount($0, in: catalog) > 0 || isUnpopulated($0) }
    }

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

    // MARK: - Body

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                catalogCard
                if let errorMessage = model.errorMessage { noticeCard(errorMessage, isError: true) }
                if model.needsRestart {
                    noticeCard("Saved. Restart the app to apply — collections are read at launch.", isError: false)
                }

                if inScopeCollections.isEmpty && !model.isLoading {
                    Text("No collections group \(catalog.name) yet. Every one of these tools is passed to the agent individually.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                ForEach(inScopeCollections) { collection in
                    collectionCard(collection)
                }

                ungroupedCard
                otherCollectionsCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Tool Collections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.savingCount > 0 {
                    ProgressView()
                } else {
                    Button { creating = true } label: { Image(systemName: "plus") }
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
    }

    // MARK: - Cards

    private func card<Content: View>(
        highlighted: Bool = false,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(highlighted
                          ? Color.accentColor.opacity(0.22)
                          : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(highlighted ? Color.accentColor : .clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var catalogCard: some View {
        card {
            Text("ORGANISING").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if catalogs.count > 1 {
                Picker("Tool surface", selection: $selectedCatalogId) {
                    ForEach(catalogs) { entry in Text(entry.name).tag(entry.id) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("ripul.toolCollections.catalogPicker")
            } else {
                Text(catalog.name).font(.subheadline.weight(.semibold))
            }
            Text(catalog.purpose).font(.caption).foregroundStyle(.secondary)
            Text("\(catalog.tools.count) tool\(catalog.tools.count == 1 ? "" : "s") registered")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func noticeCard(_ message: String, isError: Bool) -> some View {
        card {
            Label(message, systemImage: isError ? "exclamationmark.triangle" : "arrow.clockwise.circle")
                .font(.footnote)
                .foregroundStyle(isError ? .red : .orange)
        }
    }

    /// A collection. The WHOLE card is the drop target — a plain view in a
    /// ScrollView, which is the only arrangement that reliably receives drops.
    private func collectionCard(_ collection: RipulToolCollection) -> some View {
        let m = matcher(for: collection)
        let isOpen = expanded.contains(collection.id)

        return card(highlighted: dropTarget == collection.id) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isOpen { expanded.remove(collection.id) } else { expanded.insert(collection.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(collection.displayLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if collection.isIsolate {
                                Text("isolate")
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                        }
                        Text(summary(matcher: m, collection: collection))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ripul.toolCollections.header")

            if isOpen {
                Divider()
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
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button { editing = collection } label: {
                    Label("Edit patterns, mode, label…", systemImage: "slider.horizontal.3")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .onDrop(of: dropTypes, isTargeted: targetBinding(for: collection.id)) { providers in
            acceptDrop(providers, into: collection.id)
        }
    }

    private enum MemberKind { case picked, pattern, elsewhere }

    /// Only `.picked` members drag: a `.pattern` member cannot be removed by
    /// editing `explicitTools` (the pattern re-captures it immediately), and an
    /// `.elsewhere` member is not registered in the catalog on screen.
    @ViewBuilder
    private func memberRow(_ name: String, in collection: RipulToolCollection, kind: MemberKind) -> some View {
        let row = HStack(spacing: 8) {
            Image(systemName: kind == .picked ? "line.3.horizontal" : "circle.dotted")
                .font(.caption2).foregroundStyle(.secondary)
            Text(name)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(kind == .picked ? .primary : .secondary)
            Spacer()
            switch kind {
            case .picked: EmptyView()
            case .pattern: Text("pattern").font(.caption2).foregroundStyle(.secondary)
            case .elsewhere: Text(originLabel(for: name)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())

        if kind == .picked {
            row.onDrag {
                RipulLog.log("[toolDrag] start tool=\(name) source=\(collection.id)")
                return NSItemProvider(
                    object: RipulToolDragItem(toolName: name, sourceCollectionId: collection.id)
                        .encoded as NSString
                )
            }
        } else {
            row
        }
    }

    private func originLabel(for name: String) -> String {
        switch RipulMemberAttribution.origin(of: name, viewing: catalog, allCatalogs: catalogs) {
        case .thisCatalog: return ""
        case .otherCatalog(let catalogName): return "in \(catalogName)"
        case .notNative: return "web app or other device"
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

    private var ungroupedCard: some View {
        let ungrouped = model.ungroupedTools(from: tools)
        return card(highlighted: dropTarget == ungroupedDropId) {
            HStack(spacing: 8) {
                Image(systemName: "tray").font(.caption).foregroundStyle(.secondary)
                Text("Ungrouped in \(catalog.name) (\(ungrouped.count))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text("Passed to that agent individually, costing tokens on every turn. Press and hold a tool, then drag it onto a collection.")
                .font(.caption2).foregroundStyle(.secondary)
            if !ungrouped.isEmpty { Divider() }
            ForEach(ungrouped) { tool in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal").font(.caption2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.system(.footnote, design: .monospaced))
                        if !tool.description.isEmpty {
                            Text(tool.description)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onDrag {
                    RipulLog.log("[toolDrag] start tool=\(tool.name) source=ungrouped")
                    return NSItemProvider(
                        object: RipulToolDragItem(toolName: tool.name, sourceCollectionId: nil)
                            .encoded as NSString
                    )
                }
            }
        }
        .onDrop(of: dropTypes, isTargeted: targetBinding(for: ungroupedDropId)) { providers in
            acceptDrop(providers, into: nil)
        }
    }

    private var ungroupedDropId: String { "__ungrouped__" }

    // MARK: - Out of scope

    @ViewBuilder
    private var otherCollectionsCard: some View {
        if !otherCollections.isEmpty {
            card {
                Button {
                    withAnimation { showingOthers.toggle() }
                } label: {
                    HStack {
                        Text("Not organising \(catalog.name) (\(otherCollections.count))")
                            .font(.footnote.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .rotationEffect(.degrees(showingOthers ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if showingOthers {
                    Divider()
                    ForEach(otherCollections) { collection in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(collection.displayLabel).font(.footnote)
                            Text(elsewhereReason(collection))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    Text("Collections holding none of this surface's tools — the app's other surface, or Ripul's own platform collections.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Drop handling

    /// Types accepted on drop. `NSItemProvider(object: NSString)` registers
    /// `public.utf8-plain-text`; `onDrop(of:)` has matched by exact identifier
    /// rather than conformance, so all three are listed.
    private var dropTypes: [UTType] { [.utf8PlainText, .plainText, .text] }

    private func targetBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { dropTarget == id },
            set: { isOver in
                if isOver {
                    if dropTarget != id { RipulLog.log("[toolDrag] hover \(id)") }
                    dropTarget = id
                } else if dropTarget == id {
                    dropTarget = nil
                }
            }
        )
    }

    /// Accept a dropped payload. Returns false for anything that isn't ours, so
    /// text dragged in from another app is refused rather than parsed into a
    /// nonsense edit.
    private func acceptDrop(_ providers: [NSItemProvider], into targetId: String?) -> Bool {
        let types = providers.flatMap(\.registeredTypeIdentifiers).joined(separator: ",")
        RipulLog.log("[toolDrag] drop into=\(targetId ?? "ungrouped") providers=\(providers.count) types=[\(types)]")

        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            RipulLog.error("[toolDrag] no provider can load NSString — refusing drop")
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, error in
            if let error {
                RipulLog.error("[toolDrag] loadObject failed: \(error.localizedDescription)")
                return
            }
            guard let raw = object as? String else {
                RipulLog.error("[toolDrag] loaded object was not a String")
                return
            }
            guard let item = RipulToolDragItem.decode(raw) else {
                RipulLog.error("[toolDrag] payload not ours: \(raw.prefix(120))")
                return
            }
            RipulLog.log("[toolDrag] decoded tool=\(item.toolName) source=\(item.sourceCollectionId ?? "ungrouped")")
            Task { @MainActor in
                dropTarget = nil
                await model.move(item, to: targetId)
                RipulLog.log("[toolDrag] move done tool=\(item.toolName) -> \(targetId ?? "ungrouped") error=\(model.errorMessage ?? "none")")
                if let targetId {
                    withAnimation { _ = expanded.insert(targetId) }
                }
            }
        }
        return true
    }
}
#endif
