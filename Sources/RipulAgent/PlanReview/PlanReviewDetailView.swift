import SwiftUI
import MarkdownUI

/// One plan's review, as a native list.
///
/// Presentation is rebuilt for the platform rather than mirroring the rendered
/// `.review.md`: sections are `Section`s in document order, status moves are
/// `.swipeActions` and a context menu, tasks are rows you tap. The web
/// document and this screen are two renderings of the same log — neither is a
/// port of the other.
///
/// Two things are deliberately loud:
///
///  - **Orphans sit at the top.** A comment whose section was rewritten away is
///    where a review quietly loses integrity, so it gets the first section and
///    a warning tint rather than being folded in with the rest.
///  - **The lock state is a header, not a badge.** It is the question the whole
///    entity exists to answer.
@available(iOS 17.0, macOS 14.0, *)
struct PlanReviewDetailView: View {
    let slug: String
    /// The plan's own directory. The list spans projects, so a slug alone no
    /// longer identifies a plan — this is what keeps the detail on the repo the
    /// row came from. Nil falls back to the work scope (single-root callers).
    var root: String? = nil
    @ObservedObject var store: PlanReviewStore
    /// Host-supplied "Sessions on this plan" panel, keyed by the plan's link
    /// tag; the binding raises the link picker, which THIS view presents from
    /// its stable sheet level (presenting from inside the content stack
    /// knocked the sheet down mid-present). Opaque builders because the plan
    /// views stay iOS 17 while the session machinery they embed is iOS 26.
    var planSessions: ((String, PlanDetail, Binding<Bool>) -> AnyView)? = nil
    /// The link-a-session sheet content (PlanSessionLinkPicker), keyed by the
    /// plan's link tag.
    var planLinkPicker: ((String) -> AnyView)? = nil
    /// Pin storage for the run sheet's model picker. Host-namespaced, so it is
    /// passed in rather than defaulted — nil just means no Pinned section.
    var cache: RipulSessionCache? = nil

    @State private var replyTarget: PlanComment?
    @State private var replyText: String = ""
    @State private var showClosed = false
    /// Document sections the user has opened — everything starts folded so
    /// the screen reads as an outline first, and the fold state is cheap to
    /// lose (it is presentation, not review state).
    @State private var expandedSections: Set<String> = []
    @State private var composingComment = false
    /// Section pre-selected when composing was started from one.
    @State private var composeAnchor = PlanAnchorConstants.planWide
    /// Non-nil while composing a task; the inner value is its source comment.
    @State private var composingTask: TaskComposition?
    @State private var runningAgent = false
    /// Intent requested by the checkpoint control for a first-of-role run —
    /// preselects the run sheet; nil falls back to the body-aware default.
    @State private var requestedRunIntent: String?
    /// Raised by the sessions panel's link button; the sheet lives here, with
    /// the other sheets, where presentation is stable.
    @State private var showingLinkPicker = false
    @State private var showingFile = false
    // Panel disclosure state. Content panels default open — the document
    // sections carry the folded-outline behavior via expandedSections.
    @State private var orphanedExpanded = true
    @State private var verdictExpanded = true
    @State private var tasksExpanded = true
    @State private var violationsExpanded = true

    /// Prose size for the plan's markdown, scaled with Larger Text (Dynamic
    /// Type). MarkdownUI's FontSize(points) is absolute — without this the
    /// plan body ignores iOS text size entirely and can never reflow.
    @ScaledMetric(relativeTo: .body) private var proseFontSize: CGFloat = 15

    /// Wrapper so `.sheet(item:)` can distinguish "no source comment" from
    /// "not composing" — an optional PlanComment cannot express both.
    private struct TaskComposition: Identifiable {
        let id: String
        let source: PlanComment?
    }

    var body: some View {
        // The same GlassSectionPanel stack the agents screen uses — shared
        // look and feel with the plans list and the sessions panels.
        ScrollView {
            VStack(spacing: 12) {
            if let plan = store.detail {
                headerPanel(plan)

                // Below the summary, above the document: supervision should
                // not require scrolling past the prose.
                if let planSessions, let planKey = plan.planKey {
                    planSessions(planKey, plan, $showingLinkPicker)
                }

                if !plan.intro.isEmpty {
                    Markdown(plan.intro)
                        .markdownTextStyle { FontSize(proseFontSize) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .modifier(GlassPanelBackground())
                }

                if !plan.orphaned.isEmpty {
                    GlassSectionPanel(
                        title: "Orphaned anchors",
                        subtitle: "\(plan.orphaned.count)",
                        isExpanded: $orphanedExpanded,
                        trailing: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    ) {
                        panelRows(plan.orphaned) { commentRow($0, orphaned: true) }
                        Text("These point at sections that no longer exist. Each was either addressed by the rewrite, or lost in it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }
                }

                if !plan.planComments.isEmpty {
                    GlassSectionPanel(
                        title: "Verdict",
                        subtitle: "\(plan.planComments.count)",
                        isExpanded: $verdictExpanded
                    ) {
                        panelRows(plan.planComments) { commentRow($0) }
                    }
                }

                // The DOCUMENT reads as a document: heading folds are
                // typographic (chevron + heading + count pill), not stacked
                // glass cards — a full panel per heading drowned the prose.
                // One quiet panel wraps the whole body instead. The fold
                // stays hierarchical: collapsing a node hides its subtree,
                // and the pill answers for the hidden comments.
                if !plan.sections.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleSections(plan)) { display in
                            VStack(alignment: .leading, spacing: 0) {
                                sectionFoldRow(display)
                                if expandedSections.contains(display.section.slug) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        if !display.section.prose.isEmpty {
                                            Markdown(display.section.prose)
                                                .markdownTextStyle { FontSize(proseFontSize) }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.horizontal, 16)
                                                .padding(.bottom, 8)
                                                .uiKitIdentifier("PlanReviewDetailView.sectionProse")
                                        }
                                        panelRows(display.section.comments) { commentRow($0) }
                                    }
                                    // Subsections read as subordinate rather than
                                    // flattening a nested plan into a flat list.
                                    .padding(.leading, CGFloat(max(0, display.section.level - 2)) * 12)
                                }
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                // Copy works whether or not the section is
                                // expanded — the heading alone is still a
                                // long-press target, and it should still
                                // yield the section's full text.
                                Button {
                                    copyToPasteboard(sectionText(display.section))
                                } label: { Label("Copy", systemImage: "doc.on.doc") }
                                    .uiKitIdentifier("PlanReviewDetailView.sectionCopy")
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .modifier(GlassPanelBackground())
                }

                if !plan.tasks.isEmpty {
                    GlassSectionPanel(
                        title: "Tasks",
                        subtitle: "\(plan.tasks.count)",
                        isExpanded: $tasksExpanded
                    ) {
                        panelRows(plan.tasks) { taskRow($0, in: plan) }
                    }
                }

                if plan.outstandingCount == 0 && plan.tasks.isEmpty && plan.sections.isEmpty {
                    ContentUnavailableView {
                        Label("Not reviewed yet", systemImage: "text.magnifyingglass")
                    } description: {
                        Text("No comments on this plan. Ask an agent to review it, or add the first one yourself.")
                    } actions: {
                        // The description says "ask an agent" — so offer it,
                        // as the primary action, with the right verb: a
                        // template body wants drafting, not a review of its
                        // placeholders.
                        Button(plan.bodyIsTemplate ? "Draft with agent" : "Run an agent review") {
                            runningAgent = true
                        }
                        .buttonStyle(.borderedProminent)
                        .uiKitIdentifier("PlanReviewDetailView.emptyRunAgent")
                        Button("Add comment") {
                            composeAnchor = PlanAnchorConstants.planWide
                            composingComment = true
                        }
                        .uiKitIdentifier("PlanReviewDetailView.emptyAddComment")
                    }
                    .padding(.vertical, 8)
                    .modifier(GlassPanelBackground())
                }

                if !plan.closed.isEmpty {
                    GlassSectionPanel(
                        title: "Closed — not up for debate",
                        subtitle: "\(plan.closed.count)",
                        isExpanded: $showClosed
                    ) {
                        panelRows(plan.closed) { closedRow($0) }
                    }
                }

                if !plan.violations.isEmpty {
                    GlassSectionPanel(
                        title: "Log violations",
                        subtitle: "\(plan.violations.count)",
                        isExpanded: $violationsExpanded
                    ) {
                        panelRows(plan.violations) { violation in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(violation.reason).font(.subheadline.weight(.medium))
                                Text(violation.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if store.loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .navigationTitle(store.detail?.title ?? slug)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // Running an agent is the screen's primary verb — its own visible
            // button, not the third item behind an ellipsis. The header row
            // offers it too; a run should be findable from either end.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    runningAgent = true
                } label: {
                    Label("Run agent…", systemImage: "play.circle")
                }
                .uiKitIdentifier("PlanReviewDetailView.runButton")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        composeAnchor = PlanAnchorConstants.planWide
                        composingComment = true
                    } label: { Label("Add comment", systemImage: "text.bubble") }
                    Button {
                        composingTask = TaskComposition(id: "new", source: nil)
                    } label: { Label("Add task", systemImage: "checklist") }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .uiKitIdentifier("PlanReviewDetailView.addButton")
            }
        }
        .sheet(isPresented: $composingComment) {
            PlanCommentSheet(
                anchors: store.detail?.anchors ?? [],
                initialAnchor: composeAnchor
            ) { anchor, severity, body in
                await store.addComment(anchor: anchor, severity: severity, body: body, in: slug)
            }
        }
        .sheet(item: $composingTask) { composition in
            PlanTaskSheet(sourceComment: composition.source) { title, owner in
                await store.addTask(
                    title: title,
                    fromComment: composition.source?.id,
                    owner: owner,
                    in: slug
                )
            }
        }
        .sheet(isPresented: $runningAgent) {
            PlanRunSheet(
                planTitle: store.detail?.title ?? slug,
                models: store.models,
                cache: cache,
                modelMemoryKey: store.detail?.planKey,
                // The checkpoint's first-of-role request wins; otherwise a
                // born-but-unwritten plan wants drafting, not a review of
                // its placeholders. The picker still offers every intent.
                initialIntent: requestedRunIntent ?? (store.detail?.bodyIsTemplate == true ? "draft" : "review"),
                promptFor: { intent in await store.runPrompt(for: slug, intent: intent) },
                onStart: { modelId, prompt, title in
                    let result = await store.startRun(on: slug, modelId: modelId, prompt: prompt, title: title)
                    if result.error == nil, let planKey = store.detail?.planKey {
                        PlanRunActivity.announceStart(planKey: planKey)
                    }
                    return result
                }
            )
        }
        .refreshable { await store.loadDetail(slug, root: root) }
        // Unconditional: a run may have rewritten the files since this slug
        // was last loaded — the cached render stays up until replaced, so
        // there is no flicker cost to always re-reading.
        .task { await store.loadDetail(slug, root: root) }
        .onReceive(NotificationCenter.default.publisher(for: .ripulPlanRunFinished)) { note in
            guard (note.userInfo?["planKey"] as? String) == store.detail?.planKey else { return }
            Task { await store.loadDetail(slug, root: root) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ripulPlanRunSheetRequested)) { note in
            guard (note.userInfo?["planKey"] as? String) == store.detail?.planKey else { return }
            requestedRunIntent = note.userInfo?["intent"] as? String
            runningAgent = true
        }
        .onChange(of: runningAgent) { _, showing in
            if !showing { requestedRunIntent = nil }
        }
        .alert("Couldn't do that", isPresented: errorBinding) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .sheet(item: $replyTarget) { comment in
            replySheet(comment)
        }
        .sheet(isPresented: $showingLinkPicker) {
            if let planLinkPicker, let planKey = store.detail?.planKey {
                planLinkPicker(planKey)
            }
        }
        .sheet(isPresented: $showingFile) {
            PlanFileSheet(
                path: store.detail?.bodyPath ?? slug,
                contents: store.detail?.body ?? ""
            )
        }
        .uiKitIdentifier("PlanReviewDetailView.list")
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }

    // MARK: - Header

    @ViewBuilder
    private func headerPanel(_ plan: PlanDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: plan.locked ? "lock.fill" : "lock.open.fill")
                    .font(.title2)
                    .foregroundStyle(plan.locked ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.locked ? "Locked" : "Open")
                        .font(.headline)
                    Text(plan.locked
                         ? "No blocking comments outstanding."
                         : "^[\(plan.blockingOutstanding) blocking comment](inflect: true) outstanding.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            if plan.outstandingCount > 0 {
                LabeledContent("Open") {
                    Text("\(plan.openBlocking) blocking · \(plan.openShouldFix) should-fix · \(plan.openNit) nit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // The old "Run agent on this plan…" row is gone: the checkpoint
            // control names and fires the owed step, and the toolbar's
            // "Run agent…" remains the escape hatch (fresh reviewer,
            // implement, model change, prompt edit).

            // The provenance line IS the file: tap to read the raw markdown
            // whole, long-press to copy the path without opening it.
            Button {
                showingFile = true
            } label: {
                HStack(spacing: 4) {
                    Text("\(plan.bodyPath) · \(plan.machineName)")
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    PlanFileSheet.copyToPasteboard(plan.bodyPath)
                } label: {
                    Label("Copy file path", systemImage: "link")
                }
                Button {
                    showingFile = true
                } label: {
                    Label("View file", systemImage: "doc.text")
                }
            }
            .uiKitIdentifier("PlanReviewDetailView.filePathRow")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassPanelBackground())
    }

    /// Rows inside a panel: List used to supply insets; here each row gets
    /// them explicitly, with hairline dividers between.
    @ViewBuilder
    private func panelRows<T: Identifiable, Row: View>(
        _ items: [T],
        @ViewBuilder row: @escaping (T) -> Row
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                row(item)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                if item.id != items.last?.id {
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    /// A document heading's fold row: chevron + heading in the document's own
    /// typography (normal case, weighted by nesting level), count pill and
    /// composer trailing. Deliberately quieter than a GlassSectionPanel — the
    /// document's hierarchy should read as an outline, not as chrome.
    @ViewBuilder
    private func sectionFoldRow(_ display: SectionDisplay) -> some View {
        let section = display.section
        let expanded = expandedSections.contains(section.slug)
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy) {
                    if expanded {
                        expandedSections.remove(section.slug)
                    } else {
                        expandedSections.insert(section.slug)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(section.heading)
                        .font(section.level <= 2 ? .subheadline.weight(.semibold) : .caption)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .uiKitIdentifier("PlanReviewDetailView.sectionFoldRow")
            Spacer(minLength: 8)
            sectionTrailing(display)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.leading, CGFloat(max(0, section.level - 2)) * 12)
    }

    /// The document panel's trailing controls: the count pill (answering for
    /// the folded subtree) and the per-section comment composer.
    @ViewBuilder
    private func sectionTrailing(_ display: SectionDisplay) -> some View {
        let expanded = expandedSections.contains(display.section.slug)
        let count = expanded ? display.section.comments.count : display.subtreeComments
        let highlight = expanded
            ? display.section.comments.contains { $0.severity == .blocking }
            : display.subtreeBlocking
        HStack(spacing: 8) {
            if count > 0 {
                countPill(count, highlight: highlight)
            }
            Button {
                composeAnchor = display.section.slug
                composingComment = true
            } label: {
                Image(systemName: "plus.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .uiKitIdentifier("PlanReviewDetailView.sectionAddComment")
        }
    }

    private func countPill(_ count: Int, highlight: Bool) -> some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(highlight ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15))
            )
    }

    /// What "Copy" on a section's context menu puts on the pasteboard —
    /// heading plus body, so the copy is useful on its own even pasted
    /// outside the plan.
    private func sectionText(_ section: PlanSection) -> String {
        section.prose.isEmpty ? section.heading : "\(section.heading)\n\n\(section.prose)"
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func sectionBinding(_ slug: String) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(slug) },
            set: { open in
                if open { expandedSections.insert(slug) } else { expandedSections.remove(slug) }
            }
        )
    }

    /// One renderable section: the section itself plus what its subtree owes,
    /// so a folded parent can answer for its hidden children.
    private struct SectionDisplay: Identifiable {
        let section: PlanSection
        /// Open comments across the section AND its descendants.
        let subtreeComments: Int
        let subtreeBlocking: Bool
        var id: String { section.slug }
    }

    /// The flat section list with hierarchy applied: a collapsed node's
    /// descendants (following sections nested deeper) are dropped entirely,
    /// and each node carries its subtree's comment tally for the folded pill.
    private func visibleSections(_ plan: PlanDetail) -> [SectionDisplay] {
        let sections = plan.sections
        var out: [SectionDisplay] = []
        var i = 0
        while i < sections.count {
            let section = sections[i]
            var j = i + 1
            var comments = section.comments.count
            var blocking = section.comments.contains { $0.severity == .blocking }
            while j < sections.count, sections[j].level > section.level {
                comments += sections[j].comments.count
                blocking = blocking || sections[j].comments.contains { $0.severity == .blocking }
                j += 1
            }
            out.append(SectionDisplay(section: section, subtreeComments: comments, subtreeBlocking: blocking))
            // A folded node hides its whole subtree; an open one lets each
            // child answer for itself (children default to folded too).
            i = expandedSections.contains(section.slug) ? i + 1 : j
        }
        return out
    }

    // MARK: - Rows

    @ViewBuilder
    private func commentRow(_ comment: PlanComment, orphaned: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: comment.severity.symbol)
                    .foregroundStyle(comment.severity.tint)
                    .font(.caption)
                Text(comment.severity.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(comment.severity.tint)
                if comment.status != .open {
                    Text(comment.status.label)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if store.isPending(comment.id) {
                    ProgressView().controlSize(.mini)
                }
            }

            Text(comment.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if orphaned, let suggestion = comment.suggestion {
                Text("Ambiguous — could be \(suggestion)")
                    .font(.caption).foregroundStyle(.orange)
            }

            if !comment.replies.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(comment.replies) { reply in
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Text(reply.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 4)
            }

            Text(comment.author).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Only what the web layer will actually accept — offering a move
            // that bounces is worse than not offering it.
            if comment.allowedActions.contains(.resolved) {
                Button {
                    Task { await store.setStatus(.resolved, on: comment, in: slug) }
                } label: { Label("Resolve", systemImage: "checkmark.circle.fill") }
                    .tint(.green)
            }
            if comment.allowedActions.contains(.wontfix) {
                Button {
                    Task { await store.setStatus(.wontfix, on: comment, in: slug) }
                } label: { Label("Won't fix", systemImage: "slash.circle") }
                    .tint(.gray)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if comment.allowedActions.contains(.accepted) {
                Button {
                    Task { await store.setStatus(.accepted, on: comment, in: slug) }
                } label: { Label("Accept", systemImage: "checkmark") }
                    .tint(.blue)
            }
        }
        .contextMenu {
            Button {
                replyText = ""
                replyTarget = comment
            } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }

            Button {
                composingTask = TaskComposition(id: comment.id, source: comment)
            } label: { Label("Create task from this", systemImage: "checklist") }

            if !comment.allowedActions.isEmpty { Divider() }
            ForEach(comment.allowedActions, id: \.rawValue) { action in
                Button {
                    Task { await store.setStatus(action, on: comment, in: slug) }
                } label: { Label(action.label, systemImage: action.symbol) }
            }
        }
    }

    @ViewBuilder
    private func closedRow(_ comment: PlanComment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: comment.status.symbol)
                .foregroundStyle(comment.status == .resolved ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(comment.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .strikethrough(comment.status == .wontfix)
                    .lineLimit(2)
                Text(comment.status.label).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ task: PlanTask, in plan: PlanDetail) -> some View {
        Button {
            Task { await store.toggle(task, in: slug) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: task.status.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.status.isDone ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.callout)
                        .strikethrough(task.status.isDone)
                        .foregroundStyle(task.status.isDone ? .secondary : .primary)
                    if let owner = task.owner {
                        Text(owner).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if store.isPending(task.id) { ProgressView().controlSize(.mini) }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reply

    @ViewBuilder
    private func replySheet(_ comment: PlanComment) -> some View {
        NavigationStack {
            Form {
                Section("Replying to") {
                    Text(comment.body).font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Your reply", text: $replyText, axis: .vertical)
                        .lineLimit(3...10)
                        .uiKitIdentifier("PlanReviewDetailView.replyField")
                }
            }
            .navigationTitle("Reply")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { replyTarget = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let body = replyText
                        replyTarget = nil
                        Task { await store.reply(to: comment, body: body, in: slug) }
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}
