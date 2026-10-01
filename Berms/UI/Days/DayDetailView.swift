import Foundation
import MapKit
import SwiftData
import SwiftUI
import UIKit

struct DayDetailView: View {
    let day: RideDay
    let initiallyShowsRecap: Bool
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
    @State private var resolvedCatalog: TrailCatalogDescriptor?
    @State private var detailBase: SessionDetailBase?
    @State private var trailDetails: SessionDetailTrailDetails?
    @State private var notesSaveTask: Task<Void, Never>?
    @State private var saveErrorMessage: String?
    @State private var prepareFailed = false
    @State private var diagnosticLogURLs: [URL] = []
    @State private var isExportingDay = false
    @State private var showingShareCard = false
    @State private var showingRecap = false
    @State private var hasShownRecap = false
    @State private var correctionError: String?

    private static let mapPreviewHeight: CGFloat = 280
    private static let journalMinimumHeight: CGFloat = 140

    init(
        day: RideDay, initiallyShowsRecap: Bool = false,
        onRunSelected: @escaping (RunMapDestination) -> Void = { _ in }
    ) {
        self.day = day
        self.initiallyShowsRecap = initiallyShowsRecap
        self.onRunSelected = onRunSelected
    }

    private var runs: [RideSegment] {
        day.segments.filter { $0.kind == .run }.sorted { $0.startedAt < $1.startedAt }
    }

    private var lifts: [RideSegment] {
        day.segments.filter { $0.kind == .lift }.sorted { $0.startedAt < $1.startedAt }
    }

    private var correctionsBySegment: [UUID: SegmentCorrection] {
        Dictionary(day.corrections.map { ($0.segmentID, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private var timeBreakdown: DayTimeBreakdown {
        DayTimeBreakdown(day: day)
    }

    private var summaryMetrics: [DaySummaryMetric] {
        DaySummaryPresentation.detailMetrics(day: day, runCount: runs.count, liftCount: lifts.count)
    }

    private var hasPreparedRoute: Bool {
        guard let detailBase else { return true }
        return detailBase.runs.contains { $0.routePoints.count > 1 }
    }

    private var runRouteTitles: [UUID: String] {
        var sequences: [UUID: [String]] = [:]
        for segment in runs {
            let name =
                trailDetails?.sequenceBySegmentID[segment.id]
                ?? preheatedRun(for: segment)?.trailDetails.sequenceBySegmentID[segment.id]
            guard let name, !name.isEmpty else { continue }
            sequences[segment.id] = name.components(separatedBy: " → ")
        }
        return RouteTitleBuilder.titles(from: sequences)
    }

    private var preparationTaskKey: String {
        "\(day.id.uuidString)|\(catalogSelectionID)|\(presentationCache.invalidationRevision)|"
            + SessionDetailPresentationPreheater.trailRevision(for: trails)
    }

    private var dayCatalogID: String? {
        resolvedCatalog?.id
    }

    private var catalogSelectionID: String {
        day.catalogID ?? TrailCatalogRegistry.automaticSelectionID
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
            summarySection
            mapSection
            timeSection
            runsSection
            jumpsSection
            journalSection
        }
        .navigationTitle(
            day.hasCustomName ? day.displayName : day.startedAt.formatted(date: .abbreviated, time: .omitted)
        )
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
                        showingRecap = true
                    } label: {
                        Label("Day recap", systemImage: "sparkles")
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
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
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
            if initiallyShowsRecap, !hasShownRecap {
                hasShownRecap = true
                showingRecap = true
            }
        }
        .sheet(isPresented: $showingShareCard) {
            ShareCardSheet(
                day: day,
                base: detailBase,
                trailDetails: trailDetails,
                manualCatalogID: dayCatalogID)
        }
        .sheet(isPresented: $showingRecap) {
            DayRecapSheet(day: day, runs: runs, lifts: lifts) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    showingShareCard = true
                }
            }
        }
        .alert(
            "Couldn't apply correction",
            isPresented: Binding(
                get: { correctionError != nil },
                set: { if !$0 { correctionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(correctionError ?? "")
        }
        .task(id: day.id) {
            let dayID = day.id
            let startedAt = day.startedAt
            let endedAt = day.endedAt
            diagnosticLogURLs = await Task.detached(priority: .utility) {
                RideRecorder.diagnosticLogURLs(
                    for: dayID,
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
        let rawFilename =
            diagnosticLogURLs.first {
                $0.lastPathComponent.caseInsensitiveCompare(dayLogName) == .orderedSame
            }?.lastPathComponent ?? diagnosticLogURLs.first?.lastPathComponent

        let export = BermsDataExport(day: day, trails: trails, rawDiagnosticsFilename: rawFilename)
        let logURLs = diagnosticLogURLs
        let corrections = day.corrections

        Task {
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    try DayArchive.build(
                        export: export,
                        logURLs: logURLs,
                        corrections: corrections)
                }.value
                SharePresenter.present(fileURL: archive)
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
            for url in logURLs {
                try? FileManager.default.removeItem(at: url)
            }
            dismiss()
        } catch {
            modelContext.rollback()
            saveErrorMessage = "The day could not be deleted. \(error.localizedDescription)"
        }
    }

    private var resolvedResortName: String {
        resolvedCatalog?.resortName ?? "Unknown"
    }

    private var summary: some View {
        VStack(spacing: BermsSpacing.content) {
            ForEach(DaySummaryPresentation.rows(of: summaryMetrics), id: \.self) { row in
                AdaptiveStatRow {
                    ForEach(row) { metric in
                        SummaryStat(label: metric.label, value: metric.value)
                    }
                }
            }
        }
    }

    private var summarySection: some View {
        Section("Day summary") {
            LabeledContent("Resort", value: resolvedResortName)
            if day.segments.isEmpty {
                LabeledContent("Started", value: day.startedAt.formatted(date: .omitted, time: .shortened))
                LabeledContent("Duration", value: BermsFormat.duration(day.duration))
            } else {
                summary
            }
        }
    }

    @ViewBuilder
    private var mapSection: some View {
        if !runs.isEmpty && hasPreparedRoute {
            Section {
                dayMap
                    .listRowInsets(EdgeInsets())
            }
        }
    }

    @ViewBuilder
    private var timeSection: some View {
        if DaySummaryPresentation.showsTimeBreakdown(day: day, breakdown: timeBreakdown) {
            Section {
                DayTimeBreakdownView(
                    breakdown: timeBreakdown,
                    ridingTitle: "Riding time")
            } header: {
                Text("Time")
            } footer: {
                Text(timeFooter)
            }
        }
    }

    private var runsSection: some View {
        let routeTitles = runRouteTitles
        let corrections = correctionsBySegment
        return Section("Runs") {
            if runs.isEmpty {
                Text("No runs recorded during this session.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(runs.enumerated()), id: \.element.id) { index, segment in
                    let preheatedRun = preheatedRun(for: segment)
                    NavigationLink {
                        RunMapView(
                            number: index + 1,
                            segment: segment,
                            preparedBase: detailBase ?? preheatedRun?.base,
                            preparedDetail: detailBase?.segmentsByID[segment.id]
                                ?? preheatedRun?.detail,
                            preparedTrailDetails: trailDetails
                                ?? preheatedRun?.trailDetails)
                    } label: {
                        CompactRunRow(
                            number: index + 1,
                            segment: segment,
                            detail: detailBase?.segmentsByID[segment.id]
                                ?? preheatedRun?.detail,
                            routeTitle: routeTitles[segment.id],
                            isPreparingDetails: trailDetails == nil && preheatedRun == nil && !prepareFailed,
                            correction: corrections[segment.id])
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            mark(segment, as: .lift)
                        } label: {
                            Label("Mark as Lift", systemImage: "arrow.up.right")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var jumpsSection: some View {
        if jumpSummaryCount > 0 {
            Section {
                jumpSummary
            } header: {
                Text("Jumps")
            }
        }
    }

    private var journalSection: some View {
        Section("Journal") {
            TextEditor(text: $notesDraft)
                .frame(minHeight: Self.journalMinimumHeight)
                .textInputAutocapitalization(.sentences)
                .accessibilityLabel("Session journal")
        }
    }

    private var timeFooter: String {
        let end = day.endedAt ?? .now
        let range =
            day.startedAt.formatted(date: .omitted, time: .shortened) + " – "
            + end.formatted(date: .omitted, time: .shortened)
        guard !lifts.isEmpty else { return range }
        return "\(range) · \(BermsFormat.elevation(day.liftMeters)) lifted"
    }

    private var jumpSummaryCount: Int {
        detailBase?.jumpCount ?? day.jumpCount
    }

    private var jumpSummary: some View {
        VStack(spacing: BermsSpacing.content) {
            ForEach(
                DaySummaryPresentation.rows(
                    of: DaySummaryPresentation.jumpDetailMetrics(
                        day: day,
                        base: detailBase
                    )), id: \.self
            ) { row in
                AdaptiveStatRow {
                    ForEach(row) { metric in
                        SummaryStat(label: metric.label, value: metric.value)
                    }
                }
            }
        }
    }

    private func mark(_ segment: RideSegment, as kind: SegmentKind) {
        do {
            try SegmentEditor.mark(segment, as: kind, in: modelContext)
            correctionError = nil
        } catch {
            correctionError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var dayMap: some View {
        if runs.isEmpty {
            ContentUnavailableView(
                "No route", systemImage: "map",
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
            .frame(maxWidth: .infinity, minHeight: Self.mapPreviewHeight)
        } else {
            VStack(spacing: BermsSpacing.compact) {
                ProgressView()
                Text("Loading map…")
                    .font(.subheadline)
                    .foregroundStyle(Color.bermsMuted)
            }
            .frame(maxWidth: .infinity, minHeight: Self.mapPreviewHeight)
        }
    }

    @ViewBuilder
    private func preparedDayMap(_ detailBase: SessionDetailBase) -> some View {
        SessionRouteMap(
            base: detailBase, trailDetails: trailDetails,
            onRunSelected: { segmentID in
                guard let index = runs.firstIndex(where: { $0.id == segmentID }) else { return }
                onRunSelected(RunMapDestination(dayID: day.id, runID: segmentID, number: index + 1))
            }, onExpand: { showingFullScreenMap = true }
        )
        .frame(height: Self.mapPreviewHeight)
        .fullScreenCover(isPresented: $showingFullScreenMap) {
            FullScreenSummaryMap(
                title: "Ride Map",
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
            resolvedCatalog = cached.resolvedCatalog
            detailBase = cached.base
            trailDetails = cached.trailDetails
            return
        }

        resolvedCatalog = await SessionDetailPresentationPreheater.resolvedCatalog(
            dayID: day.id, container: modelContext.container)
        guard !Task.isCancelled else { return }
        guard
            let input = await SessionDetailPresentationPreheater.makeInput(
                dayID: day.id,
                manualCatalogID: dayCatalogID,
                container: modelContext.container
            )
        else {
            prepareFailed = true
            return
        }
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
                .init(resolvedCatalog: resolvedCatalog, base: base, trailDetails: details),
                for: cacheKey
            )
        } catch is CancellationError {
            return
        } catch {
            prepareFailed = true
        }
    }

}

/// Presents the system share sheet from the top-most view controller.
///
/// Hosting a `UIActivityViewController` as SwiftUI sheet content leaves its
/// activities without a stable presenter, which makes taps on Save Image or an
/// app silently do nothing. Presenting it modally from the view controller that
/// is already on screen keeps the sheet and its activities healthy.
@MainActor
enum SharePresenter {
    /// The menu that triggers a share is still dismissing, and presenting into
    /// it would take the share sheet down with the menu.
    private static let menuDismissalDelay: Duration = .milliseconds(250)

    static func present(fileURL: URL) {
        Task { @MainActor in
            try? await Task.sleep(for: menuDismissalDelay)
            guard let controller = topMostViewController(),
                !(controller is UIActivityViewController)
            else { return }
            let activity = UIActivityViewController(
                activityItems: [fileURL],
                applicationActivities: nil)
            controller.present(activity, animated: true)
        }
    }

    private static func topMostViewController() -> UIViewController? {
        guard let window = activeWindow else { return nil }
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private static var activeWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }
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
    static func build(
        export: BermsDataExport, logURLs: [URL], corrections: [SegmentCorrection] = []
    ) throws -> URL {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("Berms-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        // Jump timestamps need sub-second precision: airtime is stored at full
        // precision and the two must agree.
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(export)
        try json.write(
            to: folder.appendingPathComponent("Berms-\(export.parsed.dayID)-data.json"),
            options: .atomic)

        // Corrections only travel when the rider has opted in to sharing them.
        if !corrections.isEmpty,
            UserDefaults.standard.bool(forKey: CorrectionsSharing.key),
            let dayID = export.days.first?.id
        {
            let data = try encoder.encode(corrections)
            try data.write(
                to: folder.appendingPathComponent("Berms-\(dayID)-corrections.json"),
                options: .atomic)
        }

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
        NSFileCoordinator().coordinate(
            readingItemAt: folder,
            options: .forUploading,
            error: &coordinatorError
        ) { archiveURL in
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

/// Shortens multi-trail route strings for list rows: long sequences keep their
/// ends, and lookalike runs swap the ellipsis for the middle trail that differs.
enum RouteTitleBuilder {
    static func titles(from sequences: [UUID: [String]]) -> [UUID: String] {
        var titles = sequences.mapValues(compact)
        var idsByTitle: [String: [UUID]] = [:]
        for (id, title) in titles {
            idsByTitle[title, default: []].append(id)
        }
        for (_, ids) in idsByTitle where ids.count > 1 {
            for id in ids {
                guard let parts = sequences[id], parts.count > 2 else { continue }
                let others = ids.compactMap { $0 == id ? nil : sequences[$0] }
                guard let differentiator = differentiator(in: parts, versus: others) else { continue }
                titles[id] = "\(parts[0]) → \(differentiator) → \(parts[parts.count - 1])"
            }
        }
        return titles
    }

    static func compact(_ parts: [String]) -> String {
        if parts.count <= 2 {
            return parts.joined(separator: " → ")
        }
        let joined = parts.joined(separator: " → ")
        guard joined.count > 28 else { return joined }
        return "\(parts[0]) → \(parts[parts.count - 1])"
    }

    private static func differentiator(in parts: [String], versus others: [[String]]) -> String? {
        guard others.isEmpty == false else { return nil }
        for index in 1..<(parts.count - 1) {
            let candidate = parts[index]
            let collides = others.contains { other in
                index < other.count && other[index] == candidate
            }
            if !collides { return candidate }
        }
        return nil
    }
}

/// Two-line run row: number, trail, duration, then one metadata line. The full
/// stat grid lives one tap deeper in the run.
private struct CompactRunRow: View {
    let number: Int
    let segment: RideSegment
    let detail: SessionDetailSegment?
    let routeTitle: String?
    let isPreparingDetails: Bool
    let correction: SegmentCorrection?

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: BermsSpacing.compact) {
                Text("\(number)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(trailTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(durationTitle)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize()
            }
            HStack(spacing: BermsSpacing.compact) {
                Text(metadataLine)
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
                    .lineLimit(1)
                if let correction {
                    Text(Self.caption(for: correction))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.bermsMuted)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Run \(number), \(trailTitle)")
        .accessibilityValue("\(durationTitle), \(metadataLine)")
    }

    private var trailTitle: String {
        if let routeTitle, !routeTitle.isEmpty { return routeTitle }
        return isPreparingDetails ? "Loading trail…" : "Trail not identified"
    }

    private var durationTitle: String {
        detail.map { BermsFormat.duration($0.duration) } ?? "…"
    }

    private var metadataLine: String {
        var parts = [BermsFormat.elevation(verticalMeters) + " descent"]
        if let detail, !detail.jumps.isEmpty {
            let count = detail.jumps.count
            parts.append(count == 1 ? "1 jump" : "\(count) jumps")
        }
        parts.append(BermsFormat.speed(maximumSpeedMetersPerSecond))
        return parts.joined(separator: " · ")
    }

    private var verticalMeters: Double {
        detail?.verticalMeters ?? segment.verticalMeters
    }

    private var maximumSpeedMetersPerSecond: Double {
        detail?.maximumSpeedMetersPerSecond ?? segment.maximumSpeedMetersPerSecond
    }

    static func caption(for correction: SegmentCorrection) -> String {
        switch correction.kind {
        case .split: "Split by you"
        case .markLift: "Marked as lift"
        case .markRun: "Marked as run"
        }
    }
}
