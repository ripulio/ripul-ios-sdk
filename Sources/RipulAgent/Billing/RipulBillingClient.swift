import Foundation

// ---------------------------------------------------------------------------
// Native client for the CMS ROW-BILLING admin API (/v1/billing/* on the
// worker, reached through the Pages `api/` proxy like every other solution-
// management client). Scoped to what the native designer surface needs:
// Connect account state, billing rule CRUD, and the connected account's
// Price catalogue for the rule editor's picker.
//
// Server-side truths this client leans on rather than re-implements:
// - Save-time validation lives on the worker; a refused save comes back as a
//   400 carrying human-readable `errors` (and `warnings`), surfaced verbatim.
// - Rules require a METERED Price; the catalogue marks usage type so the
//   picker can explain licensed rows instead of hiding them.
// - Deleting a rule never cancels anything in Stripe — by design.
// ---------------------------------------------------------------------------

public struct RipulBillingAccount {
    public let stripeAccountId: String
    /// onboarding | active | restricted | revoked (revoked is terminal until
    /// the tenant reconnects from their own Stripe dashboard).
    public let onboardingState: String
    public let chargesEnabled: Bool
    public let payoutsEnabled: Bool
    public let livemode: Bool

    init?(json: [String: Any]) {
        guard let stripeAccountId = json["stripeAccountId"] as? String,
              let onboardingState = json["onboardingState"] as? String else { return nil }
        self.stripeAccountId = stripeAccountId
        self.onboardingState = onboardingState
        self.chargesEnabled = json["chargesEnabled"] as? Bool ?? false
        self.payoutsEnabled = json["payoutsEnabled"] as? Bool ?? false
        self.livemode = json["livemode"] as? Bool ?? false
    }
}

public struct RipulBillingRule: Identifiable, Hashable {
    public let id: String
    public let siteKeyId: String
    public var name: String
    /// draft | active
    public var status: String
    public var subjectQuery: String
    public var subjectPkColumn: String
    public var contactEmailColumn: String
    public var displayNameColumn: String?
    public var quantityRelationshipId: String
    /// count | sum | avg | min | max (the Phase 0 aggregate vocabulary).
    public var quantityAgg: String
    public var quantityValueColumn: String?
    public var stripePriceId: String
    public var dryRun: Bool

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let siteKeyId = json["siteKeyId"] as? String,
              let name = json["name"] as? String else { return nil }
        self.id = id
        self.siteKeyId = siteKeyId
        self.name = name
        self.status = json["status"] as? String ?? "draft"
        self.subjectQuery = json["subjectQuery"] as? String ?? ""
        self.subjectPkColumn = json["subjectPkColumn"] as? String ?? ""
        self.contactEmailColumn = json["contactEmailColumn"] as? String ?? ""
        self.displayNameColumn = json["displayNameColumn"] as? String
        self.quantityRelationshipId = json["quantityRelationshipId"] as? String ?? ""
        self.quantityAgg = json["quantityAgg"] as? String ?? "count"
        self.quantityValueColumn = json["quantityValueColumn"] as? String
        self.stripePriceId = json["stripePriceId"] as? String ?? ""
        self.dryRun = json["dryRun"] as? Bool ?? true
    }
}

/// Everything the tenant authors on a rule; ids/timestamps are the server's.
public struct RipulBillingRuleInput {
    public var name = ""
    public var status = "draft"
    public var subjectQuery = ""
    public var subjectPkColumn = ""
    public var contactEmailColumn = ""
    public var displayNameColumn = ""
    public var quantityRelationshipId = ""
    public var quantityAgg = "count"
    public var quantityValueColumn = ""
    public var stripePriceId = ""
    public var dryRun = true

    public init() {}

    public init(rule: RipulBillingRule) {
        name = rule.name
        status = rule.status
        subjectQuery = rule.subjectQuery
        subjectPkColumn = rule.subjectPkColumn
        contactEmailColumn = rule.contactEmailColumn
        displayNameColumn = rule.displayNameColumn ?? ""
        quantityRelationshipId = rule.quantityRelationshipId
        quantityAgg = rule.quantityAgg
        quantityValueColumn = rule.quantityValueColumn ?? ""
        stripePriceId = rule.stripePriceId
        dryRun = rule.dryRun
    }

    func body(siteKeyId: String) -> [String: Any] {
        var body: [String: Any] = [
            "siteKeyId": siteKeyId,
            "name": name,
            "status": status,
            "subjectQuery": subjectQuery,
            "subjectPkColumn": subjectPkColumn,
            "contactEmailColumn": contactEmailColumn,
            "quantityRelationshipId": quantityRelationshipId,
            "quantityAgg": quantityAgg,
            "stripePriceId": stripePriceId,
            "dryRun": dryRun,
        ]
        if !displayNameColumn.isEmpty { body["displayNameColumn"] = displayNameColumn }
        if !quantityValueColumn.isEmpty { body["quantityValueColumn"] = quantityValueColumn }
        return body
    }
}

public struct RipulBillingPrice: Identifiable, Hashable {
    public let id: String
    public let nickname: String?
    public let productName: String
    public let currency: String
    public let unitAmount: Int?
    /// per_unit | tiered
    public let billingScheme: String
    public let interval: String
    public let intervalCount: Int
    /// Rules require "metered"; "licensed" rows render disabled with a reason.
    public let usageType: String
    public let meterEventName: String?
    public let livemode: Bool

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let currency = json["currency"] as? String else { return nil }
        self.id = id
        self.nickname = json["nickname"] as? String
        self.productName = json["productName"] as? String ?? ""
        self.currency = currency
        self.unitAmount = json["unitAmount"] as? Int
        self.billingScheme = json["billingScheme"] as? String ?? "per_unit"
        self.interval = json["interval"] as? String ?? ""
        self.intervalCount = json["intervalCount"] as? Int ?? 1
        self.usageType = json["usageType"] as? String ?? "licensed"
        self.meterEventName = json["meterEventName"] as? String
        self.livemode = json["livemode"] as? Bool ?? false
    }

    public var isMetered: Bool { usageType == "metered" }

    /// "Seats · Standard — 2.50 USD /month" — the picker's one-line label.
    public var displayLabel: String {
        let product = productName.isEmpty ? "(no product)" : productName
        let name = nickname.map { "\(product) · \($0)" } ?? product
        let amount: String
        if billingScheme == "tiered" {
            amount = "tiered"
        } else if let unitAmount {
            amount = String(format: "%.2f %@", Double(unitAmount) / 100, currency.uppercased())
        } else {
            amount = currency.uppercased()
        }
        let cadence = intervalCount > 1 ? "every \(intervalCount) \(interval)s" : "/\(interval)"
        return "\(name) — \(amount) \(cadence)"
    }
}

/// The slices of the linked CMS definition the rule editor's pickers need.
public struct RipulBillingCmsRefs {
    public struct Query: Identifiable, Hashable {
        public let id: String   // slug
        public let name: String
    }

    public struct Relationship: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let fromQuery: String
        public let toQuery: String
    }

    public let queries: [Query]
    /// Only cardinality "many" — the server-rollup direction a rule requires.
    public let relationships: [Relationship]
}

/// A rule save refused by server-side validation. `errors` are the reasons,
/// verbatim; `warnings` may accompany an accepted save via the result instead.
public struct RipulBillingValidationError: LocalizedError {
    public let errors: [String]
    public var errorDescription: String? { errors.joined(separator: "\n") }
}

/// Platform-level readiness: the one deploy-time secret plus what has been
/// runtime-provisioned. Drives first-class UX states instead of raw 500s.
public struct RipulBillingPlatformStatus {
    public let secretKeyConfigured: Bool
    public let webhookConfigured: Bool
    /// Connect enabled on the platform Stripe account — tenant account
    /// creation is refused until the one-time dashboard signup. `nil` means
    /// the server couldn't probe (don't gate the UI on it).
    public let connectEnabled: Bool?
    /// OAuth client id present — unlocks "connect an EXISTING account".
    public let oauthConfigured: Bool
    public let mode: String

    init(json: [String: Any]) {
        secretKeyConfigured = json["secretKeyConfigured"] as? Bool ?? false
        webhookConfigured = json["webhookConfigured"] as? Bool ?? false
        connectEnabled = json["connectEnabled"] as? Bool
        oauthConfigured = json["oauthConfigured"] as? Bool ?? false
        mode = json["mode"] as? String ?? "test"
    }
}

public final class RipulBillingClient {
    private let baseURL: URL
    private let tokenProvider: () -> String?

    public init(
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    /// Tenant account (nil until one exists) plus platform readiness, in one
    /// round trip.
    public func accountState(
        siteKeyId: String
    ) async throws -> (account: RipulBillingAccount?, platform: RipulBillingPlatformStatus) {
        let data = try await send(path: "api/v1/billing/account?siteKeyId=\(encode(siteKeyId))", method: "GET", body: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RipulSolutionContextsError.malformedResponse
        }
        let account = (json["account"] as? [String: Any]).flatMap(RipulBillingAccount.init(json:))
        let platform = RipulBillingPlatformStatus(json: json["platform"] as? [String: Any] ?? [:])
        return (account, platform)
    }

    /// One-tap runtime platform setup: the worker self-registers its Connect
    /// webhook endpoint via the Stripe API. Idempotent.
    public func provisionPlatform() async throws -> RipulBillingPlatformStatus {
        let data = try await send(path: "api/v1/billing/platform/provision", method: "POST", body: [:])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platformJson = json["platform"] as? [String: Any] else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return RipulBillingPlatformStatus(json: platformJson)
    }

    /// Runtime tenant onboarding: creates a Standard account on first call and
    /// returns the Stripe-hosted onboarding URL; later calls mint a fresh link
    /// for the same account ("continue onboarding").
    public func startOnboarding(siteKeyId: String) async throws -> URL {
        let data = try await send(path: "api/v1/billing/connect/start", method: "POST", body: ["siteKeyId": siteKeyId])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return url
    }

    /// Unbind the site key from its connected account ("start over") — the
    /// escape hatch for taking the wrong path, e.g. a new account was created
    /// when the tenant meant to connect an existing one. Removes only Ripul's
    /// binding; nothing in Stripe is cancelled or deleted. Returns how many
    /// rules were left in place (their Price ids reference the old account).
    @discardableResult
    public func unbindAccount(siteKeyId: String) async throws -> Int {
        let data = try await send(path: "api/v1/billing/account?siteKeyId=\(encode(siteKeyId))", method: "DELETE", body: nil)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["rulesRetained"] as? Int ?? 0
    }

    /// The Stripe Connect OAuth URL the tenant is sent to in the browser.
    public func connectAuthorizeUrl(siteKeyId: String) async throws -> URL {
        let data = try await send(path: "api/v1/billing/connect/authorize-url?siteKeyId=\(encode(siteKeyId))", method: "GET", body: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return url
    }

    /// Create a per-unit metered plan ON THE TENANT's connected account
    /// (Meter + Product + metered Price) so nobody opens the Stripe dashboard.
    /// The objects are the tenant's; Ripul takes no cut. Returns the new
    /// Price id, ready for the rule editor's picker.
    public func createPlan(
        siteKeyId: String,
        name: String,
        unitLabel: String,
        unitAmount: Int,
        currency: String,
        interval: String
    ) async throws -> String {
        let data = try await send(
            path: "api/v1/billing/plans",
            method: "POST",
            body: [
                "siteKeyId": siteKeyId,
                "name": name,
                "unitLabel": unitLabel,
                "unitAmount": unitAmount,
                "currency": currency,
                "interval": interval,
                "idempotencyKey": UUID().uuidString,
            ]
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let price = json["price"] as? [String: Any],
              let id = price["id"] as? String else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return id
    }

    public func rules(siteKeyId: String) async throws -> [RipulBillingRule] {
        let data = try await send(path: "api/v1/billing/rules?siteKeyId=\(encode(siteKeyId))", method: "GET", body: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["rules"] as? [[String: Any]] else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return rows.compactMap(RipulBillingRule.init(json:))
    }

    /// Create (`ruleId` nil) or update. Returns the saved rule plus any
    /// warnings the server wants the tenant to see (overlap notices etc.).
    /// Throws `RipulBillingValidationError` when validation refuses the save.
    public func saveRule(
        siteKeyId: String,
        ruleId: String?,
        input: RipulBillingRuleInput
    ) async throws -> (rule: RipulBillingRule, warnings: [String]) {
        let path = ruleId.map { "api/v1/billing/rules/\(encode($0))" } ?? "api/v1/billing/rules"
        let data = try await send(
            path: path,
            method: ruleId == nil ? "POST" : "PUT",
            body: input.body(siteKeyId: siteKeyId),
            validationAware: true
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ruleJson = json["rule"] as? [String: Any],
              let rule = RipulBillingRule(json: ruleJson) else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return (rule, json["warnings"] as? [String] ?? [])
    }

    public func deleteRule(id: String, siteKeyId: String) async throws {
        _ = try await send(path: "api/v1/billing/rules/\(encode(id))?siteKeyId=\(encode(siteKeyId))", method: "DELETE", body: nil)
    }

    /// The connected account's active recurring Prices. A 409 means "not
    /// connected" / "revoked" — surfaced as a server error with the API's own
    /// message; callers that already gate on account state won't hit it.
    public func prices(siteKeyId: String) async throws -> [RipulBillingPrice] {
        let data = try await send(path: "api/v1/billing/prices?siteKeyId=\(encode(siteKeyId))", method: "GET", body: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["prices"] as? [[String: Any]] else {
            throw RipulSolutionContextsError.malformedResponse
        }
        return rows.compactMap(RipulBillingPrice.init(json:))
    }

    /// The linked CMS definition's queries and cardinality-many relationships,
    /// for the editor's pickers. `cmsRef` is the site key's `cmsDefinitionId`,
    /// which may be an internal id or a portal slug — the list is scanned for
    /// either, matching how the worker resolves the link.
    public func cmsRefs(cmsRef: String) async throws -> RipulBillingCmsRefs? {
        let data = try await send(path: "api/admin/cms-definitions", method: "GET", body: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["cmsDefinitions"] as? [[String: Any]] else {
            throw RipulSolutionContextsError.malformedResponse
        }
        guard let cms = rows.first(where: {
            ($0["id"] as? String) == cmsRef || ($0["slug"] as? String) == cmsRef
        }) else { return nil }

        let queries = (cms["queries"] as? [[String: Any]] ?? []).compactMap { q -> RipulBillingCmsRefs.Query? in
            guard let slug = q["slug"] as? String else { return nil }
            return RipulBillingCmsRefs.Query(id: slug, name: (q["name"] as? String) ?? slug)
        }
        let relationships = (cms["relationships"] as? [[String: Any]] ?? []).compactMap { r -> RipulBillingCmsRefs.Relationship? in
            guard let id = r["id"] as? String,
                  (r["cardinality"] as? String) == "many" else { return nil }
            return RipulBillingCmsRefs.Relationship(
                id: id,
                name: (r["name"] as? String) ?? (r["alias"] as? String) ?? id,
                fromQuery: (r["fromQuery"] as? String) ?? "",
                toQuery: (r["toQuery"] as? String) ?? ""
            )
        }
        return RipulBillingCmsRefs(queries: queries, relationships: relationships)
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func send(
        path: String,
        method: String,
        body: [String: Any]?,
        validationAware: Bool = false
    ) async throws -> Data {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw RipulSolutionContextsError.notSignedIn
        }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RipulSolutionContextsError.malformedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RipulSolutionContextsError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RipulSolutionContextsError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // A rule save refused by validation carries the reasons as a
            // string list — surface them as such, not one concatenated blob.
            if validationAware, http.statusCode == 400,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = json["errors"] as? [String], !errors.isEmpty {
                throw RipulBillingValidationError(errors: errors)
            }
            throw RipulSolutionContextsError.serverError(status: http.statusCode, body: data)
        }
        return data
    }
}
