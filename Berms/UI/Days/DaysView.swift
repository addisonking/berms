import MapKit
import SwiftData
import SwiftUI
import UIKit

struct DaysView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
    @Query(sort: \RideDay.startedAt, order: .reverse) private var days: [RideDay]
    @Query(sort: \Trail.updatedAt, order: .reverse) private var trails: [Trail]
    @Binding private var pendingDayID: UUID?
    let onStartTracking: () -> Void
    @State private var deleteError: String?
    @State private var dayToDelete: RideDay?
    @State private var navigationPath = NavigationPath()
    @State private var selectedDate = Date()
    @State private var didApplyDefaultSelection = false

    init(pendingDayID: Binding<UUID?> = .constant(nil),
         onStartTracking: @escaping () -> Void = {}) {
        self._pendingDayID = pendingDayID
        self.onStartTracking = onStartTracking
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                BermsBackground()
                if finishedDays.isEmpty {
                    emptyDaysView
                } else {
                    calendarContent
                }
            }
            .navigationTitle("Days")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if showsTodayButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Today") { selectedDate = .now }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { dayID in
                if let day = days.first(where: { $0.id == dayID }) {
                    DayDetailView(day: day) { destination in
                        navigationPath.append(destination)
                    }
                }
            }
            .navigationDestination(for: RunMapDestination.self) { destination in
                if let day = days.first(where: { $0.id == destination.dayID }),
                   let run = day.segments.first(where: {
                       $0.id == destination.runID && $0.kind == .run
                   }) {
                    let preheatedRunKey = SessionDetailPresentationPreheater.runCacheKey(
                        dayID: day.id,
                        segmentID: run.id,
                        selectionID: trailCatalogSelection.selectionID,
                        trails: trails
                    )
                    let preheatedRun = SessionDetailPresentationCache.shared.runEntry(for: preheatedRunKey)
                    RunMapView(number: destination.number,
                               segment: run,
                               preparedBase: preheatedRun?.base,
                               preparedDetail: preheatedRun?.detail,
                               preparedTrailDetails: preheatedRun?.trailDetails)
                }
            }
            .onAppear {
                applyDefaultSelectionIfNeeded()
                openPendingDayIfNeeded()
            }
            .onChange(of: pendingDayID) { _, _ in openPendingDayIfNeeded() }
            .onChange(of: finishedDays.map(\.id)) { _, _ in
                applyDefaultSelectionIfNeeded()
                openPendingDayIfNeeded()
            }
        }
        .task(id: latestRunPreheatKey) {
            await preheatLatestRun()
        }
        .alert("Delete day?", isPresented: Binding(
            get: { dayToDelete != nil },
            set: { if !$0 { dayToDelete = nil } }
        ), presenting: dayToDelete) { day in
            Button("Delete day", role: .destructive) { deleteDay(day) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the day and all of its runs, lifts, and map data.")
        }
        .alert("Couldn't delete day", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func deleteDay(_ day: RideDay) {
        let logURLs = RideRecorder.diagnosticLogURLs(for: day.id,
                                                     startedAt: day.startedAt,
                                                     endedAt: day.endedAt)
        modelContext.delete(day)
        do {
            try modelContext.save()
            logURLs.forEach { try? FileManager.default.removeItem(at: $0) }
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
            + "\(trailCatalogSelection.selectionID)|\(SessionDetailPresentationPreheater.trailRevision(for: trails))"
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
            selectionID: trailCatalogSelection.selectionID,
            trails: trails
        )
        if SessionDetailPresentationCache.shared.runEntry(for: cacheKey) != nil {
            return
        }

        do {
            guard let entry = try await SessionDetailPresentationPreheater.prepareRun(
                segmentID: latestRun.id,
                manualCatalogID: trailCatalogSelection.manualCatalogID,
                container: modelContext.container
            ) else { return }
            guard !Task.isCancelled else { return }
            SessionDetailPresentationCache.shared.storeRun(entry, for: cacheKey)
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private var calendarContent: some View {
        List {
            Section {
                MonthCalendarView(recordedDays: recordedDayKeys,
                                  selectedDate: $selectedDate,
                                  onVisibleMonthChange: handleVisibleMonthChange)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                if selectedDaySessions.isEmpty {
                    Text("No sessions on this day.")
                        .font(.subheadline)
                        .foregroundStyle(Color.bermsMuted)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(selectedDaySessions) { day in
                        NavigationLink(value: day.id) {
                            DayRow(day: day)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            dayDeleteAction(for: day)
                        }
                    }
                }
            } header: {
                Text(selectedDate.formatted(date: .complete, time: .omitted))
                    .textCase(nil)
            }
        }
        .listSectionSpacing(.compact)
    }

    private var showsTodayButton: Bool {
        !Calendar.current.isDate(selectedDate, equalTo: .now, toGranularity: .month)
    }

    /// Keep the agenda in step with the month on screen: paging away from the
    /// selected day moves the selection into the month being viewed.
    private func handleVisibleMonthChange(_ components: DateComponents) {
        let calendar = Calendar.current
        guard let month = calendar.date(from: components),
              !calendar.isDate(selectedDate, equalTo: month, toGranularity: .month) else { return }
        if let latestInMonth = finishedDays.first(where: {
            calendar.isDate($0.startedAt, equalTo: month, toGranularity: .month)
        }) {
            selectedDate = latestInMonth.startedAt
        } else if let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month],
                                                                                 from: month)) {
            selectedDate = firstOfMonth
        }
    }

    private var recordedDayKeys: Set<MonthCalendarView.DayKey> {
        Set(finishedDays.map { MonthCalendarView.DayKey(date: $0.startedAt) })
    }

    private var selectedDaySessions: [RideDay] {
        finishedDays
            .filter { Calendar.current.isDate($0.startedAt, inSameDayAs: selectedDate) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Sessions are sparse, so open the month and day of the most recent ride
    /// instead of landing on an empty today.
    private func applyDefaultSelectionIfNeeded() {
        guard !didApplyDefaultSelection, !finishedDays.isEmpty else { return }
        didApplyDefaultSelection = true
        guard !finishedDays.contains(where: { Calendar.current.isDateInToday($0.startedAt) }),
              let mostRecent = finishedDays.first else { return }
        selectedDate = mostRecent.startedAt
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
              let day = finishedDays.first(where: { $0.id == pendingDayID }) else { return }
        selectedDate = day.startedAt
        navigationPath = NavigationPath([pendingDayID])
        self.pendingDayID = nil
    }
}
