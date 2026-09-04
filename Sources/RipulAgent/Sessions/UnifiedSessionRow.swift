import SwiftUI

// MARK: - Session Subtitle Lozenge

/// Small, subdued pill shown at the start of the session-row subtitle line
/// when the chat has a live tool call or an active TodoWrite plan. Holds
/// the icon plus the tool label or `N/M` counter; the detail (second
/// parameter, file name, activeForm) follows after on the same line.
@available(iOS 26.0, macOS 26.0, *)
struct SessionTitleLozenge: View {
    enum Content {
        case tool(AgentActivityEvent)
        case plan(TodoState)

        /// Whether the lozenge renders its glyph. A `.tool` lozenge is only
        /// ever on screen while that same tool is live (both call sites gate
        /// on `latestToolActivity != nil`), and the row's leading slot already
        /// renders the identical `ToolIconMap` glyph for a live tool — so the
        /// lozenge carries just the name (it exists to hold the names too
        /// long to fit under the leading icon). The plan glyph appears
        /// nowhere else on the row, so `.plan` keeps its icon.
        var showsIcon: Bool {
            if case .tool = self { return false }
            return true
        }
    }

    let content: Content

    private var iconName: String {
        switch content {
        case .tool(let a):
            return ToolIconMap.symbol(for: a.toolNameForIcon)
        case .plan(let plan):
            let completed = plan.todos.filter { $0.status == "completed" }.count
            let allDone = completed == plan.todos.count && plan.todos.count > 0
            return allDone ? "checkmark.circle.fill" : "list.bullet.clipboard"
        }
    }

    private var label: String {
        switch content {
        case .tool(let a):
            return a.displayName ?? "Tool"
        case .plan(let plan):
            let completed = plan.todos.filter { $0.status == "completed" }.count
            return "\(completed)/\(plan.todos.count)"
        }
    }

    public var body: some View {
        HStack(spacing: 3) {
            if content.showsIcon {
                Image(systemName: iconName)
                    .font(.caption2)
                    .contentTransition(.symbolEffect(.replace))
                    .uiKitIdentifier("SessionTitleLozenge.icon")
            }
            Text(label)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .contentTransition(.opacity)
                .uiKitIdentifier("SessionTitleLozenge.label")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.12))
        )
        .uiKitIdentifier("SessionTitleLozenge.container")
        .animation(.easeInOut(duration: 0.175), value: iconName)
        .animation(.easeInOut(duration: 0.175), value: label)
    }
}

/// A user-authored tag, rendered as a small accent-tinted pill after the
/// repo/branch on the subtitle line. Mirrors the web session-row lozenges.
///
/// Availability deliberately tracks the OLDEST surface that renders tags, not
/// the session row's — this is Text + Capsule + Color and touches no iOS 26
/// API, and the plans list (iOS 17 / macOS 14) shows the same lozenges. Shared
/// chrome, not Sessions-private chrome.
@available(iOS 17.0, macOS 14.0, *)
struct TagLozenge: View {
    let text: String
    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .uiKitIdentifier("UnifiedSessionRow.tagLozenge")
    }
}

@available(iOS 26.0, macOS 26.0, *)
public struct UnifiedSessionRow: View {
    /// Row observes only the session-list leaf store so body re-runs are
    /// scoped to session-list data changes (activity, phases, todo states).
    /// Where this row is being rendered. Same identity resolution, same
    /// subtitle state machine, same live activity — only the chrome and the
    /// type scale differ.
    ///
    /// `.lozenge` is the chat screen's top-bar pill. It exists so the header
    /// and the session list cannot drift: the header used to derive its model
    /// from the picker cache alone, which falls back to the provider's DEFAULT
    /// model when the user has never picked one, and so routinely named a
    /// model the session wasn't running.
    public enum Presentation {
        case list
        case lozenge

        var isLozenge: Bool { self == .lozenge }
    }

    @ObservedObject var sessionStore: SessionListStore
    let session: UnifiedSession
    var presentation: Presentation = .list
    /// The user's explicit model pick for this session, when there is one.
    /// Beats `session.model` (the model of the last assistant message in the
    /// transcript, which lags a fresh pick by a whole turn) — but only if it
    /// resolves to a known family, so an unrecognised catalog id can't replace
    /// a good scanned value with a raw string.
    var modelIdOverride: String? = nil
    /// Resolved last-active time from the session-id cache (survives cold start).
    var cachedLastActive: Date? = nil
    var isOpening: Bool = false
    var isArchiving: Bool = false
    var isDeleting: Bool = false
    var isDeletingFromHost: Bool = false
    var machineIcon: String? = nil
    /// When true, the project name is omitted from the detail row — used when
    /// the list is already filtered to a single project so repeating the label
    /// on every row would be redundant.
    var hideProjectName: Bool = false
    var isSelectMode: Bool = false
    var isSelected: Bool = false
    /// Lines the title may occupy. 1 everywhere except the agent screen's
    /// EXPANDED title lozenge, where showing more of a long title is the
    /// point of expanding — and growing this row's line count (rather than
    /// swapping in a different title view) is what keeps the expansion a
    /// height animation on one view instead of a snap between two.
    var titleLineLimit: Int = 1
    var onSessionAction: ((SessionRowAction) -> Void)? = nil

    public init(
        sessionStore: SessionListStore,
        session: UnifiedSession,
        presentation: Presentation = .list,
        modelIdOverride: String? = nil,
        cachedLastActive: Date? = nil,
        isOpening: Bool = false,
        isArchiving: Bool = false,
        isDeleting: Bool = false,
        isDeletingFromHost: Bool = false,
        machineIcon: String? = nil,
        hideProjectName: Bool = false,
        isSelectMode: Bool = false,
        isSelected: Bool = false,
        titleLineLimit: Int = 1,
        onSessionAction: ((SessionRowAction) -> Void)? = nil
    ) {
        self.sessionStore = sessionStore
        self.session = session
        self.presentation = presentation
        self.modelIdOverride = modelIdOverride
        self.cachedLastActive = cachedLastActive
        self.isOpening = isOpening
        self.isArchiving = isArchiving
        self.isDeleting = isDeleting
        self.isDeletingFromHost = isDeletingFromHost
        self.machineIcon = machineIcon
        self.hideProjectName = hideProjectName
        self.isSelectMode = isSelectMode
        self.isSelected = isSelected
        self.titleLineLimit = titleLineLimit
        self.onSessionAction = onSessionAction
    }

    /// Live turn phase for this row. Reads `sessionStore.sessionPhases` at
    /// body-eval time — only sessions that are currently open as a Ripul
    /// tab have a phase (closed / offline JSONL rows return nil). Keyed by
    /// the tab's `sourceChatId`, which matches the `chatId` carried on
    /// lifecycle events.
    private var phase: AgentTurnPhase? {
        guard let sourceChatId = session.ripulSession?.sourceChatId else { return nil }
        return sessionStore.turnPhase(for: sourceChatId)
    }

    /// Whether this session's last agent turn has gone unlooked-at.
    ///
    /// Deliberately NOT derived from `phase`. The hand says the agent is
    /// waiting on you; this says you have not seen what it said. A session you
    /// opened, read, and left without replying is still awaiting input but is
    /// no longer unread — and before this the list had no way to show that
    /// difference, so everything waiting looked equally new.
    ///
    /// Every alias is offered because CLI sessions are keyed inconsistently
    /// (`cli_<uuid>` live, bare uuid from the scanner) and matchKeys is exactly
    /// the set of names this row answers to.
    private var isUnread: Bool {
        sessionStore.isUnread(anyOf: [session.id, session.ripulSession?.sourceChatId, session.ripulSession?.id]
            + session.matchKeys.map { Optional($0) })
    }

    /// Live in-progress TodoWrite plan for this row. Uses the *plain*
    /// `visibleTodoState` so the subtitle keeps ticking through `1/4`,
    /// `2/4`, ... even if the user has opened the chat once already.
    private var activePlan: TodoState? {
        guard let ripul = session.ripulSession else { return nil }
        if let byTab = sessionStore.visibleTodoState(for: ripul.id) { return byTab }
        return sessionStore.visibleTodoState(for: ripul.sourceChatId)
    }

    /// Live plan for the "Plan done" fallback only. Uses the *list*
    /// variant so a fully-completed plan clears from the row once the
    /// user opens the chat.
    private var listPlan: TodoState? {
        guard let ripul = session.ripulSession else { return nil }
        if let byTab = sessionStore.visibleTodoStateForList(for: ripul.id) { return byTab }
        return sessionStore.visibleTodoStateForList(for: ripul.sourceChatId)
    }

    /// Live "what's it doing right now" event for this row — carries the
    /// tool name (for icon lookup), display label (for the middle text),
    /// and second-lozenge detail (filename / pattern / command).
    private var latestToolActivity: AgentActivityEvent? {
        guard let ripul = session.ripulSession else { return nil }
        if let byTab = sessionStore.latestToolActivityForList(for: ripul.id) { return byTab }
        return sessionStore.latestToolActivityForList(for: ripul.sourceChatId)
    }

    /// Best-known "last active" time. Checks live bridge events, the
    /// resolved session-id cache (for cold start), and scanner file mtime.
    private var effectiveLastActive: Date {
        var best = session.lastUsed
        if let ripul = session.ripulSession {
            if let t = sessionStore.lastActiveTimeByChatId[ripul.id] { best = max(best, t) }
            if let t = sessionStore.lastActiveTimeByChatId[ripul.sourceChatId] { best = max(best, t) }
        }
        for key in session.matchKeys {
            if let t = sessionStore.lastActiveTimeByChatId[key] { best = max(best, t) }
        }
        if let t = cachedLastActive { best = max(best, t) }
        return best
    }

    /// Session-row action buttons declared by tools (e.g. "Show Plan").
    private var sessionActions: [SessionRowAction] {
        guard let ripul = session.ripulSession else { return [] }
        return sessionStore.sessionActionsByChatId[ripul.id]
            ?? sessionStore.sessionActionsByChatId[ripul.sourceChatId]
            ?? []
    }

    /// True when both a plan is in progress AND a tool call is active —
    /// determines whether the third row (inline tool line) is shown.
    private var hasInlineToolActivity: Bool {
        let state = SessionSubtitleState.resolve(activePlan: activePlan, listPlan: listPlan, latestToolActivity: latestToolActivity)
        return state.planIsInProgress && latestToolActivity != nil
    }

    private var providerIcon: String {
        ProviderConstants.icon(for: session.provider, providerLabel: session.providerLabel)
    }

    private var providerColor: Color {
        ProviderConstants.color(for: session.provider, providerLabel: session.providerLabel)
    }

    /// Resolved identity of the MODEL in use (glyph, colour, label) — e.g. a
    /// Kimi-via-env-swap session inside the Claude Code harness resolves to
    /// ☾ teal "Kimi K3", not the harness identity. nil when the model is
    /// unknown → the row falls back to the harness icon/label.
    private var modelIdentity: ModelIdentity? {
        ModelIdentity.resolve(modelId: modelIdOverride) ?? ModelIdentity.resolve(modelId: session.model)
    }

    // MARK: - Presentation metrics

    private var iconSize: CGFloat { presentation.isLozenge ? 13 : 16 }
    private var iconWidth: CGFloat { presentation.isLozenge ? 20 : 28 }
    private var titleFont: Font { presentation.isLozenge ? .caption.weight(.semibold) : .body }
    private var detailFont: Font { presentation.isLozenge ? .caption2 : .caption }

    /// Text for the leading slot of the idle detail row: the model in use
    /// (e.g. "Opus 4.6", "Kimi K3") when one resolved, else the harness
    /// label. The leading icon is model-aligned too, so both slots agree.
    private var modelOrProviderName: String {
        modelIdentity?.label
            ?? session.modelDisplayName
            ?? ProviderConstants.label(for: session.provider, providerLabel: session.providerLabel)
    }

    public var body: some View {
        HStack(spacing: presentation.isLozenge ? 6 : 12) {
            // Selection checkmark
            if isSelectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
                    .uiKitIdentifier("UnifiedSessionRow.selectionCheckmark")
            }

            // Leading icon — tool icon while a tool activity event is
            // present (both toolStart and toolEnd); otherwise the model
            // family glyph (in the model's colour) when the model resolves,
            // falling back to the harness provider icon when it doesn't.
            VStack(spacing: 2) {
                let toolIcon: String? = latestToolActivity != nil
                    ? ToolIconMap.symbol(for: latestToolActivity?.toolNameForIcon)
                    : nil
                let toolLabel: String? = {
                    guard latestToolActivity != nil,
                          let name = latestToolActivity?.displayName,
                          name.count <= 5 else { return nil }
                    return name
                }()

                ZStack(alignment: .bottomTrailing) {
                    if let toolIcon {
                        Image(systemName: toolIcon)
                            .font(.system(size: iconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: iconWidth)
                            .contentTransition(.symbolEffect(.replace))
                            .uiKitIdentifier("UnifiedSessionRow.leadingIcon")
                    } else if let identity = modelIdentity {
                        // Model-aligned: family glyph + colour, matching the
                        // chat-stream respondent lozenges (web
                        // modelIdentity.ts) — keyed off the model, not the
                        // CLI harness that carried it.
                        Text(identity.glyph)
                            .font(.system(size: iconSize))
                            .foregroundStyle(identity.color)
                            .frame(width: iconWidth)
                            .uiKitIdentifier("UnifiedSessionRow.leadingIcon")
                    } else {
                        Image(systemName: providerIcon)
                            .font(.system(size: iconSize))
                            .foregroundStyle(providerColor)
                            .frame(width: iconWidth)
                            .contentTransition(.symbolEffect(.replace))
                            .uiKitIdentifier("UnifiedSessionRow.leadingIcon")
                    }

                    // Green dot = already open in Ripul. Meaningless in the
                    // top bar, where the session on screen is open by
                    // definition.
                    if session.isOpenInRipul && toolIcon == nil && !presentation.isLozenge {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: 4)
                            .uiKitIdentifier("UnifiedSessionRow.openIndicatorDot")
                    }
                }
                .animation(.easeInOut(duration: 0.175), value: toolIcon)

                // The label under the icon needs a second line the top-bar
                // pill doesn't have; there the tool name stays in the subtitle.
                if let toolLabel, !presentation.isLozenge {
                    Text(toolLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 32)
                        .uiKitIdentifier("UnifiedSessionRow.toolLabel")
                }
            }
            .frame(width: iconWidth)
            .animation(.easeInOut(duration: 0.175), value: latestToolActivity != nil)

            VStack(alignment: .leading, spacing: 3) {
                // Shared priority chain: in-progress plan > live tool call > completed plan > idle.
                let subtitleState = SessionSubtitleState.resolve(
                    activePlan: activePlan,
                    listPlan: listPlan,
                    latestToolActivity: latestToolActivity
                )

                // Whether the tool label is short enough to be shown under
                // the leading icon — when true, the subtitle tool lozenge
                // is suppressed to avoid duplication.
                let toolLabelShownUnderIcon: Bool = {
                    guard !presentation.isLozenge,
                          latestToolActivity != nil,
                          let name = latestToolActivity?.displayName else { return false }
                    return name.count <= 5
                }()

                // Decide which lozenge (if any) belongs on the subtitle line.
                let lozengeContent: SessionTitleLozenge.Content? = {
                    switch subtitleState {
                    case .planInProgress(let plan): return .plan(plan)
                    case .toolActivity(let activity) where !toolLabelShownUnderIcon: return .tool(activity)
                    case .planCompleted(let plan): return .plan(plan)
                    default: return nil
                    }
                }()

                let subtitleDetail = subtitleState.detailText

                // When a plan is driving the row, a concurrent tool call gets
                // its own additional line below the activeForm.
                let inlineToolActivity: AgentActivityEvent? = {
                    guard subtitleState.planIsInProgress else { return nil }
                    return latestToolActivity
                }()

                let subtitleKey = subtitleState.subtitleKey(inlineToolActivity: inlineToolActivity)

                // Title row: name only (truncates). Unread is carried by the
                // row's shading, not by the title — the title is how you find
                // a session, and re-weighting it made the list read as two
                // different typographic ranks rather than one list.
                Text(session.title)
                    .font(titleFont)
                    .lineLimit(titleLineLimit)
                    .truncationMode(.tail)
                    .uiKitIdentifier("UnifiedSessionRow.title")

                // Subtitle row: lozenge (if any) at the start, then the
                // detail text for the current state, or provider/project/
                // branch/time as the default fallback.
                Group {
                    if lozengeContent != nil || subtitleDetail != nil {
                        HStack(spacing: 6) {
                            if let lozengeContent {
                                SessionTitleLozenge(content: lozengeContent)
                            }
                            if let subtitleDetail {
                                Text(subtitleDetail)
                                    .font(detailFont)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .contentTransition(.opacity)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.detailText")
                            }
                        }
                    } else {
                        HStack(spacing: 4) {
                            // Machine icon at the start of the detail row, before the CLI name.
                            if let machineIcon {
                                Image(systemName: machineIcon)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.machineIcon")
                            }
                            Text(modelOrProviderName)
                                .font(detailFont)
                                .foregroundStyle(modelIdentity?.color ?? providerColor)
                                .lineLimit(1)
                                // The most identifying fact on the line: in the
                                // top bar's ~150pt slot the project and branch
                                // truncate before the model name does.
                                .layoutPriority(1)
                                .uiKitIdentifier("UnifiedSessionRow.subtitle.providerName")

                            if let project = session.projectName, !hideProjectName {
                                Text("·").foregroundStyle(.secondary)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.projectSeparator")
                                Text(project)
                                    .font(detailFont)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.projectName")
                            }

                            if let branch = session.gitBranch {
                                Text("·").foregroundStyle(.secondary)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.branchSeparator")
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.branchIcon")
                                Text(branch)
                                    .font(detailFont)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.branchName")
                            }

                            // Tag lozenges — after the repo/branch label. Left
                            // out of the pill: user-authored labels are how you
                            // pick a session OUT of a list, and they'd eat the
                            // width the model and project need.
                            if !presentation.isLozenge {
                                // Plan link tags are machine identity — the
                                // plan screen renders that relationship; the
                                // row never shows the raw key.
                                ForEach(PlanTagConvention.userTags(session.tags), id: \.self) { tag in
                                    TagLozenge(text: tag)
                                }
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                    }
                }
                .animation(.easeInOut(duration: 0.175), value: subtitleKey)

                // Third row: only when a plan is driving the row AND a tool
                // call is live underneath it. The top-bar pill is two lines
                // tall, so it keeps the plan line and drops this one.
                if let inlineToolActivity, !presentation.isLozenge {
                    HStack(spacing: 6) {
                        if !toolLabelShownUnderIcon {
                            SessionTitleLozenge(content: .tool(inlineToolActivity))
                        }
                        if let toolDetail = inlineToolActivity.detail, !toolDetail.isEmpty {
                            Text(toolDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .contentTransition(.opacity)
                                .uiKitIdentifier("UnifiedSessionRow.inlineTool.detailText")
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.175), value: hasInlineToolActivity)

            // List-only trailing chrome. The top-bar pill hugs its content and
            // sits between two 44pt buttons — there is no room for a running
            // indicator, tool action buttons or a timestamp, and the chat
            // screen states all three itself.
            if !presentation.isLozenge {
                Spacer()
                listTrailingChrome
            }
        }
        .padding(.vertical, presentation.isLozenge ? 0 : 2)
        .background(unreadShading)
        .uiKitIdentifier("UnifiedSessionRow.container")
    }

    /// Unread, as a band behind the whole row.
    ///
    /// Bled past the content on both axes so it reads as the ROW being tinted
    /// rather than a box drawn around the text. Kept faint (and skipped in the
    /// lozenge presentation, which is a top-bar pill rather than a list row)
    /// so it layers under selection and hover instead of fighting them.
    @ViewBuilder
    private var unreadShading: some View {
        if isUnread && !presentation.isLozenge {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .padding(.horizontal, -10)
                .padding(.vertical, -4)
                .uiKitIdentifier("UnifiedSessionRow.unreadShading")
        }
    }

    @ViewBuilder
    private var listTrailingChrome: some View {
        Group {
            // Per-session busy / awaiting-input indicator.
            switch phase {
            case .running:
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityLabel("Running")
                    .uiKitIdentifier("UnifiedSessionRow.phaseIndicator.running")
            case .awaitingInput:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Waiting for your input")
                    .uiKitIdentifier("UnifiedSessionRow.phaseIndicator.awaitingInput")
            case .idle, .completed, .failed, .none:
                EmptyView()
            }

            // Session-row action buttons declared by tools
            ForEach(sessionActions) { action in
                Button {
                    onSessionAction?(action)
                } label: {
                    HStack(spacing: 4) {
                        if let icon = action.icon {
                            Image(systemName: icon)
                                .font(.caption2.weight(.semibold))
                                .uiKitIdentifier("UnifiedSessionRow.actionButton.icon")
                        }
                        Text(action.label)
                            .font(.caption2.weight(.semibold))
                            .uiKitIdentifier("UnifiedSessionRow.actionButton.label")
                    }
                    .foregroundStyle(action.style == .primary ? Color.accentColor : action.style == .destructive ? Color.red : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .modifier(GlassCapsuleBackground())
                }
                .uiKitIdentifier("UnifiedSessionRow.actionButton")
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            if isArchiving {
                HStack(spacing: 6) {
                    Text("Archiving")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .uiKitIdentifier("UnifiedSessionRow.archivingLabel")
                    ProgressView().controlSize(.small)
                        .uiKitIdentifier("UnifiedSessionRow.archivingSpinner")
                }
                .uiKitIdentifier("UnifiedSessionRow.archivingIndicator")
            } else if isDeleting {
                HStack(spacing: 6) {
                    Text(isDeletingFromHost ? "Removing from host" : "Removing")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .uiKitIdentifier("UnifiedSessionRow.deletingLabel")
                    ProgressView().controlSize(.small)
                        .uiKitIdentifier("UnifiedSessionRow.deletingSpinner")
                }
                .uiKitIdentifier("UnifiedSessionRow.deletingIndicator")
            } else {
                // Keep the time text in layout while opening (invisible) so
                // the trailing slot's width is unchanged when the spinner
                // replaces it — otherwise the phase indicator to the left
                // jumps horizontally as the narrower spinner appears.
                ZStack {
                    RelativeTimeText(date: effectiveLastActive)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .opacity(isOpening ? 0 : 1)
                        .accessibilityHidden(isOpening)
                        .uiKitIdentifier("UnifiedSessionRow.timeText")
                    if isOpening {
                        ProgressView().controlSize(.small)
                            .uiKitIdentifier("UnifiedSessionRow.openingSpinner")
                    }
                }
            }
        }
    }
}
