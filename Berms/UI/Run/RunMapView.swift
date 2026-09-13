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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let base: SessionDetailBase?
    let trailDetails: SessionDetailTrailDetails?
    let focusedSegmentID: UUID?
    let focusedRunNumber: Int?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @State private var mapPosition: MapCameraPosition = .automatic

    private var visibleSegments: [SessionDetailSegment] {
        guard let base else { return [] }
        if let focusedSegmentID {
            return base.mapSegments.filter { $0.id == focusedSegmentID }
        }
        return base.mapSegments.filter {
            $0.kind == .run || (mapLayerPreferences.showsLiftPaths && $0.kind == .lift)
        }
    }

    private var mapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: visibleSegments.flatMap(\.routePoints))
    }

    private var jumpMarkers: [SummaryMapJump] {
        guard let base else { return [] }
        let markers = focusedSegmentID.map { segmentID in
            base.jumpMarkers.filter { $0.segmentID == segmentID }
        } ?? base.summaryJumpMarkers
        return markers.map {
            SummaryMapJump(id: $0.id,
                           number: $0.number,
                           label: "Jump \($0.number)",
                           coordinate: coordinate(for: $0.coordinate),
                           airtime: $0.airtime)
        }
    }

    private var matchedTrailOverlays: [TrailMapOverlay] {
        guard let trailDetails else { return [] }
        return trailDetails.overlays
            .filter { focusedSegmentID == nil || $0.segmentID == focusedSegmentID }
            .map {
                TrailMapOverlay(id: $0.id,
                                trailID: $0.trailID,
                                name: $0.name,
                                difficulty: $0.difficulty,
                                points: $0.points,
                                score: $0.score)
            }
    }

    private var hasMatchedTrailOverlays: Bool {
        !matchedTrailOverlays.isEmpty
    }

    private var liftPathsAvailable: Bool {
        base?.mapSegments.contains { $0.kind == .lift } ?? false
    }

    var body: some View {
        NavigationStack {
            if base == nil {
                VStack(spacing: BermsSpacing.compact) {
                    ProgressView()
                    Text("Loading map…")
                        .font(.subheadline)
                        .foregroundStyle(Color.bermsMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(BermsBackground())
            } else {
            ZStack(alignment: .topTrailing) {
                ZStack {
                Map(position: $mapPosition, bounds: mapConfiguration?.bounds,
                    interactionModes: [.pan, .zoom]) {
                        ForEach(Array(visibleSegments.enumerated()), id: \.element.id) { index, segment in
                            if segment.routePoints.count > 1 {
                                if segment.kind == .lift {
                                    if mapLayerPreferences.showsLiftPaths {
                                        MapPolyline(coordinates: coordinates(for: segment.routePoints))
                                            .stroke(Color.bermsLift.opacity(0.78), style: StrokeStyle(
                                                lineWidth: 2.25, lineCap: .round, lineJoin: .round, dash: [5, 4]
                                            ))
                                    }
                                } else if mapLayerPreferences.showsRidePath {
                                    MapPolyline(coordinates: coordinates(for: segment.routePoints))
                                        .stroke(focusedSegmentID == nil
                                                ? Color.gray.opacity(RideMapPresentation.summaryRunOpacity(
                                                    index: index, count: visibleSegments.count))
                                                : Color.bermsTrail, lineWidth: 4)
                                }
                            }
                        }
                        ForEach(Array(visibleSegments.filter { $0.kind == .run }.enumerated()), id: \.element.id) { index, segment in
                            if let coordinate = segment.routePoints.first.map({
                                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                            }) {
                                Annotation("", coordinate: coordinate) {
                                    RunNumberMarker(
                                        number: focusedSegmentID == nil
                                            ? index + 1
                                            : (focusedRunNumber ?? index + 1),
                                        isSelected: focusedSegmentID == segment.id
                                    )
                                }
                            }
                        }
                        if mapLayerPreferences.showsJumps {
                            ForEach(jumpMarkers) { marker in
                                Annotation("", coordinate: marker.coordinate) {
                                    JumpMapMarker(number: marker.number,
                                                  airtime: marker.airtime,
                                                  showsAirtime: focusedSegmentID != nil)
                                }
                            }
                        }
                        if mapLayerPreferences.showsActualTrails {
                            ForEach(Array(matchedTrailOverlays.prefix(12))) { overlay in
                                trailMapContent(coordinates: overlay.coordinates,
                                                difficulty: overlay.difficulty,
                                                lineWidth: TrailMapRendering.lineWidth)
                                if focusedSegmentID != nil,
                                   let coordinate = trailLabelCoordinate(for: overlay.points) {
                                    Annotation("", coordinate: coordinate) {
                                        TrailMapLabel(name: overlay.name,
                                                      difficulty: overlay.difficulty,
                                                      color: overlay.color)
                                    }
                                }
                            }
                            ForEach(Array(matchedTrailOverlays.dropFirst(12))) { overlay in
                                trailMapContent(coordinates: overlay.coordinates,
                                                difficulty: overlay.difficulty,
                                                lineWidth: TrailMapRendering.lineWidth)
                            }
                        }
                    }
                    .mapStyle(.bermsMonochrome)
                    .mapControls { MapCompass() }

                }
                VStack(spacing: BermsSpacing.compact) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsActualTrailsControl: true,
                                  actualTrailsAvailable: hasMatchedTrailOverlays,
                                  showsJumpsControl: !jumpMarkers.isEmpty,
                                  showsLiftPathsControl: focusedSegmentID == nil,
                                  liftPathsAvailable: liftPathsAvailable)
                    Button {
                        withAnimation(reduceMotion ? nil : BermsMotion.recenter) { recenterMap() }
                    } label: {
                        Image(systemName: "scope")
                            .font(.headline)
                            .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
                    }
                    .bermsMapControl()
                    .accessibilityLabel("Recenter map")
                }
                .padding(BermsSpacing.control)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { recenterMap() }
            }
        }
    }

    private func recenterMap() {
        mapPosition = mapConfiguration?.initialPosition ?? .automatic
    }

    private func coordinates(for points: [RoutePoint]) -> [CLLocationCoordinate2D] {
        points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private func coordinate(for coordinate: Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

}

struct RunMapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    let number: Int
    let segment: RideSegment
    let preparedBase: SessionDetailBase?
    let preparedDetail: SessionDetailSegment?
    let preparedTrailDetails: SessionDetailTrailDetails?
    @Query private var trails: [Trail]
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showingFullScreenMap = false
    @State private var ownBase: SessionDetailBase?
    @State private var ownTrailDetails: SessionDetailTrailDetails?
    @State private var isPreparing = false
    @State private var prepareFailed = false

    init(number: Int,
         segment: RideSegment,
         preparedBase: SessionDetailBase? = nil,
         preparedDetail: SessionDetailSegment? = nil,
         preparedTrailDetails: SessionDetailTrailDetails? = nil) {
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

    private var mapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: routePoints)
    }

    private var matchedTrailOverlays: [TrailMapOverlay] {
        guard let activeDetail, let activeTrailDetails else { return [] }
        return activeTrailDetails.overlays
            .filter { $0.segmentID == activeDetail.id }
            .map {
                TrailMapOverlay(id: $0.id,
                                trailID: $0.trailID,
                                name: $0.name,
                                difficulty: $0.difficulty,
                                points: $0.points,
                                score: $0.score)
            }
    }

    private var jumpMarkers: [JumpMarker] {
        guard let jumps = activeDetail?.jumps, !jumps.isEmpty, !routePoints.isEmpty else { return [] }
        var markers: [JumpMarker] = []
        var searchIndex = 0
        for (index, jump) in jumps.enumerated() {
            while searchIndex + 1 < routePoints.count,
                  abs(routePoints[searchIndex + 1].timestamp.timeIntervalSince(jump.takeoffTimestamp))
                    <= abs(routePoints[searchIndex].timestamp.timeIntervalSince(jump.takeoffTimestamp)) {
                searchIndex += 1
            }
            let point = routePoints[searchIndex]
            markers.append(JumpMarker(number: index + 1,
                                      coordinate: CLLocationCoordinate2D(latitude: point.latitude,
                                                                         longitude: point.longitude),
                                      airtime: jump.airtime))
        }
        return markers
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
                VStack(spacing: BermsSpacing.compact) {
                    Image(systemName: "map")
                        .font(.title2)
                    Text("No route")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: BermsSpacing.content) {
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            Map(position: $mapPosition, bounds: mapConfiguration?.bounds,
                                interactionModes: [.pan, .zoom]) {
                                if mapLayerPreferences.showsRidePath {
                                    MapPolyline(coordinates: routePoints.map {
                                        CLLocationCoordinate2D(latitude: $0.latitude,
                                                               longitude: $0.longitude)
                                    })
                                    .stroke(Color.bermsTrail, lineWidth: 4)
                                }

                                if mapLayerPreferences.showsJumps {
                                    ForEach(jumpMarkers) { marker in
                                        Annotation("", coordinate: marker.coordinate) {
                                            JumpMapMarker(number: marker.number,
                                                          airtime: marker.airtime,
                                                          showsAirtime: true)
                                        }
                                    }
                                }

                                if mapLayerPreferences.showsActualTrails {
                                    ForEach(matchedTrailOverlays) { overlay in
                                        trailMapContent(coordinates: overlay.coordinates,
                                                        difficulty: overlay.difficulty,
                                                        lineWidth: TrailMapRendering.lineWidth)
                                        if let coordinate = trailLabelCoordinate(for: overlay.points) {
                                            Annotation("", coordinate: coordinate) {
                                                TrailMapLabel(name: overlay.name,
                                                              difficulty: overlay.difficulty,
                                                              color: overlay.color)
                                            }
                                        }
                                    }
                                }
                            }
                            .mapStyle(.bermsMonochrome)
                            .mapControls { MapCompass() }

                        }
                        VStack(spacing: BermsSpacing.compact) {
                            MapLayersMenu(preferences: mapLayerPreferences,
                                          showsActualTrailsControl: true,
                                          actualTrailsAvailable: !matchedTrailOverlays.isEmpty,
                                          showsJumpsControl: !jumpMarkers.isEmpty)
                            recenterButton
                            Button { showingFullScreenMap = true } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.headline)
                                    .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
                            }
                            .bermsMapControl()
                            .accessibilityLabel("Open full-screen run map")
                        }
                        .padding(BermsSpacing.control)
                    }
                    .frame(minHeight: 380, idealHeight: 460, maxHeight: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    RunStatsCard(segment: segment, detail: activeDetail)

                    TrailSequenceCard(sequence: trailSequence, runNumber: number)
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, BermsSpacing.content, for: .scrollContent)
                .contentMargins(.vertical, BermsSpacing.content, for: .scrollContent)
                .fullScreenCover(isPresented: $showingFullScreenMap) {
                    FullScreenSummaryMap(title: trailSequence, base: activeBase,
                                         trailDetails: activeTrailDetails,
                                         focusedSegmentID: segment.id,
                                         focusedRunNumber: number)
                }
            }
        }
        .navigationTitle(trailSequence)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recenterMap() }
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
        guard preparedDetail == nil, activeDetail == nil, (!isPreparing || force) else { return }
        if force { prepareFailed = false }
        let selectionID = trailCatalogSelection.selectionID
        var runKey: String?
        if let dayID = segment.day?.id {
            runKey = SessionDetailPresentationPreheater.runCacheKey(dayID: dayID,
                                                                     segmentID: segment.id,
                                                                     selectionID: selectionID,
                                                                     trails: trails)
            // A prepared day already covers every run in it, so reuse it before matching again.
            let dayKey = SessionDetailPresentationPreheater.cacheKey(dayID: dayID,
                                                                     selectionID: selectionID,
                                                                     trails: trails)
            if let dayEntry = SessionDetailPresentationCache.shared.entry(for: dayKey),
               dayEntry.base.segmentsByID[segment.id] != nil {
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
            guard let entry = try await SessionDetailPresentationPreheater.prepareRun(
                segmentID: segment.id,
                manualCatalogID: trailCatalogSelection.manualCatalogID,
                container: modelContext.container,
                onBase: { ownBase = $0 }
            ) else { return }
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

    private var recenterButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : BermsMotion.recenter) { recenterMap() }
        } label: {
            Image(systemName: "scope")
                .font(.headline)
                .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
        }
        .bermsMapControl()
        .accessibilityLabel("Recenter map")
    }

    private func recenterMap() {
        mapPosition = mapConfiguration?.initialPosition ?? .automatic
    }
}

struct RunStatsCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let segment: RideSegment
    let detail: SessionDetailSegment?

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.control) {
            Text("Run stats")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: BermsSpacing.content) {
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
        .padding(BermsSpacing.content)
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
            Text(sequence == "Trail not identified"
                 ? "Run \(runNumber) · GPS route only"
                 : "Run \(runNumber)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.bermsMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BermsSpacing.control)
        .background(Color.bermsCard, in: RoundedRectangle(cornerRadius: 16))
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

    init(number: Int,
         segment: RideSegment,
         detail: SessionDetailSegment? = nil,
         trailName: String? = nil,
         isPreparingDetails: Bool = false) {
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
                Text(kind == .run ? BermsFormat.elevation(verticalMeters) + " descent" : BermsFormat.elevation(verticalMeters) + " up")
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
