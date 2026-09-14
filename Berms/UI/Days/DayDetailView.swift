import MapKit
import SwiftData
import SwiftUI
import UIKit

struct DayDetailView: View {
    let day: RideDay
    let onRunSelected: (RunMapDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
    @ObservedObject private var presentationCache = SessionDetailPresentationCache.shared
    @Query(sort: \Trail.updatedAt, order: .reverse) private var trails: [Trail]
    @State private var showingFullScreenMap = false
    @State private var showingNameEditor = false
    @State private var nameDraft = ""
    @State private var notesDraft = ""
    @State private var showingDeleteConfirmation = false
    @State private var detailBase: SessionDetailBase?
    @State private var trailDetails: SessionDetailTrailDetails?
    @State private var notesSaveTask: Task<Void, Never>?
    @State private var saveErrorMessage: String?
    @State private var prepareFailed = false

    init(day: RideDay, onRunSelected: @escaping (RunMapDestination) -> Void = { _ in }) {
        self.day = day
        self.onRunSelected = onRunSelected
    }

    private var runs: [RideSegment] {
        day.segments.filter { $0.kind == .run }.sorted { $0.startedAt < $1.startedAt }
    }

    private var preparationTaskKey: String {
        "\(day.id.uuidString)|\(trailCatalogSelection.selectionID)|"
            + SessionDetailPresentationPreheater.trailRevision(for: trails)
    }

    private func preparationCacheKey(for trails: [Trail]) -> String {
        SessionDetailPresentationPreheater.cacheKey(
            dayID: day.id,
            selectionID: trailCatalogSelection.selectionID,
            trails: trails
        )
    }

    private func preheatedRun(for segment: RideSegment) -> SessionDetailPresentationCache.RunEntry? {
        let key = SessionDetailPresentationPreheater.runCacheKey(
            dayID: day.id,
            segmentID: segment.id,
            selectionID: trailCatalogSelection.selectionID,
            trails: trails
        )
        return presentationCache.runEntry(for: key)
    }

    var body: some View {
        List {
            Section("Day summary") {
                if day.segments.isEmpty {
                    LabeledContent("Started", value: day.startedAt.formatted(date: .omitted, time: .shortened))
                    LabeledContent("Duration", value: BermsFormat.duration(day.duration))
                } else {
                    summary
                }
            }
            if !runs.isEmpty {
                Section {
                    dayMap
                        .listRowInsets(EdgeInsets())
                }
            }
            Section("Runs") {
                if runs.isEmpty {
                    Text("No runs recorded during this session.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, segment in
                        let preheatedRun = preheatedRun(for: segment)
                        NavigationLink {
                            RunMapView(number: index + 1,
                                       segment: segment,
                                       preparedBase: detailBase ?? preheatedRun?.base,
                                       preparedDetail: detailBase?.segmentsByID[segment.id]
                                           ?? preheatedRun?.detail,
                                       preparedTrailDetails: trailDetails
                                           ?? preheatedRun?.trailDetails)
                        } label: {
                            SegmentRow(number: index + 1, segment: segment,
                                       detail: detailBase?.segmentsByID[segment.id]
                                           ?? preheatedRun?.detail,
                                       trailName: trailDetails?.sequenceBySegmentID[segment.id]
                                           ?? preheatedRun?.trailDetails.sequenceBySegmentID[segment.id],
                                       isPreparingDetails: trailDetails == nil && preheatedRun == nil)
                        }
                    }
                }
            }
            Section("Journal") {
                TextEditor(text: $notesDraft)
                    .frame(minHeight: 140)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityLabel("Session journal")
            }
        }
        .navigationTitle(day.hasCustomName ? day.displayName : day.startedAt.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let debugURL = RideRecorder.shared.debugLogURL(for: day) {
                        ShareLink(item: debugURL) {
                            Label("Export diagnostics", systemImage: "arrow.up.doc")
                        }
                    }
                    Button {
                        nameDraft = day.name ?? ""
                        showingNameEditor = true
                    } label: {
                        Label(day.hasCustomName ? "Edit name" : "Add name", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete day", systemImage: "trash")
                    }
                    .disabled(!day.isFinished)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
            }
        }
        .alert("Delete day?", isPresented: $showingDeleteConfirmation) {
            Button("Delete day", role: .destructive) {
                deleteDay()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the day and all of its runs, lifts, and map data.")
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
        .alert(day.hasCustomName ? "Edit name" : "Add name", isPresented: $showingNameEditor) {
            TextField("Session name", text: $nameDraft)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                saveName()
            }
        } message: {
            Text("Name this day so it is easy to find later.")
        }
        .onAppear {
            notesDraft = day.notes ?? ""
        }
        .task(id: preparationTaskKey) {
            await prepareDetails()
        }
        .onChange(of: notesDraft) { _, value in
            day.setNotes(value)
            scheduleNotesSave()
        }
        .onDisappear { commitNotesSave() }
    }

    private func scheduleNotesSave() {
        notesSaveTask?.cancel()
        notesSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            saveNotes()
        }
    }

    private func commitNotesSave() {
        notesSaveTask?.cancel()
        notesSaveTask = nil
        saveNotes()
    }

    private func saveNotes() {
        do {
            try modelContext.save()
        } catch {
            saveErrorMessage = "Your journal note could not be saved. \(error.localizedDescription)"
        }
    }

    private func saveName() {
        day.setName(nameDraft)
        do {
            try modelContext.save()
            showingNameEditor = false
        } catch {
            saveErrorMessage = "The name could not be saved. \(error.localizedDescription)"
        }
    }

    private func deleteDay() {
        let diagnosticURL = RideRecorder.debugLogURL(for: day.id)
        modelContext.delete(day)
        do {
            try modelContext.save()
            try? FileManager.default.removeItem(at: diagnosticURL)
            dismiss()
        } catch {
            modelContext.rollback()
            saveErrorMessage = "The day could not be deleted. \(error.localizedDescription)"
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.control) {
            VStack(spacing: BermsSpacing.content) {
                AdaptiveStatRow {
                    SummaryStat(label: "Time", value: BermsFormat.duration(day.duration), tint: .primary)
                    SummaryStat(label: "Runs", value: "\(runs.count)", tint: .primary)
                }
                AdaptiveStatRow {
                    SummaryStat(label: "Descent", value: BermsFormat.elevation(day.descentMeters), tint: .primary)
                    SummaryStat(label: "Distance", value: BermsFormat.distance(day.distanceMeters))
                }
                AdaptiveStatRow {
                    SummaryStat(label: "Riding time", value: BermsFormat.duration(day.activeSeconds))
                    SummaryStat(label: "Lift time", value: BermsFormat.duration(day.liftSeconds))
                }
                AdaptiveStatRow {
                    SummaryStat(label: "Top speed", value: BermsFormat.speed(day.maximumSpeedMetersPerSecond))
                    SummaryStat(label: "Jumps",
                                value: detailBase.map { "\($0.jumpCount)" } ?? "…",
                                tint: .primary)
                }
            }
        }
    }

    @ViewBuilder
    private var dayMap: some View {
        if runs.isEmpty {
            ContentUnavailableView("No route", systemImage: "map",
                                   description: Text("This day has no recorded runs."))
        } else if let detailBase {
            preparedDayMap(detailBase)
        } else if prepareFailed {
            ContentUnavailableView {
                Label("Map unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("This day's map could not be prepared.")
            } actions: {
                Button("Try Again") {
                    Task { await prepareDetails() }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        } else {
            VStack(spacing: BermsSpacing.compact) {
                ProgressView()
                Text("Loading map…")
                    .font(.subheadline)
                    .foregroundStyle(Color.bermsMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        }
    }

    @ViewBuilder
    private func preparedDayMap(_ detailBase: SessionDetailBase) -> some View {
        SessionRouteMap(base: detailBase, trailDetails: trailDetails,
                        onRunSelected: { segmentID in
                            guard let index = runs.firstIndex(where: { $0.id == segmentID }) else { return }
                            onRunSelected(RunMapDestination(dayID: day.id, runID: segmentID, number: index + 1))
                        }, onExpand: { showingFullScreenMap = true })
        .frame(height: 280)
        .fullScreenCover(isPresented: $showingFullScreenMap) {
            FullScreenSummaryMap(title: "Ride Map", base: detailBase,
                                 trailDetails: trailDetails,
                                 focusedSegmentID: nil,
                                 focusedRunNumber: nil)
        }
    }

    @MainActor
    private func prepareDetails() async {
        detailBase = nil
        trailDetails = nil
        prepareFailed = false
        await Task.yield()

        let cacheKey = preparationCacheKey(for: trails)
        if let cached = SessionDetailPresentationCache.shared.entry(for: cacheKey) {
            detailBase = cached.base
            trailDetails = cached.trailDetails
            return
        }

        guard let input = await SessionDetailPresentationPreheater.makeInput(
            dayID: day.id,
            manualCatalogID: trailCatalogSelection.manualCatalogID,
            container: modelContext.container
        ) else { return }
        guard !Task.isCancelled else { return }

        do {
            let baseTask = Task.detached(priority: .userInitiated) {
                try SessionDetailPresentationBuilder.buildBase(input)
            }
            let base = try await withTaskCancellationHandler {
                try await baseTask.value
            } onCancel: {
                baseTask.cancel()
            }
            guard !Task.isCancelled else { return }
            detailBase = base
            await Task.yield()

            let trailTask = Task.detached(priority: .userInitiated) {
                try SessionDetailPresentationBuilder.buildTrailDetails(base: base, input: input)
            }
            let details = try await withTaskCancellationHandler {
                try await trailTask.value
            } onCancel: {
                trailTask.cancel()
            }
            guard !Task.isCancelled else { return }
            trailDetails = details
            SessionDetailPresentationCache.shared.store(
                .init(base: base, trailDetails: details),
                for: cacheKey
            )
        } catch is CancellationError {
            return
        } catch {
            prepareFailed = true
        }
    }

}
