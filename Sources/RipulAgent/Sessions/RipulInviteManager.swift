import Foundation
import Combine
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A single session invite from another user.
public struct RipulShareInvite: Identifiable, Codable, Equatable {
    public let token: String
    public let roomId: String
    public let chatId: String?
    public let sourceTabId: String?
    public let label: String?
    public let inviterUserId: String
    public let inviterName: String?
    public let targetEmail: String
    public let targetUserId: String?
    public let createdAt: String
    public let accepted: Bool?

    public var id: String { token }

    public var displayLabel: String {
        label ?? "Shared Session"
    }
}

extension RipulShareInvite {
    /// The invitation as its push notification carries it. Nil for any other
    /// push, and for one from a server too old to send the whole row.
    public init?(pushPayload payload: [AnyHashable: Any]) {
        guard payload["type"] as? String == "sessionInvite",
              let token = payload["shareToken"] as? String,
              let roomId = payload["roomId"] as? String,
              let inviterUserId = payload["inviterUserId"] as? String,
              let targetEmail = payload["targetEmail"] as? String,
              let targetUserId = payload["targetUserId"] as? String,
              let createdAt = payload["createdAt"] as? String else { return nil }
        self.init(
            token: token, roomId: roomId,
            chatId: payload["chatId"] as? String,
            sourceTabId: payload["sourceTabId"] as? String,
            label: payload["label"] as? String,
            inviterUserId: inviterUserId,
            inviterName: payload["inviterName"] as? String,
            targetEmail: targetEmail, targetUserId: targetUserId,
            createdAt: createdAt, accepted: nil
        )
    }
}

public struct RipulChatMember: Identifiable, Decodable {
    public let id: String
    public let name: String
    public let accepted: Bool
}

/// Fetches, caches, and manages session invites for the signed-in user.
///
/// Lives in the SDK — not the app — because an invite is the ONLY way into the
/// app for a guest who has no Mac: with no machine and no chats, the session
/// list has nothing else to offer. A host that never injected an invites panel
/// (WAC's developer console) left such a user with "No machines or sessions
/// yet." and no way to reach the chat they were invited to.
///
/// Inert until `configure`: an unconfigured instance never polls. Once
/// configured it re-reads every `refreshInterval` while the app is active (the
/// fallback for hosts with no invite push), and stops in the background.
///
/// A host that does receive the invite push hands it to `receivePush`, which
/// shows the invitation at once: the push carries the whole row.
@MainActor
public final class RipulInviteManager: ObservableObject {
    /// What the panel shows: pushed invitations the inbox has not listed yet,
    /// then the inbox as last read. Written only by `publish()`.
    @Published public private(set) var invites: [RipulShareInvite] = []
    // Diagnostics and a re-entrancy guard, not UI: nothing renders them, and
    // publishing them re-rendered every observer (the session list, the SDK
    // console's RipulAgentScreen) twice per 20s poll, changed or not.
    public private(set) var isLoading = false
    public private(set) var lastFetchStatus: String = ""

    /// MRU list of emails the user has previously invited (persisted locally).
    @Published public private(set) var recentEmails: [String] = []

    /// Returns the current Clerk token; `true` asks for a fresh one after a 401.
    public typealias TokenProvider = @MainActor (_ forceRefresh: Bool) async -> String?

    private static let recentEmailsKey = "ripul.invite.recentEmails"
    private static let maxRecentEmails = 10

    private let baseURL: URL
    private let cache: RipulSessionCache?
    private let session: URLSession
    private let refreshInterval: Duration
    private let retryDelay: Duration
    private let tokenTimeout: Duration
    private let pushedGrace: Duration
    private var tokenProvider: TokenProvider?
    private var accountProvider: (@MainActor () -> String?)?
    private var refreshTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var failedReads = 0
    private var refreshQueued = false
    private var accountId: String?
    private var observers = Set<AnyCancellable>()
    /// The inbox as the server last listed it.
    private var listed: [RipulShareInvite] = []
    /// Invitations a push delivered that the inbox has not listed yet, by
    /// token. The next read normally lists one within a second. Until it does
    /// (or `pushedGrace` passes) the row stays, so a read that raced the push,
    /// or failed, cannot take away what the user was just told about.
    private var pushed: [String: (invite: RipulShareInvite, at: ContinuousClock.Instant)] = [:]

    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        cache: RipulSessionCache? = nil,
        session: URLSession = .shared,
        refreshInterval: Duration = .seconds(20),
        retryDelay: Duration = .seconds(2),
        tokenTimeout: Duration = .seconds(10),
        pushedGrace: Duration = .seconds(60)
    ) {
        self.baseURL = baseURL
        self.cache = cache
        self.session = session
        self.refreshInterval = refreshInterval
        self.retryDelay = retryDelay
        self.tokenTimeout = tokenTimeout
        self.pushedGrace = pushedGrace
        recentEmails = cache?.stringArray(forKey: Self.recentEmailsKey) ?? []
    }

    /// Connect to an auth source and start the foreground refresh.
    ///
    /// `account` identifies whose invites these are, so a response that was in
    /// flight across an account switch can't populate the new account's inbox.
    public func configure(
        token: @escaping TokenProvider,
        account: @escaping @MainActor () -> String?
    ) {
        tokenProvider = token
        accountProvider = account
        observeAppActivity()
        #if os(iOS)
        if UIApplication.shared.applicationState == .active { startRefreshing() }
        #else
        if NSApplication.shared.isActive { startRefreshing() }
        #endif
    }

    /// Configure from a synchronous token source (the SDK screens'
    /// `tokenProvider`). The account is the token's Clerk subject, and a 401
    /// retry happens only if the source has since produced a different token.
    public func configure(tokenProvider: @escaping () -> String?) {
        configure(
            token: { _ in tokenProvider() },
            account: { Self.subject(ofJWT: tokenProvider()) }
        )
    }

    private func observeAppActivity() {
        guard observers.isEmpty else { return }
        #if os(iOS)
        let active = UIApplication.didBecomeActiveNotification
        let inactive = UIApplication.didEnterBackgroundNotification
        #else
        let active = NSApplication.didBecomeActiveNotification
        let inactive = NSApplication.didResignActiveNotification
        #endif
        NotificationCenter.default.publisher(for: active).sink { [weak self] _ in
            Task { @MainActor in self?.startRefreshing() }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: inactive).sink { [weak self] _ in
            Task { @MainActor in self?.stopRefreshing() }
        }.store(in: &observers)
    }

    private func startRefreshing() {
        guard refreshTask == nil else { return }
        let interval = refreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchInvites()
                do { try await Task.sleep(for: interval) } catch { break }
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
        retryTask?.cancel()
        retryTask = nil
        failedReads = 0
    }

    /// A read that failed while the app is active is tried again after
    /// `retryDelay`, then twice that, until the gap would rival the regular
    /// refresh. Without this a read that lost a race on return to the app (the
    /// web view still reloading, so no token yet) waited out the whole
    /// `refreshInterval` with nothing on screen.
    private func retrySoon() {
        guard refreshTask != nil, retryTask == nil else { return }
        let delay = retryDelay * (1 << failedReads)
        guard delay * 2 <= refreshInterval else { return }
        failedReads += 1
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            await self.fetchInvites()
        }
    }

    /// The host's token source, bounded. In the Ripul app it reaches through
    /// the web view, and nothing else limits that call: one that never came
    /// back left `isLoading` set, so every later read (poll, push, return to
    /// the app) stopped at the guard until the app was restarted.
    private func requestToken(forceRefresh: Bool = false) async -> String? {
        guard let tokenProvider else { return nil }
        let limit = tokenTimeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var didResume = false
            Task { @MainActor in
                let token = await tokenProvider(forceRefresh)
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: token)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: nil)
            }
        }
    }

    /// An invitation's push arrived, or was tapped. Shows the invitation at
    /// once when the push carries it, and reads the inbox either way.
    ///
    /// A push addressed to another account (one that was signed in on this
    /// device before) is never shown: `publish()` matches it to the account.
    public func receivePush(_ payload: [AnyHashable: Any]) {
        if let invite = RipulShareInvite(pushPayload: payload),
           !listed.contains(where: { $0.token == invite.token }) {
            pushed[invite.token] = (invite, .now)
            publish()
        }
        Task { await fetchInvites() }
    }

    /// Rebuild `invites` from the two sources, publishing only a change.
    private func publish() {
        let account = accountProvider?()
        let waiting = pushed.values
            .filter { account != nil && $0.invite.targetUserId == account }
            .sorted { $0.at > $1.at }
            .map(\.invite)
        let next = waiting + listed
        if invites != next { invites = next }
    }

    private enum ReadOutcome { case listed, failed, abandoned }

    /// Fetch the user's invites from the server.
    public func fetchInvites() async {
        let currentAccount = accountProvider?()
        if accountId != currentAccount {
            listed = []
            accountId = currentAccount
            publish()
        }
        // A push during an in-flight read must trigger a second read, not be lost.
        guard !isLoading else { refreshQueued = true; return }
        isLoading = true
        let outcome = await readInbox(for: currentAccount)
        isLoading = false
        switch outcome {
        case .listed:
            failedReads = 0
            retryTask?.cancel()
            retryTask = nil
        case .failed: retrySoon()
        case .abandoned: break
        }
        // Still owed when this read's own task was cancelled, as long as the
        // app is active: the read in flight when the app left can finish
        // after it is back, and the read asked for on return queued behind it.
        if refreshQueued && (!Task.isCancelled || refreshTask != nil) {
            Task { await fetchInvites() }
        }
        refreshQueued = false
    }

    private func readInbox(for currentAccount: String?) async -> ReadOutcome {
        guard let authToken = await requestToken() else {
            lastFetchStatus = "Waiting for sign-in"
            // Signed in but no token means the token source is not ready yet,
            // which passes in seconds. Signed out, the host's own sign-in
            // change asks for the next read.
            return currentAccount == nil ? .abandoned : .failed
        }

        do {
            let url = baseURL.appendingPathComponent("api/v1/relay/share/invites")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

            var (data, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 401,
               let fresh = await requestToken(forceRefresh: true),
               fresh != authToken,
               accountProvider?() == currentAccount {
                request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                (data, response) = try await session.data(for: request)
            }
            guard accountProvider?() == currentAccount else {
                listed = []
                publish()
                return .abandoned
            }
            guard !Task.isCancelled else { return .abandoned }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status >= 200, status < 300 else {
                lastFetchStatus = "HTTP \(status)"
                return .failed
            }

            struct InvitesResponse: Codable {
                let invites: [RipulShareInvite]
            }
            let decoded = try JSONDecoder().decode(InvitesResponse.self, from: data)
            listed = decoded.invites
            // The inbox now speaks for every pushed invitation it lists; one
            // it still has not listed is kept only for `pushedGrace`.
            let now = ContinuousClock.now
            pushed = pushed.filter { token, entry in
                !listed.contains { $0.token == token } && now - entry.at < pushedGrace
            }
            publish()
            lastFetchStatus = "OK: \(decoded.invites.count) invite(s)"
            return .listed
        } catch {
            lastFetchStatus = "Error: \(error.localizedDescription)"
            return Task.isCancelled ? .abandoned : .failed
        }
    }

    /// Dismiss (or mark accepted) an invite.
    public func dismissInvite(_ invite: RipulShareInvite) async {
        guard let authToken = await requestToken() else { return }

        // Optimistic removal
        listed.removeAll { $0.token == invite.token }
        pushed[invite.token] = nil
        publish()

        do {
            let url = baseURL.appendingPathComponent("api/v1/relay/share/invites/\(invite.token)")
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status < 200 || status >= 300 {
                NSLog("[InviteManager] dismiss failed status=%d", status)
            }
        } catch {
            NSLog("[InviteManager] dismiss error: %@", error.localizedDescription)
        }
    }

    /// Send an invite for a share token to an email address.
    public func sendInvite(shareToken: String, email: String) async -> (success: Bool, error: String?) {
        guard let authToken = await requestToken() else {
            return (false, "Not authenticated")
        }

        do {
            let url = baseURL.appendingPathComponent("api/v1/relay/share/\(shareToken)/invite")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status >= 200, status < 300 {
                addRecentEmail(email)
                return (true, nil)
            } else {
                return (false, serverError(data, fallback: "Failed (status \(status))"))
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func serverError(_ data: Data, fallback: String) -> String {
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = body?["error"] as? [String: Any]
        return error?["message"] as? String ?? fallback
    }

    private func membershipRequest(path: String, method: String = "GET") async throws -> Data {
        guard let token = await requestToken() else { throw URLError(.userAuthenticationRequired) }
        let account = accountProvider?()
        let url = baseURL.appendingPathComponent("api/v1/\(path)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard accountProvider?() == account else { throw URLError(.userAuthenticationRequired) }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw NSError(domain: "Invites", code: 1, userInfo: [NSLocalizedDescriptionKey: serverError(data, fallback: "Could not update chat membership")])
        }
        return data
    }

    public func members(shareToken: String) async throws -> [RipulChatMember] {
        struct Result: Decodable { let members: [RipulChatMember] }
        return try JSONDecoder().decode(Result.self, from: await membershipRequest(path: "relay/share/\(shareToken)/members")).members
    }

    public func removeMember(_ member: RipulChatMember, shareToken: String) async throws {
        let userId = String(member.id.dropFirst("human-".count))
        _ = try await membershipRequest(path: "relay/share/\(shareToken)/members/\(userId)", method: "DELETE")
    }

    public func leaveChat(_ invite: RipulShareInvite) async throws {
        _ = try await membershipRequest(path: "session/share/\(invite.token)/leave", method: "POST")
        listed.removeAll { $0.token == invite.token }
        pushed[invite.token] = nil
        publish()
    }

    // MARK: - MRU Emails

    public func addRecentEmail(_ email: String) {
        let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
        recentEmails.removeAll { $0 == normalized }
        recentEmails.insert(normalized, at: 0)
        if recentEmails.count > Self.maxRecentEmails {
            recentEmails = Array(recentEmails.prefix(Self.maxRecentEmails))
        }
        cache?.set(recentEmails, forKey: Self.recentEmailsKey)
    }

    // MARK: - Account identity

    /// The `sub` claim of a Clerk JWT — the user id — without verifying it.
    /// Used only to tell one signed-in account from another.
    ///
    /// The session list needs the same answer for the same reason, so the
    /// parser lives in `RipulAccountIdentity`; this stays as the name the
    /// manager and its tests already call.
    nonisolated static func subject(ofJWT token: String?) -> String? {
        RipulAccountIdentity.subject(ofJWT: token)
    }
}
