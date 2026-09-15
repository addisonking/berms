import Foundation
import MapKit
import SwiftData
import SwiftUI
import UIKit

struct DayDetailView: View {
    let day: RideDay
    let onRunSelected: (RunMapDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
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
    @State private var diagnosticLogURLs: [URL] = []
    @State private var exportedArchive: ExportArchive?
    @State private var isExportingDay = false
    @State private var showingShareCard = false

    init(day: RideDay, onRunSelected: @escaping (RunMapDestination) -> Void = { _ in }) {
        self.day = day
        self.onRunSelected = onRunSelected
    }

    private var runs: [RideSegment] {
        day.segments.filter { $0.kind == .run }.sorted { $0.startedAt < $1.startedAt }
    }

    private var preparationTaskKey: String {
        "\(day.id.uuidString)|\(catalogSelectionID)|"
            + SessionDetailPresentationPreheater.trailRevision(for: trails)
    }

    private var dayCatalogID: String? {
        day.catalogID ?? TrailCatalogRegistry.catalog(for: day.activityMode)?.id
    }

    private var catalogSelectionID: String {
        dayCatalogID ?? TrailCatalogRegistry.automaticSelectionID
    }

    private func preparationCacheKey(for trails: [Trail]) -> String {
        SessionDetailPresentationPreheater.cacheKey(
            dayID: day.id,
            selectionID: catalogSelectionID,
            trails: trails
        )
    }

    private func preheatedRun(for segment: RideSegment) -> SessionDetailPresentationCache.RunEntry? {
        let key = SessionDetailPresentationPreheater.runCacheKey(
            dayID: day.id,
            segmentID: segment.id,
            selectionID: catalogSelectionID,
            trails: trails
        )
        return presentationCache.runEntry(for: key)
    }

    var body: some View {
        List {
            Section("Day summary") {
                LabeledContent("Activity", value: day.activityMode.title)
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
                    Button {
                        showingShareCard = true
                    } label: {
                        Label("Share image", systemImage: "photo.on.rectangle.angled")
                    }
                    Button {
                        exportDay()
                    } label: {
                        Label("Export day", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isExportingDay)
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
        .sheet(item: $exportedArchive) { archive in
            ShareSheet(items: [archive.url])
        }
        .sheet(isPresented: $showingShareCard) {
            ShareCardSheet(day: day,
                           base: detailBase,
                           trailDetails: trailDetails,
                           manualCatalogID: dayCatalogID)
        }
        .task(id: day.id) {
            let dayID = day.id
            let startedAt = day.startedAt
            let endedAt = day.endedAt
            diagnosticLogURLs = await Task.detached(priority: .utility) {
                RideRecorder.diagnosticLogURLs(for: dayID,
                                               startedAt: startedAt,
                                               endedAt: endedAt)
            }.value
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

    private func exportDay() {
        guard !isExportingDay else { return }
        isExportingDay = true

        let dayLogName = "Berms-\(day.id.uuidString).jsonl"
        let rawFilename = diagnosticLogURLs.first {
            $0.lastPathComponent.caseInsensitiveCompare(dayLogName) == .orderedSame
        }?.lastPathComponent ?? diagnosticLogURLs.first?.lastPathComponent

        let export = BermsDataExport(day: day, trails: trails, rawDiagnosticsFilename: rawFilename)
        let logURLs = diagnosticLogURLs

        Task {
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    try DayArchive.build(export: export, logURLs: logURLs)
                }.value
                exportedArchive = ExportArchive(url: archive)
                saveErrorMessage = nil
            } catch {
                saveErrorMessage = "The day export could not be created. \(error.localizedDescription)"
            }
            isExportingDay = false
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
        let logURLs = diagnosticLogURLs
        modelContext.delete(day)
        do {
            try modelContext.save()
            logURLs.forEach { try? FileManager.default.removeItem(at: $0) }
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
                    SummaryStat(label: day.activityMode.activeTimeTitle,
                                value: BermsFormat.duration(day.activeSeconds))
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
            FullScreenSummaryMap(title: day.activityMode == .ski ? "Ski Map" : "Ride Map",
                                 base: detailBase,
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
            manualCatalogID: dayCatalogID,
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

struct ExportArchive: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum DayArchiveError: LocalizedError {
    case zipFailed(Error)

    var errorDescription: String? {
        switch self {
        case .zipFailed(let error): "Couldn't build the zip: \(error.localizedDescription)"
        }
    }
}

/// One shareable zip holding the parsed day and every raw log behind it.
enum DayArchive {
    static func build(export: BermsDataExport, logURLs: [URL]) throws -> URL {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("Berms-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(export)
        try json.write(to: folder.appendingPathComponent("Berms-\(export.parsed.dayID)-data.json"),
                       options: .atomic)

        for log in logURLs {
            try? fileManager.copyItem(at: log, to: folder.appendingPathComponent(log.lastPathComponent))
        }

        let destination = fileManager.temporaryDirectory
            .appendingPathComponent(archiveName(for: export) + ".zip")
        try? fileManager.removeItem(at: destination)
        try zip(folder, to: destination)
        return destination
    }

    private static func archiveName(for export: BermsDataExport) -> String {
        let date = export.days.first?.startedAt ?? export.exportedAt
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Berms-\(formatter.string(from: date))"
    }

    private static func zip(_ folder: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder,
                                       options: .forUploading,
                                       error: &coordinatorError) { archiveURL in
            do {
                try fileManager.copyItem(at: archiveURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw DayArchiveError.zipFailed(coordinatorError) }
        if let copyError { throw DayArchiveError.zipFailed(copyError) }
    }
}
