import Foundation
import Combine

struct ManagedDomainZone: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let nameservers: [String]
}
struct DomainSiteChoice: Decodable, Identifiable {
    struct Key: Decodable, Identifiable { let id: String; let name: String }
    let id: String
    let name: String
    let keys: [Key]
}
struct SiteDomainAddress: Decodable, Identifiable {
    let hostname: String
    let cmsId: String?
    let siteKeyId: String?
    let status: String
    let message: String?
    let managed: Bool
    let `protected`: Bool
    var id: String { hostname }
    var statusTitle: String {
        switch status {
        case "live": return "Live"
        case "error": return "Needs attention"
        case "disconnected": return "Disconnected"
        default: return "Setting up"
        }
    }
}
struct SiteDomainsOverview: Decodable {
    let configured: Bool
    let connectionError: String?
    let zones: [ManagedDomainZone]
    let sites: [DomainSiteChoice]
    let addresses: [SiteDomainAddress]
}
struct DomainDNSRecord: Decodable, Identifiable {
    let id: String
    let type: String
    let name: String
    let content: String
    let priority: Int?
}
struct DomainZoneReview: Decodable {
    let zone: ManagedDomainZone
    let records: [DomainDNSRecord]
    let discovered: [DomainDNSRecord]
}

/// Admin transport. Tokens come from the signed-in app; Cloudflare keys never enter this client.
struct SiteDomainsClient {
    private struct Failure: Decodable { let error: String }
    let config: CmsClientConfig
    func request<T: Decodable>(_ tail: String = "", method: String = "GET", body: [String: CmsJSON]? = nil) async throws -> T {
        guard let token = await config.getToken(), !token.isEmpty else { throw CmsClientError.noToken }
        guard let url = URL(string: config.baseUrl + "/admin/site-domains" + tail) else { throw CmsClientError.badURL(tail) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "The domain request failed. Refresh to check its status."
            throw CmsClientError.queryFailed(reason)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func perform(_ tail: String, method: String = "POST", body: [String: CmsJSON] = [:]) async throws {
        struct Result: Decodable {}
        let _: Result = try await request(tail, method: method, body: method == "DELETE" ? nil : body)
    }
    static func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value }
}

@MainActor
final class SiteDomainsModel: ObservableObject {
    @Published var overview: SiteDomainsOverview?
    @Published var busy = false
    @Published var error: String?
    let client: SiteDomainsClient
    init(config: CmsClientConfig) { client = SiteDomainsClient(config: config) }
    func refresh() async throws { overview = try await client.request() }
    func act(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await work() } catch { self.error = error.localizedDescription }
    }
}
