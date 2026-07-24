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

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.caption2)
                .contentTransition(.symbolEffect(.replace))
                .uiKitIdentifier("SessionTitleLozenge.icon")
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
@available(iOS 26.0, macOS 26.0, *)
struct TagLozenge: View {
    let text: String
    var body: some View {
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
struct UnifiedSessionRow: View {
    /// Row observes only the session-list leaf store so body re-runs are
    /// scoped to session-list data changes (activity, phases, todo states).
    @ObservedObject var sessionStore: SessionListStore
    let session: UnifiedSession
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
    var onSessionAction: ((SessionRowAction) -> Void)? = nil

    /// Live turn phase for this row. Reads `sessionStore.sessionPhases` at
    /// body-eval time — only sessions that are currently open as a Ripul
    /// tab have a phase (closed / offline JSONL rows return nil). Keyed by
    /// the tab's `sourceChatId`, which matches the `chatId` carried on
    /// lifecycle events.
    private var phase: AgentTurnPhase? {
        guard let sourceChatId = session.ripulSession?.sourceChatId else { return nil }
        return sessionStore.turnPhase(for: sourceChatId)
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

    private var providerName: String {
        ProviderConstants.label(for: session.provider, providerLabel: session.providerLabel)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Selection checkmark
            if isSelectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
                    .uiKitIdentifier("UnifiedSessionRow.selectionCheckmark")
            }

            // Leading icon — tool icon while a tool activity event is
            // present (both toolStart and toolEnd), otherwise machine icon
            // (in provider color) or provider icon.
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
                    Image(systemName: toolIcon ?? providerIcon)
                        .font(.system(size: 16))
                        .foregroundStyle(toolIcon != nil ? .secondary : providerColor)
                        .frame(width: 28)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.easeInOut(duration: 0.175), value: toolIcon)
                        .uiKitIdentifier("UnifiedSessionRow.leadingIcon")

                    // Green dot = already open in Ripul
                    if session.isOpenInRipul && toolIcon == nil {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: 4)
                            .uiKitIdentifier("UnifiedSessionRow.openIndicatorDot")
                    }
                }

                if let toolLabel {
                    Text(toolLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 32)
                        .uiKitIdentifier("UnifiedSessionRow.toolLabel")
                }
            }
            .frame(width: 28)
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
                    guard latestToolActivity != nil,
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

                // Title row: name only (truncates).
                Text(session.title)
                    .font(.body)
                    .lineLimit(1)
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
                                    .font(.caption)
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
                            Text(providerName)
                                .font(.caption)
                                .foregroundStyle(providerColor)
                                .uiKitIdentifier("UnifiedSessionRow.subtitle.providerName")

                            if let project = session.projectName, !hideProjectName {
                                Text("·").foregroundStyle(.secondary)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.projectSeparator")
                                Text(project)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.branchName")
                            }

                            // Tag lozenges — after the repo/branch label.
                            ForEach(session.tags, id: \.self) { tag in
                                TagLozenge(text: tag)
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.175), value: subtitleKey)

                // Third row: only when a plan is driving the row AND a tool
                // call is live underneath it.
                if let inlineToolActivity {
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

            Spacer()

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
            } else if isOpening {
                ProgressView().controlSize(.small)
                    .uiKitIdentifier("UnifiedSessionRow.openingSpinner")
            } else {
                RelativeTimeText(date: effectiveLastActive)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .uiKitIdentifier("UnifiedSessionRow.timeText")
            }
        }
        .padding(.vertical, 2)
        .uiKitIdentifier("UnifiedSessionRow.container")
    }
}
