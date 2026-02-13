import SwiftUI
import EventKit

// MARK: - Week Calendar View

struct WeekCalendarView: View {
    @ObservedObject var calendarService: CalendarService
    @State private var weekOffset = 0
    @State private var events: [EKEvent] = []

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 60
    private let startHour = 7
    private let endHour = 22

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
            weekHeader
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

    // MARK: - Header

    private var weekHeader: some View {
        HStack {
            Button { weekOffset -= 1 } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
            }

            Spacer()

            VStack(spacing: 2) {
                Text(weekTitle)
                    .font(.headline)
                if weekOffset != 0 {
                    Button("Today") { withAnimation { weekOffset = 0 } }
                        .font(.caption)
                }
            }

            Spacer()

            Button { weekOffset += 1 } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            // Time gutter
            Color.clear.frame(width: 48)

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
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    timeLines
                    eventBlocks
                    nowIndicator
                }
                .frame(height: CGFloat(endHour - startHour) * hourHeight)
                .id("grid")
            }
            .onAppear {
                // Scroll to current hour
                // No-op — the ScrollViewReader is here for future use
            }
        }
    }

    private var timeLines: some View {
        HStack(spacing: 0) {
            // Time labels
            VStack(spacing: 0) {
                ForEach(startHour..<endHour, id: \.self) { hour in
                    HStack {
                        Spacer()
                        Text(hourLabel(hour))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                    .frame(width: 48, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -6) // Align label with line
                }
            }

            // Grid lines
            VStack(spacing: 0) {
                ForEach(startHour..<endHour, id: \.self) { _ in
                    VStack(spacing: 0) {
                        Divider().foregroundStyle(Color(.systemGray5))
                        Spacer()
                    }
                    .frame(height: hourHeight)
                }
            }
        }
    }

    // MARK: - Event Blocks

    private var eventBlocks: some View {
        GeometryReader { geo in
            let dayWidth = (geo.size.width - 48) / 7

            ForEach(events, id: \.eventIdentifier) { event in
                let dayIndex = dayIndexFor(event)
                if let dayIndex, !event.isAllDay {
                    let topOffset = yOffset(for: event.startDate)
                    let height = max(yOffset(for: event.endDate) - topOffset, 22)
                    let xOffset = 48 + dayWidth * CGFloat(dayIndex) + 1

                    eventBlock(event)
                        .frame(width: dayWidth - 2, height: height)
                        .offset(x: xOffset, y: topOffset)
                }
            }
        }
    }

    private func eventBlock(_ event: EKEvent) -> some View {
        let color = Color(cgColor: event.calendar.cgColor)
        return VStack(alignment: .leading, spacing: 1) {
            Text(event.title ?? "")
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
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

    // MARK: - Now Indicator

    private var nowIndicator: some View {
        GeometryReader { geo in
            if weekOffset == 0 {
                let now = Date()
                let y = yOffset(for: now)
                let todayIndex = weekDays.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) })

                if let todayIndex {
                    let dayWidth = (geo.size.width - 48) / 7
                    let x = 48 + dayWidth * CGFloat(todayIndex)

                    // Red line
                    Path { path in
                        path.move(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: x + dayWidth, y: y))
                    }
                    .stroke(Color.red, lineWidth: 1.5)

                    // Red dot
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

    private func yOffset(for date: Date) -> CGFloat {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let hoursFromStart = CGFloat(hour - startHour) + CGFloat(minute) / 60.0
        return max(0, hoursFromStart * hourHeight)
    }

    private func dayIndexFor(_ event: EKEvent) -> Int? {
        weekDays.firstIndex(where: { calendar.isDate($0, inSameDayAs: event.startDate) })
    }

    private func dayOfWeekShort(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return fmt.string(from: date).uppercased()
    }

    private func hourLabel(_ hour: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h a"
        var comps = DateComponents()
        comps.hour = hour
        let date = Calendar.current.date(from: comps) ?? Date()
        return fmt.string(from: date)
    }
}
