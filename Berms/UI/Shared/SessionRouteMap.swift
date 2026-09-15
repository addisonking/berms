import MapKit
import SwiftUI

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

    private var segments: [SessionDetailSegment] {
        if let focusedSegmentID {
            return base.mapSegments.filter { $0.id == focusedSegmentID }
        }
        return base.mapSegments.filter {
            $0.kind == .run || (preferences.showsLiftPaths && $0.kind == .lift)
        }
    }

    private var configuration: RouteMapConfiguration? {
        RouteMapConfiguration(points: segments.flatMap(\.routePoints))
    }

    private var jumps: [SessionDetailJumpMarker] {
        guard let focusedSegmentID else { return base.summaryJumpMarkers }
        return base.jumpMarkers.filter { $0.segmentID == focusedSegmentID }
    }

    private var trails: [TrailMapOverlay] {
        (trailDetails?.overlays ?? [])
            .filter { focusedSegmentID == nil || $0.segmentID == focusedSegmentID }
            .map(TrailMapOverlay.init(detail:))
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
                    if let point = segment.routePoints.first {
                        Annotation(
                            "", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                        ) {
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
                ForEach(jumps) { jump in
                    Annotation(
                        "",
                        coordinate: CLLocationCoordinate2D(
                            latitude: jump.coordinate.latitude,
                            longitude: jump.coordinate.longitude)
                    ) {
                        JumpMapMarker(
                            number: jump.number, airtime: jump.airtime,
                            showsAirtime: focusedSegmentID != nil)
                    }
                }
            }
            if preferences.showsActualTrails {
                ForEach(trails) { trail in
                    trailMapContent(coordinates: trail.coordinates, difficulty: trail.difficulty)
                }
                ForEach(trailMapLabelItems(for: trails)) { label in
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
