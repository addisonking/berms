import MapKit
import SwiftData
import SwiftUI
import UIKit

struct DaysView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RideDay.startedAt, order: .reverse) private var days: [RideDay]
    @Query(sort: \Trail.updatedAt, order: .reverse) private var trails: [Trail]
    @Binding private var pendingDayID: UUID?
    @Binding private var pendingRecapDayID: UUID?
    let onStartTracking: () -> Void
    @State private var deleteError: String?
    @State private var dayToDelete: RideDay?
    @State private var navigationPath = NavigationPath()
    @State private var showingCalendar = false
    @State private var calendarSelection = Date()
    @State private var pendingScrollID: UUID?
    @State private var recapDayID: UUID?

    init(
        pendingDayID: Binding<UUID?> = .constant(nil),
        pendingRecapDayID: Binding<UUID?> = .constant(nil),
        onStartTracking: @escaping () -> Void = {}
    ) {
        self._pendingDayID = pendingDayID
        self._pendingRecapDayID = pendingRecapDayID
        self.onStartTracking = onStartTracking
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                BermsBackground()
                if finishedDays.isEmpty {
                    emptyDaysView
                } else {
                    sessionsList
                }
            }
            .navigationTitle("Days")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !finishedDays.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            calendarSelection = finishedDays.first?.startedAt ?? .now
                            showingCalendar = true
                        } label: {
                            Image(systemName: "calendar")
                        }
                        .accessibilityLabel("Jump to date")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { dayID in
                if let day = days.first(where: { $0.id == dayID }) {
                    DayDetailView(day: day, initiallyShowsRecap: recapDayID == dayID) { destination in
                        navigationPath.append(destination)
                    }
                }
            }
            .navigationDestination(for: RunMapDestination.self) { destination in
                if let day = days.first(where: { $0.id == destination.dayID }),
                    let run = day.segments.first(where: {
                        $0.id == destination.runID && $0.kind == .run
                    })
                {
                    let preheatedRunKey = SessionDetailPresentationPreheater.runCacheKey(
                        dayID: day.id,
                        segmentID: run.id,
                        selectionID: catalogSelectionID(for: day),
                        trails: trails
                    )
                    let preheatedRun = SessionDetailPresentationCache.shared.runEntry(for: preheatedRunKey)
                    RunMapView(
                        number: destination.number,
                        segment: run,
                        preparedBase: preheatedRun?.base,
                        preparedDetail: preheatedRun?.detail,
                        preparedTrailDetails: preheatedRun?.trailDetails)
                }
            }
            .onAppear { openPendingDayIfNeeded() }
            .onChange(of: pendingDayID) { _, _ in openPendingDayIfNeeded() }
            .onChange(of: finishedDays.map(\.id)) { _, _ in openPendingDayIfNeeded() }
        }
        .task(id: latestRunPreheatKey) {
            await preheatLatestRun()
        }
        .sheet(isPresented: $showingCalendar) {
            calendarSheet
        }
        .alert(
            "Delete day?",
            isPresented: Binding(
                get: { dayToDelete != nil },
                set: { if !$0 { dayToDelete = nil } }
            ), presenting: dayToDelete
        ) { day in
            Button("Delete day", role: .destructive) { deleteDay(day) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the day and all of its runs, lifts, and map data.")
        }
        .alert(
            "Couldn't delete day",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func deleteDay(_ day: RideDay) {
        let logURLs = RideRecorder.diagnosticLogURLs(
            for: day.id,
            startedAt: day.startedAt,
            endedAt: day.endedAt)
        modelContext.delete(day)
        do {
            try modelContext.save()
            for url in logURLs {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            modelContext.rollback()
            deleteError = "The day could not be deleted. \(error.localizedDescription)"
        }
    }

    private var emptyDaysView: some View {
        ContentUnavailableView {
            Label("No days yet", systemImage: "mountain.2.fill")
        } description: {
            Text("Finish a ride and it will appear here.")
        } actions: {
            Button("Start tracking", action: onStartTracking)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var finishedDays: [RideDay] {
        days.filter { $0.isFinished }
    }

    private var latestRunPreheatTarget: (day: RideDay, run: RideSegment)? {
        SessionDetailPresentationPreheater.latestCompletedRun(in: days)
    }

    private var latestRunPreheatKey: String {
        guard let target = latestRunPreheatTarget else {
            return "none"
        }
        return "\(target.day.id.uuidString)|\(target.run.id.uuidString)|"
            + "\(catalogSelectionID(for: target.day))|"
            + "\(SessionDetailPresentationPreheater.trailRevision(for: trails))"
    }

    @MainActor
    private func preheatLatestRun() async {
        guard let target = latestRunPreheatTarget else { return }
        let day = target.day
        let latestRun = target.run
        await Task.yield()

        let cacheKey = SessionDetailPresentationPreheater.runCacheKey(
            dayID: day.id,
            segmentID: latestRun.id,
            selectionID: catalogSelectionID(for: day),
            trails: trails
        )
        if SessionDetailPresentationCache.shared.runEntry(for: cacheKey) != nil {
            return
        }

        do {
            guard
                let entry = try await SessionDetailPresentationPreheater.prepareRun(
                    segmentID: latestRun.id,
                    manualCatalogID: await SessionDetailPresentationPreheater.resolvedCatalog(
                        dayID: day.id, container: modelContext.container)?.id,
                    container: modelContext.container
                )
            else { return }
            guard !Task.isCancelled else { return }
            SessionDetailPresentationCache.shared.storeRun(entry, for: cacheKey)
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func catalogSelectionID(for day: RideDay) -> String {
        day.catalogID
            ?? TrailCatalogRegistry.automaticSelectionID
    }

    /// Sessions are sparse and rich, so the list stays primary: newest first,
    /// grouped under month headers that carry the month's totals.
    private var sessionsList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(monthGroups) { group in
                    Section {
                        ForEach(group.days) { day in
                            NavigationLink(value: day.id) {
                                DayRow(day: day)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                dayDeleteAction(for: day)
                            }
                            .id(day.id)
                        }
                    } header: {
                        monthHeader(for: group)
                    }
                }
            }
            .listSectionSpacing(.compact)
            .onChange(of: pendingScrollID) { _, target in
                guard let target else { return }
                withAnimation(reduceMotion ? nil : BermsMotion.recenter) { proxy.scrollTo(target, anchor: .top) }
                pendingScrollID = nil
            }
        }
    }

    private func monthHeader(for group: MonthGroup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.title)
            Spacer(minLength: BermsSpacing.compact)
            Text(group.summary)
                .foregroundStyle(Color.bermsMuted)
        }
        .textCase(nil)
    }

    private var calendarSheet: some View {
        NavigationStack {
            MonthCalendarView(
                recordedDays: recordedDayKeys,
                selectedDate: $calendarSelection,
                onSelectDate: { date in
                    calendarSelection = date
                    pendingScrollID = jumpTarget(for: date)
                    showingCalendar = false
                }
            )
            .navigationTitle("Jump to date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingCalendar = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private struct MonthGroup: Identifiable {
        let year: Int
        let month: Int
        var days: [RideDay]

        var id: String { "\(year)-\(month)" }

        private var startDate: Date? {
            Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))
        }

        var title: String {
            startDate?.formatted(.dateTime.month(.wide).year()) ?? ""
        }

        var summary: String {
            let dayCount = days.count == 1 ? "1 day" : "\(days.count) days"
            let runCount = days.reduce(0) { $0 + $1.segments.filter { $0.kind == .run }.count }
            guard runCount > 0 else { return dayCount }
            let runLabel = runCount == 1 ? "1 run" : "\(runCount) runs"
            return "\(dayCount)  ·  \(runLabel)"
        }
    }

    /// `finishedDays` is already newest-first, so walking it in order keeps the
    /// month sections newest-first too.
    private var monthGroups: [MonthGroup] {
        let calendar = Calendar.current
        var groups: [MonthGroup] = []
        for day in finishedDays {
            let components = calendar.dateComponents([.year, .month], from: day.startedAt)
            let year = components.year ?? 0
            let month = components.month ?? 0
            if var last = groups.last, last.year == year, last.month == month {
                last.days.append(day)
                groups[groups.count - 1] = last
            } else {
                groups.append(MonthGroup(year: year, month: month, days: [day]))
            }
        }
        return groups
    }

    private var recordedDayKeys: Set<MonthCalendarView.DayKey> {
        Set(finishedDays.map { MonthCalendarView.DayKey(date: $0.startedAt) })
    }

    /// The calendar is a jump-to-date affordance, so land on the exact day when
    /// it exists, otherwise the nearest session so the list still moves.
    private func jumpTarget(for date: Date) -> UUID? {
        let calendar = Calendar.current
        if let sameDay = finishedDays.first(where: {
            calendar.isDate($0.startedAt, inSameDayAs: date)
        }) {
            return sameDay.id
        }
        let components = calendar.dateComponents([.year, .month], from: date)
        if let inMonth = finishedDays.first(where: {
            let dayComponents = calendar.dateComponents([.year, .month], from: $0.startedAt)
            return dayComponents.year == components.year && dayComponents.month == components.month
        }) {
            return inMonth.id
        }
        return finishedDays.min {
            abs($0.startedAt.timeIntervalSince(date)) < abs($1.startedAt.timeIntervalSince(date))
        }?.id
    }

    @ViewBuilder
    private func dayDeleteAction(for day: RideDay) -> some View {
        if day.isFinished {
            Button(role: .destructive) {
                dayToDelete = day
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func openPendingDayIfNeeded() {
        guard let pendingDayID,
            finishedDays.contains(where: { $0.id == pendingDayID })
        else { return }
        recapDayID = pendingRecapDayID == pendingDayID ? pendingDayID : nil
        navigationPath = NavigationPath([pendingDayID])
        self.pendingDayID = nil
        pendingRecapDayID = nil
    }
}
