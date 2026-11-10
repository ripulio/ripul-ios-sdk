import Foundation

// A sign-in returning to this device (LoopbackSignInReturn.swift): what is
// taken from a request, and the listener itself on this Mac's loopback, asked
// as a browser would. Run with run.sh. The system sheet closing on the answer
// was checked in the iPhone simulator (4 November 2026); see
// chrome-extension/docs/architecture/signInReturnToThePhone.md.
@main struct LoopbackSignInReturnTests {
    @MainActor static func main() async throws {
        // A request's target, from its head. "\r\n" is one Character to Swift:
        // the first listener never found the end of the request line.
        let head = "GET /callback?code=abc&state=s HTTP/1.1\r\nHost: localhost:55811\r\nUser-Agent: Safari\r\nAccept: */*"
        precondition(LoopbackSignInReturn.requestTarget(inHead: head) == "/callback?code=abc&state=s")
        precondition(LoopbackSignInReturn.requestTarget(inHead: "POST /callback HTTP/1.1\r\nHost: x") == nil, "Only a GET")
        precondition(LoopbackSignInReturn.requestTarget(inHead: "GET /callback") == nil)

        // Which return is this sign-in's own.
        func outcome(_ target: String) -> LoopbackSignInReturn.Outcome? {
            LoopbackSignInReturn.outcome(ofRequestTarget: target, path: "/callback", port: 55811, state: "s")
        }
        precondition(outcome("/callback?code=AbC-1%2F2&state=s") == .returned("http://localhost:55811/callback?code=AbC-1%2F2&state=s"),
                     "The address exactly as the browser asked for it")
        precondition(outcome("/callback?code=abc&state=other") == nil, "Another sign-in's state is not taken")
        precondition(outcome("/callback?code=abc") == nil, "Nor no state")
        precondition(outcome("/callback?state=s") == nil, "Nor no code")
        precondition(outcome("/favicon.ico") == nil && outcome("/other?code=abc&state=s") == nil)
        precondition(outcome("/callback?error=access_denied&state=s") == .denied("The sign-in was not authorized."))

        // The return asked for by an authorize address.
        let authorize = URL(string: "https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A55811%2Fcallback&state=s")!
        guard let parsed = LoopbackSignInReturn(authorizeURL: authorize) else { preconditionFailure("A loopback return is recognised") }
        precondition(parsed.port == 55811 && parsed.path == "/callback")
        precondition(LoopbackSignInReturn(authorizeURL: URL(string: "https://claude.com/cai/oauth/authorize?redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=s")!) == nil,
                     "A return to a page elsewhere is not this device's")
        precondition(LoopbackSignInReturn(authorizeURL: URL(string: "https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A55811%2Fcallback")!) == nil,
                     "A return without a state is not taken")

        // The listener itself, on a free port, asked as a browser would.
        let port = try freePort()
        let address = URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A\(port)%2Fcallback&state=s")!
        guard let catcher = LoopbackSignInReturn(authorizeURL: address) else { preconditionFailure() }
        let listening = await catcher.start()
        precondition(listening, "It listens")
        func ask(_ target: String, host: String = "127.0.0.1") async -> String {
            await Task.detached { get(target, host: host, port: port) }.value
        }
        let otherPath = await ask("/favicon.ico"), otherState = await ask("/callback?code=abc&state=other")
        precondition(otherPath.hasPrefix("HTTP/1.1 404"), "Another path")
        precondition(otherState.hasPrefix("HTTP/1.1 404"), "Another state")
        precondition(catcher.outcome == nil, "Nothing is taken from either")
        // On a Mac one process cannot hold both ::1 and 127.0.0.1 on a port
        // (Network.framework refuses the second); the iPhone simulator held
        // both. A browser tries both for "localhost", so one is enough.
        let answered = await ask("/callback?code=abc&state=s")
        precondition(answered.hasPrefix("HTTP/1.1 302") && answered.contains("Location: ripul-sign-in://returned"),
                     "The return is answered with the sheet's own callback: \(answered)")
        precondition(catcher.outcome == .returned("http://localhost:\(port)/callback?code=abc&state=s"))
        let again = await ask("/callback?code=again&state=s")
        precondition(again.hasPrefix("HTTP/1.1 409"), "Only the first return is taken")

        // The port already held, as the tool holds it on the Mac being signed in.
        let second = LoopbackSignInReturn(authorizeURL: address)!
        let secondListening = await second.start()
        precondition(!secondListening, "A port already taken is said, not waited for")
        catcher.stop()
        let afterStop = await ask("/callback?code=abc&state=s")
        precondition(afterStop.isEmpty, "Nothing listens once stopped")
        print("Loopback sign-in return passed: the request line, which return is taken, the listener on the loopback, one return only, a taken port")
    }

    /// A port nothing listens on, from the system.
    static func freePort() throws -> UInt16 {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) } }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// A GET over a plain socket, answer as text; empty when nothing answers.
func get(_ target: String, host: String, port: UInt16) -> String {
    var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                         ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var found: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &found) == 0, let info = found else { return "" }
    defer { freeaddrinfo(found) }
    let descriptor = socket(info.pointee.ai_family, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var wait = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    guard connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { return "" }
    let request = Array("GET \(target) HTTP/1.1\r\nHost: localhost:\(port)\r\nConnection: close\r\n\r\n".utf8)
    _ = request.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
    var answer = [UInt8](repeating: 0, count: 1024)
    let received = answer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
    return received > 0 ? String(decoding: answer.prefix(received), as: UTF8.self) : ""
}
