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
            } else if routePoints.isEmpty {
                ContentUnavailableView(
                    "No route", systemImage: "map",
                    description: Text("This run has no recorded GPS route."))
            } else {
                List {
                    Section {
                        if let activeBase {
                            SessionRouteMap(
                                base: activeBase, trailDetails: activeTrailDetails,
                                focusedSegmentID: segment.id, focusedRunNumber: number,
                                onExpand: { showingFullScreenMap = true }
                            )
                            .frame(height: 320)
                            .listRowInsets(EdgeInsets())
                        }
                    }
                    Section("Run stats") {
                        RunStatsCard(segment: segment, detail: activeDetail)
                    }
                    Section("Trail") {
                        TrailSequenceCard(sequence: trailSequence, runNumber: number)
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
        VStack(alignment: .leading, spacing: BermsSpacing.control) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                alignment: .leading, spacing: BermsSpacing.content
            ) {
                // Decoded values wait for the prepared detail; reading them from the
                // segment would decode its route and jumps on the rendering path.
                SummaryStat(label: "Duration", value: detail.map { BermsFormat.duration($0.duration) } ?? "…")
                SummaryStat(label: "Distance", value: BermsFormat.distance(segment.distanceMeters))
                SummaryStat(label: "Descent", value: BermsFormat.elevation(segment.verticalMeters))
                SummaryStat(label: "Top speed", value: BermsFormat.speed(segment.maximumSpeedMetersPerSecond))
                SummaryStat(label: "Jumps", value: detail.map { "\($0.jumps.count)" } ?? "…")
                SummaryStat(label: "Best airtime", value: bestAirtime)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var bestAirtime: String {
        guard let detail else { return "…" }
        guard let airtime = detail.jumps.map(\.airtime).max() else { return "—" }
        return BermsFormat.airtime(airtime)
    }
}

struct TrailSequenceCard: View {
    let sequence: String
    let runNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.compact) {
            Text(sequence)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                sequence == "Trail not identified"
                    ? "Run \(runNumber) · GPS route only"
                    : "Run \(runNumber)"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.bermsMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sequence), Run \(runNumber)")
    }
}

struct SegmentRow: View {
    let number: Int
    let segment: RideSegment
    let detail: SessionDetailSegment?
    var trailName: String?
    let isPreparingDetails: Bool

    init(
        number: Int,
        segment: RideSegment,
        detail: SessionDetailSegment? = nil,
        trailName: String? = nil,
        isPreparingDetails: Bool = false
    ) {
        self.number = number
        self.segment = segment
        self.detail = detail
        self.trailName = trailName
        self.isPreparingDetails = isPreparingDetails
    }

    var body: some View {
        AdaptiveStatRow {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .accessibilityLabel("Run \(number)")
            VStack(alignment: .leading, spacing: 3) {
                Text(trailTitle)
                    .font(.headline)
                Text("Run \(number) · \(durationTitle)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bermsMuted)
                if let detail, detail.kind == .run, !detail.jumps.isEmpty {
                    Text("\(detail.jumps.count) jumps · \(BermsFormat.airtime(detail.jumps.map(\.airtime).max() ?? 0))")
                        .font(.caption)
                        .foregroundStyle(Color.bermsMuted)
                }
                Text(
                    kind == .run
                        ? BermsFormat.elevation(verticalMeters) + " descent"
                        : BermsFormat.elevation(verticalMeters) + " up"
                )
                .font(.caption)
                .foregroundStyle(Color.bermsMuted)
            }
            Spacer()
            Text(BermsFormat.speed(maximumSpeedMetersPerSecond))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    private var trailTitle: String {
        if let trailName { return trailName }
        return isPreparingDetails ? "Loading trail details…" : "Trail not identified"
    }

    private var durationTitle: String {
        // Reading the segment duration decodes its route, which is the work moved off
        // the main actor while preparation runs.
        detail.map { BermsFormat.duration($0.duration) } ?? "…"
    }

    private var kind: SegmentKind {
        detail?.kind ?? segment.kind
    }

    private var verticalMeters: Double {
        detail?.verticalMeters ?? segment.verticalMeters
    }

    private var maximumSpeedMetersPerSecond: Double {
        detail?.maximumSpeedMetersPerSecond ?? segment.maximumSpeedMetersPerSecond
    }
}
