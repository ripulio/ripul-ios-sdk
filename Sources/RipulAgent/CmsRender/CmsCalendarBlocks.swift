import SwiftUI

/// Native twin of the web `simpleCalendar` block (SimpleCalendarBlock.tsx).
/// Full mirror of behavior — week strip, month grid, slim predicate row,
/// runtime mode toggle, and the complete operator vocabulary — but NOT a
/// pixel port: the slim row uses native `Menu` + compact `DatePicker`
/// instead of imitating the web dropdowns.
///
/// Selection publishes the SAME output row the web block emits under the
/// block's slug (date, date_start, date_end, half-open from/to, raw operator
/// value), so `@slug.column` tokens and bound props resolve identically.
/// Not yet mirrored: `parameterId` shared-Parameter binding (needs the
/// native parameter store) and rota timeline dot colors (needs the paired
/// TimelineColorContext).
struct CmsSimpleCalendarBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    @State private var anchor = Date()
    @State private var selStart: Date?
    @State private var selEnd: Date?
    @State private var displayMode: String = "grid"
    @State private var operatorValue: CmsRangePredicateOperator = .between
    @State private var configured = false
    #if os(iOS)
    /// The header arrows' last page, which the pager slides on and settles.
    @State private var pageRequest: CmsCalendarPager.Request?
    /// The height's growth towards a neighbour of other rows, frame by frame
    /// while paging. Held, not observed: only the sizer's padding reads it.
    @State private var growth = CmsCalendarGrowth()
    #endif
    /// Light or dark, in the pages' signature (the pager hands the pages the
    /// rest of the environment).
    @Environment(\.colorScheme) private var colorScheme
    /// Set when the calendar is pinned behind the page's list.
    @Environment(\.cmsPinnedLiveResize) private var liveResize
    /// Which slim-row date chip is picking (drives the picker sheet).
    @State private var dateChipTarget: DateChipTarget?
    /// The day whose details are open (`dayDetails`), what to run once their
    /// popover has closed, and the record form a row or the add button opened.
    @State private var detailsDay: DetailsDay?
    @State private var afterDetails: (() -> Void)?
    @State private var detailsForm: CmsRecordFormRequest?
    /// The day grid's width, for `dayFill.size: 'fit'`.
    @State private var gridWidth: CGFloat = 0

    // MARK: - Props

    private var querySlug: String { block.props.string("querySlug") ?? "" }
    private var dateColumn: String { block.props.string("dateColumn") ?? "" }
    private var isRangeMode: Bool { (block.props.string("selectionMode") ?? "range") == "range" }
    private var monthView: Bool { (block.props.string("view") ?? "week") == "month" }
    private var showWeekends: Bool { block.props.bool("showWeekends") ?? true }
    /// Month view: other months' days shown or blank, the weeks spanned or six.
    private var gridOptions: CmsCalendarDecorations.MonthGrid {
        CmsCalendarDecorations.monthGrid(outsideDays: block.props["outsideDays"], monthRows: block.props["monthRows"])
    }
    private var allowModeToggle: Bool { block.props.bool("allowModeToggle") ?? true }
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif
    /// Web `modeToggleOnMobile`: false hides the toggle on phone widths and
    /// pins the author's mode there (a remembered choice must not strand them).
    private var toggleShown: Bool {
        allowModeToggle && !(isCompactWidth && block.props.bool("modeToggleOnMobile") == false)
    }
    private var dotSize: CGFloat { CGFloat(block.props.double("dotSize") ?? 8) }
    /// Web accent chain: titleTypography colour, else the PORTAL theme
    /// primary (never the system accent). Drives pagers + mode toggle.
    private var accentColor: Color {
        typographyColor("titleTypography") ?? runtime.theme.primary
    }
    /// Selection circle + range band + dots: selectionColor ?? accent.
    private var selectionColor: Color {
        runtime.color(block.props.string("selectionColor")) ?? accentColor
    }
    /// Twin of the web's getContrastText on the selection fill — a light
    /// authored colour gets dark text, not hardcoded white.
    private var selectionContrast: Color {
        CmsCss.contrastText(on: selectionColor)
    }

    private func typographyColor(_ key: String) -> Color? {
        runtime.color(block.props.object(key)?.string("color"))
    }

    // MARK: Surface (`surface: { fill, text, muted }`, palette roles)

    private func surfaceRole(_ key: String) -> Color? {
        block.props.object("surface")?.string(key)
            .flatMap(CmsPaletteRole.init(rawValue:))
            .map { runtime.theme.color(role: $0) }
    }
    /// Behind the whole calendar, its header included.
    private var surfaceFill: Color? { surfaceRole("fill") }
    /// Day numbers, the month title and the arrows.
    private var surfaceText: Color? { surfaceRole("text") }
    /// Weekday letters, other months' days and the "Pick a date" line.
    private var surfaceMuted: Color? { surfaceRole("muted") }
    @Environment(\.cmsBleed) private var bleed
    @Environment(\.cmsOverlap) private var overlap

    /// Web type scale, fixed sizes (authored content does not track Dynamic
    /// Type): base = the web default for the element, authored TypographyValue
    /// size/weight override.
    private func typographyFont(_ key: String, base: CGFloat, weight: Font.Weight) -> Font {
        let obj = block.props.object(key)
        return .system(size: CmsTypography.size(obj) ?? base,
                       weight: CmsTypography.weight(obj) ?? weight)
    }

    /// Date numerals: web is 13px, weight 400 with 700 reserved for TODAY
    /// (selection is signalled by the filled circle, not weight); authored
    /// dateTypography size/weight win.
    private func dateFont(today: Bool) -> Font {
        let obj = block.props.object("dateTypography")
        return .system(size: CmsTypography.size(obj) ?? 13,
                       weight: CmsTypography.weight(obj) ?? (today ? .bold : .regular))
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = (block.props.bool("weekStartsOnMonday") ?? true) ? 2 : 1
        return cal
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 10) {
            if displayMode == "slim" {
                slimRow
            } else if monthView {
                nativeMonthOrFallback
            } else {
                gridHeader
                weekStrip
            }
            if displayMode != "slim" { legend }
        }
        .padding(12)
        // Bleeding under the status bar: the content stays below it.
        .padding(.top, bleed?.underTop ?? 0)
        // `overlap`: empty surface at the bottom for what follows to cover.
        .padding(.bottom, overlap)
        .background(
            // The web passes backgroundColor RAW into sx — theme tokens are
            // NOT resolved for this prop and render as no background at all,
            // letting the block frame's fill show through (real portals rely
            // on this: token bg + coloured frame = transparent block on the
            // frame colour). Mirror exactly: CSS literals only, else clear.
            (bleed.map { AnyShape($0.shape(radius: 14)) } ?? AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
                .fill(surfaceFill ?? CmsCss.color(block.props.string("backgroundColor")) ?? Color.clear)
        )
        .onAppear {
            runtime.ensureLoaded(querySlug)
            if let details = dayDetailsConfig?.querySlug { runtime.ensureLoaded(details) }
            configureOnce()
        }
        // Another block writing the shared date parameter (a sidebar's
        // period list): the calendar's state and its predicate line follow.
        .onChange(of: sharedParameter) { _, value in adopt(value) }
        // A details row's or the add button's form, once the popover has gone.
        .onChange(of: detailsDay) { _, now in
            guard now == nil, let run = afterDetails else { return }
            afterDetails = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { run() }
        }
        .modifier(CmsRecordFormPresenter(runtime: runtime, request: $detailsForm))
    }

    private var parameterId: String? {
        block.props.string("parameterId").flatMap { $0.isEmpty ? nil : $0 }
    }

    private var sharedParameter: CmsJSON? { parameterId.flatMap { runtime.parameters[$0] } }

    /// Takes the shared parameter's predicate when it differs from the
    /// calendar's own (its own write comes back equal and changes nothing).
    private func adopt(_ value: CmsJSON?) {
        guard configured, let saved = value?.objectValue,
              let op = saved.string("operator").flatMap(CmsRangePredicateOperator.init(rawValue:)) else { return }
        let start = saved.string("start").flatMap(CmsDatePredicate.date(fromIso:))
        let end = saved.string("end").flatMap(CmsDatePredicate.date(fromIso:))
        let same = op == operatorValue
            && start.map(CmsDatePredicate.iso) == selStart.map(CmsDatePredicate.iso)
            && end.map(CmsDatePredicate.iso) == selEnd.map(CmsDatePredicate.iso)
        guard !same else { return }
        operatorValue = op
        selStart = start
        selEnd = end
        if let start { anchor = start } else if op.isPeriod { anchor = Date() }
        publishSelection()
    }

    private func configureOnce() {
        guard !configured else { return }
        configured = true
        // Start from the user's last-chosen mode, persisted per block
        // instance (cmsId + slug) — twin of the web's localStorage mode
        // memory — falling back to the author default.
        let authorMode = block.props.string("displayMode") ?? "grid"
        displayMode = toggleShown
            ? (UserDefaults.standard.string(forKey: modePersistenceKey) ?? authorMode)
            : authorMode
        operatorValue = block.props.string("defaultOperator")
            .flatMap(CmsRangePredicateOperator.init(rawValue:)) ?? .between
        // Two-way parameter binding: restore the user's last predicate
        // (operator + dates) from the shared Parameter — persisted by the
        // runtime across visits — before falling back to author defaults.
        if let parameterId = block.props.string("parameterId"), !parameterId.isEmpty,
           let saved = runtime.parameters[parameterId]?.objectValue,
           let op = saved.string("operator").flatMap(CmsRangePredicateOperator.init(rawValue:)),
           // A saved value with no dates is no choice at all (the web seeds
           // the default whenever the parameter holds none).
           saved.string("start") != nil || saved.string("end") != nil
               || ![.eq, .gt, .gte, .lt, .lte, .between].contains(op) {
            operatorValue = op
            selStart = saved.string("start").flatMap(CmsDatePredicate.date(fromIso:))
            selEnd = saved.string("end").flatMap(CmsDatePredicate.date(fromIso:))
            if let s = selStart { anchor = s }
            publishSelection()
            return
        }
        applyDefaultSelection()
    }

    private var modePersistenceKey: String {
        "io.ripul.cms.calendarMode.\(runtime.cmsId).\(block.slug ?? block.id)"
    }

    // MARK: - Grid header (title + paging + mode toggle)

    /// `headerActions`: icon buttons before the month (`leading`, a ☰ that
    /// opens the sidebar) or after the arrows (`trailing`), in the action
    /// button's fields.
    private func headerActions(_ placement: String) -> [(Int, [String: CmsJSON])] {
        guard case .array(let raw)? = block.props["headerActions"] else { return [] }
        return raw.enumerated().compactMap { index, entry in
            guard let action = entry.objectValue else { return nil }
            let at = action.string("placement") == "trailing" ? "trailing" : "leading"
            return at == placement ? (index, action) : nil
        }
    }

    @ViewBuilder
    private func headerActionButtons(_ placement: String) -> some View {
        ForEach(headerActions(placement), id: \.0) { index, action in
            CmsActionButtonBlockView(block: .action(id: "\(block.id).headerAction.\(index)", props: action), chrome: .icon)
                .foregroundStyle(surfaceText ?? accentColor)
                .tint(surfaceText ?? accentColor)
        }
    }

    private var gridHeader: some View {
        HStack(spacing: 4) {
            headerActionButtons("leading")
            Text(monthTitle)
                .font(typographyFont("titleTypography", base: 14, weight: .semibold))
                .foregroundColor(typographyColor("titleTypography") ?? surfaceText ?? runtime.theme.textPrimary)
            Spacer()
            if toggleShown { modeToggle }
            pagerButton(systemName: "chevron.left", step: -1)
            pagerButton(systemName: "chevron.right", step: 1)
            headerActionButtons("trailing")
        }
    }

    private func pagerButton(systemName: String, step: Int) -> some View {
        Button {
            page(step)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(surfaceText ?? accentColor)
    }

    private var modeToggle: some View {
        Button {
            withAnimation(.snappy) { displayMode = displayMode == "slim" ? "grid" : "slim" }
            UserDefaults.standard.set(displayMode, forKey: modePersistenceKey)
        } label: {
            Image(systemName: displayMode == "slim" ? "calendar" : "slider.horizontal.3")
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(surfaceText ?? accentColor)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: anchor)
    }

    // MARK: - Week strip

    /// The week, on the pager (`pagedGrid`): the week before and after are
    /// drawn beside it and slide with the finger.
    private var weekStrip: some View {
        dayDetailsGrid
    }

    private func weekDays(around date: Date, cal: Calendar) -> [Date] {
        guard let interval = cal.dateInterval(of: .weekOfYear, for: date) else { return [] }
        let all = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: interval.start) }
        return showWeekends ? all : all.filter { !cal.isDateInWeekend($0) }
    }

    // MARK: - Month view (compact custom grid on the pager)

    /// Month view = the compact custom grid (user decision, after weighing
    /// the UICalendarView trade-off: the system control exposes no
    /// typography/density API, so web-scale density won) — on a paging
    /// scroll view, as the system control pages its months: the surface
    /// follows the finger and the neighbouring months are drawn beside it.
    /// CmsNativeMonthCalendar is kept unused should the system control return
    /// as a designer option.
    @ViewBuilder
    private var nativeMonthOrFallback: some View {
        gridHeader
        monthGrid
        predicateSummary
    }

    /// Caption articulating the active predicate — carries the meaning the
    /// native calendar can't paint (range spans, periods, no-filter).
    private var predicateSummary: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
            Text(predicateDescription)
                .font(typographyFont("predicateTypography", base: 12, weight: .regular))
            Spacer(minLength: 0)
        }
        .foregroundColor(typographyColor("predicateTypography") ?? surfaceMuted ?? .secondary)
    }

    private var predicateDescription: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        let op = operatorValue
        if op == .any { return op.label }
        if op.isPeriod {
            let bounds = CmsDatePredicate.boundsForRange(op, start: "")
            if let from = CmsDatePredicate.date(fromIso: bounds.from),
               let toExclusive = CmsDatePredicate.date(fromIso: bounds.to),
               let to = calendar.date(byAdding: .day, value: -1, to: toExclusive) {
                return "\(op.label) · \(formatter.string(from: from)) – \(formatter.string(from: to))"
            }
            return op.label
        }
        guard let start = selStart else { return "Pick a date" }
        if op == .between || isRangeMode {
            guard let end = selEnd else {
                return "From \(formatter.string(from: start)) — pick an end date"
            }
            return "\(formatter.string(from: min(start, end))) – \(formatter.string(from: max(start, end)))"
        }
        return "\(op.label) · \(formatter.string(from: start))"
    }

    // MARK: - Month grid

    private var monthGrid: some View {
        let weeks = monthWeeks(for: anchor, cal: calendar)
        return VStack(spacing: 6) {
            // Weekday header row stays put (the native control's labels
            // don't slide); only the weeks page.
            if let firstWeek = weeks.first {
                HStack(spacing: 6) {
                    ForEach(firstWeek, id: \.self) { day in
                        Text(Self.weekdayLabel(day))
                            .font(typographyFont("dayLabelTypography", base: 12, weight: .medium))
                            .kerning(0.5)
                            .foregroundColor(typographyColor("dayLabelTypography") ?? surfaceMuted ?? .secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            dayDetailsGrid
        }
    }

    // MARK: - Pages (the week or month shown and its neighbours)

    /// The grid's pages. On iOS a paging scroll view (`CmsCalendarPager`)
    /// holds the page before, the page shown and the page after, each fully
    /// drawn (days, fills, rings, markers, today, the selection) as one view,
    /// so a page's days and markers never part. The finger moves UIKit's
    /// scroll alone; the anchor changes once the scroll has come to rest.
    @ViewBuilder
    private var pagedGrid: some View {
        let cal = calendar
        let look = dayLook
        let deco = decorations(look)
        let marked = look.markers == nil ? markedDays : []
        #if os(iOS)
        let common = pageSignatureBase
        let pages = (-1...1).map { offset -> CmsCalendarPager.Page in
            let date = CmsCalendarPaging.pageDate(anchor, offset: offset, months: monthView, calendar: cal)
            let key = CmsCalendarPaging.pageKey(date, months: monthView, calendar: cal)
            let weeks = monthView ? monthWeeks(for: date, cal: cal) : [weekDays(around: date, cal: cal)]
            return CmsCalendarPager.Page(
                key: key,
                signature: pageSignature(key: key, weeks: weeks, common: common, deco: deco, marked: marked),
                rows: weeks.count,
                // The runtime inside; the pager sets the calendar's environment around it.
                view: AnyView(page(date, weeks: weeks, look: look, deco: deco, marked: marked, cal: cal)
                    .environmentObject(runtime)))
        }
        // The page shown's size, measured by SwiftUI without drawing it (one
        // hidden row of cells, as many times as the page has weeks), grown
        // or shrunk as a swipe moves towards a page of other rows; the pager
        // draws over it.
        CmsCalendarGrowing(growth: growth) {
            pageSizer(rows: pages[1].rows, look: look, cal: cal)
        }
        .overlay(alignment: .top) {
            CmsCalendarPager(pages: pages, request: pageRequest, maxRows: monthView ? 6 : 1,
                             padding: look.ringRoom, growth: growth, live: liveResize, onPage: settle)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        #else
        page(anchor, weeks: monthView ? monthWeeks(for: anchor, cal: cal) : [weekDays(around: anchor, cal: cal)],
             look: look, deco: deco, marked: marked, cal: cal)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        #endif
    }

    /// One row of cells in their measuring form, hidden, standing for a page
    /// of `rows` rows. A fixed week, so it doesn't change as the pages do.
    private func pageSizer(rows: Int, look: CmsDayLook, cal: Calendar) -> some View {
        CmsRepeatedRowsLayout(rows: rows, spacing: 6, padding: look.ringRoom, growth: sizerGrowth) {
            HStack(spacing: 6) {
                ForEach(weekDays(around: Self.sizingWeek, cal: cal), id: \.self) { day in
                    dayCell(day, dimmed: false, compact: monthView, look: look, marked: [], cal: cal, sizing: true)
                }
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// Any week will do: every row is as tall.
    private static let sizingWeek = Date(timeIntervalSinceReferenceDate: 0)

    /// Told the row's step by the sizer, for the pager's growth.
    private var sizerGrowth: CmsCalendarGrowth? {
        #if os(iOS)
        growth
        #else
        nil
        #endif
    }

    /// What every page's drawing depends on besides its own days: the
    /// selection, today, the props (typography, colours, styles), the theme,
    /// light or dark, and the grid's width (`fit` sizes).
    private var pageSignatureBase: Int {
        var h = Hasher()
        h.combine(selStart)
        h.combine(selEnd)
        h.combine(operatorValue.rawValue)
        h.combine(CmsCalendarDecorations.dayKey(Date()))
        h.combine(gridWidth)
        h.combine(colorScheme == .dark)
        h.combine(String(describing: block.props))
        h.combine(String(describing: runtime.themeConfig))
        return h.finalize()
    }

    /// A page's signature: the base and its own days' decorations.
    private func pageSignature(key: String, weeks: [[Date]], common: Int, deco: [String: CmsCalendarDecorations.Day]?,
                               marked: Set<String>) -> Int {
        var h = Hasher()
        h.combine(key)
        h.combine(common)
        h.combine(weeks.count)
        for day in weeks.joined() {
            let dayKey = CmsCalendarDecorations.dayKey(day)
            h.combine(deco?[dayKey])
            h.combine(marked.contains(dayKey))
        }
        return h.finalize()
    }

    /// One page: a month's weeks or a week's days (`weeks`, its one week).
    @ViewBuilder
    private func page(_ date: Date, weeks: [[Date]], look: CmsDayLook, deco: [String: CmsCalendarDecorations.Day]?,
                      marked: Set<String>, cal: Calendar) -> some View {
        if monthView {
            let hideOutside = gridOptions.outsideDays == .hide
            VStack(spacing: 6) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 6) {
                        ForEach(week, id: \.self) { day in
                            let outside = !cal.isDate(day, equalTo: date, toGranularity: .month)
                            if outside && hideOutside {
                                // `hide`: a blank cell, a day's size so a row of
                                // them (six rows) keeps a row's height; nothing
                                // drawn, loaded or tapped.
                                dayCell(day, dimmed: false, compact: true, look: look, marked: [], cal: cal, sizing: true)
                                    .hidden()
                                    .accessibilityHidden(true)
                            } else {
                                dayCell(day, dimmed: outside, compact: true, look: look,
                                        decoration: deco?[CmsCalendarDecorations.dayKey(day)], marked: marked, cal: cal)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, look.ringRoom)
        } else {
            HStack(spacing: 6) {
                ForEach(weeks.first ?? [], id: \.self) { day in
                    dayCell(day, dimmed: false, look: look, decoration: deco?[CmsCalendarDecorations.dayKey(day)],
                            marked: marked, cal: cal)
                }
            }
            .padding(.vertical, look.ringRoom)
        }
    }

    /// The header's arrows. On iOS the pager slides the page on and settles
    /// as a swipe does; elsewhere the anchor moves at once.
    private func page(_ step: Int) {
        #if os(iOS)
        pageRequest = CmsCalendarPager.Request(id: (pageRequest?.id ?? 0) + 1, step: step)
        #else
        settle(step)
        #endif
    }

    /// The scroll came to rest `step` pages on: the anchor follows. The
    /// selection and the published window are untouched, as paging always
    /// left them. On iOS the height has already followed the scroll, so the
    /// new page is as tall as the calendar is; elsewhere it eases.
    private func settle(_ step: Int) {
        let next = CmsCalendarPaging.pageDate(anchor, offset: step, months: monthView, calendar: calendar)
        #if os(iOS)
        anchor = next
        #else
        withAnimation(.snappy) { anchor = next }
        #endif
    }

    /// The month's weeks (`monthRows`, `outsideDays`), each the days shown.
    private func monthWeeks(for date: Date, cal: Calendar) -> [[Date]] {
        CmsCalendarPaging.weekStarts(ofMonth: date, calendar: cal, grid: gridOptions, showWeekends: showWeekends).map { start in
            let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
            return showWeekends ? days : days.filter { !cal.isDateInWeekend($0) }
        }
    }

    // MARK: - Day cell (shared by strip + month grid)

    /// The day styles, read once per render rather than once per cell.
    private var dayLook: CmsDayLook {
        let fill = dayFillConfig
        let markers = markerConfig
        let columns = CGFloat(showWeekends ? 7 : 5)
        let column = gridWidth > 0 ? (gridWidth - 6 * (columns - 1)) / columns : 38
        let side = CGFloat(CmsCalendarDecorations.shapeSide(fill?.size ?? .fit, columnWidth: Double(column)))
        let size = markers.map { CGFloat(CmsCalendarDecorations.markerSize($0, dotSize: Double(dotSize))) } ?? dotSize
        // Markers never widen a day: in a column too narrow for `max` of them
        // they are drawn smaller, down to three quarters (one scale for the
        // whole calendar), and a day shows fewer (`markerStack`).
        let metrics = markers.map { CmsCalendarDecorations.markerRowMetrics($0, size: Double(size)) }
        let fitWidth: Double
        switch markers?.placement {
        case .below?, .overlap?: fitWidth = gridWidth > 0 ? Double(column) : 0
        case .inside?: fitWidth = gridWidth > 0 ? Double(side) : 0
        case .corner?, nil: fitWidth = 0
        }
        let scale = CGFloat(metrics.map {
            CmsCalendarDecorations.markerScale(cellWidth: fitWidth, max: markers?.max ?? CmsCalendarDecorations.defaultMax, $0)
        } ?? 1)
        return CmsDayLook(
            fill: fill, ring: CmsCalendarDecorations.dayRing(block.props["dayRing"]), markers: markers,
            today: CmsCalendarDecorations.todayStyle(block.props["todayStyle"]),
            selection: CmsCalendarDecorations.selectionStyle(block.props["selectionStyle"]),
            side: side, markerSize: size * scale,
            markerDot: (markers.map { CGFloat(CmsCalendarDecorations.markerDot($0, size: Double(size))) } ?? dotSize) * scale,
            markerGap: (markers.map { CGFloat(CmsCalendarDecorations.markerGap($0, size: Double(size))) } ?? 2) * scale,
            request: CmsCalendarDecorations.imageRequestSize(Double(size)),
            markerMetrics: metrics?.scaled(Double(scale)),
            markerFitWidth: fitWidth)
    }

    private func dayCell(_ day: Date, dimmed: Bool, compact: Bool = false, look: CmsDayLook,
                         decoration: CmsCalendarDecorations.Day? = nil, marked: Set<String>, cal: Calendar,
                         sizing: Bool = false) -> some View {
        let selected = isSelected(day, cal: cal)
        let inRange = isInRange(day, cal: cal)
        let today = cal.isDateInToday(day)
        let style = look.fill?.style ?? .filled
        let dayColor = decoration?.fill.flatMap { runtime.color($0.color) }
        let solid: Color? = style == .filled ? dayColor : nil
        // Selection `auto`: a filled day keeps its colour and gains a ring
        // outside it; any other day is filled with the selection colour
        // (inside a ring day's own ring).
        let selectionRings: Bool
        let selectionFills: Bool
        switch look.selection {
        case .auto: selectionRings = selected && solid != nil; selectionFills = selected && solid == nil
        case .ring: selectionRings = selected; selectionFills = false
        case .fill: selectionRings = false; selectionFills = selected
        }
        let plainText: Color = dimmed
            ? (typographyColor("dateTypography") ?? surfaceMuted ?? Color.secondary).opacity(surfaceMuted == nil ? 0.5 : 1)
            : (typographyColor("dateTypography") ?? surfaceText ?? runtime.theme.textPrimary)
        let authoredText = look.fill?.textColor.flatMap { runtime.color($0) }
        let textColor: Color = selectionFills ? selectionContrast
            : solid.map { authoredText ?? CmsDayLook.autoText(on: $0) }
            ?? (style == .soft && dayColor != nil ? authoredText ?? plainText : plainText)
        var background: Color = .clear
        if selectionFills {
            background = selectionColor
        } else if let dayColor, style == .filled || style == .soft {
            background = style == .soft ? dayColor.opacity(0.2) : dayColor
        } else if inRange {
            background = selectionColor.opacity(0.25)
        } else if today && look.today == .fill {
            background = selectionColor.opacity(0.18)
        }
        let ringed: Color? = style == .ring ? dayColor : nil
        let tinted = dayColor != nil && (style == .filled || style == .soft)
        let todayRinged = today && !selected && (look.today == .ring || (look.today == .auto && !tinted))
        let border: Color = ringed ?? (todayRinged ? selectionColor : .clear)
        let ringColor: Color? = decoration?.ring.map { mark in
            mark.color == CmsCalendarDecorations.RingMark.neutral
                ? surfaceText ?? .primary
                : runtime.color(mark.color) ?? CmsCss.color(mark.color) ?? .primary
        }
        let markers = look.markers.map { markerRow(decoration, config: $0, look: look, sizing: sizing) }
        let placement = look.markers?.placement ?? .below
        let shape = look.shape(outset: 0)

        let number = Text("\(cal.component(.day, from: day))")
            .font(dateFont(today: today))
            .foregroundColor(textColor)
        let face = VStack(spacing: 1) {
            number
            if placement == .inside, let markers { markers }
        }
        .frame(width: look.side, height: look.side)
        .background(shape.fill(background))
        .overlay(shape.strokeBorder(border, lineWidth: ringed == nil ? 1.5 : 2.5))
        .overlay(alignment: .bottom) {
            if style == .underline, let dayColor {
                Capsule().fill(dayColor)
                    .frame(width: look.side * 0.45, height: 3)
                    .padding(.bottom, look.side * 0.1)
            }
        }
        .overlay(alignment: .bottom) {
            // Today's `dot`, under the number.
            if today && look.today == .dot && !selectionFills {
                Circle().fill(selectionColor)
                    .frame(width: 4, height: 4)
                    .padding(.bottom, look.side * 0.12)
            }
        }
        .overlay {
            if let ringColor, let ring = look.ring {
                look.shape(outset: look.ringOutset)
                    .strokeBorder(ringColor, lineWidth: CGFloat(ring.width))
                    .padding(-look.ringOutset)
            }
        }
        .overlay {
            if selectionRings {
                look.shape(outset: look.selectionOutset)
                    .strokeBorder(selectionColor, lineWidth: 2)
                    .padding(-look.selectionOutset)
            }
        }
        .overlay(alignment: placement == .corner ? .topTrailing : .bottom) {
            if let markers, placement == .overlap {
                markers.offset(y: look.markerSize / 2)
            } else if let markers, placement == .corner {
                markers.offset(x: look.markerSize / 2 - look.cornerInset, y: look.cornerInset - look.markerSize / 2)
            }
        }
        .padding(look.ringOutset)
        .opacity(dimmed && (dayColor != nil || ringColor != nil) ? 0.45 : 1)

        return Button {
            tapped(day)
        } label: {
            VStack(spacing: compact ? 2 : 4) {
                if !compact {
                    Text(Self.weekdayLabel(day))
                        .font(typographyFont("dayLabelTypography", base: 12, weight: .medium))
                        .kerning(0.5)
                        .foregroundColor(typographyColor("dayLabelTypography") ?? surfaceMuted ?? .secondary)
                }
                face
                if let markers {
                    // Clear of a selection ring drawn outside a day ring.
                    if placement == .below { markers.padding(.top, look.ring == nil ? 0 : 2) }
                    // Room under a row whose markers hang below the shape.
                    if placement == .overlap { Color.clear.frame(height: max(0, look.markerSize / 2 - look.ringOutset)) }
                } else {
                    Circle()
                        .fill(marked.contains(CmsCalendarDecorations.dayKey(day)) ? selectionColor : Color.clear)
                        .frame(width: dotSize, height: dotSize)
                }
            }
            // Every day its column's share, whatever it draws: nothing in a
            // day widens it or the grid.
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .cmsInspectorID("Cms.simpleCalendar.day")
    }

    /// Single-letter day label ("M T W…"), the web's `EEEEE` format.
    private static func weekdayLabel(_ day: Date) -> String {
        weekdayFormatter.string(from: day)
    }

    /// One formatter for every label (a page draws up to 42 cells).
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter
    }()

    // MARK: - Slim predicate row (native Menu + DatePicker, not a web mimic)

    private var slimRow: some View {
        HStack(spacing: 10) {
            Menu { MenuIcons {
                ForEach(CmsRangePredicateOperator.menuOrder, id: \.rawValue) { op in
                    Button {
                        setOperator(op)
                    } label: {
                        if op == operatorValue {
                            Label(op.label, systemImage: "checkmark")
                        } else {
                            Text(op.label)
                        }
                    }
                }
            }} label: {
                HStack(spacing: 4) {
                    Text(operatorValue.label)
                        .font(typographyFont("predicateTypography", base: 14, weight: .regular))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11))
                }
                .foregroundColor(typographyColor("predicateTypography") ?? runtime.theme.textPrimary)
                .padding(.horizontal, lozengeFill == nil ? 0 : 10)
                .frame(minHeight: 32)
                .background {
                    if let fill = lozengeFill {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
                    }
                }
                .overlay {
                    if let border = lozengeBorder {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(border)
                    }
                }
            }

            Spacer(minLength: 0)

            if operatorValue.needsDate {
                dateChip(.start, value: selStart, placeholder: operatorValue == .between ? "Start date" : "Pick a date")
                if operatorValue == .between {
                    Text("and")
                        .font(typographyFont("predicateTypography", base: 13, weight: .regular))
                        .foregroundColor(typographyColor("predicateTypography") ?? .secondary)
                    dateChip(.end, value: selEnd, placeholder: "End date")
                }
            }

            if toggleShown { modeToggle }
        }
        .modifier(DateChipPickerPresenter(target: $dateChipTarget) { target in
            dateChipPicker(target)
        })
    }

    // MARK: - Slim date chips (twin of the web's DateDropdown)

    /// The web chip: bordered box on the PORTAL paper colour, `MMM d, yyyy`
    /// in dateDropdownTypography (else text.primary; placeholder disabled),
    /// chevron following the text colour. A compact DatePicker can't take
    /// any of that styling, so the chip is drawn and the tap opens the
    /// native graphical picker — a quick-selection popover per doctrine.
    fileprivate enum DateChipTarget: String, Identifiable {
        case start, end
        var id: String { rawValue }
    }

    /// The block's pill colours (`lozengeBackground` / `lozengeBorderColor`,
    /// SimpleCalendarBlock's LozengeColors): a slim row on a coloured band
    /// draws translucent pills so its light text reads.
    private var lozengeFill: Color? { runtime.color(block.props.string("lozengeBackground")) }
    private var lozengeBorder: Color? { runtime.color(block.props.string("lozengeBorderColor")) }

    private func dateChip(_ target: DateChipTarget, value: Date?, placeholder: String) -> some View {
        let typo = block.props.object("dateDropdownTypography")
        let authored = runtime.color(typo?.string("color"))
        let textColor = authored ?? (value != nil ? runtime.theme.textPrimary : runtime.theme.textSecondary)
        let font = Font.system(size: CmsTypography.size(typo) ?? 14,
                               weight: CmsTypography.weight(typo) ?? .regular)
        let formatter = DateFormatter()
        // Phones drop this year's year, as the web's short chips do.
        let thisYear = value.map { calendar.component(.year, from: $0) == calendar.component(.year, from: Date()) } ?? false
        formatter.dateFormat = thisYear ? "MMM d" : "MMM d, yyyy"
        return Button {
            dateChipTarget = target
        } label: {
            HStack(spacing: 4) {
                Text(value.map { formatter.string(from: $0) } ?? placeholder)
                    .font(font)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11))
                    .foregroundColor(textColor)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(lozengeFill ?? runtime.theme.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(lozengeBorder ?? runtime.theme.divider)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Graphical date picker for a chip; picking a date dismisses it (the
    /// web popover closes on pick too). Kept to the picker's natural size —
    /// it presents as an anchored popover card, not a half-screen sheet.
    private func dateChipPicker(_ target: DateChipTarget) -> some View {
        let base = target == .start ? startBinding : endBinding
        let binding = Binding<Date>(
            get: { base.wrappedValue },
            set: { newValue in
                base.wrappedValue = newValue
                dateChipTarget = nil
            }
        )
        return DatePicker("", selection: binding, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(12)
            .frame(width: 320)
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { selStart ?? calendar.startOfDay(for: Date()) },
            set: { newValue in
                selStart = calendar.startOfDay(for: newValue)
                publishSelection()
            }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { selEnd ?? selStart ?? calendar.startOfDay(for: Date()) },
            set: { newValue in
                selEnd = calendar.startOfDay(for: newValue)
                publishSelection()
            }
        )
    }

    private func setOperator(_ op: CmsRangePredicateOperator) {
        operatorValue = op
        if op != .between { selEnd = nil }
        publishSelection()
    }

    // MARK: - Indicator dots

    /// Days with rows, by local day key. A datetime counts on its local
    /// day, as on the web (CmsCalendarDecorations.localDayKey).
    private var markedDays: Set<String> {
        guard !dateColumn.isEmpty, case .ok(let result) = runtime.state(for: querySlug) else { return [] }
        return Set(result.rows.compactMap { CmsCalendarDecorations.localDayKey($0[dateColumn]) })
    }

    // MARK: - Day decorations (dayFill, dayRing, markers, legend)

    private var dayFillConfig: CmsCalendarDecorations.DayFill? { CmsCalendarDecorations.dayFill(block.props["dayFill"]) }
    private var markerConfig: CmsCalendarDecorations.Markers? { CmsCalendarDecorations.markers(block.props["markers"]) }

    /// Each day's shape, ring and markers, or nil when the block has none of them.
    private func decorations(_ look: CmsDayLook) -> [String: CmsCalendarDecorations.Day]? {
        guard look.fill != nil || look.markers != nil || look.ring != nil, !dateColumn.isEmpty,
              case .ok(let result) = runtime.state(for: querySlug) else { return nil }
        return CmsCalendarDecorations.decorate(rows: result.rows, dateColumn: dateColumn, fill: look.fill,
                                               markers: look.markers, ring: look.ring)
    }

    /// One marker per key (an image, else its fallback), then the overflow.
    /// Fixed height so empty days don't move the grid. A negative gap stacks
    /// the markers like coins, each drawn over the one before it; the overflow
    /// keeps its own space after them.
    @ViewBuilder
    private func markerRow(_ decoration: CmsCalendarDecorations.Day?, config: CmsCalendarDecorations.Markers,
                           look: CmsDayLook, sizing: Bool = false) -> some View {
        if sizing {
            // Measuring only: the row's height, nothing to load.
            Color.clear.frame(width: 1, height: look.markerSize)
        } else {
            markerStack(decoration, config: config, look: look)
        }
    }

    private func markerStack(_ decoration: CmsCalendarDecorations.Day?, config: CmsCalendarDecorations.Markers,
                             look: CmsDayLook) -> some View {
        let size = look.markerSize
        // The day's markers that fit its cell; the rest join the overflow.
        let all = decoration?.markers ?? []
        let total = all.count + (decoration?.overflow ?? 0)
        let shown = look.markerMetrics.map {
            CmsCalendarDecorations.markersShown(count: total, max: all.count, cellWidth: look.markerFitWidth, $0)
        } ?? all.count
        let markers = Array(all.prefix(shown))
        let overflow = total - markers.count
        let overflowColor = surfaceMuted ?? Color.secondary
        let border = config.usesImages ? config.border.map { (CGFloat($0.width), runtime.color($0.color) ?? .clear) } : nil
        let imageBackground = config.imageBackground.flatMap { runtime.color($0) }
        // After coins (a negative gap) the overflow sits 2 pt from the last one, as on the web.
        return HStack(spacing: look.markerGap < 0 ? 2 : look.markerGap) {
            if !markers.isEmpty {
                HStack(spacing: look.markerGap) {
                    ForEach(markers, id: \.key) { marker in
                        CmsDayMarkerView(
                            candidates: marker.images,
                            color: runtime.color(marker.color) ?? CmsCss.color(marker.color) ?? selectionColor,
                            size: size, request: look.request,
                            cache: marker.images.isEmpty ? nil : CmsMarkerImageCache.forPage(runtime),
                            fallback: markerFallback(config, marker: marker, look: look),
                            background: imageBackground,
                            paper: runtime.theme.paper,
                            holdWhileLoading: config.look == .images,
                            rounded: config.imageShape == .rounded,
                            border: border
                        )
                    }
                }
            }
            if let text = CmsCalendarDecorations.overflowText(overflow, config.overflow) {
                // The fit rule's fonts: "+" from the dot (the size of a dot, as
                // the web and WAC draw it), "+n" from the marker's size.
                let font = look.markerMetrics.map { CGFloat(CmsCalendarDecorations.overflowFont($0)) }
                    ?? max(9, (size * 0.8).rounded())
                Text(text)
                    .font(.system(size: font, weight: config.overflow == .plus ? .heavy : .medium))
                    .foregroundColor(overflowColor)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: size)
        .accessibilityHidden(true)
    }

    /// What a marker draws without an image (the web's rule too). `auto` and
    /// `dots` keep the dot they always drew; `images` takes `imageFallback`.
    private func markerFallback(_ config: CmsCalendarDecorations.Markers, marker: CmsCalendarDecorations.DayMarker,
                                look: CmsDayLook) -> CmsDayMarkerView.Fallback {
        // The row's icon (`iconColumn`): a badge, whatever the look (dots carry none).
        if let icon = marker.icon { return .icon(icon) }
        guard config.look == .images else { return .dot(look.markerDot) }
        switch config.imageFallback {
        case .dot: return .disc
        case .initial: return .initial(CmsCalendarDecorations.markerInitial(marker.label))
        case .placeholder:
            // `imageBackground`, else the web's disabled fill (12% of the text colour).
            return .placeholder(config.imageBackground.flatMap { runtime.color($0) } ?? Color.primary.opacity(0.12))
        }
    }

    /// The key to the day shapes' and rings' colours, under the calendar.
    @ViewBuilder
    private var legend: some View {
        let fill = dayFillConfig
        let ring = CmsCalendarDecorations.dayRing(block.props["dayRing"])
        let fills = (fill?.values ?? []).filter { $0.label != nil }
        let rings = (ring?.values ?? []).filter { $0.label != nil }
        if block.props.bool("legend") == true, !fills.isEmpty || !rings.isEmpty {
            CmsStepFlowLayout(spacing: 12) {
                ForEach(fills, id: \.value) { v in
                    legendItem(v, sample: legendSample(runtime.color(v.color) ?? .clear, style: fill?.style ?? .filled))
                }
                ForEach(rings, id: \.value) { v in
                    legendItem(v, sample: Circle().strokeBorder(runtime.color(v.color) ?? .clear, lineWidth: 2).frame(width: 10, height: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendItem(_ v: CmsCalendarDecorations.FillValue, sample: some View) -> some View {
        HStack(spacing: 4) {
            sample
            Text(v.label ?? "")
                .font(.system(size: 12))
                .foregroundColor(surfaceMuted ?? .secondary)
        }
    }

    @ViewBuilder
    private func legendSample(_ c: Color, style: CmsCalendarDecorations.FillStyle) -> some View {
        switch style {
        case .ring: Circle().strokeBorder(c, lineWidth: 2).frame(width: 10, height: 10)
        case .soft: Circle().fill(c.opacity(0.35)).frame(width: 10, height: 10)
        case .underline: Capsule().fill(c).frame(width: 10, height: 3).frame(height: 10)
        case .filled, .none: Circle().fill(c).frame(width: 10, height: 10)
        }
    }

    // MARK: - Selection

    private func isSelected(_ day: Date, cal: Calendar) -> Bool {
        if let s = selStart, cal.isDate(day, inSameDayAs: s) { return true }
        if let e = selEnd, cal.isDate(day, inSameDayAs: e) { return true }
        return false
    }

    private func isInRange(_ day: Date, cal: Calendar) -> Bool {
        guard let s = selStart, let e = selEnd else { return false }
        let d = cal.startOfDay(for: day)
        return d > cal.startOfDay(for: s) && d < cal.startOfDay(for: e)
    }

    // MARK: - A day's details (`onDayTap`, `dayDetails`)

    /// The open details' day.
    struct DetailsDay: Identifiable, Equatable {
        /// Its day key (yyyy-MM-dd): the add form's `{day}`.
        let id: String
        let day: Date
    }

    private var dayDetailsConfig: CmsCalendarDayDetails.Config? {
        CmsCalendarDayDetails.Config(block.props["dayDetails"])
    }

    /// A day's rows: the calendar's own query, or the details' own, by the
    /// same local day the decorations use.
    private func detailsRows(for day: Date, config: CmsCalendarDayDetails.Config) -> [[String: CmsJSON]] {
        let slug = config.querySlug ?? querySlug
        let column = config.dateColumn ?? dateColumn
        guard !column.isEmpty, case .ok(let result) = runtime.state(for: slug) else { return [] }
        let key = CmsCalendarDecorations.dayKey(day)
        return result.rows.filter { CmsCalendarDecorations.localDayKey($0[column]) == key }
    }

    /// A day's tap: it selects the day, opens its details, or both (`onDayTap`).
    private func tapped(_ day: Date) {
        let config = dayDetailsConfig
        let rows = config.map { detailsRows(for: day, config: $0).count } ?? 0
        let outcome = CmsCalendarDayDetails.outcome(CmsCalendarDayDetails.tapAction(block.props), details: config, rows: rows)
        if outcome.select { select(day) }
        if outcome.open { detailsDay = DetailsDay(id: CmsCalendarDecorations.dayKey(day), day: day) }
    }

    /// The grid, with the open day's details in the system popover anchored
    /// to that day (a popover on iPhone too, not a sheet).
    private var dayDetailsGrid: some View {
        pagedGrid
            .popover(item: $detailsDay, attachmentAnchor: .rect(.rect(detailsAnchor))) { item in
                detailsContent(item)
            }
    }

    /// The open day's cell, in the grid's own points: its column and week.
    private var detailsAnchor: CGRect {
        guard let item = detailsDay else { return .zero }
        let cal = calendar
        let columns = CGFloat(showWeekends ? 7 : 5)
        let width = gridWidth > 0 ? (gridWidth - 6 * (columns - 1)) / columns : 38
        let weeks = monthView ? monthWeeks(for: anchor, cal: cal) : [weekDays(around: anchor, cal: cal)]
        #if os(iOS)
        let step = growth.rowStep > 0 ? growth.rowStep : 50
        #else
        let step: CGFloat = 50
        #endif
        for (r, week) in weeks.enumerated() {
            if let c = week.firstIndex(where: { cal.isDate($0, inSameDayAs: item.day) }) {
                return CGRect(x: CGFloat(c) * (width + 6), y: dayLook.ringRoom + CGFloat(r) * step,
                              width: width, height: max(1, step - 6))
            }
        }
        return CGRect(x: 0, y: 0, width: max(1, gridWidth), height: step)
    }

    @ViewBuilder
    private func detailsContent(_ item: DetailsDay) -> some View {
        if let config = dayDetailsConfig {
            let rows = detailsRows(for: item.day, config: config)
            CmsCalendarDayDetailsView(
                title: CmsCalendarDayDetails.title(config.title, count: rows.count) { pattern in
                    let formatter = DateFormatter()
                    formatter.dateFormat = pattern
                    return formatter.string(from: item.day)
                },
                rows: rows,
                config: config,
                style: CmsResolvedListStyle(config: runtime.themeConfig, block: config.listStyle, theme: runtime.theme),
                tint: runtime.theme.primary,
                onRow: config.rowTap.map { tap in { row in closeDetails { openDetailsRow(row, tap: tap, config: config) } } },
                onAdd: config.add.map { add in {
                    closeDetails { detailsForm = CmsRecordFormRequest(spec: add.form, row: ["day": .string(item.id)]) }
                } }
            )
            .environmentObject(runtime)
            .presentationCompactAdaptation(.popover)
        }
    }

    /// Closes the popover, then runs `action` (a sheet can't open while it goes).
    private func closeDetails(then action: @escaping () -> Void) {
        afterDetails = action
        detailsDay = nil
    }

    /// A details row's tap: its record's form, or a page with the row (and
    /// the params) as its query's selection, as a card's open does.
    private func openDetailsRow(_ row: [String: CmsJSON], tap: CmsCalendarDayDetails.RowTap, config: CmsCalendarDayDetails.Config) {
        switch tap {
        case .form(let spec):
            detailsForm = CmsRecordFormRequest(spec: spec, row: row)
        case .page(let page, let params):
            var selected = row
            for (name, template) in params {
                let trimmed = template.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
                   trimmed.dropFirst().dropLast().allSatisfy({ $0 != "{" && $0 != "}" && $0 != "|" }) {
                    selected[name] = row[String(trimmed.dropFirst().dropLast())] ?? .null
                } else {
                    selected[name] = .string(CmsFormText.fill(template) { n, _ in row[n].map { CmsCards.text($0) } ?? "" })
                }
            }
            runtime.setSelectedRows(config.querySlug ?? querySlug, rows: [selected])
            runtime.navigate(toPage: page)
        }
    }

    /// Grid tap. Range mode implies `between` (start pick then end pick);
    /// single mode implies the current single-date operator (default `eq`).
    private func select(_ day: Date) {
        // A swipe never reaches here: the pager's scroll cancels the day's touch.
        if isRangeMode {
            operatorValue = .between
        } else if operatorValue == .between || !operatorValue.needsDate {
            operatorValue = .eq
        }
        (selStart, selEnd) = Self.pick(day, start: selStart, end: selEnd, range: isRangeMode, calendar: calendar)
        publishSelection()
    }

    /// A tap's new selection, twin of the web's handleDayClick. Single: the
    /// tapped day, or nothing when it was already the pick. Range: a first tap
    /// starts it, a second completes it (either order), tapping the open start
    /// again clears it, and a tap on a complete range starts a new one. With
    /// nothing picked the block publishes no row, so a list it filters shows
    /// everything again.
    static func pick(_ day: Date, start: Date?, end: Date?, range: Bool, calendar: Calendar) -> (Date?, Date?) {
        let d = calendar.startOfDay(for: day)
        guard range else {
            if let s = start, calendar.isDate(s, inSameDayAs: d) { return (nil, nil) }
            return (d, nil)
        }
        guard let s = start.map({ calendar.startOfDay(for: $0) }) else { return (d, nil) }
        guard end == nil else { return (d, nil) }
        if d == s { return (nil, nil) }
        return d < s ? (d, s) : (s, d)
    }

    private func applyDefaultSelection() {
        guard selStart == nil else { return }
        let now = Date()
        switch block.props.string("defaultSelection") ?? "none" {
        case "today":
            selStart = calendar.startOfDay(for: now)
        case "firstOfMonth":
            selStart = calendar.dateInterval(of: .month, for: now)?.start
            // Range mode: the month's last day as the end, so the default is
            // a full month that fires at once (SimpleCalendarBlock initialEnd).
            if (block.props.string("selectionMode") ?? "single") != "single",
               let interval = calendar.dateInterval(of: .month, for: now) {
                selEnd = calendar.date(byAdding: .day, value: -1, to: interval.end).map { calendar.startOfDay(for: $0) }
            }
        case "lastOfMonth":
            if let interval = calendar.dateInterval(of: .month, for: now) {
                selStart = calendar.date(byAdding: .day, value: -1, to: interval.end).map { calendar.startOfDay(for: $0) }
            }
        case "startOfYear":
            selStart = calendar.dateInterval(of: .year, for: now)?.start
        default:
            break
        }
        publishSelection()
    }

    // MARK: - Output row (exact mirror of the web block's outputRow)

    /// When `parameterId` is set, the block also writes the shared Parameter
    /// (datePredicate kind: operator + start/end) so subscribed queries
    /// re-resolve through the kind's projections — twin of the web's
    /// useParameter write path. The private output row is published either way.
    private func writeParameterIfBound() {
        guard let parameterId = block.props.string("parameterId"), !parameterId.isEmpty else { return }
        let value: CmsJSON = .object([
            "operator": .string(operatorValue.rawValue),
            "start": selStart.map { .string(CmsDatePredicate.iso($0)) } ?? .null,
            "end": selEnd.map { .string(CmsDatePredicate.iso($0)) } ?? .null,
        ])
        runtime.setParameter(parameterId, value: value)
    }

    private func publishSelection() {
        writeParameterIfBound()
        let slug = block.slug ?? block.id
        let op = operatorValue

        // 'any' = no filter: open range regardless of selection.
        if op == .any {
            publishRow(slug: slug, date: "", start: "", end: "",
                       bounds: CmsDateBounds(from: CmsDatePredicate.dateMin, to: CmsDatePredicate.dateMax), op: op)
            return
        }
        // Relative periods resolve from today — no pick needed.
        if op.isPeriod {
            let bounds = CmsDatePredicate.boundsForRange(op, start: "")
            publishRow(slug: slug, date: "", start: bounds.from, end: bounds.to, bounds: bounds, op: op)
            return
        }
        // Waiting for a date pick — publish nothing (web emits null).
        guard let s = selStart else {
            runtime.setSelectedRows(slug, rows: [])
            return
        }
        let useRange = op == .between && selEnd != nil
        let a = s
        let b = useRange ? selEnd! : s
        let lo = min(a, b)
        let hi = max(a, b)
        let loIso = CmsDatePredicate.iso(lo)
        let hiIso = CmsDatePredicate.iso(hi)
        let bounds = CmsDatePredicate.boundsForRange(op, start: loIso, end: useRange ? hiIso : nil)
        publishRow(slug: slug, date: useRange ? "" : loIso, start: loIso, end: hiIso, bounds: bounds, op: op)
    }

    private func publishRow(slug: String, date: String, start: String, end: String, bounds: CmsDateBounds, op: CmsRangePredicateOperator) {
        let row: [String: CmsJSON] = [
            "date": .string(date),
            "date_start": .string(start),
            "date_end": .string(end),
            "from": .string(bounds.from),
            "to": .string(bounds.to),
            "operator": .string(op.rawValue),
        ]
        runtime.setSelectedRows(slug, rows: [row])
    }
}

/// The day styles resolved for one render of the grid: the props parsed once
/// and the sizes every cell shares.
struct CmsDayLook {
    var fill: CmsCalendarDecorations.DayFill?
    var ring: CmsCalendarDecorations.DayRing?
    var markers: CmsCalendarDecorations.Markers?
    var today: CmsCalendarDecorations.TodayStyle
    var selection: CmsCalendarDecorations.SelectionStyle
    /// The day shape's side.
    var side: CGFloat
    var markerSize: CGFloat
    var markerDot: CGFloat
    /// Between markers, stopped at half a marker; negative overlaps them.
    var markerGap: CGFloat
    var request: Int
    /// The markers as the shared fit rule measures them, at the scale drawn
    /// (`markerSize`, `markerGap` and `markerDot` are already at it).
    var markerMetrics: CmsCalendarDecorations.MarkerRowMetrics? = nil
    /// The width a day's markers fit in: its column (below, overlapping),
    /// its shape (inside); 0 for a corner badge or before the grid is measured.
    var markerFitWidth: Double = 0

    var corner: CGFloat { CGFloat(CmsCalendarDecorations.shapeRadius(fill?.shape ?? .circle, side: Double(side))) }

    /// The day's shape, or a ring `outset` points outside it (concentric).
    func shape(outset: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: corner == 0 ? 0 : corner + outset,
                         style: fill?.shape == .rounded ? .continuous : .circular)
    }

    private static func components(_ color: Color) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        if let srgb = NSColor(color).usingColorSpace(.sRGB) { srgb.getRed(&r, green: &g, blue: &b, alpha: &a) }
        #endif
        return (Double(r), Double(g), Double(b))
    }

    /// `auto` text on a day's fill, and a marker's initial: black or white by
    /// WCAG luminance, as the web.
    static func autoText(on color: Color) -> Color {
        let (r, g, b) = components(color)
        return CmsCalendarDecorations.blackTextOn(r: r, g: g, b: b) ? .black : .white
    }

    /// How far the day ring reaches outside the shape.
    var ringOutset: CGFloat { ring.map { CGFloat($0.gap + $0.width) } ?? 0 }

    /// From the shape's bounding corner in to its edge on the diagonal, where a corner badge centres.
    var cornerInset: CGFloat { corner * (1 - 0.7071) }

    /// The selection ring's outer edge beyond the shape: as before without a
    /// day ring; tight outside one (1 pt gap, 2 pt line) so it stays clear of
    /// the markers below.
    var selectionOutset: CGFloat { ring == nil ? 4.5 : ringOutset + 3 }

    /// Room inside the paging clip for rings drawn outside the shape. None
    /// without a day shape or ring, so the grid is as before.
    var ringRoom: CGFloat {
        guard fill != nil || ring != nil else { return 0 }
        return ring == nil ? 4 : selectionOutset
    }
}

/// One day marker: the first image of its chain that loads, else its
/// fallback. An `images` marker shows only its background (and ring) while
/// its image loads, so a fallback never flashes before a logo arrives.
private struct CmsDayMarkerView: View {
    enum Fallback {
        /// The earlier look: a dot of this diameter, centred in the marker's slot.
        case dot(CGFloat)
        /// A full-size disc in the marker's colour.
        case disc
        /// That disc with a letter on it.
        case initial(String)
        /// That disc with an icon on it (an SF Symbol name): a badge.
        case icon(String)
        /// A neutral shape in this colour.
        case placeholder(Color)
    }

    let candidates: [CmsCalendarDecorations.ImageCandidate]
    let color: Color
    let size: CGFloat
    let request: Int
    let cache: CmsMarkerImageCache?
    var fallback: Fallback
    /// The configured `imageBackground`: behind an image and as the marker while it loads.
    var background: Color?
    /// Behind an image when no `imageBackground` is set.
    var paper: Color = .clear
    var holdWhileLoading = false
    var rounded = false
    var border: (CGFloat, Color)?
    @State private var image: CmsPlatformImage?
    @State private var loading = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: rounded ? (size * 0.25).rounded() : size / 2, style: rounded ? .continuous : .circular)
    }

    /// The border, outside the marker's size (the web's box-shadow), so it
    /// takes no room and a later coin's ring lies over the one before.
    @ViewBuilder
    private var ring: some View {
        if let border {
            let corner = rounded ? (size * 0.25).rounded() : size / 2
            RoundedRectangle(cornerRadius: corner + border.0, style: rounded ? .continuous : .circular)
                .strokeBorder(border.1, lineWidth: border.0)
                .padding(-border.0)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(cmsPlatformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .background(background ?? paper)
                    .clipShape(shape)
                    .overlay { ring }
            } else if holdWhileLoading, loading, !candidates.isEmpty {
                shape.fill(background ?? .clear)
                    .frame(width: size, height: size)
                    .overlay { ring }
            } else {
                switch fallback {
                case .dot(let diameter):
                    Circle()
                        .fill(color)
                        .frame(width: diameter, height: diameter)
                        .frame(width: diameter, height: size)
                case .disc:
                    shape.fill(color)
                        .frame(width: size, height: size)
                        .overlay { ring }
                case .initial(let letter):
                    shape.fill(color)
                        .frame(width: size, height: size)
                        .overlay {
                            Text(letter)
                                .font(.system(size: max(7, (size * 0.55).rounded()), weight: .semibold))
                                .foregroundColor(CmsDayLook.autoText(on: color))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                        .overlay { ring }
                case .icon(let name):
                    shape.fill(color)
                        .frame(width: size, height: size)
                        .overlay {
                            // A nav icon key (the web's too), else an SF Symbol name.
                            Image(systemName: CmsNavIcon.symbol(for: name) ?? name)
                                .resizable()
                                .scaledToFit()
                                .fontWeight(.semibold)
                                .frame(width: (size * 0.6).rounded(), height: (size * 0.6).rounded())
                                .foregroundColor(CmsDayLook.autoText(on: color))
                        }
                        .overlay { ring }
                case .placeholder(let neutral):
                    shape.fill(neutral)
                        .frame(width: size, height: size)
                        .overlay { ring }
                }
            }
        }
        .task(id: candidates) {
            guard let cache, !candidates.isEmpty else { image = nil; loading = false; return }
            loading = true
            image = await cache.resolve(candidates, size: request)
            loading = false
        }
        .accessibilityHidden(true)
    }
}

/// Presents a slim-row date chip's picker as an ANCHORED POPOVER card —
/// the web Popover reading; `presentationCompactAdaptation(.popover)`
/// keeps the compact card on iPhone (iOS 16.4+) instead of inflating to a
/// half-screen sheet. Older OSes fall back to a sheet.
private struct DateChipPickerPresenter<PickerContent: View>: ViewModifier {
    @Binding var target: CmsSimpleCalendarBlockView.DateChipTarget?
    let picker: (CmsSimpleCalendarBlockView.DateChipTarget) -> PickerContent

    init(target: Binding<CmsSimpleCalendarBlockView.DateChipTarget?>,
         @ViewBuilder picker: @escaping (CmsSimpleCalendarBlockView.DateChipTarget) -> PickerContent) {
        _target = target
        self.picker = picker
    }

    func body(content: Content) -> some View {
        if #available(iOS 16.4, macOS 13.3, *) {
            content.popover(item: $target, arrowEdge: .bottom) { t in
                picker(t)
                    .presentationCompactAdaptation(.popover)
            }
        } else {
            content.ripulSheet(item: $target) { t in
                picker(t)
            }
        }
    }
}
