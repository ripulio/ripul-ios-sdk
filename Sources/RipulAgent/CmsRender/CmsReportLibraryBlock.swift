import SwiftUI

/// Native twin of `reportLibrary` (ReportLibraryBlock.tsx): each pay period's
/// kept reconcile report, newest first, to open as the full report or save
/// as a spreadsheet.
///
/// Semantics: `keptFromRow` (a row whose report_json is not a report is
/// skipped), sorted by period end, the period and Reconciled wording.
/// Presentation: a card per report; the full report opens in a sheet drawn
/// natively (CmsReportView), and Spreadsheet hands the CSV to the system
/// share sheet (the web downloads it).
struct CmsReportLibraryBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var open: Kept?

    struct Kept: Identifiable, Equatable {
        var id: String
        var from: String
        var to: String
        var report: CmsReport
        var savedAt: Date?
    }

    private var props: [String: CmsJSON] { block.props }
    private var querySlug: String { props.string("querySlug") ?? "" }

    static func kept(_ r: [String: CmsJSON]) -> Kept? {
        guard let json = r["report_json"]?.displayString, let data = json.data(using: .utf8),
              let report = CmsReport.normalise(try? JSONSerialization.jsonObject(with: data)) else { return nil }
        return Kept(
            id: r["id"]?.displayString ?? UUID().uuidString,
            from: String((r["period_from"]?.displayString ?? "").prefix(10)),
            to: String((r["period_to"]?.displayString ?? "").prefix(10)),
            report: report,
            savedAt: Impact.date(r["saved_at"]?.displayString ?? "")
        )
    }

    private static func day(_ iso: String, year: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        return year ? d.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "en_GB")))
            : d.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }

    var body: some View {
        let state = runtime.state(for: querySlug)
        let reports: [Kept]? = {
            guard case .ok(let r) = state else { return nil }
            return r.rows.compactMap(Self.kept).sorted { $0.to > $1.to }
        }()
        VStack(alignment: .leading, spacing: 12) {
            let heading = props.string("heading") ?? "Pay period reports"
            if !heading.isEmpty { Text(heading).font(.system(size: 18, weight: .bold)) }
            if let intro = props.string("intro"), !intro.isEmpty {
                Text(intro).font(.system(size: 13.5)).foregroundColor(runtime.theme.textSecondary)
            }
            if case .error(let message) = state {
                CmsQueryErrorView(message: message, querySlug: querySlug)
            } else if let reports {
                if reports.isEmpty {
                    Label(props.string("emptyText") ?? "Each pay period’s report is kept here once it has been reconciled.",
                          systemImage: "doc.text")
                        .font(.system(size: 13.5))
                        .foregroundColor(runtime.theme.textSecondary)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: runtime.theme.cardRadius).fill(runtime.theme.tint))
                        .overlay(RoundedRectangle(cornerRadius: runtime.theme.cardRadius)
                            .strokeBorder(runtime.theme.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                } else {
                    ForEach(reports) { card($0) }
                }
            } else if !querySlug.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            }
        }
        .onAppear { runtime.ensureLoaded(querySlug) }
        .ripulSheet(item: $open) { kept in
            NavigationStack {
                ScrollView { CmsReportView(report: kept.report).padding(20) }
                    .navigationTitle("Pay period · \(Self.day(kept.from)) – \(Self.day(kept.to, year: true))")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { open = nil } }
                        if kept.report.table != nil, let file = kept.report.csvFile() {
                            ToolbarItem(placement: .primaryAction) {
                                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                            }
                        }
                    }
            }
            .tint(runtime.theme.primary)
            .environmentObject(runtime)
        }
    }

    private func card(_ k: Kept) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PAY PERIOD · \(Self.day(k.from).uppercased()) – \(Self.day(k.to, year: true).uppercased())")
                .font(.system(size: 11.5, weight: .bold)).tracking(1).foregroundColor(runtime.theme.textSecondary)
            Text(k.report.title.isEmpty ? "Pay period report" : k.report.title).font(.system(size: 15, weight: .bold))
            if !k.report.stats.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(k.report.stats.enumerated()), id: \.offset) { _, s in
                            (Text(s.value).fontWeight(.bold).foregroundColor(runtime.theme.primary) + Text(" \(s.label)"))
                                .font(.system(size: 12))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(runtime.theme.tint))
                        }
                    }
                }
            }
            if let saved = k.savedAt {
                Text("Reconciled \(saved.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "en_GB"))))")
                    .font(.system(size: 12)).foregroundColor(runtime.theme.textSecondary)
            }
            HStack(spacing: 8) {
                Button { open = k } label: { Label("Open full report", systemImage: "doc.richtext") }
                    .buttonStyle(.borderedProminent)
                if k.report.table != nil, let file = k.report.csvFile() {
                    ShareLink(item: file) { Label("Spreadsheet", systemImage: "tablecells") }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .tint(runtime.theme.primary)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous).fill(runtime.theme.paper))
        .overlay(RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous).strokeBorder(runtime.theme.divider))
        .cmsInspectorID("Cms.reportLibrary.report")
    }
}
