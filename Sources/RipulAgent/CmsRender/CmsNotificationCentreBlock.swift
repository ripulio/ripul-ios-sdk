import SwiftUI

/// Native twin of `notificationCentre` (NotificationCentreBlock.tsx): a bell
/// with the unread count that opens the messages the signed-in person may
/// see, newest first, and marks what it shows as read for that person.
///
/// Semantics mirrored: messages and read records are rows of two queries;
/// only this person's read records count (a site admin's row access can
/// return everyone's); nothing is counted until the read records arrive;
/// opening marks the unread ones read through the mark-read mutation (params:
/// the message id and the reader's email), which stay "new" while the list is
/// open; a message's page link opens that page.
///
/// Presentation: an SF Symbol bell with a red count, opening a native list in
/// a sheet (the web's popover).
///
/// Not yet native: upload reminders (`reminderStore`), which the web works out
/// from the file store's uploads.
struct CmsNotificationCentreBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var open = false
    @State private var readHere: Set<String> = []
    @State private var newOnOpen: Set<String> = []
    @State private var sent: Set<String> = []

    private var props: [String: CmsJSON] { block.props }
    private func col(_ key: String, _ fallback: String) -> String {
        props.string(key).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
    private var querySlug: String { props.string("querySlug") ?? "" }
    private var readsSlug: String { props.string("readsQuerySlug") ?? "" }
    private var idColumn: String { col("idColumn", "id") }
    private var titleColumn: String { col("titleColumn", "title") }
    private var bodyColumn: String { col("bodyColumn", "body") }
    private var dateColumn: String { col("dateColumn", "created_at") }
    private var linkColumn: String { props.string("linkColumn") ?? "link_page" }
    private var readIdColumn: String { col("readNotificationIdColumn", "notification_id") }
    private var readerParam: String { col("readerParam", "user_email") }
    private var heading: String { col("heading", "Notifications") }
    /// `auth.user.email || membership.email`.
    private var email: String {
        (runtime.client.userEmail ?? runtime.membership?.email ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func rows(_ slug: String) -> [[String: CmsJSON]]? {
        guard !slug.isEmpty, case .ok(let result) = runtime.state(for: slug) else { return nil }
        return result.rows
    }

    /// Newest first by the date column; undated rows last, in order (`newestFirst`).
    private var messages: [[String: CmsJSON]] {
        let all = rows(querySlug) ?? []
        return all.enumerated().sorted { a, b in
            let ta = Self.time(a.element[dateColumn]) ?? -.infinity
            let tb = Self.time(b.element[dateColumn]) ?? -.infinity
            return ta != tb ? ta > tb : a.offset < b.offset
        }.map(\.element)
    }

    /// `unreadIds`, counting only this person's read records.
    private var unread: [String] {
        // Until the read records arrive nothing is known to be unread.
        if !readsSlug.isEmpty && rows(readsSlug) == nil { return [] }
        var read = readHere
        for r in rows(readsSlug) ?? [] {
            if let who = r[readerParam]?.displayString.trimmingCharacters(in: .whitespaces).lowercased(),
               !who.isEmpty, !email.isEmpty, who != email { continue }
            let id = r[readIdColumn]?.displayString ?? ""
            if !id.isEmpty { read.insert(id) }
        }
        return messages.compactMap { m in
            let id = m[idColumn]?.displayString ?? ""
            return id.isEmpty || read.contains(id) ? nil : id
        }
    }

    var body: some View {
        let count = unread.count
        Button {
            newOnOpen = Set(unread)
            open = true
        } label: {
            Image(systemName: props.string("iconStyle") == "filled" ? "bell.fill" : "bell")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(runtime.color(props.string("iconColor")).map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                .frame(width: 36, height: 36)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count > 9 ? "9+" : "\(count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white) // theme-exempt: count on the error badge, as the web's MUI Badge
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(runtime.theme.error))
                            .offset(x: 2, y: 0)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(heading), \(count) unread" : heading)
        .cmsInspectorID("Cms.notificationCentre.bell")
        .onAppear {
            runtime.ensureLoaded(querySlug)
            runtime.ensureLoaded(readsSlug)
        }
        .ripulSheet(isPresented: $open) {
            list.environmentObject(runtime)
        }
        .onChange(of: open) { isOpen in
            if isOpen { markRead() }
        }
    }

    private func markRead() {
        let ids = unread
        guard !ids.isEmpty else { return }
        readHere.formUnion(ids)
        let mutation = props.string("markReadMutationSlug") ?? ""
        guard !mutation.isEmpty, !email.isEmpty else { return }
        for id in ids where !sent.contains(id) {
            sent.insert(id)
            Task {
                let params: [String: CmsJSON] = [
                    readIdColumn: .object(["type": .string("string"), "value": .string(id)]),
                    readerParam: .object(["type": .string("string"), "value": .string(email)]),
                ]
                if case .failed = await runtime.runMutation(mutation, params: params) {
                    sent.remove(id)
                }
            }
        }
    }

    private var list: some View {
        NavigationStack {
            List {
                if messages.isEmpty {
                    Text(querySlug.isEmpty ? "Choose the messages query for this block." : col("emptyText", "Nothing new."))
                        .foregroundColor(runtime.theme.textSecondary)
                }
                ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                    row(message, index: index)
                }
            }
            .navigationTitle(heading)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { open = false }
                }
            }
        }
        .tint(runtime.theme.primary)
    }

    private func row(_ message: [String: CmsJSON], index: Int) -> some View {
        let id = message[idColumn]?.displayString ?? "\(index)"
        let link = linkColumn.isEmpty ? "" : (message[linkColumn]?.displayString ?? "").trimmingCharacters(in: .whitespaces)
        let linkPage = link.isEmpty ? nil : runtime.pageTitles[link]
        let body = message[bodyColumn]?.displayString ?? ""
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(newOnOpen.contains(id) ? runtime.theme.primary : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message[titleColumn]?.displayString ?? "")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(Self.when(message[dateColumn]))
                        .font(.system(size: 12))
                        .foregroundColor(runtime.theme.textSecondary)
                }
                if !body.isEmpty {
                    Text(body)
                        .font(.system(size: 14))
                        .foregroundColor(runtime.theme.textSecondary)
                }
                if let linkPage {
                    Button("Open \(linkPage.isEmpty ? link : linkPage)") {
                        open = false
                        runtime.navigate(toPage: link)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
        .cmsInspectorID("Cms.notificationCentre.item")
    }

    // D1 timestamps are UTC without a zone ("2026-10-09 14:00:00").
    private static func date(_ value: CmsJSON?) -> Date? {
        guard let raw = value?.displayString, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if raw.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}"#, options: .regularExpression) != nil {
            return iso.date(from: raw.replacingOccurrences(of: " ", with: "T") + "Z")
        }
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withFullDate]
        return iso.date(from: String(raw.prefix(10)))
    }

    private static func time(_ value: CmsJSON?) -> Double? { date(value)?.timeIntervalSince1970 }

    private static func when(_ value: CmsJSON?) -> String {
        guard let d = date(value) else { return "" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}
