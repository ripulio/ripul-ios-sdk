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
@MainActor
public final class RipulInviteManager: ObservableObject {
    @Published public private(set) var invites: [RipulShareInvite] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastFetchStatus: String = ""

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
    private var tokenProvider: TokenProvider?
    private var accountProvider: (@MainActor () -> String?)?
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    private var accountId: String?
    private var observers = Set<AnyCancellable>()

    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        cache: RipulSessionCache? = nil,
        session: URLSession = .shared,
        refreshInterval: Duration = .seconds(20)
    ) {
        self.baseURL = baseURL
        self.cache = cache
        self.session = session
        self.refreshInterval = refreshInterval
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
    }

    private func requestToken(forceRefresh: Bool = false) async -> String? {
        await tokenProvider?(forceRefresh)
    }

    /// Fetch the user's invites from the server.
    public func fetchInvites() async {
        let currentAccount = accountProvider?()
        if accountId != currentAccount { invites = []; accountId = currentAccount }
        // A push during an in-flight read must trigger a second read, not be lost.
        guard !isLoading else { refreshQueued = true; return }
        isLoading = true
        defer {
            isLoading = false
            if refreshQueued && !Task.isCancelled {
                refreshQueued = false
                Task { await fetchInvites() }
            } else { refreshQueued = false }
        }
        guard let authToken = await requestToken() else {
            lastFetchStatus = "Waiting for sign-in"
            return
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
            guard accountProvider?() == currentAccount else { invites = []; return }
            guard !Task.isCancelled else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status >= 200, status < 300 else {
                lastFetchStatus = "HTTP \(status)"
                return
            }

            struct InvitesResponse: Codable {
                let invites: [RipulShareInvite]
            }
            let decoded = try JSONDecoder().decode(InvitesResponse.self, from: data)
            if invites != decoded.invites { invites = decoded.invites }
            lastFetchStatus = "OK: \(decoded.invites.count) invite(s)"
        } catch {
            lastFetchStatus = "Error: \(error.localizedDescription)"
        }
    }

    /// Dismiss (or mark accepted) an invite.
    public func dismissInvite(_ invite: RipulShareInvite) async {
        guard let authToken = await requestToken() else { return }

        // Optimistic removal
        invites.removeAll { $0.token == invite.token }

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
        invites.removeAll { $0.token == invite.token }
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
    nonisolated static func subject(ofJWT token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["sub"] as? String
    }
}
