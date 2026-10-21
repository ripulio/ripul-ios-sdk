import Foundation
import Observation

/// An account's unanswered questions, independent of which chat is mounted or
/// has been read. Answers still travel through the existing inline controls.
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
    public var id: String { chatId + ":" + questionId }
    public var isMention: Bool { kind == "mention" }
}

@MainActor @Observable
public final class PendingQuestionStore {
    public static let shared = PendingQuestionStore()
    public private(set) var questions: [PendingAgentQuestion] = []
    public private(set) var accountId: String?
    private var mentionActivity: [String: Double] = [:]
    @ObservationIgnored private var tokenProvider: (() -> String?)?
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored public var visibleChatId: String?
    @ObservationIgnored public var openQuestion: ((PendingAgentQuestion) -> Void)?
    @ObservationIgnored private var dismissed: [PendingAgentQuestion] = []
    @ObservationIgnored private var firstByCanonicalChatId: [String: PendingAgentQuestion] = [:]
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
        mentionActivity = accountId.flatMap { defaults.dictionary(forKey: "ripul.mentionActivity.\($0)") as? [String: Double] } ?? [:]
        dismissed = accountId.flatMap { defaults.data(forKey: "ripul.dismissedQuestions.\($0)") }
            .flatMap { try? JSONDecoder().decode([PendingAgentQuestion].self, from: $0) } ?? []
        if let accountId, let data = defaults.data(forKey: cacheKey(accountId)),
           let cached = try? JSONDecoder().decode([PendingAgentQuestion].self, from: data) {
            replace(cached)
        }
    }

    /// True when any item is a mention, so the list says "attention", not "answer".
    public var hasMentions: Bool { questions.contains(where: \.isMention) }

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
        item.kind = payload["kind"] as? String == "mention" ? "mention" : "question"
        item.fromName = payload["fromName"] as? String
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

    public func isViewing(_ chatId: String) -> Bool {
        visibleChatId.map { Self.canonical($0) == Self.canonical(chatId) } ?? false
    }

    public static func canonical(_ id: String) -> String {
        id.hasPrefix("cli_") ? String(id.dropFirst(4)) : id
    }

    /// Clears attention only; never submits an answer or cancels the agent.
    public func dismiss(anyOf keys: [String]) {
        let aliases = Set(keys.map(Self.canonical))
        dismiss(where: { aliases.contains(Self.canonical($0.chatId)) })
    }

    private func dismiss(where matches: (PendingAgentQuestion) -> Bool) {
        guard let account = accountId else { return }
        dismissed += questions.filter(matches)
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
        for item in live {
            let key = Self.canonical(item.chatId)
            if byChat[key] == nil { byChat[key] = item }
        }
        firstByCanonicalChatId = byChat
        if live != questions { questions = live }
    }

    private func cacheKey(_ account: String) -> String { "ripul.pendingQuestions.\(account)" }
}
