import SwiftUI
import UIKit

/// Month grid backed by `UICalendarView`: the same layout, chevron header, and
/// swipe paging as the system Calendar app, with a dot on every recorded day.
struct MonthCalendarView: UIViewRepresentable {
    struct DayKey: Hashable {
        let year: Int
        let month: Int
        let day: Int

        init(date: Date, calendar: Calendar = .current) {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            year = components.year ?? 0
            month = components.month ?? 0
            day = components.day ?? 0
        }

        init?(components: DateComponents) {
            guard let year = components.year,
                let month = components.month,
                let day = components.day
            else { return nil }
            self.year = year
            self.month = month
            self.day = day
        }

        var components: DateComponents {
            DateComponents(year: year, month: month, day: day)
        }
    }

    var recordedDays: Set<DayKey>
    @Binding var selectedDate: Date
    var onVisibleMonthChange: (DateComponents) -> Void = { _ in }
    var onSelectDate: (Date) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedDate: $selectedDate, onSelectDate: onSelectDate)
    }

    func makeUIView(context: Context) -> UICalendarView {
        let calendarView = UICalendarView()
        calendarView.calendar = .current
        calendarView.locale = .current
        calendarView.wantsDateDecorations = true
        calendarView.delegate = context.coordinator

        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        let components = Self.components(for: selectedDate)
        selection.selectedDate = components
        calendarView.selectionBehavior = selection

        context.coordinator.attach(recordedDays: recordedDays, selectedComponents: components)
        return calendarView
    }

    func updateUIView(_ calendarView: UICalendarView, context: Context) {
        context.coordinator.onVisibleMonthChange = onVisibleMonthChange
        context.coordinator.onSelectDate = onSelectDate
        context.coordinator.update(
            calendarView,
            selection: calendarView.selectionBehavior as? UICalendarSelectionSingleDate,
            recordedDays: recordedDays,
            selectedDate: selectedDate)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitting = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: max(fitting.height, 300))
    }

    private static func components(for date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    @MainActor
    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        private let selectedDate: Binding<Date>
        private var recordedDays: Set<DayKey> = []
        private var lastSelectedComponents: DateComponents?
        var onVisibleMonthChange: (DateComponents) -> Void = { _ in }
        var onSelectDate: (Date) -> Void = { _ in }

        init(selectedDate: Binding<Date>, onSelectDate: @escaping (Date) -> Void) {
            self.selectedDate = selectedDate
            self.onSelectDate = onSelectDate
        }

        func attach(recordedDays: Set<DayKey>, selectedComponents: DateComponents) {
            self.recordedDays = recordedDays
            lastSelectedComponents = selectedComponents
        }

        func update(
            _ calendarView: UICalendarView, selection: UICalendarSelectionSingleDate?,
            recordedDays: Set<DayKey>, selectedDate: Date
        ) {
            if self.recordedDays != recordedDays {
                let changed = self.recordedDays.symmetricDifference(recordedDays)
                self.recordedDays = recordedDays
                calendarView.reloadDecorations(forDateComponents: changed.map(\.components), animated: false)
            }

            let components = Self.components(for: selectedDate)
            guard components != lastSelectedComponents else { return }
            lastSelectedComponents = components
            calendarView.setVisibleDateComponents(components, animated: false)
            selection?.setSelected(components, animated: false)
        }

        func calendarView(
            _ calendarView: UICalendarView,
            decorationFor dateComponents: DateComponents
        ) -> UICalendarView.Decoration? {
            guard let key = DayKey(components: dateComponents), recordedDays.contains(key) else { return nil }
            return .default(color: .secondaryLabel, size: .small)
        }

        func calendarView(
            _ calendarView: UICalendarView,
            didChangeVisibleDateComponentsFrom previousDateComponents: DateComponents
        ) {
            let components = calendarView.visibleDateComponents
            let notify = onVisibleMonthChange
            // Hop out of the current update pass before touching SwiftUI state.
            Task { @MainActor in
                notify(components)
            }
        }

        func dateSelection(
            _ selection: UICalendarSelectionSingleDate,
            didSelectDate dateComponents: DateComponents?
        ) {
            guard let dateComponents,
                let date = Calendar.current.date(from: dateComponents)
            else { return }
            lastSelectedComponents = Self.components(for: date)
            selectedDate.wrappedValue = date
            onSelectDate(date)
        }

        private static func components(for date: Date) -> DateComponents {
            Calendar.current.dateComponents([.year, .month, .day], from: date)
        }
    }
}
