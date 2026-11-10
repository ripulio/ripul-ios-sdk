import XCTest
@testable import RipulAgent

/// The booking blocks' data and rules (CmsBookings.swift), held to
/// GuestBookingsBlock.tsx, WebsiteBookingsBlock.tsx, ExtraNightsBlock.tsx and
/// the worker's cmsBookings routes.
final class CmsBookingsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func guest(_ id: String, status: String = "confirmed", arrival: String, departure: String) throws -> CmsGuestBooking {
        try decode(CmsGuestBooking.self, """
        {"id":"\(id)","reference":"R\(id)","status":"\(status)","arrival":"\(arrival)","departure":"\(departure)","nights":3,
         "stays":[{"label":"Montauk","adults":2,"children":1,"totalMinor":90000}],"currency":"gbp","totalMinor":90000,
         "paidMinor":27000,"balanceMinor":63000,"balanceDueOn":"2026-12-01","cancelledAt":null,"refundedMinor":null,
         "addOns":[{"name":"Hamper","quantity":2,"unitMinor":4500,"answer":"No nuts"}],"addOnsOpen":true}
        """)
    }

    func testGuestBookingsSortIntoTheWebsSections() throws {
        let list = [
            try guest("a", arrival: "2027-02-01", departure: "2027-02-04"),
            try guest("b", arrival: "2026-12-20", departure: "2026-12-23"),
            try guest("c", arrival: "2026-09-01", departure: "2026-09-04"),
            try guest("d", status: "refunded", arrival: "2027-03-01", departure: "2027-03-04"),
            // A stay under way is upcoming until its last day.
            try guest("e", arrival: "2026-11-01", departure: "2026-11-03"),
        ]
        let sections = CmsGuestBookingSections(list, today: "2026-11-03")
        XCTAssertEqual(sections.upcoming.map(\.id), ["e", "b", "a"])
        XCTAssertEqual(sections.past.map(\.id), ["c"])
        XCTAssertEqual(sections.cancelled.map(\.id), ["d"])
    }

    func testTheAddOnsBasketChargesPostageOnce() throws {
        let addOns = try decode([CmsGuestAddOn].self, """
        [{"id":"h","name":"Hamper","description":null,"category":null,"priceMinor":4500,"maxQuantity":3,"question":"Any allergies?","image":null,"posted":false},
         {"id":"m","name":"Mug","description":null,"category":null,"priceMinor":1200,"maxQuantity":5,"question":null,"image":null,"posted":true,"postageMinor":395},
         {"id":"t","name":"Tea","description":null,"category":null,"priceMinor":800,"maxQuantity":5,"question":null,"image":null,"posted":true,"postageMinor":250}]
        """)
        let basket = CmsAddOnBasket(addOns: addOns, quantities: ["h": 1, "m": 2, "t": 1], answers: [:])
        XCTAssertEqual(basket.postageMinor, 395)
        XCTAssertTrue(basket.posting)
        XCTAssertEqual(basket.totalMinor, 4500 + 2400 + 800 + 395)
        XCTAssertEqual(basket.unanswered?.id, "h")
        XCTAssertNil(CmsAddOnBasket(addOns: addOns, quantities: ["h": 1], answers: ["h": "none"]).unanswered)
        XCTAssertEqual(CmsAddOnBasket.step(3, by: 1, max: 3), 3)
        XCTAssertEqual(CmsAddOnBasket.step(0, by: -1, max: 3), 0)
    }

    private let staffJSON = """
    {"website":[
      {"id":"bko_abc123def456","status":"confirmed","state":"Booked","arrival":"2026-12-10","departure":"2026-12-13","currency":"gbp",
       "guest":{"name":"Ann Lee","email":"ann@example.com","phone":"0123"},"stays":[{"label":"Montauk","adults":2,"children":0,"totalMinor":60000,"bookingId":991}],
       "totalMinor":60000,"paidMinor":18000,"balanceMinor":42000,"balanceDueOn":"2026-11-26","extras":[],"extraNights":[],
       "refundedMinor":null,"cancelledAt":null,"problem":null,"createdAt":"2026-10-01T10:00:00Z",
       "cancel":{"termsMinor":null,"fullMinor":18000,"daysToArrival":37,"fullRefundUntilDays":null}},
      {"id":"bko_old","status":"cancelled","state":"Cancelled","arrival":"2026-12-01","departure":"2026-12-04","currency":"gbp",
       "guest":{"name":"Old Guest","email":"old@example.com","phone":""},"stays":[],"totalMinor":1,"paidMinor":1,"balanceMinor":0,
       "balanceDueOn":null,"extras":[],"extraNights":[],"refundedMinor":1,"cancelledAt":"2026-10-02","problem":null,"createdAt":"2026-09-01T10:00:00Z","cancel":null}
    ],"lodgify":[
      {"bookingId":555,"channel":"Booking.com","status":"Booked","unit":"Sag Harbor","arrival":"2026-11-20","departure":"2026-11-22","currency":"gbp",
       "guest":{"name":"Bo Chan","email":"","phone":""},"people":2,"totalMinor":40000,"paidMinor":0,"dueMinor":0,"extraNights":[],
       "extraNightFor":null,"lodgifyUrl":"https://app.lodgify.com/#/reservation/555","action":{"kind":"channel","channel":"Booking.com"}},
      {"bookingId":777,"channel":"Manual","status":"Booked","unit":"East Hampton","arrival":"2027-01-05","departure":"2027-01-08","currency":"gbp",
       "guest":{"name":"Cy Doe","email":"cy@example.com","phone":""},"people":4,"totalMinor":80000,"paidMinor":0,"dueMinor":80000,
       "extraNights":[{"nights":["2027-01-08"],"paidMinor":9000,"linked":[778]}],"extraNightFor":null,
       "lodgifyUrl":"https://app.lodgify.com/#/reservation/777","action":{"kind":"cancel","refundMinor":9000}}
    ]}
    """

    func testManageBookingsListsEveryChannelInArrivalOrder() throws {
        let bookings = try decode(CmsStaffBookings.self, staffJSON)
        let rows = CmsStaffBookingRow.shown(bookings, search: "", showEnded: false, today: "2026-11-03")
        XCTAssertEqual(rows.map(\.id), ["lgy-555", "bko_abc123def456", "lgy-777"])
        XCTAssertEqual(CmsStaffBookingRow.shown(bookings, search: "", showEnded: true, today: "2026-11-03").map(\.id),
                       ["lgy-555", "bko_old", "bko_abc123def456", "lgy-777"])
        XCTAssertEqual(CmsStaffBookingRow.shown(bookings, search: "ABC123DE montauk", showEnded: false, today: "2026-11-03").map(\.id),
                       ["bko_abc123def456"])
        XCTAssertEqual(CmsStaffBookingRow.shown(bookings, search: "january 2027", showEnded: false, today: "2026-11-03").map(\.id), ["lgy-777"])
        XCTAssertEqual(CmsStaffBookingRow.shown(bookings, search: "b777", showEnded: false, today: "2026-11-03").map(\.id), ["lgy-777"])
        XCTAssertEqual(bookings.website[0].reference, "ABC123DE")
        XCTAssertEqual(bookings.lodgify[0].action, .channel("Booking.com"))
        XCTAssertEqual(bookings.lodgify[1].action, .cancel(refundMinor: 9000))
    }

    func testTheRefundStartsByTheTermsUnlessThereAreNone() throws {
        let order = try decode(CmsStaffBookings.self, staffJSON).website[0]
        XCTAssertEqual(CmsRefundChoice.initial(for: order.cancel), .full)
        let terms = CmsStaffOrder.Cancel(termsMinor: 5000, fullMinor: 18000, daysToArrival: 10, fullRefundUntilDays: 28)
        XCTAssertEqual(CmsRefundChoice.initial(for: terms), .terms)
        XCTAssertEqual(CmsRefundChoice.terms.minor(for: terms), 5000)
        XCTAssertEqual(CmsRefundChoice.full.minor(for: terms), 18000)
        XCTAssertEqual(CmsRefundChoice.none.minor(for: terms), 0)
    }

    private func candidate(offers: Int = 0, last: String? = nil, bought: Bool = false, stopped: Bool = false, locked: String? = nil) -> CmsNightCandidate {
        CmsNightCandidate(orderId: "o", reference: "REF1", source: "Website", guest: "Ann", email: "ann@example.com", units: ["Montauk"],
                          arrival: "2026-12-10", departure: "2026-12-13", before: ["2026-12-09"], after: [], offers: offers,
                          lastOfferedAt: last, lastOfferStatus: nil, bought: bought, stopped: stopped, locked: locked)
    }

    func testTheLeversSayWhyABookingIsLeftOut() {
        let now = CmsSiteSession.date("2026-11-03T12:00:00Z")!
        let levers = CmsNightLevers(discount: "15", skipDays: "14", maxOffers: "2")
        XCTAssertTrue(levers.isValid)
        XCTAssertNil(levers.heldBack(candidate(), now: now))
        XCTAssertEqual(levers.heldBack(candidate(locked: "Lodgify will not let this booking be changed"), now: now),
                       "Lodgify will not let this booking be changed")
        XCTAssertEqual(levers.heldBack(candidate(stopped: true), now: now), "Asked for no more offers")
        XCTAssertEqual(levers.heldBack(candidate(bought: true), now: now), "Bought extra nights already")
        XCTAssertEqual(levers.heldBack(candidate(offers: 2, last: "2026-09-01T10:00:00Z"), now: now), "Offered 2 times")
        XCTAssertEqual(levers.heldBack(candidate(offers: 1, last: "2026-10-30T10:00:00Z"), now: now), "Offered Fri 30 Oct, within 14 days")
        XCTAssertNil(CmsNightLevers(discount: "15", skipDays: "0", maxOffers: "0").heldBack(candidate(offers: 9, last: "2026-11-03T10:00:00Z"), now: now))
        XCTAssertNil(CmsNightLevers(discount: "51", skipDays: "1", maxOffers: "1").discountPct)
        XCTAssertNil(CmsNightLevers(discount: "1.5", skipDays: "1", maxOffers: "1").discountPct)
        XCTAssertEqual(CmsNightLevers(discount: "", skipDays: "1", maxOffers: "1").discountPct, 0)
    }

    func testTheWebsWords() {
        XCTAssertEqual(CmsBookingWording.money(123456, "gbp"), "£1,234.56")
        XCTAssertEqual(CmsBookingWording.day("2026-11-06"), "Fri 6 Nov 2026")
        XCTAssertEqual(CmsBookingWording.weekdayDay("2026-11-06"), "Fri 6 Nov")
        XCTAssertEqual(CmsBookingWording.guestParty(adults: 1, children: 2), "1 adult, 2 children")
        XCTAssertEqual(CmsBookingWording.staffParty(adults: 2, children: 1), "2 adults, 1 child")
        XCTAssertEqual(CmsBookingWording.guestStatus("balance_failed").label, "Balance to pay")
        XCTAssertEqual(CmsBookingWording.guestStatus("weird").label, "weird")
        XCTAssertEqual(CmsBookingWording.staffTone("needs_review"), .warning)
        XCTAssertEqual(CmsBookingWording.lastOfferStatus("awaiting_payment"), "paying now")
        XCTAssertEqual(CmsBookingWording.today(CmsSiteSession.date("2026-11-03T23:30:00Z")!), "2026-11-03")
        let earned = CmsGuestPoints.Entry(kind: "Earned", points: 120, startsOn: "2026-05-01", endsOn: "2026-05-04", cottage: "Montauk", on: "2026-05-04", note: nil)
        XCTAssertEqual(CmsBookingWording.pointsEntry(earned), "Montauk, 1 May – 4 May 2026")
        XCTAssertEqual(CmsBookingWording.count(12500), "12,500")
    }

    final class Server: @unchecked Sendable {
        var answers: [(Int, String)]
        var sent: [URLRequest] = []
        init(_ answers: [(Int, String)]) { self.answers = answers }
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            sent.append(request)
            let (status, body) = answers.isEmpty ? (200, "{}") : answers.removeFirst()
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func client(_ server: Server, token: String? = "tok") -> CmsBookingsClient {
        CmsBookingsClient(site: "cms_site", baseUrl: "https://api.example.com", token: { token }, send: { try await server.send($0) })
    }

    func testEachActionSendsWhatTheWebSends() async throws {
        let server = Server([
            (200, #"{"refundedMinor":18000,"terms":"full","problems":[]}"#),
            (200, #"{"orderId":"bko_x","status":"confirmed"}"#),
            (200, #"{"cancelled":[777,778],"refundedMinor":9000,"problems":[]}"#),
            (200, #"{"results":[{"orderId":"o","reference":"REF1","sent":true,"to":"office@example.com","options":[]}]}"#),
        ])
        let c = client(server)
        let cancelled = try await c.cancelOrder("bko_x", refund: .full)
        XCTAssertEqual(cancelled.refundedMinor, 18000)
        try await c.keepOrder("bko_x")
        let lodgify = try await c.cancelLodgify(777)
        XCTAssertEqual(lodgify.cancelled, [777, 778])
        let results = try await c.sendNightOffers(orderIds: ["o"], levers: CmsNightLevers(discount: "15", skipDays: "14", maxOffers: "2"), preview: true)
        XCTAssertEqual(results.first?.to, "office@example.com")

        XCTAssertEqual(server.sent.map { $0.url?.path }, [
            "/v1/cms-bookings/cms_site/staff/orders/bko_x/cancel",
            "/v1/cms-bookings/cms_site/staff/orders/bko_x/keep",
            "/v1/cms-bookings/cms_site/staff/bookings/777/cancel",
            "/v1/cms-bookings/cms_site/staff/nights",
        ])
        XCTAssertTrue(server.sent.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
        let refund = try JSONSerialization.jsonObject(with: server.sent[0].httpBody!) as? [String: String]
        XCTAssertEqual(refund, ["refund": "full"])
        let send = try JSONSerialization.jsonObject(with: server.sent[3].httpBody!) as? [String: Any]
        XCTAssertEqual(send?["orderIds"] as? [String], ["o"])
        XCTAssertEqual(send?["discountPct"] as? Int, 15)
        XCTAssertEqual(send?["skipOfferedWithinDays"] as? Int, 14)
        XCTAssertEqual(send?["maxOffersPerBooking"] as? Int, 2)
        XCTAssertEqual(send?["preview"] as? Bool, true)
    }

    func testAGuestWhoseSessionEndedIsSignedOut() async {
        let server = Server([(401, #"{"error":"Sign in first."}"#)])
        do {
            _ = try await client(server).guestBookings()
            XCTFail("expected signed out")
        } catch {
            XCTAssertEqual(error as? CmsBookingsError, .signedOut)
        }
        XCTAssertEqual(server.sent.first?.httpMethod, "GET")
        XCTAssertEqual(server.sent.first?.url?.path, "/v1/cms-bookings/cms_site/guest/bookings")
    }

    func testAStaffRefusalCarriesTheServersWords() async {
        let server = Server([(403, #"{"error":"Only the site’s owners, admins and managers can do this."}"#)])
        do {
            _ = try await client(server).staffBookings()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Only the site’s owners, admins and managers can do this.")
        }
        do {
            _ = try await client(Server([]), token: nil).nightCandidates()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Sign in again to send offers.")
        }
    }

    func testTheGuestsAddOnsAreAskedForByOrder() async throws {
        let server = Server([(200, #"{"addOns":[]}"#)])
        _ = try await client(server).guestAddOns(order: "bko_x")
        XCTAssertEqual(server.sent.first?.url?.absoluteString, "https://api.example.com/v1/cms-bookings/cms_site/guest/add-ons?order=bko_x")
    }
}
