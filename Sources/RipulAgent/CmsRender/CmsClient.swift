import Foundation

/// HTTP client for the two backend surfaces the native renderer needs:
///  - fetching a CMS definition (pages tree)
///  - running saved queries (`POST /v1/cms-definitions/:id/queries/:slug/run`)
///
/// Follows the SDK's established auth pattern (see SessionChannelClientConfig):
/// the host app injects a `getToken` closure returning a fresh Clerk JWT and
/// every request carries it as a Bearer header. The client holds no auth
/// state of its own.
public struct CmsClientConfig {
    /// Fresh Clerk JWT, refreshed by the host app (AuthTokenStore in the
    /// reference implementation).
    public var getToken: () async -> String?
    /// llm-proxy base, e.g. "https://llm-proxy.ripul.io".
    public var baseUrl: String
    /// Optional site key for @siteKeyId expansion in saved queries.
    public var siteKeyId: String?
    /// Opaque portal credentials (portalAuth.provider 'opaque'): header
    /// name→value pairs the HOST app's own auth system holds (e.g. WAC's
    /// `secret`/`secret-id`). When set and non-empty, portal requests carry
    /// these headers INSTEAD of a Bearer token — the worker forwards them to
    /// the customer backend's validation endpoint and authenticates the
    /// caller as that app's user (member id `<subPrefix>:<principalId>`).
    public var portalCredentialProvider: (() async -> [String: String]?)?

    public init(
        getToken: @escaping () async -> String?,
        baseUrl: String = RipulDomain.llmProxyURL,
        siteKeyId: String? = nil,
        portalCredentialProvider: (() async -> [String: String]?)? = nil
    ) {
        self.getToken = getToken
        self.baseUrl = baseUrl
        self.siteKeyId = siteKeyId
        self.portalCredentialProvider = portalCredentialProvider
    }
}

public enum CmsClientError: Error, LocalizedError {
    case noToken
    case badURL(String)
    case http(Int, String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noToken: return "No auth token available"
        case .badURL(let u): return "Bad URL: \(u)"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .queryFailed(let message): return message
        }
    }
}

public final class CmsClient {
    private let config: CmsClientConfig

    /// Site key threaded into query runs for RLS scoping. Without one, a
    /// Clerk-authed run has no site-key context and owner/site-scoped RLS
    /// policies filter every row — the web portal always supplies it via
    /// BlockRuntimeContext. Resolved per-CMS by the page loader (the site
    /// key whose cmsDefinitionId links to the definition), unless the host
    /// pinned one in the config.
    public var siteKeyId: String?

    /// Visitor mode: a site-key SESSION token (from /api/v1/site-key/validate)
    /// used as the Bearer instead of the Clerk token — queries then run as an
    /// anonymous portal visitor (site-key principal, public role, RLS from
    /// the token's site key).
    public var visitorSessionToken: String?

    /// Publishable key of the resolved site key — blocks that embed the web
    /// app in portal mode (agentChat) inherit it, matching the web block's
    /// "empty siteKey = inherit portal" rule.
    public var siteKeyPublishable: String?

    public init(config: CmsClientConfig) {
        self.config = config
        self.siteKeyId = config.siteKeyId
    }

    /// True when the host app supplied opaque portal credentials — the
    /// loader then runs in member mode (identity = the host app's user)
    /// instead of anonymous visitor mode.
    public var hasPortalCredentials: Bool {
        config.portalCredentialProvider != nil
    }

    /// Site keys linked to the caller's org — used to resolve the RLS
    /// site-key context for a CMS definition.
    public func listSiteKeys() async throws -> [CmsSiteKeySummary] {
        let data = try await request(path: "/admin/site-keys?organizationId=default", method: "GET", body: nil)
        struct ListResponse: Codable { var siteKeys: [CmsSiteKeySummary] }
        return try JSONDecoder().decode(ListResponse.self, from: data).siteKeys
    }

    /// List the owner's CMS definitions (summaries — pages may be present
    /// but fetchDefinition is the authoritative source for rendering).
    public func listDefinitions() async throws -> [CmsRenderDefinition] {
        let data = try await request(path: "/admin/cms-definitions", method: "GET", body: nil)
        struct ListResponse: Codable {
            var cmsDefinitions: [CmsRenderDefinition]
        }
        return try JSONDecoder().decode(ListResponse.self, from: data).cmsDefinitions
    }

    /// Fetch the full definition (owner-scoped admin endpoint — the PoC
    /// authenticates as the Clerk-signed-in owner, same principal the
    /// designer uses).
    public func fetchDefinition(cmsId: String) async throws -> CmsRenderDefinition {
        let data = try await request(path: "/admin/cms-definitions/\(encode(cmsId))", method: "GET", body: nil)
        return try JSONDecoder().decode(CmsRenderDefinition.self, from: data)
    }

    /// Full definition PLUS the pages array as raw JSON — the design
    /// controller edits raw so fields the typed models don't carry
    /// (scriptIds, exportMode, canvas designWidth, …) round-trip untouched
    /// through a save.
    public func fetchDefinitionRaw(cmsId: String) async throws -> (definition: CmsRenderDefinition, rawPages: [CmsJSON]) {
        let data = try await request(path: "/admin/cms-definitions/\(encode(cmsId))", method: "GET", body: nil)
        let definition = try JSONDecoder().decode(CmsRenderDefinition.self, from: data)
        struct PagesOnly: Codable { var pages: [CmsJSON]? }
        let rawPages = (try? JSONDecoder().decode(PagesOnly.self, from: data).pages) ?? []
        return (definition, rawPages)
    }

    /// Owner save path — replaces the pages array wholesale (the web
    /// designer's admin PATCH). Pages travel as raw JSON so unmodeled
    /// fields survive.
    public func patchDefinitionPages(cmsId: String, pages: [CmsJSON]) async throws {
        _ = try await request(
            path: "/admin/cms-definitions/\(encode(cmsId))",
            method: "PATCH",
            body: ["pages": .array(pages)]
        )
    }

    /// Delegated save path — the per-site design endpoint (role-gated
    /// server-side). `siteKey` is the site key's PUBLISHABLE key, matching
    /// the web's `updatePortalDesign`.
    public func patchPortalDesign(cmsId: String, siteKey: String, pages: [CmsJSON]) async throws {
        _ = try await request(
            path: "/v1/cms-definitions/\(encode(cmsId))/design",
            method: "PATCH",
            body: ["siteKeyId": .string(siteKey), "pages": .array(pages)]
        )
    }

    /// The current user's membership on a site key (`GET /v1/site-key/me`).
    /// In opaque-portal mode the credential headers identify the user; the
    /// worker resolves their member row (invite-only portals 401 non-members
    /// and blocked members at the auth gate — surfaced here as `.http(401,…)`).
    public func fetchPortalMembership(siteKey: String) async throws -> CmsPortalMembership {
        let data = try await request(
            path: "/v1/site-key/me?siteKey=\(encode(siteKey))",
            method: "GET",
            body: nil
        )
        return try JSONDecoder().decode(CmsPortalMembership.self, from: data)
    }

    /// Run a saved query by slug. The server holds the SQL and applies RLS;
    /// the client sends only pre-resolved typed params.
    public func runSavedQuery(
        cmsId: String,
        querySlug: String,
        params: [String: CmsJSON]? = nil
    ) async throws -> CmsQueryResult {
        var body: [String: CmsJSON] = [:]
        if let siteKeyId {
            body["siteKeyId"] = .string(siteKeyId)
        }
        if let params, !params.isEmpty {
            body["params"] = .object(params)
        }
        let data = try await request(
            path: "/v1/cms-definitions/\(encode(cmsId))/queries/\(encode(querySlug))/run",
            method: "POST",
            body: body
        )

        struct RunResponse: Codable {
            var ok: Bool
            var rows: [[String: CmsJSON]]?
            var schema: [CmsQueryResultColumn]?
            var error: String?
        }
        let response = try JSONDecoder().decode(RunResponse.self, from: data)
        guard response.ok else {
            throw CmsClientError.queryFailed(response.error ?? "Query failed")
        }
        return CmsQueryResult(rows: response.rows ?? [], schema: response.schema ?? [])
    }

    // MARK: - Internals

    private func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private func request(path: String, method: String, body: [String: CmsJSON]?) async throws -> Data {
        let urlString = config.baseUrl + path
        guard let url = URL(string: urlString) else {
            throw CmsClientError.badURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method

        // Credential precedence: opaque portal headers (host-app auth, no
        // Bearer at all) → site-key session token → Clerk JWT. Opaque wins
        // when configured because the caller's identity IS the host app's
        // user — a session/Clerk token would run as someone else.
        if let provider = config.portalCredentialProvider,
           let headers = await provider(), !headers.isEmpty {
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
        } else if let visitor = visitorSessionToken, !visitor.isEmpty {
            request.setValue("Bearer \(visitor)", forHTTPHeaderField: "Authorization")
        } else if let clerk = await config.getToken(), !clerk.isEmpty {
            request.setValue("Bearer \(clerk)", forHTTPHeaderField: "Authorization")
        } else {
            throw CmsClientError.noToken
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw CmsClientError.http(http.statusCode, bodyText)
        }
        return data
    }
}

/// Response of `GET /v1/site-key/me` — the caller's membership on a portal.
public struct CmsPortalMembership: Codable {
    public var isMember: Bool
    public var role: String?
    public var canDesign: Bool?
}
