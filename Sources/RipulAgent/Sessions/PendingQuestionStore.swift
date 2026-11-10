import Foundation
import Observation

/// An account's unanswered questions, independent of which chat is mounted or
/// has been read. One that came with how it is answered is answered in the
/// Waiting on You screen (WaitingOnYou.swift); any other in its chat.
public struct PendingAgentQuestion: Codable, Equatable, Identifiable {
    public let chatId: String
    public let questionId: String
    public let title: String
    public let question: String
    public let blocking: Int
    public let createdAt: Double
    public let expiresAt: Double?
    /// "mention" when a person @'d this account (questionId is the message);
    /// "question", or nil from an older server, for an agent's question.
    public var kind: String? = nil
    /// Who mentioned this account.
    public var fromName: String? = nil
    /// "owner" for a permission request only this account, the chat's owner,
    /// may answer. The Waiting on You screen comes forward for one as it
    /// arrives, and sends the answer to `machineId`, the Mac that asked.
    public var answerPolicy: String? = nil
    /// How it is answered, for a question in this account's own chat: its
    /// choices, whether several may be chosen, typed words or a date.
    public var options: [PendingQuestionOption]? = nil
    public var multiSelect: Bool? = nil
    public var allowsText: Bool? = nil
    public var passwordInput: Bool? = nil
    public var dateInput: PendingQuestionDateInput? = nil
    public var header: String? = nil
    public var machineId: String? = nil
    public var threadId: String? = nil
    public var actionId: String? = nil
    public var id: String { chatId + ":" + questionId }
    public var isMention: Bool { kind == "mention" }
    /// A question macOS is asking on one of the owner's Macs (WaitingDialogNotifier.swift), which has no chat.
    public var isMacDialog: Bool { chatId.hasPrefix("mac-dialog:") }
    /// The machine id encoded in a `mac-dialog:<machineId>` chat id.
    public var macDialogMachineId: String? {
        guard isMacDialog else { return nil }
        let id = String(chatId.dropFirst("mac-dialog:".count))
        return id.isEmpty ? nil : id
    }
    /// A yes or no one of the owner's Macs asks about itself (a Trainyard readiness need, such as a diverged
    /// checkout to reset), published by that Mac's host page (fleetAlerts.ts). No chat: the app answers it
    /// from the Mac's live need (FleetAsk.swift).
    public var isFleetAsk: Bool { chatId.hasPrefix("mac-fleet:") }
    /// A permission request: an owner approval card, by its policy or, from an older server, its key.
    public var isPermission: Bool { !isMention && (answerPolicy == "owner" || questionId.hasPrefix("owner_browser_access_")) }
    /// A password or secret elicitation card whose input must be masked and never echoed.
    public var isPassword: Bool { passwordInput == true || questionId.hasPrefix("owner_browser_access_secret_") }
    /// The agent that asked has stopped waiting, and an answer still reaches it: a question it did not
    /// stop for, or a Claude question or permission request whose call was handed back. Claude's calls go
    /// back after about four minutes (CLI_QUESTION_HANDOFF_MS, 255 s) and the card stays open: a late
    /// answer starts the agent's next turn (lateAnswers.ts). Nothing closes one by age (Peter, 28 October
    /// 2026: it "should not time out").
    public func agentMovedOn(now: Date = Date()) -> Bool {
        guard !isMention, !isMacDialog, !isFleetAsk else { return false }
        if blocking == 0 { return true }
        let handedBack = questionId.hasPrefix("cli_ask_user_") || isPermission
        return handedBack && now.timeIntervalSince1970 * 1000 - createdAt > 5 * 60_000
    }
    /// It came with how it is answered and where the answer goes, so it can be answered where it is shown.
    public var isAnswerableHere: Bool {
        guard !isMention, !isMacDialog, !isFleetAsk else { return false }
        let form = !(options ?? []).isEmpty || allowsText == true || isPassword || dateInput != nil
        // A permission request's ids follow from its key; any other question's come with it.
        return form && (isPermission || (threadId?.isEmpty == false && actionId?.isEmpty == false))
    }
}

/// One choice, as its card offers it. Its answer is its value, or the label when it has none.
public struct PendingQuestionOption: Codable, Equatable, Hashable {
    public let label: String
    public let description: String?
    public var value: String? = nil
    public var answer: String { value ?? label }
}

/// A question's date picker. Dates are local days ("2026-10-30") or local times ("2026-10-30T14:05").
public struct PendingQuestionDateInput: Codable, Equatable, Hashable {
    public var includeTime: Bool? = nil
    public var minDate: String? = nil
    public var maxDate: String? = nil
    public var defaultDate: String? = nil
}

@MainActor @Observable
public final class PendingQuestionStore {
    public static let shared = PendingQuestionStore()
    public private(set) var questions: [PendingAgentQuestion] = [] {
        didSet { noteWaitingCount() }
    }
    /// How many items wait (`waiting.count`), assigned only when it changes: a
    /// badge reads this, not the list. The shell's tab bar read `waiting` for
    /// its badge, so every change to any question (a push, a refresh, a
    /// reading) redrew the whole shell, Home and its lists with it (120 ms on
    /// Peter's Duo, 5 November 2026; docs/main-thread.md, rule 4).
    public private(set) var waitingCount = 0
    public private(set) var accountId: String?
    private var mentionActivity: [String: Double] = [:]
    @ObservationIgnored private var tokenProvider: (() -> String?)?
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    /// When the list was last read from the server: the Waiting on You screen waits for a fresh list before it comes forward.
    public private(set) var refreshedAt: Date?
    @ObservationIgnored public var visibleChatId: String?
    @ObservationIgnored public var openQuestion: ((PendingAgentQuestion) -> Void)?
    @ObservationIgnored private var dismissed: [PendingAgentQuestion] = []
    @ObservationIgnored private var firstByCanonicalChatId: [String: PendingAgentQuestion] = [:]
    @ObservationIgnored private var mentionIdsByCanonicalChatId: [String: Set<String>] = [:]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func configure(accountId: String?, tokenProvider: @escaping () -> String?) {
        self.tokenProvider = tokenProvider
        guard self.accountId != accountId else { return }
        refreshTask?.cancel()
        refreshTask = nil
        self.accountId = accountId
        questions = []
        firstByCanonicalChatId = [:]
        mentionIdsByCanonicalChatId = [:]
        mentionActivity = accountId.flatMap { defaults.dictionary(forKey: "ripul.mentionActivity.\($0)") as? [String: Double] } ?? [:]
        dismissed = accountId.flatMap { defaults.data(forKey: "ripul.dismissedQuestions.\($0)") }
            .flatMap { try? JSONDecoder().decode([PendingAgentQuestion].self, from: $0) } ?? []
        if let accountId, let data = defaults.data(forKey: cacheKey(accountId)),
           let cached = try? JSONDecoder().decode([PendingAgentQuestion].self, from: data) {
            replace(cached)
        }
    }

    /// True when any item is a mention, so the list says "attention", not "answer".
    public var hasMentions: Bool { waiting.contains(where: \.isMention) }

    /// Everything waiting on this account: what the Waiting on You screen shows and the Agents screen counts.
    public var waiting: [PendingAgentQuestion] { questions + previewItems }

    /// The open permission requests that come with their choices, oldest first: the Waiting on You screen
    /// comes forward for each as it arrives. One without them (asked before requests carried them) is never
    /// brought forward as a link to its chat (Peter, 29 October 2026: "permissions need to be surfaced outside
    /// the chat, not just a link to it inside the chat"): the Mac that asked it asks it again with its choices
    /// (browserAccessPrompt.settleOwnerApprovals), and that one comes forward.
    public var permissionRequests: [PendingAgentQuestion] { waiting.filter { $0.isPermission && $0.isAnswerableHere } }

    /// What brings the Waiting on You screen forward as it arrives: those permission requests, and macOS
    /// questions on one of the owner's Macs. Only a person can answer one (at the Mac, or from the live
    /// dialog, MacDialogPanel), and whatever asked for it waits unseen: Gatekeeper's "Open ipsw?" on the
    /// Studio reached the account's list twice and was never put in front of Peter (1 November 2026).
    public var broughtForward: [PendingAgentQuestion] {
        waiting.filter { ($0.isPermission && $0.isAnswerableHere) || $0.isMacDialog }
    }

    /// A question that was answered, or that nothing waits for any more: let it
    /// go here and in the account's list, as a dismissal does.
    public func settle(_ question: PendingAgentQuestion) {
        if previewItems.contains(question) { previewItems.removeAll { $0 == question }; return }
        dismiss(where: { $0.id == question.id }, includingPermissions: true)
    }

    /// Clear one item from the list without answering it (a permission request is cleared only by an answer).
    public func dismiss(_ question: PendingAgentQuestion) {
        if previewItems.contains(question) { if !question.isPermission { previewItems.removeAll { $0 == question } }; return }
        dismiss(where: { $0.id == question.id })
    }

    /// Dismiss any `mac-dialog:` questions whose Mac was re-enrolled under a
    /// new machine id with the same name, or whose Mac is no longer in the
    /// account's online machine list past the 3-minute presence window.
    public func pruneMacDialogs(activeMachines: [(machineId: String, displayName: String)], now: Date = Date()) {
        guard !activeMachines.isEmpty else { return }
        let activeIds = Set(activeMachines.map(\.machineId))
        let nowMs = now.timeIntervalSince1970 * 1000
        func normalizedName(_ s: String) -> String {
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower.hasSuffix(".local") ? String(lower.dropLast(6)) : lower
        }
        let activeNames = Set(activeMachines.map { normalizedName($0.displayName) }.filter { !$0.isEmpty })
        let stale = questions.filter { item in
            guard let mid = item.macDialogMachineId else { return false }
            if activeIds.contains(mid) { return false }
            if activeNames.contains(normalizedName(item.title)) { return true }
            return nowMs - item.createdAt > 3 * 60_000
        }
        guard !stale.isEmpty else { return }
        let staleIds = Set(stale.map(\.id))
        dismiss(where: { staleIds.contains($0.id) })
    }

    /// Samples for checking the Waiting on You screen on a simulator, which no Mac waits for.
    private var previewItems: [PendingAgentQuestion] = [] {
        didSet { noteWaitingCount() }
    }

    @ObservationIgnored public private(set) var questionsRevision = 0

    private func noteWaitingCount() {
        questionsRevision &+= 1
        let count = questions.count + previewItems.count
        if count != waitingCount { waitingCount = count }
    }

    #if DEBUG
    /// Put a sample of each kind of item in the list: a permission request from a member's chat, questions
    /// with choices, several choices, typed words and a date, one answered only in its chat, and a mention.
    /// Debug builds only: the app does it when launched with RIPUL_PREVIEW_PERMISSION_REQUEST=1. Answering
    /// one says no Mac can be reached, which shows the card's other state.
    public func showPreviewItems() {
        let now = Date().timeIntervalSince1970 * 1000
        func item(_ id: String, _ title: String, _ question: String, minutesAgo: Double) -> PendingAgentQuestion {
            var sample = PendingAgentQuestion(chatId: "preview-\(id)", questionId: id, title: title, question: question,
                blocking: 1, createdAt: now - minutesAgo * 60_000, expiresAt: nil)
            sample.kind = "question"
            sample.threadId = "preview-thread-\(id)"
            sample.actionId = "preview-action-\(id)"
            sample.machineId = "preview-mac"
            return sample
        }
        var permission = item("owner_browser_access_preview", "wac 3.0.0 review", "George Fairhall asked the agent for something that changes files or runs "
            + "commands in the repo WAC_ios_final (/Users/peter/Documents/WAC_ios_final) on your Mac. Commands run as you. "
            + "The agent is held to that repo and its worktrees by a check on each command, which is not a sandbox. Allow it?", minutesAgo: 3)
        permission.answerPolicy = "owner"
        permission.header = "Folder access"
        permission.options = [
            .init(label: "Allow for one hour", description: "For George Fairhall's requests in this chat, in this folder only."),
            .init(label: "Allow once", description: "For the one action that is waiting."),
            .init(label: "Always, for George Fairhall in this chat", description: "George Fairhall's requests use this folder without asking you again."),
            .init(label: "Permanently for this repo", description: "George Fairhall's requests in any of your chats on this Mac read and change this repo and its worktrees."),
            .init(label: "Don't allow", description: "Nothing is read or changed there."),
        ]
        var colour = item("cli_ask_user_preview_0", "Website refresh", "Which **colour** should the new header use?", minutesAgo: 42)
        colour.header = "Header colour"
        colour.allowsText = true
        colour.options = [.init(label: "Navy", description: "Matches the logo"), .init(label: "Teal", description: "The accent we use for links"),
                          .init(label: "Paper", description: "Warm off-white, no contrast change")]
        var checks = item("cli_ask_user_preview_1", "Release 3.1", "Which checks should run before the release?", minutesAgo: 90)
        checks.multiSelect = true
        checks.options = [.init(label: "Unit tests", description: nil), .init(label: "Simulator run", description: "About ten minutes"),
                          .init(label: "Phone install", description: nil)]
        var date = item("ask_date_preview", "Rota planner", "When should the rota start?", minutesAgo: 130)
        date.dateInput = PendingQuestionDateInput(includeTime: false, minDate: nil, maxDate: nil, defaultDate: nil)
        let table = item("ask_table_preview", "Data clean-up", "Which of these rows should be merged? The table is in the chat.", minutesAgo: 200)
        var mention = item("msg_preview", "Design review", "Can you look at the new settings screen before I send it round?", minutesAgo: 15)
        mention.kind = "mention"
        mention.fromName = "Sam"
        previewItems = [permission, colour, checks, date, table, mention]
    }
    #endif

    /// Kept after reading a mention: reading must not move the chat backwards.
    public func latestMentionAt(anyOf keys: [String]) -> Date? {
        guard !mentionActivity.isEmpty else { return nil }
        var latest: Double?
        for key in keys {
            if let ts = mentionActivity[Self.canonical(key)], ts > (latest ?? -.infinity) {
                latest = ts
            }
        }
        return latest.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Show the account-scoped attention row as soon as its push arrives,
    /// including when a token refresh or a network read is temporarily failing.
    @discardableResult public func receivePush(_ payload: [AnyHashable: Any]) -> Bool {
        guard let accountId, payload["userId"] as? String == accountId,
              payload["type"] as? String == "agentQuestion",
              let chatId = payload["chatId"] as? String, !chatId.isEmpty,
              let questionId = payload["questionId"] as? String, !questionId.isEmpty,
              let title = payload["title"] as? String,
              let aps = payload["aps"] as? [String: Any],
              let alert = aps["alert"] as? [String: Any],
              let question = alert["body"] as? String,
              let createdAt = payload["createdAt"] as? Double, createdAt.isFinite, createdAt > 0,
              let expiresAt = payload["expiresAt"] as? Double, expiresAt.isFinite,
              expiresAt > Date().timeIntervalSince1970 * 1000 else { return false }
        var item = PendingAgentQuestion(chatId: chatId, questionId: questionId, title: title,
            question: question, blocking: payload["blocking"] as? Int ?? 0,
            createdAt: createdAt, expiresAt: expiresAt)
        // What the list already knows of it (its choices, the Mac that asked) is not lost to the push.
        if let known = questions.first(where: { $0.id == item.id }) {
            item.options = known.options; item.header = known.header; item.machineId = known.machineId
            item.threadId = known.threadId; item.actionId = known.actionId
            item.multiSelect = known.multiSelect; item.allowsText = known.allowsText; item.dateInput = known.dateInput
        }
        item.kind = payload["kind"] as? String == "mention" ? "mention" : "question"
        item.fromName = payload["fromName"] as? String
        item.answerPolicy = payload["answerPolicy"] as? String
        // A push carries no choices: the list has them, so read it now and the question can be answered.
        if questions.first(where: { $0.id == item.id })?.options == nil { Task { await refresh() } }
        replace(questions.filter { $0.id != item.id } + [item])
        if let encoded = try? JSONEncoder().encode(questions) { defaults.set(encoded, forKey: cacheKey(accountId)) }
        return questions.contains { $0.id == item.id }
    }

    /// A mention is answered by reading it: opening the chat clears it.
    /// Agent questions stay until they are answered.
    public func clearMentions(anyOf keys: [String]) {
        let aliases = Set(keys.map(Self.canonical))
        guard questions.contains(where: { $0.isMention && aliases.contains(Self.canonical($0.chatId)) }) else { return }
        dismiss(where: { $0.isMention && aliases.contains(Self.canonical($0.chatId)) })
    }

    public func first(anyOf keys: [String]) -> PendingAgentQuestion? {
        guard !questions.isEmpty else { return nil }
        var earliest: PendingAgentQuestion?
        for key in keys {
            if let match = firstByCanonicalChatId[Self.canonical(key)] {
                if let current = earliest {
                    if match.createdAt < current.createdAt { earliest = match }
                } else {
                    earliest = match
                }
            }
        }
        return earliest
    }

    /// Unread mentions for this row, excluding agent questions. A shared chat
    /// can have several local/owner aliases, and push plus inbox delivery can
    /// repeat a message; count each message only once across all of them.
    public func unreadMentionCount(anyOf keys: [String]) -> Int {
        // Observe the live list even though the lookup index itself is ignored.
        guard !questions.isEmpty else { return 0 }
        var ids = Set<String>()
        for key in keys {
            if let mentions = mentionIdsByCanonicalChatId[Self.canonical(key)] {
                ids.formUnion(mentions)
            }
        }
        return ids.count
    }

    public func isViewing(_ chatId: String) -> Bool {
        visibleChatId.map { Self.canonical($0) == Self.canonical(chatId) } ?? false
    }

    public static func canonical(_ id: String) -> String {
        id.hasPrefix("cli_") ? String(id.dropFirst(4)) : id
    }

    /// Clears attention only; never submits an answer or cancels the agent.
    /// A permission request stays: it is cleared only by being answered.
    public func dismiss(anyOf keys: [String]) {
        let aliases = Set(keys.map(Self.canonical))
        dismiss(where: { aliases.contains(Self.canonical($0.chatId)) })
    }

    private func dismiss(where matches: (PendingAgentQuestion) -> Bool, includingPermissions: Bool = false) {
        guard let account = accountId else { return }
        dismissed += questions.filter { matches($0) && (includingPermissions || !$0.isPermission) }
        if let data = try? JSONEncoder().encode(dismissed) {
            defaults.set(data, forKey: "ripul.dismissedQuestions.\(account)")
        }
        replace(questions)
        Task { await refresh() }
    }

    @discardableResult public func refresh() async -> Bool {
        // Expiry is known locally even when offline or signed out.
        replace(questions)
        if let refreshTask { return await refreshTask.value }
        guard let account = accountId, let token = tokenProvider?() else { return false }
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                // Persisted dismissals also act as an offline retry queue. The
                // server's closed tombstone makes retries idempotent.
                let sentDismissals = Set(self.dismissed.map(\.id))
                for question in self.dismissed {
                    var close = URLRequest(url: AgentConfiguration.defaultBaseURL
                        .appendingPathComponent("api/v1/notifications/questions"))
                    close.httpMethod = "POST"
                    close.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    close.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    close.timeoutInterval = 15
                    close.httpBody = try JSONSerialization.data(withJSONObject: [
                        "chatId": question.chatId, "questionId": question.questionId, "closed": true])
                    let (_, response) = try await URLSession.shared.data(for: close)
                    guard !Task.isCancelled, self.accountId == account,
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
                }
                var request = URLRequest(url: AgentConfiguration.defaultBaseURL
                    .appendingPathComponent("api/v1/notifications/questions"))
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, self.accountId == account,
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
                struct Reply: Decodable { let questions: [PendingAgentQuestion] }
                let reply = try JSONDecoder().decode(Reply.self, from: data)
                self.replace(reply.questions)
                self.refreshedAt = Date()
                // A successful list after the closes confirms they cannot return.
                let liveIds = Set(reply.questions.map(\.id))
                self.dismissed.removeAll { sentDismissals.contains($0.id) && !liveIds.contains($0.id) }
                if let encoded = try? JSONEncoder().encode(self.dismissed) {
                    self.defaults.set(encoded, forKey: "ripul.dismissedQuestions.\(account)")
                }
                if let encoded = try? JSONEncoder().encode(self.questions) {
                    self.defaults.set(encoded, forKey: self.cacheKey(account))
                }
            } catch {
                // A failed read is unknown, not evidence that questions closed.
                return false
            }
            return true
        }
        refreshTask = task
        let success = await task.value
        if accountId == account { refreshTask = nil }
        return success
    }

    func replace(_ incoming: [PendingAgentQuestion], now: Double = Date().timeIntervalSince1970 * 1000) {
        var activity = mentionActivity
        for item in incoming where item.isMention && item.createdAt.isFinite && item.createdAt > 0 {
            let key = Self.canonical(item.chatId)
            activity[key] = max(activity[key] ?? 0, item.createdAt)
        }
        if activity.count > 300 {
            activity = Dictionary(uniqueKeysWithValues: activity.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) })
        }
        if activity != mentionActivity {
            mentionActivity = activity
            if let accountId { defaults.set(activity, forKey: "ripul.mentionActivity.\(accountId)") }
        }
        let hidden = Set(dismissed.map(\.id))
        let live = incoming.filter { !hidden.contains($0.id) && ($0.expiresAt == nil || $0.expiresAt! > now) }
            .sorted { $0.createdAt < $1.createdAt }
        var byChat: [String: PendingAgentQuestion] = [:]
        var mentionsByChat: [String: Set<String>] = [:]
        for item in live {
            let key = Self.canonical(item.chatId)
            if byChat[key] == nil { byChat[key] = item }
            if item.isMention { mentionsByChat[key, default: []].insert(item.questionId) }
        }
        firstByCanonicalChatId = byChat
        mentionIdsByCanonicalChatId = mentionsByChat
        if live != questions { questions = live }
    }

    private func cacheKey(_ account: String) -> String { "ripul.pendingQuestions.\(account)" }
}
