import Foundation

final class FixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static let token = String(repeating: "a", count: 64)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let body: String
        if request.url!.path.hasSuffix("/session") && request.httpMethod == "POST" {
            precondition(request.value(forHTTPHeaderField: "secret") == "customer-credential")
            precondition(request.value(forHTTPHeaderField: "Origin") == "https://customer.test")
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            body = "{\"token\":\"\(Self.token)\",\"expiresAt\":\(Date().timeIntervalSince1970 + 900)}"
        } else {
            precondition(request.value(forHTTPHeaderField: "secret") == nil)
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
            if request.httpMethod == "DELETE" { body = "{\"signedOut\":true}" }
            else { body = "{\"claims\":[{\"id\":\"claim-a\",\"binding_key\":\"CAFE-A\",\"organisation_id\":\"cafe\",\"generation\":1},{\"id\":\"claim-b\",\"binding_key\":\"BAR-A\",\"organisation_id\":\"bar\",\"generation\":1}]}" }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

actor CredentialGate {
    var waiter: CheckedContinuation<[String: String], Never>?
    var entered: CheckedContinuation<Void, Never>?
    var started = false
    func credentials() async -> [String: String] {
        started = true
        entered?.resume(); entered = nil
        return await withCheckedContinuation { waiter = $0 }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { waiter?.resume(returning: ["secret": "customer-credential"]); waiter = nil }
}

@main struct Checks {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let transport = URLSession(configuration: config)
        let client = try EmbeddedAgentClient(baseURL: URL(string: "https://api.test")!, siteKeyID: "sk_a", origin: "https://customer.test", transport: transport) {
            ["secret": "customer-credential", "Origin": "https://attacker.test", "Authorization": "forged"]
        }
        let claims = try await client.claims()
        precondition(claims.map(\.binding_key) == ["CAFE-A", "BAR-A"])
        _ = try await client.claims()
        precondition(FixtureProtocol.requests.filter { $0.url!.path.hasSuffix("/session") }.count == 1)
        print("PASS: separate employment identities; credentials only in exchange; session reused")
        await client.resetIdentity()
        _ = try await client.claims()
        precondition(FixtureProtocol.requests.filter { $0.httpMethod == "DELETE" }.count == 1)
        precondition(FixtureProtocol.requests.filter { $0.url!.path.hasSuffix("/session") && $0.httpMethod == "POST" }.count == 2)
        print("PASS: logout revokes the old session and a new call reauthenticates")

        let gate = CredentialGate()
        let pending = try EmbeddedAgentClient(baseURL: URL(string: "https://api.test")!, siteKeyID: "sk_a", origin: "https://customer.test", transport: transport) { await gate.credentials() }
        let task = Task { try await pending.claims() }
        await gate.waitForStart()
        await pending.resetIdentity()
        await gate.release()
        do { _ = try await task.value; fatalError("Old identity result escaped") }
        catch EmbeddedAgentClient.ClientError.identityChanged { }
        print("PASS: account change invalidates an in-flight authentication result")

        do { _ = try await client.conversation(id: "../other"); fatalError("Path injection accepted") }
        catch EmbeddedAgentClient.ClientError.invalidConfiguration { }
        do { _ = try EmbeddedAgentClient(baseURL: URL(string: "http://api.test")!, siteKeyID: "sk_a", origin: "https://customer.test") { [:] }; fatalError("Insecure base URL accepted") }
        catch EmbeddedAgentClient.ClientError.invalidConfiguration { }
        print("PASS: insecure transport and conversation path injection refused")
    }
}
