import SwiftUI
import UniformTypeIdentifiers

/// "HH:MM" as a time picker's date, and back.
private func timeBinding(_ text: Binding<String>) -> Binding<Date> {
    Binding(
        get: {
            let m = Rota.minutesOf(text.wrappedValue.isEmpty ? "09:00" : text.wrappedValue)
            return Calendar.current.date(bySettingHour: m / 60 % 24, minute: m % 60, second: 0, of: Date()) ?? Date()
        },
        set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            text.wrappedValue = Rota.hhmm((c.hour ?? 0) * 60 + (c.minute ?? 0))
        })
}

// MARK: - The plan

/// The web's plan panel (its three steps) as a Form: what's on, the shifts
/// needed, the budget. Every change saves (debounced) through the model.
struct CmsRotaPlanSheet: View {
    @ObservedObject var model: CmsRotaBuilderModel
    let theme: CmsPortalTheme
    let done: () -> Void
    @State private var importing = false
    @State private var note = ""

    static let presets: [(name: String, start: String, end: String)] = [
        ("Early", "07:00", "15:00"), ("Middle", "09:00", "17:00"), ("Late", "14:00", "22:00"), ("Night", "22:00", "06:00"),
    ]

    private var plan: Rota.Plan { model.plan }
    private func update(_ f: (inout Rota.Plan) -> Void) {
        var p = model.plan
        f(&p)
        model.changePlan(p)
    }

    var body: some View {
        NavigationStack {
            Form {
                whatsOn
                shiftsNeeded
                specialDays
                budget
                Section {
                    Button {
                        done()
                        model.build()
                    } label: { Label("Build this \(model.word)", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .listRowBackground(Color.clear)
                        .disabled(!model.busyText.isEmpty)
                } footer: {
                    if !model.planOrigin.isEmpty { Text(model.planOrigin) }
                }
            }
            .navigationTitle("Plan \(model.period.label)")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await model.flushPlan() }; done() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, !urls.isEmpty { model.uploadDocs(urls) }
            }
        }
        .tint(theme.primary)
    }

    // 1. What's on

    private var whatsOn: some View {
        Section {
            Button { importing = true } label: { Label("Upload bookings, events or an old rota", systemImage: "arrow.up.doc") }
            HStack {
                TextField("Or tell ask wac what's on", text: $note, axis: .vertical).lineLimit(1...4)
                Button {
                    let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !n.isEmpty else { return }
                    note = ""
                    model.tell(n)
                } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
            }
            NavigationLink { CmsRotaCalendarForm(model: model) } label: { Label("Connect a calendar", systemImage: "calendar.badge.plus") }
            NavigationLink { CmsRotaBookingForm(model: model) } label: { Label("Link a booking system", systemImage: "link") }
            ForEach(model.sources) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name.isEmpty ? (s.kind == "calendar" ? "Calendar" : "Booking system") : s.name)
                    Text(s.kind == "calendar" ? "Calendar · saved" : "Booking system · asked for")
                        .font(.system(size: 12.5)).foregroundColor(theme.textSecondary)
                }
                .swipeActions { Button("Remove", role: .destructive) { model.removeSource(s.id) } }
            }
            ForEach(Array(plan.sources.enumerated()), id: \.offset) { _, s in
                Label("\(s.name) (\(s.kind == "file" ? "read" : s.kind))", systemImage: s.kind == "file" ? "doc" : "text.bubble")
                    .font(.system(size: 14)).foregroundColor(theme.textSecondary)
            }
        } header: { Text("1 · What's on") } footer: {
            Text("ask wac reads what you give it and suggests the shifts you need this \(model.word).")
        }
    }

    // 2. Shifts needed

    private var shiftsNeeded: some View {
        Section {
            if let s = plan.suggestion, !s.cells.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Suggested from \(s.from.joined(separator: " and "))\(s.note.isEmpty ? "" : ": \(s.note)")", systemImage: "sparkles")
                        .font(.system(size: 14))
                    Button("Looks good") { update { $0 = Rota.acceptSuggestion($0) } }.buttonStyle(.bordered)
                }
            }
            if plan.shifts.isEmpty {
                Button { model.startFromWorked() } label: { Label("Start from what was worked", systemImage: "clock.arrow.circlepath") }
            }
            ForEach(plan.shifts) { s in
                NavigationLink {
                    CmsRotaPlanShiftForm(model: model, id: s.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(s.name.isEmpty ? "Shift" : s.name).font(.system(size: 15, weight: .medium))
                            Text(Rota.timeRange(s.start, s.end)).foregroundColor(theme.textSecondary)
                            if s.suggested { Image(systemName: "sparkles").foregroundColor(theme.primary).font(.system(size: 12)) }
                        }
                        Text(Rota.weekdays.map { "\(Rota.weekdayLabel[$0]!.prefix(1)) \(s.people[$0] ?? 0)" }.joined(separator: "  "))
                            .font(.system(size: 12.5, design: .monospaced)).foregroundColor(theme.textSecondary)
                    }
                }
            }
            .onDelete { idx in update { p in p.shifts.remove(atOffsets: idx) } }
            Menu {
                ForEach(Self.presets, id: \.name) { pr in
                    Button("\(pr.name) \(Rota.timeRange(pr.start, pr.end))") {
                        update { p in
                            var people = Rota.noPeople()
                            for d in ["mon", "tue", "wed", "thu", "fri"] { people[d] = 1 }
                            p.shifts.append(Rota.PlanShift(id: Rota.newId("sh"), name: pr.name, start: pr.start, end: pr.end, breakMinutes: 30,
                                                           people: people, skill: "", skillPeople: 0, siteId: ""))
                        }
                    }
                }
            } label: { Label("Add a shift", systemImage: "plus") }
        } header: { Text("2 · Shifts needed") } footer: {
            let i = model.inputs
            let dates = Rota.datesBetween(model.period.start, model.period.end)
            let slots = Rota.demandFor(dates, types: i.types, needs: i.needs, busy: i.busy, siteId: model.siteId)
            let hours = slots.reduce(0.0) { $0 + Rota.paidHours($1.type.start, $1.type.end, $1.type.breakMinutes) }
            if !slots.isEmpty {
                Text("\(slots.count) shifts, \(Rota.formatHours(hours))\(model.averageRate > 0 ? ", about \(Rota.formatMoney(hours * model.averageRate))" : "") this \(model.word).")
            }
        }
    }

    // Special days

    private var specialDays: some View {
        Section {
            ForEach(plan.special) { d in
                NavigationLink { CmsRotaSpecialDayForm(model: model, id: d.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Rota.dayLabelShort(d.date)) · \(d.label.isEmpty ? "Special day" : d.label)")
                        Text(d.extra == 0 ? "No change" : "\(d.extra > 0 ? "+" : "")\(d.extra) \(abs(d.extra) == 1 ? "person" : "people")\(plan.shifts.first { $0.id == d.shiftId }.map { " on \($0.name)" } ?? " on every shift")")
                            .font(.system(size: 12.5)).foregroundColor(theme.textSecondary)
                    }
                }
            }
            .onDelete { idx in update { p in p.special.remove(atOffsets: idx) } }
            Button {
                update { p in p.special.append(Rota.SpecialDay(id: Rota.newId("sd"), date: model.period.start, label: "", extra: 1, shiftId: "")) }
            } label: { Label("Add a busy or quiet day", systemImage: "star") }
        } header: { Text("Special days") }
    }

    // 3. Budget

    private var budget: some View {
        Section {
            HStack {
                Text("Staff cost")
                Spacer()
                TextField("No budget", value: Binding(get: { plan.budgetGbp }, set: { v in update { $0.budgetGbp = v } }), format: .number)
                    .multilineTextAlignment(.trailing).keyboardTypeDecimal()
                Text("£").foregroundColor(theme.textSecondary)
            }
            HStack {
                Text("Hours")
                Spacer()
                TextField("No limit", value: Binding(get: { plan.budgetHours }, set: { v in update { $0.budgetHours = v } }), format: .number)
                    .multilineTextAlignment(.trailing).keyboardTypeDecimal()
                Text("h").foregroundColor(theme.textSecondary)
            }
        } header: { Text("3 · Budget") } footer: {
            let s = model.summary
            if s.hours > 0 { Text("This \(model.word)'s rota has \(Rota.formatHours(s.hours)), \(Rota.formatMoney(s.cost)).") }
        }
    }
}

private extension View {
    @ViewBuilder func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    @ViewBuilder func keyboardTypeDecimal() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}

/// One shift of the plan: its times and how many people each weekday.
struct CmsRotaPlanShiftForm: View {
    @ObservedObject var model: CmsRotaBuilderModel
    let id: String

    private var shift: Rota.PlanShift? { model.plan.shifts.first { $0.id == id } }
    private func update(_ f: (inout Rota.PlanShift) -> Void) {
        var p = model.plan
        guard let i = p.shifts.firstIndex(where: { $0.id == id }) else { return }
        f(&p.shifts[i])
        model.changePlan(p)
    }
    private func text(_ k: WritableKeyPath<Rota.PlanShift, String>) -> Binding<String> {
        Binding(get: { shift?[keyPath: k] ?? "" }, set: { v in update { $0[keyPath: k] = v } })
    }

    var body: some View {
        Form {
            if let s = shift {
                Section {
                    TextField("Name", text: text(\.name))
                    DatePicker("Starts", selection: timeBinding(text(\.start)), displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: timeBinding(text(\.end)), displayedComponents: .hourAndMinute)
                    Stepper("Break \(s.breakMinutes) min", value: Binding(get: { s.breakMinutes }, set: { v in update { $0.breakMinutes = v } }), in: 0...120, step: 5)
                } footer: { Text("\(Rota.formatHours(Rota.paidHours(s.start, s.end, s.breakMinutes))) paid.") }
                Section("People each day") {
                    ForEach(Rota.weekdays, id: \.self) { d in
                        let suggested = model.plan.suggestion?.cells.contains("\(id)|\(d)") ?? false
                        Stepper(value: Binding(get: { s.people[d] ?? 0 }, set: { v in
                            var p = model.plan
                            guard let i = p.shifts.firstIndex(where: { $0.id == id }) else { return }
                            p.shifts[i].people[d] = max(0, v)
                            p.suggestion?.cells.removeAll { $0 == "\(id)|\(d)" }
                            model.changePlan(p)
                        }), in: 0...50) {
                            HStack {
                                Text(Rota.weekdayLabel[d]!)
                                if suggested { Image(systemName: "sparkles").font(.system(size: 12)).foregroundColor(model.runtime?.theme.primary) }
                                Spacer()
                                Text("\(s.people[d] ?? 0)").monospacedDigit()
                            }
                        }
                    }
                }
                Section {
                    TextField("Skill needed (optional)", text: text(\.skill))
                    if !s.skill.isEmpty {
                        Stepper("With it: \(s.skillPeople)", value: Binding(get: { s.skillPeople }, set: { v in update { $0.skillPeople = v } }), in: 0...20)
                    }
                    if model.sites.count > 1 {
                        Picker("Site", selection: text(\.siteId)) {
                            Text("Any site").tag("")
                            ForEach(model.sites, id: \.id) { x in Text(x.name).tag(x.id) }
                        }
                    }
                }
            } else {
                Text("This shift was removed.")
            }
        }
        .navigationTitle(shift?.name.isEmpty == false ? shift!.name : "Shift")
    }
}

/// One special day: its date, what's on, and how many more or fewer people.
struct CmsRotaSpecialDayForm: View {
    @ObservedObject var model: CmsRotaBuilderModel
    let id: String

    private var day: Rota.SpecialDay? { model.plan.special.first { $0.id == id } }
    private func update(_ f: (inout Rota.SpecialDay) -> Void) {
        var p = model.plan
        guard let i = p.special.firstIndex(where: { $0.id == id }) else { return }
        f(&p.special[i])
        p.special[i].suggested = false
        model.changePlan(p)
    }

    var body: some View {
        Form {
            if let d = day {
                let dates = Rota.datesBetween(model.period.start, model.period.end)
                Picker("Day", selection: Binding(get: { d.date }, set: { v in update { $0.date = v } })) {
                    ForEach(dates, id: \.self) { x in Text(Rota.dayLabelShort(x)).tag(x) }
                }
                TextField("What's on", text: Binding(get: { d.label }, set: { v in update { $0.label = v } }))
                Stepper("\(d.extra > 0 ? "+" : "")\(d.extra) \(abs(d.extra) == 1 ? "person" : "people")",
                        value: Binding(get: { d.extra }, set: { v in update { $0.extra = v } }), in: -9...20)
                Picker("On", selection: Binding(get: { d.shiftId }, set: { v in update { $0.shiftId = v } })) {
                    Text("Every shift").tag("")
                    ForEach(model.plan.shifts) { s in Text(s.name.isEmpty ? Rota.timeRange(s.start, s.end) : s.name).tag(s.id) }
                }
            }
        }
        .navigationTitle("Special day")
    }
}

/// Connect a calendar: the web's steps for each provider, then its link.
struct CmsRotaCalendarForm: View {
    @ObservedObject var model: CmsRotaBuilderModel
    @Environment(\.dismiss) private var dismiss
    @State private var provider = "google"
    @State private var name = ""
    @State private var address = ""

    private var steps: [String] {
        switch provider {
        case "outlook": return ["In Outlook on the web, open Settings → Calendar → Shared calendars.", "Under Publish a calendar, choose the calendar and Can view all details, then Publish.", "Copy the ICS link and paste it below."]
        case "apple": return ["In the Calendar app on a Mac, Control-click the calendar and choose Share Calendar.", "Tick Public Calendar and copy the address.", "Paste it below."]
        default: return ["In Google Calendar, open the calendar's Settings and sharing.", "Under Integrate calendar, copy the Secret address in iCal format.", "Paste it below."]
        }
    }

    var body: some View {
        Form {
            Picker("Calendar", selection: $provider) {
                Text("Google").tag("google")
                Text("Outlook").tag("outlook")
                Text("Apple").tag("apple")
            }
            .pickerStyle(.segmented)
            Section("How") {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in Text("\(i + 1). \(s)").font(.system(size: 14)) }
            }
            Section {
                TextField("Name, like Functions diary", text: $name)
                TextField("Calendar link", text: $address).textContentType(.URL).autocorrectionDisabled()
            }
            Button("Save calendar") {
                model.saveSource(kind: "calendar", name: name.isEmpty ? provider.capitalized : name, address: address.trimmingCharacters(in: .whitespaces))
                dismiss()
            }
            .disabled(!address.lowercased().hasPrefix("http") && !address.lowercased().hasPrefix("webcal"))
        }
        .navigationTitle("Connect a calendar")
    }
}

/// Ask for a booking system to be linked (recorded as requested).
struct CmsRotaBookingForm: View {
    @ObservedObject var model: CmsRotaBuilderModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""

    var body: some View {
        Form {
            Section {
                TextField("Which system, like ResDiary or OpenTable", text: $name)
                TextField("Anything we should know", text: $note, axis: .vertical).lineLimit(2...5)
            } footer: { Text("We'll be in touch to link it. Until then, upload an export from it.") }
            Button("Ask for it") {
                model.saveSource(kind: "booking", name: name, address: "", note: note)
                dismiss()
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle("Booking system")
    }
}

// MARK: - One shift

/// The web's shift dialog: who, when, which shift, break, site and note,
/// with why it was given and anything to check.
struct CmsRotaShiftEditor: View {
    @ObservedObject var model: CmsRotaBuilderModel
    let theme: CmsPortalTheme
    let editing: CmsRotaBuilderModel.Editing
    @Environment(\.dismiss) private var dismiss
    @State private var s: Rota.Shift
    @State private var confirmRemove = false

    init(model: CmsRotaBuilderModel, theme: CmsPortalTheme, editing: CmsRotaBuilderModel.Editing) {
        self.model = model
        self.theme = theme
        self.editing = editing
        if let shift = editing.shift {
            _s = State(initialValue: shift)
        } else {
            let type = model.inputs.types.first
            _s = State(initialValue: Rota.Shift(id: Rota.newId("rs"), rotaId: model.active?.id ?? "", code: editing.code, date: editing.date,
                                                start: type?.start ?? "09:00", end: type?.end ?? "17:00", breakMinutes: type?.breakMinutes ?? 30,
                                                typeId: type?.id ?? "", skill: "", siteId: type?.siteId ?? model.siteId, hours: 0, cost: 0,
                                                source: "hand", note: ""))
        }
    }

    var body: some View {
        let types = model.inputs.types
        let dates = Rota.datesBetween(model.period.start, model.period.end)
        let hours = Rota.paidHours(s.start, s.end, s.breakMinutes)
        let person = model.people.first { $0.code == s.code }
        let warn = model.warnings.filter { $0.shiftId == s.id }
        NavigationStack {
            Form {
                Section {
                    Picker("Who", selection: $s.code) {
                        Text("Open shift").tag("")
                        ForEach(model.shown) { p in
                            let r = model.blockedReason(p, for: s)
                            Text(r.map { "\(p.name) — \($0)" } ?? p.name).tag(p.code)
                        }
                    }
                    if let p = person, let r = model.blockedReason(p, for: s) {
                        Label("\(p.name) \(r).", systemImage: "exclamationmark.triangle").font(.system(size: 13.5)).foregroundColor(theme.warning)
                    }
                    Picker("Day", selection: $s.date) {
                        ForEach(dates.contains(s.date) ? dates : [s.date] + dates, id: \.self) { d in Text(Rota.dayLabelShort(d)).tag(d) }
                    }
                }
                Section {
                    Picker("Shift", selection: Binding(get: { s.typeId }, set: { id in
                        s.typeId = id
                        if let t = types.first(where: { $0.id == id }) {
                            s.start = t.start; s.end = t.end; s.breakMinutes = t.breakMinutes
                            if !t.siteId.isEmpty { s.siteId = t.siteId }
                        }
                    })) {
                        Text("Own times").tag("")
                        ForEach(types) { t in Text("\(t.name) \(Rota.timeRange(t.start, t.end, compact: true))").tag(t.id) }
                    }
                    DatePicker("Starts", selection: timeBinding(Binding(get: { s.start }, set: { s.start = $0; s.typeId = matchType(types) })),
                               displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: timeBinding(Binding(get: { s.end }, set: { s.end = $0; s.typeId = matchType(types) })),
                               displayedComponents: .hourAndMinute)
                    Stepper("Break \(s.breakMinutes) min", value: $s.breakMinutes, in: 0...120, step: 5)
                    if model.sites.count > 1 {
                        Picker("Site", selection: $s.siteId) {
                            Text("Any site").tag("")
                            ForEach(model.sites, id: \.id) { x in Text(x.name).tag(x.id) }
                        }
                    }
                    TextField("Note", text: $s.note)
                } footer: {
                    Text("\(Rota.formatHours(hours)) paid\(person.map { $0.rate > 0 ? ", \(Rota.formatMoney(hours * $0.rate))" : "" } ?? "").")
                }
                if let why = model.why[s.id], !why.isEmpty {
                    Section("Why") { Text(why).font(.system(size: 14)) }
                }
                if !warn.isEmpty {
                    Section("To check") {
                        ForEach(warn) { w in
                            Label(w.text, systemImage: w.severity == "error" ? "exclamationmark.octagon" : "exclamationmark.triangle")
                                .foregroundColor(w.severity == "error" ? theme.error : theme.warning).font(.system(size: 14))
                        }
                    }
                }
                if editing.shift != nil {
                    Section {
                        Button("Remove this shift", role: .destructive) { confirmRemove = true }
                    }
                }
            }
            .navigationTitle(editing.shift == nil ? "New shift" : "Shift")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var next = s
                        if let old = editing.shift, old != next, old.source == "build" || old.source == "copy" { next.source = "hand" }
                        model.saveShift(next)
                    }
                    .disabled(!model.busyText.isEmpty || s.start == s.end)
                }
            }
            .confirmationDialog("Remove this shift?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let old = editing.shift { model.removeShift(old) } }
            }
        }
        .tint(theme.primary)
    }

    private func matchType(_ types: [Rota.ShiftType]) -> String {
        types.first { $0.start == s.start && $0.end == s.end }?.id ?? ""
    }
}
