import SwiftUI
import UniformTypeIdentifiers

/// Native twin of `rotaBuilder` (RotaBuilderBlock.tsx): plan a week or a
/// month, build it, change it by hand, publish it.
///
/// Semantics mirrored, through `CmsRotaBuilderModel` and `CmsRotaLogic`: the
/// plan (carried from the last one, saved as it changes, suggestions from
/// the last four weeks or ask wac), Build, Copy last, Publish (a spreadsheet
/// on Reconcile), one shift saved, moved or removed, the warnings and the
/// budget figures.
///
/// Presentation, for a phone: the web's grid of people by days becomes two
/// views of the same shifts. By day is a strip of the period's days over that
/// day's shifts, grouped by shift; By person is each person's hours against
/// their target, opening to their shifts. Dragging a shift becomes its
/// context menu (another day, another person). The plan's three steps are a
/// Form in a sheet; one shift is a Form in a sheet.
///
/// Not native yet: "Publish into the employee app" (coming soon on the web
/// too), and printing straight to a printer (Share gives a PDF instead).
struct CmsRotaBuilderBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @StateObject private var model = CmsRotaBuilderModel()
    @State private var view = "day"
    @State private var day = ""
    @State private var planOpen = false
    @State private var checksOpen = false

    private var t: CmsPortalTheme { runtime.theme }

    var body: some View {
        let m = model
        VStack(alignment: .leading, spacing: 12) {
            header(m)
            actions(m)
            banner(m)
            if m.account.isEmpty {
                card { Text("Choose a company to plan its rota.").font(.system(size: 14)).foregroundColor(t.textSecondary) }
            } else {
                planCard(m)
                figures(m)
                checks(m)
                Picker("View", selection: $view) {
                    Text("By day").tag("day")
                    Text("By person").tag("person")
                }
                .pickerStyle(.segmented)
                if view == "day" { byDay(m) } else { byPerson(m) }
            }
        }
        .tint(t.primary)
        .onAppear { model.attach(runtime: runtime, block: block) }
        .task(id: m.rangeKey) { await model.reload() }
        .onChange(of: m.period.start) { _ in day = "" }
        .ripulSheet(isPresented: $planOpen) {
            CmsRotaPlanSheet(model: model, theme: t) { planOpen = false }
        }
        .ripulSheet(item: $model.edit) { e in
            CmsRotaShiftEditor(model: model, theme: t, editing: e)
        }
        .alert(model.confirm?.title ?? "", isPresented: Binding(get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } }), presenting: model.confirm) { c in
            Button(c.confirm) { c.run() }
            Button("Cancel", role: .cancel) {}
        } message: { c in Text(c.text) }
    }

    // MARK: - Header

    private func header(_ m: CmsRotaBuilderModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.text("title", "Rota")).font(.system(size: 22, weight: .bold)).foregroundColor(t.textPrimary)
                Spacer()
                statusChip(m.status)
            }
            HStack(spacing: 6) {
                Button { m.anchor = Rota.movePeriod(m.period, by: -1).start } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                    .accessibilityLabel("Previous \(m.word)")
                Text(m.period.label).font(.system(size: 16, weight: .semibold)).foregroundColor(t.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                Button { m.anchor = Rota.movePeriod(m.period, by: 1).start } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                    .accessibilityLabel("Next \(m.word)")
                Button("Today") { m.anchor = Rota.iso(Date()) }.buttonStyle(.bordered).controlSize(.small)
            }
            HStack {
                Picker("Plan by", selection: Binding(get: { m.mode }, set: { m.setMode($0) })) {
                    Text("Week").tag("week")
                    Text("Month").tag("month")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                Spacer()
                if m.sites.count > 1 {
                    Menu {
                        Picker("Site", selection: Binding(get: { m.siteId }, set: { m.siteId = $0 })) {
                            Text("All sites").tag("")
                            ForEach(m.sites, id: \.id) { s in Text(s.name).tag(s.id) }
                        }
                    } label: {
                        Label(m.sites.first { $0.id == m.siteId }?.name ?? "All sites", systemImage: "mappin.and.ellipse").font(.system(size: 14))
                    }
                }
            }
        }
    }

    private func statusChip(_ status: String) -> some View {
        let (text, fg, bg): (String, Color, Color) = switch status {
        case "published": ("Published", t.success, t.successSoft)
        case "draft": ("Draft", t.warning, t.warningSoft)
        default: ("Not built", t.textSecondary, t.surfaceMuted)
        }
        return Text(text).font(.system(size: 12, weight: .bold)).foregroundColor(fg)
            .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(bg))
    }

    // MARK: - Actions

    private func actions(_ m: CmsRotaBuilderModel) -> some View {
        let busy = !m.busyText.isEmpty
        return HStack(spacing: 8) {
            Button { m.build() } label: {
                Label(m.status == "none" ? "Build this \(m.word)" : "Rebuild", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if m.status == "draft" {
                Button { m.publish() } label: { Label("Publish", systemImage: "paperplane").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            Menu {
                Button { m.copyLast() } label: { Label("Copy last \(m.word)", systemImage: "doc.on.doc") }
                Button { planOpen = true } label: { Label("Plan the \(m.word)", systemImage: "list.bullet.clipboard") }
                if !m.inPeriod.isEmpty {
                    ShareLink(item: CmsRotaExport(kind: .csv, title: exportTitle(m), csv: csv(m), rows: exportRows(m)),
                              preview: SharePreview(exportTitle(m))) { Label("Share as a spreadsheet", systemImage: "tablecells") }
                    ShareLink(item: CmsRotaExport(kind: .pdf, title: exportTitle(m), csv: "", rows: exportRows(m)),
                              preview: SharePreview(exportTitle(m))) { Label("Share as a PDF", systemImage: "doc.richtext") }
                }
                Button { m.notice = .init(tone: "info", text: "Publishing into the employee app is coming soon.") } label: {
                    Label("Publish into the employee app", systemImage: "iphone")
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 34)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("More")
        }
        .disabled(busy || m.account.isEmpty)
    }

    private func exportTitle(_ m: CmsRotaBuilderModel) -> String { "Rota \(m.period.label) \(m.period.start.prefix(4))" }
    private func csv(_ m: CmsRotaBuilderModel) -> String {
        Rota.csv(m.inPeriod, nameOf: m.nameOf, typeName: { m.typeOf($0)?.name ?? "" }, siteName: { id in m.sites.first { $0.id == id }?.name ?? "" })
    }
    private func exportRows(_ m: CmsRotaBuilderModel) -> [CmsRotaExport.Row] {
        m.inPeriod.map { s in
            .init(day: Rota.dayLabelShort(s.date), name: s.code.isEmpty ? "Open" : m.nameOf(s.code),
                  shift: m.typeOf(s.typeId)?.name ?? "", time: Rota.timeRange(s.start, s.end), hours: Rota.formatHours(s.hours))
        }
    }

    // MARK: - Banner

    @ViewBuilder
    private func banner(_ m: CmsRotaBuilderModel) -> some View {
        if !m.busyText.isEmpty {
            HStack(spacing: 8) { ProgressView(); Text(m.busyText).font(.system(size: 14)) }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(t.primarySoft))
        } else if let n = m.notice {
            let (fg, bg): (Color, Color) = switch n.tone {
            case "error": (t.error, t.errorSoft)
            case "warning": (t.warning, t.warningSoft)
            case "success": (t.success, t.successSoft)
            default: (t.info, t.primarySoft)
            }
            HStack(alignment: .top) {
                Text(n.text).font(.system(size: 14)).foregroundColor(t.textPrimary)
                Spacer()
                Button { m.notice = nil } label: { Image(systemName: "xmark").foregroundColor(fg) }.accessibilityLabel("Dismiss")
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(bg))
        } else if !m.error.isEmpty {
            HStack {
                Text(m.error).font(.system(size: 14)).foregroundColor(t.error)
                Spacer()
                Button("Try again") { Task { await m.reload() } }.controlSize(.small)
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(t.errorSoft))
        } else if let r = m.reading, r.key == m.planKey {
            HStack(spacing: 8) {
                ProgressView()
                Text("ask wac is reading \(r.name). Its suggestion shows in the plan when it's done.").font(.system(size: 14))
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(t.primarySoft))
        } else if m.status == "published", !m.lastPublished.at.isEmpty {
            let at = Impact.date(m.lastPublished.at).map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "en_GB"))) } ?? ""
            Text("Published \(at)\(m.lastPublished.by.isEmpty ? "" : " by \(m.lastPublished.by)").")
                .font(.system(size: 13)).foregroundColor(t.textSecondary)
        }
    }

    // MARK: - The plan

    private func planCard(_ m: CmsRotaBuilderModel) -> some View {
        let p = m.plan
        return Button { planOpen = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Plan for \(m.period.label)", systemImage: "list.bullet.clipboard").font(.system(size: 15, weight: .semibold))
                        .foregroundColor(t.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(t.textSecondary)
                }
                if p.shifts.isEmpty {
                    Text("Say what's on and the shifts you need, or just Build: it starts from what was worked.")
                        .font(.system(size: 13.5)).foregroundColor(t.textSecondary).multilineTextAlignment(.leading)
                } else {
                    HStack {
                        Spacer()
                        Text(Rota.weekdays.map { String(Rota.weekdayLabel[$0]!.prefix(1)) }.joined(separator: " "))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(t.textSecondary)
                    }
                    ForEach(p.shifts) { s in
                        HStack(spacing: 8) {
                            Circle().fill(tone(Rota.shiftKind(s.start, s.end, name: s.name))).frame(width: 8, height: 8)
                            Text(s.name.isEmpty ? Rota.timeRange(s.start, s.end) : s.name).font(.system(size: 14, weight: .medium)).foregroundColor(t.textPrimary)
                            Text(Rota.timeRange(s.start, s.end, compact: true)).font(.system(size: 13)).foregroundColor(t.textSecondary)
                            Spacer()
                            Text(Rota.weekdays.map { String(s.people[$0] ?? 0) }.joined(separator: " "))
                                .font(.system(size: 12.5, design: .monospaced)).foregroundColor(t.textSecondary)
                        }
                    }
                    if !p.special.isEmpty {
                        Text(p.special.map { "\(Rota.dayLabelShort($0.date)): \($0.label)" }.joined(separator: " · "))
                            .font(.system(size: 13)).foregroundColor(t.primary).multilineTextAlignment(.leading)
                    }
                }
                if let s = p.suggestion, !s.cells.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundColor(t.primary)
                        Text("Suggested from \(s.from.joined(separator: " and "))\(s.note.isEmpty ? "" : ": \(s.note)")").font(.system(size: 13))
                            .foregroundColor(t.textPrimary).multilineTextAlignment(.leading)
                    }
                }
                let origin = m.planOrigin
                if !origin.isEmpty { Text(origin).font(.system(size: 12.5)).foregroundColor(t.textSecondary).multilineTextAlignment(.leading) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.paper))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.divider))
    }

    // MARK: - Figures

    private func figures(_ m: CmsRotaBuilderModel) -> some View {
        let s = m.summary, b = m.budget
        let tiles: [(String, String, String, Bool)] = [
            ("Hours planned", Rota.formatHours(s.hours), b.hours.map { "of \(Rota.formatHours($0)) budget" } ?? "", (b.hours.map { s.hours > $0 + 0.01 }) ?? false),
            ("Staff cost", Rota.formatMoney(s.cost), b.gbp.map { "of \(Rota.formatMoney($0)) budget" } ?? "", (b.gbp.map { s.cost > $0 + 0.01 }) ?? false),
            ("Shifts filled", "\(s.shifts - s.open) of \(s.shifts)", s.open > 0 ? "\(s.open) open" : "", s.open > 0),
            ("Preferences met", s.prefsMet.map { "\($0)%" } ?? "–", "\(s.people) \(s.people == 1 ? "person" : "people")", false),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(tiles, id: \.0) { tile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.0).font(.system(size: 12, weight: .medium)).foregroundColor(t.textSecondary)
                    Text(tile.1).font(.system(size: 20, weight: .bold)).foregroundColor(tile.3 ? t.warning : t.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
                    Text(tile.2.isEmpty ? " " : tile.2).font(.system(size: 12)).foregroundColor(tile.3 ? t.warning : t.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.surfaceMuted))
            }
        }
    }

    // MARK: - Things to check

    @ViewBuilder
    private func checks(_ m: CmsRotaBuilderModel) -> some View {
        let w = m.warnings
        if !w.isEmpty {
            let errors = w.filter { $0.severity == "error" }.count
            DisclosureGroup(isExpanded: $checksOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(w) { x in
                        Button {
                            if let id = x.shiftId, let s = m.shifts.first(where: { $0.id == id }) { m.edit = .init(shift: s, code: s.code, date: s.date) }
                            else if let d = x.date { view = "day"; day = d }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: x.severity == "error" ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(x.severity == "error" ? t.error : t.warning)
                                Text(x.text).font(.system(size: 13.5)).foregroundColor(t.textPrimary).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("\(w.count) thing\(w.count == 1 ? "" : "s") to check\(errors > 0 ? " · \(errors) break\(errors == 1 ? "s" : "") a rule" : "")",
                      systemImage: errors > 0 ? "exclamationmark.octagon" : "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(errors > 0 ? t.error : t.warning)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(errors > 0 ? t.errorSoft : t.warningSoft))
        }
    }

    // MARK: - By day

    private func byDay(_ m: CmsRotaBuilderModel) -> some View {
        let dates = Rota.datesBetween(m.period.start, m.period.end)
        let today = Rota.iso(Date())
        let sel = dates.contains(day) ? day : (dates.contains(today) ? today : dates.first ?? "")
        let all = m.inPeriod
        let busy = m.inputs.busy
        return VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(dates, id: \.self) { d in
                            let n = all.filter { $0.date == d }
                            let open = n.filter { $0.code.isEmpty }.count
                            let special = busy.contains { d >= $0.from && d <= $0.to && !$0.label.isEmpty }
                            Button { day = d } label: {
                                VStack(spacing: 2) {
                                    Text(String(Rota.weekdayLabel[Rota.weekdayOf(d)]!.prefix(3))).font(.system(size: 11, weight: .semibold))
                                    Text(String(Int(d.suffix(2)) ?? 0)).font(.system(size: 17, weight: .bold))
                                    HStack(spacing: 3) {
                                        Circle().fill(n.isEmpty ? Color.clear : (open > 0 ? t.warning : t.success)).frame(width: 5, height: 5)
                                        if special { Image(systemName: "star.fill").font(.system(size: 6)) }
                                    }
                                    .frame(height: 6)
                                }
                                .foregroundColor(d == sel ? t.primaryContrast : (d == today ? t.primary : t.textPrimary))
                                .frame(width: 46, height: 62)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(d == sel ? t.primary : t.surfaceMuted))
                            }
                            .buttonStyle(.plain)
                            .id(d)
                            .accessibilityLabel("\(Rota.dayLabelShort(d)), \(n.count) shift\(n.count == 1 ? "" : "s")")
                        }
                    }
                }
                .task(id: "\(m.period.start)|\(sel)") {
                    // After the strip has laid out, or the scroll lands short.
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation { proxy.scrollTo(sel, anchor: .center) }
                }
            }
            dayDetail(m, sel, all.filter { $0.date == sel })
        }
    }

    private func dayDetail(_ m: CmsRotaBuilderModel, _ date: String, _ list: [Rota.Shift]) -> some View {
        let labels = m.inputs.busy.filter { date >= $0.from && date <= $0.to && !$0.label.isEmpty }.map(\.label)
        let off = m.shown.filter { p in
            Rota.onDayOff(date, p.daysOff) || m.timeOff.contains { $0.code == p.code && $0.kind != "extra" && $0.status == "approved" && date >= $0.from && date <= $0.to }
        }
        var groups: [(key: String, name: String, shifts: [Rota.Shift])] = []
        for s in list {
            let key = s.typeId.isEmpty ? "own:\(s.start)-\(s.end)" : s.typeId
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].shifts.append(s) }
            else { groups.append((key, m.typeOf(s.typeId)?.name ?? Rota.timeRange(s.start, s.end), [s])) }
        }
        let hours = list.reduce(0.0) { $0 + $1.hours }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Rota.parse(date).formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "en_GB"))))
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(t.textPrimary)
                Spacer()
                if !list.isEmpty { Text("\(list.count) · \(Rota.formatHours(hours))").font(.system(size: 13)).foregroundColor(t.textSecondary) }
            }
            ForEach(labels, id: \.self) { l in
                Label(l, systemImage: "star.fill").font(.system(size: 13, weight: .medium)).foregroundColor(t.primary)
            }
            if list.isEmpty {
                card {
                    Text(m.loadedFor == m.rangeKey ? "No shifts on this day." : "Loading…").font(.system(size: 14)).foregroundColor(t.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(groups, id: \.key) { g in
                VStack(alignment: .leading, spacing: 0) {
                    let first = g.shifts[0]
                    HStack {
                        Circle().fill(tone(Rota.shiftKind(first.start, first.end, name: g.name))).frame(width: 9, height: 9)
                        Text(g.name).font(.system(size: 14, weight: .semibold)).foregroundColor(t.textPrimary)
                        Text(Rota.timeRange(first.start, first.end)).font(.system(size: 13)).foregroundColor(t.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    ForEach(g.shifts) { s in
                        Divider().padding(.leading, 12)
                        shiftRow(m, s, showDate: false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.paper))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.divider))
            }
            Button { m.edit = .init(shift: nil, code: "", date: date) } label: { Label("Add a shift", systemImage: "plus") }
                .buttonStyle(.bordered)
            if !off.isEmpty {
                Text("Off: " + off.map(\.name).joined(separator: ", ")).font(.system(size: 13)).foregroundColor(t.textSecondary)
            }
        }
    }

    private func shiftRow(_ m: CmsRotaBuilderModel, _ s: Rota.Shift, showDate: Bool) -> some View {
        let warn = m.warnings.filter { $0.shiftId == s.id }
        let dates = Rota.datesBetween(m.period.start, m.period.end)
        return Button { m.edit = .init(shift: s, code: s.code, date: s.date) } label: {
            HStack(spacing: 10) {
                if s.code.isEmpty {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 22)).foregroundColor(t.warning).frame(width: 30)
                } else {
                    CmsInitialsAvatar(name: m.nameOf(s.code), size: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.code.isEmpty ? "Open shift" : m.nameOf(s.code)).font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(s.code.isEmpty ? t.warning : t.textPrimary)
                    Text([showDate ? Rota.dayLabelShort(s.date) : "", showDate ? (m.typeOf(s.typeId)?.name ?? "") : "",
                          Rota.timeRange(s.start, s.end), s.note].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundColor(t.textSecondary).lineLimit(1)
                }
                Spacer()
                if let w = warn.first {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(w.severity == "error" ? t.error : t.warning)
                        .accessibilityLabel(w.text)
                }
                Text(Rota.formatHours(s.hours)).font(.system(size: 13, weight: .medium)).foregroundColor(t.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Move to another day") {
                ForEach(dates.filter { $0 != s.date }, id: \.self) { d in Button(Rota.dayLabelShort(d)) { m.move(s, date: d) } }
            }
            Menu("Give to") {
                if !s.code.isEmpty { Button("No one (open shift)") { m.move(s, code: "") } }
                ForEach(m.shown.filter { $0.code != s.code }) { p in
                    let reason = m.blockedReason(p, for: s)
                    Button(reason.map { "\(p.name) — \($0)" } ?? p.name) { m.move(s, code: p.code) }
                }
            }
            Button(role: .destructive) { m.removeShift(s) } label: { Label("Remove", systemImage: "trash") }
        }
    }

    // MARK: - By person

    private func byPerson(_ m: CmsRotaBuilderModel) -> some View {
        let all = m.inPeriod
        let open = all.filter { $0.code.isEmpty }
        return VStack(spacing: 8) {
            if !open.isEmpty {
                personCard(m, name: "Open shifts", code: "", shifts: open, target: nil)
            }
            ForEach(m.shown) { p in
                let target = m.mode == "week" ? p.prefs.targetWeek : (p.prefs.targetMonth ?? p.prefs.targetWeek.map { $0 * 52 / 12 })
                personCard(m, name: p.name, code: p.code, shifts: all.filter { $0.code == p.code }, target: target)
            }
            if m.shown.isEmpty {
                card { Text("No one on the team yet. Add them on Employees.").font(.system(size: 14)).foregroundColor(t.textSecondary) }
            }
        }
    }

    private func personCard(_ m: CmsRotaBuilderModel, name: String, code: String, shifts: [Rota.Shift], target: Double?) -> some View {
        let hours = shifts.reduce(0.0) { $0 + $1.hours }
        let over = target.map { hours > $0 + 0.01 } ?? false
        return DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(shifts) { s in
                    shiftRow(m, s, showDate: true)
                    Divider().padding(.leading, 12)
                }
                if !code.isEmpty {
                    Button { m.edit = .init(shift: nil, code: code, date: m.period.start) } label: { Label("Add a shift", systemImage: "plus") }
                        .padding(.vertical, 8)
                }
            }
        } label: {
            HStack(spacing: 10) {
                if code.isEmpty {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 26)).foregroundColor(t.warning)
                } else {
                    CmsInitialsAvatar(name: name, size: 34)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(name).font(.system(size: 15, weight: .semibold)).foregroundColor(t.textPrimary)
                        Spacer()
                        Text("\(Rota.formatHours(hours))\(target.map { " of \(Rota.formatHours($0))" } ?? "")")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(over ? t.warning : t.textSecondary)
                    }
                    if let target, target > 0 {
                        ProgressView(value: min(hours, target), total: target).tint(over ? t.warning : t.primary)
                    } else {
                        Text("\(shifts.count) shift\(shifts.count == 1 ? "" : "s")").font(.system(size: 12.5)).foregroundColor(t.textSecondary)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.paper))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.divider))
    }

    // MARK: - Bits

    private func tone(_ kind: String) -> Color {
        switch kind {
        case "early": return t.info
        case "late": return t.warning
        case "night": return t.secondary
        default: return t.primary
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.paper))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.divider))
    }
}

extension CmsRotaBuilderModel {
    /// Why this person can't work this shift (the web's greyed-out drop target).
    func blockedReason(_ p: Rota.Person, for s: Rota.Shift) -> String? {
        let others = shifts.filter { $0.code == p.code && $0.id != s.id }
        let origin = Rota.addDays(period.start, -7)
        return Rota.blocked(p, date: s.date, start: s.start, end: s.end, hours: Rota.paidHours(s.start, s.end, s.breakMinutes),
                            siteId: s.siteId, load: Rota.loadFrom(others, origin: origin), timeOff: timeOff, origin: origin)
    }
}

// MARK: - Share

/// The period's rota as a spreadsheet or a PDF, made when shared.
struct CmsRotaExport: Transferable {
    enum Kind { case csv, pdf }
    struct Row { var day, name, shift, time, hours: String }
    var kind: Kind
    var title: String
    var csv: String
    var rows: [Row]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { item in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.title).csv")
            try Data(item.csv.utf8).write(to: url)
            return SentTransferredFile(url)
        }
        .exportingCondition { $0.kind == .csv }
        FileRepresentation(exportedContentType: .pdf) { item in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.title).pdf")
            try await MainActor.run { try item.writePDF(url) }
            return SentTransferredFile(url)
        }
        .exportingCondition { $0.kind == .pdf }
    }

    @MainActor
    func writePDF(_ url: URL) throws {
        let page = VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 18, weight: .bold)).padding(.bottom, 12)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 8) {
                    Text(r.day).frame(width: 110, alignment: .leading)
                    Text(r.name).frame(width: 150, alignment: .leading)
                    Text(r.shift).frame(width: 90, alignment: .leading)
                    Text(r.time).frame(width: 100, alignment: .leading)
                    Text(r.hours).frame(width: 50, alignment: .trailing)
                }
                .font(.system(size: 10))
                .padding(.vertical, 3)
                Divider()
            }
        }
        .padding(36)
        .frame(width: 595, alignment: .leading)
        .foregroundColor(.black) // theme-exempt: printed page
        .background(Color.white) // theme-exempt: printed page
        let renderer = ImageRenderer(content: page)
        var failed = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { failed = true; return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        if failed { throw CocoaError(.fileWriteUnknown) }
    }
}
