import SwiftUI

public extension Notification.Name {
    /// Posted when a plan-tagged session's turn finishes (running → idle),
    /// carrying `planKey` in userInfo. The plan screens reload on it — the
    /// document a run just rewrote must not require a pull or a restart to
    /// appear.
    static let ripulPlanRunFinished = Notification.Name("ripulPlanRunFinished")
    /// Posted by the checkpoint when a role has no remembered model yet —
    /// the detail screen presents the run sheet preconfigured (`planKey` +
    /// `intent` in userInfo) so the FIRST run of each role always asks.
    static let ripulPlanRunSheetRequested = Notification.Name("ripulPlanRunSheetRequested")
    /// Posted after a run starts by ANY path (checkpoint one-tap, run sheet,
    /// create-and-draft), `planKey` in userInfo. The sessions panel refreshes
    /// on it — a run you just started must appear without a pull.
    static let ripulPlanRunStarted = Notification.Name("ripulPlanRunStarted")
    /// Posted when the shared WORK SCOPE moves — from this app, from the web
    /// Plans screen, or from the web sessions list (the web layer announces to
    /// every surface, and `AgentBridge` forwards the announcement here).
    ///
    /// Both native lists observe it and RE-READ. They deliberately do not cache
    /// the new value out of `userInfo`: four surfaces holding four copies of
    /// one folder is precisely the drift this scope split exists to end.
    static let ripulWorkScopeChanged = Notification.Name("ripulWorkScopeChanged")
}

/// The plan's BREAKPOINT: one visible control that names the owed next step
/// and fires it on a single tap — hitting run on a breakpoint.
///
/// The state derives entirely from data the screen already has: the fold
/// (blocking counts, locked, template body) plus the plan's tagged sessions,
/// whose role-carrying titles ("Draft:", "Review:", "Address:") and live turn
/// phases make rounds machine-readable without new log event kinds — the
/// session-plan-link doctrine holds (no session ephemera in the shared log).
///
/// This is the turn-semantics design's `nextTurn` with the HUMAN as executor;
/// the future no-checkpoints mode is the same derivation with the tap
/// automated. The loop is SYMMETRIC — the same two sessions bounce:
///
///  - **The author keeps its context.** "Address" KICKS the recorded
///    drafting/addressing session awake — the repo exploration and rejected
///    alternatives that never made the document stay loaded, so it can argue
///    a `wontfix` instead of capitulating to every comment.
///  - **The reviewer keeps its context too.** Round 2+ KICKS the recorded
///    review session: a later round is first a confirm-round on that
///    reviewer's OWN comments (`accepted` still blocks until the reviewer
///    `resolved`s it), which is exactly where remembering why each was
///    raised matters. Only the FIRST review spawns fresh. Fresh eyes on
///    demand: "Run agent… → Review" always spawns new, and the new session
///    replaces the recorded reviewer.
@available(iOS 26.0, macOS 26.0, *)
public struct PlanCheckpointControl: View {
    private let bridge: AgentBridge
    @ObservedObject private var model: RipulSessionListModel
    @ObservedObject private var sessionStore: SessionListStore
    private let cache: RipulSessionCache
    private let plan: PlanDetail
    private let planKey: String
    private let chatId: String

    @State private var working = false
    @State private var feedback: String?
    /// Optimistic run-start overlay — see PlanRunActivity. Keeps the control
    /// from offering a call-to-action during the seconds between a start and
    /// the tagged session becoming visible with a live phase.
    @ObservedObject private var activity = PlanRunActivity.shared

    public init(
        bridge: AgentBridge,
        model: RipulSessionListModel,
        cache: RipulSessionCache,
        plan: PlanDetail,
        planKey: String,
        chatId: String
    ) {
        self.bridge = bridge
        self.model = model
        self.sessionStore = bridge.sessionList
        self.cache = cache
        self.plan = plan
        self.planKey = planKey
        self.chatId = chatId
    }

    private var tagged: [UnifiedSession] {
        model.unifiedSessions.filter { $0.tags.contains(planKey) }
    }

    /// The active run's id — watched so the running→idle transition can
    /// announce itself (see .ripulPlanRunFinished).
    private var runningId: String? {
        tagged.first(where: isActive)?.id
    }

    private func isActive(_ session: UnifiedSession) -> Bool {
        switch sessionStore.turnPhase(for: session.metadataKey) {
        case .running, .awaitingInput: return true
        default: return false
        }
    }

    private enum Step {
        case running(String)
        case draft
        case review(round: Int, reviewerChatId: String?, reviewerTitle: String?, reviewerMachineId: String?)
        case address(count: Int, drafterChatId: String?, drafterTitle: String?, drafterMachineId: String?)
        case settled(openTasks: Int)
    }

    /// Durable driver state, recorded at start time by whichever path started
    /// the run (checkpoint, run sheet). Titles are decoration — auto-retitling
    /// silently broke every title-derived decision, so the driver records
    /// what it does instead of re-deriving it from display strings.
    private var recordedAuthorChatId: String? {
        cache.object(forKey: "planAuthor:\(planKey)") as? String
    }
    private var recordedReviewerChatId: String? {
        cache.object(forKey: "planReviewer:\(planKey)") as? String
    }
    private var recordedLastActor: String? {
        cache.object(forKey: "planLastActor:\(planKey)") as? String
    }

    /// The author session to kick: the durable record first; the title
    /// heuristic only as legacy fallback. The row is optional — kicking only
    /// needs the chatId (plus machineId to reopen a closed tab). The record
    /// holds the `cli_<uuid>` form while rows carry the bare form, so the
    /// row lookup must be canonical, never string-equal.
    private func resolveAuthor() -> (chatId: String?, title: String?, machineId: String?) {
        if let id = recordedAuthorChatId {
            let row = tagged.first {
                $0.matchKeys.contains(id)
                    || UnifiedSession.canonicalKey($0.metadataKey) == UnifiedSession.canonicalKey(id)
            }
            return (id, row?.title, row?.machineId)
        }
        let row = tagged
            .filter { $0.title.hasPrefix("Draft:") || $0.title.hasPrefix("Address:") }
            .max { $0.lastUsed < $1.lastUsed }
        return (row?.metadataKey, row?.title, row?.machineId)
    }

    /// The reviewer session to kick on round 2+ — same record-first shape as
    /// `resolveAuthor`. Nil chatId ⇒ no reviewer is known and the round
    /// spawns fresh (which then becomes the recorded reviewer).
    private func resolveReviewer() -> (chatId: String?, title: String?, machineId: String?) {
        if let id = recordedReviewerChatId {
            let row = tagged.first {
                $0.matchKeys.contains(id)
                    || UnifiedSession.canonicalKey($0.metadataKey) == UnifiedSession.canonicalKey(id)
            }
            return (id, row?.title, row?.machineId)
        }
        let row = tagged
            .filter { $0.title.hasPrefix("Review:") }
            .max { $0.lastUsed < $1.lastUsed }
        return (row?.metadataKey, row?.title, row?.machineId)
    }

    private var step: Step {
        if let running = tagged.first(where: isActive) {
            return .running(running.title)
        }
        // A start was announced but the session is not visible/live yet —
        // show running, not a call-to-action for the step already underway.
        if activity.recentlyStarted(planKey) {
            return .running("Starting…")
        }
        if plan.bodyIsTemplate { return .draft }
        // "Has a review happened?" comes from the LOG first — comments cannot
        // exist without one — with review-titled sessions as the refinement
        // for round counting. Titles alone proved fragile: a session whose
        // name was auto-retitled made the checkpoint re-offer "first review"
        // forever after one had plainly run.
        let reviews = tagged.filter { $0.title.hasPrefix("Review:") }
        let commentsExist = plan.outstandingCount + plan.closed.count > 0
        if reviews.isEmpty && !commentsExist {
            // The first review always spawns fresh — there is no reviewer yet,
            // and the first read deserves clean eyes.
            return .review(round: 1, reviewerChatId: nil, reviewerTitle: nil, reviewerMachineId: nil)
        }
        let reviewRounds = max(reviews.count, 1)

        // The turn alternates by LAST ACTOR, not by lock state alone.
        // `accepted` still counts as blocking-outstanding (agreeing is not
        // fixing), so "blocking > 0 → address" would re-offer Address forever
        // after the author accepts: only a reviewer's confirming `resolved`
        // clears it, and that reviewer must be offered. Author had the last
        // word → a review round is owed (confirm the accepted, or re-raise);
        // review had the last word → outstanding findings are the author's.
        let authorActedLast: Bool
        if let recorded = recordedLastActor {
            authorActedLast = recorded == "author"
        } else {
            let last = tagged.max { $0.lastUsed < $1.lastUsed }
            authorActedLast = last.map { $0.title.hasPrefix("Draft:") || $0.title.hasPrefix("Address:") } ?? false
        }

        if authorActedLast {
            // Round 2+ is first a confirm-round on the reviewer's own
            // comments — kick the recorded reviewer with its context intact.
            let reviewer = resolveReviewer()
            return .review(
                round: reviewRounds + 1,
                reviewerChatId: reviewer.chatId,
                reviewerTitle: reviewer.title,
                reviewerMachineId: reviewer.machineId
            )
        }
        if plan.blockingOutstanding > 0 {
            let author = resolveAuthor()
            return .address(
                count: plan.blockingOutstanding,
                drafterChatId: author.chatId,
                drafterTitle: author.title,
                drafterMachineId: author.machineId
            )
        }
        let openTasks = plan.tasks.filter { $0.status == .open || $0.status == .doing }.count
        return .settled(openTasks: openTasks)
    }

    /// The model remembered from this ROLE's last run-sheet start — what
    /// makes subsequent rounds of the same kind one tap. Each role's first
    /// run has no memory and routes through the run sheet instead.
    private func rememberedModel(for intent: String) -> String? {
        cache.object(forKey: "planRunModel:\(planKey):\(intent)") as? String
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch step {
            case .running(let title):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Running").font(.subheadline.weight(.semibold))
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            case .draft:
                stepButton("Draft with agent", icon: "play.circle.fill") {
                    await fire(intent: "draft", resumeChatId: nil, resumeTitle: nil)
                }
            case .review(let round, let reviewerChatId, let reviewerTitle, let reviewerMachineId):
                stepButton(
                    round == 1 ? "Run first review" : "Run review — round \(round)",
                    icon: reviewerChatId != nil ? "arrow.uturn.forward.circle.fill" : "play.circle.fill",
                    subtitle: reviewerChatId != nil
                        ? "Kicks \(reviewerTitle ?? "the review session") — context intact"
                        : nil
                ) {
                    await fire(
                        intent: "review",
                        resumeChatId: reviewerChatId,
                        resumeTitle: reviewerTitle,
                        resumeMachineId: reviewerMachineId
                    )
                }
            case .address(let count, let drafterChatId, let drafterTitle, let drafterMachineId):
                stepButton(
                    count == 1 ? "Address 1 blocking comment" : "Address \(count) blocking comments",
                    icon: drafterChatId != nil ? "arrow.uturn.forward.circle.fill" : "play.circle.fill",
                    subtitle: drafterChatId != nil
                        ? "Kicks \(drafterTitle ?? "the drafting session") — context intact"
                        : nil
                ) {
                    await fire(
                        intent: "address",
                        resumeChatId: drafterChatId,
                        resumeTitle: drafterTitle,
                        resumeMachineId: drafterMachineId
                    )
                }
            case .settled(let openTasks):
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reviewed & locked").font(.subheadline.weight(.semibold))
                        if openTasks > 0 {
                            Text("\(openTasks) open tasks — Run agent… → Do the tasks")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassPanelBackground())
        .onChange(of: runningId) { old, new in
            // Real session state arrived — the optimistic overlay is done.
            if new != nil { activity.clear(planKey) }
            // A run just finished: refresh the session facts and tell the
            // plan screens to re-read the document it may have rewritten.
            if old != nil, new == nil {
                Task { await model.refresh() }
                NotificationCenter.default.post(
                    name: .ripulPlanRunFinished,
                    object: nil,
                    userInfo: ["planKey": planKey]
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulPlanRunStarted)) { note in
            // A run started from ANY surface (create-and-draft on the list,
            // the detail run sheet): refresh the session facts now and again
            // shortly after — the plan tag lands server-side moments after
            // the session exists, and the first refresh can beat it.
            guard (note.userInfo?["planKey"] as? String) == planKey else { return }
            Task { await model.refresh() }
            Task {
                try? await Task.sleep(for: .seconds(2))
                await model.refresh()
            }
        }
        // Mounted after the fact (run started from the list, THEN the plan
        // was opened): if the plan has no visible sessions yet, the list
        // snapshot may simply predate the run — re-read it once.
        .task {
            if tagged.isEmpty { await model.refresh() }
        }
        .uiKitIdentifier("PlanCheckpointControl.root")
    }

    @ViewBuilder
    private func stepButton(
        _ label: String,
        icon: String,
        subtitle: String? = nil,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            guard !working else { return }
            working = true
            feedback = nil
            Task {
                await action()
                working = false
            }
        } label: {
            HStack(spacing: 10) {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon).font(.title3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.subheadline.weight(.semibold))
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uiKitIdentifier("PlanCheckpointControl.stepButton")
    }

    private func fire(
        intent: String,
        resumeChatId: String?,
        resumeTitle: String?,
        resumeMachineId: String? = nil
    ) async {
        let prompt = await bridge.planRunPrompt(chatId: chatId, plan: plan.slug, intent: intent)
        guard !prompt.isEmpty else {
            feedback = "Could not build the prompt."
            return
        }

        if let resumeChatId {
            // Kick the role's recorded session awake with its context intact.
            let failure = await bridge.planResumeSession(
                chatId: resumeChatId, message: prompt, machineId: resumeMachineId)
            if failure == nil {
                if intent == "review" {
                    cache.set(resumeChatId, forKey: "planReviewer:\(planKey)")
                    cache.set("reviewer", forKey: "planLastActor:\(planKey)")
                } else {
                    cache.set(resumeChatId, forKey: "planAuthor:\(planKey)")
                    cache.set("author", forKey: "planLastActor:\(planKey)")
                }
                PlanRunActivity.announceStart(planKey: planKey)
                feedback = "Kicked \(resumeTitle ?? "the session")"
                await model.refresh()
            } else {
                feedback = failure
            }
            return
        }

        guard let modelId = rememberedModel(for: intent) else {
            // First run of this role: hand off to the run sheet so the model
            // is a deliberate choice, remembered for one-tap rounds after.
            NotificationCenter.default.post(
                name: .ripulPlanRunSheetRequested,
                object: nil,
                userInfo: ["planKey": planKey, "intent": intent]
            )
            return
        }
        let verb = intent == "draft" ? "Draft" : intent == "address" ? "Address" : "Review"
        let result = await bridge.planStartRun(
            sourceChatId: chatId,
            modelId: modelId,
            prompt: prompt,
            planKey: planKey,
            title: "\(verb): \(plan.title)"
        )
        if result.error == nil {
            if let newChatId = result.chatId {
                if intent == "draft" || intent == "address" {
                    cache.set(newChatId, forKey: "planAuthor:\(planKey)")
                } else if intent == "review" {
                    cache.set(newChatId, forKey: "planReviewer:\(planKey)")
                }
            }
            cache.set(intent == "review" ? "reviewer" : "author", forKey: "planLastActor:\(planKey)")
            PlanRunActivity.announceStart(planKey: planKey)
        }
        feedback = result.error
        if result.error == nil { await model.refresh() }
    }
}
