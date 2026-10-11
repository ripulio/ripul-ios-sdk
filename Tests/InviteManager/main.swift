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
/// Counts one inbox's own requests: activating the app wakes every inbox in the process.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
let noInvites = "{\"invites\":[]}"
/// An invitation's push, as the server sends it.
func push(_ token: String, to user: String) -> [AnyHashable: Any] {
    ["type": "sessionInvite", "shareToken": token, "roomId": "room", "chatId": "chat", "label": "Plans",
     "inviterUserId": "owner", "inviterName": "Olive", "targetEmail": "alice@example.test",
     "targetUserId": user, "createdAt": "now"]
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

        // An inbox signed in as alice whose only reads are the ones a check asks for.
        func inbox(as bearer: String = "alice-token", grace: Duration = .seconds(60), retryDelay: Duration = .seconds(2)) -> RipulInviteManager {
            let inbox = RipulInviteManager(session: session, refreshInterval: .seconds(60), retryDelay: retryDelay, pushedGrace: grace)
            inbox.configure(token: { _ in bearer }, account: { "alice" })
            return inbox
        }

        do {
            let phone = inbox()
            InviteProtocol.reset { _, n in (200, n == 1 ? noInvites : body("pushed"), 0.05) }
            phone.receivePush(push("pushed", to: "alice"))
            // Shown before any request has even been made.
            precondition(InviteProtocol.requests == 0 && phone.invites.map(\.token) == ["pushed"])
            precondition(phone.invites[0].inviterName == "Olive" && phone.invites[0].label == "Plans" && phone.invites[0].chatId == "chat")
            try await Task.sleep(for: .milliseconds(200))
            // The read the push started came back without it: the row stays.
            precondition(InviteProtocol.requests == 1 && phone.invites.map(\.token) == ["pushed"])
            await phone.fetchInvites()
            // Listed now, so the server's row takes over: one row, not two.
            precondition(phone.invites.map(\.token) == ["pushed"] && phone.invites[0].inviterName == nil)
            print("PASS: a pushed invitation shows at once, survives a read that lacks it, and is not doubled")
        }

        do {
            let phone = inbox()
            InviteProtocol.reset { _, _ in (200, noInvites, 0) }
            phone.receivePush(push("bobs", to: "bob"))
            precondition(phone.invites.isEmpty)
            try await Task.sleep(for: .milliseconds(100))
            precondition(phone.invites.isEmpty && InviteProtocol.requests == 1)
            print("PASS: a push addressed to another account is read for, never shown")
        }

        do {
            let phone = inbox()
            InviteProtocol.reset { _, _ in (200, body("listed"), 0) }
            phone.receivePush(["type": "sessionInvite", "shareToken": "listed", "roomId": "room"])
            precondition(phone.invites.isEmpty)
            try await Task.sleep(for: .milliseconds(100))
            precondition(phone.invites.map(\.token) == ["listed"])
            print("PASS: a push without the row still reads the inbox")
        }

        do {
            let phone = inbox(grace: .milliseconds(250))
            InviteProtocol.reset { _, _ in (200, noInvites, 0) }
            phone.receivePush(push("withdrawn", to: "alice"))
            try await Task.sleep(for: .milliseconds(100))
            precondition(phone.invites.map(\.token) == ["withdrawn"])
            try await Task.sleep(for: .milliseconds(250))
            await phone.fetchInvites()
            precondition(phone.invites.isEmpty)
            phone.receivePush(push("unwanted", to: "alice"))
            await phone.dismissInvite(phone.invites[0])
            try await Task.sleep(for: .milliseconds(100))
            precondition(phone.invites.isEmpty)
            print("PASS: a pushed invitation the inbox never lists goes after its grace, and at once when dismissed")
        }

        do {
            // The Ripul app's token source reaches through a web view; this one never answers.
            var parked: [CheckedContinuation<Void, Never>] = []
            var answers = false
            let phone = RipulInviteManager(session: session, refreshInterval: .seconds(60), tokenTimeout: .milliseconds(80))
            phone.configure(
                token: { _ in
                    if !answers { await withCheckedContinuation { parked.append($0) } }
                    return "alice-token"
                },
                account: { "alice" }
            )
            InviteProtocol.reset { _, _ in (200, body("after"), 0) }
            await phone.fetchInvites()
            precondition(InviteProtocol.requests == 0 && phone.lastFetchStatus == "Waiting for sign-in" && !phone.isLoading)
            answers = true
            await phone.fetchInvites()
            precondition(phone.invites.map(\.token) == ["after"])
            parked.forEach { $0.resume() }
            print("PASS: a token source that never answers does not freeze the inbox")
        }

        do {
            let phone = inbox(as: "retry-token", retryDelay: .milliseconds(50))
            let reads = Counter()
            InviteProtocol.reset { request, _ in
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer retry-token" else { return (200, noInvites, 0) }
                return reads.next() == 1 ? (503, "{}", 0) : (200, body("recovered"), 0)
            }
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            try await Task.sleep(for: .milliseconds(400))
            // The regular refresh is a minute away: only the retry can have read again.
            precondition(reads.value == 2 && phone.invites.map(\.token) == ["recovered"])
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
            try await Task.sleep(for: .milliseconds(40))
            let quiet = Counter()
            InviteProtocol.reset { request, _ in
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer retry-token" { _ = quiet.next() }
                return (503, "{}", 0)
            }
            await phone.fetchInvites()
            try await Task.sleep(for: .milliseconds(300))
            precondition(quiet.value == 1)
            print("PASS: a failed read is tried again shortly while the app is active, and not in the background")
        }

        do {
            // A read caught waiting for its token when the app leaves, and still
            // waiting when it is back: the read asked for on return queues behind it.
            let phone = RipulInviteManager(session: session, refreshInterval: .seconds(60))
            phone.configure(
                token: { _ in try? await Task.sleep(for: .milliseconds(150)); return "resume-token" },
                account: { "alice" }
            )
            InviteProtocol.reset { request, _ in
                (200, request.value(forHTTPHeaderField: "Authorization") == "Bearer resume-token" ? body("back") : noInvites, 0)
            }
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            try await Task.sleep(for: .milliseconds(30))
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
            try await Task.sleep(for: .milliseconds(30))
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            try await Task.sleep(for: .milliseconds(600))
            precondition(phone.invites.map(\.token) == ["back"])
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
            print("PASS: the read asked for on return to the app is not lost behind one cancelled as it left")
        }
    }
}
