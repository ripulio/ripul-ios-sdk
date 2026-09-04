import SwiftUI

/// State for the plan review screen.
///
/// A **leaf** ObservableObject on purpose: it is owned by the review screen and
/// by nothing above it. Publishing plan state from a store the host view also
/// observes re-renders the WKWebView on every comment, which is both a visible
/// stutter and pure waste.
///
/// The store never computes review rules. Every mutation round-trips to the web
/// layer and replaces state with the refreshed model that comes back, so the
/// screen cannot drift from the log — and an action the web layer refuses
/// (reopening a closed comment, an anchor that stopped resolving) surfaces as
/// an error instead of an optimistic update that silently disagrees with disk.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class PlanReviewStore: ObservableObject {

    /// The three web callables, injected so the screen is drivable in previews
    /// and tests without a live web view.
    public struct Bridge: Sendable {
        /// (chatId, roots). Empty roots = the work scope alone.
        public var list: @Sendable (String, [String]) async -> Result<[PlanListEntry], PlanReviewError>
        /// (chatId, plan, root) — root is the plan's OWN directory, not the scope.
        public var get: @Sendable (String, String, String?) async -> Result<PlanDetail, PlanReviewError>
        public var act: @Sendable (String, String, PlanAction, String, String?) async -> Result<PlanDetail, PlanReviewError>
        /// (chatId, title, problem) — problem seeds the Problem section.
        public var create: @Sendable (String, String, String?, String?) async -> Result<PlanDetail, PlanReviewError>
        /// (chatId, plan, intent) -> prompt text
        public var runPrompt: @Sendable (String, String, String) async -> String
        /// (chatId, modelId, prompt, planKey, title). `planKey` tags the new
        /// session onto the plan at creation; `title` names it after its job
        /// ("Review: <plan>"). The result carries the new session's chatId so
        /// the checkpoint can record the plan's author session durably.
        public var startRun: @Sendable (String, String, String, String?, String?) async -> PlanRunStartResult
        /// Model catalog for the run picker.
        public var models: @Sendable () async -> [ModelInfo]
        /// Folder selector state for the Plans surface.
        public var workDir: @Sendable (String) async -> WorkScopeState?
        /// Set (nil clears) the chosen Plans folder.
        public var setWorkDir: @Sendable (String?) async -> Bool
        /// (chatId, plan) -> nil on success, else the reason. Deletes the
        /// plan's three files outright — the confirmation copy lives in the
        /// view, the approver is the person holding the phone.
        public var delete: @Sendable (String, String, String?) async -> String?
        /// Bulk `{ metadataId: tags }` for the account — the SAME map the
        /// session list joins against. Injected so the store never reaches the
        /// API itself, and so previews can supply a fixture.
        public var allTags: @Sendable () async -> [String: [String]]

        public init(
            list: @escaping @Sendable (String, [String]) async -> Result<[PlanListEntry], PlanReviewError>,
            get: @escaping @Sendable (String, String, String?) async -> Result<PlanDetail, PlanReviewError>,
            act: @escaping @Sendable (String, String, PlanAction, String, String?) async -> Result<PlanDetail, PlanReviewError>,
            create: @escaping @Sendable (String, String, String?, String?) async -> Result<PlanDetail, PlanReviewError>,
            runPrompt: @escaping @Sendable (String, String, String) async -> String,
            startRun: @escaping @Sendable (String, String, String, String?, String?) async -> PlanRunStartResult,
            models: @escaping @Sendable () async -> [ModelInfo],
            workDir: @escaping @Sendable (String) async -> WorkScopeState?,
            setWorkDir: @escaping @Sendable (String?) async -> Bool,
            delete: @escaping @Sendable (String, String, String?) async -> String?,
            allTags: @escaping @Sendable () async -> [String: [String]] = { [:] }
        ) {
            self.list = list
            self.get = get
            self.act = act
            self.create = create
            self.runPrompt = runPrompt
            self.startRun = startRun
            self.models = models
            self.workDir = workDir
            self.setWorkDir = setWorkDir
            self.delete = delete
            self.allTags = allTags
        }
    }

    @Published public private(set) var plans: [PlanListEntry] = []
    @Published public private(set) var detail: PlanDetail?
    @Published public private(set) var loading = false
    /// Set while a specific comment or task is mid-flight, so only that row
    /// shows progress rather than the whole list going inert.
    @Published public private(set) var pendingIds: Set<String> = []
    @Published public var errorMessage: String?
    /// Loaded lazily when the run sheet is first opened — the catalog is not
    /// needed to read a plan, and fetching it on every detail load would put a
    /// network round-trip in front of the document.
    @Published public private(set) var models: [ModelInfo] = []
    /// The folder plans resolve against, with provenance and picker options.
    @Published public private(set) var workDir: WorkScopeState?
    /// Bulk tag map, keyed by metadata id. Refreshed alongside the list and
    /// joined per row via `tags(for:)`.
    @Published public private(set) var tagsById: [String: [String]] = [:]
    /// Directories the list spans. Set by the view from the work scope's
    /// options; empty means "the work scope alone", the original behaviour.
    @Published public var roots: [String] = []

    /// The directory a plan lives in.
    ///
    /// The list spans projects, so every action has to go back to the plan's
    /// OWN root — otherwise editing a plan you can see would write to whichever
    /// repo the work scope happens to point at. Nil for a slug not in the list
    /// (a plan just created), which correctly falls back to the scope.
    public func root(for slug: String) -> String? {
        plans.first { $0.slug == slug }?.root
    }

    private let bridge: Bridge
    private let chatId: String
    private let author: String

    public init(bridge: Bridge, chatId: String, author: String = "you") {
        self.bridge = bridge
        self.chatId = chatId
        self.author = author
    }

    // MARK: - Loading

    public func loadPlans() async {
        loading = true
        defer { loading = false }
        // Tags come from the account, plans from the repo — two independent
        // sources joined by key at render time, exactly as the session list
        // does it (UnifiedSession.build(tagsByKey:)). Fetched concurrently
        // because neither needs the other, and a tag failure must not cost the
        // list: an empty map just means no lozenges this round.
        async let tags = bridge.allTags()
        async let listing = bridge.list(chatId, roots)
        let (fetchedTags, result) = await (tags, listing)

        tagsById = fetchedTags
        switch result {
        case .success(let entries):
            plans = entries
            errorMessage = nil
        case .failure(let failure):
            errorMessage = failure.message
        }
    }

    /// User tags for a row. A pure dictionary lookup on a web-computed key —
    /// there is no rule here to drift, which is why the join is allowed to live
    /// client-side while lock/sort/lifecycle state stays web-side.
    public func tags(for entry: PlanListEntry) -> [String] {
        guard let id = entry.tagsId else { return [] }
        return tagsById[id] ?? []
    }

    /// `root` disambiguates a slug that exists in more than one project. Nil
    /// falls back to a scan, which is correct when only one root is loaded.
    public func loadDetail(_ slug: String, root: String? = nil) async {
        loading = true
        defer { loading = false }
        switch await bridge.get(chatId, slug, root ?? self.root(for: slug)) {
        case .success(let plan):
            detail = plan
            errorMessage = nil
        case .failure(let failure):
            errorMessage = failure.message
        }
    }

    // MARK: - Mutation

    /// Apply one action. `trackingId` is the row that should show progress.
    public func apply(_ action: PlanAction, to slug: String, trackingId: String?, root: String? = nil) async {
        if let trackingId { pendingIds.insert(trackingId) }
        defer { if let trackingId { pendingIds.remove(trackingId) } }

        switch await bridge.act(chatId, slug, action, author, root ?? self.root(for: slug)) {
        case .success(let plan):
            detail = plan
            errorMessage = nil
        case .failure(let failure):
            // Deliberately not reverting anything: nothing was applied locally,
            // so there is nothing to roll back. The row simply stays as it was.
            errorMessage = failure.message
        }
    }

    public func isPending(_ id: String) -> Bool { pendingIds.contains(id) }

    // MARK: - Agent runs

    public func loadModels() async {
        guard models.isEmpty else { return }
        models = await bridge.models()
    }

    // MARK: - Working directory

    public func loadWorkDir() async {
        workDir = await bridge.workDir(chatId)
        // Every candidate folder becomes a root the list spans — the effective
        // one first so it is read even when it is not among the machine's
        // favourites. The scope still decides where NEW plans are created; it
        // no longer decides what you are allowed to see.
        var candidates: [String] = []
        if let effective = workDir?.effective, !effective.isEmpty { candidates.append(effective) }
        candidates.append(contentsOf: workDir?.options ?? [])
        var seen = Set<String>()
        roots = candidates.filter { seen.insert($0).inserted }
    }

    /// Choose the Plans folder (nil = back to Automatic), then reload against it.
    public func setWorkingDirectory(_ path: String?) async {
        _ = await bridge.setWorkDir(path)
        await loadWorkDir()
        await loadPlans()
    }

    /// Delete a plan's files, then drop it from the list locally — the files
    /// are gone either way, so a refetch would only confirm the absence.
    public func deletePlan(_ slug: String) async {
        if let reason = await bridge.delete(chatId, slug, root(for: slug)) {
            errorMessage = reason
        } else {
            plans.removeAll { $0.slug == slug }
            errorMessage = nil
        }
    }

    /// Delete one plan and RETURN the failure instead of surfacing it.
    ///
    /// The batch path needs to collect failures across the whole selection and
    /// report them once — a per-item `errorMessage` write would leave only the
    /// last failure visible, which for a destructive verb is the wrong half of
    /// the story. Deliberately does not touch `plans`: the caller re-reads the
    /// folder when the loop ends rather than reconciling optimistic removals.
    public func deletePlanReportingFailure(_ slug: String, root: String? = nil) async -> String? {
        await bridge.delete(chatId, slug, root ?? self.root(for: slug))
    }

    public func runPrompt(for slug: String, intent: String) async -> String {
        await loadModels()
        return await bridge.runPrompt(chatId, slug, intent)
    }

    public func startRun(on slug: String, modelId: String, prompt: String, title: String? = nil) async -> PlanRunStartResult {
        // The link key rides along so the new session is tagged onto the plan
        // at creation. The loaded detail is the plan the run sheet was opened
        // on; the slug check only guards a stale detail.
        let planKey = detail?.slug == slug ? detail?.planKey : nil
        return await bridge.startRun(chatId, modelId, prompt, planKey, title)
    }

    public func setStatus(_ status: PlanCommentStatus, on comment: PlanComment, in slug: String) async {
        await apply(.status(commentId: comment.id, status: status, note: nil), to: slug, trackingId: comment.id)
    }

    public func toggle(_ task: PlanTask, in slug: String) async {
        await apply(.taskStatus(taskId: task.id, status: task.status == .done ? .open : .done),
                    to: slug, trackingId: task.id)
    }

    public func reply(to comment: PlanComment, body: String, in slug: String) async {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await apply(.reply(commentId: comment.id, body: body), to: slug, trackingId: comment.id)
    }

    /// Create a plan, then open it.
    ///
    /// Refreshes the list too: a newly created plan must appear behind the
    /// detail screen, or backing out lands on a list that does not contain the
    /// thing you just made.
    @discardableResult
    public func createPlan(title: String, problem: String? = nil) async -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        loading = true
        defer { loading = false }

        let statement = problem?.trimmingCharacters(in: .whitespacesAndNewlines)
        // New plans land in the WORK SCOPE — that is what the scope is for.
        switch await bridge.create(chatId, trimmed, statement?.isEmpty == false ? statement : nil, nil) {
        case .success(let plan):
            detail = plan
            errorMessage = nil
            await loadPlans()
            return plan.slug
        case .failure(let failure):
            errorMessage = failure.message
            return nil
        }
    }

    public func addComment(anchor: String, severity: PlanSeverity, body: String, in slug: String) async {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await apply(.comment(anchor: anchor, severity: severity, body: body), to: slug, trackingId: nil)
    }

    public func addTask(title: String, fromComment: String?, owner: String?, in slug: String) async {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await apply(.task(title: title, fromComment: fromComment, owner: owner), to: slug, trackingId: nil)
    }
}
