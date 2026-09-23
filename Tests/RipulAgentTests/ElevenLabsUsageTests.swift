import XCTest
@testable import RipulAgent

final class ElevenLabsUsageTests: XCTestCase {
    func testSubscriptionMapsToQuotaAndBilling() {
        let usage = ElevenLabsUsage.parse(subscription: [
            "tier": "creator", "character_count": 25_000, "character_limit": 100_000,
            "next_character_count_reset_unix": 1_790_000_000, "voice_slots_used": 3, "voice_limit": 30,
            "status": "active", "currency": "gbp", "billing_period": "monthly_period",
            "next_invoice": ["amount_due_cents": 1_980, "next_payment_attempt_unix": 1_790_000_000],
            "open_invoices": [],
        ], characterStats: nil)
        XCTAssertEqual(usage.quota.plan, "creator")
        XCTAssertEqual(usage.quota.windows.map(\.id), ["credits", "voices"])
        XCTAssertEqual(usage.quota.windows[0].usedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(usage.quota.windows[0].resetsAt, 1_790_000_000)
        XCTAssertEqual(usage.nextInvoice?.amountDue, Decimal(string: "19.8"))
        XCTAssertEqual(usage.nextInvoice?.currency, "GBP")
        XCTAssertEqual(usage.billingPeriodName, "Monthly")
        XCTAssertNil(usage.daily, "No stats means the key could not read them, not zero usage")
    }

    func testDailyStatsSumBreakdownsAndAcceptMilliseconds() {
        let usage = ElevenLabsUsage.parse(subscription: ["tier": "free"], characterStats: [
            "time": [1_790_000_000_000, 1_790_086_400_000],
            "usage": ["All": [100, 50], "Other": [1, 2]],
        ])
        XCTAssertEqual(usage.daily?.map(\.credits), [101, 52])
        XCTAssertEqual(usage.daily?.first?.date, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(usage.dailyTotal, 153)
        XCTAssertTrue(usage.quota.windows.isEmpty)
    }

    func testDirectPolicyAllowsOnlyReadOnlyUsageRoutes() throws {
        func authorized(_ path: String, _ method: String) -> Bool {
            let request = NSMutableURLRequest(url: URL(string: "https://api.elevenlabs.io" + path)!)
            request.httpMethod = method
            StandaloneNetworkPolicy.authorizeDirectSpeech(request)
            return StandaloneNetworkPolicy.isDirectSpeechRequest(request as URLRequest)
        }
        XCTAssertTrue(authorized("/v1/user/subscription", "GET"))
        XCTAssertTrue(authorized("/v1/usage/character-stats", "GET"))
        XCTAssertFalse(authorized("/v1/user/subscription", "POST"))
        XCTAssertFalse(authorized("/v1/user", "GET"))
    }
}
