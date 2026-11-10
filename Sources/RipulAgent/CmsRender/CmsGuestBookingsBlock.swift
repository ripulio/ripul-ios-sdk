#if os(iOS)
import SwiftUI

/// A booking's lozenge in the web's tones, in the theme's colours.
struct CmsBookingTag: View {
    let label: String
    let tone: CmsBookingWording.Tone
    var outlined = false

    private var colour: Color {
        switch tone {
        case .success: return .ripul(.success)
        case .warning: return .ripul(.warning)
        case .info: return .ripul(.info)
        case .error: return .ripul(.danger)
        case .neutral: return .ripul(.textSecondary)
        }
    }

    var body: some View {
        Text(label)
            .font(.ripul(.caption, weight: .semibold))
            .foregroundStyle(colour)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                if outlined {
                    Capsule().strokeBorder(colour.opacity(0.6))
                } else {
                    Capsule().fill(colour.opacity(0.15))
                }
            }
    }
}

/// A card on the page: the surface colour, rounded as the system's grouped rows.
struct CmsBookingCard<Content: View>: View {
    var highlighted: Color? = nil
    @ViewBuilder let content: Content
    @EnvironmentObject private var runtime: CmsRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: runtime.theme.cardCorner(16), style: .continuous).fill(Color.ripul(.surface)))
            .overlay {
                if let highlighted {
                    RoundedRectangle(cornerRadius: runtime.theme.cardCorner(16), style: .continuous).strokeBorder(highlighted, lineWidth: 1.5)
                }
            }
    }
}

/// A message on the page, in the web's alert tones.
struct CmsBookingNotice: View {
    enum Kind { case error, success, warning, info }
    let kind: Kind
    let title: String
    var lines: [String] = []
    var onClose: (() -> Void)? = nil

    private var colour: Color {
        switch kind {
        case .error: return .ripul(.danger)
        case .success: return .ripul(.success)
        case .warning: return .ripul(.warning)
        case .info: return .ripul(.info)
        }
    }

    private var symbol: String {
        switch kind {
        case .error, .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(colour)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ripul(.subheadline, weight: .semibold))
                ForEach(lines, id: \.self) { Text($0).font(.ripul(.subheadline)) }
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.ripul(.footnote)) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(colour.opacity(0.12)))
    }
}

/// Native twin of `guestBookings` (GuestBookingsBlock.tsx): a guest signs in
/// with a code emailed from the site's mailbox and sees their own bookings:
/// upcoming, past and cancelled, each with its cottages, dates, party, what was
/// paid and the balance, what they added to the stay, and their points.
///
/// Degraded: buying add-ons ends in Stripe's checkout on the web. How the app
/// pays is not decided, so the app lists what can be added and says it cannot
/// be bought here yet. The extra-nights offer the email's buttons bring to this
/// page on the web (ExtraNightsReturn) is the website's.
struct CmsGuestBookingsBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime

    var body: some View {
        Group {
            if let signIn = runtime.siteSignIn {
                CmsGuestBookingsContent(block: block, signIn: signIn)
            } else {
                Text("Guests sign in here on the site’s own address, with a code sent to their email, to see their bookings.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
            }
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .cmsInspectorID("Cms.guestBookings")
    }
}

private struct CmsGuestBookingsContent: View {
    let block: CmsBlock
    @ObservedObject var signIn: CmsSiteSignIn
    @EnvironmentObject private var runtime: CmsRuntime

    @State private var bookings: [CmsGuestBooking]?
    @State private var points: CmsGuestPoints?
    @State private var error: String?

    private var bookPage: String? { block.props.string("bookPageSlug").flatMap { $0.isEmpty ? nil : $0 } }

    var body: some View {
        if let email = signIn.email {
            signedIn(email)
                .task(id: email) { await load() }
        } else {
            CmsSiteSignInForm(signIn: signIn, wording: .guestBookings(intro: block.props.string("intro")))
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func signedIn(_ email: String) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Signed in as \(email)").font(.ripul(.subheadline))
                Spacer()
                Button("Sign out") {
                    bookings = nil
                    points = nil
                    Task { await signIn.signOut() }
                }
                .buttonStyle(.borderless)
                .font(.ripul(.subheadline))
                .accessibilityIdentifier("Cms.guestBookings.signOut")
            }
            if let points, points.enabled { CmsGuestPointsCard(points: points) }
            if let error { CmsBookingNotice(kind: .error, title: error) }
            if bookings == nil, error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let bookings {
                if bookings.isEmpty {
                    VStack(spacing: 12) {
                        Text("There are no bookings for \(email) yet.").font(.ripul(.subheadline))
                        if let bookPage {
                            Button("Book a stay") { runtime.navigate(toPage: bookPage) }
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(runtime.theme.buttonShape)
                                .tint(runtime.theme.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    let sections = CmsGuestBookingSections(bookings, today: CmsBookingWording.today())
                    section("Upcoming", sections.upcoming)
                    section("Past stays", sections.past)
                    section("Cancelled", sections.cancelled)
                    if let bookPage {
                        Button("Book another stay") { runtime.navigate(toPage: bookPage) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(runtime.theme.buttonShape)
                            .tint(runtime.theme.primary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [CmsGuestBooking]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.ripul(.headline))
                ForEach(list) { CmsGuestBookingCard(booking: $0) }
            }
        }
    }

    private func load() async {
        guard let client = runtime.bookings else { return }
        bookings = nil
        error = nil
        async let pointsRead = client.guestPoints()
        do {
            bookings = try await client.guestBookings()
        } catch CmsBookingsError.signedOut {
            error = CmsBookingsError.signedOut.errorDescription
            signIn.forget()
        } catch {
            self.error = (error as? CmsBookingsError)?.errorDescription ?? "Your bookings could not be loaded."
        }
        points = await pointsRead
    }
}

private struct CmsGuestBookingCard: View {
    let booking: CmsGuestBooking
    @State private var adding = false
    @EnvironmentObject private var runtime: CmsRuntime

    var body: some View {
        let status = CmsBookingWording.guestStatus(booking.status)
        let money = { CmsBookingWording.money($0, booking.currency) }
        CmsBookingCard {
            HStack(alignment: .firstTextBaseline) {
                Text(booking.stays.map(\.label).joined(separator: ", ")).font(.ripul(.headline))
                Spacer()
                CmsBookingTag(label: status.label, tone: status.tone, outlined: booking.isCancelled)
            }
            Text("\(CmsBookingWording.day(booking.arrival)) to \(CmsBookingWording.day(booking.departure)) · \(booking.nights) \(booking.nights == 1 ? "night" : "nights")")
                .font(.ripul(.subheadline))
            if !booking.stays.isEmpty {
                Text(booking.stays.map { "\($0.label): \(CmsBookingWording.guestParty(adults: $0.adults, children: $0.children))" }.joined(separator: " · "))
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Total \(money(booking.totalMinor))")
                if booking.isCancelled {
                    Text(booking.refundedMinor.map { $0 > 0 ? "Refunded \(money($0))" : "No refund" } ?? "No refund")
                } else {
                    Text("Paid \(money(booking.paidMinor))")
                    if booking.balanceMinor > 0, let due = booking.balanceDueOn {
                        Text("Balance \(money(booking.balanceMinor)), taken on \(CmsBookingWording.day(due))")
                    } else {
                        Text("Paid in full")
                    }
                }
            }
            .font(.ripul(.subheadline))
            if !booking.addOns.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Added to your stay").font(.ripul(.subheadline, weight: .semibold))
                    ForEach(Array(booking.addOns.enumerated()), id: \.offset) { _, line in
                        Text("\(line.quantity) × \(line.name), \(money(line.unitMinor * line.quantity))\(line.answer.map { " (\($0))" } ?? "")")
                            .font(.ripul(.subheadline))
                    }
                }
            }
            Text("Booking reference \(booking.reference)")
                .font(.ripul(.caption))
                .foregroundStyle(.ripul(.textSecondary))
            if booking.addOnsOpen {
                if adding {
                    CmsGuestAddOnsList(booking: booking)
                } else {
                    // A stay begun or over can still order what is posted.
                    Button(booking.arrival > CmsBookingWording.today() ? "Add to your stay" : "Order something to be posted to you") {
                        adding = true
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(runtime.theme.buttonShape)
                    .controlSize(.small)
                }
            }
        }
    }
}

/// What can still be added to a stay. The web's picker ends in Stripe's
/// checkout; paying in the app is not decided, so this lists them only.
private struct CmsGuestAddOnsList: View {
    let booking: CmsGuestBooking
    @EnvironmentObject private var runtime: CmsRuntime
    @State private var addOns: [CmsGuestAddOn]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            if let error, addOns == nil {
                CmsBookingNotice(kind: .error, title: error)
            } else if let addOns {
                if addOns.isEmpty {
                    Text("There is nothing to add to this stay just now.")
                        .font(.ripul(.subheadline))
                        .foregroundStyle(.ripul(.textSecondary))
                } else {
                    ForEach(addOns) { row($0) }
                    Text("Adding these is not in the app yet.")
                        .font(.ripul(.footnote))
                        .foregroundStyle(.ripul(.textSecondary))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: booking.id) {
            guard let client = runtime.bookings else { return }
            do {
                addOns = try await client.guestAddOns(order: booking.id)
            } catch {
                self.error = (error as? CmsBookingsError)?.errorDescription ?? "The add-ons could not be loaded."
            }
        }
    }

    private func row(_ addOn: CmsGuestAddOn) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let image = addOn.image, let url = URL(string: image) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.ripul(.surfaceSunken) }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(addOn.name).font(.ripul(.subheadline, weight: .semibold))
                    Spacer()
                    Text(CmsBookingWording.money(addOn.priceMinor, booking.currency)).font(.ripul(.subheadline))
                }
                if let description = addOn.description, !description.isEmpty {
                    Text(description).font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary))
                }
                let when = addOn.posted
                    ? "Posted to you\(addOn.postageMinor.map { $0 > 0 ? " · postage \(CmsBookingWording.money($0, booking.currency))" : "" } ?? "")"
                    : addOn.orderBy.map { "Order by \(CmsBookingWording.orderBy($0))" } ?? ""
                let left = addOn.left.map { $0 <= 5 ? " · Only \($0) left" : "" } ?? ""
                if !(when + left).isEmpty {
                    Text(when + left).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                }
            }
        }
    }
}

/// The guest's points (GuestPoints.tsx), once the site's staff show them.
private struct CmsGuestPointsCard: View {
    let points: CmsGuestPoints
    @State private var open = false

    var body: some View {
        let count = points.points ?? 0
        let gbp = { CmsBookingWording.money($0, "gbp") }
        CmsBookingCard {
            Text("YOUR POINTS").font(.ripul(.caption, weight: .semibold)).foregroundStyle(.ripul(.textSecondary))
            Text(CmsBookingWording.count(count)).font(.ripul(.largeTitle, weight: .bold))
            if count > 0 {
                let worth = points.worthMinor ?? 0
                let best = points.bestWorthMinor ?? 0
                let band = points.bestBand.flatMap { best > worth ? ", or \(gbp(best)) in \($0.lowercased())" : nil } ?? ""
                Text("Worth \(gbp(worth)) off a stay in a normal week\(band). \(points.canSpend == true ? "Use them when you book a stay on this website." : "Soon you will be able to use them when you book on this website.")")
                    .font(.ripul(.subheadline))
            } else {
                Text("You earn points for every stay you book on this website, once you have stayed.").font(.ripul(.subheadline))
            }
            if let expires = points.expiresOn {
                Text("They expire on \(CmsBookingWording.dayMonthYear(expires)) if you have no stay before then.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            if let entries = points.entries, !entries.isEmpty {
                DisclosureGroup(open ? "Hide how you earned them" : "How you earned them", isExpanded: $open) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            Text("\(CmsBookingWording.pointsEntry(entry)): \(entry.points > 0 ? "+" : "")\(CmsBookingWording.count(entry.points))")
                                .font(.ripul(.subheadline))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .font(.ripul(.subheadline))
            }
        }
    }
}
#endif
