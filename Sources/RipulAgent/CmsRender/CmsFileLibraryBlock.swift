import SwiftUI
import UniformTypeIdentifiers
#if canImport(QuickLook)
import QuickLook
#endif

/// Native twin of `fileLibrary` (FileLibraryBlock.tsx + fileWeeks.ts +
/// fileLibraryAccount.ts): a CMS file store as a list, or as weeks of rotas
/// grouped under pay periods.
///
/// Semantics mirrored: the listing with the member's permissions; the bound
/// account for members who reach several; replaced rotas relabelled once by
/// whoever can upload; an upload into a week labels the file with that week
/// and the upload kind; an upload with no week hands the files to the chat
/// with `dropAskPrompt`; week status, pay periods and their figures; the ask
/// buttons fill their prompts (week, period) and send them to the page's chat.
///
/// Presentation: the brand pay-period band with the week dots and an Ask wac
/// menu; week cards; file rows with an Ask menu, Quick Look to open, and a
/// confirmation before delete; uploads through the system file picker (no
/// drop target on a phone). An account picker for members who span accounts
/// with nothing bound is not native yet: they see every account's files.
struct CmsFileLibraryBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    @State private var listing: CmsFileListing?
    @State private var error: String?
    @State private var notice: String?
    @State private var uploading: String?
    @State private var importing = false
    @State private var uploadWeek: CmsFileWeeks.Week?
    @State private var openPeriods: [String: Bool] = [:]
    @State private var confirmDelete: CmsFileRecord?
    @State private var previewURL: URL?
    @State private var busyId: String?
    @State private var relabelled = ""

    private var props: [String: CmsJSON] { block.props }
    private func text(_ key: String, _ fallback: String = "") -> String {
        props.string(key).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
    private var store: String { text("storeSlug") }
    private var weekKey: String { text("weekKey", "week") }
    private var askChat: String { text("askChat") }

    private struct Ask: Hashable { var label: String; var prompt: String }
    private func asks(_ key: String) -> [Ask] {
        guard case .array(let raw) = props[key] ?? .null else { return [] }
        return raw.compactMap { a in
            guard let o = a.objectValue, let l = o.string("label"), let p = o.string("prompt"), !l.isEmpty, !p.isEmpty else { return nil }
            return Ask(label: l, prompt: p)
        }
    }

    /// The bound account, once its tokens resolve.
    private var resolvedAccount: String? {
        let template = text("account")
        guard !template.isEmpty else { return nil }
        let value = runtime.resolveTemplate(template).trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value.contains("@") ? nil : value
    }
    private var focusAccount: String? { listing?.boundAccount(resolvedAccount) }

    private func path(_ fileId: String? = nil, _ sub: String? = nil, query: [String: String?] = [:]) -> String {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s }
        var p = "/v1/cms-definitions/\(enc(runtime.cmsId))/files/\(enc(store))"
        if let fileId { p += "/\(enc(fileId))" }
        if let sub { p += "/\(sub)" }
        var items = query
        items["siteKeyId"] = runtime.client.siteKeyId
        let q = items.compactMap { k, v in v.flatMap { $0.isEmpty ? nil : "\(k)=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? $0)" } }
        return q.isEmpty ? p : p + "?" + q.sorted().joined(separator: "&")
    }

    // MARK: - Data

    private func load() async {
        guard !store.isEmpty else { return }
        do {
            let json = try await runtime.client.json(path(query: ["partition": focusAccount]))
            listing = CmsFileListing(json)
            error = nil
            await relabelReplaced()
        } catch {
            self.error = CmsQueryErrorText.describe(error.localizedDescription).message
        }
    }

    /// A newer rota for a week replaces the older one everywhere.
    private func relabelReplaced() async {
        guard let listing, listing.upload else { return }
        let replaced = CmsFileWeeks.replacedRotas(listing.files, key: weekKey)
        let sig = replaced.map(\.file.id).sorted().joined(separator: ",")
        guard !sig.isEmpty, sig != relabelled else { return }
        relabelled = sig
        for (file, by) in replaced {
            _ = try? await runtime.client.json(path(file.id, query: ["partition": file.partition]), method: "PATCH", body: [
                "metadata": .object(["kind": .string(CmsFileWeeks.replacedKind), "replacedBy": .string(by.id),
                                     "replacedAt": .string(ISO8601DateFormatter().string(from: Date()))]),
            ])
        }
        await load()
    }

    private func upload(_ urls: [URL], week: CmsFileWeeks.Week?) async {
        guard let listing else { return }
        let account = focusAccount ?? (listing.spansAccounts ? resolvedAccount : nil)
        if listing.spansAccounts && account == nil {
            error = "Choose an account first."
            return
        }
        error = nil
        notice = nil
        var dupes: [String] = [], dropped: [(String, String)] = []
        for (i, url) in urls.enumerated() {
            let name = url.lastPathComponent
            uploading = urls.count > 1 ? "\(name) (\(i + 1) of \(urls.count))" : name
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let res = try await runtime.client.raw(path(query: ["filename": name, "partition": account]), method: "POST", data: data, contentType: type)
                let json = try JSONDecoder().decode(CmsJSON.self, from: res).objectValue ?? [:]
                guard let file = json["file"].flatMap(CmsFileRecord.init) else { continue }
                if case .array(let d)? = json["duplicates"], !d.isEmpty { dupes.append(name) }
                if let week {
                    var labels: [String: CmsJSON] = [weekKey: .string(week.start)]
                    if !text("uploadKind").isEmpty { labels["kind"] = .string(text("uploadKind")) }
                    _ = try? await runtime.client.json(path(file.id, query: ["partition": account]), method: "PATCH", body: ["metadata": .object(labels)])
                } else {
                    dropped.append((file.id, name))
                }
            } catch {
                self.error = "Couldn't upload \(name)."
            }
        }
        uploading = nil
        if !dupes.isEmpty { notice = "Already uploaded before: \(dupes.joined(separator: ", ")). Both copies are kept." }
        let dropPrompt = text("dropAskPrompt")
        if !dropped.isEmpty, !dropPrompt.isEmpty, !askChat.isEmpty {
            runtime.ask(chat: askChat, prompt: CmsFileWeeks.fillPrompt(dropPrompt, [
                "files": dropped.map { "- \"\($0.1)\" (file \($0.0))" }.joined(separator: "\n"), "store": store,
            ]))
        }
        await load()
    }

    private func open(_ f: CmsFileRecord) async {
        busyId = f.id
        defer { busyId = nil }
        do {
            let data = try await runtime.client.raw(path(f.id, "content"))
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(f.id, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(f.filename)
            try data.write(to: url)
            previewURL = url
        } catch {
            self.error = "Couldn't open \(f.filename)."
        }
    }

    private func remove(_ f: CmsFileRecord) async {
        busyId = f.id
        defer { busyId = nil }
        do {
            _ = try await runtime.client.raw(path(f.id), method: "DELETE")
            await load()
        } catch {
            self.error = "Couldn't delete \(f.filename)."
        }
    }

    // MARK: - Asking the chat

    private func ask(_ a: Ask, file f: CmsFileRecord, week: CmsFileWeeks.Week?) {
        let now = Date()
        let labelled = CmsFileWeeks.fileWeekStart(f, key: weekKey)
        let w = week ?? labelled.map { CmsFileWeeks.weekOfStart($0, now: now) }
        let cover = CmsFileWeeks.coverage(f, key: weekKey)
        runtime.ask(chat: askChat, prompt: CmsFileWeeks.fillPrompt(a.prompt, [
            "filename": f.filename, "fileId": f.id, "store": store,
            "uploaded": Impact.date(f.createdAt).map { $0.formatted(date: .abbreviated, time: .omitted) },
            "week": w?.start, "weekEnd": w?.end, "weekLabel": w?.label,
            "differencesKey": CmsFileWeeks.resultKey(f, weekStart: w?.start, key: weekKey),
            "valueKey": CmsFileWeeks.resultKey(f, weekStart: w?.start, key: weekKey, name: "differencesValue"),
            "covers": cover.map { CmsFileWeeks.coverageLabel($0, now: now) },
            "today": CmsFileWeeks.iso(now),
        ]))
    }

    private func ask(_ a: Ask, period p: CmsFileWeeks.PayPeriod) {
        let now = Date()
        let lines = p.files.map { f -> String in
            let cover = CmsFileWeeks.coverage(f, key: weekKey)
            return "- \"\(f.filename)\" (file \(f.id)\(cover.map { ", covers \(CmsFileWeeks.coverageLabel($0, now: now))" } ?? ""))"
        }
        runtime.ask(chat: askChat, prompt: CmsFileWeeks.fillPrompt(a.prompt, [
            "periodLabel": p.label, "periodStart": p.start, "periodEnd": p.end, "periodLastDay": p.lastDay,
            "payday": p.payday, "today": CmsFileWeeks.iso(now), "store": store,
            "files": lines.isEmpty ? "(none uploaded)" : lines.joined(separator: "\n"),
        ]))
    }

    // MARK: - View

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !text("heading", "Files").isEmpty { Text(text("heading", "Files")).font(.system(size: 22, weight: .heavy)) }
            if !text("intro").isEmpty { Text(text("intro")).font(.system(size: 14)).foregroundColor(runtime.theme.textSecondary) }
            if store.isEmpty {
                Label("Choose a file store for this block.", systemImage: "info.circle").font(.system(size: 13))
            } else if let listing {
                content(listing)
            } else if let error {
                Text(error).font(.system(size: 14)).foregroundColor(runtime.theme.error)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous).fill(runtime.theme.paper))
        .overlay(RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous).strokeBorder(runtime.theme.divider))
        .task(id: "\(store)|\(focusAccount ?? "")|\(resolvedAccount ?? "")") { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: uploadWeek == nil) { result in
            let week = uploadWeek
            uploadWeek = nil
            if case .success(let urls) = result { Task { await upload(urls, week: week) } }
        }
        .confirmationDialog("Delete \(confirmDelete?.filename ?? "this file")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let f = confirmDelete { Task { await remove(f) } } }
            Button("Keep", role: .cancel) {}
        }
        #if canImport(QuickLook) && os(iOS)
        .quickLookPreview($previewURL)
        #endif
    }

    @ViewBuilder
    private func content(_ listing: CmsFileListing) -> some View {
        let canUpload = listing.upload && (props.bool("allowUpload") ?? true)
        let files = focusAccount.map { a in listing.files.filter { $0.partition == a } } ?? listing.files
        if canUpload && !(props.bool("hideDrop") ?? false) {
            Button {
                uploadWeek = nil
                importing = true
            } label: {
                VStack(spacing: 4) {
                    if let uploading {
                        ProgressView()
                        Text("Uploading \(uploading)").font(.system(size: 14, weight: .bold))
                    } else {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 20, weight: .semibold))
                        Text(text("dropTitle", "Choose files to upload")).font(.system(size: 15, weight: .bold))
                        if !text("dropDetail").isEmpty {
                            Text(text("dropDetail")).font(.system(size: 13)).foregroundColor(runtime.theme.textSecondary)
                        }
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundColor(runtime.theme.primary)
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: runtime.theme.cardRadius).fill(runtime.theme.tint))
                .overlay(RoundedRectangle(cornerRadius: runtime.theme.cardRadius)
                    .strokeBorder(runtime.theme.primary, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            }
            .buttonStyle(.plain)
            .disabled(uploading != nil || runtime.isDesignMode)
            .cmsInspectorID("Cms.fileLibrary.upload")
        }
        if let error { Text(error).font(.system(size: 13)).foregroundColor(runtime.theme.error) }
        if let notice { Text(notice).font(.system(size: 13)).foregroundColor(runtime.theme.textSecondary) }

        if text("layout", "list") == "weeks" {
            weeksView(files, listing: listing, canUpload: canUpload)
        } else if files.isEmpty {
            Text(text("emptyText", "No files yet.")).font(.system(size: 14)).foregroundColor(runtime.theme.textSecondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(files.sorted { $0.createdAt > $1.createdAt }.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Divider() }
                    fileRow(f, week: nil, listing: listing)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(runtime.theme.divider))
        }
    }

    @ViewBuilder
    private func weeksView(_ files: [CmsFileRecord], listing: CmsFileListing, canUpload: Bool) -> some View {
        let now = Date()
        let built = CmsFileWeeks.buildWeeks(files, now: now, ahead: Int(props.double("weeksAhead") ?? 1),
                                            back: Int(props.double("weeksBack") ?? 6), key: weekKey)
        if props.bool("payPeriods") == true {
            let cutoff = CmsFileWeeks.parseCutoffDay(text("periodCutoffDay").isEmpty ? nil : runtime.resolveTemplate(text("periodCutoffDay")))
            let schedule = text("periodPaySchedule").isEmpty ? nil : runtime.resolveTemplate(text("periodPaySchedule"))
            ForEach(CmsFileWeeks.buildPayPeriods(built.weeks, now: now, cutoff: cutoff, paySchedule: schedule)) { period in
                periodView(period, now: now, listing: listing, canUpload: canUpload)
            }
        } else {
            ForEach(built.weeks) { weekCard($0, listing: listing, canUpload: canUpload) }
        }
        if !built.unfiled.isEmpty {
            Text("NOT FILED UNDER A WEEK").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundColor(runtime.theme.textSecondary)
            VStack(spacing: 0) {
                ForEach(Array(built.unfiled.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Divider() }
                    fileRow(f, week: nil, listing: listing)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(runtime.theme.divider))
        }
    }

    private func money(_ amount: Double) -> String {
        let code = text("valueCurrency").uppercased()
        return code.isEmpty ? String(format: "%.2f", amount) : amount.formatted(.currency(code: code))
    }

    private func differencesNote(_ count: Double, _ value: Double?) -> String {
        let n = Int(count)
        return "\(n) variance\(n == 1 ? "" : "s")" + (value.map { " · \(money($0))" } ?? "")
    }

    private func periodView(_ p: CmsFileWeeks.PayPeriod, now: Date, listing: CmsFileListing, canUpload: Bool) -> some View {
        let sum = CmsFileWeeks.summary(p)
        let open = openPeriods[p.start] ?? (p.offset == 0)
        let onBrand = runtime.theme.primaryContrast
        let tag = p.offset == 0 ? "This pay period" : p.offset == 1 ? "Next pay period" : p.offset == -1 ? "Last pay period" : "Pay period"
        func away(_ iso: String) -> String {
            let n = CmsFileWeeks.daysUntil(iso, now: now)
            return n == 0 ? " (today)" : n == 1 ? " (tomorrow)" : (n > 1 && n <= 45 ? " (in \(n) days)" : "")
        }
        let dates = ["Cut-off \(CmsFileWeeks.dayLabel(p.lastDay))\(p.offset == 0 ? away(p.lastDay) : "")",
                     p.payday.map { "Payday \(CmsFileWeeks.dayLabel($0))\(p.offset <= 0 ? away($0) : "")" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        var figures: [(String, String)] = [("\(sum.weeksWithRota)/\(sum.weeksDue)", "rotas in"), ("\(sum.weeksChecked)", "checked"),
                                           ("\(Int(sum.differences))", sum.differences == 1 ? "variance" : "variances")]
        if let v = sum.differencesValue { figures.append((money(v), "at stake")) }
        let alert = runtime.color(text("periodDotColor")) ?? runtime.theme.warning
        let periodAsks = asks("periodAskActions")

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tag.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).opacity(0.85)
                        Text(p.label).font(.system(size: 20, weight: .heavy))
                        Text(dates).font(.system(size: 13)).opacity(0.9)
                    }
                    Spacer()
                    Button {
                        withAnimation(.snappy) { openPeriods[p.start] = !open }
                    } label: {
                        Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                            .font(.system(size: 14, weight: .bold)).frame(width: 32, height: 32)
                            .background(Circle().fill(onBrand.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? "Hide the weeks" : "Show the weeks")
                }
                HStack(spacing: 16) {
                    ForEach(figures, id: \.1) { f in
                        VStack(spacing: 1) {
                            Text(f.0).font(.system(size: 18, weight: .heavy))
                            Text(f.1.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.6).opacity(0.85)
                        }
                    }
                }
                HStack(spacing: 6) {
                    ForEach(p.weeks.reversed()) { w in
                        let st = CmsFileWeeks.status(w)
                        Circle()
                            .fill(dotFill(st, alert: alert, onBrand: onBrand))
                            .overlay(Circle().strokeBorder(dotBorder(st, alert: alert, onBrand: onBrand), lineWidth: 2))
                            .frame(width: 12, height: 12)
                            .accessibilityLabel(w.label)
                    }
                    Spacer()
                    if !askChat.isEmpty && !periodAsks.isEmpty {
                        if p.files.isEmpty {
                            Text("Upload a rota to check this period").font(.system(size: 12.5)).opacity(0.85)
                        } else {
                            Menu {
                                ForEach(periodAsks, id: \.self) { a in Button(a.label) { ask(a, period: p) } }
                            } label: {
                                Label("Ask wac", systemImage: "sparkles")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(runtime.theme.primary)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Capsule().fill(onBrand))
                            }
                            .disabled(runtime.isDesignMode)
                        }
                    }
                }
            }
            .foregroundColor(onBrand)
            .padding(16)
            .background(runtime.theme.gradient, in: RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous))
            .cmsInspectorID("Cms.fileLibrary.period")
            if open {
                // Oldest week first, as the dots read (George, 23 Oct 2026: newest first looked funny).
                ForEach(p.weeks.reversed()) { weekCard($0, listing: listing, canUpload: canUpload) }
            }
        }
    }

    private func dotFill(_ st: CmsFileWeeks.Status, alert: Color, onBrand: Color) -> Color {
        switch st {
        case .matched: return runtime.theme.success
        case .differences: return alert
        case .uploaded, .ready: return onBrand
        case .missing, .due: return .clear
        }
    }

    private func dotBorder(_ st: CmsFileWeeks.Status, alert: Color, onBrand: Color) -> Color {
        switch st {
        case .missing: return alert
        case .due: return onBrand.opacity(0.6)
        default: return .clear
        }
    }

    private func weekCard(_ w: CmsFileWeeks.Week, listing: CmsFileListing, canUpload: Bool) -> some View {
        let st = CmsFileWeeks.status(w)
        let tag = w.offset == 1 ? "Next week" : w.offset == 0 ? "This week" : w.offset == -1 ? "Last week" : ""
        let (mark, note, color): (String, String, Color) = {
            switch st {
            case .due: return ("arrow.up", w.offset > 0 ? "Due before the week starts" : "Nothing uploaded yet", runtime.theme.primary)
            case .missing: return ("exclamationmark", "Nothing uploaded", runtime.theme.error)
            case .uploaded: return ("circle.fill", "Uploaded", runtime.theme.primary)
            case .ready: return ("circle.fill", "Ready to check", runtime.theme.primary)
            case .matched: return ("checkmark", "All matched", runtime.theme.success)
            case .differences(let c, let v): return ("exclamationmark", differencesNote(c, v), runtime.theme.error)
            }
        }()
        let due = st == .due
        let current = w.offset == 0 || w.offset == 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: mark).font(.system(size: 14, weight: .bold)).foregroundColor(color)
                    .frame(width: 34, height: 34).background(Circle().fill(color.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(w.label).font(.system(size: 16, weight: .heavy))
                    // This week, next week and last week carry a small pill leading the line
                    // under the dates; every week is drawn alike, as on the web (George, 23 Oct 2026).
                    HStack(spacing: 6) {
                        if !tag.isEmpty {
                            Text(tag).font(.system(size: 12, weight: .bold)).foregroundColor(runtime.theme.primary)
                                .padding(.horizontal, 8).padding(.vertical, 1)
                                .background(Capsule().fill(runtime.theme.tint))
                                .fixedSize()
                        }
                        Text(note).font(.system(size: 13))
                            .foregroundColor(st == .missing || { if case .differences = st { return true } else { return false } }() ? color : runtime.theme.textSecondary)
                    }
                }
                Spacer()
                if canUpload && (st == .due || st == .missing) {
                    Button(due ? "Upload" : "Upload late") {
                        uploadWeek = w
                        importing = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(runtime.theme.primary)
                    .disabled(uploading != nil || runtime.isDesignMode)
                }
            }
            .padding(14)
            if !w.files.isEmpty {
                Divider()
                ForEach(w.files) { fileRow($0, week: w, listing: listing) }
            }
        }
        // This week and next week carry a quiet outline, as on the web.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(runtime.theme.paper)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(runtime.theme.primary.opacity(current ? 0.05 : 0)))
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(current ? runtime.theme.primary.opacity(0.5) : runtime.theme.divider, lineWidth: current ? 1.5 : 1))
        .cmsInspectorID("Cms.fileLibrary.week")
    }

    private func fileRow(_ f: CmsFileRecord, week: CmsFileWeeks.Week?, listing: CmsFileListing) -> some View {
        let fileAsks = askChat.isEmpty ? [] : asks("askActions")
        let size = f.size < 1024 ? "\(Int(f.size)) B" : f.size < 1_048_576 ? "\(Int((f.size / 1024).rounded())) KB" : String(format: "%.1f MB", f.size / 1_048_576)
        var detail = [size, Impact.date(f.createdAt).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""]
        if let by = f.uploadedByEmail { detail.append(by) }
        if CmsFileWeeks.spansWeeks(f, key: weekKey), let c = CmsFileWeeks.coverage(f, key: weekKey) {
            detail.append("covers \(CmsFileWeeks.coverageLabel(c, now: Date()))")
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc").foregroundColor(runtime.theme.textSecondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(f.filename).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                Text(detail.filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12.5))
                    .foregroundColor(runtime.theme.textSecondary).lineLimit(2)
                if !fileAsks.isEmpty {
                    Menu {
                        ForEach(fileAsks, id: \.self) { a in Button(a.label) { ask(a, file: f, week: week) } }
                    } label: {
                        Label("Ask wac", systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(runtime.theme.primary)
                    .disabled(runtime.isDesignMode)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button { Task { await open(f) } } label: { Label("Open", systemImage: "eye") }
                if listing.delete && (props.bool("allowDelete") ?? true) {
                    Button(role: .destructive) { confirmDelete = f } label: { Label("Delete", systemImage: "trash") }
                }
            } label: {
                Group {
                    if busyId == f.id { ProgressView() } else { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                }
                .frame(width: 32, height: 32)
            }
            .tint(runtime.theme.textSecondary)
        }
        .padding(12)
        .cmsInspectorID("Cms.fileLibrary.file")
    }
}
