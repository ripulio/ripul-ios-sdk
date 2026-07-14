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
    /// Month-swipe state: which edge the incoming month slides from, and
    /// the in-flight finger offset.
    @State private var monthSlide: Edge = .trailing
    @State private var monthDragX: CGFloat = 0
    /// Which slim-row date chip is picking (drives the picker sheet).
    @State private var dateChipTarget: DateChipTarget?

    // MARK: - Props

    private var querySlug: String { block.props.string("querySlug") ?? "" }
    private var dateColumn: String { block.props.string("dateColumn") ?? "" }
    private var isRangeMode: Bool { (block.props.string("selectionMode") ?? "range") == "range" }
    private var monthView: Bool { (block.props.string("view") ?? "week") == "month" }
    private var showWeekends: Bool { block.props.bool("showWeekends") ?? true }
    private var allowModeToggle: Bool { block.props.bool("allowModeToggle") ?? true }
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
        }
        .padding(12)
        .background(
            // The web passes backgroundColor RAW into sx — theme tokens are
            // NOT resolved for this prop and render as no background at all,
            // letting the block frame's fill show through (real portals rely
            // on this: token bg + coloured frame = transparent block on the
            // frame colour). Mirror exactly: CSS literals only, else clear.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(CmsCss.color(block.props.string("backgroundColor")) ?? Color.clear)
        )
        .onAppear {
            runtime.ensureLoaded(querySlug)
            configureOnce()
        }
    }

    private func configureOnce() {
        guard !configured else { return }
        configured = true
        // Start from the user's last-chosen mode, persisted per block
        // instance (cmsId + slug) — twin of the web's localStorage mode
        // memory — falling back to the author default.
        displayMode = UserDefaults.standard.string(forKey: modePersistenceKey)
            ?? block.props.string("displayMode") ?? "grid"
        operatorValue = block.props.string("defaultOperator")
            .flatMap(CmsRangePredicateOperator.init(rawValue:)) ?? .between
        // Two-way parameter binding: restore the user's last predicate
        // (operator + dates) from the shared Parameter — persisted by the
        // runtime across visits — before falling back to author defaults.
        if let parameterId = block.props.string("parameterId"), !parameterId.isEmpty,
           let saved = runtime.parameters[parameterId]?.objectValue,
           let op = saved.string("operator").flatMap(CmsRangePredicateOperator.init(rawValue:)) {
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

    private var gridHeader: some View {
        HStack(spacing: 4) {
            Text(monthTitle)
                .font(typographyFont("titleTypography", base: 14, weight: .semibold))
                .foregroundColor(typographyColor("titleTypography") ?? .primary)
            Spacer()
            if allowModeToggle { modeToggle }
            pagerButton(systemName: "chevron.left", step: -1)
            pagerButton(systemName: "chevron.right", step: 1)
        }
    }

    private func pagerButton(systemName: String, step: Int) -> some View {
        Button {
            if monthView {
                pageMonth(step)
            } else {
                withAnimation(.snappy) {
                    anchor = calendar.date(byAdding: .weekOfYear, value: step, to: anchor) ?? anchor
                }
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(accentColor)
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
        .foregroundColor(accentColor)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: anchor)
    }

    // MARK: - Week strip

    private var weekStrip: some View {
        HStack(spacing: 6) {
            ForEach(weekDays(around: anchor), id: \.self) { day in
                dayCell(day, dimmed: false)
            }
        }
    }

    private func weekDays(around date: Date) -> [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        let all = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        return showWeekends ? all : all.filter { !calendar.isDateInWeekend($0) }
    }

    // MARK: - Month view (compact custom grid + native-style month swiping)

    /// Month view = the compact custom grid (user decision, after weighing
    /// the UICalendarView trade-off: the system control exposes no
    /// typography/density API, so web-scale density won) — with the native
    /// control's month swiping ported: a horizontal drag follows the finger
    /// and pages months with an edge slide. CmsNativeMonthCalendar is kept
    /// unused should the system control return as a designer option.
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
        .foregroundColor(typographyColor("predicateTypography") ?? .secondary)
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
        let weeks = monthWeeks
        return VStack(spacing: 6) {
            // Weekday header row stays put (the native control's labels
            // don't slide); only the weeks page.
            if let firstWeek = weeks.first {
                HStack(spacing: 6) {
                    ForEach(firstWeek, id: \.self) { day in
                        Text(weekdayLabel(day))
                            .font(typographyFont("dayLabelTypography", base: 12, weight: .medium))
                            .kerning(0.5)
                            .foregroundColor(typographyColor("dayLabelTypography") ?? .secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            ZStack {
                VStack(spacing: 6) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 6) {
                            ForEach(week, id: \.self) { day in
                                dayCell(day, dimmed: !calendar.isDate(day, equalTo: anchor, toGranularity: .month), compact: true)
                            }
                        }
                    }
                }
                // New identity per month so paging runs the edge-slide
                // transition (incoming from monthSlide, outgoing opposite).
                .id(monthIdentity)
                .transition(.asymmetric(
                    insertion: .move(edge: monthSlide),
                    removal: .move(edge: monthSlide == .trailing ? .leading : .trailing)
                ))
            }
            .offset(x: monthDragX)
            .clipped()
        }
        .contentShape(Rectangle())
        // simultaneousGesture, not .gesture: inside the page ScrollView and
        // over the day-cell Buttons a plain gesture is starved of onChanged
        // updates (it only resolves on a decisive flick). Simultaneous
        // streams the drag; the horizontal-dominance guard keeps vertical
        // page scrolls from nudging the grid.
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    monthDragX = value.translation.width
                }
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else {
                        withAnimation(.snappy) { monthDragX = 0 }
                        return
                    }
                    if value.translation.width < -60 {
                        pageMonth(1)
                    } else if value.translation.width > 60 {
                        pageMonth(-1)
                    } else {
                        withAnimation(.snappy) { monthDragX = 0 }
                    }
                }
        )
    }

    private var monthIdentity: String {
        let c = calendar.dateComponents([.year, .month], from: anchor)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    /// Page the visible month with the native control's slide: the incoming
    /// month enters from the direction of travel, the outgoing one leaves
    /// through the opposite edge, and any in-flight finger offset settles.
    private func pageMonth(_ step: Int) {
        monthSlide = step > 0 ? .trailing : .leading
        withAnimation(.snappy) {
            anchor = calendar.date(byAdding: .month, value: step, to: anchor) ?? anchor
            monthDragX = 0
        }
    }

    private var monthWeeks: [[Date]] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: anchor),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start)
        else { return [] }
        var weeks: [[Date]] = []
        var weekStart = firstWeek.start
        while weekStart < monthInterval.end {
            let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
            weeks.append(showWeekends ? days : days.filter { !calendar.isDateInWeekend($0) })
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { break }
            weekStart = next
        }
        return weeks
    }

    // MARK: - Day cell (shared by strip + month grid)

    private func dayCell(_ day: Date, dimmed: Bool, compact: Bool = false) -> some View {
        let selected = isSelected(day)
        let inRange = isInRange(day)
        let today = calendar.isDateInToday(day)
        return Button {
            select(day)
        } label: {
            VStack(spacing: compact ? 2 : 4) {
                if !compact {
                    Text(weekdayLabel(day))
                        .font(typographyFont("dayLabelTypography", base: 12, weight: .medium))
                        .kerning(0.5)
                        .foregroundColor(typographyColor("dayLabelTypography") ?? .secondary)
                }
                Text("\(calendar.component(.day, from: day))")
                    .font(dateFont(today: today))
                    .foregroundColor(
                        selected ? selectionContrast
                            : dimmed ? (typographyColor("dateTypography") ?? .secondary).opacity(0.5)
                            : (typographyColor("dateTypography") ?? .primary)
                    )
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(
                            selected ? selectionColor
                                : inRange ? selectionColor.opacity(0.25)
                                : Color.clear
                        )
                    )
                    .overlay(
                        Circle().strokeBorder(
                            today && !selected ? selectionColor : Color.clear,
                            lineWidth: 1.5
                        )
                    )
                Circle()
                    .fill(hasMarker(day) ? selectionColor : Color.clear)
                    .frame(width: dotSize, height: dotSize)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .cmsInspectorID("Cms.simpleCalendar.day")
    }

    /// Single-letter day label ("M T W…"), the web's `EEEEE` format.
    private func weekdayLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: day)
    }

    // MARK: - Slim predicate row (native Menu + DatePicker, not a web mimic)

    private var slimRow: some View {
        HStack(spacing: 10) {
            Menu {
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
            } label: {
                HStack(spacing: 4) {
                    Text(operatorValue.label)
                        .font(typographyFont("predicateTypography", base: 14, weight: .regular))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11))
                }
                .foregroundColor(typographyColor("predicateTypography") ?? .primary)
            }

            Spacer(minLength: 0)

            if operatorValue.needsDate {
                dateChip(.start, value: selStart)
                if operatorValue == .between {
                    Text("–").foregroundColor(typographyColor("predicateTypography") ?? .secondary)
                    dateChip(.end, value: selEnd ?? selStart)
                }
            }

            if allowModeToggle { modeToggle }
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

    private func dateChip(_ target: DateChipTarget, value: Date?) -> some View {
        let typo = block.props.object("dateDropdownTypography")
        let authored = runtime.color(typo?.string("color"))
        let textColor = authored ?? (value != nil ? runtime.theme.textPrimary : runtime.theme.textSecondary)
        let font = Font.system(size: CmsTypography.size(typo) ?? 14,
                               weight: CmsTypography.weight(typo) ?? .regular)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return Button {
            dateChipTarget = target
        } label: {
            HStack(spacing: 4) {
                Text(value.map { formatter.string(from: $0) } ?? "Pick a date")
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
                    .fill(runtime.theme.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(runtime.theme.divider)
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

    private var markedDays: Set<Date> {
        guard !dateColumn.isEmpty, case .ok(let result) = runtime.state(for: querySlug) else { return [] }
        var days: Set<Date> = []
        for row in result.rows {
            if let value = row[dateColumn], let date = CmsDatePredicate.date(fromIso: value.displayString) {
                days.insert(calendar.startOfDay(for: date))
            }
        }
        return days
    }

    private func hasMarker(_ day: Date) -> Bool {
        markedDays.contains(calendar.startOfDay(for: day))
    }

    // MARK: - Selection

    private func isSelected(_ day: Date) -> Bool {
        if let s = selStart, calendar.isDate(day, inSameDayAs: s) { return true }
        if let e = selEnd, calendar.isDate(day, inSameDayAs: e) { return true }
        return false
    }

    private func isInRange(_ day: Date) -> Bool {
        guard let s = selStart, let e = selEnd else { return false }
        let d = calendar.startOfDay(for: day)
        return d > calendar.startOfDay(for: s) && d < calendar.startOfDay(for: e)
    }

    /// Grid tap. Range mode implies `between` (start pick then end pick);
    /// single mode implies the current single-date operator (default `eq`).
    private func select(_ day: Date) {
        let d = calendar.startOfDay(for: day)
        if isRangeMode {
            operatorValue = .between
            if let s = selStart, selEnd == nil, d != s {
                if d < s { selEnd = s; selStart = d } else { selEnd = d }
            } else {
                selStart = d
                selEnd = nil
            }
        } else {
            if operatorValue == .between || !operatorValue.needsDate { operatorValue = .eq }
            selStart = d
            selEnd = nil
        }
        publishSelection()
    }

    private func applyDefaultSelection() {
        guard selStart == nil else { return }
        let now = Date()
        switch block.props.string("defaultSelection") ?? "none" {
        case "today":
            selStart = calendar.startOfDay(for: now)
        case "firstOfMonth":
            selStart = calendar.dateInterval(of: .month, for: now)?.start
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
            content.sheet(item: $target) { t in
                picker(t)
            }
        }
    }
}
