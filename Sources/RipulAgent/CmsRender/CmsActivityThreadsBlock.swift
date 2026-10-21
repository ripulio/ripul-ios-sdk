import SwiftUI

/// Native twin of `activityThreads` (ActivityThreadsBlock.tsx +
/// activityThreads.ts): the team, active and not active, each with their
/// latest entry; picking someone shows everything logged about them as a
/// conversation — wac's own entries on the left, the team's on the right.
/// Reads two queries, writes nothing.
///
/// Semantics: `buildPeople` (match by employee code, else a unique first
/// name; unmatched entries still get a row; most recent first), `isActive`,
/// `isFromWac`, `groupByDay`, `shortWhen`, `senderName`, `shiftLabel`.
/// Presentation: the Messages pattern — a people list with search and a
/// "Not active" disclosure, the conversation in a sheet starting at the
/// latest entry (the web's phone layout also takes turns).
struct CmsActivityThreadsBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var search = ""
    @State private var showInactive = false
    @State private var selected: Person?

    struct Entry: Identifiable, Equatable {
        var id: String
        var at: Date
        var kind: String
        var kindLabel: String
        var person: String
        var employeeCode: String
        var shiftDate: String
        var text: String
        var detail: String
        var by: String
        var fromWac: Bool
    }

    struct Person: Identifiable, Equatable {
        var id: String
        var name: String
        var firstName: String
        var employeeCode: String
        var headshot: String
        var job: String
        var active: Bool
        var entries: [Entry] = []
        var last: Entry? { entries.last }
    }

    private var props: [String: CmsJSON] { block.props }
    private var peopleSlug: String { props.string("peopleQuerySlug") ?? "" }
    private var logSlug: String { props.string("logQuerySlug") ?? "" }
    private var email: String { runtime.client.userEmail ?? runtime.membership?.email ?? "" }

    // MARK: - activityThreads.ts

    private static func str(_ v: CmsJSON?) -> String {
        guard let v, v != .null else { return "" }
        return v.displayString.trimmingCharacters(in: .whitespaces)
    }

    static func isFromWac(_ by: String) -> Bool {
        let b = by.lowercased()
        return b.isEmpty || b.hasPrefix("wac") || b.hasPrefix("seen on the") || b == "location check"
    }

    static func entry(_ r: [String: CmsJSON]) -> Entry? {
        guard let at = Impact.date(str(r["at"])) else { return nil }
        let by = str(r["by"])
        return Entry(
            id: str(r["id"]).isEmpty ? "\(str(r["at"]))-\(str(r["text"]))" : str(r["id"]),
            at: at, kind: str(r["kind"]),
            kindLabel: str(r["kind_label"]).isEmpty ? str(r["kind"]) : str(r["kind_label"]),
            person: str(r["person"]), employeeCode: str(r["employee_code"]), shiftDate: str(r["shift_date"]),
            text: str(r["text"]), detail: str(r["detail"]), by: by, fromWac: isFromWac(by)
        )
    }

    static func isActive(_ status: CmsJSON?) -> Bool {
        let s = str(status).lowercased()
        return s.isEmpty || s == "active"
    }

    static func buildPeople(_ employees: [[String: CmsJSON]], _ log: [[String: CmsJSON]]) -> [Person] {
        var people: [Person] = []
        var byCode: [String: Int] = [:]
        var byFirst: [String: [Int]] = [:]
        for e in employees {
            let name = str(e["Name"] ?? e["name"])
            guard !name.isEmpty else { continue }
            let code = str(e["employee_code"])
            let first = String(name.split(whereSeparator: \.isWhitespace).first ?? "")
            people.append(Person(id: code.isEmpty ? "name:\(name)" : code, name: name, firstName: first, employeeCode: code,
                                 headshot: str(e["headshot"]), job: str(e["job_name"]), active: isActive(e["status"])))
            let i = people.count - 1
            if !code.isEmpty { byCode[code] = i }
            byFirst[first.lowercased(), default: []].append(i)
        }
        for r in log {
            guard let entry = entry(r) else { continue }
            var index = entry.employeeCode.isEmpty ? nil : byCode[entry.employeeCode]
            if index == nil, !entry.person.isEmpty {
                let first = String(entry.person.split(whereSeparator: \.isWhitespace).first ?? "").lowercased()
                if let same = byFirst[first], same.count == 1 { index = same[0] }
            }
            if index == nil {
                let name = entry.person.isEmpty ? "Someone" : entry.person
                let first = String(name.split(whereSeparator: \.isWhitespace).first ?? "")
                people.append(Person(id: entry.employeeCode.isEmpty ? "name:\(name)" : entry.employeeCode, name: name,
                                     firstName: first, employeeCode: entry.employeeCode, headshot: "", job: "", active: true))
                index = people.count - 1
                if !entry.employeeCode.isEmpty { byCode[entry.employeeCode] = index }
                byFirst[first.lowercased()] = [index!]
            }
            people[index!].entries.append(entry)
        }
        for i in people.indices { people[i].entries.sort { $0.at < $1.at } }
        // Most recent activity first, then everyone else by name.
        return people.sorted { a, b in
            let at = a.last?.at ?? .distantPast, bt = b.last?.at ?? .distantPast
            return at != bt ? at > bt : a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    static func dayLabel(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        let gb = Locale(identifier: "en_GB")
        return cal.component(.year, from: d) == cal.component(.year, from: now)
            ? d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(gb))
            : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().locale(gb))
    }

    static func shortWhen(_ d: Date, now: Date = Date()) -> String {
        let label = dayLabel(d, now: now)
        if label == "Today" { return d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB"))) }
        if label == "Yesterday" { return label }
        return d.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }

    static func senderName(_ by: String, viewer: String) -> String {
        if by.isEmpty { return "wac" }
        if !viewer.isEmpty, by.lowercased() == viewer.lowercased() { return "You" }
        if by.contains("@") {
            let local = (by.split(separator: "@").first.map(String.init) ?? "").split(separator: "+").first.map(String.init) ?? ""
            let spaced = local.replacingOccurrences(of: "[._-]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            return spaced.isEmpty ? by : spaced.capitalized
        }
        return by
    }

    static func shiftLabel(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(iso.prefix(10))) else { return "" }
        return "Shift on " + d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }

    // MARK: - View

    private func rows(_ slug: String) -> [[String: CmsJSON]]? {
        guard !slug.isEmpty, case .ok(let r) = runtime.state(for: slug) else { return nil }
        return r.rows
    }

    var body: some View {
        let peopleRows = rows(peopleSlug), logRows = rows(logSlug)
        let loading = peopleRows == nil || logRows == nil
        let people = Self.buildPeople(peopleRows ?? [], logRows ?? [])
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = { (p: Person) in q.isEmpty || p.name.lowercased().contains(q) || p.job.lowercased().contains(q) }
        let active = people.filter { $0.active && matches($0) }
        let inactive = people.filter { !$0.active && matches($0) }

        VStack(alignment: .leading, spacing: 10) {
            let heading = props.string("heading") ?? "Activity"
            if !heading.isEmpty { Text(heading).font(.system(size: 18, weight: .bold)) }
            if let intro = props.string("intro"), !intro.isEmpty {
                Text(intro).font(.system(size: 13.5)).foregroundColor(runtime.theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(runtime.theme.textSecondary)
                    TextField("Search the team", text: $search).textFieldStyle(.plain)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(runtime.theme.surfaceMuted))
                .padding(12)
                if loading && people.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                } else if people.isEmpty {
                    Text("No one on the team yet.").font(.system(size: 13)).foregroundColor(runtime.theme.textSecondary).padding(16)
                } else {
                    section("Active", active.count)
                    ForEach(active) { personRow($0) }
                    if !inactive.isEmpty {
                        DisclosureGroup(isExpanded: Binding(get: { showInactive || !q.isEmpty }, set: { showInactive = $0 })) {
                            ForEach(inactive) { personRow($0) }
                        } label: {
                            section("Not active", inactive.count)
                        }
                        .padding(.trailing, 12)
                    }
                }
            }
            .padding(.bottom, 8)
            .background(RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous).fill(runtime.theme.paper))
            .overlay(RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous).strokeBorder(runtime.theme.divider))
        }
        .onAppear {
            runtime.ensureLoaded(peopleSlug)
            runtime.ensureLoaded(logSlug)
        }
        .ripulSheet(item: $selected) { person in
            CmsActivityConversation(person: person, viewer: email).environmentObject(runtime)
        }
    }

    private func section(_ label: String, _ n: Int) -> some View {
        Text("\(label.uppercased()) · \(n)")
            .font(.system(size: 11.5, weight: .bold)).tracking(0.8)
            .foregroundColor(runtime.theme.textSecondary)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    private func personRow(_ p: Person) -> some View {
        Button { selected = p } label: {
            HStack(spacing: 10) {
                CmsInitialsAvatar(name: p.name, headshot: p.headshot)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(p.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Spacer()
                        if let last = p.last {
                            Text(Self.shortWhen(last.at)).font(.system(size: 12)).foregroundColor(runtime.theme.textSecondary)
                        }
                    }
                    HStack {
                        Text(p.last?.text ?? (p.active ? "Nothing logged yet" : "Not active"))
                            .font(.system(size: 13)).foregroundColor(runtime.theme.textSecondary).lineLimit(1)
                        Spacer()
                        if !p.entries.isEmpty {
                            Text("\(p.entries.count)").font(.system(size: 11, weight: .bold))
                                .foregroundColor(runtime.theme.primary)
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(Capsule().fill(runtime.theme.tint))
                        }
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .opacity(p.active ? 1 : 0.7)
        }
        .buttonStyle(.plain)
        .cmsInspectorID("Cms.activityThreads.person")
    }
}

/// A person's photo, or their initials on the brand tint.
struct CmsInitialsAvatar: View {
    let name: String
    var headshot: String = ""
    var size: CGFloat = 40
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        let initials = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        let fallback = Text(initials).font(.system(size: size * 0.36, weight: .bold)).foregroundColor(runtime.theme.primary)
            .frame(width: size, height: size).background(Circle().fill(runtime.theme.tint))
        if let url = URL(string: headshot), headshot.hasPrefix("http") {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFill() } else { fallback }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            fallback
        }
    }
}

private struct CmsActivityConversation: View {
    let person: CmsActivityThreadsBlockView.Person
    let viewer: String
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.dismiss) private var dismiss

    private static let tones: [String: String] = [
        "todo_added": "primary", "todo_done": "success", "fixed": "success", "todo_reopened": "warning",
        "todo_removed": "neutral", "message": "info", "variance": "success", "message_sent": "info", "shift_changed": "success",
    ]

    private func tone(_ kind: String) -> Color {
        switch Self.tones[kind] ?? "neutral" {
        case "primary": return runtime.theme.primary
        case "success": return runtime.theme.success
        case "warning": return runtime.theme.warning
        case "info": return runtime.theme.info
        default: return runtime.theme.textSecondary
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if person.entries.isEmpty {
                        Text(person.active ? "Nothing logged about \(person.firstName) yet." : "Not active.")
                            .font(.system(size: 14)).foregroundColor(runtime.theme.textSecondary).padding(.top, 40)
                    }
                    ForEach(groups, id: \.key) { group in
                        Text(group.label).font(.system(size: 12, weight: .semibold)).foregroundColor(runtime.theme.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(runtime.theme.surfaceMuted))
                            .padding(.top, 6)
                        ForEach(group.entries) { bubble($0) }
                    }
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(person.name).font(.system(size: 16, weight: .semibold))
                        Text([person.active ? "Active" : "Not active", person.job,
                              "\(person.entries.count) \(person.entries.count == 1 ? "entry" : "entries")"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundColor(runtime.theme.textSecondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .tint(runtime.theme.primary)
    }

    private var groups: [(key: String, label: String, entries: [CmsActivityThreadsBlockView.Entry])] {
        var out: [(key: String, label: String, entries: [CmsActivityThreadsBlockView.Entry])] = []
        let cal = Calendar.current
        for e in person.entries {
            let c = cal.dateComponents([.year, .month, .day], from: e.at)
            let key = "\(c.year!)-\(c.month!)-\(c.day!)"
            if out.last?.key == key { out[out.count - 1].entries.append(e) }
            else { out.append((key, CmsActivityThreadsBlockView.dayLabel(e.at), [e])) }
        }
        return out
    }

    private func bubble(_ e: CmsActivityThreadsBlockView.Entry) -> some View {
        let mine = !e.fromWac
        let color = tone(e.kind)
        let shift = CmsActivityThreadsBlockView.shiftLabel(e.shiftDate)
        return VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            Text("\(CmsActivityThreadsBlockView.senderName(e.by, viewer: viewer)) · \(e.at.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB"))))")
                .font(.system(size: 11)).foregroundColor(runtime.theme.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(e.kindLabel).font(.system(size: 10.5, weight: .bold)).foregroundColor(color)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.12)))
                    if !shift.isEmpty { Text(shift).font(.system(size: 11)).foregroundColor(runtime.theme.textSecondary) }
                }
                Text(e.text).font(.system(size: 14))
                if !e.detail.isEmpty {
                    if e.kind == "message" {
                        Text(e.detail).font(.system(size: 13)).italic().foregroundColor(runtime.theme.textSecondary)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) { Rectangle().fill(color.opacity(0.45)).frame(width: 3) }
                    } else {
                        Text(e.detail).font(.system(size: 12.5)).foregroundColor(runtime.theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(mine ? runtime.theme.tint : runtime.theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(mine ? runtime.theme.primary.opacity(0.18) : runtime.theme.divider))
            .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .cmsInspectorID("Cms.activityThreads.entry")
    }
}
