#if os(iOS)
import SwiftUI
import UIKit

/// Native month calendar for the simpleCalendar block — a UICalendarView
/// wrapper. Degrades the block contract to what the native control supports,
/// without fighting it:
///  - per-day data dots → decorations (colour honoured; size stepped)
///  - range/"Between" → two single taps; the active predicate is articulated
///    by a caption OUTSIDE this view (no in-range tinting)
///  - showWeekends:false and per-cell typography are not expressible → the
///    exact authored date colour degrades to a light/dark rendering choice:
///    a LIGHT authored date colour flips the control to dark style (white
///    labels for a coloured backdrop), a dark one to light style.
/// Selection/date-fold semantics stay in the owning block; this view only
/// reports taps.
@available(iOS 16.0, *)
struct CmsNativeMonthCalendar: UIViewRepresentable {
    let markedDays: Set<Date>
    let selectedDate: Date?
    let tint: Color
    /// Authored dateTypography colour; nil follows the system appearance.
    let dateTextColor: Color?
    let firstWeekday: Int
    let dotSize: CGFloat
    let initialMonth: Date
    let onSelect: (Date) -> Void

    private var interfaceStyle: UIUserInterfaceStyle {
        guard let dateTextColor else { return .unspecified }
        return CmsCss.isLight(dateTextColor) ? .dark : .light
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = firstWeekday
        return cal
    }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = calendar
        view.tintColor = UIColor(tint)
        view.overrideUserInterfaceStyle = interfaceStyle
        view.delegate = context.coordinator
        view.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.visibleDateComponents = calendar.dateComponents([.year, .month], from: initialMonth)
        // Let the page column rule the width; the calendar adapts.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.tintColor = UIColor(tint)
        view.overrideUserInterfaceStyle = interfaceStyle

        // Sync the visible selection to the block's state (last tap).
        if let selection = view.selectionBehavior as? UICalendarSelectionSingleDate {
            let current = selection.selectedDate.flatMap { calendar.date(from: $0) }
            if current != selectedDate {
                let components = selectedDate.map { calendar.dateComponents([.year, .month, .day], from: $0) }
                selection.setSelected(components, animated: false)
            }
        }

        // Reload only the days whose marker changed.
        if coordinator.marked != markedDays {
            let changed = coordinator.marked.symmetricDifference(markedDays)
            coordinator.marked = markedDays
            let components = changed.map { calendar.dateComponents([.year, .month, .day], from: $0) }
            if !components.isEmpty {
                view.reloadDecorations(forDateComponents: components, animated: false)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: CmsNativeMonthCalendar
        var marked: Set<Date>

        init(_ parent: CmsNativeMonthCalendar) {
            self.parent = parent
            self.marked = parent.markedDays
        }

        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let date = calendarView.calendar.date(from: dateComponents) else { return nil }
            guard marked.contains(calendarView.calendar.startOfDay(for: date)) else { return nil }
            let size: UICalendarView.DecorationSize = parent.dotSize < 7 ? .small : parent.dotSize <= 10 ? .medium : .large
            return .default(color: UIColor(parent.tint), size: size)
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let components = dateComponents,
                  let date = Calendar(identifier: .gregorian).date(from: components) else { return }
            parent.onSelect(date)
        }
    }
}
#endif
