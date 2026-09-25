import MapKit
import SwiftUI

/// Buckets run starts that sit in the same ~20 m of ground.
private struct RunStartKey: Hashable {
    let latitude: Int
    let longitude: Int

    init(latitude: Double, longitude: Double) {
        self.latitude = Int((latitude * 5_000).rounded())
        self.longitude = Int((longitude * 5_000).rounded())
    }
}

enum SessionMapOverlayPresentation {
    static let zoomedInDistance: CLLocationDistance = 1_500
    static let overviewJumpLimit = 6
    static let notableJumpAirtime: TimeInterval = 0.4

    static func isZoomedIn(
        cameraDistance: CLLocationDistance?,
        initialDistance: CLLocationDistance?
    ) -> Bool {
        (cameraDistance ?? initialDistance ?? .greatestFiniteMagnitude) < zoomedInDistance
    }

    static func showsRunMarkers(isZoomedIn: Bool, focusedSegmentID: UUID?) -> Bool {
        isZoomedIn || focusedSegmentID != nil
    }

    static func overviewJumps(
        _ jumps: [SessionDetailJumpMarker],
        limit: Int = overviewJumpLimit,
        minimumSeparationMeters: Double = 140
    ) -> [SessionDetailJumpMarker] {
        guard limit > 0 else { return [] }
        let candidates =
            jumps
            .filter { $0.airtime >= notableJumpAirtime }
            .sorted {
                if $0.airtime == $1.airtime { return $0.number < $1.number }
                return $0.airtime > $1.airtime
            }
        var selected: [SessionDetailJumpMarker] = []
        for jump in candidates {
            guard
                !selected.contains(where: {
                    $0.coordinate.distance(to: jump.coordinate) < minimumSeparationMeters
                })
            else { continue }
            selected.append(jump)
            if selected.count == limit { break }
        }
        return selected.sorted { $0.number < $1.number }
    }
}

struct SessionRouteMap: View {
    let base: SessionDetailBase
    let trailDetails: SessionDetailTrailDetails?
    var focusedSegmentID: UUID?
    var focusedRunNumber: Int?
    var extendsUnderBars = false
    var onRunSelected: ((UUID) -> Void)?
    var onExpand: (() -> Void)?

    @EnvironmentObject private var preferences: MapLayerPreferences
    @Namespace private var mapScope
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedRunID: UUID?
    @State private var cameraDistance: CLLocationDistance?
    @State private var visibleRegion: MKCoordinateRegion?

    private static let zoomedOutLabelLimit = 3

    private var segments: [SessionDetailSegment] {
        if let focusedSegmentID {
            return base.mapSegments.filter { $0.id == focusedSegmentID }
        }
        return base.mapSegments.filter {
            $0.kind == .run || (preferences.showsLiftPaths && $0.kind == .lift)
        }
    }

    /// One resort means the map is bounded to its trails. A trip across resorts
    /// falls back to the session extent so the camera still cannot wander.
    private var resortBoundary: ResortBoundary? {
        guard let first = segments.first?.resortID,
            segments.allSatisfy({ $0.resortID == first })
        else { return nil }
        return TrailCatalogRegistry.resort(withID: first)?.boundary
    }

    private var configuration: RouteMapConfiguration? {
        RouteMapConfiguration(
            points: segments.flatMap(\.routePoints),
            boundary: resortBoundary)
    }

    private var jumps: [SessionDetailJumpMarker] {
        guard let focusedSegmentID else { return base.summaryJumpMarkers }
        return base.jumpMarkers.filter { $0.segmentID == focusedSegmentID }
    }

    private var isZoomedIn: Bool {
        SessionMapOverlayPresentation.isZoomedIn(
            cameraDistance: cameraDistance,
            initialDistance: configuration?.initialDistance)
    }

    private var presentationDistance: CLLocationDistance {
        cameraDistance ?? configuration?.initialDistance ?? .greatestFiniteMagnitude
    }

    private var showsRunMarkers: Bool {
        SessionMapOverlayPresentation.showsRunMarkers(
            isZoomedIn: isZoomedIn,
            focusedSegmentID: focusedSegmentID)
    }

    /// Zoomed out, only jumps worth looking at; every marker once the camera is
    /// close enough for them to be readable.
    private var visibleJumps: [SessionDetailJumpMarker] {
        guard !isZoomedIn else { return jumps }
        return SessionMapOverlayPresentation.overviewJumps(
            jumps,
            minimumSeparationMeters: max(100, presentationDistance * 0.08))
    }

    private var trails: [TrailMapOverlay] {
        (trailDetails?.overlays ?? [])
            .filter { focusedSegmentID == nil || $0.segmentID == focusedSegmentID }
            .map(TrailMapOverlay.init(detail:))
    }

    private var trailLabels: [TrailMapLabelItem] {
        let center = visibleRegion?.center ?? configuration?.framingRegion.center
        let mapCenter = center.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
        let labels = trailMapLabelItems(
            for: trails,
            limit: isZoomedIn ? TrailMapRendering.labelLimit : Self.zoomedOutLabelLimit,
            minimumSeparationMeters: max(120, presentationDistance * 0.3),
            prioritizingAround: mapCenter,
            avoidingCoordinates: preferences.showsJumps ? visibleJumps.map(\.coordinate) : [],
            avoidanceDistanceMeters: max(70, presentationDistance * 0.08),
            within: visibleRegion ?? configuration?.framingRegion,
            edgeMarginFraction: 0.22)
        return labels
    }

    /// Runs often start from the same lift top, so exact start markers stack and
    /// only the top one stays visible. Fan co-located starts out in a small ring.
    private var runMarkerOffsets: [UUID: CGSize] {
        var groups: [RunStartKey: [UUID]] = [:]
        for segment in segments where segment.kind == .run {
            guard let point = segment.routePoints.first else { continue }
            groups[RunStartKey(latitude: point.latitude, longitude: point.longitude), default: []]
                .append(segment.id)
        }

        var offsets: [UUID: CGSize] = [:]
        for ids in groups.values where ids.count > 1 {
            let radius = min(92, 24 + Double(ids.count) * 5)
            for (index, id) in ids.enumerated() {
                let angle = (2 * Double.pi / Double(ids.count)) * Double(index) - Double.pi / 2
                offsets[id] = CGSize(width: radius * cos(angle), height: radius * sin(angle))
            }
        }
        return offsets
    }

    var body: some View {
        Map(
            position: $position, bounds: configuration?.bounds,
            interactionModes: [.pan, .zoom, .rotate], selection: $selectedRunID, scope: mapScope
        ) {
            if preferences.showsRidePath {
                ForEach(Array(segments.filter { $0.kind == .run }.enumerated()), id: \.element.id) { index, segment in
                    if segment.routePoints.count > 1 {
                        MapPolyline(coordinates: trailCoordinates(for: segment.routePoints))
                            .stroke(
                                focusedSegmentID == nil
                                    ? Color.gray.opacity(
                                        RideMapPresentation.summaryRunOpacity(index: index, count: base.runs.count))
                                    : Color.bermsTrail, lineWidth: 4
                            )
                            .tag(segment.id)
                    }
                    if showsRunMarkers, let point = segment.routePoints.first {
                        Annotation(
                            "", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                        ) {
                            Group {
                                if let onRunSelected {
                                    Button {
                                        onRunSelected(segment.id)
                                    } label: {
                                        RunNumberMarker(number: focusedRunNumber ?? index + 1, isSelected: false)
                                            .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
                                            .contentShape(.circle)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Opens this run")
                                } else {
                                    RunNumberMarker(
                                        number: focusedRunNumber ?? index + 1,
                                        isSelected: focusedSegmentID == segment.id)
                                }
                            }
                            .offset(runMarkerOffsets[segment.id] ?? .zero)
                        }
                    }
                }
            }
            if preferences.showsLiftPaths {
                ForEach(segments.filter { $0.kind == .lift }) { segment in
                    MapPolyline(coordinates: trailCoordinates(for: segment.routePoints))
                        .stroke(
                            Color.bermsLift,
                            style: StrokeStyle(
                                lineWidth: 2.25, lineCap: .round, lineJoin: .round, dash: [5, 4]
                            ))
                }
            }
            if preferences.showsJumps {
                ForEach(visibleJumps) { jump in
                    Annotation(
                        "",
                        coordinate: CLLocationCoordinate2D(
                            latitude: jump.coordinate.latitude,
                            longitude: jump.coordinate.longitude)
                    ) {
                        JumpMapMarker(number: jump.number, airtime: jump.airtime)
                    }
                }
            }
            if preferences.showsActualTrails {
                ForEach(trails) { trail in
                    trailMapContent(coordinates: trail.coordinates, difficulty: trail.difficulty)
                }
                ForEach(trailLabels) { label in
                    Annotation("", coordinate: label.coordinate) {
                        TrailMapLabel(name: label.name, difficulty: label.difficulty, color: label.color)
                    }
                }
            }
        }
        .mapStyle(.bermsMonochrome)
        .mapControls { MapScaleView() }
        .ignoresSafeArea(.container, edges: extendsUnderBars ? .all : [])
        .overlay(alignment: .topTrailing) {
            MapControlStack {
                MapLayersMenu(
                    preferences: preferences,
                    actualTrailsAvailable: !trails.isEmpty,
                    showsJumpsControl: !jumps.isEmpty,
                    showsLiftPathsControl: focusedSegmentID == nil,
                    liftPathsAvailable: base.mapSegments.contains { $0.kind == .lift })
                MapRecenterButton { recenter() }
                if let onExpand {
                    MapActionButton(
                        title: "Open full-screen map", systemImage: "arrow.up.left.and.arrow.down.right",
                        action: onExpand)
                }
            }
            .padding(BermsSpacing.control)
        }
        .overlay(alignment: .topLeading) {
            MapCompass(scope: mapScope)
                .padding(BermsSpacing.control)
        }
        .mapScope(mapScope)
        .onMapCameraChange(frequency: .onEnd) { context in
            cameraDistance = context.camera.distance
            visibleRegion = context.region
        }
        .onAppear { recenter() }
        .onChange(of: selectedRunID) { _, id in
            guard let id else { return }
            onRunSelected?(id)
            selectedRunID = nil
        }
    }

    private func recenter() {
        position = configuration?.initialPosition ?? .automatic
    }
}
