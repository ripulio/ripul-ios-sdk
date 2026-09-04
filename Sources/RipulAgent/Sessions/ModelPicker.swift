import SwiftUI

// MARK: - Purpose

/// What picking a model in this list will DO.
///
/// The only thing this changes is row *availability* and the "why not" line —
/// the sections, the pins and the ordering are identical either way, which is
/// the point: one picker, whatever you are picking for.
public enum ModelPickerPurpose {
    /// Switch an existing target — the global override, or one chat's model.
    /// Every row is tappable: pointing a chat at a CLI model is meaningful even
    /// when no machine happens to be online this second.
    case select
    /// Start a NEW session with the picked model. CLI and axis-2 subscription
    /// rows need a host to launch on, so they're disabled — and say so — when
    /// `machine` is nil.
    case launch(machine: RemoteMachine?)
}

// MARK: - Effort

/// Reasoning effort, which is orthogonal to the model but lives in the same
/// decision. Surfaces that can't set it pass nil and the section is omitted.
public struct ModelPickerEffort {
    public static let levels = ["low", "medium", "high", "xhigh", "max"]

    public let current: String?
    public let onChange: (String?) -> Void

    public init(current: String?, onChange: @escaping (String?) -> Void) {
        self.current = current
        self.onChange = onChange
    }

    /// "XHigh", not "Xhigh" — `capitalized` gets that one wrong.
    public static func label(_ level: String) -> String {
        level == "xhigh" ? "XHigh" : level.capitalized
    }
}

// MARK: - Model Picker List

/// **The** model picker. Every surface that asks "which model?" renders this.
///
/// Before this existed there were six of them — a grouped sheet with search, two
/// nested `Menu` trees in the chat context menu, a hardcoded "Anthropic API only"
/// button list in two more menus, a plain `Picker` in the plan run sheet, and the
/// quick-launch popover. They disagreed about which models were offered, how they
/// were grouped, what a row said, and whether you could pin anything. This is the
/// quick-launch popover's design — sections plus pins — generalised to serve all
/// of them.
///
/// ## Sections
///
/// **Pinned** first, then one section per CLI harness (in `providers.json`
/// order), then "Your Claude subscription", then the remaining catalog groups
/// with the platform-API group ahead of the rest. Section titles name the
/// harness rather than the raw `group` field because that is the axis a CLI
/// model is actually chosen along, and footers carry the billing sentence —
/// which sign-in pays, and whether a machine is needed.
///
/// ## Pins
///
/// There is exactly ONE pin list, `QuickLaunchPreferences.selectedIds`, shared
/// with the quick-launch strip. Pinning a model here puts it at the top of every
/// picker *and* gives it a circle on the strip; that identity is the feature, not
/// a side effect. The order is the strip's order, left to right, so the Pinned
/// section is reorderable.
///
/// `cache` is optional because pins are host-namespaced storage and not every
/// caller owns a cache. Without one the picker still works — it just has no
/// Pinned section and no pin buttons, rather than silently writing pins into the
/// wrong suite.
///
/// ## Rows
///
/// The subtitle is metadata — who pays · price · effort · thinking — not the
/// catalog `description`. Two rows can render the same model name ("Opus 4.8"
/// via Claude Code, "Opus 4.8" via the API) and the thing that distinguishes
/// them is billing, so that is what the line says. Descriptions are still
/// searchable.
///
/// Hosted in whatever the caller provides. `ModelPickerSheetContent` is the
/// batteries-included version (navigation container, title, search, Done).
public struct ModelPickerSections: View {
    let models: [ModelInfo]
    /// Catalog the pin list is seeded from when the user has never pinned
    /// anything. Defaults to `models`, and MUST be overridden by any caller
    /// showing a subset — the raw-CLI picker lists one harness's models, and
    /// seeding the (global) pin list from those would silently drop every other
    /// harness's shortcut the first time you pinned something there.
    let pinCatalog: [ModelInfo]
    let cache: RipulSessionCache?
    let purpose: ModelPickerPurpose
    let selectedId: String?
    let showsDefaultRow: Bool
    let showsDisabled: Bool
    let effort: ModelPickerEffort?
    let searchText: String
    let identifierPrefix: String
    let isLoading: Bool
    let loadFailure: String?
    @Binding var loadingId: String?
    let onRetry: (() -> Void)?
    let onEdit: ((ModelInfo) -> Void)?
    let onDelete: ((ModelInfo) -> Void)?
    /// Called with the picked model, or nil for the "Default" row.
    ///
    /// **Optional**: when it is nil the picker isn't choosing anything, it is
    /// *curating* — a row tap toggles that model's pin instead. That is what the
    /// Quick Start settings screen wants, and it means the rows never look
    /// tappable while doing nothing.
    let onPick: ((ModelInfo?) -> Void)?

    /// Local mirror of the persisted pin order. The cache is the source of
    /// truth; this exists so a pin toggle repaints the open list immediately
    /// rather than waiting on a notification round-trip.
    @State private var pinnedIds: [String] = []

    public init(
        models: [ModelInfo],
        pinCatalog: [ModelInfo]? = nil,
        cache: RipulSessionCache?,
        purpose: ModelPickerPurpose = .select,
        selectedId: String? = nil,
        showsDefaultRow: Bool = false,
        showsDisabled: Bool = false,
        effort: ModelPickerEffort? = nil,
        searchText: String = "",
        identifierPrefix: String,
        isLoading: Bool = false,
        loadFailure: String? = nil,
        loadingId: Binding<String?> = .constant(nil),
        onRetry: (() -> Void)? = nil,
        onEdit: ((ModelInfo) -> Void)? = nil,
        onDelete: ((ModelInfo) -> Void)? = nil,
        onPick: ((ModelInfo?) -> Void)? = nil
    ) {
        self.models = models
        self.pinCatalog = pinCatalog ?? models
        self.cache = cache
        self.purpose = purpose
        self.selectedId = selectedId
        self.showsDefaultRow = showsDefaultRow
        self.showsDisabled = showsDisabled
        self.effort = effort
        self.searchText = searchText
        self.identifierPrefix = identifierPrefix
        self.isLoading = isLoading
        self.loadFailure = loadFailure
        self._loadingId = loadingId
        self.onRetry = onRetry
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onPick = onPick
    }

    // MARK: Data

    private var offered: [ModelInfo] {
        showsDisabled ? models : models.filter(\.enabled)
    }

    private var searching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var matches: [ModelInfo] {
        guard searching else { return offered }
        let query = searchText.lowercased()
        return offered.filter {
            $0.name.lowercased().contains(query)
                || $0.modelId.lowercased().contains(query)
                || $0.id.lowercased().contains(query)
                || $0.provider.lowercased().contains(query)
                || $0.group.lowercased().contains(query)
                || ($0.description?.lowercased().contains(query) ?? false)
        }
    }

    /// Pinned rows in strip order. Ids that don't resolve to a catalog model are
    /// skipped, not dropped — the catalog may still be loading, and a pin must
    /// not evaporate because of it. `movePinned` writes the unresolved ones back.
    private var pinnedModels: [ModelInfo] {
        guard cache != nil else { return [] }
        return pinnedIds.compactMap { id in offered.first { $0.id == id } }
    }

    /// Everything not in the Pinned section. Pinned models are lifted out rather
    /// than listed twice — the pin is a property of the model, so two copies
    /// would raise the question of which one is real.
    private var unpinned: [ModelInfo] {
        matches.filter { !pinnedIds.contains($0.id) }
    }

    // MARK: Body

    /// Sections only, so a host `List` can put its own rows above and below
    /// them (the Quick Start settings screen does exactly that). `ModelPickerList`
    /// is the same thing with the `List` supplied.
    public var body: some View {
        Group {
            if offered.isEmpty {
                Section { statusRow }
            } else {
                // Effort and Default are answers to "how should this run", not
                // "which model" — searching is a model question, so they get out
                // of the way while a query is active.
                if !searching {
                    if let effort {
                        Section("Reasoning effort") { effortRow(effort) }
                    }
                    if showsDefaultRow {
                        Section { defaultRow }
                    }
                }

                if searching {
                    Section(matches.isEmpty ? "No matches" : "Results") {
                        ForEach(matches) { row(for: $0) }
                    }
                } else {
                    if !pinnedModels.isEmpty {
                        Section {
                            ForEach(pinnedModels) { row(for: $0) }
                                .onMove(perform: movePinned)
                        } header: {
                            Text("Pinned")
                        } footer: {
                            Text("Also the quick-start circles, in this order, left to right. Drag to reorder; tap the pin to remove.")
                        }
                    }
                    ForEach(sections(for: unpinned)) { section in
                        Section {
                            ForEach(section.models) { row(for: $0) }
                        } header: {
                            Text(section.title)
                        } footer: {
                            if let footer = section.footer { Text(footer) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: reloadPins)
        .onReceive(NotificationCenter.default.publisher(for: QuickLaunchPreferences.didChangeNotification)) { _ in
            reloadPins()
        }
    }

    /// Loading / failed / empty, as a row rather than a centred splash — this
    /// has to sit inside someone else's `List`, and a full-bleed placeholder
    /// can't.
    @ViewBuilder
    private var statusRow: some View {
        if let loadFailure {
            VStack(alignment: .leading, spacing: 8) {
                Label("Failed to load models", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.medium))
                    .uiKitIdentifier("\(identifierPrefix).error.title")
                Text(loadFailure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .uiKitIdentifier("\(identifierPrefix).error.message")
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                        .uiKitIdentifier("\(identifierPrefix).retryButton")
                }
            }
            .padding(.vertical, 4)
        } else if isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                    .uiKitIdentifier("\(identifierPrefix).loading.spinner")
                Text("Loading models…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .uiKitIdentifier("\(identifierPrefix).loading.label")
            }
        } else {
            Text("No models available yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .uiKitIdentifier("\(identifierPrefix).empty.label")
        }
    }

    // MARK: Sections

    private struct PickerSection: Identifiable {
        let id: String
        let title: String
        let footer: String?
        let models: [ModelInfo]
    }

    /// Harness sections first (in `providers.json` order), then the axis-2
    /// subscription models, then the catalog's own groups with the platform-API
    /// group ahead of the rest. Deliberately not alphabetical: the order runs
    /// from "your sign-in pays" to "Ripul's credits pay".
    private func sections(for models: [ModelInfo]) -> [PickerSection] {
        var cliBuckets: [String: [ModelInfo]] = [:]
        var subscription: [ModelInfo] = []
        var groups: [String: [ModelInfo]] = [:]

        for model in models {
            if let key = QuickLaunchTarget.resolve(model: model).providerKey {
                cliBuckets[key, default: []].append(model)
            } else if model.isSubscription {
                subscription.append(model)
            } else {
                let group = model.group.isEmpty ? "Other" : model.group
                groups[group, default: []].append(model)
            }
        }

        var out: [PickerSection] = []

        for provider in ProviderConstants.cliProviders {
            guard let key = provider.providerKey,
                  let bucket = cliBuckets[key], !bucket.isEmpty else { continue }
            out.append(PickerSection(
                id: "cli:\(key)",
                title: provider.displayLabel,
                footer: "Runs through the \(provider.displayLabel) harness you signed in on that machine — spends that account's allowance, not Ripul's API credits. Needs a machine.",
                models: sortedForDisplay(bucket)
            ))
        }

        if !subscription.isEmpty {
            out.append(PickerSection(
                id: "subscription",
                title: "Your Claude subscription",
                footer: "Runs on the host via the Messages API using its own signed-in Claude subscription — spends your plan's allowance, not Ripul's API credits. Needs a machine.",
                models: sortedForDisplay(subscription)
            ))
        }

        let groupKeys = groups.keys.sorted { lhs, rhs in
            if lhs == QuickLaunchPreferences.apiGroup { return true }
            if rhs == QuickLaunchPreferences.apiGroup { return false }
            return lhs < rhs
        }
        for key in groupKeys {
            guard let bucket = groups[key], !bucket.isEmpty else { continue }
            out.append(PickerSection(
                id: "group:\(key)",
                title: key,
                footer: "Streams through the LLM proxy on Ripul's platform API key. Starts without a machine, but still uses your paired or default machine for repo tools.",
                models: sortedForDisplay(bucket)
            ))
        }

        return out
    }

    /// Catalog order (`sortOrder`) is curated, so honour it and fall back to the
    /// name only where it's absent.
    private func sortedForDisplay(_ models: [ModelInfo]) -> [ModelInfo] {
        models.sorted { lhs, rhs in
            let l = lhs.sortOrder ?? Int.max
            let r = rhs.sortOrder ?? Int.max
            if l != r { return l < r }
            return lhs.name < rhs.name
        }
    }

    // MARK: Rows

    private var defaultRow: some View {
        Button {
            onPick?(nil)
        } label: {
            HStack {
                Text("Default")
                    .foregroundStyle(.primary)
                    .uiKitIdentifier("\(identifierPrefix).defaultModelRow.label")
                Spacer()
                if selectedId == nil {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .uiKitIdentifier("\(identifierPrefix).defaultModelRow.checkmark")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uiKitIdentifier("\(identifierPrefix).defaultModelRow")
    }

    private func effortRow(_ effort: ModelPickerEffort) -> some View {
        Menu {
            Button("Default") { effort.onChange(nil) }
            ForEach(ModelPickerEffort.levels, id: \.self) { level in
                Button(ModelPickerEffort.label(level)) { effort.onChange(level) }
            }
        } label: {
            HStack {
                Text("Effort").foregroundStyle(.primary)
                Spacer()
                Text(effort.current.map(ModelPickerEffort.label) ?? "Default")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .uiKitIdentifier("\(identifierPrefix).effortMenu")
    }

    @ViewBuilder
    private func row(for model: ModelInfo) -> some View {
        let target = QuickLaunchTarget.resolve(model: model)
        let available = isAvailable(target)
        HStack(spacing: 10) {
            Button {
                guard available else { return }
                // Curating rather than choosing: with no `onPick`, the row IS
                // the pin control.
                guard let onPick else { return togglePin(model) }
                onPick(model)
            } label: {
                HStack(spacing: 10) {
                    glyph(for: target)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(.body)
                            .foregroundStyle(available ? .primary : .secondary)
                            .uiKitIdentifier("\(identifierPrefix).modelRow.\(model.id).name")
                        Text(subtitle(for: target, available: available))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .uiKitIdentifier("\(identifierPrefix).modelRow.\(model.id).subtitle")
                    }
                    Spacer(minLength: 0)
                    if selectedId == model.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .uiKitIdentifier("\(identifierPrefix).modelRow.\(model.id).checkmark")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!available)
            .uiKitIdentifier("\(identifierPrefix).modelRow.\(model.id)")

            if cache != nil {
                pinButton(for: model)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onDelete, model.isCli {
                Button(role: .destructive) { onDelete(model) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if let onEdit, model.isCli {
                Button { onEdit(model) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
    }

    @ViewBuilder
    private func glyph(for target: QuickLaunchTarget) -> some View {
        if loadingId == target.id {
            ProgressView().controlSize(.small)
        } else if let identity = target.identity {
            Text(identity.glyph)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(identity.color)
        } else {
            Image(systemName: target.providerSymbol ?? "message.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(target.color)
        }
    }

    /// Pinning is availability-independent — a CLI model you can't launch right
    /// now is still one you may want on the strip for when that machine is back.
    private func pinButton(for model: ModelInfo) -> some View {
        let pinned = pinnedIds.contains(model.id)
        return Button {
            togglePin(model)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pinned ? "Unpin from shortcuts" : "Pin to shortcuts")
        .uiKitIdentifier("\(identifierPrefix).pinButton.\(model.id)")
    }

    // MARK: Labels

    /// The load-bearing line: **who pays**, never where it runs.
    ///
    /// Deliberately avoids two tempting-but-wrong words. Not "your machine" — an
    /// API chat uses the host machine too for repo tools, so that names the
    /// wrong axis. Not "your subscription" — a Kimi model carried by the Claude
    /// CLI bills a Kimi API key, not a Claude plan. "Your <harness> sign-in" is
    /// true for every CLI row regardless of which account backs it.
    private func billingLabel(for target: QuickLaunchTarget) -> String {
        if target.model.isSubscription { return "Your Claude subscription" }
        guard let key = target.providerKey else { return "Ripul platform credits" }
        return "Your \(ProviderConstants.legacyLabel(for: key)) sign-in"
    }

    private func subtitle(for target: QuickLaunchTarget, available: Bool) -> String {
        if !available {
            return "\(billingLabel(for: target)) · needs a machine"
        }
        var parts = [billingLabel(for: target)]
        // Concrete price makes the billing split legible: the pair of rows that
        // render the same glyph differ as "$10/$50 per MTok" vs nothing (a CLI
        // row's 0/0 means the sign-in's allowance carries it, so no price line).
        if !target.isCli, let price = priceLabel(for: target.model) {
            parts.append(price)
        }
        if let effort = target.model.cliEffort, !effort.isEmpty {
            parts.append(effort)
        }
        if target.model.supportsThinking {
            parts.append("thinking")
        }
        if !target.model.enabled {
            parts.append("disabled")
        }
        return parts.joined(separator: " · ")
    }

    /// "$10/$50 per MTok" — nil when pricing is absent or zero/zero.
    private func priceLabel(for model: ModelInfo) -> String? {
        let input = model.perMInput ?? 0
        let output = model.perMOutput ?? 0
        guard input > 0 || output > 0 else { return nil }
        return "\(formatPrice(input))/\(formatPrice(output)) per MTok"
    }

    private func formatPrice(_ value: Double) -> String {
        value == value.rounded() ? "$\(Int(value))" : String(format: "$%.2f", value)
    }

    // MARK: Availability

    private func isAvailable(_ target: QuickLaunchTarget) -> Bool {
        switch purpose {
        case .select:
            // Switching to a model that needs a machine is legitimate — the
            // machine only has to be there when the turn runs.
            return true
        case .launch(let machine):
            return target.requiresMachine ? machine != nil : true
        }
    }

    // MARK: Pins

    /// Idempotent: the body renders several sections and each carries the
    /// `onAppear`/`onReceive` that calls this, so it must not invalidate state
    /// it didn't change.
    private func reloadPins() {
        guard let cache else { return }
        let stored = QuickLaunchPreferences.selectedIds(models: pinCatalog, cache: cache)
        if stored != pinnedIds { pinnedIds = stored }
    }

    private func togglePin(_ model: ModelInfo) {
        guard let cache else { return }
        var ids = pinnedIds
        if let idx = ids.firstIndex(of: model.id) {
            ids.remove(at: idx)
        } else {
            // New pins land last, so pinning never silently rearranges an order
            // the user has already dragged into place.
            ids.append(model.id)
        }
        pinnedIds = ids
        QuickLaunchPreferences.setSelectedIds(ids, cache: cache)
    }

    /// Reorder the pinned section. The stored array IS the strip, left to right,
    /// so this write is what moves the circles.
    private func movePinned(from source: IndexSet, to destination: Int) {
        guard let cache else { return }
        var ids = pinnedModels.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        // Re-append any pinned ids the catalog couldn't resolve. They aren't in
        // the visible list so they can't be positioned meaningfully — but
        // writing back only what was visible would delete the user's pin for any
        // model whose catalog entry simply hadn't loaded yet.
        let visible = Set(ids)
        pinnedIds = ids + pinnedIds.filter { !visible.contains($0) }
        QuickLaunchPreferences.setSelectedIds(pinnedIds, cache: cache)
    }
}

// MARK: - Standalone List

/// `ModelPickerSections` with the `List` supplied — the form every caller wants
/// unless it is splicing the sections into a list of its own.
public struct ModelPickerList: View {
    let models: [ModelInfo]
    /// See `ModelPickerSections.pinCatalog` — override when `models` is a subset.
    let pinCatalog: [ModelInfo]
    let cache: RipulSessionCache?
    let purpose: ModelPickerPurpose
    let selectedId: String?
    let showsDefaultRow: Bool
    let showsDisabled: Bool
    let effort: ModelPickerEffort?
    let searchText: String
    let identifierPrefix: String
    let isLoading: Bool
    let loadFailure: String?
    @Binding var loadingId: String?
    let onRetry: (() -> Void)?
    let onEdit: ((ModelInfo) -> Void)?
    let onDelete: ((ModelInfo) -> Void)?
    let onPick: ((ModelInfo?) -> Void)?

    public init(
        models: [ModelInfo],
        pinCatalog: [ModelInfo]? = nil,
        cache: RipulSessionCache?,
        purpose: ModelPickerPurpose = .select,
        selectedId: String? = nil,
        showsDefaultRow: Bool = false,
        showsDisabled: Bool = false,
        effort: ModelPickerEffort? = nil,
        searchText: String = "",
        identifierPrefix: String,
        isLoading: Bool = false,
        loadFailure: String? = nil,
        loadingId: Binding<String?> = .constant(nil),
        onRetry: (() -> Void)? = nil,
        onEdit: ((ModelInfo) -> Void)? = nil,
        onDelete: ((ModelInfo) -> Void)? = nil,
        onPick: ((ModelInfo?) -> Void)? = nil
    ) {
        self.models = models
        self.pinCatalog = pinCatalog ?? models
        self.cache = cache
        self.purpose = purpose
        self.selectedId = selectedId
        self.showsDefaultRow = showsDefaultRow
        self.showsDisabled = showsDisabled
        self.effort = effort
        self.searchText = searchText
        self.identifierPrefix = identifierPrefix
        self.isLoading = isLoading
        self.loadFailure = loadFailure
        self._loadingId = loadingId
        self.onRetry = onRetry
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onPick = onPick
    }

    public var body: some View {
        List {
            ModelPickerSections(
                models: models,
                pinCatalog: pinCatalog,
                cache: cache,
                purpose: purpose,
                selectedId: selectedId,
                showsDefaultRow: showsDefaultRow,
                showsDisabled: showsDisabled,
                effort: effort,
                searchText: searchText,
                identifierPrefix: identifierPrefix,
                isLoading: isLoading,
                loadFailure: loadFailure,
                loadingId: $loadingId,
                onRetry: onRetry,
                onEdit: onEdit,
                onDelete: onDelete,
                onPick: onPick
            )
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }
}

// MARK: - Sheet Content

/// `ModelPickerList` in the chrome a sheet or popover needs: navigation
/// container, title, search field, Done, and the Edit button that makes the
/// Pinned section's drag-to-reorder discoverable.
///
/// Presented as a sheet on iPhone and a popover on Mac; both get the same body,
/// which is why the search lives here rather than at each call site.
public struct ModelPickerSheetContent: View {
    let title: String
    let models: [ModelInfo]
    /// See `ModelPickerSections.pinCatalog` — override when `models` is a subset.
    let pinCatalog: [ModelInfo]
    let cache: RipulSessionCache?
    let purpose: ModelPickerPurpose
    let selectedId: String?
    let showsDefaultRow: Bool
    let showsDisabled: Bool
    let effort: ModelPickerEffort?
    let identifierPrefix: String
    let isLoading: Bool
    let loadFailure: String?
    @Binding var loadingId: String?
    let onRetry: (() -> Void)?
    let onCreate: (() -> Void)?
    let onEdit: ((ModelInfo) -> Void)?
    let onDelete: ((ModelInfo) -> Void)?
    let onPick: (ModelInfo?) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    public init(
        title: String = "Model",
        models: [ModelInfo],
        pinCatalog: [ModelInfo]? = nil,
        cache: RipulSessionCache?,
        purpose: ModelPickerPurpose = .select,
        selectedId: String? = nil,
        showsDefaultRow: Bool = false,
        showsDisabled: Bool = false,
        effort: ModelPickerEffort? = nil,
        identifierPrefix: String,
        isLoading: Bool = false,
        loadFailure: String? = nil,
        loadingId: Binding<String?> = .constant(nil),
        onRetry: (() -> Void)? = nil,
        onCreate: (() -> Void)? = nil,
        onEdit: ((ModelInfo) -> Void)? = nil,
        onDelete: ((ModelInfo) -> Void)? = nil,
        onPick: @escaping (ModelInfo?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.models = models
        self.pinCatalog = pinCatalog ?? models
        self.cache = cache
        self.purpose = purpose
        self.selectedId = selectedId
        self.showsDefaultRow = showsDefaultRow
        self.showsDisabled = showsDisabled
        self.effort = effort
        self.identifierPrefix = identifierPrefix
        self.isLoading = isLoading
        self.loadFailure = loadFailure
        self._loadingId = loadingId
        self.onRetry = onRetry
        self.onCreate = onCreate
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onPick = onPick
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            ModelPickerList(
                models: models,
                pinCatalog: pinCatalog,
                cache: cache,
                purpose: purpose,
                selectedId: selectedId,
                showsDefaultRow: showsDefaultRow,
                showsDisabled: showsDisabled,
                effort: effort,
                searchText: searchText,
                identifierPrefix: identifierPrefix,
                isLoading: isLoading,
                loadFailure: loadFailure,
                loadingId: $loadingId,
                onRetry: onRetry,
                onEdit: onEdit,
                onDelete: onDelete,
                onPick: onPick
            )
            .searchable(
                text: $searchText,
                placement: searchPlacement,
                prompt: "Search models"
            )
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                        .uiKitIdentifier("\(identifierPrefix).doneButton")
                }
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        // Long-press-drag reorders the pinned section without
                        // it, but only once you know to try; the explicit
                        // affordance is what makes that discoverable. Pointless
                        // without a pin store, so it follows the cache.
                        if cache != nil { EditButton() }
                        if let onCreate {
                            Button(action: onCreate) { Image(systemName: "plus") }
                                .uiKitIdentifier("\(identifierPrefix).addModelButton")
                        }
                    }
                }
                #else
                if let onCreate {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: onCreate) { Image(systemName: "plus") }
                            .uiKitIdentifier("\(identifierPrefix).addModelButton")
                    }
                }
                #endif
            }
        }
    }

    private var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .automatic
        #endif
    }
}

// MARK: - Push Destination

/// `ModelPickerList` as a **pushed** destination, for callers already inside a
/// navigation container — a form row that drills into the picker rather than
/// presenting a second sheet over the one it's already in.
///
/// Same list, same search, same pins; it just pops itself once a model is
/// chosen instead of calling a dismiss closure.
public struct ModelPickerPushList: View {
    let title: String
    let models: [ModelInfo]
    /// See `ModelPickerSections.pinCatalog` — override when `models` is a subset.
    let pinCatalog: [ModelInfo]
    let cache: RipulSessionCache?
    let purpose: ModelPickerPurpose
    let selectedId: String?
    let identifierPrefix: String
    let onPick: (ModelInfo) -> Void

    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    public init(
        title: String = "Model",
        models: [ModelInfo],
        pinCatalog: [ModelInfo]? = nil,
        cache: RipulSessionCache?,
        purpose: ModelPickerPurpose = .select,
        selectedId: String? = nil,
        identifierPrefix: String,
        onPick: @escaping (ModelInfo) -> Void
    ) {
        self.title = title
        self.models = models
        self.pinCatalog = pinCatalog ?? models
        self.cache = cache
        self.purpose = purpose
        self.selectedId = selectedId
        self.identifierPrefix = identifierPrefix
        self.onPick = onPick
    }

    public var body: some View {
        ModelPickerList(
            models: models,
            pinCatalog: pinCatalog,
            cache: cache,
            purpose: purpose,
            selectedId: selectedId,
            searchText: searchText,
            identifierPrefix: identifierPrefix,
            onPick: { model in
                guard let model else { return }
                onPick(model)
                dismiss()
            }
        )
        .searchable(text: $searchText, prompt: "Search models")
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        #endif
    }
}
