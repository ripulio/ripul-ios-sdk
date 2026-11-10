import Foundation

/// HTTP client for the two backend surfaces the native renderer needs:
///  - fetching a CMS definition (pages tree)
///  - running saved queries (`POST /v1/cms-definitions/:id/queries/:slug/run`)
///
/// Follows the SDK's established auth pattern:
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
    /// The signed-in person as the host app knows them (the web's
    /// `auth.user`): the account avatar's initials and name, and the email the
    /// bell's read records are kept under when the member lookup has none.
    public var userName: String?
    public var userEmail: String?
    /// The address the host app's site key allows (one of its `allowedOrigins`),
    /// e.g. WAC Next's `https://wac-next.app`, presented as the `Origin` when the
    /// key is checked. A native app has no page of its own, so without it the
    /// check presents the Ripul portal host (`RipulDomain.demoURL`), and only a
    /// key that allows that host loads.
    public var origin: String?
    /// Anonymous visitor mode only (a `visitorSiteKey` and no portal
    /// credentials): send the publishable key as `X-Site-Key`, with `origin` as
    /// the `Origin`, instead of the site-key session token. The worker runs
    /// queries, views and mutations for that header itself, only those marked
    /// `exposedToSiteKey`, with row rules held to the site key; it refuses a
    /// session token on those routes. Off by default.
    public var visitorSendsSiteKey: Bool
    /// A member signed in with the site's own identity provider (the site key's
    /// `portalAuth` 'clerk', e.g. WAC's business accounts at clerk.wac.rocks): a
    /// fresh JWT from that provider, sent as the Bearer. The worker checks it
    /// against the key's JWKS and runs every query as that member, as it does
    /// for the site's own web pages. With a `visitorSiteKey`, the loader loads as
    /// a member, as with `portalCredentialProvider`. nil (no token yet, or signed
    /// out) fails the request rather than falling back to another identity.
    public var portalTokenProvider: (() async -> String?)?

    public init(
        getToken: @escaping () async -> String?,
        baseUrl: String = RipulDomain.llmProxyURL,
        siteKeyId: String? = nil,
        portalCredentialProvider: (() async -> [String: String]?)? = nil,
        userName: String? = nil,
        userEmail: String? = nil,
        origin: String? = nil,
        visitorSendsSiteKey: Bool = false,
        portalTokenProvider: (() async -> String?)? = nil
    ) {
        self.getToken = getToken
        self.baseUrl = baseUrl
        self.siteKeyId = siteKeyId
        self.portalCredentialProvider = portalCredentialProvider
        self.userName = userName
        self.userEmail = userEmail
        self.origin = origin
        self.visitorSendsSiteKey = visitorSendsSiteKey
        self.portalTokenProvider = portalTokenProvider
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
    public var userName: String? { config.userName.flatMap { $0.isEmpty ? nil : $0 } }
    public var userEmail: String? { config.userEmail.flatMap { $0.isEmpty ? nil : $0 } }
    /// The host app's own origin for site-key checks (`CmsClientConfig.origin`).
    public var origin: String? { config.origin.flatMap { $0.isEmpty ? nil : $0 } }

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

    /// Visitor mode with `CmsClientConfig.visitorSendsSiteKey`: the publishable
    /// key sent as `X-Site-Key` (with the `Origin`) in place of any token.
    public var visitorSiteKeyHeader: String?

    /// Whether the loader should use `visitorSiteKeyHeader` for an anonymous visitor.
    public var visitorSendsSiteKey: Bool { config.visitorSendsSiteKey }

    /// Publishable key of the resolved site key — blocks that embed the web
    /// app in portal mode (agentChat) inherit it, matching the web block's
    /// "empty siteKey = inherit portal" rule.
    public var siteKeyPublishable: String?

    /// A site that signs people in by an emailed code (`CmsSiteSignIn`): the
    /// session of a signed-in member of the site, sent as the Bearer in place of
    /// the visitor's token. The loader sets it only while the person is one of
    /// the site's members; a signed-in guest's queries run as a visitor, and the
    /// booking blocks send the guest's session themselves.
    public var siteSessionToken: (() async -> String?)?

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

    /// True when the host app signs its member in with the site's own identity
    /// provider (`CmsClientConfig.portalTokenProvider`).
    public var hasPortalToken: Bool {
        config.portalTokenProvider != nil
    }

    /// The caller is one of the site's members, by either the host app's
    /// credentials or the site's own sign-in: the loader loads as that member.
    public var signsInAsMember: Bool {
        hasPortalCredentials || hasPortalToken
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
        // One site that fails to decode is left out rather than emptying the
        // whole list (a numeric frame gap once hid every site).
        struct Lossy: Decodable {
            let value: CmsRenderDefinition?
            init(from decoder: Decoder) throws { value = try? CmsRenderDefinition(from: decoder) }
        }
        struct ListResponse: Decodable {
            var cmsDefinitions: [Lossy]
        }
        return try JSONDecoder().decode(ListResponse.self, from: data).cmsDefinitions.compactMap(\.value)
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

    /// Run a saved mutation by slug (`runSavedMutation` in
    /// cmsDefinitionsService.ts). Returns the rows it changed; a refusal
    /// throws with the server's message.
    public func runSavedMutation(
        cmsId: String,
        mutationSlug: String,
        params: [String: CmsJSON]? = nil
    ) async throws -> Int {
        try await runSavedMutationResult(cmsId: cmsId, mutationSlug: mutationSlug, params: params).affectedRows
    }

    /// A mutation run's result: the rows it changed, and a `warning` when it
    /// succeeded but a follow-up call (an endpoint's `then` step) didn't.
    public struct MutationRunResult {
        public var affectedRows: Int
        public var warning: String?
        /// The run's `result` (an endpoint mutation's answer), for a creatable choice.
        public var result: CmsJSON? = nil
    }

    public func runSavedMutationResult(
        cmsId: String,
        mutationSlug: String,
        params: [String: CmsJSON]? = nil
    ) async throws -> MutationRunResult {
        var body: [String: CmsJSON] = [:]
        if let siteKeyId {
            body["siteKeyId"] = .string(siteKeyId)
        }
        if let params, !params.isEmpty {
            body["params"] = .object(params)
        }
        let data = try await request(
            path: "/v1/cms-definitions/\(encode(cmsId))/mutations/\(encode(mutationSlug))/run",
            method: "POST",
            body: body
        )
        struct RunResponse: Decodable {
            var ok: Bool
            var affectedRows: Int?
            var error: String?
            var warning: String?
            var result: CmsJSON?
        }
        let response = try JSONDecoder().decode(RunResponse.self, from: data)
        guard response.ok else {
            throw CmsClientError.queryFailed(response.error ?? "Mutation failed")
        }
        return MutationRunResult(affectedRows: response.affectedRows ?? 0,
                                 warning: response.warning.flatMap { $0.isEmpty ? nil : $0 },
                                 result: response.result)
    }

    /// Raw JSON call to an llm-proxy route a block owns (billing, files…),
    /// with the same credentials as every other call.
    public func json(_ path: String, method: String = "GET", body: [String: CmsJSON]? = nil) async throws -> CmsJSON {
        let data = try await request(path: path, method: method, body: body)
        return try JSONDecoder().decode(CmsJSON.self, from: data)
    }

    /// Raw bytes in or out of a block-owned route (file uploads and
    /// downloads): the body goes as-is with its own content type.
    public func raw(_ path: String, method: String = "GET", data: Data? = nil, contentType: String? = nil) async throws -> Data {
        try await request(path: path, method: method, body: nil, rawBody: data, contentType: contentType)
    }

    // MARK: - Internals

    private func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    // MARK: - Views

    /// Run a saved view (`POST …/views/:slug/run`), read as it streams: the
    /// base rows first, then each source's results as they finish. `keys`
    /// asks only for those rows' per-row sources (rows that came back
    /// `later`). A server that answers in one piece is read the same way.
    public func runView(cmsId: String, viewSlug: String, params: [String: CmsJSON]? = nil,
                        keys: [String]? = nil) -> AsyncThrowingStream<CmsJSON, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: CmsJSON] = [:]
                    if let siteKeyId { body["siteKeyId"] = .string(siteKeyId) }
                    if let params, !params.isEmpty { body["params"] = .object(params) }
                    if let keys { body["keys"] = .array(keys.map(CmsJSON.string)) }
                    var request = try await makeRequest(
                        path: "/v1/cms-definitions/\(encode(cmsId))/views/\(encode(viewSlug))/run",
                        method: "POST", body: body)
                    request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    if let http, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count > 65_536 { break } }
                        // A failed base answers with its status and one JSON
                        // error line (`{"type":"error","error":…}`, or the
                        // whole answer's `{ok:false,error}`): pass it on as an
                        // event so its message shows, not the raw status.
                        let text = String(data: data, encoding: .utf8) ?? ""
                        if let line = text.split(separator: "\n").first,
                           let json = try? JSONDecoder().decode(CmsJSON.self, from: Data(line.utf8)),
                           let message = json.objectValue?.string("error") {
                            continuation.yield(.object(["type": .string("error"), "error": .string(message)]))
                            continuation.finish()
                            return
                        }
                        throw CmsClientError.http(http.statusCode, text)
                    }
                    let streamed = http?.value(forHTTPHeaderField: "Content-Type")?.contains("ndjson") ?? false
                    if streamed {
                        for try await line in bytes.lines {
                            let text = line.trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty,
                                  let json = try? JSONDecoder().decode(CmsJSON.self, from: Data(text.utf8)) else { continue }
                            continuation.yield(json)
                        }
                    } else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        continuation.yield(try JSONDecoder().decode(CmsJSON.self, from: data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Requests

    private func request(path: String, method: String, body: [String: CmsJSON]?,
                         rawBody: Data? = nil, contentType: String? = nil) async throws -> Data {
        let request = try await makeRequest(path: path, method: method, body: body, rawBody: rawBody, contentType: contentType)
        return try await send(request)
    }

    /// A request with the caller's credentials and body.
    private func makeRequest(path: String, method: String, body: [String: CmsJSON]?,
                             rawBody: Data? = nil, contentType: String? = nil) async throws -> URLRequest {
        let urlString = config.baseUrl + path
        guard let url = URL(string: urlString) else {
            throw CmsClientError.badURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method

        // Credential precedence: opaque portal headers (host-app auth, no
        // Bearer at all) → the site's own sign-in → site-key session token →
        // Clerk JWT. A member's credential wins when configured because the
        // caller's identity IS that member — a session/Clerk token would run
        // as someone else.
        if let provider = config.portalCredentialProvider,
           let headers = await provider(), !headers.isEmpty {
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
        } else if let provider = config.portalTokenProvider {
            // Never another identity in its place: no token means signed out.
            guard let token = await provider(), !token.isEmpty else { throw CmsClientError.noToken }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let provider = siteSessionToken, let token = await provider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let key = visitorSiteKeyHeader, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-Site-Key")
            request.setValue(origin ?? RipulDomain.demoURL, forHTTPHeaderField: "Origin")
        } else if let visitor = visitorSessionToken, !visitor.isEmpty {
            request.setValue("Bearer \(visitor)", forHTTPHeaderField: "Authorization")
        } else if let clerk = await config.getToken(), !clerk.isEmpty {
            request.setValue("Bearer \(clerk)", forHTTPHeaderField: "Authorization")
        } else {
            throw CmsClientError.noToken
        }

        // What this build draws, so the server can later serve a fallback to a build without it.
        request.setValue(CmsBlockRegistry.capabilities.joined(separator: ","), forHTTPHeaderField: CmsPrimitives.capabilitiesHeader)

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        } else if let rawBody {
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = rawBody
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // A refusal is JSON with an `error`: keep that message whole, as
            // `{"error": …}`, so a long one is not cut into invalid JSON and
            // shown raw. Anything else is cut to 500 characters.
            if let message = (try? JSONDecoder().decode([String: CmsJSON].self, from: data))?.string("error"),
               let encoded = try? JSONEncoder().encode(["error": message]),
               let text = String(data: encoded, encoding: .utf8) {
                throw CmsClientError.http(http.statusCode, text)
            }
            let bodyText = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw CmsClientError.http(http.statusCode, bodyText)
        }
        return data
    }
}

/// Response of `GET /v1/site-key/me` — the caller's membership on a portal.
public struct CmsPortalMembership: Codable, Equatable {
    public var isMember: Bool
    public var role: String?
    public var canDesign: Bool?
    /// The email the membership was matched on (SiteKeyMeResponse.email).
    public var email: String?
}
