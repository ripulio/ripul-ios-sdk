import SwiftUI

/// Native twin of `varianceImpact` (VarianceImpactBlock.tsx +
/// varianceImpact.ts): wac's impact, all time — every confirmed variance
/// (hours and £ in the worker's and the company's favour), what kinds, how
/// they were found, the last 12 months, and the shifts wac has tracked. Reads
/// two queries and changes nothing.
///
/// Semantics: `summarise`, `shiftTotals`, `hoursLabel` and the kind/found
/// labels ported function for function. Presentation: the brand hero, a
/// two-column grid of figures, system progress bars for the breakdowns and a
/// bar chart for the months.
///
/// The months are drawn with SwiftUI shapes, not Swift Charts: a host app with
/// a CocoaPod named `Charts` (wac has danielgindi/Charts 3.6) links that pod's
/// Charts.framework in place of Apple's, and every Swift Charts symbol the SDK
/// uses is then undefined at the host's link.
struct CmsVarianceImpactBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    private var props: [String: CmsJSON] { block.props }
    private var varianceSlug: String { props.string("varianceQuerySlug") ?? "" }
    private var shiftsSlug: String { props.string("shiftsQuerySlug") ?? "" }
    private var currency: String { props.string("currency").flatMap { $0.isEmpty ? nil : $0 } ?? "GBP" }

    private func rows(_ slug: String) -> [[String: CmsJSON]]? {
        guard !slug.isEmpty, case .ok(let r) = runtime.state(for: slug) else { return nil }
        return r.rows
    }

    var body: some View {
        let vRows = rows(varianceSlug)
        let loading = !varianceSlug.isEmpty && vRows == nil
        let shifts = Impact.shiftTotals(rows(shiftsSlug) ?? [])
        let impact = Impact.summarise(vRows ?? [], shifts: shifts)
        let since = impact.since ?? shifts.flatMap { Impact.date($0.firstDay) }
        let onBrand = runtime.theme.primaryContrast

        VStack(alignment: .leading, spacing: 16) {
            let heading = props.string("heading") ?? "wac’s impact"
            if !heading.isEmpty {
                Text(heading).font(.system(size: 22, weight: .bold)).tracking(-0.4)
            }
            if let intro = props.string("intro"), !intro.isEmpty {
                Text(intro).font(.system(size: 13.5)).foregroundColor(runtime.theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("ALL TIME" + (since.map { " · SINCE \($0.formatted(.dateTime.month(.wide).year()).uppercased())" } ?? ""))
                    .font(.system(size: 11.5, weight: .bold)).tracking(1.2).opacity(0.85)
                if loading {
                    ProgressView().tint(onBrand).padding(.vertical, 12)
                } else if impact.count == 0 {
                    Text("Every variance wac finds will add up here").font(.system(size: 24, weight: .bold))
                    Text("A wac out or wac in corrected on the shifts is counted automatically. Anything else ticked off on Reconcile asks whether pay changed, either way, and only a yes is counted.")
                        .font(.system(size: 13.5)).opacity(0.9)
                } else {
                    Text(impact.amount > 0 ? money(impact.amount) : Impact.hoursLabel(impact.hours))
                        .font(.system(size: 40, weight: .bold))
                    Text("of variance found and put right").font(.system(size: 14)).opacity(0.92)
                    // For an employer wac's job is to find them money: that leads.
                    VStack(alignment: .leading, spacing: 8) {
                        pill("\(money(impact.company.amount)) found for your business", side: impact.company)
                        pill("\(money(impact.worker.amount)) put right for your team", side: impact.worker)
                    }
                    .padding(.top, 8)
                    Text("One record both sides can trust.").font(.system(size: 12.5)).opacity(0.85).padding(.top, 4)
                }
            }
            .foregroundColor(onBrand)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(runtime.theme.gradient, in: RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous))
            .cmsInspectorID("Cms.varianceImpact.hero")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                tile("Hours of variance", Impact.hoursLabel(impact.hours), "Pay now matches the hours worked")
                tile("Variances found", count(impact.count), foundSub(impact))
                tile("Time to put right", impact.avgDaysToFix.map { $0 < 1 ? "Same day" : String(format: "%.1f days", $0) } ?? "–",
                     "From found to fixed, on average")
                if let shifts {
                    tile("Shifts tracked on wac", count(Int(shifts.shifts)), "\(Impact.hoursLabel(shifts.hours)) · \(count(Int(shifts.people))) people")
                }
            }

            card(title: "What wac found") { bars(impact.byKind) }
            card(title: "How it was found") { bars(impact.byFound) }
            card(title: "The last 12 months") { months(impact.byMonth) }
        }
        .onAppear {
            runtime.ensureLoaded(varianceSlug)
            runtime.ensureLoaded(shiftsSlug)
        }
    }

    private func money(_ x: Double, whole: Bool = false) -> String {
        x.formatted(.currency(code: currency).precision(.fractionLength(whole ? 0 : 2)).locale(Locale(identifier: "en_GB")))
    }

    private func count(_ x: Int) -> String { x.formatted(.number.locale(Locale(identifier: "en_GB"))) }

    private func foundSub(_ impact: Impact) -> String {
        let parts = [
            impact.fixedOnShifts > 0 ? "\(count(impact.fixedOnShifts)) seen on the shifts" : "",
            impact.count - impact.fixedOnShifts > 0 ? "\(count(impact.count - impact.fixedOnShifts)) confirmed by a manager" : "",
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? "Each one confirmed" : parts.joined(separator: " · ")
    }

    private func pill(_ title: String, side: Impact.Side) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13, weight: .bold))
            Text("\(count(side.count)) \(side.count == 1 ? "variance" : "variances") · \(Impact.hoursLabel(side.hours))")
                .font(.system(size: 11.5)).opacity(0.85)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(runtime.theme.primaryContrast.opacity(0.16)))
    }

    private var cardShape: some View {
        RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous)
            .fill(runtime.theme.paper)
            .overlay(RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous).strokeBorder(runtime.theme.divider))
    }

    private func tile(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundColor(runtime.theme.textSecondary)
            Text(value).font(.system(size: 24, weight: .bold)).minimumScaleFactor(0.6).lineLimit(1)
            Text(sub).font(.system(size: 12)).foregroundColor(runtime.theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(cardShape)
        .cmsInspectorID("Cms.varianceImpact.tile")
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .bold))
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape)
    }

    @ViewBuilder
    private func bars(_ list: [Impact.Bar]) -> some View {
        if list.isEmpty {
            Text("Nothing yet.").font(.system(size: 13)).foregroundColor(runtime.theme.textSecondary)
        } else {
            let useMoney = list.contains { $0.amount > 0 }
            let maxValue = max(1, list.map { useMoney ? $0.amount : Double($0.count) }.max() ?? 1)
            VStack(spacing: 12) {
                ForEach(list, id: \.label) { b in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(b.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text("\(count(b.count)) · \(useMoney ? money(b.amount) : Impact.hoursLabel(b.hours))")
                                .font(.system(size: 13)).foregroundColor(runtime.theme.textSecondary)
                        }
                        ProgressView(value: max(0.04, (useMoney ? b.amount : Double(b.count)) / maxValue))
                            .tint(runtime.theme.primary)
                    }
                }
            }
        }
    }

    private func months(_ list: [Impact.Bar]) -> some View {
        let useMoney = list.contains { $0.amount > 0 }
        let value: (Impact.Bar) -> Double = { useMoney ? $0.amount : Double($0.count) }
        let top = max(list.map(value).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(list, id: \.key) { m in
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        VStack {
                            Spacer(minLength: 0)
                            UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5, style: .continuous)
                                .fill(runtime.theme.gradient)
                                .frame(height: value(m) > 0 ? max(2, geo.size.height * value(m) / top) : 0)
                        }
                    }
                    Text(m.label)
                        .font(.system(size: 10)).foregroundColor(runtime.theme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(m.label)
                .accessibilityValue(useMoney ? String(format: "£%.0f", m.amount) : "\(m.count) variances")
            }
        }
        .frame(height: 150)
        .cmsInspectorID("Cms.varianceImpact.months")
    }
}

/// varianceImpact.ts, ported function for function.
struct Impact {
    struct Side { var count = 0; var amount = 0.0; var hours = 0.0 }
    struct Bar { var label: String; var key = ""; var count = 0; var amount = 0.0; var hours = 0.0 }
    struct ShiftTotals { var shifts: Double; var hours: Double; var pay: Double; var people: Double; var firstDay: String }

    var count = 0
    var amount = 0.0
    var hours = 0.0
    var worker = Side()
    var company = Side()
    var avgDaysToFix: Double?
    var fixedOnShifts = 0
    var since: Date?
    var byKind: [Bar] = []
    var byFound: [Bar] = []
    var byMonth: [Bar] = []

    static let kindLabels = [
        "wac_out": "No wac out", "wac_in": "No wac in", "hours": "Hours against the rota", "break": "Breaks",
        "not_on_rota": "Not on the rota", "location_in": "Away from site", "location_out": "Away from site",
        "rule": "Rules", "other": "Other",
    ]

    static func foundByLabel(_ foundBy: String) -> String {
        let f = foundBy.lowercased()
        if f.contains("location") { return "Location check" }
        if f.contains("dashboard") { return "Dashboard" }
        if f.contains("daily") || f.contains("morning") { return "Daily check" }
        if f.isEmpty { return "Other" }
        return "Reconcile report"
    }

    private static func str(_ v: CmsJSON?) -> String {
        guard let v, v != .null else { return "" }
        return v.displayString.trimmingCharacters(in: .whitespaces)
    }

    private static func num(_ v: CmsJSON?) -> Double {
        let s = str(v)
        return s.isEmpty ? 0 : (Double(s) ?? 0)
    }

    /// Dates without a zone are UTC (D1).
    static func date(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        let zoned = s.range(of: #"[zZ]|[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil
        let text = zoned ? s : s.replacingOccurrences(of: " ", with: "T") + "Z"
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withFullDate]
        return iso.date(from: String(s.prefix(10)))
    }

    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    static func summarise(_ rows: [[String: CmsJSON]], shifts: ShiftTotals?, now: Date = Date()) -> Impact {
        var out = Impact()
        var kinds: [String: Bar] = [:], found: [String: Bar] = [:]
        var kindOrder: [String] = [], foundOrder: [String] = []
        let cal = Calendar.current
        var months: [Bar] = []
        for i in stride(from: 11, through: 0, by: -1) {
            let d = cal.date(byAdding: .month, value: -i, to: cal.date(from: cal.dateComponents([.year, .month], from: now))!)!
            let c = cal.dateComponents([.year, .month], from: d)
            months.append(Bar(label: d.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "en_GB"))),
                              key: String(format: "%04d-%02d", c.year!, c.month!)))
        }
        var days = 0.0, timed = 0
        func add(_ map: inout [String: Bar], _ order: inout [String], _ label: String, _ amount: Double, _ hours: Double) {
            if map[label] == nil { order.append(label); map[label] = Bar(label: label) }
            map[label]!.count += 1; map[label]!.amount += amount; map[label]!.hours += hours
        }
        for r in rows {
            guard !str(r["id"]).isEmpty else { continue }
            let kind = str(r["kind"]).isEmpty ? "other" : str(r["kind"])
            let amount = abs(num(r["amount"])), hrs = abs(num(r["hours"]))
            let foundAt = date(str(r["found_at"])), fixedAt = date(str(r["fixed_at"]))
            if str(r["direction"]) == "company" {
                out.company.count += 1; out.company.amount += amount; out.company.hours += hrs
            } else {
                out.worker.count += 1; out.worker.amount += amount; out.worker.hours += hrs
            }
            out.count += 1
            add(&kinds, &kindOrder, kindLabels[kind] ?? kindLabels["other"]!, amount, hrs)
            add(&found, &foundOrder, foundByLabel(str(r["found_by"])), amount, hrs)
            if str(r["fixed_how"]) == "grid" { out.fixedOnShifts += 1 }
            if let when = fixedAt ?? foundAt {
                let c = cal.dateComponents([.year, .month], from: when)
                let key = String(format: "%04d-%02d", c.year!, c.month!)
                if let i = months.firstIndex(where: { $0.key == key }) {
                    months[i].count += 1; months[i].amount += amount; months[i].hours += hrs
                }
                if out.since == nil || when < out.since! { out.since = when }
            }
            if let foundAt, let fixedAt, fixedAt >= foundAt {
                days += fixedAt.timeIntervalSince(foundAt) / 86_400
                timed += 1
            }
        }
        // A stable sort on insertion order, as JS's sort is stable.
        func sorted(_ map: [String: Bar], _ order: [String]) -> [Bar] {
            order.enumerated().map { ($0.offset, map[$0.element]!) }
                .sorted { a, b in
                    if a.1.amount != b.1.amount { return a.1.amount > b.1.amount }
                    if a.1.count != b.1.count { return a.1.count > b.1.count }
                    return a.0 < b.0
                }.map(\.1)
        }
        out.amount = round2(out.worker.amount + out.company.amount)
        out.hours = round2(out.worker.hours + out.company.hours)
        out.worker.amount = round2(out.worker.amount); out.worker.hours = round2(out.worker.hours)
        out.company.amount = round2(out.company.amount); out.company.hours = round2(out.company.hours)
        if timed > 0 { out.avgDaysToFix = days / Double(timed) }
        out.byKind = sorted(kinds, kindOrder)
        out.byFound = sorted(found, foundOrder)
        out.byMonth = months
        return out
    }

    static func shiftTotals(_ rows: [[String: CmsJSON]]) -> ShiftTotals? {
        guard !rows.isEmpty else { return nil }
        let firstDays = rows.map { str($0["first_day"]) }.filter { !$0.isEmpty }.sorted()
        return ShiftTotals(
            shifts: rows.reduce(0) { $0 + num($1["shifts"]) },
            hours: round2(rows.reduce(0) { $0 + num($1["hours"]) }),
            pay: round2(rows.reduce(0) { $0 + num($1["pay"]) }),
            people: max(0, rows.map { num($0["people"]) }.max() ?? 0),
            firstDay: firstDays.first ?? ""
        )
    }

    /// "5h 30m", or "45m".
    static func hoursLabel(_ h: Double) -> String {
        let mins = Int((h * 60).rounded())
        let hh = mins / 60, mm = mins % 60
        if hh == 0 { return "\(mm)m" }
        let hs = hh.formatted(.number.locale(Locale(identifier: "en_GB")))
        return mm > 0 ? "\(hs)h \(mm)m" : "\(hs)h"
    }
}
