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
    @ObservationIgnored private var tokenProvider: (() -> String?)?
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored public var visibleChatId: String?
    @ObservationIgnored public var openQuestion: ((PendingAgentQuestion) -> Void)?
    @ObservationIgnored private var dismissed: [PendingAgentQuestion] = []
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func configure(accountId: String?, tokenProvider: @escaping () -> String?) {
        self.tokenProvider = tokenProvider
        guard self.accountId != accountId else { return }
        refreshTask?.cancel()
        refreshTask = nil
        self.accountId = accountId
        questions = []
        dismissed = accountId.flatMap { defaults.data(forKey: "ripul.dismissedQuestions.\($0)") }
            .flatMap { try? JSONDecoder().decode([PendingAgentQuestion].self, from: $0) } ?? []
        if let accountId, let data = defaults.data(forKey: cacheKey(accountId)),
           let cached = try? JSONDecoder().decode([PendingAgentQuestion].self, from: data) {
            replace(cached)
        }
    }

    /// True when any item is a mention, so the list says "attention", not "answer".
    public var hasMentions: Bool { questions.contains(where: \.isMention) }

    /// A mention is answered by reading it: opening the chat clears it.
    /// Agent questions stay until they are answered.
    public func clearMentions(anyOf keys: [String]) {
        let aliases = Set(keys.map(Self.canonical))
        guard questions.contains(where: { $0.isMention && aliases.contains(Self.canonical($0.chatId)) }) else { return }
        dismiss(where: { $0.isMention && aliases.contains(Self.canonical($0.chatId)) })
    }

    public func first(anyOf keys: [String]) -> PendingAgentQuestion? {
        let aliases = Set(keys.map(Self.canonical))
        return questions.first { aliases.contains(Self.canonical($0.chatId)) }
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
        let hidden = Set(dismissed.map(\.id))
        let live = incoming.filter { !hidden.contains($0.id) && ($0.expiresAt == nil || $0.expiresAt! > now) }
        if live != questions { questions = live }
    }

    private func cacheKey(_ account: String) -> String { "ripul.pendingQuestions.\(account)" }
}
