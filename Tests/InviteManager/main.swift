import Foundation
import AppKit

final class InviteProtocol: URLProtocol {
    static let lock = NSLock()
    static var count = 0
    static var handler: (URLRequest, Int) -> (Int, String, TimeInterval) = { _, _ in (200, "{\"invites\":[]}", 0) }
    static func reset(_ next: @escaping (URLRequest, Int) -> (Int, String, TimeInterval)) {
        lock.lock(); defer { lock.unlock() }; count = 0; handler = next
    }
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let n = Self.count; let handler = Self.handler; Self.lock.unlock()
        let (status, body, delay) = handler(request, n)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func body(_ token: String) -> String {
    "{\"invites\":[{\"token\":\"\(token)\",\"roomId\":\"room\",\"inviterUserId\":\"owner\",\"targetEmail\":\"alice@example.test\",\"createdAt\":\"now\"}]}"
}
@main struct Checks {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InviteProtocol.self]
        let session = URLSession(configuration: config)
        let auth = AuthTokenStore()
        let manager = RipulInviteManager(session: session, refreshInterval: .milliseconds(100))
        // The Ripul app's `configure(authStore:)` adapter, verbatim.
        manager.configure(
            token: { forceRefresh in await auth.requestToken(forceRefresh: forceRefresh) },
            account: { auth.userId }
        )
        InviteProtocol.reset { request, n in
            if n == 1 { return (401, "{}", 0) }
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer alice-fresh")
            return (200, body("fresh"), 0)
        }
        await manager.fetchInvites()
        precondition(InviteProtocol.requests == 2 && auth.forcedRefreshes == 1 && manager.invites.first?.token == "fresh")
        print("PASS: rejected token refreshes once and updates invites")

        InviteProtocol.reset { _, n in (200, body(n == 1 ? "old" : "arrived"), 0.08) }
        let first = Task { await manager.fetchInvites() }
        try await Task.sleep(for: .milliseconds(15))
        await manager.fetchInvites() // Push while the old response is in flight.
        await first.value
        try await Task.sleep(for: .milliseconds(160))
        precondition(InviteProtocol.requests == 2 && manager.invites.first?.token == "arrived")
        print("PASS: in-flight push queues a fresh read")

        InviteProtocol.reset { _, _ in (200, body("alice-only"), 0.08) }
        let oldAccount = Task { await manager.fetchInvites() }
        try await Task.sleep(for: .milliseconds(15)); auth.userId = "bob"
        await oldAccount.value
        precondition(manager.invites.first?.token != "alice-only")
        print("PASS: old-account response cannot populate the new account")

        InviteProtocol.reset { _, _ in (200, body("foreground"), 0) }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(260))
        precondition(InviteProtocol.requests >= 2 && manager.invites.first?.token == "foreground")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(40)); let stopped = InviteProtocol.requests
        try await Task.sleep(for: .milliseconds(220))
        precondition(InviteProtocol.requests == stopped)
        print("PASS: foreground fallback refreshes without push and stops in background")
        InviteProtocol.reset { _, _ in (403, "{\"error\":{\"type\":\"error\",\"message\":\"Access was removed\"}}", 0) }
        do {
            try await manager.leaveChat(manager.invites[0])
            preconditionFailure("Expected denied membership request")
        } catch { precondition(error.localizedDescription == "Access was removed") }
        print("PASS: membership errors preserve the server's readable reason")
        auth.userId = nil
        await manager.fetchInvites()
        precondition(manager.invites.isEmpty)
        print("PASS: signed-out account clears the inbox")

        // The SDK screens' path (WAC's developer console): only a synchronous
        // token, so the account is the JWT's Clerk subject.
        precondition(RipulInviteManager.subject(ofJWT: jwt("user_alice")) == "user_alice")
        precondition(RipulInviteManager.subject(ofJWT: "not-a-jwt") == nil && RipulInviteManager.subject(ofJWT: nil) == nil)
        print("PASS: account id is read from the token's subject")

        var token: String? = jwt("user_alice")
        let cache = MemoryCache()
        let guest = RipulInviteManager(cache: cache, session: session, refreshInterval: .seconds(60))
        guest.configure(tokenProvider: { token })
        InviteProtocol.reset { request, _ in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt("user_alice"))")
            return (200, body("guest"), 0)
        }
        await guest.fetchInvites()
        precondition(InviteProtocol.requests == 1 && guest.invites.first?.token == "guest")
        print("PASS: token-only host loads the guest's invites")

        InviteProtocol.reset { _, _ in (401, "{}", 0) }
        await guest.fetchInvites()
        precondition(InviteProtocol.requests == 1 && guest.lastFetchStatus == "HTTP 401")
        print("PASS: a 401 is not retried with the same token")

        InviteProtocol.reset { _, _ in (200, body("alice-only"), 0.08) }
        let switching = Task { await guest.fetchInvites() }
        try await Task.sleep(for: .milliseconds(15)); token = jwt("user_bob")
        await switching.value
        precondition(guest.invites.first?.token != "alice-only")
        print("PASS: token-only host drops a response that crossed an account switch")

        token = nil
        await guest.fetchInvites()
        precondition(guest.invites.isEmpty && guest.lastFetchStatus == "Waiting for sign-in")
        print("PASS: token-only host clears the inbox on sign-out")

        guest.addRecentEmail(" Carol@Example.test ")
        precondition(RipulInviteManager(cache: cache).recentEmails == ["carol@example.test"])
        print("PASS: recent invite emails persist in the host's cache")
    }
}
