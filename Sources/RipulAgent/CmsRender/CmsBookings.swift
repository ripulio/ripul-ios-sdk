import Foundation

// A booking site's own routes (packages/api/src/cmsBookings/handlers.ts), for
// the native twins of `guestBookings`, `websiteBookings` and `extraNights`.
// Every call carries the site's emailed-code session (`CmsSiteSignIn`): the
// guest routes answer for the email it proves, the staff routes only for an
// owner, admin or manager.
//
//   GET  guest/bookings · guest/points · guest/add-ons?order=<id>
//   GET  staff/bookings (every channel) · staff/nights (offer candidates)
//   POST staff/orders/<bko_…>/cancel {refund} · staff/orders/<bko_…>/keep
//   POST staff/bookings/<Lodgify id>/cancel · staff/nights {orderIds, levers, preview}
//
// Paying (Stripe Checkout for add-ons, extra nights) is not here: it waits on
// how a native app should pay (docs/plans/cms-app.md in sandsend-retreats).

// MARK: - Guest

public struct CmsGuestBooking: Codable, Equatable, Identifiable, Sendable {
    public struct Stay: Codable, Equatable, Sendable {
        public var label: String
        public var adults: Int
        public var children: Int
        public var totalMinor: Int
    }
    public struct AddOnLine: Codable, Equatable, Sendable {
        public var name: String
        public var quantity: Int
        public var unitMinor: Int
        public var answer: String?
    }
    public var id: String
    public var reference: String
    public var status: String
    public var arrival: String
    public var departure: String
    public var nights: Int
    public var stays: [Stay]
    public var currency: String
    public var totalMinor: Int
    public var paidMinor: Int
    public var balanceMinor: Int
    public var balanceDueOn: String?
    public var cancelledAt: String?
    public var refundedMinor: Int?
    public var addOns: [AddOnLine]
    public var addOnsOpen: Bool

    public var isCancelled: Bool { status == "cancelled" || status == "refunded" }
}

public struct CmsGuestAddOn: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var category: String?
    public var priceMinor: Int
    public var maxQuantity: Int
    public var question: String?
    public var image: String?
    public var posted: Bool
    public var postageMinor: Int?
    public var orderBy: String?
    public var left: Int?
}

public struct CmsGuestPoints: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var kind: String
        public var points: Int
        public var startsOn: String?
        public var endsOn: String?
        public var cottage: String?
        public var on: String
        public var note: String?
    }
    public var enabled: Bool
    public var points: Int?
    public var worthMinor: Int?
    public var bestWorthMinor: Int?
    public var bestBand: String?
    public var expiresOn: String?
    public var canSpend: Bool?
    public var entries: [Entry]?
}

/// The guest's three lists, as the web's `GuestBookingsRender` sorts them.
public struct CmsGuestBookingSections: Equatable {
    public var upcoming: [CmsGuestBooking]
    public var past: [CmsGuestBooking]
    public var cancelled: [CmsGuestBooking]

    /// `today` is the web's `new Date().toISOString().slice(0, 10)`.
    public init(_ bookings: [CmsGuestBooking], today: String) {
        let live = bookings.filter { !$0.isCancelled }
        upcoming = live.filter { $0.departure >= today }.sorted { $0.arrival < $1.arrival }
        past = live.filter { $0.departure < today }
        cancelled = bookings.filter(\.isCancelled)
    }
}

/// The add-ons picker's sums, as the server charges them: postage once for the
/// order, the highest of the posted add-ons chosen.
public struct CmsAddOnBasket: Equatable {
    public var postageMinor: Int
    public var posting: Bool
    public var totalMinor: Int
    /// The first add-on chosen whose question has no answer yet.
    public var unanswered: CmsGuestAddOn?

    public init(addOns: [CmsGuestAddOn], quantities: [String: Int], answers: [String: String]) {
        let chosen = addOns.filter { (quantities[$0.id] ?? 0) > 0 }
        postageMinor = max(0, chosen.filter(\.posted).map { $0.postageMinor ?? 0 }.max() ?? 0)
        posting = chosen.contains(where: \.posted)
        totalMinor = chosen.reduce(0) { $0 + $1.priceMinor * (quantities[$1.id] ?? 0) } + postageMinor
        unanswered = chosen.first { addOn in
            addOn.question != nil && (answers[addOn.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// `step`: one more or fewer, within 0 and the add-on's most.
    public static func step(_ quantity: Int, by: Int, max: Int) -> Int { Swift.min(max, Swift.max(0, quantity + by)) }
}

// MARK: - Staff

public struct CmsStaffOrder: Codable, Equatable, Identifiable, Sendable {
    public struct Guest: Codable, Equatable, Sendable {
        public var name: String
        public var email: String
        public var phone: String
        public var notes: String?
    }
    public struct Stay: Codable, Equatable, Sendable {
        public var label: String
        public var adults: Int
        public var children: Int
        public var totalMinor: Int
        public var bookingId: Int?
    }
    public struct Extra: Codable, Equatable, Sendable {
        public var name: String
        public var quantity: Int
        public var unitMinor: Int
        public var answer: String?
    }
    public struct Nights: Codable, Equatable, Sendable {
        public var nights: [String]
        public var paidMinor: Int
    }
    public struct Cancel: Codable, Equatable, Sendable {
        public var termsMinor: Int?
        public var fullMinor: Int
        public var daysToArrival: Int
        public var fullRefundUntilDays: Int?
    }
    public var id: String
    public var status: String
    public var state: String
    public var arrival: String
    public var departure: String
    public var currency: String
    public var guest: Guest
    public var stays: [Stay]
    public var totalMinor: Int
    public var paidMinor: Int
    public var balanceMinor: Int
    public var balanceDueOn: String?
    public var extras: [Extra]
    public var extraNights: [Nights]
    public var refundedMinor: Int?
    public var cancelledAt: String?
    public var problem: String?
    public var createdAt: String
    public var cancel: Cancel?

    /// The web's `ended`: cancelled, cancelling, or the stay is over.
    public func hasEnded(today: String) -> Bool {
        status == "cancelled" || status == "cancelling" || departure < today
    }

    /// The web's `reference`: the id without `bko_`, eight characters, upper case.
    public var reference: String { String(id.replacingOccurrences(of: "bko_", with: "", options: .anchored).prefix(8)).uppercased() }
}

public struct CmsLodgifyBooking: Codable, Equatable, Identifiable, Sendable {
    public struct Guest: Codable, Equatable, Sendable {
        public var name: String
        public var email: String
        public var phone: String
    }
    public struct Nights: Codable, Equatable, Sendable {
        public var nights: [String]
        public var paidMinor: Int
        public var linked: [Int]
    }
    /// What the website can do to it.
    public enum Action: Codable, Equatable, Sendable {
        /// Cancel to Lodgify's bin from here, refunding what the website sold for it.
        case cancel(refundMinor: Int)
        /// The guest paid Lodgify: only Lodgify's own cancel refunds that.
        case lodgify(paidMinor: Int, nightsMinor: Int)
        /// Booking.com or Airbnb, which own the booking and its money.
        case channel(String)

        private enum Keys: String, CodingKey { case kind, refundMinor, paidMinor, nightsMinor, channel }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "cancel": self = .cancel(refundMinor: try c.decodeIfPresent(Int.self, forKey: .refundMinor) ?? 0)
            case "lodgify": self = .lodgify(paidMinor: try c.decodeIfPresent(Int.self, forKey: .paidMinor) ?? 0,
                                            nightsMinor: try c.decodeIfPresent(Int.self, forKey: .nightsMinor) ?? 0)
            default: self = .channel(try c.decodeIfPresent(String.self, forKey: .channel) ?? "")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .cancel(let refund): try c.encode("cancel", forKey: .kind); try c.encode(refund, forKey: .refundMinor)
            case .lodgify(let paid, let nights):
                try c.encode("lodgify", forKey: .kind); try c.encode(paid, forKey: .paidMinor); try c.encode(nights, forKey: .nightsMinor)
            case .channel(let channel): try c.encode("channel", forKey: .kind); try c.encode(channel, forKey: .channel)
            }
        }
    }
    public var bookingId: Int
    public var channel: String
    public var status: String
    public var unit: String
    public var arrival: String
    public var departure: String
    public var currency: String
    public var guest: Guest
    public var people: Int
    public var totalMinor: Int
    public var paidMinor: Int
    public var dueMinor: Int
    public var extraNights: [Nights]
    public var extraNightFor: Int?
    public var lodgifyUrl: String
    public var action: Action

    public var id: Int { bookingId }
}

public struct CmsStaffBookings: Codable, Equatable, Sendable {
    public var website: [CmsStaffOrder]
    public var lodgify: [CmsLodgifyBooking]
}

public struct CmsStaffCancelResult: Codable, Equatable, Sendable {
    public var refundedMinor: Int
    public var terms: String?
    public var problems: [String]
}

public struct CmsLodgifyCancelResult: Codable, Equatable, Sendable {
    public var cancelled: [Int]
    public var refundedMinor: Int
    public var problems: [String]
}

/// How a website booking is refunded when it is cancelled.
public enum CmsRefundChoice: String, CaseIterable, Sendable {
    case terms, full, none

    /// The web's `refundFor`.
    public func minor(for cancel: CmsStaffOrder.Cancel) -> Int {
        switch self {
        case .none: return 0
        case .full: return cancel.fullMinor
        case .terms: return cancel.termsMinor ?? 0
        }
    }

    /// The web's `startCancel`: by the terms unless the terms give nothing to offer.
    public static func initial(for cancel: CmsStaffOrder.Cancel?) -> CmsRefundChoice {
        cancel?.termsMinor == nil ? .full : .terms
    }
}

/// One row of Manage bookings: the website's own, or one from Lodgify.
public enum CmsStaffBookingRow: Equatable, Identifiable {
    case website(CmsStaffOrder)
    case lodgify(CmsLodgifyBooking)

    public var id: String {
        switch self {
        case .website(let order): return order.id
        case .lodgify(let booking): return "lgy-\(booking.bookingId)"
        }
    }

    var arrival: String {
        switch self {
        case .website(let order): return order.arrival
        case .lodgify(let booking): return booking.arrival
        }
    }

    /// The web's `shown`: every word typed found in the row's text, ended
    /// website bookings only when asked for, all in arrival order.
    public static func shown(_ bookings: CmsStaffBookings, search: String, showEnded: Bool, today: String) -> [CmsStaffBookingRow] {
        let words = CmsBookingWording.words(search)
        let website = bookings.website
            .filter { (showEnded || !$0.hasEnded(today: today)) && CmsBookingWording.matches(words, CmsBookingWording.haystack($0)) }
            .map(CmsStaffBookingRow.website)
        let lodgify = bookings.lodgify
            .filter { CmsBookingWording.matches(words, CmsBookingWording.haystack($0)) }
            .map(CmsStaffBookingRow.lodgify)
        // A stable sort, as the web's Array.sort is.
        return (website + lodgify).enumerated()
            .sorted { $0.element.arrival == $1.element.arrival ? $0.offset < $1.offset : $0.element.arrival < $1.element.arrival }
            .map(\.element)
    }
}

// MARK: - Extra nights

public struct CmsNightCandidate: Codable, Equatable, Identifiable, Sendable {
    public var orderId: String
    public var reference: String
    public var source: String
    public var guest: String
    public var email: String
    public var units: [String]
    public var arrival: String
    public var departure: String
    public var before: [String]
    public var after: [String]
    public var offers: Int
    public var lastOfferedAt: String?
    public var lastOfferStatus: String?
    public var bought: Bool
    public var stopped: Bool
    public var locked: String?

    public var id: String { orderId }
}

public struct CmsNightCandidates: Codable, Equatable, Sendable {
    public var candidates: [CmsNightCandidate]
    public var currency: String
}

public struct CmsNightSendResult: Codable, Equatable, Identifiable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var name: String
        public var nights: [String]
        public var fullMinor: Int
        public var priceMinor: Int
    }
    public var orderId: String
    public var reference: String
    public var sent: Bool
    public var to: String?
    public var skipped: String?
    public var options: [Option]?

    public var id: String { orderId }
}

/// The levers of one send, each a whole number within its range or nil (the
/// web's `levers`).
public struct CmsNightLevers: Equatable {
    public var discountPct: Int?
    public var skipOfferedWithinDays: Int?
    public var maxOffersPerBooking: Int?

    public init(discount: String, skipDays: String, maxOffers: String) {
        func whole(_ text: String, _ min: Int, _ max: Int) -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            // `Number('')` is 0 on the web, so an empty box is 0 there too.
            guard let n = trimmed.isEmpty ? 0 : Int(trimmed), n >= min, n <= max else { return nil }
            return n
        }
        discountPct = whole(discount, 0, 50)
        skipOfferedWithinDays = whole(skipDays, 0, 365)
        maxOffersPerBooking = whole(maxOffers, 0, 20)
    }

    public var isValid: Bool { discountPct != nil && skipOfferedWithinDays != nil && maxOffersPerBooking != nil }

    /// The web's `heldBack`: why the levers (or the booking itself) leave it
    /// out, in the server's words, or nil when it can be offered.
    public func heldBack(_ c: CmsNightCandidate, now: Date = Date()) -> String? {
        if let locked = c.locked { return locked }
        if c.stopped { return "Asked for no more offers" }
        if c.bought { return "Bought extra nights already" }
        if let most = maxOffersPerBooking, most > 0, c.offers >= most {
            return "Offered \(c.offers) time\(c.offers == 1 ? "" : "s")"
        }
        if let days = skipOfferedWithinDays, days > 0, let last = c.lastOfferedAt, let at = CmsSiteSession.date(last),
           now.timeIntervalSince(at) < Double(days) * 86_400 {
            return "Offered \(CmsBookingWording.weekdayDay(String(last.prefix(10)))), within \(days) days"
        }
        return nil
    }
}

// MARK: - Wording

/// The web blocks' words for money, days and states, so the app says what the website says.
public enum CmsBookingWording {
    private static let gb = Locale(identifier: "en_GB")

    /// `Intl.NumberFormat('en-GB', { style: 'currency', currency })`.
    public static func money(_ minor: Int, _ currency: String) -> String {
        let f = NumberFormatter()
        f.locale = gb
        f.numberStyle = .currency
        f.currencyCode = currency.uppercased()
        return f.string(from: NSNumber(value: Double(minor) / 100)) ?? "\(minor)"
    }

    private static func parse(_ iso: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(iso.prefix(10)))
    }

    private static func format(_ iso: String, _ pattern: String) -> String {
        guard let date = parse(iso) else { return iso }
        let f = DateFormatter()
        f.locale = gb
        f.timeZone = .current
        f.dateFormat = pattern
        return f.string(from: date)
    }

    /// `EEE d MMM yyyy`: "Fri 6 Nov 2026".
    public static func day(_ iso: String) -> String { format(iso, "EEE d MMM yyyy") }
    /// `EEE d MMM`: "Fri 6 Nov".
    public static func weekdayDay(_ iso: String) -> String { format(iso, "EEE d MMM") }
    /// `d MMM yyyy`.
    public static func dayMonthYear(_ iso: String) -> String { format(iso, "d MMM yyyy") }
    /// `d MMM`.
    public static func dayMonth(_ iso: String) -> String { format(iso, "d MMM") }
    /// `MMMM yyyy`, for searching by month.
    public static func month(_ iso: String) -> String { format(iso, "MMMM yyyy") }

    /// `EEE d MMM, HH:mm` of a full timestamp, in the viewer's time zone.
    public static func orderBy(_ iso: String) -> String {
        guard let date = CmsSiteSession.date(iso) else { return iso }
        let f = DateFormatter()
        f.locale = gb
        f.dateFormat = "EEE d MMM, HH:mm"
        return f.string(from: date)
    }

    /// Today as the web reads it: `new Date().toISOString().slice(0, 10)` (UTC).
    public static func today(_ now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: now)
    }

    /// The guest list's party: "2 adults, 1 child".
    public static func guestParty(adults: Int, children: Int) -> String {
        var parts = ["\(adults) \(adults == 1 ? "adult" : "adults")"]
        if children > 0 { parts.append("\(children) \(children == 1 ? "child" : "children")") }
        return parts.joined(separator: ", ")
    }

    /// The staff list's party: "2 adults, 1 child" (built from "adult"+"s").
    public static func staffParty(adults: Int, children: Int) -> String {
        var parts = ["\(adults) adult\(adults == 1 ? "" : "s")"]
        if children > 0 { parts.append("\(children) child\(children == 1 ? "" : "ren")") }
        return parts.joined(separator: ", ")
    }

    public enum Tone: Equatable { case success, neutral, warning, info, error }

    /// The guest's status lozenge (`STATUS` in GuestBookingsBlock.tsx).
    public static func guestStatus(_ status: String) -> (label: String, tone: Tone) {
        switch status {
        case "confirmed": return ("Booked", .success)
        case "balance_paid": return ("Booked, paid in full", .success)
        case "paid": return ("Confirming", .info)
        case "balance_failed": return ("Balance to pay", .warning)
        case "cancelled": return ("Cancelled", .neutral)
        case "refunded": return ("Refunded", .neutral)
        default: return (status, .neutral)
        }
    }

    /// The staff state lozenge's tone (`tone` in WebsiteBookingsBlock.tsx).
    public static func staffTone(_ status: String) -> Tone {
        switch status {
        case "needs_review", "balance_failed": return .warning
        case "balance_paid", "confirmed": return .success
        default: return .neutral
        }
    }

    /// What became of an extra-nights offer (`LAST_STATUS`).
    public static func lastOfferStatus(_ status: String?) -> String? {
        switch status {
        case "sent": return "not taken up yet"
        case "awaiting_payment": return "paying now"
        case "expired": return "ended"
        case "refunded": return "refunded"
        case "failed": return "needs a look"
        default: return nil
        }
    }

    /// The points history line (`entryText` in GuestPoints.tsx).
    public static func pointsEntry(_ e: CmsGuestPoints.Entry) -> String {
        switch e.kind {
        case "Earned":
            return "\(e.cottage ?? "Your stay"), \(e.startsOn.map(dayMonth) ?? "")\(e.endsOn.map { " – \(dayMonthYear($0))" } ?? "")"
        case "Expired": return "Expired \(dayMonthYear(e.on))"
        case "Spent": return "Used \(dayMonthYear(e.on))"
        default:
            let note = e.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return note.isEmpty ? "Added \(dayMonthYear(e.on))" : note
        }
    }

    /// `toLocaleString('en-GB')`: "1,250".
    public static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = gb
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func words(_ search: String) -> [String] {
        search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ words: [String], _ haystack: String) -> Bool {
        words.allSatisfy { haystack.contains($0) }
    }

    static func haystack(_ o: CmsStaffOrder) -> String {
        ([o.guest.name, o.guest.email, o.guest.phone, o.reference, o.state]
            + o.stays.map { "\($0.label) \($0.bookingId.map(String.init) ?? "")" }
            + [weekdayDay(o.arrival), month(o.arrival)]).joined(separator: " ").lowercased()
    }

    static func haystack(_ b: CmsLodgifyBooking) -> String {
        [b.guest.name, b.guest.email, b.guest.phone, "B\(b.bookingId)", String(b.bookingId), b.channel, b.unit, b.status,
         weekdayDay(b.arrival), month(b.arrival)].joined(separator: " ").lowercased()
    }

    static func haystack(_ c: CmsNightCandidate) -> String {
        ([c.guest, c.email, c.reference, c.source] + c.units + [weekdayDay(c.arrival), weekdayDay(c.departure), month(c.arrival)])
            .joined(separator: " ").lowercased()
    }

    /// Extra-nights search: every word typed, and only those offerable when asked.
    public static func shownCandidates(_ all: [CmsNightCandidate], search: String, onlyOfferable: Bool,
                                       levers: CmsNightLevers, now: Date = Date()) -> [CmsNightCandidate] {
        let words = words(search)
        return all.filter { (!onlyOfferable || levers.heldBack($0, now: now) == nil) && matches(words, haystack($0)) }
    }
}

// MARK: - Client

public enum CmsBookingsError: Error, LocalizedError, Equatable {
    case signedOut
    case refused(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: return "Your sign-in has run out; please sign in again."
        case .refused(_, let message): return message
        }
    }
}

/// The booking routes for one site, signed in as `token()`.
public struct CmsBookingsClient: Sendable {
    public let site: String
    let baseUrl: String
    let token: @Sendable () async -> String?
    let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(site: String, baseUrl: String = RipulDomain.llmProxyURL,
                token: @escaping @Sendable () async -> String?,
                send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.site = site
        self.baseUrl = baseUrl
        self.token = token
        self.send = send
    }

    func request(_ path: String, body: [String: Any]? = nil, signedOutMessage: String) async throws -> Data {
        guard let token = await token() else { throw CmsBookingsError.refused(status: 401, message: signedOutMessage) }
        let site = site.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? site
        guard let url = URL(string: "\(baseUrl)/v1/cms-bookings/\(site)/\(path)") else {
            throw CmsBookingsError.refused(status: 0, message: "Something went wrong; please try again.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = CmsSiteSignInError.message(in: data) ?? "Something went wrong; please try again."
            throw CmsBookingsError.refused(status: status, message: message)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw CmsBookingsError.refused(status: 200, message: "Something went wrong; please try again.")
        }
    }

    // Guest. A 401 here is a session the server no longer knows: signed out.

    private func guest(_ path: String) async throws -> Data {
        do {
            return try await request("guest/\(path)", signedOutMessage: CmsBookingsError.signedOut.errorDescription!)
        } catch CmsBookingsError.refused(let status, _) where status == 401 {
            throw CmsBookingsError.signedOut
        }
    }

    public func guestBookings() async throws -> [CmsGuestBooking] {
        struct Answer: Decodable { var bookings: [CmsGuestBooking] }
        return try decode(Answer.self, try await guest("bookings")).bookings
    }

    public func guestAddOns(order: String) async throws -> [CmsGuestAddOn] {
        struct Answer: Decodable { var addOns: [CmsGuestAddOn] }
        // encodeURIComponent's set.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        let encoded = order.addingPercentEncoding(withAllowedCharacters: allowed) ?? order
        return try decode(Answer.self, try await guest("add-ons?order=\(encoded)")).addOns
    }

    /// Nil when they cannot be read: points are a bonus on the page.
    public func guestPoints() async -> CmsGuestPoints? {
        guard let data = try? await guest("points") else { return nil }
        return try? JSONDecoder().decode(CmsGuestPoints.self, from: data)
    }

    // Staff.

    private static let staffSignIn = "Sign in again to manage bookings."

    public func staffBookings() async throws -> CmsStaffBookings {
        try decode(CmsStaffBookings.self, try await request("staff/bookings", signedOutMessage: Self.staffSignIn))
    }

    public func cancelOrder(_ id: String, refund: CmsRefundChoice) async throws -> CmsStaffCancelResult {
        try decode(CmsStaffCancelResult.self, try await request("staff/orders/\(id)/cancel", body: ["refund": refund.rawValue],
                                                                signedOutMessage: Self.staffSignIn))
    }

    public func keepOrder(_ id: String) async throws {
        _ = try await request("staff/orders/\(id)/keep", body: [:], signedOutMessage: Self.staffSignIn)
    }

    public func cancelLodgify(_ bookingId: Int) async throws -> CmsLodgifyCancelResult {
        try decode(CmsLodgifyCancelResult.self, try await request("staff/bookings/\(bookingId)/cancel", body: [:],
                                                                  signedOutMessage: Self.staffSignIn))
    }

    private static let offersSignIn = "Sign in again to send offers."

    public func nightCandidates() async throws -> CmsNightCandidates {
        try decode(CmsNightCandidates.self, try await request("staff/nights", signedOutMessage: Self.offersSignIn))
    }

    /// Send the offer email (or, with `preview`, a sample to the site's own mailbox).
    public func sendNightOffers(orderIds: [String], levers: CmsNightLevers, preview: Bool) async throws -> [CmsNightSendResult] {
        struct Answer: Decodable { var results: [CmsNightSendResult] }
        let body: [String: Any] = [
            "orderIds": orderIds,
            "discountPct": levers.discountPct ?? 0,
            "skipOfferedWithinDays": levers.skipOfferedWithinDays ?? 0,
            "maxOffersPerBooking": levers.maxOffersPerBooking ?? 0,
            "preview": preview,
        ]
        return try decode(Answer.self, try await request("staff/nights", body: body, signedOutMessage: Self.offersSignIn)).results
    }
}
