import Foundation

/// The standalone app uses loopback HTTP for installed assets/local commands
/// and pinned Network.framework TLS for the paired Mac. Its CLI child talks
/// to the AI provider directly. Explicit native BYOK speech requests may also
/// reach ElevenLabs; ordinary app/web requests retain the loopback-only policy.
public enum StandaloneNetworkPolicy {
    public static func install() { URLProtocol.registerClass(StandaloneBlockedRequest.self) }
    private static let speechMarker = "RipulNativeElevenLabsRequest"
    static func authorizeDirectSpeech(_ request: NSMutableURLRequest) {
        URLProtocol.setProperty(true, forKey: speechMarker, in: request)
    }
    static func isDirectSpeechRequest(_ request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: speechMarker, in: request) as? Bool == true,
              let url = request.url, url.scheme == "https", url.host == "api.elevenlabs.io",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return false }
        if url.path == "/v2/voices" { return request.httpMethod == "GET" }
        if url.path == "/v1/single-use-token/realtime_scribe" { return request.httpMethod == "POST" }
        let parts = url.pathComponents
        guard parts.count == 5, parts[1] == "v1", parts[2] == "text-to-speech", parts[4] == "stream", request.httpMethod == "POST" else { return false }
        return !parts[3].isEmpty && parts[3].utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func denies(_ url: URL, standalone: Bool) -> Bool {
        guard standalone, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return !["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host?.lowercased() ?? "")
    }
}

private final class StandaloneBlockedRequest: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        if StandaloneNetworkPolicy.isDirectSpeechRequest(request) { return false }
        guard let url = request.url else { return false }
        return StandaloneNetworkPolicy.denies(url, standalone: UserDefaults.standard.bool(forKey: "ripul.standalone.enabled"))
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "This network service is unavailable in standalone mode"]))
    }
    override func stopLoading() {}
}
