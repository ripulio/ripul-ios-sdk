import SwiftUI

/// The data and actions of the native `rotaBuilder` (RotaBuilderBlock.tsx),
/// kept apart from its views. Every action is the web's: the same queries,
/// mutations, file-store writes and prompts to the page's chat, in the same
/// order. `CmsRotaLogic.swift` holds the pure rules.
@MainActor
final class CmsRotaBuilderModel: ObservableObject {
    struct RotaRow: Equatable {
        var id: String
        var start: String
        var last: String
        var cadence: String
        var status: String
        var madeBy: String
        var summary: [String: CmsJSON]
        var builtBy: String
        var builtAt: String
        var publishedBy: String
        var publishedAt: String
    }
    struct Source: Identifiable, Equatable { var id: String; var kind: String; var name: String; var address: String; var status: String }
    struct Notice: Equatable { var tone: String; var text: String }
    struct Confirm: Identifiable { let id = UUID(); var title: String; var text: String; var confirm: String; var run: () -> Void }
    struct Editing: Identifiable { let id = UUID(); var shift: Rota.Shift?; var code: String; var date: String }

    private(set) var runtime: CmsRuntime?
    private(set) var block: CmsBlock?

    @Published var mode = "week"
    @Published var anchor = Rota.iso(Date())
    @Published var siteId = ""
    @Published var shifts: [Rota.Shift] = []
    @Published var loadedFor = ""
    @Published var error = ""
    @Published var localPlan: (key: String, plan: Rota.Plan)?
    @Published var planSaving = false
    @Published var busyText = ""
    @Published var notice: Notice?
    @Published var confirm: Confirm?
    @Published var edit: Editing?
    @Published var why: [String: String] = [:]
    @Published var reading: (key: String, name: String, at: String)?
    private var pendingPlan: (key: String, plan: Rota.Plan, period: Rota.Period)?
    private var saveTask: Task<Void, Never>?

    func attach(runtime: CmsRuntime, block: CmsBlock) {
        self.runtime = runtime
        self.block = block
        if let saved = UserDefaults.standard.string(forKey: modeKey), saved == "week" || saved == "month" { mode = saved }
        for key in ["teamQuerySlug", "availabilityQuerySlug", "timeOffQuerySlug", "sitesQuerySlug", "rotasQuerySlug", "plansQuerySlug", "sourcesQuerySlug"] {
            runtime.ensureLoaded(text(key))
        }
    }

    // MARK: - Props and data

    func text(_ key: String, _ fallback: String = "") -> String {
        block?.props.string(key).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
    private var modeKey: String { "ripul:rotaBuilder:mode:\(block?.slug ?? "rota")" }

    func setMode(_ m: String) {
        mode = m
        UserDefaults.standard.set(m, forKey: modeKey)
    }

    private func resolved(_ key: String) -> String {
        guard let runtime else { return "" }
        let t = text(key)
        guard !t.isEmpty else { return "" }
        let v = runtime.resolveTemplate(t).trimmingCharacters(in: .whitespaces)
        return v.contains("@") ? "" : v
    }
    var account: String { resolved("account") }
    var accountPrefix: String { resolved("accountPrefix") }
    var email: String { runtime?.client.userEmail ?? runtime?.membership?.email ?? "" }

    func rows(_ key: String) -> [[String: CmsJSON]]? {
        guard let runtime, !text(key).isEmpty, case .ok(let r) = runtime.state(for: text(key)) else { return nil }
        return r.rows
    }

    var people: [Rota.Person] {
        let weeks = CmsRotaTeamBlockView.weeks(rows("availabilityQuerySlug") ?? [])
        return (rows("teamQuerySlug") ?? []).compactMap { Rota.person($0, week: weeks[Rota.str($0["employee_code"])]) }
    }
    var timeOff: [Rota.TimeOff] { (rows("timeOffQuerySlug") ?? []).compactMap(CmsRotaTeamBlockView.timeOff) }
    var sites: [(id: String, name: String)] {
        (rows("sitesQuerySlug") ?? []).map { (Rota.str($0["id"]), Rota.str($0["name"])) }.filter { !$0.id.isEmpty }
    }
    var sources: [Source] {
        (rows("sourcesQuerySlug") ?? []).map {
            Source(id: Rota.str($0["id"]), kind: Rota.str($0["kind"]) == "booking" ? "booking" : "calendar", name: Rota.str($0["name"]),
                   address: Rota.str($0["address"]), status: Rota.str($0["status"]))
        }
    }
    var rotas: [RotaRow] {
        (rows("rotasQuerySlug") ?? []).compactMap { r in
            let id = Rota.str(r["id"]), start = String(Rota.str(r["period_start"]).prefix(10)), last = String(Rota.str(r["period_end"]).prefix(10))
            guard !id.isEmpty, !start.isEmpty, !last.isEmpty else { return nil }
            var summary: [String: CmsJSON] = [:]
            if case .string(let s)? = r["summary"], let d = s.data(using: .utf8), let o = (try? JSONDecoder().decode(CmsJSON.self, from: d))?.objectValue { summary = o }
            else if let o = r["summary"]?.objectValue { summary = o }
            return RotaRow(id: id, start: start, last: last, cadence: Rota.str(r["cadence"]), status: Rota.str(r["status"]).isEmpty ? "draft" : Rota.str(r["status"]),
                           madeBy: Rota.str(r["made_by"]), summary: summary, builtBy: Rota.str(r["built_by"]), builtAt: Rota.str(r["built_at"]),
                           publishedBy: Rota.str(r["published_by"]), publishedAt: Rota.str(r["published_at"]))
        }
    }

    var period: Rota.Period { Rota.periodFor(anchor, mode: mode) }
    var lastDay: String { Rota.addDays(period.start.isEmpty ? anchor : period.end, -1) }
    var word: String { mode == "week" ? "week" : "month" }
    var rangeKey: String { "\(account)|\(period.start)|\(period.end)" }

    // MARK: - The plan

    var planKey: String { Rota.planId(account, mode, period.start) }
    var savedPlanRow: [String: CmsJSON]? { rows("plansQuerySlug")?.first { Rota.str($0["id"]) == planKey } }
    var earlierPlanRow: [String: CmsJSON]? {
        (rows("plansQuerySlug") ?? []).filter { String(Rota.str($0["period_start"]).prefix(10)) < period.start }.sorted { a, b in
            let ma = Rota.str(a["mode"]) == mode ? 0 : 1, mb = Rota.str(b["mode"]) == mode ? 0 : 1
            return ma != mb ? ma < mb : Rota.str(a["period_start"]) > Rota.str(b["period_start"])
        }.first
    }
    var plan: Rota.Plan {
        if let l = localPlan, l.key == planKey { return l.plan }
        if let saved = savedPlanRow { return Rota.plan(saved) }
        if let e = earlierPlanRow { return Rota.carryPlan(Rota.plan(e), from: Rota.str(e["mode"]) == "month" ? "month" : "week", to: period) }
        return Rota.Plan()
    }
    var planOrigin: String {
        if let l = localPlan, l.key == planKey { return planSaving ? "Saving…" : "Saved." }
        if let saved = savedPlanRow {
            let at = Impact.date(Rota.str(saved["updated_at"])).map { $0.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "en_GB"))) } ?? ""
            return "Saved \(at)\(Rota.str(saved["updated_by"]) == "ask wac" ? " by ask wac" : "")."
        }
        if let e = earlierPlanRow {
            let label = Rota.str(e["mode"]) == "month" ? Rota.periodFor(Rota.str(e["period_start"]), mode: "month").label
                : CmsRotaTeamBlockView.rangeLabel(String(Rota.str(e["period_start"]).prefix(10)), String(Rota.str(e["period_end"]).prefix(10)))
            return "Started from your plan for \(label): change anything that's different this \(word)."
        }
        return ""
    }

    func changePlan(_ next: Rota.Plan) {
        localPlan = (planKey, next)
        pendingPlan = (planKey, next, period)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushPlan()
        }
    }

    func flushPlan() async {
        saveTask?.cancel()
        saveTask = nil
        guard let p = pendingPlan else { return }
        pendingPlan = nil
        await savePlanNow(p.key, p.plan, p.period)
    }

    private func savePlanNow(_ key: String, _ next: Rota.Plan, _ per: Rota.Period) async {
        guard !account.isEmpty, !text("planSaveMutationSlug").isEmpty else { return }
        planSaving = true
        do {
            try await run("planSaveMutationSlug", [
                "id": T.s(key), "company_id": T.s(account), "mode": T.s(per.mode), "period_start": T.d(per.start), "period_end": T.d(Rota.addDays(per.end, -1)),
                "plan": T.s(Rota.planToJson(next)), "budget_gbp": T.f(next.budgetGbp), "budget_hours": T.f(next.budgetHours),
                "updated_by": T.s(email), "updated_at": T.ts(ISO8601DateFormatter().string(from: Date())),
            ])
            runtime?.invalidate(text("plansQuerySlug"))
        } catch {
            notice = Notice(tone: "error", text: "The plan wasn't saved: \(error.localizedDescription).")
        }
        planSaving = false
    }

    private func ensurePlanSaved() async {
        if pendingPlan != nil { await flushPlan() }
        else if savedPlanRow == nil && (!plan.shifts.isEmpty || plan.budgetGbp != nil) { await savePlanNow(planKey, plan, period) }
    }

    private func commitPlan(_ next: Rota.Plan) async {
        saveTask?.cancel()
        pendingPlan = nil
        localPlan = (planKey, next)
        await savePlanNow(planKey, next, period)
    }

    // MARK: - Derived

    func inSite(_ s: Rota.Shift) -> Bool { siteId.isEmpty || s.siteId.isEmpty || s.siteId == siteId }
    var visible: [Rota.Shift] { shifts.filter(inSite).sorted(by: Rota.compare) }
    var inPeriod: [Rota.Shift] { visible.filter { $0.date >= period.start && $0.date < period.end } }
    var shown: [Rota.Person] { people.filter { siteId.isEmpty || $0.siteId.isEmpty || $0.siteId == siteId } }
    var inputs: (types: [Rota.ShiftType], needs: [Rota.Need], busy: [Rota.Busy]) { Rota.planInputs(plan) }
    var budget: Rota.Budget { Rota.budgetOf(plan, period) }
    var context: Rota.Context {
        let i = inputs
        return Rota.Context(period: period, people: people, types: i.types, needs: i.needs, busy: i.busy, timeOff: timeOff, budget: budget, siteId: siteId)
    }
    var warnings: [Rota.Warning] { loadedFor == rangeKey ? Rota.check(visible, context) : [] }
    var summary: Rota.Summary { Rota.summarise(visible, context) }
    var averageRate: Double {
        let r = shown.map(\.rate).filter { $0 > 0 }
        return r.isEmpty ? 0 : r.reduce(0, +) / Double(r.count)
    }
    var overlapping: [RotaRow] { rotas.filter { $0.start <= lastDay && $0.last >= period.start } }
    var active: RotaRow? {
        let withShifts = Set(inPeriod.map(\.rotaId))
        return overlapping.first { $0.start == period.start && $0.last == lastDay }
            ?? overlapping.first { $0.start <= period.start && $0.last >= lastDay }
            ?? overlapping.first { withShifts.contains($0.id) }
    }
    var drafts: [RotaRow] {
        let withShifts = Set(inPeriod.map(\.rotaId))
        let a = active
        return overlapping.filter { $0.status != "published" && (withShifts.contains($0.id) || $0 == a) }
    }
    var status: String {
        if inPeriod.isEmpty && active == nil { return "none" }
        return !drafts.isEmpty || inPeriod.contains { $0.rotaStatus != nil && $0.rotaStatus != "published" } ? "draft" : "published"
    }
    var lastPublished: (at: String, by: String) {
        let at = overlapping.map(\.publishedAt).filter { !$0.isEmpty }.sorted().last ?? ""
        return (at, overlapping.first { $0.publishedAt == at }?.publishedBy ?? "")
    }
    func typeOf(_ id: String) -> Rota.ShiftType? { inputs.types.first { $0.id == id } }
    func nameOf(_ code: String) -> String { people.first { $0.code == code }?.name ?? shifts.first { $0.code == code }?.name ?? code }

    // MARK: - Running things

    enum T {
        static func s(_ v: String?) -> CmsJSON { .object(["value": v.flatMap { $0.isEmpty ? nil : CmsJSON.string($0) } ?? .null, "type": .string("string")]) }
        static func d(_ v: String) -> CmsJSON { .object(["value": .string(v), "type": .string("date")]) }
        static func f(_ v: Double?) -> CmsJSON { .object(["value": v.map { .string(Rota.fmt($0)) } ?? .null, "type": .string("float")]) }
        static func i(_ v: Int) -> CmsJSON { .object(["value": .string(String(v)), "type": .string("integer")]) }
        static func ts(_ v: String?) -> CmsJSON { .object(["value": v.flatMap { $0.isEmpty ? nil : CmsJSON.string($0) } ?? .null, "type": .string("timestamp")]) }
    }

    func run(_ key: String, _ params: [String: CmsJSON]) async throws {
        guard let runtime, !text(key).isEmpty else { throw CmsClientError.queryFailed("Not set up to save.") }
        if case .failed(let message) = await runtime.runMutation(text(key), params: params) {
            throw CmsClientError.queryFailed(CmsQueryErrorText.main(message))
        }
    }

    func withBusy(_ label: String, _ job: @escaping () async throws -> Void) {
        busyText = label
        notice = nil
        Task {
            do { try await job() } catch { notice = Notice(tone: "error", text: error.localizedDescription) }
            busyText = ""
        }
    }

    func fetchShifts(_ from: String, _ to: String) async throws -> [Rota.Shift] {
        guard let runtime, !text("shiftsQuerySlug").isEmpty, !account.isEmpty else { return [] }
        let res = try await runtime.client.runSavedQuery(cmsId: runtime.cmsId, querySlug: text("shiftsQuerySlug"), params: [
            "company_id": T.s(account), "range_from": T.d(from), "range_to": T.d(to),
        ])
        return res.rows.compactMap(Rota.shift)
    }

    func reload() async {
        guard !account.isEmpty else { return }
        let key = rangeKey, p = period
        do {
            let list = try await fetchShifts(Rota.addDays(p.start, -7), Rota.addDays(p.end, 7))
            guard key == rangeKey else { return }
            shifts = list
            loadedFor = key
            error = ""
        } catch {
            self.error = CmsQueryErrorText.describe(error.localizedDescription).message
        }
    }

    private func fetchWorked(_ from: String, _ to: String) async -> [Rota.Shift] {
        guard let runtime, !text("workedQuerySlug").isEmpty, !account.isEmpty,
              let res = try? await runtime.client.runSavedQuery(cmsId: runtime.cmsId, querySlug: text("workedQuerySlug"), params: [
                "shift_from": T.d(from), "shift_to": T.d(to), "all_employees": T.s("1"),
                "employee_code": .object(["values": .array([]), "type": .string("string"), "mode": .string("multi")]),
                "company_id": T.s(account), "company_prefix": T.s(accountPrefix),
              ]) else { return [] }
        return Rota.shiftsFromWorked(res.rows, people: people)
    }

    private func saveRota(_ r: RotaRow, _ change: (inout RotaRow) -> Void = { _ in }) async throws {
        var next = r
        change(&next)
        let summaryText = (try? JSONEncoder().encode(CmsJSON.object(next.summary))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try await run("rotaSaveMutationSlug", [
            "id": T.s(next.id), "company_id": T.s(account), "site_id": T.s(siteId), "period_start": T.d(next.start), "period_end": T.d(next.last),
            "cadence": T.s(next.cadence), "status": T.s(next.status), "made_by": T.s(next.madeBy), "summary": T.s(summaryText),
            "built_by": T.s(next.builtBy), "built_at": T.ts(next.builtAt), "published_by": T.s(next.publishedBy), "published_at": T.ts(next.publishedAt),
        ])
    }

    private func refreshAll() async {
        runtime?.invalidate(text("rotasQuerySlug"))
        await reload()
    }

    private func rotaForPeriod(_ madeBy: String) async throws -> RotaRow {
        if let a = active, a.start <= period.start, a.last >= lastDay { return a }
        let fresh = RotaRow(id: Rota.newId("rota"), start: period.start, last: lastDay, cadence: mode, status: "draft", madeBy: madeBy, summary: [:],
                            builtBy: email, builtAt: ISO8601DateFormatter().string(from: Date()), publishedBy: "", publishedAt: "")
        try await saveRota(fresh)
        return fresh
    }

    private func markChanged(_ rotaId: String) async throws {
        if let r = rotas.first(where: { $0.id == rotaId }), r.status == "published" { try await saveRota(r) { $0.status = "draft" } }
    }

    private func summaryJSON(_ base: [String: CmsJSON], _ s: Rota.Summary) -> [String: CmsJSON] {
        var o = base
        o["hours"] = .number(s.hours); o["cost"] = .number(s.cost); o["shifts"] = .number(Double(s.shifts)); o["open"] = .number(Double(s.open))
        return o
    }

    /// Put a whole new set of shifts in the period, as a draft.
    private func replacePeriod(_ next: [Rota.Shift], madeBy: String) async throws -> Rota.Summary {
        let target = try await rotaForPeriod(madeBy)
        var touched: [String] = [target.id]
        for id in inPeriod.map(\.rotaId) where !id.isEmpty && !touched.contains(id) { touched.append(id) }
        for id in touched {
            try await run("shiftsClearMutationSlug", ["rota_id": T.s(id), "range_from": T.d(period.start), "range_to": T.d(period.end)])
        }
        let rows = next.map { s -> CmsJSON in var x = s; x.rotaId = target.id; return Rota.shiftRow(x) }
        var i = 0
        while i < rows.count {
            busyText = "Saving shifts \(min(i + 60, rows.count)) of \(rows.count)…"
            let chunk = Array(rows[i..<min(i + 60, rows.count)])
            let text = (try? JSONEncoder().encode(CmsJSON.array(chunk))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try await run("shiftsAddManyMutationSlug", ["rota_id": T.s(target.id), "company_id": T.s(account), "shifts": T.s(text)])
            i += 60
        }
        for r in overlapping where r.id != target.id && r.start >= period.start && r.last <= lastDay {
            try await run("rotaDiscardMutationSlug", ["id": T.s(r.id)])
        }
        let sum = Rota.summarise(next, context)
        let now = ISO8601DateFormatter().string(from: Date())
        let me = email
        try await saveRota(target) { r in
            r.status = "draft"; r.madeBy = madeBy; r.builtBy = me; r.builtAt = now
            r.summary = self.summaryJSON(r.summary, sum)
        }
        await refreshAll()
        return sum
    }

    private func confirmReplace(_ what: String, _ go: @escaping () -> Void) {
        let n = inPeriod.count
        guard n > 0 else { go(); return }
        confirm = Confirm(title: "\(what) \(period.label)?",
                          text: "This replaces the \(n) shift\(n == 1 ? "" : "s") already planned for this \(word). It stays a draft until you publish it.",
                          confirm: what, run: go)
    }

    private func withHistory(_ base: Rota.Plan) async -> Rota.Plan {
        guard base.shifts.isEmpty else { return base }
        let usual = Rota.planFromWorked(await fetchWorked(Rota.addDays(period.start, -28), period.start)).map { s -> Rota.PlanShift in var x = s; x.suggested = true; return x }
        guard !usual.isEmpty else { return base }
        var next = base
        next.shifts = usual
        next.suggestion = Rota.Suggestion(from: ["your last 4 weeks"], at: ISO8601DateFormatter().string(from: Date()), cells: Rota.suggestionCells(usual), note: "")
        return next
    }

    // MARK: - Actions

    func build() {
        let team = shown
        guard !people.isEmpty else {
            notice = Notice(tone: "info", text: "There are no active employees to put on the rota yet. Add them on Employees.")
            return
        }
        confirmReplace("Build") { [self] in
            withBusy("Building the \(word)…") { [self] in
                var usePlan = plan
                if inputs.types.isEmpty {
                    usePlan = await withHistory(plan)
                    if usePlan.shifts.isEmpty {
                        let fromTeam = Rota.planFromTeam(team)
                        usePlan.shifts = fromTeam
                        usePlan.suggestion = Rota.Suggestion(from: ["your team’s preferences"], at: ISO8601DateFormatter().string(from: Date()),
                                                             cells: Rota.suggestionCells(fromTeam), note: "")
                    }
                    await commitPlan(usePlan)
                } else {
                    await ensurePlanSaved()
                }
                let i = Rota.planInputs(usePlan)
                let fixed = visible.filter { $0.date < period.start || $0.date >= period.end }
                let result = Rota.build(period: period, rotaId: "", people: team, types: i.types, needs: i.needs, busy: i.busy,
                                        timeOff: timeOff, budget: budget, siteId: siteId, fixed: fixed)
                why = result.why
                let sum = try await replacePeriod(result.shifts, madeBy: "build")
                notice = Notice(tone: sum.open > 0 ? "warning" : "success",
                                text: "Built \(sum.shifts) shift\(sum.shifts == 1 ? "" : "s") for \(period.label)\(sum.open > 0 ? ", \(sum.open) still open" : ""). It's a draft until you publish it.")
            }
        }
    }

    func copyLast() {
        confirmReplace("Copy last \(word) into") { [self] in
            withBusy("Copying last \(word)…") { [self] in
                let prev = Rota.movePeriod(period, by: -1)
                var source = try await fetchShifts(prev.start, prev.end).filter(inSite)
                var from = "last \(word)'s rota"
                if source.isEmpty {
                    let types = inputs.types
                    source = await fetchWorked(prev.start, prev.end).map { s in
                        var x = s
                        if let t = types.first(where: { $0.start == s.start && $0.end == s.end }) { x.typeId = t.id }
                        return x
                    }
                    from = "what was worked last \(word) (wac in to wac out)"
                }
                guard !source.isEmpty else {
                    notice = Notice(tone: "info", text: "Nothing to copy: there's no rota and nothing worked for \(prev.label). Build the \(word) instead.")
                    return
                }
                let copies = Rota.copyForward(source, to: period, people: shown, timeOff: timeOff, rotaId: "")
                let sum = try await replacePeriod(copies, madeBy: "copy")
                why = [:]
                notice = Notice(tone: sum.open > 0 ? "warning" : "success",
                                text: "Copied \(from): \(sum.shifts) shift\(sum.shifts == 1 ? "" : "s")\(sum.open > 0 ? ", \(sum.open) now open because someone can't work them" : ""). It's a draft until you publish it.")
            }
        }
    }

    func publish() {
        let errors = warnings.filter { $0.severity == "error" }.count
        let open = summary.open
        let go = { [self] in
            withBusy("Publishing…") { [self] in
                guard let runtime, !text("reconcileStoreSlug").isEmpty else { throw CmsClientError.queryFailed("Not set up to publish.") }
                let now = ISO8601DateFormatter().string(from: Date())
                let targets = drafts.isEmpty ? (active.map { [$0] } ?? []) : drafts
                for r in targets {
                    let own = try await fetchShifts(r.start, Rota.addDays(r.last, 1)).filter { $0.rotaId == r.id }
                    let types = inputs.types, siteList = sites, names = Dictionary(people.map { ($0.code, $0.name) }, uniquingKeysWith: { a, _ in a })
                    let csv = Rota.csv(own, nameOf: { names[$0] ?? $0 }, typeName: { id in types.first { $0.id == id }?.name ?? "" },
                                       siteName: { id in siteList.first { $0.id == id }?.name ?? "" })
                    let filename = "Rota \(CmsRotaTeamBlockView.rangeLabel(r.start, r.last)) \(r.start.prefix(4)) (wac Scheduling).csv"
                    let store = text("reconcileStoreSlug")
                    let res = try await runtime.client.raw(filePath(store, query: ["filename": filename, "partition": account]),
                                                           method: "POST", data: Data(csv.utf8), contentType: "text/csv")
                    guard let file = (try JSONDecoder().decode(CmsJSON.self, from: res)).objectValue?["file"].flatMap(CmsFileRecord.init) else { continue }
                    let weekly = r.cadence.hasPrefix("week") && Rota.weekdayOf(r.start) == "mon" && Rota.datesBetween(r.start, Rota.addDays(r.last, 1)).count == 7
                    var meta: [String: CmsJSON] = ["kind": .string(text("reconcileKind", "rota")), "source": .string("scheduling"), "rota_id": .string(r.id)]
                    if weekly { meta[text("reconcileWeekKey", "week")] = .string(r.start) } else { meta["from"] = .string(r.start); meta["to"] = .string(r.last) }
                    _ = try await runtime.client.json(filePath(store, file.id, query: ["partition": account]), method: "PATCH", body: ["metadata": .object(meta)])
                    if case .array(let old)? = r.summary["files"] {
                        for id in old.map({ $0.displayString }) where id != file.id {
                            _ = try? await runtime.client.raw(filePath(store, id, query: ["partition": account]), method: "DELETE")
                        }
                    }
                    var ctx = context
                    ctx.period = Rota.Period(mode: period.mode, start: r.start, end: Rota.addDays(r.last, 1), label: period.label)
                    let sum = Rota.summarise(own, ctx)
                    let me = email
                    try await saveRota(r) { x in
                        x.status = "published"; x.publishedBy = me; x.publishedAt = now
                        x.summary = self.summaryJSON(x.summary, sum)
                        x.summary["files"] = .array([.string(file.id)])
                    }
                }
                await refreshAll()
                notice = Notice(tone: "success", text: "Published. \(period.label) is now the company's rota, and it's on Reconcile to check against what's worked.")
            }
        }
        if open > 0 || errors > 0 {
            let parts = [open > 0 ? "\(open) shift\(open == 1 ? " is" : "s are") still open" : "",
                         errors > 0 ? "\(errors) thing\(errors == 1 ? "" : "s") break\(errors == 1 ? "s" : "") a rule" : ""].filter { !$0.isEmpty }
            confirm = Confirm(title: "Publish \(period.label)?",
                              text: parts.joined(separator: " and ") + ". You can still publish and fix them after; publishing again updates Reconcile.",
                              confirm: "Publish", run: go)
        } else {
            go()
        }
    }

    func saveShift(_ s: Rota.Shift) {
        withBusy("Saving…") { [self] in
            let rotaId = s.rotaId.isEmpty ? try await rotaForPeriod("hand").id : s.rotaId
            let person = people.first { $0.code == s.code }
            let hours = Rota.paidHours(s.start, s.end, s.breakMinutes)
            let cost = person.map { Rota.round2(hours * $0.rate) } ?? 0
            try await run("shiftSaveMutationSlug", [
                "id": T.s(s.id), "rota_id": T.s(rotaId), "company_id": T.s(account), "site_id": T.s(s.siteId), "employee_code": T.s(s.code),
                "shift_date": T.d(s.date), "start_time": T.s(s.start), "end_time": T.s(s.end), "break_minutes": T.i(s.breakMinutes),
                "shift_type_id": T.s(s.typeId), "skill": T.s(s.skill), "hours": T.f(hours), "cost": T.f(cost),
                "source": T.s(s.source.isEmpty ? "hand" : s.source), "note": T.s(s.note),
            ])
            try await markChanged(rotaId)
            edit = nil
            await refreshAll()
        }
    }

    func removeShift(_ s: Rota.Shift) {
        withBusy("Removing…") { [self] in
            try await run("shiftRemoveMutationSlug", ["id": T.s(s.id)])
            try await markChanged(s.rotaId)
            edit = nil
            await refreshAll()
        }
    }

    /// The web's drag: a shift to another day or person.
    func move(_ s: Rota.Shift, code: String? = nil, date: String? = nil) {
        var next = s
        if let code { next.code = code }
        if let date { next.date = date }
        guard next.code != s.code || next.date != s.date else { return }
        if s.source == "build" || s.source == "copy" { next.source = "hand" }
        saveShift(next)
    }

    // MARK: - The plan's sources and ask wac

    private func ask(_ prompt: String) { runtime?.ask(chat: text("askChat"), prompt: prompt) }

    private func planPrompt(intro: String, readStep: String, kind: String, name: String) -> String {
        let p = period, last = lastDay
        let unit = word
        func j(_ s: String) -> String { (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(s)\"" }
        let five = p.mode == "week"
            ? "Each weekday is one date this week, so set each shift's people on each day to what that date needs, from the usual numbers and what is on."
            : "Set each shift's people per weekday to a typical week of the month, and add a special day for each date that needs more or fewer people than its weekday usually does."
        let extra = p.mode == "week" ? "0, since the day's numbers already cover it" : "people to add to each shift that day, negative for fewer"
        return [
            intro, "", "```steps",
            "In wac, \"wac in\" means clocking in and \"wac out\" means clocking out: always use those words.",
            "The plan is for \(p.mode == "week" ? "the week of \(p.label)" : p.label): \(p.mode) from \(p.start) to \(last). Its id is \"\(planKey)\", company_id \"\(account)\", mode \"\(p.mode)\", period_start \(p.start), period_end \(last).",
            "1. Read the plan with read_query \"rota_plans_for_selected_company\" (the row with that id). Its plan column is JSON: shifts [{id, name, start, end, breakMinutes, people: {mon..sun}, skill, skillPeople, siteId, suggested}], special days [{id, date, label, extra, shiftId, suggested}], sources, and suggestion {from, at, cells, note}.",
            "2. \(readStep)",
            "3. Read what was worked in the four weeks before with read_query \"shifts_by_day\" (params {\"shift_from\": \"\(Rota.addDays(p.start, -28))\", \"shift_to\": \"\(p.start)\", \"all_employees\": \"1\"}): the usual start and end times, and how many people usually work each weekday.",
            "4. Work out what is on each day from \(p.start) to \(last): bookings, events, parties, functions, closures, and how big each is. Keep no customer names, emails or phone numbers.",
            "5. Make step 2 your smart suggestion for this \(unit). Keep the shifts already in the plan (and their ids) unless they plainly don't fit; if there are none, add the usual shifts from step 3, or from the document's opening hours, each {\"id\": \"<a new short id>\", \"name\": \"<Early, Late…>\", \"start\": \"HH:MM\", \"end\": \"HH:MM\", \"breakMinutes\": 30, \"people\": {\"mon\": 0, …}, \"skill\": \"\", \"skillPeople\": 0, \"siteId\": \"\", \"suggested\": true}. \(five) Add a special day {\"id\": \"<a new short id>\", \"date\": \"YYYY-MM-DD\", \"label\": \"<what is on, in a few words, like 3 parties · 90 guests>\", \"extra\": <\(extra)>, \"shiftId\": \"<the one shift it affects, or \"\">\", \"suggested\": true} for each busy or unusual date, so it shows over the rota.",
            "6. Set \"suggestion\": {\"from\": [<what you used, like \"your last 4 weeks\", \(j(name))>], \"at\": \"<now, ISO>\", \"cells\": [<\"<shift id>|<mon, tue, wed, thu, fri, sat or sun>\" for every number you set or changed>], \"note\": \"<the main reason in at most six words, like Saturday busier: 3 parties>\"}.",
            "7. Save it with the rota_plan_save action: the same id, company_id, mode, period_start and period_end; plan = the whole plan as JSON, with {\"kind\": \"\(kind)\", \"name\": \(j(name)), \"at\": \"<now, ISO>\"} added to its sources; budget_gbp \(plan.budgetGbp.map(Rota.fmt) ?? "null") and budget_hours \(plan.budgetHours.map(Rota.fmt) ?? "null") as they are; updated_by \"ask wac\".",
            "8. Tell me in two short lines what you suggested and why, and that it is ready to check in step 2 before \"Build this \(unit)\".",
            "```",
        ].joined(separator: "\n")
    }

    private func askIntoPlan(name: String, kind: String, intro: String, readStep: String) async {
        await flushPlan()
        await commitPlan(await withHistory(plan))
        reading = (planKey, name, ISO8601DateFormatter().string(from: Date()))
        ask(planPrompt(intro: intro, readStep: readStep, kind: kind, name: name))
    }

    func uploadDocs(_ urls: [URL]) {
        withBusy(urls.count > 1 ? "Uploading \(urls.count) files…" : "Uploading \(urls.first?.lastPathComponent ?? "")…") { [self] in
            guard let runtime, !text("planStoreSlug").isEmpty else { throw CmsClientError.queryFailed("Not set up to upload.") }
            let store = text("planStoreSlug")
            var uploaded: [(name: String, id: String)] = []
            for (i, url) in urls.enumerated() {
                if urls.count > 1 { busyText = "Uploading \(i + 1) of \(urls.count): \(url.lastPathComponent)…" }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let res = try await runtime.client.raw(filePath(store, query: ["filename": url.lastPathComponent, "partition": account]),
                                                       method: "POST", data: data, contentType: "application/octet-stream")
                guard let file = (try JSONDecoder().decode(CmsJSON.self, from: res)).objectValue?["file"].flatMap(CmsFileRecord.init) else { continue }
                _ = try await runtime.client.json(filePath(store, file.id, query: ["partition": account]), method: "PATCH", body: [
                    "metadata": .object(["kind": .string("rota_plan"), "mode": .string(period.mode), "plan_from": .string(period.start), "plan_to": .string(lastDay)]),
                ])
                uploaded.append((url.lastPathComponent, file.id))
            }
            guard !uploaded.isEmpty else { return }
            let names = uploaded.map { "\"\($0.name)\"" }.joined(separator: ", ")
            let label = uploaded.count > 1 ? "\(uploaded.count) files" : uploaded[0].name
            await askIntoPlan(
                name: label, kind: "file",
                intro: "I've uploaded \(names) for \(period.mode == "week" ? "the week of \(period.label)" : period.label). Suggest the shifts we need from \(uploaded.count > 1 ? "them" : "it").",
                readStep: "Read \(uploaded.map { "\"\($0.name)\" (file \($0.id))" }.joined(separator: ", ")) in the \(store) store with read_stored_file, each in turn. They may be anything that helps: a booking or till export, an old rota, an event list, opening hours, a photo or a scan. Take from each what tells you how busy each day is or how the team usually works, and say if one tells you nothing.")
        }
    }

    func tell(_ note: String) {
        withBusy("Sending to ask wac…") { [self] in
            await askIntoPlan(name: "your note", kind: "note", intro: "For \(period.mode == "week" ? "the week of \(period.label)" : period.label): \(note)",
                              readStep: "What is on is in my message above. Ask me only if a date or a number is unclear.")
        }
    }

    func startFromWorked() {
        withBusy("Reading the last four weeks…") { [self] in
            var empty = plan
            empty.shifts = []
            let next = await withHistory(empty)
            guard !next.shifts.isEmpty else {
                notice = Notice(tone: "info", text: "No worked shifts in the last four weeks to start from. Add your shifts with the buttons instead.")
                return
            }
            await commitPlan(next)
        }
    }

    func saveSource(kind: String, name: String, address: String, note: String = "") {
        withBusy("Saving…") { [self] in
            try await run("sourceSaveMutationSlug", [
                "id": T.s(Rota.newId("src")), "company_id": T.s(account), "kind": T.s(kind), "name": T.s(name), "address": T.s(address),
                "status": T.s(kind == "calendar" ? "saved" : "requested"), "note": T.s(note), "created_by": T.s(email),
                "created_at": T.ts(ISO8601DateFormatter().string(from: Date())),
            ])
            runtime?.invalidate(text("sourcesQuerySlug"))
            if kind == "calendar" && plan.shifts.isEmpty {
                let next = await withHistory(plan)
                if next != plan { await commitPlan(next) }
            }
        }
    }

    func removeSource(_ id: String) {
        withBusy("Removing…") { [self] in
            try await run("sourceRemoveMutationSlug", ["id": T.s(id)])
            runtime?.invalidate(text("sourcesQuerySlug"))
        }
    }

    func filePath(_ store: String, _ fileId: String? = nil, query: [String: String?] = [:]) -> String {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s }
        var p = "/v1/cms-definitions/\(enc(runtime?.cmsId ?? ""))/files/\(enc(store))"
        if let fileId { p += "/\(enc(fileId))" }
        var items = query
        items["siteKeyId"] = runtime?.client.siteKeyId
        let q = items.compactMap { k, v in v.flatMap { $0.isEmpty ? nil : "\(k)=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? $0)" } }
        return q.isEmpty ? p : p + "?" + q.sorted().joined(separator: "&")
    }
}
