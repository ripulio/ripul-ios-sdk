import SwiftUI
import RipulThemeKit
import CoreTransferable
import UniformTypeIdentifiers

struct NativeMarkdownReportBlock: View {
    let source: String
    @State private var parsed: NativeMarkdownReport.Parsed
    @State private var parsedSource: String
    @State private var detail: ReportSnapshot?
    @NativeRowState("report.layout") private var layoutSignature = ""
    init(source: String) {
        self.source = source
        let cached = NativeMarkdownReport.cached(source)
        _parsed = State(initialValue: cached ?? .preparing)
        _parsedSource = State(initialValue: cached == nil ? "" : source)
    }

    var body: some View {
        content
            .ripulSheet(item: $detail) { NativeMarkdownReportSheet(report: $0.report) }
            .task(id: source) {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                let next = await NativeMarkdownReportParser.shared.parse(source)
                guard !Task.isCancelled else { return }
                parsed = next
                parsedSource = source
                layoutSignature = String(source.hashValue)
            }
    }

    @ViewBuilder private var content: some View {
        switch parsed {
        case .complete(let report), .writing(let report):
            NativeMarkdownReportCard(report: report, writing: writing) { detail = ReportSnapshot(report: report) }
        case .preparing:
            Text("Preparing the report…").font(.ripul(.callout))
                .foregroundStyle(.ripul(.textSecondary)).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ripul(.surface), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("NativeMarkdown.report.preparing")
        case .invalid: NativeMarkdownSourceBlock(source: source, language: "report")
        }
    }

    private var writing: Bool {
        if parsedSource != source { return true }
        if case .writing = parsed { return true }
        return false
    }
}

private struct NativeMarkdownReportCard: View {
    let report: NativeMarkdownReport
    let writing: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.title).font(.ripul(.headline)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("NativeMarkdown.report.title")
            if let badge = report.badge {
                Text(badge.text).font(.ripul(.caption, weight: .semibold))
                    .foregroundStyle(badge.tone.color).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(badge.tone.color.opacity(0.1), in: Capsule())
            }
            if !report.stats.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(report.stats.indices, id: \.self) { index in
                        ReportStatView(stat: report.stats[index])
                    }
                }
            }
            // Bound work in a chat row. The complete report uses reusable List
            // cells and exports all normalized rows, not just this preview.
            ForEach(Array(report.groups.prefix(2).indices), id: \.self) { index in
                let group = report.groups[index]
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title).font(.ripul(.callout, weight: .semibold))
                    if !group.detail.isEmpty { Text(group.detail).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)) }
                    ForEach(Array(group.bars.prefix(4).indices), id: \.self) { ReportBarView(bar: group.bars[$0]) }
                }
            }
            ForEach(Array(report.notes.prefix(2).indices), id: \.self) { ReportNoteView(note: report.notes[$0]) }
            if writing {
                Text("Still writing the report…").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
            } else {
                HStack {
                    Button("View full report", action: open)
                        .accessibilityIdentifier("NativeMarkdown.report.open")
                    Spacer()
                    if !report.download.isEmpty { ReportExportMenu(report: report) }
                }.font(.ripul(.callout))
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ripul(.surface), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ripul(.separator)))
    }
}

private struct ReportSnapshot: Identifiable {
    let id = UUID()
    let report: NativeMarkdownReport
}

struct NativeMarkdownReportSheet: View {
    let report: NativeMarkdownReport
    @Environment(\.dismiss) private var dismiss
    @State private var showsTable = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(report.title).font(.ripul(.headline))
                    if let badge = report.badge { Text(badge.text).foregroundStyle(badge.tone.color) }
                    ForEach(report.stats.indices, id: \.self) { ReportStatView(stat: report.stats[$0]) }
                }
                ForEach(report.groups.indices, id: \.self) { index in
                    let group = report.groups[index]
                    Section {
                        if !group.detail.isEmpty { Text(group.detail).font(.ripul(.callout)) }
                        ForEach(group.bars.indices, id: \.self) { ReportBarView(bar: group.bars[$0]) }
                    } header: { Text(group.title) }
                }
                if !report.notes.isEmpty {
                    Section("Notes") { ForEach(report.notes.indices, id: \.self) { ReportNoteView(note: report.notes[$0]) } }
                }
                if let table = report.table {
                    Section {
                        Button("View data table (\(table.rows.count) rows)") { showsTable = true }
                            .accessibilityIdentifier("NativeMarkdown.report.table")
                    }
                }
            }
            .textSelection(.enabled)
            .navigationTitle("Report")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("NativeMarkdown.report.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    if !report.download.isEmpty { ReportExportMenu(report: report, identifier: "NativeMarkdown.report.export.full") }
                }
            }
            .ripulSheet(isPresented: $showsTable) {
                if let table = report.table { NativeReportTableSheet(table: table) }
            }
        }
        .frame(minWidth: 280, minHeight: 320)
    }
}

private struct ReportStatView: View {
    let stat: NativeMarkdownReport.Stat
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stat.value).font(.ripul(.title3, weight: .semibold)).foregroundStyle(stat.tone.color)
            Text(stat.label).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct ReportBarView: View {
    let bar: NativeMarkdownReport.Bar
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bar.label).font(.ripul(.callout, weight: .medium))
            ProgressView(value: bar.value).tint(bar.tone.color).accessibilityHidden(true)
            if !bar.note.isEmpty { Text(bar.note).font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary)) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([bar.label, bar.note].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(Text("\(Int((bar.value * 100).rounded())) percent"))
    }
}

private struct ReportNoteView: View {
    let note: NativeMarkdownReport.Note
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: note.tone == .ok ? "checkmark.circle" : note.tone == .neutral ? "info.circle" : "exclamationmark.circle")
                .font(.ripulIcon(.callout)).foregroundStyle(note.tone.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if !note.title.isEmpty { Text(note.title).font(.ripul(.callout, weight: .semibold)) }
                Text(note.text).font(.ripul(.callout))
            }.fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

private struct NativeReportTableSheet: View {
    let table: NativeMarkdownReport.Table
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var cellWidth: CGFloat = 180
    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    tableRow(table.columns, header: true)
                    ForEach(table.rows.indices, id: \.self) { index in tableRow(table.rows[index], header: false) }
                }
            }
            .navigationTitle("Data table")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("NativeMarkdown.report.table.done")
                }
            }
        }.frame(minWidth: 280, minHeight: 320)
    }
    private func tableRow(_ values: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                Text(values[index]).font(.ripul(.callout, weight: header ? .semibold : .regular))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(width: cellWidth, alignment: .leading).padding(8)
            }
        }
        .background(header ? Color.ripul(.text).opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private extension NativeMarkdownReport.Tone {
    var color: Color {
        switch self {
        case .neutral: return .ripul(.text)
        case .ok: return .ripul(.success)
        case .warn: return .ripul(.warning)
        case .bad: return .ripul(.danger)
        }
    }
}

private struct ReportExportMenu: View {
    let report: NativeMarkdownReport
    var identifier = "NativeMarkdown.report.export"
    var body: some View {
        Menu {
            ShareLink(item: NativeReportDocumentExport(report: report), preview: SharePreview(report.title)) { Text(report.download) }
            ShareLink(item: NativeReportCSVExport(report: report), preview: SharePreview(report.title)) { Text("Spreadsheet (CSV)") }
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
        .accessibilityIdentifier(identifier)
    }
}

struct NativeReportCSVExport: Transferable {
    let report: NativeMarkdownReport
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data(("\u{FEFF}" + $0.report.csv).utf8) }
            .suggestedFileName { $0.report.filename + ".csv" }
    }
}

struct NativeReportDocumentExport: Transferable {
    let report: NativeMarkdownReport
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .html) { Data($0.report.html.utf8) }
            .suggestedFileName { $0.report.filename + ".html" }
    }
}
