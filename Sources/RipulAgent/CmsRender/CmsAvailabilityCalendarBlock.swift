#if os(iOS)
import SwiftUI

/// The `availabilityCalendar` block natively: the web's AvailabilityCalendarBlock
/// (rules in CmsAvailability). A month at a time, as the web shows on a phone,
/// each day with one mark per unit (a dot when free, a cross when taken, a faint
/// ring when not known) and a shade when every unit is free; arrows and a
/// sideways swipe between months up to a year ahead, and the month's name opens
/// a menu of months. Tap the arrival, then the departure; a choice the feeds rule
/// out is refused with the web's words. With `checkout`, the free units can be
/// ticked with their guests and the price comes from the site's quote. Payment
/// is not here yet: it waits on how the app should take it.
struct CmsAvailabilityCalendarBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var feeds = CmsAvailabilityFeeds()
    @State private var first = CmsAvailabilityCalendarBlockView.startOfMonth(Date())
    @State private var choice = CmsAvailability.Choice()
    @State private var helpOpen = false
    @State private var notice: String?
    @State private var slide: Edge = .trailing
    @State private var signingIn = false

    private var props: CmsAvailability.Props { CmsAvailability.Props(runtime.resolvedProps(for: block)) }
    private var today: String { CmsAvailability.key(Date()) }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }

    var body: some View {
        let props = self.props
        let colours = props.units.indices.map { unitColour(props, $0) }
        VStack(alignment: .leading, spacing: 12) {
            header
            month(props, colours: colours)
                .id(CmsAvailability.key(first))
                .transition(.asymmetric(insertion: .move(edge: slide).combined(with: .opacity), removal: .opacity))
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    guard abs(dx) >= 40, abs(dx) >= abs(dy) * 1.5 else { return }
                    go(dx < 0 ? 1 : -1)
                })
            key(props, colours: colours)
            if helpOpen { help(props, colours: colours) }
            stayPanel(props, colours: colours)
        }
        .padding(props.surfacePaper ? 12 : 0)
        .background {
            if props.surfacePaper {
                RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous).fill(runtime.theme.paper)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .cmsSiteFont("body2", 14, relativeTo: .subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .task(id: props.units.map(\.feed)) { await feeds.load(site: runtime.cmsId, feeds: props.units.map(\.feed)) }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app shows the latest copy, and a fresh one if it is due.
            if phase == .active { Task { await feeds.load(site: runtime.cmsId, feeds: props.units.map(\.feed)) } }
        }
        // From the calendar's root, not inside the stay panel, whose navy text style
        // a sheet would inherit (its prominent button lost its white label).
        .ripulSheet(isPresented: $signingIn) {
            if let signIn = runtime.siteSignIn {
                // The app's own sign-in sheet; the dates and choices stay as they are.
                CmsSiteSignInSheet(signIn: signIn, formProps: [:], wording: .returningGuest) { _ in signingIn = false }
                    .environmentObject(runtime)
            }
        }
        .cmsInspectorID("Cms.availabilityCalendar")
    }

    // MARK: Months

    private static func startOfMonth(_ date: Date) -> Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: date)) ?? date
    }

    private var thisMonth: Date { Self.startOfMonth(Date()) }
    private var lastMonth: Date { Calendar.current.date(byAdding: .month, value: 11, to: thisMonth) ?? thisMonth }
    private var canBack: Bool { first > thisMonth }
    private var canForward: Bool { first < lastMonth }

    private func go(_ step: Int) {
        guard step > 0 ? canForward : canBack else { return }
        slide = step > 0 ? .trailing : .leading
        withAnimation(.easeOut(duration: 0.22)) {
            first = Calendar.current.date(byAdding: .month, value: step, to: first) ?? first
        }
    }

    private var header: some View {
        HStack {
            Button { go(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .disabled(!canBack)
                .accessibilityLabel("Previous month")
            Spacer()
            Text(feeds.status)
                .cmsSiteFont("caption", 12, relativeTo: .caption)
                .foregroundStyle(.ripul(.textSecondary))
            Spacer()
            Button { go(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(!canForward)
                .accessibilityLabel("Next month")
        }
        .tint(runtime.theme.textPrimary)
    }

    private func month(_ props: CmsAvailability.Props, colours: [Color]) -> some View {
        let days = monthDays(first)
        return VStack(spacing: 8) {
            Menu {
                ForEach(0..<12, id: \.self) { i in
                    let m = Calendar.current.date(byAdding: .month, value: i, to: thisMonth) ?? thisMonth
                    Button {
                        slide = m > first ? .trailing : .leading
                        withAnimation(.easeOut(duration: 0.22)) { first = m }
                    } label: {
                        if m == first { Label(monthName(m), systemImage: "checkmark") } else { Text(monthName(m)) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(monthName(first)).cmsSiteFont("body1", 16, relativeTo: .headline, weight: 600)
                    Image(systemName: "chevron.down").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                }
                .foregroundStyle(runtime.theme.textPrimary)
            }
            .accessibilityLabel("\(monthName(first)). Choose a month")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                // By place: "T" and "S" come twice.
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .cmsSiteFont("caption", 12, relativeTo: .caption)
                        .foregroundStyle(.ripul(.textSecondary))
                        .accessibilityHidden(true)
                }
                ForEach(days.indices, id: \.self) { i in
                    if let day = days[i] {
                        dayCell(day, props: props, colours: colours)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
    }

    private var weekdaySymbols: [String] {
        // Monday first, as the web's weekStartsOn: 1; the symbols' own order starts on Sunday.
        let s = calendar.veryShortStandaloneWeekdaySymbols
        return Array(s[1...]) + [s[0]]
    }

    /// The month's days as keys, padded with nils to start on a Monday.
    private func monthDays(_ month: Date) -> [String?] {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = cal.component(.weekday, from: month) // 1 = Sunday
        let lead = (weekday + 5) % 7
        return Array(repeating: nil, count: lead) + range.compactMap { d in
            cal.date(byAdding: .day, value: d - 1, to: month).map { CmsAvailability.key($0) }
        }
    }

    private func monthName(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    private func longDay(_ day: String) -> String {
        guard let date = CmsAvailability.date(day) else { return day }
        let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }

    private func dayCell(_ day: String, props: CmsAvailability.Props, colours: [Color]) -> some View {
        let past = day < today
        let states = props.units.indices.map { CmsAvailability.state(feeds.units[safe: $0] ?? nil, day) }
        let allFree = !props.togetherLabel.isEmpty && states.allSatisfy { $0 == .free }
        let inStay = choice.arrival.map { a in day == a || (choice.departure.map { day > a && day <= $0 } ?? false) } ?? false
        let end = day == choice.arrival || day == choice.departure
        let mark = markColour(props)
        let shape = RoundedRectangle(cornerRadius: runtime.theme.baseRadius, style: .continuous)
        return Button { tap(day) } label: {
            VStack(spacing: 4) {
                Text(String(Int(day.suffix(2)) ?? 0))
                    .modifier(CmsScaledFont(theme: runtime.theme, size: 14.4, weight: end ? .bold : .regular, relativeTo: .subheadline))
                    .foregroundStyle(runtime.theme.textPrimary)
                HStack(spacing: 3) {
                    ForEach(states.indices, id: \.self) { i in
                        CmsAvailabilityMark(state: states[i], colour: colours[i])
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(shape.fill(inStay ? mark.opacity(0.18) : allFree ? togetherColour(props).opacity(0.14) : .clear))
            .overlay { if inStay { shape.strokeBorder(mark, lineWidth: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(past)
        .opacity(past ? 0.35 : 1)
        .accessibilityLabel(dayLabel(day, props: props, states: states))
        .accessibilityAddTraits(end ? .isSelected : [])
    }

    private func dayLabel(_ day: String, props: CmsAvailability.Props, states: [CmsAvailability.DayState]) -> String {
        let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEEE d MMMM"
        let name = CmsAvailability.date(day).map { f.string(from: $0) } ?? day
        let parts = props.units.indices.map { i in
            "\(props.units[i].label) \(states[i] == .free ? "available" : states[i] == .taken ? "taken" : "not known")"
        }
        return "\(name): \(parts.joined(separator: ", "))"
    }

    private func tap(_ day: String) {
        let loaded: [CmsAvailability.Unit?]? = feeds.loaded ? feeds.units : nil
        switch CmsAvailability.choose(day, current: choice, units: loaded, today: today, longDay: longDay) {
        case .chosen(let next): withAnimation(.snappy) { choice = next }
        case .refused(let words): show(words)
        case .ignored: break
        }
    }

    private func show(_ words: String) {
        withAnimation { notice = words }
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation { if notice == words { notice = nil } }
        }
    }

    // MARK: Colours

    private func unitColour(_ props: CmsAvailability.Props, _ i: Int) -> Color {
        let token = props.colourToken(i)
        return runtime.color(token) ?? CmsCss.color(token) ?? markColour(props)
    }

    private func markColour(_ props: CmsAvailability.Props) -> Color {
        runtime.color(props.markColor) ?? runtime.theme.primary
    }

    private func togetherColour(_ props: CmsAvailability.Props) -> Color {
        runtime.color(props.togetherColor) ?? runtime.theme.primary
    }

    // MARK: Key and help

    private func key(_ props: CmsAvailability.Props, colours: [Color]) -> some View {
        // Along one row, wrapping only when it must (the web's flex-wrap), help last.
        CmsFlowLayout(spacing: 16, lineSpacing: 8) {
            keyItems(props, colours: colours)
            if !props.helpLabel.isEmpty {
                Button { withAnimation { helpOpen.toggle() } } label: {
                    Label(props.helpLabel, systemImage: "questionmark.circle")
                        .cmsSiteFont("body2", 14, relativeTo: .subheadline)
                        .foregroundStyle(.ripul(.textSecondary))
                }
                .accessibilityValue(helpOpen ? "Open" : "Closed")
            }
        }
    }

    @ViewBuilder
    private func keyItems(_ props: CmsAvailability.Props, colours: [Color]) -> some View {
        ForEach(props.units.indices, id: \.self) { i in
            HStack(spacing: 6) {
                CmsAvailabilityMark(state: .free, colour: colours[i])
                Text(props.units[i].label).cmsSiteFont("body2", 14, relativeTo: .subheadline).foregroundStyle(runtime.theme.textPrimary)
            }
        }
        if props.explainMarks && !props.togetherLabel.isEmpty && props.units.count > 1 {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(togetherColour(props).opacity(0.14)).frame(width: 16, height: 16)
                Text(props.togetherLabel).cmsSiteFont("body2", 14, relativeTo: .subheadline).foregroundStyle(runtime.theme.textPrimary)
            }
        }
        if props.explainMarks {
            Text("Dot: available. Cross: taken.").cmsSiteFont("body2", 14, relativeTo: .subheadline).foregroundStyle(.ripul(.textSecondary))
        }
    }

    /// Everything the marks, shading and panel mean, behind the help label (the web's HelpPanel).
    private func help(_ props: CmsAvailability.Props, colours: [Color]) -> some View {
        let names = props.units.map(\.label)
        let count = CmsAvailability.numberWords[safe: names.count] ?? String(names.count)
        let mark = markColour(props)
        func row(_ state: CmsAvailability.DayState, _ text: String) -> some View {
            HStack(spacing: 12) {
                HStack(spacing: 3) { ForEach(colours.indices, id: \.self) { CmsAvailabilityMark(state: state, colour: colours[$0]) } }
                    .frame(minWidth: 56)
                Text(text).cmsSiteFont("body2", 14, relativeTo: .subheadline)
            }
        }
        func heading(_ t: String) -> some View { Text(t).cmsSiteFont("subtitle2", 14, relativeTo: .subheadline, weight: 700).padding(.top, 8) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(names.count > 1 ? "Each day shows \(count) marks, one for each of \(CmsAvailability.listOf(names)), in the colour named in the key." : "Each day shows a mark for \(names.first ?? "").")
                .cmsSiteFont("body2", 14, relativeTo: .subheadline)
            heading("What the marks mean")
            row(.free, "A dot in a colour: that one is available that night.")
            row(.taken, "A cross: that night is taken, booked or closed.")
            row(.unknown, "A faint ring: not known yet, for days before today or more than a year ahead.")
            if !props.togetherLabel.isEmpty && names.count > 1 {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(togetherColour(props).opacity(0.14)).frame(width: 28, height: 18).frame(minWidth: 56)
                    Text("A shaded day: all \(count) are available that night.").cmsSiteFont("body2", 14, relativeTo: .subheadline)
                }
            }
            heading("Choosing your dates")
            Text("Tap the day you arrive, then the day you leave. Every day of your stay is ringed, from arrival to departure. You can arrive on a day when \(names.count > 1 ? "at least one of them" : names.first ?? "it") is available and stay for as long as it remains available; the day you leave may be taken, since you leave that morning. If you tap dates that are not available, a message says so. Tap another day to start again, or choose Clear dates. Use the arrows, or swipe across the month, to move between months, up to a year ahead. Tap the month’s name to jump straight to another month.")
                .cmsSiteFont("body2", 14, relativeTo: .subheadline)
            heading("Keeping up to date")
            Text("Availability is checked every 15 minutes, and the time it was last checked is shown at the top.")
                .cmsSiteFont("body2", 14, relativeTo: .subheadline)
            HStack { Spacer(); Button("Close") { withAnimation { helpOpen = false } } }
        }
        .foregroundStyle(runtime.theme.textPrimary)
        .padding(12)
        .background(mark.opacity(0.04), in: RoundedRectangle(cornerRadius: runtime.theme.baseRadius))
        .overlay(RoundedRectangle(cornerRadius: runtime.theme.baseRadius).strokeBorder(mark.opacity(0.15)))
    }

    // MARK: The stay

    @ViewBuilder
    private func stayPanel(_ props: CmsAvailability.Props, colours: [Color]) -> some View {
        let mark = markColour(props)
        VStack(alignment: .leading, spacing: 10) {
            if choice.arrival == nil {
                Label("Choose your arrival date.", systemImage: "calendar.badge.checkmark")
                    .cmsSiteFont("body1", 16)
            } else if let arrival = choice.arrival, choice.departure == nil {
                CmsFlowLayout(spacing: 16) {
                    Text("Arriving \(longDay(arrival)). Now choose your departure date.").cmsSiteFont("body1", 16)
                    Button("Clear dates") { withAnimation { choice = .init() } }.cmsSiteFont("body2", 14, relativeTo: .subheadline)
                }
            } else if let arrival = choice.arrival, let departure = choice.departure {
                let nights = CmsAvailability.nights(arrival, departure)
                CmsFlowLayout(spacing: 16) {
                    Text("\(longDay(arrival)) – \(longDay(departure)) · \(nights.count) \(nights.count == 1 ? "night" : "nights")")
                        .cmsSiteFont("body1", 16, weight: 600)
                    Button("Clear dates") { withAnimation { choice = .init() } }.cmsSiteFont("body2", 14, relativeTo: .subheadline)
                }
                if !props.togetherLabel.isEmpty, props.units.count > 1,
                   props.units.indices.allSatisfy({ i in feeds.units[safe: i]??.isFreeFor(nights) == true }) {
                    Text("All \(props.units.count) are available for these dates.").cmsSiteFont("body1", 16)
                }
                if props.checkout {
                    CmsAvailabilityCheckout(
                        site: runtime.cmsId, arrival: arrival, departure: departure, mark: mark,
                        units: props.units.indices.compactMap { i in
                            guard let key = props.units[i].bookingKey else { return nil }
                            return .init(key: key, label: props.units[i].label, maxGuests: props.units[i].maxGuests,
                                         colour: colours[i], free: feeds.units[safe: i]??.isFreeFor(nights) == true)
                        },
                        signIn: { signingIn = true })
                } else {
                    ForEach(props.units.indices, id: \.self) { i in
                        let stay = feeds.units[safe: i]?.map { CmsAvailability.stay($0, nights) } ?? nil
                        VStack(alignment: .leading, spacing: 2) {
                            Text(props.units[i].label).cmsSiteFont("body1", 16, weight: 600)
                            Text(stay == nil ? "Availability not known." : stay!.free ? "Available for your stay." : "Taken on \(longDay(stay!.firstTaken ?? "")).")
                                .cmsSiteFont("body2", 14, relativeTo: .subheadline).foregroundStyle(.ripul(.textSecondary))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .foregroundStyle(runtime.theme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(mark.opacity(0.06), in: RoundedRectangle(cornerRadius: runtime.theme.baseRadius))
        .overlay(RoundedRectangle(cornerRadius: runtime.theme.baseRadius).strokeBorder(mark.opacity(0.15)))
        .accessibilityElement(children: .contain)
    }
}

private extension CmsAvailability.Unit {
    func isFreeFor(_ nights: [String]) -> Bool { CmsAvailability.stay(self, nights).free }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// One unit's mark on a day: a filled dot when available, a cross when taken, a faint ring when not known.
struct CmsAvailabilityMark: View {
    let state: CmsAvailability.DayState
    let colour: Color

    var body: some View {
        switch state {
        case .taken:
            Path { p in
                p.move(to: CGPoint(x: 1.6, y: 1.6)); p.addLine(to: CGPoint(x: 7.4, y: 7.4))
                p.move(to: CGPoint(x: 7.4, y: 1.6)); p.addLine(to: CGPoint(x: 1.6, y: 7.4))
            }
            .stroke(colour, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
        case .free:
            Circle().fill(colour).frame(width: 7, height: 7).accessibilityHidden(true)
        case .unknown:
            Circle().strokeBorder(colour, lineWidth: 1).frame(width: 7, height: 7).opacity(0.2).accessibilityHidden(true)
        }
    }
}

/// Each unit's feed, as the web reads them: the latest copy each has had, and a
/// fresh copy asked for when the feed refreshes on view and its copy is old.
@MainActor
final class CmsAvailabilityFeeds: ObservableObject {
    @Published private(set) var units: [CmsAvailability.Unit?] = []
    @Published private(set) var loaded = false
    @Published private(set) var checking = 0
    private var feedNames: [String] = []

    var status: String {
        if loaded && units.allSatisfy({ $0 == nil }) { return "Availability is not available just now." }
        if !loaded { return "Loading availability…" }
        let times = units.compactMap { $0?.refreshedAt }.sorted()
        guard let first = times.first, let date = CmsAvailability.parseInstant(first) else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "Updated \(f.string(from: date))\(checking > 0 ? " · checking for changes…" : "")"
    }

    private struct Feed: Decodable {
        var refreshedAt: String?
        var data: CmsJSON?
        var refreshOnViewMinutes: Double?
    }

    private static func url(_ site: String, _ feed: String) -> URL? {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s }
        return URL(string: "\(RipulDomain.llmProxyURL)/v1/cms-feeds/\(enc(site))/\(enc(feed))")
    }

    func load(site: String, feeds names: [String]) async {
        if names != feedNames {
            // Other feeds: nothing of the last ones is kept.
            feedNames = names
            units = names.map { _ in nil }
            loaded = false
        }
        let bodies = await withTaskGroup(of: (Int, Feed?).self) { group in
            for (i, name) in names.enumerated() {
                group.addTask { (i, name.isEmpty ? nil : await Self.fetch(Self.url(site, name), method: "GET")) }
            }
            var out = [Feed?](repeating: nil, count: names.count)
            for await (i, body) in group { out[i] = body }
            return out
        }
        guard names == feedNames else { return }
        for (i, body) in bodies.enumerated() { keep(i, body) }
        loaded = true
        for (i, body) in bodies.enumerated() where !names[i].isEmpty {
            guard let body, CmsAvailability.wantsRefresh(refreshedAt: body.refreshedAt, minutes: body.refreshOnViewMinutes) else { continue }
            checking += 1
            let fresh = await Self.fetch(Self.url(site, names[i]).map { $0.appendingPathComponent("refresh") }, method: "POST")
            checking -= 1
            if names == feedNames { keep(i, fresh) }
        }
    }

    private func keep(_ i: Int, _ body: Feed?) {
        guard units.indices.contains(i) else { return }
        let copy = body.flatMap { b in b.data?.objectValue.map { CmsAvailability.read(data: $0, refreshedAt: b.refreshedAt) } }
        units[i] = CmsAvailability.newer(units[i], copy)
    }

    private static func fetch(_ url: URL?, method: String) async -> Feed? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Feed.self, from: data)
    }
}
#endif
