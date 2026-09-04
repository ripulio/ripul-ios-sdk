import Foundation

// ---------------------------------------------------------------------------
// Model catalog admin — the native mirror of the web "Models" tab's data.
//
// The catalog is a single D1 row (whole catalog as JSON) behind /admin/models*,
// gated server-side on `admin:manage_site_keys`. Like the web grid, this shows
// the STORED catalog only — the system CLI floor (SYSTEM_CLI_MODELS) merged
// into /v1/models does not appear here unless a stored row overrides it.
//
// Writes are Clerk-authed, reached through the web app's API proxy
// (`<baseURL>/api/*` → llm-proxy) exactly as the peer admin clients do.
// ---------------------------------------------------------------------------

/// A catalog entry as stored server-side (`CatalogModelDefinition`).
public struct RipulCatalogModel: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// "openai" | "anthropic" | "openrouter" | "backend"
    public var provider: String
    /// For backend models: the wire format ("openai" | "anthropic" | "openrouter").
    public var apiFormat: String?
    /// CF AI Gateway provider prefix, e.g. "google-ai-studio".
    public var gatewayProvider: String?
    public var modelId: String
    public var url: String
    public var secretName: String?
    public var perMInput: Double
    public var perMOutput: Double
    public var maxInputTokens: Int?
    public var maxOutputTokens: Int?
    public var description: String?
    public var enabled: Bool
    public var sortOrder: Int
    /// "standard" | "premium"
    public var tier: String
    public var group: String?
    public var capabilities: [String]?
    public var supportsThinking: Bool?
    public var useNativeEndpoint: Bool?
    /// Client-side model type ("claude-cli", "antigravity-cli", …). CLI models
    /// are never proxy-routed, so provider/url are vestigial for them.
    public var clientType: String?
    public var supportsTools: Bool?
    public var cliMode: String?
    public var cliAllowedTools: [String]?
    public var cliRawMode: Bool?
    public var cliModelId: String?
    public var cliEffort: String?
    public var addedAt: String?
    public var updatedAt: String?

    public var isCli: Bool {
        (clientType ?? "").hasSuffix("-cli") || !(cliModelId ?? "").isEmpty
    }
    /// Section heading; rows without an explicit group fall back to provider.
    public var displayGroup: String {
        if let group, !group.isEmpty { return group }
        return provider.capitalized
    }
    /// The badge text: what kind of thing this row is.
    public var typeLabel: String {
        if let clientType, !clientType.isEmpty { return clientType }
        return provider
    }

    // The D1 blob has accreted rows from several schema generations; decode
    // defensively so one sparse row can't sink the whole screen.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? "backend"
        apiFormat = try? c.decodeIfPresent(String.self, forKey: .apiFormat)
        gatewayProvider = try? c.decodeIfPresent(String.self, forKey: .gatewayProvider)
        modelId = (try? c.decodeIfPresent(String.self, forKey: .modelId)) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        secretName = try? c.decodeIfPresent(String.self, forKey: .secretName)
        perMInput = (try? c.decodeIfPresent(Double.self, forKey: .perMInput)) ?? 0
        perMOutput = (try? c.decodeIfPresent(Double.self, forKey: .perMOutput)) ?? 0
        maxInputTokens = try? c.decodeIfPresent(Int.self, forKey: .maxInputTokens)
        maxOutputTokens = try? c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        sortOrder = (try? c.decodeIfPresent(Int.self, forKey: .sortOrder)) ?? 0
        tier = (try? c.decodeIfPresent(String.self, forKey: .tier)) ?? "standard"
        group = try? c.decodeIfPresent(String.self, forKey: .group)
        capabilities = try? c.decodeIfPresent([String].self, forKey: .capabilities)
        supportsThinking = try? c.decodeIfPresent(Bool.self, forKey: .supportsThinking)
        useNativeEndpoint = try? c.decodeIfPresent(Bool.self, forKey: .useNativeEndpoint)
        clientType = try? c.decodeIfPresent(String.self, forKey: .clientType)
        supportsTools = try? c.decodeIfPresent(Bool.self, forKey: .supportsTools)
        cliMode = try? c.decodeIfPresent(String.self, forKey: .cliMode)
        cliAllowedTools = try? c.decodeIfPresent([String].self, forKey: .cliAllowedTools)
        cliRawMode = try? c.decodeIfPresent(Bool.self, forKey: .cliRawMode)
        cliModelId = try? c.decodeIfPresent(String.self, forKey: .cliModelId)
        cliEffort = try? c.decodeIfPresent(String.self, forKey: .cliEffort)
        addedAt = try? c.decodeIfPresent(String.self, forKey: .addedAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

/// The catalog's per-context default model ids.
public struct RipulModelCatalogDefaults: Codable, Equatable {
    public var free: String
    public var pro: String
    public var enterprise: String
    public var siteKey: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        free = (try? c.decodeIfPresent(String.self, forKey: .free)) ?? ""
        pro = (try? c.decodeIfPresent(String.self, forKey: .pro)) ?? ""
        enterprise = (try? c.decodeIfPresent(String.self, forKey: .enterprise)) ?? ""
        siteKey = (try? c.decodeIfPresent(String.self, forKey: .siteKey)) ?? ""
    }
}

public struct RipulModelCatalogStats: Codable {
    public var totalModels: Int
    public var enabledModels: Int
}

/// GET /admin/models — full stored catalog with stats.
public struct RipulAdminModelCatalog: Codable {
    public struct Catalog: Codable {
        public var version: String
        public var updatedAt: String
        public var models: [RipulCatalogModel]
        public var defaults: RipulModelCatalogDefaults
    }
    public var catalog: Catalog
    public var stats: RipulModelCatalogStats?
}

/// Write shape (`UpsertModelRequest`). nil fields are omitted, and the server's
/// PATCH merges field-by-field, so a partial body leaves the rest unchanged.
public struct RipulModelUpsert: Encodable {
    public var id: String?
    public var name: String
    public var provider: String
    public var apiFormat: String?
    public var gatewayProvider: String?
    public var modelId: String
    public var url: String
    public var secretName: String?
    public var perMInput: Double
    public var perMOutput: Double
    public var maxInputTokens: Int?
    public var maxOutputTokens: Int?
    public var description: String?
    public var enabled: Bool
    public var sortOrder: Int?
    public var tier: String
    public var group: String?
    public var supportsThinking: Bool?
    public var useNativeEndpoint: Bool?
    public var clientType: String?
    public var supportsTools: Bool?
    public var cliMode: String?
    public var cliRawMode: Bool?
    public var cliModelId: String?
    public var cliEffort: String?

    public init(
        id: String? = nil,
        name: String,
        provider: String,
        apiFormat: String? = nil,
        gatewayProvider: String? = nil,
        modelId: String,
        url: String,
        secretName: String? = nil,
        perMInput: Double,
        perMOutput: Double,
        maxInputTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        description: String? = nil,
        enabled: Bool,
        sortOrder: Int? = nil,
        tier: String,
        group: String? = nil,
        supportsThinking: Bool? = nil,
        useNativeEndpoint: Bool? = nil,
        clientType: String? = nil,
        supportsTools: Bool? = nil,
        cliMode: String? = nil,
        cliRawMode: Bool? = nil,
        cliModelId: String? = nil,
        cliEffort: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.apiFormat = apiFormat
        self.gatewayProvider = gatewayProvider
        self.modelId = modelId
        self.url = url
        self.secretName = secretName
        self.perMInput = perMInput
        self.perMOutput = perMOutput
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.description = description
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.tier = tier
        self.group = group
        self.supportsThinking = supportsThinking
        self.useNativeEndpoint = useNativeEndpoint
        self.clientType = clientType
        self.supportsTools = supportsTools
        self.cliMode = cliMode
        self.cliRawMode = cliRawMode
        self.cliModelId = cliModelId
        self.cliEffort = cliEffort
    }
}

/// A model found on the CF AI Gateway (POST /admin/models/discover).
public struct RipulDiscoveredModel: Codable, Identifiable, Hashable {
    public var gatewayId: String
    public var catalogId: String
    public var name: String
    public var provider: String
    public var modelId: String
    public var providerName: String
    public var perMInput: Double
    public var perMOutput: Double
    public var supportsThinking: Bool?

    public var id: String { gatewayId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gatewayId = try c.decode(String.self, forKey: .gatewayId)
        catalogId = (try? c.decodeIfPresent(String.self, forKey: .catalogId)) ?? gatewayId
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? gatewayId
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? "backend"
        modelId = (try? c.decodeIfPresent(String.self, forKey: .modelId)) ?? ""
        providerName = (try? c.decodeIfPresent(String.self, forKey: .providerName)) ?? ""
        perMInput = (try? c.decodeIfPresent(Double.self, forKey: .perMInput)) ?? 0
        perMOutput = (try? c.decodeIfPresent(Double.self, forKey: .perMOutput)) ?? 0
        supportsThinking = try? c.decodeIfPresent(Bool.self, forKey: .supportsThinking)
    }
}

public struct RipulDiscoverResult: Codable {
    public struct Match: Codable, Hashable {
        public var discovered: RipulDiscoveredModel
        public var catalogId: String
    }
    public var discovered: [RipulDiscoveredModel]
    public var newModels: [RipulDiscoveredModel]
    public var existingMatches: [Match]
    public var totalGatewayModels: Int
}

/// A catalog price that disagrees with the gateway (POST /admin/models/verify-costs).
public struct RipulCostDiscrepancy: Codable, Identifiable, Hashable {
    public struct Prices: Codable, Hashable {
        public var perMInput: Double
        public var perMOutput: Double
    }
    public var catalogId: String
    public var modelName: String
    public var modelId: String
    public var catalog: Prices
    public var gateway: Prices

    public var id: String { catalogId }
}

public struct RipulVerifyCostsResult: Codable {
    public var discrepancies: [RipulCostDiscrepancy]
    public var totalChecked: Int
    public var totalMatched: Int
}

public enum RipulModelCatalogError: LocalizedError {
    case notSignedIn
    /// Non-2xx. Carries the server message — its validation wording (required
    /// fields, duplicate ids, built-in deletes) beats anything synthesized here.
    case server(status: Int, message: String)
    case transport(Error)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Ripul."
        case .server(let status, let message):
            return message.isEmpty ? "Request failed (HTTP \(status))." : message
        case .transport(let error):
            return error.localizedDescription
        case .malformedResponse:
            return "The server returned an unexpected response."
        }
    }
}

/// CRUD + gateway operations over `/admin/models*`.
public final class RipulModelCatalogClient {
    private let baseURL: URL
    private let tokenProvider: () -> String?

    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    public func fetchCatalog() async throws -> RipulAdminModelCatalog {
        let data = try await send(path: "api/admin/models", method: "GET")
        return try decode(RipulAdminModelCatalog.self, from: data)
    }

    public func create(_ model: RipulModelUpsert) async throws {
        _ = try await send(path: "api/admin/models", method: "POST", body: try encodeBody(model))
    }

    public func update(id: String, _ model: RipulModelUpsert) async throws {
        _ = try await send(path: "api/admin/models/\(encode(id))", method: "PATCH", body: try encodeBody(model))
    }

    /// Partial PATCH — flips one field, everything else keeps its stored value.
    public func setEnabled(id: String, _ enabled: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        _ = try await send(path: "api/admin/models/\(encode(id))", method: "PATCH", body: body)
    }

    public func delete(id: String) async throws {
        _ = try await send(path: "api/admin/models/\(encode(id))", method: "DELETE")
    }

    /// Slots: "free" | "pro" | "enterprise" | "siteKey". Absent slots unchanged.
    public func updateDefaults(_ slots: [String: String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: slots)
        _ = try await send(path: "api/admin/models/defaults", method: "PATCH", body: body)
    }

    public func discover() async throws -> RipulDiscoverResult {
        let data = try await send(path: "api/admin/models/discover", method: "POST")
        return try decode(RipulDiscoverResult.self, from: data)
    }

    /// Returns the number actually imported (already-present ids are skipped).
    public func importDiscovered(gatewayIds: [String]) async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["gatewayIds": gatewayIds])
        let data = try await send(path: "api/admin/models/discover/import", method: "POST", body: body)
        struct R: Decodable { let imported: Int }
        return try decode(R.self, from: data).imported
    }

    public func verifyCosts() async throws -> RipulVerifyCostsResult {
        let data = try await send(path: "api/admin/models/verify-costs", method: "POST")
        return try decode(RipulVerifyCostsResult.self, from: data)
    }

    /// Returns the number of models whose prices were updated to gateway values.
    public func applyCostUpdates(catalogIds: [String]) async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["catalogIds": catalogIds])
        let data = try await send(path: "api/admin/models/apply-cost-updates", method: "POST", body: body)
        struct R: Decodable { let updated: Int }
        return try decode(R.self, from: data).updated
    }

    // MARK: - Transport

    private func send(path: String, method: String, body: Data? = nil) async throws -> Data {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw RipulModelCatalogError.notSignedIn
        }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RipulModelCatalogError.malformedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RipulModelCatalogError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RipulModelCatalogError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RipulModelCatalogError.server(
                status: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            throw RipulModelCatalogError.malformedResponse
        }
        return decoded
    }

    private func encodeBody(_ model: RipulModelUpsert) throws -> Data {
        do {
            return try JSONEncoder().encode(model)
        } catch {
            throw RipulModelCatalogError.transport(error)
        }
    }

    /// The API returns `{ "error": "..." }` on failure; fall back to the raw
    /// body so a proxy/HTML error page is still legible rather than blank.
    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String {
            return error
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
