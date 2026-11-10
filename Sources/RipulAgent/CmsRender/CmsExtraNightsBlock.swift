#if os(iOS)
import SwiftUI

/// Native twin of `extraNights` (ExtraNightsBlock.tsx), for a booking site's
/// staff: the upcoming bookings with free nights just before or after the
/// stay, what each has been offered, and sending the offer email to those
/// chosen, at a discount set for this send. The levers against sending too
/// often are set each time; a booking they leave out says why, as the server
/// would. A sample goes to the site's own mailbox first; sending asks first.
struct CmsExtraNightsBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime

    @State private var candidates: [CmsNightCandidate]?
    @State private var currency = "gbp"
    @State private var error: String?
    @State private var chosen: Set<String> = []
    @State private var discount = ""
    @State private var skipDays = ""
    @State private var maxOffers = ""
    @State private var search = ""
    @State private var onlyOfferable = false
    @State private var busy: Busy?
    @State private var confirming = false
    @State private var results: (preview: Bool, results: [CmsNightSendResult])?
    @State private var started = false

    private enum Busy { case sample, send }

    private var levers: CmsNightLevers { CmsNightLevers(discount: discount, skipDays: skipDays, maxOffers: maxOffers) }

    var body: some View {
        let levers = self.levers
        let all = candidates ?? []
        let picked = all.filter { levers.heldBack($0) == nil && chosen.contains($0.orderId) }
        VStack(alignment: .leading, spacing: 16) {
            CmsBookingCard {
                lever("Discount (%)", text: $discount, valid: levers.discountPct != nil,
                      help: "Off what the nights would have cost them. 0 to 50.")
                lever("Skip if offered in the last (days)", text: $skipDays, valid: levers.skipOfferedWithinDays != nil,
                      help: "0: send whatever was sent before.")
                lever("At most offers per booking", text: $maxOffers, valid: levers.maxOffersPerBooking != nil,
                      help: "0: no limit.")
            }

            if let error { CmsBookingNotice(kind: .error, title: error) }
            if let results { resultsNotice(results) }

            if candidates == nil, error == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if all.isEmpty, candidates != nil {
                Text("No upcoming booking has a free night beside it just now.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
            } else if !all.isEmpty {
                list(all, levers: levers, picked: picked)
                HStack(spacing: 8) {
                    Button(busy == .sample ? "Sending…" : "Send me a sample") { Task { await run(preview: true, picked: picked) } }
                        .buttonStyle(.bordered)
                    Button(busy == .send ? "Sending…" : "Send offers to \(picked.count) guest\(picked.count == 1 ? "" : "s")") {
                        confirming = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("Cms.extraNights.send")
                }
                .tint(runtime.theme.primary)
                .disabled(picked.isEmpty || !levers.isValid || busy != nil)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            // The props' starting values, as the web's defaults.
            discount = String(Int(block.props.double("defaultDiscount") ?? 15))
            skipDays = String(Int(block.props.double("defaultSkipDays") ?? 14))
            maxOffers = String(Int(block.props.double("defaultMaxOffers") ?? 2))
        }
        .task { await load() }
        .alert("Send \(picked.count) offer\(picked.count == 1 ? "" : "s")?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Send") { Task { await run(preview: false, picked: picked) } }
        } message: {
            Text("Each guest is emailed the free nights beside their stay at \(levers.discountPct ?? 0)% off, paid in full by card if they take one. Lodgify is changed only once they pay.")
        }
        .cmsInspectorID("Cms.extraNights")
    }

    private func lever(_ label: String, text: Binding<String>, valid: Bool, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label) {
                TextField(label, text: text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                    .textFieldStyle(.roundedBorder)
            }
            .font(.ripul(.subheadline))
            Text(help)
                .font(.ripul(.caption))
                .foregroundStyle(valid ? .ripul(.textSecondary) : .ripul(.danger))
        }
    }

    @ViewBuilder
    private func list(_ all: [CmsNightCandidate], levers: CmsNightLevers, picked: [CmsNightCandidate]) -> some View {
        let shown = CmsBookingWording.shownCandidates(all, search: search, onlyOfferable: onlyOfferable, levers: levers)
        let shownChoosable = shown.filter { levers.heldBack($0) == nil }
        let shownPicked = shownChoosable.filter { chosen.contains($0.orderId) }
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.ripul(.textSecondary))
            TextField("Search by guest, email, reference, cottage or month", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Search the bookings")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: runtime.theme.cardCorner(10), style: .continuous).fill(Color.ripul(.surface)))
        Toggle("Only those that can be offered now", isOn: $onlyOfferable)
            .font(.ripul(.subheadline))
            .tint(runtime.theme.primary)
        HStack(spacing: 10) {
            let allPicked = !shownChoosable.isEmpty && shownPicked.count == shownChoosable.count
            Button {
                for c in shownChoosable {
                    if allPicked { chosen.remove(c.orderId) } else { chosen.insert(c.orderId) }
                }
            } label: {
                Image(systemName: allPicked ? "checkmark.circle.fill" : shownPicked.isEmpty ? "circle" : "minus.circle.fill")
                    .font(.ripul(.title3))
            }
            .buttonStyle(.borderless)
            .disabled(shownChoosable.isEmpty)
            .accessibilityLabel("Choose every booking shown that can be offered")
            Text("\(shown.count == all.count ? "\(all.count) booking\(all.count == 1 ? "" : "s") with free nights beside them" : "\(shown.count) of \(all.count) shown") · \(picked.count) chosen")
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.textSecondary))
        }
        if shown.isEmpty {
            Text("No booking matches that search.")
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.textSecondary))
        }
        ForEach(shown) { row($0, why: levers.heldBack($0)) }
    }

    private func row(_ c: CmsNightCandidate, why: String?) -> some View {
        let isChosen = why == nil && chosen.contains(c.orderId)
        return Button {
            if chosen.contains(c.orderId) { chosen.remove(c.orderId) } else { chosen.insert(c.orderId) }
        } label: {
            CmsBookingCard(highlighted: isChosen ? runtime.theme.primary : nil) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .font(.ripul(.title3))
                        .foregroundStyle(isChosen ? runtime.theme.primary : Color.ripul(.textTertiary))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(c.guest) · \(c.units.joined(separator: " and "))").font(.ripul(.headline))
                        Text("\(CmsBookingWording.weekdayDay(c.arrival)) – \(CmsBookingWording.weekdayDay(c.departure)) · \(c.source) · \(c.reference) · \(c.email)")
                            .font(.ripul(.subheadline))
                            .foregroundStyle(.ripul(.textSecondary))
                        CmsFlowRow(spacing: 6) {
                            ForEach(c.before.reversed(), id: \.self) {
                                CmsBookingTag(label: "Before: \(CmsBookingWording.weekdayDay($0))", tone: .neutral, outlined: true)
                            }
                            ForEach(c.after, id: \.self) {
                                CmsBookingTag(label: "After: \(CmsBookingWording.weekdayDay($0))", tone: .neutral, outlined: true)
                            }
                        }
                        Text(why ?? history(c))
                            .font(.ripul(.caption))
                            .foregroundStyle(why != nil ? .ripul(.warning) : .ripul(.textSecondary))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(why != nil)
        .opacity(why != nil ? 0.6 : 1)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func history(_ c: CmsNightCandidate) -> String {
        guard c.offers > 0, let last = c.lastOfferedAt else { return "Not offered yet" }
        let status = CmsBookingWording.lastOfferStatus(c.lastOfferStatus).map { " (\($0))" } ?? ""
        return "Offered \(c.offers) time\(c.offers == 1 ? "" : "s"), last \(CmsBookingWording.weekdayDay(String(last.prefix(10))))\(status)"
    }

    private func resultsNotice(_ results: (preview: Bool, results: [CmsNightSendResult])) -> some View {
        let title = results.preview
            ? "Samples sent to \(results.results.first(where: { $0.to != nil })?.to ?? "the site’s mailbox")"
            : "\(results.results.filter(\.sent).count) of \(results.results.count) offers sent"
        let lines = results.results.map { r in
            "\(r.reference): " + (r.sent
                ? (r.options ?? []).map { "\($0.name) \(CmsBookingWording.money($0.priceMinor, currency))" }.joined(separator: " · ")
                : (r.skipped ?? ""))
        }
        return CmsBookingNotice(kind: results.results.contains(where: \.sent) ? .success : .info, title: title, lines: lines) {
            self.results = nil
        }
    }

    private func load() async {
        guard let client = runtime.bookings else {
            error = "Sign in again to send offers."
            return
        }
        do {
            let found = try await client.nightCandidates()
            candidates = found.candidates
            currency = found.currency
            error = nil
        } catch {
            self.error = (error as? CmsBookingsError)?.errorDescription ?? "The bookings could not be loaded."
        }
    }

    private func run(preview: Bool, picked: [CmsNightCandidate]) async {
        let levers = self.levers
        guard levers.isValid, !picked.isEmpty, let client = runtime.bookings else { return }
        busy = preview ? .sample : .send
        error = nil
        do {
            let answer = try await client.sendNightOffers(orderIds: picked.map(\.orderId), levers: levers, preview: preview)
            results = (preview, answer)
            if !preview {
                chosen = []
                await load()
            }
        } catch {
            self.error = (error as? CmsBookingsError)?.errorDescription ?? "The offers could not be sent."
        }
        busy = nil
    }
}

/// Lozenges that wrap onto the next line, as the web's flex-wrap.
struct CmsFlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(width: bounds.width, subviews: subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), points)
    }
}
#endif
