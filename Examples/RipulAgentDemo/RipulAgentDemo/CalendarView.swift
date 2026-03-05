import SwiftUI
import EventKit

// MARK: - Shared

enum CalendarViewMode: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case agenda = "Agenda"
}

private let calendarConstants = (
    hourHeight: CGFloat(60),
    startHour: 7,
    endHour: 22,
    gutterWidth: CGFloat(48)
)

private func hourLabel(_ hour: Int) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "h a"
    var comps = DateComponents()
    comps.hour = hour
    let date = Calendar.current.date(from: comps) ?? Date()
    return fmt.string(from: date)
}

private func yOffset(for date: Date) -> CGFloat {
    let cal = Calendar.current
    let hour = cal.component(.hour, from: date)
    let minute = cal.component(.minute, from: date)
    let hoursFromStart = CGFloat(hour - calendarConstants.startHour) + CGFloat(minute) / 60.0
    return max(0, hoursFromStart * calendarConstants.hourHeight)
}

private func timeLabelsView() -> some View {
    VStack(spacing: 0) {
        ForEach(calendarConstants.startHour..<calendarConstants.endHour, id: \.self) { hour in
            HStack {
                Spacer()
                Text(hourLabel(hour))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
            .frame(width: calendarConstants.gutterWidth, height: calendarConstants.hourHeight, alignment: .topTrailing)
            .offset(y: -6)
        }
    }
}

private func gridLinesView() -> some View {
    VStack(spacing: 0) {
        ForEach(calendarConstants.startHour..<calendarConstants.endHour, id: \.self) { _ in
            VStack(spacing: 0) {
                Divider().foregroundStyle(Color(.systemGray5))
                Spacer()
            }
            .frame(height: calendarConstants.hourHeight)
        }
    }
}

private func eventBlockView(_ event: EKEvent, showTime: Bool = false) -> some View {
    let color = Color(cgColor: event.calendar.cgColor)
    return VStack(alignment: .leading, spacing: 1) {
        Text(event.title ?? "")
            .font(.caption2.weight(.semibold))
            .lineLimit(2)
        if showTime {
            let fmt = DateFormatter()
            let _ = fmt.dateFormat = "h:mm a"
            Text("\(fmt.string(from: event.startDate)) – \(fmt.string(from: event.endDate))")
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        if let location = event.location, !location.isEmpty {
            Text(location)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 2)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(color.opacity(0.2))
    .overlay(
        Rectangle().fill(color).frame(width: 3),
        alignment: .leading
    )
    .clipShape(RoundedRectangle(cornerRadius: 4))
}

private func navigationHeader<Content: View>(
    title: String,
    showToday: Bool,
    onPrev: @escaping () -> Void,
    onNext: @escaping () -> Void,
    onToday: @escaping () -> Void,
    @ViewBuilder extra: () -> Content = { EmptyView() }
) -> some View {
    HStack {
        Button(action: onPrev) {
            Image(systemName: "chevron.left")
                .font(.title3.weight(.semibold))
        }

        Spacer()

        VStack(spacing: 2) {
            Text(title)
                .font(.headline)
            if showToday {
                Button("Today", action: onToday)
                    .font(.caption)
            }
            extra()
        }

        Spacer()

        Button(action: onNext) {
            Image(systemName: "chevron.right")
                .font(.title3.weight(.semibold))
        }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
}

// MARK: - Calendar Container

struct CalendarContainerView: View {
    @ObservedObject var calendarService: CalendarService
    @State private var mode: CalendarViewMode = .week
    @State private var selectedDate: Date?

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(CalendarViewMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

            switch mode {
            case .day:
                DayCalendarView(calendarService: calendarService, initialDate: selectedDate)
            case .week:
                WeekCalendarView(calendarService: calendarService)
            case .month:
                MonthCalendarView(calendarService: calendarService, onSelectDay: { date in
                    selectedDate = date
                    withAnimation { mode = .day }
                })
            case .agenda:
                AgendaCalendarView(calendarService: calendarService)
            }
        }
    }
}

// MARK: - Day Calendar View

struct DayCalendarView: View {
    @ObservedObject var calendarService: CalendarService
    var initialDate: Date?
    @State private var dayOffset = 0
    @State private var events: [EKEvent] = []
    @State private var didApplyInitial = false

    private let cal = Calendar.current

    private var currentDay: Date {
        let base = didApplyInitial && initialDate != nil ? cal.startOfDay(for: initialDate!) : cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: dayOffset, to: base)!
    }

    private var isToday: Bool {
        cal.isDateInToday(currentDay)
    }

    private var dayTitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d"
        return fmt.string(from: currentDay)
    }

    private var allDayEvents: [EKEvent] {
        events.filter { $0.isAllDay }
    }

    private var timedEvents: [EKEvent] {
        events.filter { !$0.isAllDay }
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationHeader(
                title: dayTitle,
                showToday: !isToday,
                onPrev: { dayOffset -= 1 },
                onNext: { dayOffset += 1 },
                onToday: { withAnimation { dayOffset = didApplyInitial && initialDate != nil ? offsetToToday() : 0 } }
            )

            if !allDayEvents.isEmpty {
                allDaySection
            }

            Divider()
            timeGrid
        }
        .onAppear {
            if initialDate != nil, !didApplyInitial {
                didApplyInitial = true
                dayOffset = 0
            }
            loadEvents()
        }
        .onChange(of: dayOffset) { _, _ in loadEvents() }
        .onReceive(NotificationCenter.default.publisher(for: .calendarDidChange)) { _ in
            loadEvents()
        }
    }

    // MARK: - All Day

    private var allDaySection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("All Day")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: calendarConstants.gutterWidth - 8, alignment: .trailing)

                ForEach(allDayEvents, id: \.eventIdentifier) { event in
                    let color = Color(cgColor: event.calendar.cgColor)
                    Text(event.title ?? "")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(color.opacity(0.2))
                        .overlay(
                            Rectangle().fill(color).frame(width: 3),
                            alignment: .leading
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Time Grid

    private var timeGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    timeLabelsView()
                    gridLinesView()
                }
                dayEventBlocks
                if isToday {
                    nowLine
                }
            }
            .frame(height: CGFloat(calendarConstants.endHour - calendarConstants.startHour) * calendarConstants.hourHeight)
        }
    }

    private var dayEventBlocks: some View {
        GeometryReader { geo in
            let contentWidth = geo.size.width - calendarConstants.gutterWidth

            ForEach(timedEvents, id: \.eventIdentifier) { event in
                let top = yOffset(for: event.startDate)
                let height = max(yOffset(for: event.endDate) - top, 24)

                eventBlockView(event, showTime: true)
                    .frame(width: contentWidth - 4, height: height)
                    .offset(x: calendarConstants.gutterWidth + 2, y: top)
            }
        }
    }

    private var nowLine: some View {
        GeometryReader { geo in
            let y = yOffset(for: Date())

            Path { path in
                path.move(to: CGPoint(x: calendarConstants.gutterWidth, y: y))
                path.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
            .stroke(Color.red, lineWidth: 1.5)

            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .offset(x: calendarConstants.gutterWidth - 4, y: y - 4)
        }
    }

    // MARK: - Helpers

    private func loadEvents() {
        guard calendarService.hasAccess else { return }
        let start = currentDay
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        events = calendarService.fetchEvents(from: start, to: end)
    }

    private func offsetToToday() -> Int {
        let base = cal.startOfDay(for: initialDate ?? Date())
        let today = cal.startOfDay(for: Date())
        return cal.dateComponents([.day], from: base, to: today).day ?? 0
    }
}

// MARK: - Week Calendar View

struct WeekCalendarView: View {
    @ObservedObject var calendarService: CalendarService
    @State private var weekOffset = 0
    @State private var events: [EKEvent] = []

    private let calendar = Calendar.current

    private var weekStart: Date {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let daysToMonday = (weekday == 1) ? -6 : (2 - weekday)
        let monday = calendar.date(byAdding: .day, value: daysToMonday + (weekOffset * 7), to: today)!
        return monday
    }

    private var weekDays: [Date] {
        (0..<7).map { calendar.date(byAdding: .day, value: $0, to: weekStart)! }
    }

    private var weekTitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        let start = fmt.string(from: weekDays.first!)
        let end = fmt.string(from: weekDays.last!)
        return "\(start) – \(end)"
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationHeader(
                title: weekTitle,
                showToday: weekOffset != 0,
                onPrev: { weekOffset -= 1 },
                onNext: { weekOffset += 1 },
                onToday: { withAnimation { weekOffset = 0 } }
            )
            dayHeaders
            Divider()
            timeGrid
        }
        .onAppear { loadEvents() }
        .onChange(of: weekOffset) { _, _ in loadEvents() }
        .onReceive(NotificationCenter.default.publisher(for: .calendarDidChange)) { _ in
            loadEvents()
        }
    }

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: calendarConstants.gutterWidth)

            ForEach(weekDays, id: \.timeIntervalSinceReferenceDate) { day in
                let isToday = calendar.isDateInToday(day)
                VStack(spacing: 2) {
                    Text(dayOfWeekShort(day))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(calendar.component(.day, from: day))")
                        .font(.subheadline.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? .white : .primary)
                        .frame(width: 28, height: 28)
                        .background(isToday ? Color.accentColor : Color.clear)
                        .clipShape(Circle())
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Time Grid

    private var timeGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    timeLabelsView()
                    gridLinesView()
                }
                eventBlocks
                nowIndicator
            }
            .frame(height: CGFloat(calendarConstants.endHour - calendarConstants.startHour) * calendarConstants.hourHeight)
        }
    }

    private var eventBlocks: some View {
        GeometryReader { geo in
            let dayWidth = (geo.size.width - calendarConstants.gutterWidth) / 7

            ForEach(events, id: \.eventIdentifier) { event in
                let dayIndex = dayIndexFor(event)
                if let dayIndex, !event.isAllDay {
                    let topOffset = yOffset(for: event.startDate)
                    let height = max(yOffset(for: event.endDate) - topOffset, 22)
                    let xOffset = calendarConstants.gutterWidth + dayWidth * CGFloat(dayIndex) + 1

                    eventBlockView(event)
                        .frame(width: dayWidth - 2, height: height)
                        .offset(x: xOffset, y: topOffset)
                }
            }
        }
    }

    private var nowIndicator: some View {
        GeometryReader { geo in
            if weekOffset == 0 {
                let now = Date()
                let y = yOffset(for: now)
                let todayIndex = weekDays.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) })

                if let todayIndex {
                    let dayWidth = (geo.size.width - calendarConstants.gutterWidth) / 7
                    let x = calendarConstants.gutterWidth + dayWidth * CGFloat(todayIndex)

                    Path { path in
                        path.move(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: x + dayWidth, y: y))
                    }
                    .stroke(Color.red, lineWidth: 1.5)

                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: x - 4, y: y - 4)
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadEvents() {
        guard calendarService.hasAccess else { return }
        let start = weekStart
        let end = calendar.date(byAdding: .day, value: 7, to: start)!
        events = calendarService.fetchEvents(from: start, to: end)
    }

    private func dayIndexFor(_ event: EKEvent) -> Int? {
        weekDays.firstIndex(where: { calendar.isDate($0, inSameDayAs: event.startDate) })
    }

    private func dayOfWeekShort(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return fmt.string(from: date).uppercased()
    }
}

// MARK: - Month Calendar View

struct MonthCalendarView: View {
    @ObservedObject var calendarService: CalendarService
    var onSelectDay: (Date) -> Void
    @State private var monthOffset = 0
    @State private var events: [EKEvent] = []

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    private var monthStart: Date {
        let today = cal.startOfDay(for: Date())
        let comps = cal.dateComponents([.year, .month], from: today)
        let thisMonthStart = cal.date(from: comps)!
        return cal.date(byAdding: .month, value: monthOffset, to: thisMonthStart)!
    }

    private var monthTitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: monthStart)
    }

    /// All dates to display in the grid (includes trailing/leading days from adjacent months).
    private var gridDates: [Date] {
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let firstDay = monthStart
        let weekday = cal.component(.weekday, from: firstDay)
        // Days to show before the 1st (to fill the week row starting Monday)
        let leadingDays = (weekday == 1) ? 6 : (weekday - 2)

        let totalDays = leadingDays + range.count
        let rows = (totalDays + 6) / 7
        let totalCells = rows * 7

        return (-leadingDays..<(totalCells - leadingDays)).map { offset in
            cal.date(byAdding: .day, value: offset, to: firstDay)!
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationHeader(
                title: monthTitle,
                showToday: monthOffset != 0,
                onPrev: { monthOffset -= 1 },
                onNext: { monthOffset += 1 },
                onToday: { withAnimation { monthOffset = 0 } }
            )

            weekdayHeaders
            Divider()

            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(gridDates, id: \.timeIntervalSinceReferenceDate) { date in
                    dayCell(date)
                }
            }
            .padding(.horizontal, 4)

            Spacer()
        }
        .onAppear { loadEvents() }
        .onChange(of: monthOffset) { _, _ in loadEvents() }
        .onReceive(NotificationCenter.default.publisher(for: .calendarDidChange)) { _ in
            loadEvents()
        }
    }

    // MARK: - Headers

    private var weekdayHeaders: some View {
        HStack(spacing: 0) {
            ForEach(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"], id: \.self) { day in
                Text(day)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - Day Cell

    private func dayCell(_ date: Date) -> some View {
        let isCurrentMonth = cal.isDate(date, equalTo: monthStart, toGranularity: .month)
        let isToday = cal.isDateInToday(date)
        let dayEvents = eventsFor(date)
        let maxDots = 3

        return Button {
            onSelectDay(date)
        } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: date))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? .white : isCurrentMonth ? .primary : Color(.tertiaryLabel))
                    .frame(width: 30, height: 30)
                    .background(isToday ? Color.accentColor : Color.clear)
                    .clipShape(Circle())

                if dayEvents.isEmpty {
                    Color.clear.frame(height: 6)
                } else {
                    HStack(spacing: 3) {
                        ForEach(0..<min(dayEvents.count, maxDots), id: \.self) { i in
                            Circle()
                                .fill(Color(cgColor: dayEvents[i].calendar.cgColor))
                                .frame(width: 5, height: 5)
                        }
                        if dayEvents.count > maxDots {
                            Text("+\(dayEvents.count - maxDots)")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func loadEvents() {
        guard calendarService.hasAccess else { return }
        let dates = gridDates
        guard let first = dates.first, let last = dates.last else { return }
        let end = cal.date(byAdding: .day, value: 1, to: last)!
        events = calendarService.fetchEvents(from: first, to: end)
    }

    private func eventsFor(_ date: Date) -> [EKEvent] {
        events.filter { cal.isDate($0.startDate, inSameDayAs: date) }
    }
}

// MARK: - Agenda Calendar View

struct AgendaCalendarView: View {
    @ObservedObject var calendarService: CalendarService
    @State private var events: [EKEvent] = []
    @State private var daysToShow = 30

    private let cal = Calendar.current

    private var groupedEvents: [(date: Date, events: [EKEvent])] {
        let start = cal.startOfDay(for: Date())
        let days = (0..<daysToShow).map { cal.date(byAdding: .day, value: $0, to: start)! }

        return days.compactMap { day in
            let dayEvents = events.filter { cal.isDate($0.startDate, inSameDayAs: day) }
            return dayEvents.isEmpty ? nil : (date: day, events: dayEvents)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if groupedEvents.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No upcoming events")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Next \(daysToShow) days are clear.")
                        .font(.caption)
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(groupedEvents, id: \.date.timeIntervalSinceReferenceDate) { group in
                            Section(header: daySectionHeader(group.date)) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(group.events.enumerated()), id: \.element.eventIdentifier) { idx, event in
                                        agendaRow(event)
                                        if idx < group.events.count - 1 {
                                            Divider().padding(.leading, 68)
                                        }
                                    }
                                }
                            }
                        }

                        Button {
                            daysToShow += 30
                            loadEvents()
                        } label: {
                            Text("Show more")
                                .font(.subheadline)
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }
                }
            }
        }
        .onAppear { loadEvents() }
        .onReceive(NotificationCenter.default.publisher(for: .calendarDidChange)) { _ in
            loadEvents()
        }
    }

    // MARK: - Section Header

    private func daySectionHeader(_ date: Date) -> some View {
        let isToday = cal.isDateInToday(date)
        let isTomorrow = cal.isDateInTomorrow(date)

        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d"
        let dateStr = fmt.string(from: date)

        let label = isToday ? "Today" : isTomorrow ? "Tomorrow" : nil

        return HStack(spacing: 6) {
            if let label {
                Text(label)
                    .font(.subheadline.weight(.bold))
                Text(dateStr)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(dateStr)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Event Row

    private func agendaRow(_ event: EKEvent) -> some View {
        let color = Color(cgColor: event.calendar.cgColor)

        return HStack(alignment: .top, spacing: 12) {
            // Time column
            VStack(alignment: .trailing, spacing: 2) {
                if event.isAllDay {
                    Text("All Day")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(timeString(event.startDate))
                        .font(.caption.weight(.medium))
                    Text(timeString(event.endDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, alignment: .trailing)

            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4)

            // Details
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "")
                    .font(.subheadline.weight(.medium))
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func loadEvents() {
        guard calendarService.hasAccess else { return }
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: daysToShow, to: start)!
        events = calendarService.fetchEvents(from: start, to: end)
    }

    private func timeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }
}
