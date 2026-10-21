import SwiftUI

/// Native twin of `actionList` (ActionListBlock.tsx + reconcileActions.ts):
/// the to-do list a reconcile leaves behind — grouped by the day each is
/// about, ticked off by hand or seen done on the grid, removed, messaged.
///
/// Semantics mirrored: `actionFromRow`; the status and remove mutations (with
/// company_id); the grid check (`gridRange`, `gridShowsDone`, a put-back item
/// left alone) that ticks off and logs "seen on the shifts" (`gridFixNote`)
/// and records its variance (`varianceOnDone`, `varianceFromGrid`); a tick by
/// hand records the variance a reconcile found; putting back takes it off;
/// `suggestedMessage` and "Mark as sent" into the activity log; "Run today's
/// check" claims the day and asks the page's chat; re-checks every
/// `recheckMinutes` while shown.
///
/// Presentation: the brand summary band, a segmented To do / Done, day
/// sections of rows with a check circle, swipe and context-menu actions, the
/// system share sheet for a message, and an Undo bar after a tick.
///
/// Not native yet: the location check (`locationQuerySlug`), the automatic
/// daily run (`autoRunDaily`; the web runs it for everyone on first open of
/// the day) and the wide layout's side column.
struct CmsActionListBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    @State private var view = "open"
    @State private var local: [String: Action] = [:]
    @State private var removed: Set<String> = []
    @State private var undo: Action?
    @State private var messageFor: Action?
    @State private var lastChecked = ""

    struct Action: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String
        var kind: String
        var person: String
        var employeeCode: String
        var date: String
        var value: Double?
        var plannedHours: Double?
        var workedHours: Double?
        var favour: String?
        var source: String
        var status: String
        var doneHow: String
        var createdAt: String
        var doneAt: String
    }

    private var props: [String: CmsJSON] { block.props }
    private func text(_ key: String, _ fallback: String = "") -> String {
        props.string(key).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
    private var querySlug: String { text("querySlug") }
    private var account: String { resolved("account") }
    private var accountPrefix: String { resolved("accountPrefix") }
    private var email: String { runtime.client.userEmail ?? runtime.membership?.email ?? "" }

    private func resolved(_ key: String) -> String {
        let t = text(key)
        guard !t.isEmpty else { return "" }
        let v = runtime.resolveTemplate(t).trimmingCharacters(in: .whitespaces)
        return v.contains("@") ? "" : v
    }

    // MARK: - reconcileActions.ts

    private static func str(_ v: CmsJSON?) -> String {
        guard let v, v != .null else { return "" }
        return v.displayString.trimmingCharacters(in: .whitespaces)
    }
    private static func num(_ v: CmsJSON?) -> Double? {
        let s = str(v)
        return s.isEmpty ? nil : Double(s).flatMap { $0.isFinite ? $0 : nil }
    }

    static func action(_ r: [String: CmsJSON]) -> Action? {
        let id = str(r["id"]), title = str(r["title"])
        guard !id.isEmpty, !title.isEmpty else { return nil }
        let date = String(str(r["shift_date"]).prefix(10))
        let favour = str(r["favour"])
        return Action(
            id: id, title: title, detail: str(r["detail"]), kind: str(r["kind"]).isEmpty ? "other" : str(r["kind"]),
            person: str(r["person"]), employeeCode: str(r["employee_code"]),
            date: date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? date : "",
            value: num(r["value"]), plannedHours: num(r["planned_hours"]), workedHours: num(r["worked_hours"]),
            favour: favour == "worker" || favour == "company" ? favour : nil,
            source: str(r["source"]), status: str(r["status"]) == "done" ? "done" : "open",
            doneHow: str(r["done_how"]), createdAt: str(r["created_at"]), doneAt: str(r["done_at"])
        )
    }

    static let gridCheckedKinds: Set<String> = ["wac_out", "wac_in", "hours"]

    private static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
    private static func shiftDay(_ s: [String: CmsJSON]) -> String {
        let d = String(str(s["shift_date"]).prefix(10))
        return d.isEmpty ? String(str(s["clocked_in_at"]).prefix(10)) : d
    }
    private static func isThisPerson(_ a: Action, _ s: [String: CmsJSON]) -> Bool {
        let code = str(s["employee_code"])
        if !a.employeeCode.isEmpty && !code.isEmpty { return code.lowercased() == a.employeeCode.lowercased() }
        let name = norm(str(s["user_name"])), who = norm(a.person)
        guard !name.isEmpty, !who.isEmpty else { return false }
        return name == who || (!who.contains(" ") && name.split(separator: " ").first.map(String.init) == who)
    }

    static func gridShowsDone(_ a: Action, _ shifts: [[String: CmsJSON]]) -> Bool? {
        guard gridCheckedKinds.contains(a.kind), !a.date.isEmpty, !(a.employeeCode.isEmpty && a.person.isEmpty) else { return nil }
        if a.kind == "hours" && a.plannedHours == nil { return nil }
        let theirs = shifts.filter { shiftDay($0) == a.date && isThisPerson(a, $0) }
        if a.kind == "wac_in" { return theirs.contains { !str($0["clocked_in_at"]).isEmpty } }
        if a.kind == "hours" {
            guard !theirs.isEmpty, theirs.allSatisfy({ !str($0["clocked_out_at"]).isEmpty }) else { return false }
            let worked = theirs.reduce(0) { $0 + (num($1["hours_worked"]) ?? 0) }
            return abs(worked - (a.plannedHours ?? 0)) <= 0.25 + 1e-9
        }
        return !theirs.isEmpty && theirs.allSatisfy { !str($0["clocked_out_at"]).isEmpty }
    }

    static func gridRange(_ actions: [Action]) -> (from: String, to: String)? {
        let days = actions.filter { $0.status == "open" && gridCheckedKinds.contains($0.kind) && !$0.date.isEmpty }.map(\.date).sorted()
        guard let first = days.first, let last = days.last else { return nil }
        return (first, CmsFileWeeks.iso(CmsFileWeeks.addDays(CmsFileWeeks.parse(last), 1)))
    }

    static func dayHeading(_ date: String, now: Date) -> String {
        guard !date.isEmpty else { return "No day given" }
        if date == CmsFileWeeks.iso(now) { return "Today" }
        if date == CmsFileWeeks.iso(CmsFileWeeks.addDays(now, -1)) { return "Yesterday" }
        let d = CmsFileWeeks.parse(date)
        let gb = Locale(identifier: "en_GB")
        return Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: now)
            ? d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(gb))
            : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().locale(gb))
    }

    static func doneThisWeek(_ actions: [Action], now: Date) -> Int {
        let from = CmsFileWeeks.iso(CmsFileWeeks.mondayOf(now))
        return actions.filter { $0.status == "done" && String($0.doneAt.prefix(10)) >= from }.count
    }

    private static func shortDay(_ date: String) -> String {
        guard !date.isEmpty else { return "" }
        return CmsFileWeeks.parse(date).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }

    static func suggestedMessage(_ a: Action) -> String {
        let first = a.person.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let name = first.isEmpty ? "" : first.prefix(1).uppercased() + first.dropFirst()
        let hi = name.isEmpty ? "Hi" : "Hi \(name)"
        let day = shortDay(a.date)
        let on = day.isEmpty ? "" : " on \(day)"
        switch a.kind {
        case "wac_out": return "\(hi), there's no wac out for your shift\(on). Could you add it in wac when you get a moment? Thanks!"
        case "wac_in": return "\(hi), I can't see a wac in for your shift\(on). Could you add it in wac? Thanks!"
        case "location_out", "location_in":
            let how = a.detail.range(of: #"was ([\d.,]+ k?m) from site"#, options: .regularExpression)
                .map { String(a.detail[$0]).replacingOccurrences(of: "was ", with: "").replacingOccurrences(of: " from site", with: "") }
            let away = how.map { " (about \($0) from work)" } ?? ""
            return a.kind == "location_in"
                ? "\(hi), it looks like your wac in\(on) happened before you got to work\(away). No worries, it's easily done! Could you check your wac in time and update it if it's not right? Thanks!"
                : "\(hi), it looks like you might have forgotten to wac out before leaving work\(on)\(away). No worries, it's easily done! Could you check your wac out time and update it if it's not right? Thanks!"
        case "break": return "\(hi), could you check the break on your shift\(on) in wac? Thanks!"
        case "hours": return "\(hi), your hours\(on) are different from the rota. If you stayed on later, that's fine and we'll make sure you're paid for it. If you forgot to wac out, could you update your wac out time? Thanks!"
        default: return "\(hi), could you check your shift\(on) in wac? \(a.title). Thanks!"
        }
    }

    struct Variance { var direction: String; var hours: Double?; var amount: Double? }
    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    static func varianceFromGrid(_ a: Action, _ shifts: [[String: CmsJSON]]) -> Variance? {
        if a.kind == "hours", let before = a.workedHours {
            let day = shifts.filter { shiftDay($0) == a.date && isThisPerson(a, $0) && !str($0["clocked_out_at"]).isEmpty }
            guard !day.isEmpty else { return nil }
            let delta = day.reduce(0) { $0 + (num($1["hours_worked"]) ?? 0) } - before
            guard abs(delta) >= 0.01 else { return nil }
            let rate = num(day[0]["hourly_pay"]) ?? 0
            let amount = rate > 0 ? abs(delta) * rate : a.value
            return Variance(direction: delta > 0 ? "worker" : "company", hours: round2(abs(delta)), amount: amount.map(round2))
        }
        guard a.kind == "wac_out" || a.kind == "wac_in" else { return nil }
        let theirs = shifts.filter { shiftDay($0) == a.date && isThisPerson(a, $0) && !str($0["clocked_out_at"]).isEmpty }
        let hours = theirs.reduce(0) { $0 + (num($1["hours_worked"]) ?? 0) }
        guard !theirs.isEmpty, hours > 0 else { return nil }
        let rates = theirs.map { num($0["hourly_pay"]) ?? 0 }
        let priced = rates.allSatisfy { $0 > 0 } ? theirs.reduce(0) { $0 + (num($1["hours_worked"]) ?? 0) * (num($1["hourly_pay"]) ?? 0) } : a.value
        return Variance(direction: "worker", hours: round2(hours), amount: priced.map(round2))
    }

    static func varianceOnDone(_ a: Action, how: String, shifts: [[String: CmsJSON]] = []) -> Variance? {
        let reconcileKinds: Set<String> = ["wac_out", "wac_in", "hours", "break", "not_on_rota", "rule", "other"]
        guard reconcileKinds.contains(a.kind), a.source != "location" else { return nil }
        if how == "grid", let seen = varianceFromGrid(a, shifts) { return seen }
        var direction = a.favour
        var hours: Double?
        if a.kind == "hours", let p = a.plannedHours, let w = a.workedHours, abs(w - p) > 1e-9 {
            hours = round2(abs(w - p))
            direction = direction ?? (w > p ? "worker" : "company")
        }
        if direction == nil, ["wac_out", "wac_in", "not_on_rota"].contains(a.kind) { direction = "worker" }
        guard let direction, a.value != nil || hours != nil else { return nil }
        return Variance(direction: direction, hours: hours, amount: a.value.map { round2(abs($0)) })
    }

    // MARK: - Data

    private var actions: [Action]? {
        guard case .ok(let result) = runtime.state(for: querySlug) else { return nil }
        return result.rows.compactMap(Self.action).filter { !removed.contains($0.id) }.map { local[$0.id] ?? $0 }
    }

    private func typed(_ v: String?, _ type: String = "string") -> CmsJSON {
        .object(["value": v.map { .string($0) } ?? .null, "type": .string(type)])
    }

    private func mutate(_ key: String, _ params: [String: CmsJSON]) async -> Bool {
        let slug = text(key)
        guard !slug.isEmpty else { return false }
        if case .done = await runtime.runMutation(slug, params: params) { return true }
        return false
    }

    private func setStatus(_ a: Action, _ status: String, how: String) async {
        var changed = a
        changed.status = status
        changed.doneHow = status == "done" ? how : (how == "reopened" ? "reopened" : "")
        changed.doneAt = status == "done" ? ISO8601DateFormatter().string(from: Date()) : ""
        local[a.id] = changed
        _ = await mutate("statusMutationSlug", ["id": typed(a.id), "status": typed(status), "done_how": typed(how), "company_id": typed(account)])
        runtime.invalidate(querySlug)
    }

    private func log(_ a: Action, kind: String, text value: String, detail: String = "", by: String = "") async {
        guard !account.isEmpty else { return }
        _ = await mutate("logMutationSlug", [
            "company_id": typed(account), "kind": typed(kind), "person": typed(a.person), "employee_code": typed(a.employeeCode),
            "shift_date": typed(a.date.isEmpty ? nil : a.date, "date"), "text": typed(value), "detail": typed(detail),
            "by": typed(by), "action_id": typed(a.id), "at": typed(""),
        ])
        if !text("logQuerySlug").isEmpty { runtime.invalidate(text("logQuerySlug")) }
    }

    private func recordVariance(_ a: Action, _ v: Variance, how: String) async {
        guard !account.isEmpty else { return }
        _ = await mutate("varianceMutationSlug", [
            "action_id": typed(a.id), "company_id": typed(account), "direction": typed(v.direction),
            "hours": typed(v.hours.map { String($0) }, "float"), "amount": typed(v.amount.map { String($0) }, "float"),
            "fixed_how": typed(how), "confirmed_by": typed(how == "manager" ? email : ""), "note": typed(""),
        ])
        if !text("varianceQuerySlug").isEmpty { runtime.invalidate(text("varianceQuerySlug")) }
    }

    private func tick(_ a: Action) {
        let toDone = a.status != "done"
        Task {
            await setStatus(a, toDone ? "done" : "open", how: toDone ? "you" : (a.doneHow == "grid" ? "reopened" : "you"))
            if toDone, let v = Self.varianceOnDone(a, how: "you") { await recordVariance(a, v, how: "manager") }
            if !toDone { _ = await mutate("varianceClearMutationSlug", ["action_id": typed(a.id), "company_id": typed(account)]) }
        }
        withAnimation { undo = toDone ? a : nil }
        if toDone {
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                withAnimation { if undo?.id == a.id { undo = nil } }
            }
        }
    }

    private func remove(_ a: Action) {
        if a.kind == "location_in" || a.kind == "location_out" {
            Task { await setStatus(a, "done", how: "you") }
            return
        }
        removed.insert(a.id)
        Task {
            _ = await mutate("deleteMutationSlug", ["id": typed(a.id), "company_id": typed(account)])
            runtime.invalidate(querySlug)
        }
    }

    /// The grid check: a missing wac out or wac in (or hours) since put right.
    private func checkGrid(_ list: [Action]) async {
        let shiftsSlug = text("shiftsQuerySlug")
        guard !shiftsSlug.isEmpty, !runtime.isDesignMode, let range = Self.gridRange(list) else { return }
        guard let result = try? await runtime.client.runSavedQuery(cmsId: runtime.cmsId, querySlug: shiftsSlug, params: [
            "shift_from": typed(range.from, "date"), "shift_to": typed(range.to, "date"), "all_employees": typed("1"),
            "employee_code": .object(["values": .array([]), "type": .string("string"), "mode": .string("multi")]),
            "company_id": typed(account), "company_prefix": typed(accountPrefix),
        ]) else { return }
        let shifts = result.rows
        for a in list where a.status == "open" && a.doneHow != "reopened" && Self.gridShowsDone(a, shifts) == true {
            await setStatus(a, "done", how: "grid")
            let who = a.person.isEmpty ? (a.employeeCode.isEmpty ? "Their" : a.employeeCode) : a.person
            let note: String = {
                switch a.kind {
                case "wac_out": return "\(who)'s wac out for \(Self.shortDay(a.date)) was added"
                case "wac_in": return "\(who)'s wac in for \(Self.shortDay(a.date)) was added"
                case "hours": return "\(who)'s hours for \(Self.shortDay(a.date)) were changed"
                default: return "\(who)'s shift for \(Self.shortDay(a.date)) was changed"
                }
            }()
            await log(a, kind: "shift_changed", text: note, by: "Seen on the shifts")
            if let v = Self.varianceOnDone(a, how: "grid", shifts: shifts) { await recordVariance(a, v, how: "grid") }
        }
    }

    private func runDaily() {
        let now = Date()
        let prompt = CmsFileWeeks.fillPrompt(text("dailyPrompt"), [
            "today": CmsFileWeeks.iso(now), "yesterday": CmsFileWeeks.iso(CmsFileWeeks.addDays(now, -1)),
            "todayLabel": now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "en_GB"))),
        ])
        let day = CmsFileWeeks.iso(now)
        Task {
            _ = await mutate("claimMutationSlug", [
                "id": typed("\(account)|\(day)"), "company_id": typed(account), "run_date": typed(day, "date"),
                "run_by": typed(email), "how": typed("you"),
            ])
            if !text("runsQuerySlug").isEmpty { runtime.invalidate(text("runsQuerySlug")) }
        }
        runtime.ask(chat: text("askChat"), prompt: prompt)
    }

    // MARK: - View

    private static let kinds: [String: (String, String)] = [
        "wac_out": ("No wac out", "rectangle.portrait.and.arrow.right"), "wac_in": ("No wac in", "rectangle.portrait.and.arrow.forward"),
        "break": ("Break", "cup.and.saucer"), "hours": ("Hours", "clock"), "not_on_rota": ("Not on the rota", "calendar.badge.exclamationmark"),
        "rule": ("Rule", "building.columns"), "other": ("To check", "flag"),
        "location_in": ("Away from site", "location.slash"), "location_out": ("Away from site", "location.slash"),
    ]

    private func money(_ x: Double) -> String {
        x.formatted(.currency(code: text("valueCurrency", "GBP")).locale(Locale(identifier: "en_GB")))
    }

    var body: some View {
        let list = actions
        let now = Date()
        let open = (list ?? []).filter { $0.status == "open" }
        let done = (list ?? []).filter { $0.status == "done" }
        let openValue = open.reduce(0) { $0 + ($1.value ?? 0) }
        let shown = view == "open" ? open : done
        var days: [(String, [Action])] = []
        for a in shown {
            if let i = days.firstIndex(where: { $0.0 == a.date }) { days[i].1.append(a) } else { days.append((a.date, [a])) }
        }
        days.sort { a, b in a.0.isEmpty ? false : b.0.isEmpty ? true : a.0 > b.0 }
        let checkable = open.filter { Self.gridCheckedKinds.contains($0.kind) }.map(\.id).sorted().joined(separator: ",")

        return VStack(alignment: .leading, spacing: 14) {
            if !text("heading", "To-do list").isEmpty { Text(text("heading", "To-do list")).font(.system(size: 22, weight: .heavy)) }
            if !text("intro").isEmpty { Text(text("intro")).font(.system(size: 14)).foregroundColor(runtime.theme.textSecondary) }

            band(open: open, openValue: openValue, list: list ?? [], now: now)

            Picker("", selection: $view) {
                Text("To do \(open.count)").tag("open")
                Text("Done \(done.count)").tag("done")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if case .error(let message) = runtime.state(for: querySlug) {
                CmsQueryErrorView(message: message, querySlug: querySlug)
            } else if list == nil {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            } else if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: view == "open" ? "checkmark" : "tray").font(.system(size: 22, weight: .bold))
                        .foregroundColor(runtime.theme.success).frame(width: 52, height: 52)
                        .background(Circle().fill(runtime.theme.success.opacity(0.14)))
                    Text(view == "open" ? "All clear" : "Nothing done yet").font(.system(size: 17, weight: .heavy))
                    if view == "open" {
                        Text("Nothing to sort. Everything ask wac finds lands here, so it is put right before payday.")
                            .font(.system(size: 13.5)).foregroundColor(runtime.theme.textSecondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(RoundedRectangle(cornerRadius: runtime.theme.cardRadius).fill(runtime.theme.tint.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: runtime.theme.cardRadius)
                    .strokeBorder(runtime.theme.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            } else {
                ForEach(days, id: \.0) { day in
                    Text(Self.dayHeading(day.0, now: now).uppercased())
                        .font(.system(size: 11.5, weight: .bold)).tracking(1).foregroundColor(runtime.theme.textSecondary)
                    ForEach(day.1) { row($0) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let undo {
                HStack {
                    Text("Marked done: \(undo.title)").font(.system(size: 14)).lineLimit(1)
                    Spacer()
                    Button("Undo") { tick(local[undo.id] ?? undo); self.undo = nil }.fontWeight(.bold)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .foregroundColor(runtime.theme.paper)
                .background(Capsule().fill(runtime.theme.textPrimary))
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: checkable) {
            guard !checkable.isEmpty, checkable != lastChecked, let list = actions else { return }
            lastChecked = checkable
            await checkGrid(list)
        }
        .task(id: querySlug) {
            runtime.ensureLoaded(querySlug)
            let minutes = props.double("recheckMinutes") ?? 5
            guard minutes > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(minutes * 60) * 1_000_000_000)
                if Task.isCancelled { break }
                runtime.invalidate(querySlug)
                if let list = actions { await checkGrid(list) }
            }
        }
        .ripulSheet(item: $messageFor, size: .form) { a in
            CmsActionMessageSheet(action: a, message: Self.suggestedMessage(a)) { message in
                let first = a.person.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "them"
                let company = resolved("companyName")
                Task { await log(a, kind: "message_sent", text: "\(company.isEmpty ? "You" : company) messaged \(first)", detail: message, by: email) }
            }
            .environmentObject(runtime)
        }
    }

    private func band(open: [Action], openValue: Double, list: [Action], now: Date) -> some View {
        let onBrand = runtime.theme.primaryContrast
        var figures: [(String, String)] = [("\(open.count)", "to do")]
        if openValue > 0 { figures.append((money(openValue), "to sort")) }
        figures.append(("\(Self.doneThisWeek(list, now: now))", "done this week"))
        return VStack(alignment: .leading, spacing: 10) {
            Text("TO SORT BEFORE PAYDAY").font(.system(size: 11, weight: .bold)).tracking(1.2).opacity(0.85)
            Text(open.isEmpty ? "All clear" : "\(open.count) to sort").font(.system(size: 24, weight: .heavy))
            HStack(spacing: 22) {
                ForEach(figures, id: \.1) { f in
                    VStack(spacing: 1) {
                        Text(f.0).font(.system(size: 20, weight: .heavy))
                        Text(f.1.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6).opacity(0.85)
                    }
                }
            }
            if !text("askChat").isEmpty && !text("dailyPrompt").isEmpty {
                Button(action: runDaily) {
                    Label(text("dailyLabel", "Run today’s check"), systemImage: "sparkles")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(runtime.theme.primary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(onBrand))
                }
                .buttonStyle(.plain)
                .disabled(runtime.isDesignMode)
                .cmsInspectorID("Cms.actionList.daily")
            }
        }
        .foregroundColor(onBrand)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(runtime.theme.gradient, in: RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous))
    }

    private func row(_ a: Action) -> some View {
        let isDone = a.status == "done"
        let kind = Self.kinds[a.kind] ?? Self.kinds["other"]!
        return HStack(alignment: .top, spacing: 12) {
            Button { tick(a) } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26))
                    .foregroundColor(isDone ? runtime.theme.success : runtime.theme.primary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(runtime.isDesignMode)
            .accessibilityLabel(isDone ? "Put back to do: \(a.title)" : "Mark done: \(a.title)")
            VStack(alignment: .leading, spacing: 5) {
                Text(a.title).font(.system(size: 14.5, weight: .bold))
                    .foregroundColor(isDone ? runtime.theme.textSecondary : runtime.theme.textPrimary)
                    .strikethrough(isDone)
                HStack(spacing: 6) {
                    Label(kind.0, systemImage: kind.1).font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(runtime.theme.primary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(runtime.theme.tint))
                    if let v = a.value { Text(money(v)).font(.system(size: 12, weight: .semibold)) }
                    if !a.person.isEmpty { Text(a.person).font(.system(size: 12)).foregroundColor(runtime.theme.textSecondary).lineLimit(1) }
                }
                if !a.detail.isEmpty {
                    Text(a.detail).font(.system(size: 12.5)).foregroundColor(runtime.theme.textSecondary)
                }
                if isDone && a.doneHow == "grid" {
                    Label("Seen on the shifts", systemImage: "checkmark.seal").font(.system(size: 11.5)).foregroundColor(runtime.theme.success)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(runtime.theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(runtime.theme.divider))
        .contextMenu {
            Button { tick(a) } label: { Label(isDone ? "Put back to do" : "Mark done", systemImage: isDone ? "arrow.uturn.backward" : "checkmark") }
            if !a.person.isEmpty { Button { messageFor = a } label: { Label("Message \(a.person.split(separator: " ").first ?? "")", systemImage: "message") } }
            Button(role: .destructive) { remove(a) } label: { Label("Remove", systemImage: "trash") }
        }
        .cmsInspectorID("Cms.actionList.item")
    }
}

/// The suggested message to send the person, editable, with the share sheet
/// and "Mark as sent" (copying or sharing alone may not send it).
private struct CmsActionMessageSheet: View {
    let action: CmsActionListBlockView.Action
    @State var message: String
    let onSent: (String) -> Void
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.dismiss) private var dismiss

    init(action: CmsActionListBlockView.Action, message: String, onSent: @escaping (String) -> Void) {
        self.action = action
        _message = State(initialValue: message)
        self.onSent = onSent
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("A message for \(action.person)") {
                    TextEditor(text: $message).frame(minHeight: 120)
                }
                Section {
                    ShareLink(item: message) { Label("Share or copy", systemImage: "square.and.arrow.up") }
                    Button { onSent(message); dismiss() } label: { Label("Mark as sent", systemImage: "checkmark.message") }
                }
            }
            .navigationTitle("Message")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .tint(runtime.theme.primary)
    }
}
