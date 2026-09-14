import Foundation

/// The standalone app uses loopback HTTP for installed assets/local commands
/// and pinned Network.framework TLS for the paired Mac. Its CLI child talks
/// to the AI provider directly. No other app URLSession traffic is required.
public enum StandaloneNetworkPolicy {
    public static func install() { URLProtocol.registerClass(StandaloneBlockedRequest.self) }
    static func denies(_ url: URL, standalone: Bool) -> Bool {
        guard standalone, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return !["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host?.lowercased() ?? "")
    }
}

private final class StandaloneBlockedRequest: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return StandaloneNetworkPolicy.denies(url, standalone: UserDefaults.standard.bool(forKey: "ripul.standalone.enabled"))
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "This network service is unavailable in standalone mode"]))
    }
    override func stopLoading() {}
}
