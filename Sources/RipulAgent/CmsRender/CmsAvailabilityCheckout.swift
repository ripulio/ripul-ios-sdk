#if os(iOS)
import SwiftUI

/// The calendar's `checkout` choosing, natively: the web's CheckoutPanel up to
/// the price. Each unit free for the stay can be ticked, with its adults and
/// children; the price for all of them comes from the site's quote
/// (`POST /v1/cms-bookings/<site>/quote`, which only reads), with what is due
/// now and when the balance is taken. Going on to the guest's details and
/// paying is not here: how the app takes payment is still to be decided.
struct CmsAvailabilityCheckout: View {
    struct Unit: Equatable {
        var key: String
        var label: String
        var maxGuests: Int
        var colour: Color
        /// Free every night of the stay, by the calendar's own reading.
        var free: Bool
    }

    struct Choice: Equatable {
        var selected = false
        var adults = 2
        var children = 0
    }

    let site: String
    let arrival: String
    let departure: String
    let mark: Color
    let units: [Unit]
    /// "Sign in and we will fill in your details": the calendar opens the app's sign-in sheet.
    var signIn: () -> Void = {}
    @EnvironmentObject private var runtime: CmsRuntime
    @State private var choices: [String: Choice] = [:]
    @State private var quote: CmsBookingQuote?
    @State private var quoting = false
    @State private var error: String?

    private var chosen: [CmsBookingQuote.Stay] {
        units.filter { $0.free && choices[$0.key]?.selected == true }
            .map { CmsBookingQuote.Stay(key: $0.key, adults: choices[$0.key]!.adults, children: choices[$0.key]!.children) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let signIn = runtime.siteSignIn {
                CmsReturningGuest(signIn: signIn, open: self.signIn)
                    .padding(.bottom, 8)
            }
            ForEach(units, id: \.key) { unit in
                row(unit)
                Divider().overlay(mark.opacity(0.12))
            }
            if !chosen.isEmpty { total }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .cmsSiteFont("body2", 14, relativeTo: .subheadline)
                    .foregroundStyle(.ripul(.warning))
                    .padding(.top, 8)
            }
        }
        // A new stay starts the choice again.
        .onChange(of: "\(arrival)|\(departure)") { _, _ in choices = [:]; quote = nil; error = nil }
        .task(id: "\(arrival)|\(departure)|\(chosen.map { "\($0.key):\($0.adults):\($0.children)" }.joined(separator: ","))") {
            await requote()
        }
    }

    private func row(_ unit: Unit) -> some View {
        let choice = choices[unit.key] ?? Choice()
        let ticked = unit.free && choice.selected
        let price = quote?.stays.first { $0.key == unit.key }?.totalMinor
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                var c = choice; c.selected.toggle(); choices[unit.key] = c
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .font(.ripul(.title3))
                        .foregroundStyle(unit.free ? unit.colour : Color.ripul(system: .tertiaryLabel))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unit.label).cmsSiteFont("body1", 16, weight: 600)
                        Text(!unit.free ? "Not available for these dates."
                             : price.flatMap { p in quote.map { CmsBookingQuote.money(p, $0.currency) } } ?? "Available for your stay.")
                            .cmsSiteFont("body2", 14, relativeTo: .subheadline)
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!unit.free)
            .accessibilityLabel("Book \(unit.label)")
            .accessibilityAddTraits(ticked ? .isSelected : [])
            if ticked {
                // Labelled, as the web's Adults and Children fields are.
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Adults").cmsSiteFont("caption", 12, relativeTo: .caption).foregroundStyle(.ripul(.textSecondary))
                        Picker("Adults", selection: Binding(
                            get: { choice.adults },
                            set: { n in var c = choice; c.adults = n; c.children = min(c.children, unit.maxGuests - n); choices[unit.key] = c })) {
                            ForEach(1...max(1, unit.maxGuests), id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Children").cmsSiteFont("caption", 12, relativeTo: .caption).foregroundStyle(.ripul(.textSecondary))
                        Picker("Children", selection: Binding(
                            get: { choice.children },
                            set: { n in var c = choice; c.children = n; choices[unit.key] = c })) {
                            ForEach(0...max(0, unit.maxGuests - choice.adults), id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                }
                .pickerStyle(.menu)
                .tint(runtime.theme.textPrimary)
                .padding(.leading, 36)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var total: some View {
        VStack(alignment: .leading, spacing: 4) {
            if quoting && quote == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Getting the price…").cmsSiteFont("body2", 14, relativeTo: .subheadline) }
            }
            if let quote {
                Text("Total \(CmsBookingQuote.money(quote.totalMinor, quote.currency))").cmsSiteFont("body1", 16, weight: 700)
                Text(quote.balanceMinor > 0 && quote.balanceDueOn != nil
                     ? "\(CmsBookingQuote.money(quote.dueNowMinor, quote.currency)) now, and the balance of \(CmsBookingQuote.money(quote.balanceMinor, quote.currency)) taken from the same card on \(CmsBookingQuote.day(quote.balanceDueOn!))."
                     : "Paid in full now.")
                    .cmsSiteFont("body2", 14, relativeTo: .subheadline)
                    .foregroundStyle(.ripul(.textSecondary))
                Text("Booking in the app is not available yet.")
                    .cmsSiteFont("caption", 12, relativeTo: .footnote)
                    .foregroundStyle(.ripul(.textSecondary))
                    .padding(.top, 4)
            }
        }
        .padding(.top, 12)
    }

    private func requote() async {
        let request = chosen
        guard !request.isEmpty else { quote = nil; return }
        quoting = true
        error = nil
        // The web waits 350 ms after the last change before asking.
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        do {
            let q = try await CmsBookingQuote.fetch(site: site, arrival: arrival, departure: departure, units: request)
            guard !Task.isCancelled else { return }
            quote = q
        } catch {
            guard !Task.isCancelled else { return }
            quote = nil
            self.error = error.localizedDescription
        }
        quoting = false
    }
}

/// The site's price for a stay (packages/shared-types cmsBookings.ts `BookingQuote`).
struct CmsBookingQuote: Decodable, Equatable {
    struct Stay: Codable, Equatable { var key: String; var adults: Int; var children: Int }
    struct Priced: Decodable, Equatable { var key: String; var available: Bool; var totalMinor: Int?; var reason: String? }

    var currency: String
    var stays: [Priced]
    var available: Bool
    var totalMinor: Int
    var dueNowMinor: Int
    var balanceMinor: Int
    var balanceDueOn: String?

    struct Refusal: LocalizedError { let errorDescription: String? }

    static func fetch(site: String, arrival: String, departure: String, units: [Stay]) async throws -> CmsBookingQuote {
        let enc = site.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? site
        guard let url = URL(string: "\(RipulDomain.llmProxyURL)/v1/cms-bookings/\(enc)/quote") else { throw Refusal(errorDescription: "Something went wrong.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { var arrival: String; var departure: String; var units: [Stay] }
        request.httpBody = try JSONEncoder().encode(Body(arrival: arrival, departure: departure, units: units))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            struct Failure: Decodable { var error: String? }
            let words = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw Refusal(errorDescription: words ?? "Something went wrong. Nothing has been charged.")
        }
        return try JSONDecoder().decode(CmsBookingQuote.self, from: data)
    }

    /// Minor units as money, as the web's `Intl.NumberFormat('en-GB', currency)`.
    static func money(_ minor: Int, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_GB")
        f.currencyCode = currency.uppercased()
        return f.string(from: NSNumber(value: Double(minor) / 100)) ?? "\(minor)"
    }

    /// "Thu 5 Nov 2026".
    static func day(_ iso: String) -> String {
        guard let date = CmsAvailability.date(String(iso.prefix(10))) else { return iso }
        let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE d MMM yyyy"
        return f.string(from: date)
    }
}
/// The web's ReturningGuest (AvailabilityCheckout.tsx), on a site that signs in
/// by an emailed code: signed out, "Booked with us before? Sign in and we will
/// fill in your details", opening the app's sign-in sheet (the chosen stay is
/// kept); signed in, who they are and "Not you?". The web's "Your details are
/// filled in from your last booking" waits for the details step, which the app
/// doesn't have yet.
private struct CmsReturningGuest: View {
    @ObservedObject var signIn: CmsSiteSignIn
    let open: () -> Void
    @EnvironmentObject private var runtime: CmsRuntime

    var body: some View {
        Group {
            if let email = signIn.email {
                Text(Self.line("Signed in as \(email). ", lead: runtime.theme.textSecondary, link: "Not you?", linkColour: runtime.theme.primary))
                    .cmsSiteFont("body2", 14, relativeTo: .subheadline)
                    .onTapGesture { Task { await signIn.signOut() } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Signed in as \(email)")
                    .accessibilityAction(named: "Not you? Sign out") { Task { await signIn.signOut() } }
            } else {
                Text(Self.line("Booked with us before? ", lead: runtime.theme.textPrimary,
                               link: "Sign in and we will fill in your details", linkColour: runtime.theme.primary))
                    .cmsSiteFont("body2", 14, relativeTo: .subheadline)
                    .onTapGesture(perform: open)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Booked with us before? Sign in and we will fill in your details")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { open() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cmsInspectorID("Cms.availabilityCalendar.returning")
    }

    /// Words, then a link in the site's primary, underlined (MUI's Link).
    private static func line(_ words: String, lead: Color, link: String, linkColour: Color) -> AttributedString {
        var first = AttributedString(words)
        first.foregroundColor = lead
        var second = AttributedString(link)
        second.foregroundColor = linkColour
        second.underlineStyle = .single
        return first + second
    }
}
#endif
