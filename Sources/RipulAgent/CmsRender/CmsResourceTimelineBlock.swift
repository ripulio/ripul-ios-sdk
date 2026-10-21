import SwiftUI

/// Native twin of `resourceTimeline` (ResourceTimelineBlock.tsx), read-only:
/// rows of resources (people), bars for each item from its start to its end,
/// on a day axis that pages by week or month.
///
/// Semantics mirrored: resources from `resourceColumn` (or `resourceIdColumn`),
/// items from `startColumn`/`endColumn` (UTC timestamps), the window anchored
/// on the earliest item until the reader pages, lanes for overlapping items
/// (`assignLanes`), `collapseThreshold` folding a row with more lanes into
/// one summary bar until expanded, `autoColorBy` resource with the
/// `spectrum` spread (an even hue wheel), the label from `labelColumn` with
/// `labelFormat` (or `labelTemplate`), and the tooltip layout's field grid
/// shown for a tapped item.
///
/// Presentation: a segmented Week / Month scale with previous / next, a
/// pinned name column and a horizontally scrolling day grid; a tapped bar
/// opens its details in a sheet.
///
/// Not native yet: editing (drag, resize, insert), the assignee and
/// allocation ("things") modes, the hour, quarter and year scales, custom
/// colour palettes and the cell layout under a bar.
struct CmsResourceTimelineBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var scale = "month"
    @State private var viewDate: Date?
    @State private var expanded: Set<String> = []
    @State private var openItem: Item?

    struct Item: Identifiable, Equatable {
        var id: String
        var resource: String
        var start: Date
        var end: Date
        var label: String
        var row: [String: CmsJSON]
    }

    private var props: [String: CmsJSON] { block.props }
    private var querySlug: String { props.string("querySlug") ?? "" }
    private var dayWidth: CGFloat { CGFloat(props.double("dayWidthPx") ?? 48) }
    private var itemHeight: CGFloat { max(CGFloat(props.double("itemHeightPx") ?? 32), 28) }
    private var sidebarWidth: CGFloat { min(CGFloat(props.double("sidebarWidthPx") ?? 160), 120) }
    private let cal = Calendar(identifier: .gregorian)

    private var items: [Item] {
        guard case .ok(let result) = runtime.state(for: querySlug) else { return [] }
        let resCol = props.string("resourceColumn").flatMap { $0.isEmpty ? nil : $0 } ?? props.string("resourceIdColumn") ?? ""
        let startCol = props.string("startColumn") ?? "", endCol = props.string("endColumn") ?? ""
        let labelCol = props.string("labelColumn") ?? "", fmt = props.string("labelFormat") ?? ""
        let template = props.string("labelTemplate") ?? ""
        return result.rows.enumerated().compactMap { i, r in
            guard let start = Impact.date(r[startCol]?.displayString ?? "") else { return nil }
            let end = Impact.date(r[endCol]?.displayString ?? "") ?? start.addingTimeInterval(3600)
            var label = ""
            if !template.isEmpty { label = runtime.resolveTemplate(template, rowContext: r) }
            else if let v = r[labelCol], v != .null { label = fmt.isEmpty ? v.displayString : CmsFormatValue.apply(v.displayString, pattern: fmt) }
            return Item(id: "\(i)", resource: r[resCol]?.displayString ?? "—", start: start, end: max(end, start.addingTimeInterval(60)),
                        label: label, row: r)
        }
    }

    /// The axis: a Monday-start week or a calendar month around the reference.
    private func axis(_ ref: Date) -> (start: Date, days: Int) {
        if scale == "week" { return (CmsFileWeeks.mondayOf(ref), 7) }
        let start = cal.date(from: cal.dateComponents([.year, .month], from: ref))!
        return (start, cal.range(of: .day, in: .month, for: start)!.count)
    }

    var body: some View {
        let items = self.items
        let anchor = items.map(\.start).min().map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: Date())
        let ref = viewDate ?? anchor
        let (axisStart, days) = axis(ref)
        let axisEnd = cal.date(byAdding: .day, value: days, to: axisStart)!
        let width = CGFloat(days) * dayWidth
        func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(axisStart) / 86_400) * dayWidth }

        // Resources in first-seen order, coloured by an even hue spread.
        var order: [String] = []
        for it in items where !order.contains(it.resource) { order.append(it.resource) }
        order.sort { $0.localizedCompare($1) == .orderedAscending }
        let colors = Dictionary(uniqueKeysWithValues: order.enumerated().map { i, k in
            (k, Color(hue: order.isEmpty ? 0 : Double(i) / Double(order.count), saturation: 0.65, brightness: 0.78))
        })
        let threshold = Int(props.double("collapseThreshold") ?? 0)
        let rows: [(resource: String, lanes: [[Item]], collapsed: Bool, collapsible: Bool)] = order.map { r in
            let mine = items.filter { $0.resource == r && $0.end > axisStart && $0.start < axisEnd }.sorted { $0.start < $1.start }
            var lanes: [[Item]] = []
            for it in mine {
                if let i = lanes.firstIndex(where: { ($0.last?.end ?? .distantPast) <= it.start }) { lanes[i].append(it) } else { lanes.append([it]) }
            }
            let collapsible = threshold > 0 && lanes.count > threshold
            return (r, lanes, collapsible && !expanded.contains(r), collapsible)
        }.filter { !$0.lanes.isEmpty }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $scale) { Text("Week").tag("week"); Text("Month").tag("month") }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 180)
                Spacer()
                Button { viewDate = cal.date(byAdding: scale == "week" ? .day : .month, value: scale == "week" ? -7 : -1, to: ref) } label: { Image(systemName: "chevron.left") }
                Button("Today") { viewDate = Date() }
                Button { viewDate = cal.date(byAdding: scale == "week" ? .day : .month, value: scale == "week" ? 7 : 1, to: ref) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(runtime.theme.primary)
            Text(scale == "week"
                 ? CmsFileWeeks.weekLabel(axisStart, now: Date())
                 : axisStart.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_GB"))))
                .font(.system(size: 15, weight: .bold))

            if case .error(let message) = runtime.state(for: querySlug) {
                CmsQueryErrorView(message: message, querySlug: querySlug)
            } else if case .ok = runtime.state(for: querySlug) {
                if rows.isEmpty {
                    Text("Nothing in this \(scale).").font(.system(size: 14)).foregroundColor(runtime.theme.textSecondary).padding(.vertical, 20)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        // Pinned names.
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 30)
                            ForEach(rows, id: \.resource) { row in
                                let h = CGFloat(row.collapsed ? 1 : row.lanes.count) * itemHeight
                                HStack(spacing: 4) {
                                    Text(row.resource).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                                    if row.collapsible {
                                        Image(systemName: row.collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .bold))
                                    }
                                }
                                .frame(width: sidebarWidth, height: h, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard row.collapsible else { return }
                                    if expanded.contains(row.resource) { expanded.remove(row.resource) } else { expanded.insert(row.resource) }
                                }
                                .overlay(alignment: .bottom) { Divider() }
                            }
                        }
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 0) {
                                    ForEach(0..<days, id: \.self) { i in
                                        let d = cal.date(byAdding: .day, value: i, to: axisStart)!
                                        let today = cal.isDateInToday(d)
                                        VStack(spacing: 0) {
                                            Text(d.formatted(.dateTime.weekday(.narrow))).font(.system(size: 10))
                                            Text("\(cal.component(.day, from: d))").font(.system(size: 12, weight: today ? .heavy : .semibold))
                                        }
                                        .foregroundColor(today ? runtime.theme.primary : runtime.theme.textSecondary)
                                        .frame(width: dayWidth, height: 30)
                                    }
                                }
                                ForEach(rows, id: \.resource) { row in
                                    let color = colors[row.resource] ?? runtime.theme.primary
                                    ZStack(alignment: .topLeading) {
                                        HStack(spacing: 0) {
                                            ForEach(0..<days, id: \.self) { i in
                                                let d = cal.date(byAdding: .day, value: i, to: axisStart)!
                                                Rectangle().fill(cal.isDateInWeekend(d) ? runtime.theme.surfaceMuted : Color.clear)
                                                    .frame(width: dayWidth)
                                                    .overlay(alignment: .leading) { Rectangle().fill(runtime.theme.divider.opacity(0.6)).frame(width: 0.5) }
                                            }
                                        }
                                        if row.collapsed {
                                            let all = row.lanes.flatMap { $0 }
                                            let left = max(0, x(all.map(\.start).min()!)), right = min(width, x(all.map(\.end).max()!))
                                            Text("\(all.count) shifts")
                                                .font(.system(size: 11, weight: .bold)).foregroundColor(.white) // theme-exempt: text on a resource's own colour
                                                .padding(.horizontal, 6)
                                                .frame(width: max(right - left, 40), height: itemHeight - 6, alignment: .leading)
                                                .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.8)))
                                                .offset(x: left, y: 3)
                                        } else {
                                            ForEach(Array(row.lanes.enumerated()), id: \.offset) { lane, list in
                                                ForEach(list) { it in
                                                    let left = max(0, x(it.start)), right = min(width, x(it.end))
                                                    Button { openItem = it } label: {
                                                        Text(it.label)
                                                            .font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                                                            .foregroundColor(.white) // theme-exempt: text on a resource's own colour
                                                            .padding(.horizontal, 4)
                                                            .frame(width: max(right - left, 6), height: itemHeight - 6, alignment: .leading)
                                                            .background(RoundedRectangle(cornerRadius: 6).fill(color))
                                                    }
                                                    .buttonStyle(.plain)
                                                    .offset(x: left, y: CGFloat(lane) * itemHeight + 3)
                                                }
                                            }
                                        }
                                    }
                                    .frame(width: width, height: CGFloat(row.collapsed ? 1 : row.lanes.count) * itemHeight, alignment: .topLeading)
                                    .overlay(alignment: .bottom) { Divider() }
                                }
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(runtime.theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(runtime.theme.divider))
                    .cmsInspectorID("Cms.resourceTimeline.grid")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            }
        }
        .onAppear {
            runtime.ensureLoaded(querySlug)
            if let s = props.string("defaultScale"), s == "week" || s == "month" { scale = s }
        }
        .ripulSheet(item: $openItem, size: .form) { it in
            CmsTimelineItemSheet(item: it, tooltip: tooltipFieldGrid, querySlug: querySlug).environmentObject(runtime)
        }
    }

    /// The tooltip layout's first field grid: its title template and fields.
    private var tooltipFieldGrid: CmsBlock? {
        var raw = props["tooltipLayout"]
        if case .string(let s)? = raw, let data = s.data(using: .utf8) { raw = try? JSONDecoder().decode(CmsJSON.self, from: data) }
        guard let raw, let data = try? JSONEncoder().encode(raw),
              let blocks = try? JSONDecoder().decode(CmsPageBlocks.self, from: data) else { return nil }
        return blocks.allBlocks().first { $0.type == "fieldGrid" }
    }
}

/// A timeline item's details: the tooltip field grid's title and visible
/// fields with their formats, read from the item's own row.
private struct CmsTimelineItemSheet: View {
    let item: CmsResourceTimelineBlockView.Item
    let tooltip: CmsBlock?
    let querySlug: String
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        guard let template = tooltip?.props.string("title"), !template.isEmpty else { return item.resource }
        return runtime.resolveTemplate(template.replacingOccurrences(of: "@\(querySlug).", with: "@"), rowContext: item.row)
    }

    private var fields: [(String, String)] {
        let configured: [(String, String?)] = {
            guard case .array(let list)? = tooltip?.props["fields"] else { return item.row.keys.sorted().map { ($0, nil) } }
            return list.compactMap { f in
                guard let o = f.objectValue, let key = o.string("key"), o.bool("visible") != false else { return nil }
                return (key, o.string("format"))
            }
        }()
        return configured.compactMap { key, format in
            guard let v = item.row[key], v != .null else { return nil }
            let text = format.map { CmsFormatValue.apply(v.displayString, pattern: $0) } ?? v.displayString
            return (key.replacingOccurrences(of: "_", with: " ").capitalized, text)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(fields, id: \.0) { f in LabeledContent(f.0, value: f.1) }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(runtime.theme.primary)
    }
}
