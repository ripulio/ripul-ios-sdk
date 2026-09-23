import Foundation

/// An ElevenLabs account's plan, credits and billing, in the same quota shape
/// the Claude and Codex account rows use, plus the money the others lack.
///
/// Parsed from ElevenLabs' own JSON (`/v1/user/subscription` and
/// `/v1/usage/character-stats`). Both key paths produce that JSON: the worker
/// passes it through for an account key, and `ElevenLabsDirectAPI` fetches it
/// for a device key, so there is one parser.
struct ElevenLabsUsage: Equatable, Sendable {
    struct Invoice: Equatable, Sendable {
        let amountDue: Decimal
        let currency: String
        let dueAt: Date?
    }
    struct Day: Equatable, Identifiable, Sendable {
        let date: Date
        let credits: Double
        var id: Date { date }
    }

    var quota: CodingAccountUsage
    var creditsUsed: Int?
    var creditsLimit: Int?
    var status: String?
    var billingPeriod: String?
    var nextInvoice: Invoice?
    var openInvoiceCount = 0
    /// Nil when the key cannot read usage stats; empty when there were none.
    var daily: [Day]?

    var statusName: String? {
        guard let status, !status.isEmpty else { return nil }
        switch status {
        case "past_due": return "Past due"
        case "free_disabled": return "Disabled"
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var billingPeriodName: String? {
        switch billingPeriod {
        case "monthly_period": return "Monthly"
        case "3_month_period": return "Every 3 months"
        case "6_month_period": return "Every 6 months"
        case "annual_period": return "Annual"
        default: return nil
        }
    }
    var dailyTotal: Double { daily?.reduce(0) { $0 + $1.credits } ?? 0 }

    static func parse(subscription: Data, characterStats: Data?, now: Date = Date()) throws -> ElevenLabsUsage {
        guard let sub = try JSONSerialization.jsonObject(with: subscription) as? [String: Any] else {
            throw ElevenLabsDirectAPI.Failure.invalidResponse
        }
        return parse(subscription: sub, characterStats: characterStats.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }, now: now)
    }

    static func parse(subscription sub: [String: Any], characterStats stats: [String: Any]?, now: Date = Date()) -> ElevenLabsUsage {
        func int(_ key: String, in object: [String: Any] = sub) -> Int? { (object[key] as? NSNumber)?.intValue }
        var windows: [CodingAccountUsage.Window] = []
        let used = int("character_count"), limit = int("character_limit")
        if let used, let limit, limit > 0 {
            windows.append(.init(id: "credits", label: "Credits",
                                 usedPercent: Double(used) / Double(limit) * 100,
                                 resetsAt: (sub["next_character_count_reset_unix"] as? NSNumber)?.doubleValue))
        }
        if let slots = int("voice_slots_used"), let voiceLimit = int("voice_limit"), voiceLimit > 0 {
            windows.append(.init(id: "voices", label: "Voice slots",
                                 usedPercent: Double(slots) / Double(voiceLimit) * 100))
        }
        var usage = ElevenLabsUsage(
            quota: CodingAccountUsage(plan: sub["tier"] as? String, windows: windows, updatedAt: now.timeIntervalSince1970),
            creditsUsed: used, creditsLimit: limit,
            status: sub["status"] as? String, billingPeriod: sub["billing_period"] as? String)
        let currency = (sub["currency"] as? String)?.uppercased() ?? "USD"
        if let invoice = sub["next_invoice"] as? [String: Any], let cents = int("amount_due_cents", in: invoice) {
            usage.nextInvoice = Invoice(amountDue: Decimal(cents) / 100, currency: currency,
                                        dueAt: (invoice["next_payment_attempt_unix"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        usage.openInvoiceCount = (sub["open_invoices"] as? [Any])?.count ?? 0
        if let stats, let times = stats["time"] as? [NSNumber], let series = stats["usage"] as? [String: [NSNumber]] {
            usage.daily = times.enumerated().map { index, time in
                // Documented as milliseconds; tolerate seconds.
                let raw = time.doubleValue
                let credits = series.values.reduce(0) { $0 + (index < $1.count ? $1[index].doubleValue : 0) }
                return Day(date: Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw), credits: credits)
            }
        }
        return usage
    }

    /// Query for the daily chart: the last 30 days, one bucket per day.
    static func characterStatsQuery(now: Date = Date()) -> [URLQueryItem] {
        let end = Int64(now.timeIntervalSince1970 * 1000)
        return [URLQueryItem(name: "start_unix", value: String(end - 30 * 24 * 60 * 60 * 1000)),
                URLQueryItem(name: "end_unix", value: String(end)),
                URLQueryItem(name: "aggregation_interval", value: "day"),
                URLQueryItem(name: "metric", value: "credits")]
    }
}
