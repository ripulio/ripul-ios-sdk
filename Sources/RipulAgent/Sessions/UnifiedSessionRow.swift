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
                    .font(.ripulIcon(.caption2))
                    .contentTransition(.symbolEffect(.replace))
                    .uiKitIdentifier("SessionTitleLozenge.icon")
            }
            Text(label)
                .font(.ripul(.caption2).monospacedDigit())
                .lineLimit(1)
                .contentTransition(.opacity)
                .uiKitIdentifier("SessionTitleLozenge.label")
        }
        .foregroundStyle(.ripul(.textSecondary))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.ripul(.textSecondary).opacity(0.12))
        )
        .uiKitIdentifier("SessionTitleLozenge.container")
        // No animation on a new tool or count: see the row's subtitle.
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
            .font(.ripul(.caption2, weight: .semibold))
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

    var sessionStore: SessionListStore
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
    /// When true, the branch is omitted from the detail row — used for a
    /// started chat on the same branch as the chat it sits under.
    var hideBranch: Bool = false
    var isSelectMode: Bool = false
    var isSelected: Bool = false
    /// Another person is in this chat. Shown as a group icon under the time.
    var isGroupChat: Bool = false
    /// On a team's Mac, shared with the team by whoever started it.
    var isTeamShared: Bool = false
    /// Lines the title may occupy. 1 everywhere except the agent screen's
    /// EXPANDED title lozenge, where showing more of a long title is the
    /// point of expanding — and growing this row's line count (rather than
    /// swapping in a different title view) is what keeps the expansion a
    /// height animation on one view instead of a snap between two.
    var titleLineLimit: Int = 1
    /// How far under the chat that started it this row sits: 0 for a row by
    /// itself or at the head of a family. The list decides; see `SessionFamilies`.
    var familyDepth: Int = 0
    /// For a chat that has started others: how many, whether the person has
    /// put them away, and whether one of those put away is working or asking.
    var startedChats: Int = 0
    var startedChatsClosed: Bool = false
    var startedChatsNeedLooking: Bool = false
    /// The chats put away under this one. A family put away is one row, so
    /// this row says what theirs would: that one is mid-turn, and when one of
    /// them was last active.
    var startedChatsPutAway: [UnifiedSession] = []
    /// Tapping the row's icon puts the started chats away, or brings them back.
    var onToggleStartedChats: (() -> Void)? = nil
    var onSessionAction: ((SessionRowAction) -> Void)? = nil
    /// What is waiting on you in this chat, worked out by the list and handed
    /// in. A row in the session `List` was not redrawn when the store changed,
    /// so a mention showed only once the filter rebuilt the rows; a value
    /// that changes always redraws. Nil `attention` with `attentionGiven`
    /// false means the row reads the store itself (the other screens).
    var attention: PendingAgentQuestion? = nil
    var attentionGiven = false

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
        hideBranch: Bool = false,
        isSelectMode: Bool = false,
        isSelected: Bool = false,
        isGroupChat: Bool = false,
        isTeamShared: Bool = false,
        titleLineLimit: Int = 1,
        familyDepth: Int = 0,
        startedChats: Int = 0,
        startedChatsClosed: Bool = false,
        startedChatsNeedLooking: Bool = false,
        startedChatsPutAway: [UnifiedSession] = [],
        onToggleStartedChats: (() -> Void)? = nil,
        onSessionAction: ((SessionRowAction) -> Void)? = nil,
        attention: PendingAgentQuestion?? = .none
    ) {
        if case .some(let given) = attention {
            self.attention = given
            self.attentionGiven = true
        }
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
        self.hideBranch = hideBranch
        self.isSelectMode = isSelectMode
        self.isSelected = isSelected
        self.isGroupChat = isGroupChat
        self.isTeamShared = isTeamShared
        self.titleLineLimit = titleLineLimit
        self.familyDepth = familyDepth
        self.startedChats = startedChats
        self.startedChatsClosed = startedChatsClosed
        self.startedChatsNeedLooking = startedChatsNeedLooking
        self.startedChatsPutAway = startedChatsPutAway
        self.onToggleStartedChats = onToggleStartedChats
        self.onSessionAction = onSessionAction
    }

    /// How many of the chats put away under this one are mid-turn, each read
    /// as this row's own is, so a head and the rows it stands for cannot
    /// disagree.
    private var startedChatsRunning: Int {
        startedChatsPutAway.reduce(0) { sessionStore.isRunning($1) ? $0 + 1 : $0 }
    }

    /// Whether this session's last agent turn has gone unlooked-at.
    ///
    /// Deliberately NOT derived from `phase`, and now the row's only
    /// "your move" signal: the phase says the agent is waiting on you, this
    /// says you have not seen what it said. A session you opened, read, and
    /// left without replying is still awaiting input but is no longer unread
    /// — which is the distinction worth the row's ink.
    ///
    /// Every alias is offered because CLI sessions are keyed inconsistently
    /// (`cli_<uuid>` live, bare uuid from the scanner) and matchKeys is exactly
    /// the set of names this row answers to.
    private var pendingAttention: PendingAgentQuestion? {
        attentionGiven ? attention : PendingQuestionStore.shared.first(anyOf: session.attentionKeys)
    }

    /// Bold for an unread reply, and for a question or mention waiting on you.
    private var isUnread: Bool {
        sessionStore.isUnread(anyOf: session.readStateKeys)
            || pendingAttention != nil
    }

    private var isPinned: Bool {
        sessionStore.isPinned(anyOf: session.readStateKeys)
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
    ///
    /// With its started chats put away, the time is the family's: that of
    /// whichever chat in it was active last. Each is read through its own
    /// cell, as this row's is, so the time moves with a chat that is working.
    private var effectiveLastActive: Date {
        var best = liveLastActive(of: session)
        for started in startedChatsPutAway { best = max(best, liveLastActive(of: started)) }
        if let t = cachedLastActive { best = max(best, t) }
        if let t = PendingQuestionStore.shared.latestMentionAt(anyOf: session.attentionKeys) { best = max(best, t) }
        if let pendingAttention { best = max(best, Date(timeIntervalSince1970: pendingAttention.createdAt / 1000)) }
        return best
    }

    /// A chat's scanned time, moved on by a live event under any of its names.
    private func liveLastActive(of session: UnifiedSession) -> Date {
        var best = session.lastUsed
        if let ripul = session.ripulSession {
            if let t = sessionStore.lastActive(for: ripul.id) { best = max(best, t) }
            if let t = sessionStore.lastActive(for: ripul.sourceChatId) { best = max(best, t) }
        }
        for key in session.matchKeys {
            if let t = sessionStore.lastActive(for: key) { best = max(best, t) }
        }
        return best
    }

    /// Session-row action buttons declared by tools (e.g. "Show Plan").
    private var sessionActions: [SessionRowAction] {
        guard let ripul = session.ripulSession else { return [] }
        return sessionStore.sessionActions(for: ripul.id)
            ?? sessionStore.sessionActions(for: ripul.sourceChatId)
            ?? []
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
    private var titleFont: Font {
        presentation.isLozenge ? .ripul(.caption, weight: .semibold) : .ripul(.body, weight: isUnread ? .bold : .regular)
    }
    private var detailFont: Font { presentation.isLozenge ? .ripul(.caption2) : .ripul(.caption) }

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
                    .font(.ripulIcon(.title3))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.ripul(.textSecondary))
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
                    .uiKitIdentifier("UnifiedSessionRow.selectionCheckmark")
            }

            // A chat another agent started hangs under the chat that started
            // it. The turn of the arrow says so, where the title used to.
            if familyDepth > 0, !presentation.isLozenge {
                Image(systemName: "arrow.turn.down.right")
                    .font(.ripulIcon(.caption, weight: .medium))
                    .foregroundStyle(.ripul(.textTertiary))
                    .frame(width: CGFloat(familyDepth) * 14, alignment: .trailing)
                    .accessibilityLabel("Under the chat above")
                    .uiKitIdentifier("UnifiedSessionRow.familyConnector")
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
                            .font(.ripulIcon(size: iconSize))
                            .foregroundStyle(.ripul(.textSecondary))
                            .frame(width: iconWidth)
                            .contentTransition(.symbolEffect(.replace))
                            .uiKitIdentifier("UnifiedSessionRow.leadingIcon")
                    } else if let identity = modelIdentity {
                        // Model-aligned: family glyph + colour, matching the
                        // chat-stream respondent lozenges (web
                        // modelIdentity.ts) — keyed off the model, not the
                        // CLI harness that carried it.
                        Text(identity.glyph)
                            .font(.ripul(size: iconSize))
                            .foregroundStyle(identity.color)
                            .frame(width: iconWidth)
                            .uiKitIdentifier("UnifiedSessionRow.leadingIcon")
                    } else {
                        Image(systemName: providerIcon)
                            .font(.ripulIcon(size: iconSize))
                            .foregroundStyle(providerColor)
                            .frame(width: iconWidth)
                            .contentTransition(.symbolEffect(.replace))
                            .uiKitIdentifier("UnifiedSessionRow.leadingIcon")
                    }

                    // Unread reply badge, using the same read state as the
                    // bold title. The top-bar pill is the chat being read.
                    // One slot: unread outranks pinned, because it asks for
                    // action and a pin is already shown by the row's position.
                    if !presentation.isLozenge {
                        if let pending = pendingAttention {
                            Image(systemName: pending.isMention ? "at.circle.fill" : "questionmark.bubble.fill")
                                .font(.ripulIcon(size: 12, weight: .medium))
                                .foregroundStyle(.tint)
                                .background(.background, in: RoundedRectangle(cornerRadius: 2))
                                .offset(x: 4, y: 4)
                                .accessibilityLabel(pending.isMention
                                    ? "\(pending.fromName ?? "Someone") mentioned you" : "Needs your answer")
                                .uiKitIdentifier("UnifiedSessionRow.questionIndicator")
                        } else if isUnread {
                            Image(systemName: "envelope")
                                .font(.ripulIcon(size: 11, weight: .medium))
                                // .primary, not .white: the backing is
                                // .background, which is white in light mode.
                                .foregroundStyle(.ripul(.text))
                                .background(.background, in: RoundedRectangle(cornerRadius: 2))
                                .offset(x: 4, y: 4)
                                .accessibilityLabel("Unread reply")
                                .uiKitIdentifier("UnifiedSessionRow.unreadIndicatorEnvelope")
                        } else if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.ripulIcon(size: 10, weight: .medium))
                                .foregroundStyle(.ripul(.text))
                                .background(.background, in: RoundedRectangle(cornerRadius: 2))
                                .offset(x: 4, y: 4)
                                .accessibilityLabel("Pinned")
                                .uiKitIdentifier("UnifiedSessionRow.pinnedIndicator")
                        }
                    }
                }

                // The label under the icon needs a second line the top-bar
                // pill doesn't have; there the tool name stays in the subtitle.
                if let toolLabel, !presentation.isLozenge {
                    Text(toolLabel)
                        .font(.ripul(size: 8, weight: .medium))
                        .foregroundStyle(.ripul(.textSecondary))
                        .lineLimit(1)
                        .frame(width: 32)
                        .uiKitIdentifier("UnifiedSessionRow.toolLabel")
                }
            }
            .frame(width: iconWidth)
            .modifier(StartedChatsToggle(
                count: startedChats, isClosed: startedChatsClosed,
                // Selecting rows owns the tap; the top-bar pill has no family to show.
                action: startedChats > 0 && !isSelectMode && !presentation.isLozenge ? onToggleStartedChats : nil))

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

                // Unread replies use a bold title alongside the envelope.
                HStack(spacing: 6) {
                    Text(session.title).ripulText()
                        .font(titleFont)
                        .lineLimit(titleLineLimit)
                        .truncationMode(.tail)
                        .uiKitIdentifier("UnifiedSessionRow.title")
                    // Started chats that are put away: how many, so the row
                    // does not look like a chat by itself. Tinted when one of
                    // them is working or asking.
                    if startedChatsClosed, startedChats > 0, !presentation.isLozenge {
                        let tint: Color = startedChatsNeedLooking ? .accentColor : Color.ripul(.textSecondary)
                        Text("+\(startedChats)")
                            .font(.ripul(.caption2, weight: .semibold).monospacedDigit())
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tint.opacity(0.14)))
                            .fixedSize()
                            .accessibilityLabel("\(startedChats) \(startedChats == 1 ? "chat" : "chats") under it put away")
                            .uiKitIdentifier("UnifiedSessionRow.startedChatsCount")
                    }
                    let typingNames = session.ripulSession?.typingNames ?? []
                    let isTyping = !typingNames.isEmpty
                    let personName = isTyping ? typingNames.joined(separator: ", ") : session.ripulSession?.latestReplyAuthorName
                    if let author = personName, !author.isEmpty {
                        Spacer(minLength: 0)
                        SessionReplyAuthorLayout {
                            HStack(spacing: 2) {
                                Text(author)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if isTyping {
                                    Text("…").fixedSize()
                                }
                            }
                            .font(.ripul(.caption2, weight: .semibold))
                            .foregroundStyle(isTyping ? Color.accentColor : Color.ripul(.textSecondary))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background {
                                Capsule()
                                    .fill(isTyping ? Color.accentColor.opacity(0.18) : Color.ripul(.textSecondary).opacity(0.12))
                                    .shadow(color: Color.accentColor.opacity(isTyping ? 0.55 : 0), radius: 5)
                            }
                        }
                        .layoutPriority(1)
                        .accessibilityLabel(isTyping ? "\(author) typing" : "Latest reply from \(author)")
                        .uiKitIdentifier("UnifiedSessionRow.replyAuthorLozenge")
                    }
                }

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
                                    .foregroundStyle(.ripul(.textSecondary))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .contentTransition(.opacity)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.detailText")
                            }
                        }
                    } else {
                        HStack(spacing: 4) {
                            // Started by a chat that is not in the list (archived, filtered
                            // out, or on another Mac): with no row to sit under, say whose it is.
                            if familyDepth == 0, !presentation.isLozenge, let starter = session.startedBy?.title {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.ripulIcon(.caption2))
                                    .foregroundStyle(.ripul(.textSecondary))
                                    .accessibilityLabel("Started by")
                                Text(starter)
                                    .font(detailFont)
                                    .foregroundStyle(.ripul(.textSecondary))
                                    .lineLimit(1)
                                    // Whose chat it is outranks its folder and branch for the room there is.
                                    .layoutPriority(0.5)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.startedBy")
                                Text("·").foregroundStyle(.ripul(.textSecondary))
                            }
                            // Machine icon at the start of the detail row, before the CLI name.
                            if let machineIcon {
                                Image(systemName: machineIcon)
                                    .font(.ripulIcon(.caption2))
                                    .foregroundStyle(.ripul(.textSecondary))
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

                            // The starter's name takes the folder's place: the line has room for one of them.
                            if let project = session.projectName, !hideProjectName,
                               !(familyDepth == 0 && !presentation.isLozenge && session.startedBy?.title != nil) {
                                Text("·").foregroundStyle(.ripul(.textSecondary))
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.projectSeparator")
                                Text(project)
                                    .font(detailFont)
                                    .foregroundStyle(.ripul(.textSecondary))
                                    .lineLimit(1)
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.projectName")
                            }

                            if let branch = session.gitBranch, !hideBranch {
                                Text("·").foregroundStyle(.ripul(.textSecondary))
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.branchSeparator")
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.ripulIcon(.caption2))
                                    .foregroundStyle(.ripul(.textSecondary))
                                    .uiKitIdentifier("UnifiedSessionRow.subtitle.branchIcon")
                                Text(branch)
                                    .font(detailFont)
                                    .foregroundStyle(.ripul(.textSecondary))
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
                // A new tool swaps the icon, the lozenge and this line at once,
                // not in 0.175 s animations. Each of those was about 20 frames
                // of SwiftUI layout on a 120 Hz phone, for every tool event, in
                // the list row and again in the chat's top-bar pill (whose
                // width change morphed the bar's glass too). Peter's phone,
                // 18 October 2026: 43-83 tool events a minute, and one row and
                // the hidden top bar changing 7-13 times a second.

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
                                .font(.ripul(.caption))
                                .foregroundStyle(.ripul(.textSecondary))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .contentTransition(.opacity)
                                .uiKitIdentifier("UnifiedSessionRow.inlineTool.detailText")
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: presentation.isLozenge ? nil : .infinity, alignment: .leading)

            // List-only trailing chrome. The top-bar pill hugs its content and
            // sits between two 44pt buttons — there is no room for a running
            // indicator, tool action buttons or a timestamp, and the chat
            // screen states all three itself.
            if !presentation.isLozenge {
                listTrailingChrome
            }
        }
        .padding(.vertical, presentation.isLozenge ? 0 : 2)
        .uiKitIdentifier("UnifiedSessionRow.container")
    }

    /// SF Symbol for the busy indicator: the icon of the machine the chat is
    /// running on. `machineIcon` is only the user's own pick, so a host
    /// without one gets the default host icon, and a chat with no host is
    /// running on this device.
    private var runningIndicatorIcon: String {
        if let machineIcon { return machineIcon }
        if session.machineName != nil { return RemoteMachine.defaultHostIconName }
        #if os(iOS)
        if ProcessInfo.processInfo.isMacCatalystApp { return RemoteMachine.defaultHostIconName }
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #else
        return RemoteMachine.defaultHostIconName
        #endif
    }

    /// The busy indicator, parked UNDER the timestamp instead of beside it.
    ///
    /// Stacked because it is the trailing column's *second* fact, not a
    /// competitor for the row's horizontal run — every point it took there was
    /// taken from the title and the tool lozenges, which are what you actually
    /// read the row for. The timestamp is already the narrowest thing on the
    /// right, so the icon fits under it for free.
    ///
    /// The slot keeps its height whether or not the glyph is in it: a turn
    /// starting or ending must not resize the row, or a list of live sessions
    /// twitches every time one of them changes state.
    ///
    /// Unread replies are indicated by the bold title and envelope; a chat
    /// awaiting input may already have been read.
    ///
    /// A group chat's icon shares the slot at its trailing edge, so it sits
    /// under the time and holds still while the busy icon comes and goes
    /// beside it.
    ///
    /// A chat whose started chats are put away is busy while one of them is:
    /// their rows are not there to say so, and a family that is put away is
    /// one row.
    @ViewBuilder
    private var runningIndicatorSlot: some View {
        // The live phase of a chat open here; for one that is not, what its Mac's list said.
        let ownRunning = sessionStore.isRunning(session)
        let startedRunning = startedChatsRunning
        let isRunning = ownRunning || startedRunning > 0
        HStack(spacing: 4) {
            if isRunning {
                // Core Animation, not a SwiftUI symbol effect: see
                // RenderServerPulsingSymbol for the per-frame cost that has.
                RunningIndicatorSymbol(systemName: runningIndicatorIcon)
                    .accessibilityElement()
                    .accessibilityLabel(ownRunning ? "Running"
                        : "\(startedRunning) \(startedRunning == 1 ? "chat" : "chats") under it running")
                    .transition(.opacity)
                    .uiKitIdentifier("UnifiedSessionRow.phaseIndicator.running")
            }
            if isGroupChat {
                Image(systemName: "person.2.fill")
                    .font(.ripulIcon(.caption2))
                    .foregroundStyle(.ripul(.textTertiary))
                    .accessibilityLabel("Group chat")
                    .uiKitIdentifier("UnifiedSessionRow.groupChatIcon")
            }
            if isTeamShared {
                Image(systemName: "person.3.fill")
                    .font(.ripulIcon(.caption2))
                    .foregroundStyle(.ripul(.textTertiary))
                    .accessibilityLabel("Shared with team")
                    .uiKitIdentifier("UnifiedSessionRow.teamSharedIcon")
            }
        }
        .frame(height: 16)
        .animation(.easeInOut(duration: 0.175), value: isRunning)
    }

    @ViewBuilder
    private var listTrailingChrome: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 12) {
                // Session-row action buttons declared by tools
                ForEach(sessionActions) { action in
                    Button {
                        onSessionAction?(action)
                    } label: {
                        HStack(spacing: 4) {
                            if let icon = action.icon {
                                Image(systemName: icon)
                                    .font(.ripulIcon(.caption2, weight: .semibold))
                                    .uiKitIdentifier("UnifiedSessionRow.actionButton.icon")
                            }
                            Text(action.label)
                                .font(.ripul(.caption2, weight: .semibold))
                                .uiKitIdentifier("UnifiedSessionRow.actionButton.label")
                        }
                        .foregroundStyle(action.style == .primary ? Color.accentColor : action.style == .destructive ? Color.ripul(.danger) : Color.ripul(.textSecondary))
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
                            .font(.ripul(.caption))
                            .foregroundStyle(.ripul(.warning))
                            .uiKitIdentifier("UnifiedSessionRow.archivingLabel")
                        ProgressView().controlSize(.small)
                            .uiKitIdentifier("UnifiedSessionRow.archivingSpinner")
                    }
                    .uiKitIdentifier("UnifiedSessionRow.archivingIndicator")
                } else if isDeleting {
                    HStack(spacing: 6) {
                        Text(isDeletingFromHost ? "Removing from host" : "Removing")
                            .font(.ripul(.caption))
                            .foregroundStyle(.ripul(.danger))
                            .uiKitIdentifier("UnifiedSessionRow.deletingLabel")
                        ProgressView().controlSize(.small)
                            .uiKitIdentifier("UnifiedSessionRow.deletingSpinner")
                    }
                    .uiKitIdentifier("UnifiedSessionRow.deletingIndicator")
                } else {
                    // Keep the time text in layout while opening (invisible) so
                    // the trailing slot's width is unchanged when the spinner
                    // replaces it — otherwise the whole row reflows around the
                    // narrower spinner as it appears.
                    ZStack {
                        RelativeTimeText(date: effectiveLastActive)
                            .font(.ripul(.caption2))
                            .foregroundStyle(.ripul(.textTertiary))
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

            runningIndicatorSlot
        }
    }
}

/// Makes the icon of a chat that has started others the switch for them: a tap
/// puts them away, another brings them back. A small chevron at the icon's
/// corner says which way it stands.
private struct StartedChatsToggle: ViewModifier {
    let count: Int
    let isClosed: Bool
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            Button(action: action) {
                content
                    // Where a disclosure chevron sits: before the icon, level with it.
                    .overlay(alignment: .leading) {
                        Image(systemName: "chevron.right")
                            .font(.ripulIcon(size: 8, weight: .bold))
                            .foregroundStyle(.ripul(.textSecondary))
                            .rotationEffect(.degrees(isClosed ? 0 : 90))
                            .offset(x: -8)
                            .animation(.easeInOut(duration: 0.2), value: isClosed)
                            .accessibilityHidden(true)
                    }
                    // The icon is 28 points wide: reach a finger's width around it.
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isClosed ? "Show" : "Hide") \(count) \(count == 1 ? "chat" : "chats") under it")
            .uiKitIdentifier("UnifiedSessionRow.startedChatsToggle")
        } else {
            content
        }
    }
}

/// The running indicator, pulsing only while the session list can be seen.
///
/// On an iPhone the list stays in place behind an open chat. Its indicators
/// pulsed there unseen, and one moving layer makes the render server compose
/// the whole screen every refresh: 32% of a core on a simulator, measured
/// 8 October 2026, with nothing else animating. A view of its own, so a change
/// re-evaluates the indicators and not the rows.
private struct RunningIndicatorSymbol: View {
    let systemName: String
    @Environment(\.ripulSessionListCanBeSeen) private var listCanBeSeen

    var body: some View {
        RenderServerPulsingSymbol(systemName: systemName, color: .accentColor, animates: listCanBeSeen)
    }
}

private struct SessionListCanBeSeenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while something covers the whole session list (a chat, on a
    /// narrow screen). Looping decorations in the list stop for that long.
    var ripulSessionListCanBeSeen: Bool {
        get { self[SessionListCanBeSeenKey.self] }
        set { self[SessionListCanBeSeenKey.self] = newValue }
    }
}
