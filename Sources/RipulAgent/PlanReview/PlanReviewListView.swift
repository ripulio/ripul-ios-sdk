import SwiftUI

/// Plans in the chat's working directory.
///
/// The sort is most-recently-active first (computed web-side from the plan's
/// log), so the list answers "what was I doing?" by order; the row's subtitle
/// still answers "does this need me?" — blocking counts stay orange. Plans
/// nothing has happened to yet sink to the bottom.
@available(iOS 17.0, macOS 14.0, *)
public struct PlanReviewListView: View {
    /// Injected rather than owned, so a host that needs to drive creation from
    /// its own chrome (PlansScreen's glass top bar hides the nav bar, so the
    /// toolbar "+" below is invisible there) can hold the same store.
    /// `PlanReviewScreen` is the batteries-included wrapper.
    @ObservedObject var store: PlanReviewStore
    @Binding var showingCreate: Bool
    /// Passed through to the detail screen — see
    /// `PlanReviewDetailView.planSessions` / `.planLinkPicker`.
    let planSessions: ((String, PlanDetail, Binding<Bool>) -> AnyView)?
    let planLinkPicker: ((String) -> AnyView)?
    /// Fired when a plan detail is pushed (true) or popped (false). The iPhone
    /// host uses it to let the detail go full-bleed over the shared top bar.
    let onDetailActive: ((Bool) -> Void)?
    /// Pin storage for the run sheet's model picker, passed through to the
    /// detail. Host-namespaced — nil just means the picker has no Pinned
    /// section. See `ModelPickerList`.
    let cache: RipulSessionCache?
    /// Plans with a run in flight (by planKey), computed by the host from the
    /// unified session list plus the PlanRunActivity overlay. A running plan's
    /// row shows a live spinner instead of its static lifecycle stage — the
    /// list must not say "draft me" about a plan an agent is drafting.
    let runningPlanKeys: Set<String>
    @State private var query = ""
    /// Folder starts collapsed, its choice as the subtitle — the Machines
    /// panel's pattern. Plans starts open: it is the screen.
    @State private var folderExpanded = false
    @State private var plansExpanded = true
    /// Non-nil while "create & draft" is presenting the run sheet for the plan
    /// that was just created. `sheet(item:)` needs Identifiable.
    @State private var draftTarget: DraftTarget?
    /// Slug awaiting the create sheet's dismissal before its draft run sheet
    /// presents (see the create sheet's onDismiss).
    @State private var pendingDraftSlug: String?
    /// The plan a delete confirmation is showing for.
    @State private var deleteTarget: PlanListEntry?
    /// Batch selection, mirroring the agents screen.
    @State private var isSelecting = false
    @State private var selectedSlugs: Set<String> = []
    @State private var showBatchDeleteConfirm = false
    @State private var batchBusy = false
    /// Detail navigation. The rows used to be `NavigationLink`s; the shared
    /// list dispatches a tap instead, so the push is driven from here.
    ///
    /// Carries the ENTRY, not the slug: the same slug can exist in two projects
    /// and the detail has to open the one that was tapped.
    @State private var pushedPlan: PlanListEntry?
    /// Project view filter — ephemeral, and it never writes the work scope.
    /// Selecting a project changes what you SEE; the scope still decides where
    /// new work goes. Keeping those separate is the whole point of the split.
    @State private var projectFilter: String?

    private struct DraftTarget: Identifiable {
        let slug: String
        var id: String { slug }
    }

    public init(
        store: PlanReviewStore,
        showingCreate: Binding<Bool>,
        planSessions: ((String, PlanDetail, Binding<Bool>) -> AnyView)? = nil,
        planLinkPicker: ((String) -> AnyView)? = nil,
        onDetailActive: ((Bool) -> Void)? = nil,
        cache: RipulSessionCache? = nil,
        runningPlanKeys: Set<String> = []
    ) {
        self.store = store
        self._showingCreate = showingCreate
        self.planSessions = planSessions
        self.planLinkPicker = planLinkPicker
        self.onDetailActive = onDetailActive
        self.cache = cache
        self.runningPlanKeys = runningPlanKeys
    }

    /// Distinct projects across the loaded plans, for the filter menu.
    private var availableProjects: [String] {
        let names = store.plans.compactMap(\.projectName)
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Guards a selection that dropped out of the list, mirroring Sessions.
    private var activeProjectFilter: String? {
        guard let p = projectFilter, availableProjects.contains(p) else { return nil }
        return p
    }

    private var filtered: [PlanListEntry] {
        var base = store.plans
        if let project = activeProjectFilter {
            base = base.filter { $0.projectName == project }
        }
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.slug.localizedCaseInsensitiveContains(query)
        }
    }

    /// Project filter, as the same inline Picker the agents screen uses.
    @ViewBuilder
    private var projectFilterMenu: some View {
        if availableProjects.count > 1 {
            Menu {
                Picker("Filter by Project", selection: Binding(
                    get: { activeProjectFilter },
                    set: { projectFilter = $0 }
                )) {
                    Text("All Projects").tag(String?.none)
                    ForEach(availableProjects, id: \.self) { project in
                        Text(project).tag(String?.some(project))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.caption2.weight(.bold))
                    Text(activeProjectFilter ?? "All Projects")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(activeProjectFilter != nil ? Color.accentColor : Color.secondary)
            }
            .uiKitIdentifier("PlanReviewListView.projectFilterMenu")
        }
    }

    /// Deliberately does NOT own a NavigationStack. It is pushed as a link
    /// destination from the commands sheet and presented inside a stack from
    /// AgentView; owning one here would nest stacks in the first case and break
    /// the push to the detail screen.
    // Panels are separate computed properties, not inline in `body`.
    // Inlined, the whole stack became one expression the Swift type-checker
    // could not solve in reasonable time once the plans panel grew a filter
    // menu, a select button and a configured list.
    @ViewBuilder
    private var scopePanel: some View {
        GlassSectionPanel(
            title: WorkScopeState.title,
            subtitle: folderSubtitle,
            isExpanded: $folderExpanded
        ) {
            workDirRow
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .uiKitIdentifier("PlanReviewListView.folderPanel")
    }

    @ViewBuilder
    private var plansPanel: some View {
        GlassSectionPanel(
            title: "Plans",
            subtitle: "\(store.plans.count)",
            isExpanded: $plansExpanded,
            trailing: {
                HStack(spacing: 8) {
                    projectFilterMenu
                    GlassSearchField("Find a plan", text: $query)
                        .frame(maxWidth: 110)
                    GlassSelectButton(isSelecting: isSelecting) {
                        isSelecting.toggle()
                        selectedSlugs.removeAll()
                    }
                    .uiKitIdentifier("PlanReviewListView.selectButton")
                    .opacity(store.plans.isEmpty ? 0 : 1)
                    .disabled(store.plans.isEmpty)
                }
            }
        ) {
            // The same list the agents screen uses — real rows, real
            // gestures, and one typed empty state per situation rather
            // than a single ContentUnavailableView gated on
            // `plans.isEmpty` (which left a search that excluded
            // everything rendering a blank panel).
            GlassRichList(
                items: filtered,
                emptyState: emptyState,
                identifierPrefix: "PlanReviewListView.plans",
                // This screen is a ScrollView, so a `List` would have
                // no height to fill and would render nothing at all.
                // Plans has no swipe, which is the only thing `List`
                // would have bought it.
                layout: .stack,
                activity: { entry in isRunning(entry) ? .opening : .idle },
                isSelecting: isSelecting,
                selectedIds: selectedSlugs,
                onTap: { entry in pushedPlan = entry },
                onToggleSelect: { entry in
                    // Keyed on the composite id — two projects can hold
                    // the same slug, and selecting one must not select both.
                    if selectedSlugs.contains(entry.id) {
                        selectedSlugs.remove(entry.id)
                    } else {
                        selectedSlugs.insert(entry.id)
                    }
                },
                // No onRefresh: the screen's own ScrollView already
                // carries `.refreshable`, and a second one inside it
                // would be unreachable.
                row: { entry in
                    HStack(spacing: 8) {
                        row(entry)
                        Spacer(minLength: 0)
                        if !isSelecting {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                },
                // No swipe: Plans' only bulk verb is Delete, which
                // removes three git-tracked files. Sessions' swipe is
                // Archive — reversible, and a different risk class.
                swipe: { _ in EmptyView() },
                rowMenu: { entry in
                    Button(role: .destructive) {
                        deleteTarget = entry
                    } label: {
                        Label("Delete plan", systemImage: "trash")
                    }
                }
            )
        }
        .uiKitIdentifier("PlanReviewListView.plansPanel")
    }

    public var body: some View {
        // The same disclosure panels the agents screen wraps Sessions /
        // Folders / Machines in — shared look and feel, not a lookalike.
        // The Folder panel starts collapsed with its choice as the subtitle
        // (the Machines pattern); Plans starts open with the house search
        // field in its header.
        ScrollView {
            VStack(spacing: 12) {
                scopePanel
                plansPanel
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        // The rows are no longer NavigationLinks (the shared list dispatches a
        // tap), so the push is driven from `pushedSlug`.
        .navigationDestination(item: $pushedPlan) { entry in
            PlanReviewDetailView(
                slug: entry.slug,
                root: entry.root,
                store: store,
                planSessions: planSessions,
                planLinkPicker: planLinkPicker,
                cache: cache
            )
            .onAppear { onDetailActive?(true) }
            .onDisappear { onDetailActive?(false) }
        }
        // Floating batch bar, the same chrome the agents screen uses. Delete
        // is the only verb — Plans has no archive concept to pair with it.
        .overlay(alignment: .bottom) {
            if isSelecting && !selectedSlugs.isEmpty {
                GlassBatchBar(
                    actions: [
                        GlassBatchAction(
                            id: "delete",
                            title: batchBusy
                                ? "Deleting…"
                                : "Delete (\(selectedSlugs.count))",
                            systemImage: "trash",
                            tint: .red,
                            perform: { showBatchDeleteConfirm = true }
                        )
                    ],
                    identifierPrefix: "PlanReviewListView"
                )
                .disabled(batchBusy)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isSelecting)
        .animation(.easeInOut(duration: 0.25), value: selectedSlugs.count)
        .confirmationDialog(
            "Delete \(selectedSlugs.count) plans?",
            isPresented: $showBatchDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedSlugs.count) Plans", role: .destructive) {
                deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each plan's body, review log and rendered review are removed from docs/plans. Anything already committed stays in git history.")
        }
        .navigationTitle("Plans")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreate = true
                } label: {
                    Label("New plan", systemImage: "plus")
                }
                .uiKitIdentifier("PlanReviewListView.createButton")
            }
        }
        .sheet(isPresented: $showingCreate, onDismiss: {
            // Present the draft run sheet only AFTER the create sheet has
            // fully dismissed. The previous timed sleep raced the dismissal
            // animation, and when it lost, the run sheet (intent + MODEL +
            // prompt) silently never appeared — the plan was created but the
            // draft was never offered.
            if let slug = pendingDraftSlug {
                pendingDraftSlug = nil
                draftTarget = DraftTarget(slug: slug)
            }
        }) {
            PlanCreateSheet { title, problem, draftAfter in
                guard let slug = await store.createPlan(title: title, problem: problem) else { return }
                if draftAfter {
                    pendingDraftSlug = slug
                }
            }
        }
        .sheet(item: $draftTarget) { target in
            PlanRunSheet(
                planTitle: store.detail?.title ?? target.slug,
                models: store.models,
                cache: cache,
                modelMemoryKey: store.detail?.planKey,
                initialIntent: "draft",
                promptFor: { intent in await store.runPrompt(for: target.slug, intent: intent) },
                onStart: { modelId, prompt, title in
                    let result = await store.startRun(on: target.slug, modelId: modelId, prompt: prompt, title: title)
                    if result.error == nil, let planKey = store.detail?.planKey {
                        PlanRunActivity.announceStart(planKey: planKey)
                    }
                    return result
                }
            )
        }
        .refreshable {
            await store.loadWorkDir()
            await store.loadPlans()
        }
        // The scope is shared now, so this screen is not the only thing that
        // can move it — re-read rather than assume this picker was the writer.
        .onReceive(NotificationCenter.default.publisher(for: .ripulWorkScopeChanged)) { _ in
            Task {
                await store.loadWorkDir()
                await store.loadPlans()
            }
        }
        .task {
            if store.workDir == nil { await store.loadWorkDir() }
            if store.plans.isEmpty { await store.loadPlans() }
        }
        .overlay {
            if store.loading && store.plans.isEmpty { ProgressView() }
        }
        .alert("Couldn't do that", isPresented: errorBinding) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete this plan?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { entry in
            Button("Delete", role: .destructive) {
                deleteTarget = nil
                Task { await store.deletePlan(entry.slug) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { entry in
            Text("\(entry.slug).md, its review log, and the rendered review are removed from docs/plans. Anything already committed stays in git history.")
        }
        .uiKitIdentifier("PlanReviewListView.root")
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil && store.detail == nil },
                set: { if !$0 { store.errorMessage = nil } })
    }

    /// Which resting state the list is in, or nil when it has rows.
    ///
    /// Four distinct situations that used to be one `ContentUnavailableView`
    /// gated on `store.plans.isEmpty` — which meant a search excluding every
    /// plan drew a blank panel with no message at all, since `filtered` can be
    /// empty while `store.plans` is not.
    private var emptyState: GlassListEmptyState? {
        if store.loading && store.plans.isEmpty { return .loading }
        if store.roots.isEmpty && store.workDir?.effective == nil {
            return .unresolved("No folder resolves — choose one above to use Plans.")
        }
        if store.plans.isEmpty {
            return .empty("Nothing in docs/plans in any of these projects yet.")
        }
        if filtered.isEmpty {
            return .noMatches("No matches for \"\(query)\".")
        }
        return nil
    }

    /// Delete every selected plan, then re-read the folder.
    ///
    /// Best-effort and sequential: each delete is an independent `git rm` plus
    /// a path-scoped commit, so a partial failure is the normal outcome and
    /// concurrent commits in one checkout would race the index. The surviving
    /// set is READ back rather than reconciled — the repo is ground truth.
    private func deleteSelected() {
        let targets = store.plans.filter { selectedSlugs.contains($0.id) }
        guard !targets.isEmpty, !batchBusy else { return }
        let slugs = targets.map(\.slug)
        batchBusy = true
        Task {
            defer { batchBusy = false }
            var failures: [String] = []
            for entry in targets {
                if let reason = await store.deletePlanReportingFailure(entry.slug, root: entry.root) {
                    failures.append("\(entry.slug): \(reason)")
                }
            }
            isSelecting = false
            selectedSlugs.removeAll()
            await store.loadPlans()
            if !failures.isEmpty {
                store.errorMessage = "\(failures.count) of \(slugs.count) could not be deleted:\n• "
                    + failures.joined(separator: "\n• ")
            }
        }
    }

    /// Collapsed-header hint: the folder's last path component, or the nudge.
    private var folderSubtitle: String {
        guard let effective = store.workDir?.effective, !effective.isEmpty else {
            return "Choose a folder"
        }
        return (effective as NSString).lastPathComponent
    }

    // MARK: - Work scope selector

    /// Where plans are read from, as an explicit control. Menu of the
    /// machine's directories plus Automatic (the old inference).
    private var workDirRow: some View {
        Menu {
            Button {
                choose(nil)
            } label: {
                if store.workDir?.source != "chosen" {
                    Label("Automatic (follow the active chat)", systemImage: "checkmark")
                } else {
                    Text("Automatic (follow the active chat)")
                }
            }
            ForEach(scopeOptions, id: \.self) { dir in
                Button {
                    choose(dir)
                } label: {
                    if store.workDir?.source == "chosen" && store.workDir?.effective == dir {
                        Label(dir, systemImage: "checkmark")
                    } else {
                        Text(dir)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayFolder)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(folderCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .uiKitIdentifier("PlanReviewListView.workDirRow")
    }

    private var displayFolder: String {
        store.workDir?.effective ?? "Choose a folder"
    }

    private var folderCaption: String {
        store.workDir?.caption ?? "Where work resolves"
    }

    /// The machine's folders, plus the current choice when it came from
    /// somewhere this screen cannot enumerate.
    ///
    /// The sessions list contributes folders discovered from its own rows, and
    /// the scope is shared — so a folder chosen there would otherwise be
    /// missing from this menu entirely, leaving no checkmark and no way to
    /// return to it after switching away. This screen has no session list of
    /// its own to discover from, which is why it can only re-add the effective
    /// value rather than the whole set.
    private var scopeOptions: [String] {
        guard let scope = store.workDir else { return [] }
        guard scope.source == "chosen", let effective = scope.effective else { return scope.options }
        return scope.mergedOptions(discovered: [effective])
    }

    private func choose(_ path: String?) {
        Task { await store.setWorkingDirectory(path) }
    }

    private func isRunning(_ entry: PlanListEntry) -> Bool {
        guard let key = entry.planKey else { return false }
        return runningPlanKeys.contains(key)
    }

    @ViewBuilder
    private func row(_ entry: PlanListEntry) -> some View {
        HStack(spacing: 12) {
            if isRunning(entry) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)
            } else {
                Image(systemName: symbol(for: entry))
                    .foregroundStyle(tint(for: entry))
                    .font(.title3)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.body).lineLimit(2)
                if isRunning(entry) {
                    Text("Agent running…")
                        .font(.caption)
                        .foregroundStyle(Color.blue)
                } else {
                    // Subtitle then lozenges, the same order the session row
                    // uses — the sentence answers "does this need me?", the
                    // lozenges answer "which one is this?".
                    HStack(spacing: 6) {
                        Text(subtitle(for: entry))
                            .font(.caption)
                            .foregroundStyle(entry.blockingOutstanding > 0 ? Color.orange : Color.secondary)
                        if activeProjectFilter == nil, let project = entry.projectName {
                            Text("· \(project)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(store.tags(for: entry), id: \.self) { tag in
                            TagLozenge(text: tag)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            // The list is sorted by this — show it, in the same terse style
            // the session list uses ("5m", "2h", "3d").
            if let active = Self.lastActiveDate(for: entry) {
                RelativeTimeText(date: active)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    /// ISO-8601 with fractional seconds (what `Date.toISOString()` emits),
    /// falling back to the plain form so an unusual timestamp degrades to
    /// "no time shown" rather than breaking the row.
    private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoParserPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func lastActiveDate(for entry: PlanListEntry) -> Date? {
        guard let raw = entry.lastActiveAt else { return nil }
        return isoParser.date(from: raw) ?? isoParserPlain.date(from: raw)
    }

    // Lifecycle iconography — one glyph per stage, so the list answers
    // "where is each plan in its life?" at a glance:
    //   dashed square  — born: template body, nothing written yet
    //   doc            — drafted, not yet reviewed
    //   orange bubble  — review findings outstanding (author's turn)
    //   checklist      — approved with work owed (implement it)
    //   green seal     — settled: reviewed, locked, no open tasks
    //
    // All three of these switch on `entry.state`, which is computed once
    // web-side (`planLifecycleState`). They were previously three separate
    // ladders over the raw booleans, and the web list ran a fourth — which is
    // how this list came to show five states while the web one showed three.
    // Deriving state from the booleans here again would restore that bug.
    private func symbol(for entry: PlanListEntry) -> String {
        switch entry.state {
        case .template: return "square.dashed"
        case .drafted: return "doc.text"
        case .openFindings: return "exclamationmark.bubble.fill"
        case .lockedWithTasks: return "checklist"
        case .lockedClean: return "checkmark.seal.fill"
        }
    }

    private func tint(for entry: PlanListEntry) -> Color {
        switch entry.state {
        case .template: return .secondary
        case .drafted: return .blue
        case .openFindings: return .orange
        case .lockedWithTasks: return .teal
        case .lockedClean: return .green
        }
    }

    // The COUNTS still come from the raw fields — "2 blocking · 1 task" is
    // data, not state. Only the shape of the sentence keys off the state.
    private func subtitle(for entry: PlanListEntry) -> String {
        switch entry.state {
        case .template:
            return "Problem statement only — draft me"
        case .drafted:
            return "Drafted · not reviewed"
        case .lockedClean:
            return "Locked"
        case .lockedWithTasks:
            return "Locked · ^[\(entry.openTasks) task](inflect: true) open"
        case .openFindings:
            var parts = ["^[\(entry.blockingOutstanding) blocking](inflect: true)"]
            if entry.openComments > entry.blockingOutstanding {
                parts.append("\(entry.openComments - entry.blockingOutstanding) other")
            }
            if entry.openTasks > 0 { parts.append("^[\(entry.openTasks) task](inflect: true)") }
            return parts.joined(separator: " · ")
        }
    }
}

/// `PlanReviewListView` with its store and create-sheet state owned for you.
///
/// Use this anywhere the screen is simply presented (a sheet, a pushed
/// destination). Hosts that render their own top bar should own the store and
/// use `PlanReviewListView` directly so their chrome can trigger creation too.
@available(iOS 17.0, macOS 14.0, *)
public struct PlanReviewScreen: View {
    @StateObject private var store: PlanReviewStore
    @State private var showingCreate = false
    private let cache: RipulSessionCache?

    public init(
        bridge: PlanReviewStore.Bridge,
        chatId: String,
        author: String = "you",
        cache: RipulSessionCache? = nil
    ) {
        _store = StateObject(wrappedValue: PlanReviewStore(bridge: bridge, chatId: chatId, author: author))
        self.cache = cache
    }

    public var body: some View {
        PlanReviewListView(store: store, showingCreate: $showingCreate, cache: cache)
    }
}
