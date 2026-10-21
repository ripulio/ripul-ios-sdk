import SwiftUI

/// Native twin of `rotaTeam` (RotaTeamBlock.tsx + rotaPreferences.ts): the
/// selected company's active employees and their rota preferences, each
/// opening an editor of the three layers — hours and limits, the weekly
/// pattern, and time off.
///
/// Semantics mirrored: `personFromRow`, `availabilityByPerson` (a day with no
/// row is available), `timeOffFromRow`, `upcomingTimeOff`, `timeOffInWeek`,
/// `summaryChips`, `suggestedTarget` (offered, never filled in by itself),
/// the figures and filters, and `writePreferences` (the preferences row, then
/// only the days of the week that changed); time off added, decided and
/// removed through its mutations.
///
/// Presentation: a brand band of figures, a search field and a segmented
/// filter over person cards; the editor is a native Form in a sheet.
///
/// Not native yet: the days-off and works-well-with pickers (plain text
/// here, in the stored format), and the embedded single-person mode used in
/// an employee's own form.
struct CmsRotaTeamBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var query = ""
    @State private var filter = "all"
    @State private var open: Person?

    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    static let weekdayLabel = ["mon": "Monday", "tue": "Tuesday", "wed": "Wednesday", "thu": "Thursday", "fri": "Friday", "sat": "Saturday", "sun": "Sunday"]
    static let kinds = ["available", "between", "prefer_not", "unavailable"]
    static let kindLabel = ["available": "Available", "between": "Between", "prefer_not": "Prefers not", "unavailable": "Unavailable"]

    struct Day: Equatable { var kind = "available"; var from = ""; var to = "" }

    struct Person: Identifiable, Equatable {
        var id: String { code }
        var code: String
        var name: String
        var jobTitle: String
        var headshot: String
        var jobType: String
        var prefs: [String: CmsJSON]
        var isSet: Bool
    }

    struct TimeOff: Identifiable, Equatable {
        var id: String
        var code: String
        var name: String
        var from: String
        var to: String
        var part: String
        var fromTime: String = ""
        var toTime: String = ""
        var kind: String
        var status: String
        var note: String
    }

    private var props: [String: CmsJSON] { block.props }
    private func text(_ key: String) -> String { props.string(key) ?? "" }
    private var account: String {
        let v = runtime.resolveTemplate(text("account")).trimmingCharacters(in: .whitespaces)
        return v.contains("@") ? "" : v
    }
    private func rows(_ key: String) -> [[String: CmsJSON]]? {
        let slug = text(key)
        guard !slug.isEmpty, case .ok(let r) = runtime.state(for: slug) else { return nil }
        return r.rows
    }

    private static func str(_ v: CmsJSON?) -> String {
        guard let v, v != .null else { return "" }
        return v.displayString.trimmingCharacters(in: .whitespaces)
    }

    static func person(_ r: [String: CmsJSON]) -> Person? {
        let code = str(r["employee_code"])
        guard !code.isEmpty else { return nil }
        return Person(code: code, name: str(r["name"]).isEmpty ? code : str(r["name"]), jobTitle: str(r["job_title"]),
                      headshot: str(r["headshot"]), jobType: str(r["job_type_code"]), prefs: r, isSet: !str(r["pref_code"]).isEmpty)
    }

    static func weeks(_ rows: [[String: CmsJSON]]) -> [String: [String: Day]] {
        var out: [String: [String: Day]] = [:]
        for r in rows {
            let code = str(r["employee_code"]), day = str(r["weekday"]), kind = str(r["kind"])
            guard !code.isEmpty, weekdays.contains(day), kinds.contains(kind) else { continue }
            var week = out[code] ?? blankWeek()
            week[day] = Day(kind: kind, from: str(r["from_time"]), to: str(r["to_time"]))
            out[code] = week
        }
        return out
    }

    static func blankWeek() -> [String: Day] { Dictionary(uniqueKeysWithValues: weekdays.map { ($0, Day()) }) }

    static func timeOff(_ r: [String: CmsJSON]) -> TimeOff? {
        let id = str(r["id"]), from = String(str(r["start_date"]).prefix(10))
        guard !id.isEmpty, !from.isEmpty else { return nil }
        let to = String(str(r["end_date"]).prefix(10))
        return TimeOff(id: id, code: str(r["employee_code"]), name: str(r["name"]), from: from, to: to.isEmpty ? from : to,
                       part: str(r["part"]).isEmpty ? "all_day" : str(r["part"]),
                       fromTime: str(r["from_time"]), toTime: str(r["to_time"]), kind: str(r["kind"]).isEmpty ? "holiday" : str(r["kind"]),
                       status: str(r["status"]).isEmpty ? "requested" : str(r["status"]), note: str(r["note"]))
    }

    static func rangeLabel(_ from: String, _ to: String) -> String {
        if from == to {
            return CmsFileWeeks.parse(from).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
        }
        return CmsFileWeeks.rangeLabel(CmsFileWeeks.parse(from), CmsFileWeeks.parse(to), now: CmsFileWeeks.parse(to))
    }

    /// `summaryChips`.
    static func chips(_ p: Person, week: [String: Day]?) -> [String] {
        var out: [String] = []
        func n(_ k: String) -> String? { let s = str(p.prefs[k]); return s.isEmpty ? nil : s }
        if let t = n("target_week_hours") { out.append("\(t)h a week") }
        else if n("min_week_hours") != nil || n("max_week_hours") != nil { out.append("\(n("min_week_hours") ?? "0")–\(n("max_week_hours") ?? "…")h a week") }
        if let d = n("max_days_week") { out.append("up to \(d) days") }
        if let week {
            let off = weekdays.filter { week[$0]?.kind == "unavailable" }
            if !off.isEmpty && off.count < 7 { out.append("no " + off.map { String(weekdayLabel[$0]!.prefix(3)) }.joined(separator: ", ")) }
        }
        if let s = n("preferred_shift"), s != "any" { out.append("prefers \(s)s") }
        let today = CmsFileWeeks.iso(Date())
        let offs = (n("days_off") ?? "").split(whereSeparator: { $0 == ";" || $0 == "\n" }).filter { part in
            let days = String(part).matches(of: #/\d{4}-\d{2}-\d{2}/#).map { String($0.output) }
            guard let first = days.first else { return false }
            return (days.last ?? first) >= today
        }.count
        if offs > 0 { out.append("\(offs) day\(offs == 1 ? "" : "s") off booked") }
        if ["1", "true", "Y"].contains(str(p.prefs["under_18"])) { out.append("under 18") }
        return out
    }

    var body: some View {
        let people = (rows("teamQuerySlug") ?? []).compactMap(Self.person)
        let weeks = Self.weeks(rows("availabilityQuerySlug") ?? [])
        let offs = (rows("timeOffQuerySlug") ?? []).compactMap(Self.timeOff)
        let monday = CmsFileWeeks.iso(CmsFileWeeks.mondayOf(Date()))
        let sunday = CmsFileWeeks.iso(CmsFileWeeks.addDays(CmsFileWeeks.mondayOf(Date()), 6))
        let offCodes = Set(offs.filter { $0.kind != "extra" && $0.status != "declined" && $0.from <= sunday && $0.to >= monday }.map(\.code))
        let today = CmsFileWeeks.iso(Date())
        let requested = offs.filter { $0.status == "requested" && $0.to >= today }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = people.filter { p in
            if filter == "unset" && p.isSet { return false }
            if filter == "off" && !offCodes.contains(p.code) { return false }
            return q.isEmpty || [p.name, p.jobTitle, Self.str(p.prefs["skills"])].joined(separator: " ").lowercased().contains(q)
        }
        let onBrand = runtime.theme.primaryContrast

        VStack(alignment: .leading, spacing: 14) {
            if !text("heading").isEmpty { Text(text("heading")).font(.system(size: 22, weight: .heavy)) }
            if !text("intro").isEmpty { Text(text("intro")).font(.system(size: 14)).foregroundColor(runtime.theme.textSecondary) }
            HStack {
                ForEach([("\(people.count)", "active"), ("\(people.filter(\.isSet).count)", "preferences set"),
                         ("\(offCodes.count)", "off this week"), ("\(requested.count)", "requests to decide")], id: \.1) { f in
                    VStack(spacing: 1) {
                        Text(f.0).font(.system(size: 20, weight: .heavy))
                        Text(f.1.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.5).multilineTextAlignment(.center).opacity(0.85)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .foregroundColor(onBrand)
            .padding(.vertical, 14)
            .background(runtime.theme.gradient, in: RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous))

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(runtime.theme.textSecondary)
                TextField("Search the team", text: $query).textFieldStyle(.plain)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(runtime.theme.surfaceMuted))
            Picker("", selection: $filter) {
                Text("Everyone").tag("all")
                Text("Not set").tag("unset")
                Text("Off this week").tag("off")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if rows("teamQuerySlug") == nil {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            } else if shown.isEmpty {
                Text("No one here.").font(.system(size: 14)).foregroundColor(runtime.theme.textSecondary)
            }
            ForEach(shown) { p in
                Button { open = p } label: { card(p, week: weeks[p.code], off: offCodes.contains(p.code)) }
                    .buttonStyle(.plain)
            }
        }
        .onAppear {
            for key in ["teamQuerySlug", "availabilityQuerySlug", "timeOffQuerySlug", "settingsQuerySlug"] { runtime.ensureLoaded(text(key)) }
        }
        .ripulSheet(item: $open) { p in
            CmsRotaPersonEditor(person: p, week: weeks[p.code] ?? Self.blankWeek(),
                                timeOff: offs.filter { $0.code == p.code && $0.to >= today && $0.status != "declined" }.sorted { $0.from < $1.from },
                                settings: rows("settingsQuerySlug")?.first, props: props, account: account) {
                for key in ["teamQuerySlug", "availabilityQuerySlug", "timeOffQuerySlug"] { runtime.invalidate(text(key)) }
            }
            .environmentObject(runtime)
        }
    }

    private func card(_ p: Person, week: [String: Day]?, off: Bool) -> some View {
        let chips = Self.chips(p, week: week)
        return HStack(alignment: .top, spacing: 12) {
            CmsInitialsAvatar(name: p.name, headshot: p.headshot, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(p.name).font(.system(size: 15.5, weight: .bold))
                    if off {
                        Text("Off this week").font(.system(size: 11, weight: .bold)).foregroundColor(runtime.theme.warning)
                            .padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(runtime.theme.warning.opacity(0.14)))
                    }
                }
                if !p.jobTitle.isEmpty { Text(p.jobTitle).font(.system(size: 13)).foregroundColor(runtime.theme.textSecondary) }
                if chips.isEmpty {
                    Text(p.isSet ? "Preferences set" : "No preferences yet").font(.system(size: 12.5)).foregroundColor(runtime.theme.textSecondary)
                } else {
                    Text(chips.joined(separator: " · ")).font(.system(size: 12.5)).foregroundColor(runtime.theme.primary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary).padding(.top, 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(runtime.theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(runtime.theme.divider))
        .contentShape(Rectangle())
        .cmsInspectorID("Cms.rotaTeam.person")
    }
}

/// One person's preferences, as a native Form: hours and limits, shifts, the
/// usual week, and time off.
private struct CmsRotaPersonEditor: View {
    let person: CmsRotaTeamBlockView.Person
    let initialWeek: [String: CmsRotaTeamBlockView.Day]
    let timeOff: [CmsRotaTeamBlockView.TimeOff]
    let settings: [String: CmsJSON]?
    let props: [String: CmsJSON]
    let account: String
    let onSaved: () -> Void
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.dismiss) private var dismiss

    @State private var form: [String: String]
    @State private var optOut48: Bool
    @State private var under18: Bool
    @State private var week: [String: CmsRotaTeamBlockView.Day]
    @State private var saving = false
    @State private var error = ""
    @State private var offFrom = Date()
    @State private var offTo = Date()
    @State private var offKind = "holiday"
    @State private var offPart = "all_day"
    @State private var offStatus = "approved"
    @State private var offNote = ""

    private static let numberKeys = ["target_week_hours", "min_week_hours", "max_week_hours", "target_month_hours",
                                     "max_days_week", "max_shift_hours", "min_shift_hours", "min_rest_hours", "min_notice_days"]
    private static let textKeys = ["skills", "preferred_shift", "shift_length", "days_off", "works_with", "note"]

    init(person: CmsRotaTeamBlockView.Person, week: [String: CmsRotaTeamBlockView.Day], timeOff: [CmsRotaTeamBlockView.TimeOff],
         settings: [String: CmsJSON]?, props: [String: CmsJSON], account: String, onSaved: @escaping () -> Void) {
        self.person = person
        self.initialWeek = week
        self.timeOff = timeOff
        self.settings = settings
        self.props = props
        self.account = account
        self.onSaved = onSaved
        var f: [String: String] = [:]
        for k in Self.numberKeys + Self.textKeys {
            let v = person.prefs[k]
            f[k] = v == nil || v == .null ? "" : v!.displayString
        }
        if (f["preferred_shift"] ?? "").isEmpty { f["preferred_shift"] = "any" }
        if (f["shift_length"] ?? "").isEmpty { f["shift_length"] = "any" }
        _form = State(initialValue: f)
        let truthy: (CmsJSON?) -> Bool = { ["1", "true", "Y"].contains($0?.displayString ?? "") }
        _optOut48 = State(initialValue: truthy(person.prefs["opt_out_48h"]))
        _under18 = State(initialValue: truthy(person.prefs["under_18"]))
        _week = State(initialValue: week)
    }

    private var email: String { runtime.client.userEmail ?? runtime.membership?.email ?? "" }
    private func slug(_ key: String) -> String { props.string(key) ?? "" }
    private func typed(_ v: String?, _ type: String = "string") -> CmsJSON {
        .object(["value": v.flatMap { $0.isEmpty ? nil : CmsJSON.string($0) } ?? .null, "type": .string(type)])
    }
    private func number(_ key: String, integer: Bool = false) -> CmsJSON {
        let raw = (form[key] ?? "").trimmingCharacters(in: .whitespaces)
        guard let n = Double(raw) else { return typed(nil, integer ? "integer" : "float") }
        return typed(integer ? String(Int(n.rounded())) : String(n), integer ? "integer" : "float")
    }

    /// `suggestedTarget`: the work type's suggestion, from the company's own table when it has one.
    private var suggestion: (label: String, target: Double?, min: Double?, max: Double?, days: Double?)? {
        let defaults: [String: (String, Double?, Double?, Double?, Double?)] = [
            "full_time": ("Full time", 37.5, 35, 40, 5), "part_time": ("Part time", 20, 16, 30, 4),
            "zero_hour": ("Zero hours", nil, 0, 40, 6), "freelance": ("Freelance", nil, nil, nil, nil), "self_employed": ("Self employed", nil, nil, nil, nil),
        ]
        var own: [String: CmsJSON]?
        if let raw = settings?["default_targets"] {
            if case .string(let s) = raw, let data = s.data(using: .utf8) { own = (try? JSONDecoder().decode(CmsJSON.self, from: data))?.objectValue?.object(person.jobType) }
            else { own = raw.objectValue?.object(person.jobType) }
        }
        guard let base = defaults[person.jobType] ?? own.map({ _ in (person.jobType, nil, nil, nil, nil) }) else { return nil }
        return (own?.string("label") ?? base.0, own?.double("target") ?? base.1, own?.double("min") ?? base.2,
                own?.double("max") ?? base.3, own?.double("days") ?? base.4)
    }

    private func field(_ key: String, _ label: String, unit: String = "h") -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: Binding(get: { form[key] ?? "" }, set: { form[key] = $0 }))
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .frame(width: 70)
            Text(unit).foregroundColor(runtime.theme.textSecondary)
        }
    }

    private func time(_ value: String) -> Date {
        let p = value.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }
    private func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("target_week_hours", "Target a week")
                    field("min_week_hours", "At least a week")
                    field("max_week_hours", "At most a week")
                    field("target_month_hours", "Target a month")
                    field("max_days_week", "Most days a week", unit: "days")
                    field("max_shift_hours", "Longest shift")
                    field("min_shift_hours", "Shortest shift")
                    field("min_rest_hours", "Rest between shifts")
                    Toggle("Opted out of the 48-hour week", isOn: $optOut48)
                    Toggle("Under 18", isOn: $under18)
                } header: {
                    Text("Hours and limits")
                } footer: {
                    if let s = suggestion, s.target != nil || s.min != nil {
                        Button("Use the \(s.label.lowercased()) suggestion") {
                            if let t = s.target { form["target_week_hours"] = String(format: "%g", t) }
                            if let m = s.min { form["min_week_hours"] = String(format: "%g", m) }
                            if let m = s.max { form["max_week_hours"] = String(format: "%g", m) }
                            if let d = s.days { form["max_days_week"] = String(format: "%g", d) }
                        }
                    }
                }
                Section("Shifts") {
                    Picker("Preferred shift", selection: Binding(get: { form["preferred_shift"] ?? "any" }, set: { form["preferred_shift"] = $0 })) {
                        ForEach([("any", "Any"), ("early", "Early"), ("middle", "Middle"), ("late", "Late"), ("night", "Night")], id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Shift length", selection: Binding(get: { form["shift_length"] ?? "any" }, set: { form["shift_length"] = $0 })) {
                        ForEach([("any", "No preference"), ("longer", "Longer shifts, fewer days"), ("shorter", "Shorter shifts, more days")], id: \.0) { Text($0.1).tag($0.0) }
                    }
                    TextField("Skills", text: Binding(get: { form["skills"] ?? "" }, set: { form["skills"] = $0 }))
                    TextField("Days off (YYYY-MM-DD; …)", text: Binding(get: { form["days_off"] ?? "" }, set: { form["days_off"] = $0 }))
                    TextField("Works well with", text: Binding(get: { form["works_with"] ?? "" }, set: { form["works_with"] = $0 }))
                    field("min_notice_days", "Notice needed", unit: "days")
                    TextField("Note", text: Binding(get: { form["note"] ?? "" }, set: { form["note"] = $0 }), axis: .vertical)
                }
                Section("Usual week") {
                    ForEach(CmsRotaTeamBlockView.weekdays, id: \.self) { d in
                        let day = week[d] ?? CmsRotaTeamBlockView.Day()
                        Picker(CmsRotaTeamBlockView.weekdayLabel[d]!, selection: Binding(get: { day.kind }, set: { week[d]?.kind = $0; if $0 == "between", (week[d]?.from ?? "").isEmpty { week[d]?.from = "09:00"; week[d]?.to = "17:00" } })) {
                            ForEach(CmsRotaTeamBlockView.kinds, id: \.self) { Text(CmsRotaTeamBlockView.kindLabel[$0]!).tag($0) }
                        }
                        if day.kind == "between" {
                            HStack {
                                DatePicker("From", selection: Binding(get: { time(day.from) }, set: { week[d]?.from = hhmm($0) }), displayedComponents: .hourAndMinute)
                                DatePicker("To", selection: Binding(get: { time(day.to) }, set: { week[d]?.to = hhmm($0) }), displayedComponents: .hourAndMinute)
                            }
                            .labelsHidden()
                        }
                    }
                }
                Section("Time off") {
                    ForEach(timeOff) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(CmsRotaTeamBlockView.rangeLabel(t.from, t.to)) · \(kindLabel(t.kind))").font(.system(size: 15, weight: .semibold))
                            Text([t.status.capitalized, t.part == "all_day" ? "" : (t.part == "am" ? "Morning" : "Afternoon"), t.note].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 13)).foregroundColor(runtime.theme.textSecondary)
                            if t.status == "requested" {
                                HStack {
                                    Button("Approve") { Task { await decide(t, "approved") } }.buttonStyle(.borderedProminent)
                                    Button("Decline") { Task { await decide(t, "declined") } }.buttonStyle(.bordered)
                                }
                                .controlSize(.small)
                            }
                        }
                        .swipeActions { Button("Remove", role: .destructive) { Task { await removeOff(t) } } }
                    }
                    DatePicker("First day off", selection: $offFrom, displayedComponents: .date)
                    DatePicker("Last day", selection: $offTo, in: offFrom..., displayedComponents: .date)
                    Picker("Kind", selection: $offKind) {
                        ForEach(["holiday", "sick", "unpaid", "training", "unavailable", "extra", "other"], id: \.self) { Text(kindLabel($0)).tag($0) }
                    }
                    Picker("Part", selection: $offPart) {
                        Text("All day").tag("all_day"); Text("Morning").tag("am"); Text("Afternoon").tag("pm")
                    }
                    Picker("Status", selection: $offStatus) { Text("Approved").tag("approved"); Text("Requested").tag("requested") }
                    TextField("Note", text: $offNote)
                    Button("Add time off") { Task { await addOff() } }
                }
                if !error.isEmpty { Section { Text(error).foregroundColor(runtime.theme.error) } }
            }
            .navigationTitle(person.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("Save").bold() } }
                        .disabled(saving || runtime.isDesignMode)
                }
            }
        }
        .tint(runtime.theme.primary)
    }

    private func kindLabel(_ k: String) -> String {
        ["holiday": "Holiday", "sick": "Sick", "unpaid": "Unpaid", "training": "Training", "unavailable": "Can't work",
         "extra": "Can work extra", "other": "Other"][k] ?? k.capitalized
    }

    private func run(_ key: String, _ params: [String: CmsJSON]) async throws {
        let s = slug(key)
        guard !s.isEmpty else { throw CmsClientError.queryFailed("Not set up to save.") }
        if case .failed(let message) = await runtime.runMutation(s, params: params) { throw CmsClientError.queryFailed(message) }
    }

    /// `writePreferences`: the preferences row, then only the days that changed.
    private func save() async {
        guard !account.isEmpty else { error = "Choose a company first."; return }
        saving = true
        error = ""
        do {
            try await run("prefsMutationSlug", [
                "employee_code": typed(person.code), "company_id": typed(account), "site_id": typed(nil),
                "target_week_hours": number("target_week_hours"), "min_week_hours": number("min_week_hours"), "max_week_hours": number("max_week_hours"),
                "target_month_hours": number("target_month_hours"), "max_days_week": number("max_days_week", integer: true),
                "max_shift_hours": number("max_shift_hours"), "min_shift_hours": number("min_shift_hours"), "min_rest_hours": number("min_rest_hours"),
                "opt_out_48h": typed(optOut48 ? "1" : "0", "integer"), "under_18": typed(under18 ? "1" : "0", "integer"),
                "skills": typed(form["skills"]), "preferred_shift": typed(form["preferred_shift"]), "shift_length": typed(form["shift_length"]),
                "days_off": typed(form["days_off"]), "min_notice_days": number("min_notice_days", integer: true),
                "works_with": typed(form["works_with"]), "note": typed(form["note"]), "source": typed("manual"), "updated_by": typed(email),
            ])
            for d in CmsRotaTeamBlockView.weekdays where week[d] != initialWeek[d] {
                let a = week[d] ?? CmsRotaTeamBlockView.Day()
                try await run("availabilityMutationSlug", [
                    "employee_code": typed(person.code), "company_id": typed(account), "weekday": typed(d), "kind": typed(a.kind),
                    "from_time": typed(a.kind == "between" ? a.from : ""), "to_time": typed(a.kind == "between" ? a.to : ""), "source": typed("manual"),
                ])
            }
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }

    private func addOff() async {
        do {
            try await run("timeOffAddMutationSlug", [
                "id": typed("off_\(Int(Date().timeIntervalSince1970 * 1000).description)\(Int.random(in: 1000...9999))"),
                "company_id": typed(account), "employee_code": typed(person.code),
                "start_date": typed(CmsFileWeeks.iso(offFrom), "date"), "end_date": typed(CmsFileWeeks.iso(max(offTo, offFrom)), "date"),
                "part": typed(offPart), "from_time": typed(""), "to_time": typed(""), "kind": typed(offKind), "status": typed(offStatus),
                "note": typed(offNote), "requested_by": typed(email),
            ])
            offNote = ""
            onSaved()
        } catch {
            self.error = "Could not add the time off."
        }
    }

    private func decide(_ t: CmsRotaTeamBlockView.TimeOff, _ status: String) async {
        do { try await run("timeOffStatusMutationSlug", ["id": typed(t.id), "status": typed(status), "decided_by": typed(email)]); onSaved() }
        catch { self.error = "Could not change it." }
    }

    private func removeOff(_ t: CmsRotaTeamBlockView.TimeOff) async {
        do { try await run("timeOffDeleteMutationSlug", ["id": typed(t.id)]); onSaved() }
        catch { self.error = "Could not remove it." }
    }
}
