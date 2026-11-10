#if os(iOS)
import SwiftUI

/// Native twin of `websiteBookings` (WebsiteBookingsBlock.tsx), for a booking
/// site's staff: every booking from every channel in arrival order, searched
/// by guest, email, reference, cottage, channel or month, each opening to what
/// can be done to it from the website:
///  - the website's own: Cancel, with the refund by the site's terms, in full
///    or nothing (a form sheet, as the web's dialog), and Keep for one found
///    cancelled in Lodgify before its balance;
///  - Lodgify's booking site and bookings entered by hand: Cancel to Lodgify's
///    bin, refunding the extra nights the website sold for it (an alert);
///  - one the guest paid Lodgify for: cancelled in Lodgify, which is opened;
///  - Booking.com and Airbnb: on the channel, which is opened.
/// Links to Lodgify and the channels open in the system browser.
struct CmsWebsiteBookingsBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime

    @State private var bookings: CmsStaffBookings?
    @State private var error: String?
    @State private var search = ""
    @State private var showEnded: Bool?
    @State private var open: String?
    @State private var cancelling: CmsStaffOrder?
    @State private var cancellingLodgify: CmsLodgifyBooking?
    @State private var busy: String?
    @State private var outcome: (title: String, problems: [String])?

    private var endedShown: Bool { showEnded ?? (block.props.bool("showEnded") ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.ripul(.textSecondary))
                TextField("Search by guest, email, reference, cottage, channel or month", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Search the bookings")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: runtime.theme.cardCorner(10), style: .continuous).fill(Color.ripul(.surface)))
            Toggle("Show cancelled and past website bookings", isOn: Binding(get: { endedShown }, set: { showEnded = $0 }))
                .font(.ripul(.subheadline))
                .tint(runtime.theme.primary)

            if let error { CmsBookingNotice(kind: .error, title: error) { self.error = nil } }
            if let outcome {
                CmsBookingNotice(kind: outcome.problems.isEmpty ? .success : .warning, title: outcome.title,
                                 lines: outcome.problems) { self.outcome = nil }
            }

            if let bookings {
                let rows = CmsStaffBookingRow.shown(bookings, search: search, showEnded: endedShown, today: CmsBookingWording.today())
                if rows.isEmpty {
                    Text(bookings.website.isEmpty && bookings.lodgify.isEmpty ? "No bookings yet." : "No booking matches that search.")
                        .font(.ripul(.subheadline))
                        .foregroundStyle(.ripul(.textSecondary))
                        .padding(.vertical, 8)
                }
                ForEach(rows) { row in
                    switch row {
                    case .website(let order): websiteRow(order)
                    case .lodgify(let booking): lodgifyRow(booking)
                    }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
        .task { await load() }
        .ripulSheet(item: $cancelling, size: .form) { order in
            CmsCancelOrderSheet(order: order) { refund in
                cancelling = nil
                Task { await cancel(order, refund: refund) }
            } onBack: { cancelling = nil }
            .environmentObject(runtime)
        }
        .alert(lodgifyTitle, isPresented: Binding(get: { cancellingLodgify != nil }, set: { if !$0 { cancellingLodgify = nil } }),
               presenting: cancellingLodgify) { booking in
            Button("Back", role: .cancel) { cancellingLodgify = nil }
            Button(lodgifyConfirm(booking), role: .destructive) {
                cancellingLodgify = nil
                Task { await cancelLodgify(booking) }
            }
        } message: { booking in
            Text(lodgifyMessage(booking))
        }
        .cmsInspectorID("Cms.websiteBookings")
    }

    // MARK: Website bookings

    private func websiteRow(_ o: CmsStaffOrder) -> some View {
        let expanded = open == o.id
        let money = { CmsBookingWording.money($0, o.currency) }
        let ended = o.hasEnded(today: CmsBookingWording.today())
        return CmsBookingCard(highlighted: o.status == "needs_review" ? .ripul(.warning) : nil) {
            Button {
                withAnimation(.snappy) { open = expanded ? nil : o.id }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(o.guest.name) · \(o.stays.map(\.label).joined(separator: " and "))")
                            .font(.ripul(.headline))
                        let due = o.balanceMinor > 0
                            ? " · \(money(o.balanceMinor)) due\(o.balanceDueOn.map { " \(CmsBookingWording.weekdayDay($0))" } ?? "")" : ""
                        Text("\(CmsBookingWording.weekdayDay(o.arrival)) – \(CmsBookingWording.weekdayDay(o.departure)) · \(o.reference) · paid \(money(o.paidMinor))\(due)")
                            .font(.ripul(.subheadline))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 4) {
                        CmsBookingTag(label: "Website", tone: .neutral, outlined: true)
                        CmsBookingTag(label: o.state, tone: CmsBookingWording.staffTone(o.status), outlined: o.status == "cancelled")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the details" : "Shows the details")
            if expanded {
                Divider()
                websiteDetails(o)
            }
        }
        .opacity(ended ? 0.7 : 1)
    }

    @ViewBuilder
    private func websiteDetails(_ o: CmsStaffOrder) -> some View {
        let money = { CmsBookingWording.money($0, o.currency) }
        if let problem = o.problem {
            CmsBookingNotice(kind: o.status == "needs_review" ? .warning : .info,
                             title: problem + (o.status == "needs_review" ? " Cancel it here to refund the guest by your terms, or put it back in Lodgify and press Keep." : ""))
        }
        Text("\(o.guest.email) · \(o.guest.phone)\(o.guest.notes.map { " · “\($0)”" } ?? "")").font(.ripul(.subheadline))
        Text("\(CmsBookingWording.day(o.arrival)) to \(CmsBookingWording.day(o.departure)) · booked \(CmsBookingWording.weekdayDay(String(o.createdAt.prefix(10))))")
            .font(.ripul(.subheadline))
        VStack(alignment: .leading, spacing: 2) {
            ForEach(o.stays, id: \.label) { s in
                Text("• \(s.label): \(CmsBookingWording.staffParty(adults: s.adults, children: s.children)), \(money(s.totalMinor))\(s.bookingId.map { " (Lodgify \($0))" } ?? "")")
            }
            ForEach(Array(o.extraNights.enumerated()), id: \.offset) { _, n in
                Text("• Extra night\(n.nights.count == 1 ? "" : "s") \(n.nights.map(CmsBookingWording.weekdayDay).joined(separator: ", ")): \(money(n.paidMinor)) paid")
            }
            ForEach(Array(o.extras.enumerated()), id: \.offset) { _, x in
                Text("• \(x.quantity > 1 ? "\(x.quantity) × " : "")\(x.name): \(money(x.unitMinor * x.quantity)) paid\(x.answer.map { " (\($0))" } ?? "")")
            }
        }
        .font(.ripul(.subheadline))
        let balance = o.balanceMinor > 0 ? " · balance \(money(o.balanceMinor))\(o.balanceDueOn.map { ", taken \(CmsBookingWording.day($0))" } ?? "")" : ""
        let refunded = o.refundedMinor != nil && o.status == "cancelled" ? " · refunded \(money(o.refundedMinor ?? 0))" : ""
        Text("Total \(money(o.totalMinor)) · paid \(money(o.paidMinor))\(balance)\(refunded)")
            .font(.ripul(.subheadline, weight: .semibold))
        if o.cancel != nil {
            HStack(spacing: 8) {
                Button(busy == o.id ? "Working…" : "Cancel booking", role: .destructive) { cancelling = o }
                    .buttonStyle(.bordered)
                    .disabled(busy == o.id)
                    .accessibilityIdentifier("Cms.websiteBookings.cancel")
                if o.status == "needs_review" {
                    Button("Keep: it is booked again in Lodgify") { Task { await keep(o) } }
                        .buttonStyle(.borderedProminent)
                        .tint(runtime.theme.primary)
                        .disabled(busy == o.id)
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Lodgify bookings

    private func lodgifyRow(_ b: CmsLodgifyBooking) -> some View {
        let key = "lgy-\(b.bookingId)"
        let expanded = open == key
        let money = { CmsBookingWording.money($0, b.currency) }
        return CmsBookingCard {
            Button {
                withAnimation(.snappy) { open = expanded ? nil : key }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(b.guest.name) · \(b.unit)").font(.ripul(.headline))
                        Text("\(CmsBookingWording.weekdayDay(b.arrival)) – \(CmsBookingWording.weekdayDay(b.departure)) · B\(b.bookingId) · \(money(b.totalMinor))\(b.extraNightFor.map { " · extra night for B\($0)" } ?? "")")
                            .font(.ripul(.subheadline))
                            .foregroundStyle(.ripul(.textSecondary))
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 4) {
                        CmsBookingTag(label: b.channel, tone: .neutral, outlined: true)
                        CmsBookingTag(label: b.status, tone: b.status == "Booked" ? .success : .neutral)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider()
                lodgifyDetails(b)
            }
        }
    }

    @ViewBuilder
    private func lodgifyDetails(_ b: CmsLodgifyBooking) -> some View {
        let money = { CmsBookingWording.money($0, b.currency) }
        let contact = [b.guest.email, b.guest.phone].filter { !$0.isEmpty }.joined(separator: " · ")
        Text("\(contact.isEmpty ? "No contact details in Lodgify" : contact)\(b.people > 0 ? " · \(b.people) guest\(b.people == 1 ? "" : "s")" : "")")
            .font(.ripul(.subheadline))
        Text("\(CmsBookingWording.day(b.arrival)) to \(CmsBookingWording.day(b.departure))").font(.ripul(.subheadline))
        ForEach(Array(b.extraNights.enumerated()), id: \.offset) { _, n in
            Text("Extra night\(n.nights.count == 1 ? "" : "s") \(n.nights.map(CmsBookingWording.weekdayDay).joined(separator: ", ")): \(money(n.paidMinor)) paid on the website\(n.linked.isEmpty ? "" : " (booked as \(n.linked.map { "B\($0)" }.joined(separator: ", ")))")")
                .font(.ripul(.subheadline))
        }
        if b.extraNightFor == nil, b.action.isChannel == false {
            Text("Total \(money(b.totalMinor)) · paid to Lodgify \(money(b.paidMinor)) · due \(money(b.dueMinor))")
                .font(.ripul(.subheadline, weight: .semibold))
        }
        switch b.action {
        case .channel(let channel):
            HStack(spacing: 4) {
                Text("Booked on \(channel), which holds the booking and the guest’s payment: cancel or change it there.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            if let link = Self.channelLinks[channel], let url = URL(string: link) {
                Link("Open \(channel)", destination: url).font(.ripul(.subheadline))
            }
        case .lodgify(let paid, let nights):
            CmsBookingNotice(kind: .info,
                             title: "The guest paid Lodgify \(money(paid)), so cancel this booking in Lodgify: only Lodgify’s own cancel refunds that payment. In the booking’s Quote box, click the status and choose Owner cancels to refund everything, or Guest cancels to refund by your policy."
                                + (nights > 0 ? " The \(money(nights)) paid on the website for its extra nights is refunded by the website automatically, within about 15 minutes of the cancel." : ""))
        case .cancel:
            EmptyView()
        }
        HStack(spacing: 8) {
            if let url = URL(string: b.lodgifyUrl) {
                if case .lodgify = b.action {
                    Link("Open in Lodgify", destination: url).buttonStyle(.borderedProminent).tint(runtime.theme.primary)
                } else {
                    Link("Open in Lodgify", destination: url).buttonStyle(.bordered)
                }
            }
            if case .cancel = b.action {
                let working = busy == String(b.bookingId)
                Button(working ? "Working…" : b.extraNightFor != nil ? "Cancel extra night" : "Cancel booking", role: .destructive) {
                    cancellingLodgify = b
                }
                .buttonStyle(.bordered)
                .disabled(working)
            }
        }
        .controlSize(.small)
    }

    private static let channelLinks = [
        "Booking.com": "https://admin.booking.com/",
        "Airbnb": "https://www.airbnb.co.uk/hosting/reservations",
    ]

    private var lodgifyTitle: String {
        guard let b = cancellingLodgify else { return "" }
        return b.extraNightFor != nil ? "Cancel \(b.guest.name)’s extra night?" : "Cancel \(b.guest.name)’s booking?"
    }

    private func lodgifyMessage(_ b: CmsLodgifyBooking) -> String {
        guard case .cancel(let refund) = b.action else { return "" }
        let money = { CmsBookingWording.money($0, b.currency) }
        var parts = ["\(b.unit), \(CmsBookingWording.weekdayDay(b.arrival)) – \(CmsBookingWording.weekdayDay(b.departure)) (Lodgify B\(b.bookingId)) goes to Lodgify’s bin, as cancelling it in Lodgify does."]
        if let stay = b.extraNightFor {
            parts.append("The \(money(refund)) paid for it on the website is refunded to the guest’s card. Their stay, B\(stay), is unchanged.")
        } else if !b.extraNights.isEmpty {
            let linked = b.extraNights.flatMap(\.linked)
            parts.append("The extra nights bought on the website are cancelled with it\(linked.isEmpty ? "" : " (\(linked.map { "B\($0)" }.joined(separator: ", ")))"), and their \(money(refund)) refunded to the guest’s card.")
        }
        parts.append("The website doesn’t email the guest about this: let them know yourself. A booking in Lodgify’s bin can be restored there.")
        return parts.joined(separator: "\n\n")
    }

    private func lodgifyConfirm(_ b: CmsLodgifyBooking) -> String {
        guard case .cancel(let refund) = b.action, refund > 0 else { return "Cancel in Lodgify" }
        return "Cancel and refund \(CmsBookingWording.money(refund, b.currency))"
    }

    // MARK: Calls

    private func load() async {
        guard let client = runtime.bookings else {
            error = "Sign in again to manage bookings."
            return
        }
        do {
            bookings = try await client.staffBookings()
            error = nil
        } catch {
            self.error = (error as? CmsBookingsError)?.errorDescription ?? "The bookings could not be loaded."
        }
    }

    private func cancel(_ order: CmsStaffOrder, refund: CmsRefundChoice) async {
        guard let client = runtime.bookings else { return }
        busy = order.id
        error = nil
        do {
            let result = try await client.cancelOrder(order.id, refund: refund)
            let refunded = result.refundedMinor > 0
                ? "\(CmsBookingWording.money(result.refundedMinor, order.currency)) refunded to their card." : "Nothing refunded."
            outcome = ("\(order.guest.name)’s booking is cancelled. \(refunded)", result.problems)
            await load()
        } catch {
            self.error = (error as? CmsBookingsError)?.errorDescription ?? "The booking could not be cancelled."
        }
        busy = nil
    }

    private func keep(_ order: CmsStaffOrder) async {
        guard let client = runtime.bookings else { return }
        busy = order.id
        error = nil
        do {
            try await client.keepOrder(order.id)
            await load()
        } catch {
            self.error = (error as? CmsBookingsError)?.errorDescription ?? "The booking could not be put back."
        }
        busy = nil
    }

    private func cancelLodgify(_ booking: CmsLodgifyBooking) async {
        guard let client = runtime.bookings else { return }
        busy = String(booking.bookingId)
        error = nil
        do {
            let result = try await client.cancelLodgify(booking.bookingId)
            let cancelled = result.cancelled.isEmpty
                ? "Nothing was cancelled." : "Cancelled in Lodgify: \(result.cancelled.map { "B\($0)" }.joined(separator: ", "))."
            let refunded = result.refundedMinor > 0
                ? " \(CmsBookingWording.money(result.refundedMinor, booking.currency)) refunded to the guest’s card." : ""
            outcome = (cancelled + refunded, result.problems)
            await load()
        } catch {
            self.error = (error as? CmsBookingsError)?.errorDescription ?? "The booking could not be cancelled."
        }
        busy = nil
    }
}

private extension CmsLodgifyBooking.Action {
    var isChannel: Bool {
        if case .channel = self { return true }
        return false
    }
}

/// The web's cancel dialog, as a form sheet: the stay, the refund to choose
/// (by the terms when the terms give one, everything, or nothing), what
/// follows, and the button that says what will be refunded.
private struct CmsCancelOrderSheet: View {
    let order: CmsStaffOrder
    let onConfirm: (CmsRefundChoice) -> Void
    let onBack: () -> Void
    @State private var refund: CmsRefundChoice

    init(order: CmsStaffOrder, onConfirm: @escaping (CmsRefundChoice) -> Void, onBack: @escaping () -> Void) {
        self.order = order
        self.onConfirm = onConfirm
        self.onBack = onBack
        _refund = State(initialValue: CmsRefundChoice.initial(for: order.cancel))
    }

    var body: some View {
        let money = { CmsBookingWording.money($0, order.currency) }
        NavigationStack {
            Form {
                if let cancel = order.cancel {
                    Section {
                        Text("\(order.stays.map(\.label).joined(separator: " and ")), \(CmsBookingWording.weekdayDay(order.arrival)) – \(CmsBookingWording.weekdayDay(order.departure)): \(cancel.daysToArrival) days before arrival. Paid so far \(money(order.paidMinor)).")
                    }
                    Section {
                        Picker("Refund", selection: $refund) {
                            if let terms = cancel.termsMinor {
                                Text("By the terms: refund \(money(terms))\(cancel.fullRefundUntilDays.map { " (in full until \($0) days before; extras always)" } ?? "")")
                                    .tag(CmsRefundChoice.terms)
                            }
                            Text("Refund everything: \(money(cancel.fullMinor))").tag(CmsRefundChoice.full)
                            Text("Refund nothing").tag(CmsRefundChoice.none)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Refund")
                    } footer: {
                        Text("No balance will be taken. The cottages go back on sale in Lodgify, and the guest and you are emailed. This cannot be undone.")
                    }
                    Section {
                        Button("Cancel and refund \(money(refund.minor(for: cancel)))", role: .destructive) { onConfirm(refund) }
                            .accessibilityIdentifier("Cms.websiteBookings.confirmCancel")
                    }
                }
            }
            .navigationTitle("Cancel \(order.guest.name)’s booking?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back", action: onBack) }
            }
        }
    }
}
#endif
