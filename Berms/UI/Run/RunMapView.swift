import MapKit
import SwiftData
import SwiftUI
import UIKit

struct RunMapDestination: Hashable {
    let dayID: UUID
    let runID: UUID
    let number: Int
}

struct FullScreenSummaryMap: View {
    let title: String
    let base: SessionDetailBase?
    let trailDetails: SessionDetailTrailDetails?
    let focusedSegmentID: UUID?
    let focusedRunNumber: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let base {
                    SessionRouteMap(
                        base: base, trailDetails: trailDetails,
                        focusedSegmentID: focusedSegmentID,
                        focusedRunNumber: focusedRunNumber,
                        extendsUnderBars: true)
                } else {
                    ProgressView("Loading map…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct RunMapView: View {
    private static let mapPreviewHeight: CGFloat = 320

    @Environment(\.modelContext) private var modelContext
    let number: Int
    let segment: RideSegment
    let preparedBase: SessionDetailBase?
    let preparedDetail: SessionDetailSegment?
    let preparedTrailDetails: SessionDetailTrailDetails?
    @Query private var trails: [Trail]
    @State private var showingFullScreenMap = false
    @State private var ownBase: SessionDetailBase?
    @State private var ownTrailDetails: SessionDetailTrailDetails?
    @State private var jumpComparisons: SessionJumpComparisons = .empty
    @State private var isPreparing = false
    @State private var prepareFailed = false

    init(
        number: Int,
        segment: RideSegment,
        preparedBase: SessionDetailBase? = nil,
        preparedDetail: SessionDetailSegment? = nil,
        preparedTrailDetails: SessionDetailTrailDetails? = nil
    ) {
        self.number = number
        self.segment = segment
        self.preparedBase = preparedBase
        self.preparedDetail = preparedDetail
        self.preparedTrailDetails = preparedTrailDetails
    }

    private var activeBase: SessionDetailBase? {
        preparedBase ?? ownBase
    }

    private var activeDetail: SessionDetailSegment? {
        preparedDetail ?? ownBase?.segmentsByID[segment.id]
    }

    private var activeTrailDetails: SessionDetailTrailDetails? {
        preparedTrailDetails ?? ownTrailDetails
    }

    private var routePoints: [RoutePoint] {
        activeDetail?.routePoints ?? []
    }

    private var isLoaded: Bool {
        activeDetail != nil
    }

    private var runStats: [DaySummaryMetric] {
        RunStatsPresentation.metrics(segment: segment, detail: activeDetail)
    }

    var body: some View {
        ZStack {
            BermsBackground()
            if !isLoaded {
                if prepareFailed {
                    ContentUnavailableView {
                        Label("Map unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("This run's map could not be prepared.")
                    } actions: {
                        Button("Try Again") {
                            Task { await prepareIfNeeded(force: true) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: BermsSpacing.compact) {
                        ProgressView()
                        Text("Loading map…")
                            .font(.subheadline)
                            .foregroundStyle(Color.bermsMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    if routePoints.count > 1 {
                        if let activeBase {
                            Section {
                                SessionRouteMap(
                                    base: activeBase, trailDetails: activeTrailDetails,
                                    focusedSegmentID: segment.id, focusedRunNumber: number,
                                    onExpand: { showingFullScreenMap = true }
                                )
                                .frame(height: Self.mapPreviewHeight)
                                .listRowInsets(EdgeInsets())
                            }
                        }
                    } else {
                        Section {
                            Label("No route recorded", systemImage: "map")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !runStats.isEmpty {
                        Section("Run stats") {
                            RunStatsCard(segment: segment, detail: activeDetail)
                        }
                    }
                    jumpsSection
                    if activeTrailDetails != nil {
                        Section("Trail") {
                            TrailSequenceCard(sequence: trailSequence, runNumber: number)
                        }
                    }
                }
                .fullScreenCover(isPresented: $showingFullScreenMap) {
                    FullScreenSummaryMap(
                        title: "Run \(number)", base: activeBase,
                        trailDetails: activeTrailDetails,
                        focusedSegmentID: segment.id,
                        focusedRunNumber: number)
                }
            }
        }
        .navigationTitle("Run \(number)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: preparedDetail == nil) { await prepareIfNeeded() }
        .task(id: segment.id) { await prepareJumpComparisons() }
    }

    @ViewBuilder
    private var jumpsSection: some View {
        if !jumps.isEmpty {
            Section {
                if notableJumps.isEmpty {
                    Text("No notable jumps in this run.")
                        .foregroundStyle(.secondary)
                }
                ForEach(notableJumps, id: \.index) { entry in
                    jumpLink(index: entry.index, jump: entry.jump)
                }
                if !smallerJumps.isEmpty {
                    DisclosureGroup("Smaller catches (\(smallerJumps.count))") {
                        ForEach(smallerJumps, id: \.index) { entry in
                            jumpLink(index: entry.index, jump: entry.jump)
                        }
                    }
                }
            } header: {
                Text("Jumps")
            }
        }
    }

    private func jumpLink(index: Int, jump: JumpEvent) -> some View {
        let attemptID = jumpAttemptID(index: index)
        let feature = jumpComparisons.feature(forAttemptID: attemptID)
        return NavigationLink {
            JumpComparisonView(
                attempt: attempt(at: index, jump: jump),
                feature: feature)
        } label: {
            RunJumpRow(
                number: index + 1,
                jump: jump,
                attemptID: attemptID,
                feature: feature)
        }
    }

    private var notableJumps: [(index: Int, jump: JumpEvent)] {
        jumps.enumerated()
            .filter { isNotable($0.element) }
            .map { (index: $0.offset, jump: $0.element) }
    }

    private var smallerJumps: [(index: Int, jump: JumpEvent)] {
        jumps.enumerated()
            .filter { !isNotable($0.element) }
            .map { (index: $0.offset, jump: $0.element) }
    }

    private func isNotable(_ jump: JumpEvent) -> Bool {
        jump.airtime >= 0.4 || (jump.lengthMeters ?? 0) >= 5
    }

    private var jumps: [JumpEvent] {
        activeDetail?.jumps ?? []
    }

    private func jumpAttemptID(index: Int) -> String {
        "\(segment.id.uuidString)-\(index)"
    }

    private func attempt(at index: Int, jump: JumpEvent) -> SessionJumpAttempt {
        let id = jumpAttemptID(index: index)
        if let existing = jumpComparisons.features
            .flatMap(\.attempts)
            .first(where: { $0.id == id })
        {
            return existing
        }
        return SessionJumpAttempt(
            id: id,
            segmentID: segment.id,
            runNumber: number,
            jumpNumber: index + 1,
            jump: jump)
    }

    @MainActor
    private func prepareJumpComparisons() async {
        guard let dayID = segment.day?.id else { return }
        let comparisons = await SessionDetailPresentationPreheater.prepareJumpComparisons(
            dayID: dayID,
            container: modelContext.container)
        guard !Task.isCancelled, let comparisons else { return }
        jumpComparisons = comparisons
    }

    private var trailSequence: String {
        guard let activeDetail, let activeTrailDetails else { return "Loading trails…" }
        return activeTrailDetails.sequenceBySegmentID[activeDetail.id] ?? "Trail not identified"
    }

    /// Prepares this run off the main actor when the caller has no presentation for
    /// it, so decoding and trail matching never run on the rendering path.
    @MainActor
    private func prepareIfNeeded(force: Bool = false) async {
        guard preparedDetail == nil, activeDetail == nil, !isPreparing || force else { return }
        if force { prepareFailed = false }
        let catalogID =
            segment.day.flatMap(TrailCatalogRegistry.resolvedCatalog(for:))?.id
        let selectionID = catalogID ?? TrailCatalogRegistry.automaticSelectionID
        var runKey: String?
        if let dayID = segment.day?.id {
            runKey = SessionDetailPresentationPreheater.runCacheKey(
                dayID: dayID,
                segmentID: segment.id,
                selectionID: selectionID,
                trails: trails)
            // A prepared day already covers every run in it, so reuse it before matching again.
            let dayKey = SessionDetailPresentationPreheater.cacheKey(
                dayID: dayID,
                selectionID: selectionID,
                trails: trails)
            if let dayEntry = SessionDetailPresentationCache.shared.entry(for: dayKey),
                dayEntry.base.segmentsByID[segment.id] != nil
            {
                ownBase = dayEntry.base
                ownTrailDetails = dayEntry.trailDetails
                return
            }
        }
        if let runKey, let cached = SessionDetailPresentationCache.shared.runEntry(for: runKey) {
            ownBase = cached.base
            ownTrailDetails = cached.trailDetails
            return
        }
        isPreparing = true
        defer { isPreparing = false }
        do {
            guard
                let entry = try await SessionDetailPresentationPreheater.prepareRun(
                    segmentID: segment.id,
                    manualCatalogID: catalogID,
                    container: modelContext.container,
                    onBase: { ownBase = $0 }
                )
            else { return }
            guard !Task.isCancelled else { return }
            ownTrailDetails = entry.trailDetails
            if let runKey {
                SessionDetailPresentationCache.shared.storeRun(entry, for: runKey)
            }
        } catch is CancellationError {
            return
        } catch {
            prepareFailed = true
        }
    }

}

struct RunStatsCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let segment: RideSegment
    let detail: SessionDetailSegment?

    var body: some View {
        let metrics = RunStatsPresentation.metrics(segment: segment, detail: detail)
        let columnCount = dynamicTypeSize.isAccessibilitySize ? 1 : min(2, max(1, metrics.count))
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: columnCount),
            alignment: .leading,
            spacing: BermsSpacing.content
        ) {
            ForEach(metrics) { metric in
                SummaryStat(label: metric.label, value: metric.value)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

enum RunStatsPresentation {
    static func metrics(segment: RideSegment, detail: SessionDetailSegment?) -> [DaySummaryMetric] {
        guard let detail else { return [] }
        var metrics: [DaySummaryMetric] = []
        appendPositive(BermsFormat.duration(detail.duration), label: "Duration", when: detail.duration, to: &metrics)
        appendPositive(
            BermsFormat.distance(segment.distanceMeters), label: "Distance", when: segment.distanceMeters, to: &metrics)
        appendPositive(
            BermsFormat.elevation(segment.verticalMeters), label: "Descent", when: segment.verticalMeters, to: &metrics)
        appendPositive(
            BermsFormat.speed(segment.maximumSpeedMetersPerSecond),
            label: "Top speed",
            when: segment.maximumSpeedMetersPerSecond,
            to: &metrics)

        if !detail.jumps.isEmpty {
            metrics.append(DaySummaryMetric(label: "Jumps", value: "\(detail.jumps.count)"))
            if let airtime = detail.jumps.map(\.airtime).max(), airtime > 0 {
                metrics.append(DaySummaryMetric(label: "Best airtime", value: BermsFormat.airtime(airtime)))
            }
            if let length = detail.jumps.compactMap(\.lengthMeters).max(), length > 0 {
                metrics.append(DaySummaryMetric(label: "Longest jump", value: BermsFormat.jumpSize(length)))
            }
            if let height = detail.jumps.compactMap(\.heightMeters).max(), height > 0 {
                metrics.append(DaySummaryMetric(label: "Highest air", value: BermsFormat.jumpSize(height)))
            }
        }
        return metrics
    }

    private static func appendPositive(
        _ value: String,
        label: String,
        when quantity: Double,
        to metrics: inout [DaySummaryMetric]
    ) {
        guard quantity > 0 else { return }
        metrics.append(DaySummaryMetric(label: label, value: value))
    }
}

struct JumpStatsGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let jump: JumpEvent

    var body: some View {
        let metrics = JumpStatsPresentation.metrics(jump: jump)
        let columnCount = dynamicTypeSize.isAccessibilitySize ? 1 : max(1, metrics.count)
        Group {
            if metrics.isEmpty {
                Text("No jump measurements available.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: columnCount),
                    alignment: .leading, spacing: BermsSpacing.content
                ) {
                    ForEach(metrics) { metric in
                        SummaryStat(label: metric.label, value: metric.value)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

enum JumpStatsPresentation {
    static func metrics(jump: JumpEvent) -> [DaySummaryMetric] {
        var metrics: [DaySummaryMetric] = []
        if let length = jump.lengthMeters, length > 0 {
            metrics.append(DaySummaryMetric(label: "Length", value: BermsFormat.jumpSize(length)))
        }
        if let height = jump.heightMeters, height > 0 {
            metrics.append(DaySummaryMetric(label: "Highest air", value: BermsFormat.jumpSize(height)))
        }
        if jump.airtime > 0 {
            metrics.append(DaySummaryMetric(label: "Airtime", value: BermsFormat.airtime(jump.airtime)))
        }
        return metrics
    }
}

struct RunJumpRow: View {
    let number: Int
    let jump: JumpEvent
    let attemptID: String
    let feature: SessionJumpFeature?

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.tight) {
            Text("Jump \(number)")
                .font(.headline)
            Text(jumpStatsLine(jump))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.bermsMuted)
            if let comparisonLine {
                Text(comparisonLine)
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Jump \(number)")
        .accessibilityValue(accessibilityValue)
    }

    private var comparisonLine: String? {
        guard let feature, feature.attempts.count > 1,
            let best = feature.attempts.max(by: {
                ($0.jump.lengthMeters ?? 0) < ($1.jump.lengthMeters ?? 0)
            })
        else { return nil }
        if best.id == attemptID {
            let runCount = Set(feature.attempts.map(\.runNumber)).count
            return runCount == 2
                ? "Best of 2 runs at this jump"
                : "Best of \(runCount) runs at this jump"
        }
        return "Best \(BermsFormat.jumpSize(best.jump.lengthMeters)) · Run \(best.runNumber)"
    }

    private var accessibilityValue: String {
        [jumpStatsLine(jump), comparisonLine].compactMap { $0 }.joined(separator: ", ")
    }
}

struct JumpComparisonView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let attempt: SessionJumpAttempt
    let feature: SessionJumpFeature?

    private var attempts: [SessionJumpAttempt] {
        (feature?.attempts ?? [attempt]).sorted {
            ($0.runNumber, $0.jumpNumber) < ($1.runNumber, $1.jumpNumber)
        }
    }

    private var bestLengthID: String? {
        attempts.max(by: { ($0.jump.lengthMeters ?? 0) < ($1.jump.lengthMeters ?? 0) })?.id
    }

    private func comparisonTitle(for other: SessionJumpAttempt) -> some View {
        Text("Run \(other.runNumber) · Jump \(other.jumpNumber)")
            .font(.headline)
    }

    private func comparisonValue(for other: SessionJumpAttempt) -> some View {
        Text(BermsFormat.jumpSize(other.jump.lengthMeters))
            .font(.headline.monospacedDigit())
    }

    var body: some View {
        List {
            Section("Run \(attempt.runNumber) · Jump \(attempt.jumpNumber)") {
                JumpStatsGrid(jump: attempt.jump)
            }
            if attempts.count > 1 {
                Section {
                    ForEach(attempts, id: \.id) { other in
                        VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                                    comparisonTitle(for: other)
                                    comparisonValue(for: other)
                                }
                            } else {
                                HStack {
                                    comparisonTitle(for: other)
                                    Spacer()
                                    comparisonValue(for: other)
                                }
                            }
                            Text(jumpStatsLine(other.jump))
                                .font(.caption)
                                .foregroundStyle(Color.bermsMuted)
                            if other.id == bestLengthID {
                                Text("Longest in session")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.bermsMuted)
                            }
                            if other.id == attempt.id {
                                Text("This run")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.bermsMuted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Across runs")
                }
            } else {
                Section {
                    Text("No other run in this session hit this jump.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Jump \(attempt.jumpNumber)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func jumpStatsLine(_ jump: JumpEvent) -> String {
    var parts: [String] = []
    if let length = jump.lengthMeters {
        parts.append(BermsFormat.jumpSize(length))
    }
    if let height = jump.heightMeters {
        parts.append("\(BermsFormat.jumpSize(height)) air")
    }
    parts.append(BermsFormat.airtime(jump.airtime))
    return parts.joined(separator: " · ")
}

struct TrailSequenceCard: View {
    let sequence: String
    let runNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.compact) {
            Text(sequence)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("Run \(runNumber)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.bermsMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sequence), Run \(runNumber)")
    }
}
