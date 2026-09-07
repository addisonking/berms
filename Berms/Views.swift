import MapKit
import SwiftData
import SwiftUI
import UIKit

@MainActor
final class MapLayerPreferences: ObservableObject {
    private enum Key {
        static let ridePath = "berms.mapLayers.ridePath"
        static let actualTrails = "berms.mapLayers.actualTrails"
        static let jumps = "berms.mapLayers.jumps"
    }

    private let defaults: UserDefaults

    @Published var showsRidePath: Bool {
        didSet { defaults.set(showsRidePath, forKey: Key.ridePath) }
    }

    @Published var showsActualTrails: Bool {
        didSet { defaults.set(showsActualTrails, forKey: Key.actualTrails) }
    }

    @Published var showsJumps: Bool {
        didSet { defaults.set(showsJumps, forKey: Key.jumps) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsRidePath = defaults.object(forKey: Key.ridePath) as? Bool ?? true
        showsActualTrails = defaults.object(forKey: Key.actualTrails) as? Bool ?? true
        showsJumps = defaults.object(forKey: Key.jumps) as? Bool ?? true
    }
}

private struct MapLayersMenu: View {
    @ObservedObject var preferences: MapLayerPreferences
    var showsRidePathControl = true
    var showsActualTrailsControl = true
    var showsJumpsControl = true
    var hasActualTrails = true

    var body: some View {
        Menu {
            Toggle("Ride path", isOn: $preferences.showsRidePath)
                .disabled(!showsRidePathControl)
            Toggle("Actual trails", isOn: $preferences.showsActualTrails)
                .disabled(!showsActualTrailsControl || !hasActualTrails)
            Toggle("Jumps", isOn: $preferences.showsJumps)
                .disabled(!showsJumpsControl)
        } label: {
            Label("Layers", systemImage: "square.3.layers.3d")
                .labelStyle(.iconOnly)
                .font(.headline)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(.black.opacity(0.7))
        .foregroundStyle(.white)
        .accessibilityLabel("Map layers")
    }
}

private struct TrailMapOverlay: Identifiable {
    let id: String
    let trailID: UUID
    let name: String
    let difficulty: TrailDifficulty
    let points: [RoutePoint]
    let score: Double

    var color: Color {
        .bermsDifficulty(difficulty)
    }

    var coordinates: [CLLocationCoordinate2D] {
        points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }
}

@MainActor
private func trailOverlays(for segment: RideSegment, trails: [Trail]) -> [TrailMapOverlay] {
    guard segment.kind == .run else { return [] }
    return TrailRouteMatchCache.shared.matchingSections(for: segment, trails: trails).compactMap { section in
        guard let trail = trails.first(where: { $0.id == section.trailID }) else { return nil }
        let points = TrailRouteSlice.slice(trail.points, progress: section.trailProgress)
        guard points.count > 1 else { return nil }
        return TrailMapOverlay(id: section.id, trailID: trail.id, name: trail.name,
                               difficulty: trail.difficulty, points: points, score: section.score)
    }
}

private func trailCoordinates(for trail: Trail) -> [CLLocationCoordinate2D] {
    trailCoordinates(for: trail.points)
}

private func trailCoordinates(for points: [RoutePoint]) -> [CLLocationCoordinate2D] {
    points.map {
        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
    }
}

private func trailDistance(from coordinate: Coordinate, to points: [RoutePoint]) -> Double {
    guard points.count >= 2 else {
        guard let point = points.first else { return .greatestFiniteMagnitude }
        let start = Coordinate(latitude: point.latitude, longitude: point.longitude)
        return start.distance(to: coordinate)
    }

    let latitudeScale = max(0.1, cos(coordinate.latitude * .pi / 180))
    func project(_ value: Coordinate) -> (x: Double, y: Double) {
        ((value.longitude - coordinate.longitude) * 111_000 * latitudeScale,
         (value.latitude - coordinate.latitude) * 111_000)
    }

    let origin = project(coordinate)
    return zip(points, points.dropFirst()).map { start, end in
        let a = project(Coordinate(latitude: start.latitude, longitude: start.longitude))
        let b = project(Coordinate(latitude: end.latitude, longitude: end.longitude))
        let dx = b.x - a.x
        let dy = b.y - a.y
        let denominator = dx * dx + dy * dy
        let fraction = denominator > 0
            ? max(0, min(1, ((origin.x - a.x) * dx + (origin.y - a.y) * dy) / denominator))
            : 0
        return hypot(origin.x - (a.x + dx * fraction), origin.y - (a.y + dy * fraction))
    }.min() ?? .greatestFiniteMagnitude
}

@MainActor
private func trailPathKeyline(for coordinates: [CLLocationCoordinate2D]) -> some MapContent {
    MapPolyline(coordinates: coordinates)
        .stroke(Color(uiColor: .systemBackground).opacity(0.85), lineWidth: 5)
}

@MainActor
private func trailPath(for overlay: TrailMapOverlay) -> some MapContent {
    MapPolyline(coordinates: overlay.coordinates)
        .stroke(overlay.color.opacity(0.9), style: StrokeStyle(
            lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [7, 5]
        ))
}

struct RootView: View {
    private enum Tab: Hashable {
        case track
        case days
#if DEBUG
        case map
#endif
    }

    @ObservedObject var recorder: RideRecorder
#if DEBUG
    @ObservedObject private var trailMapper = TrailMapper.shared
#endif
    @StateObject private var mapLayerPreferences = MapLayerPreferences()
    @State private var selectedTab: Tab = .track
    @State private var pendingDayID: UUID?

    var body: some View {
        TabView(selection: $selectedTab) {
            TrackView(recorder: recorder) { day in
                pendingDayID = day.id
                selectedTab = .days
            }
            .tabItem { Label("Track", systemImage: "location.fill") }
            .tag(Tab.track)
            DaysView(pendingDayID: $pendingDayID)
                .tabItem { Label("Days", systemImage: "calendar") }
                .tag(Tab.days)
#if DEBUG
            TrailMappingView(mapper: trailMapper, recorder: recorder)
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)
#endif
        }
        .tint(.bermsTrail)
        .environmentObject(mapLayerPreferences)
        .onAppear { recorder.resumeIfNeeded() }
        .onOpenURL { url in
            guard url.scheme == "berms" else { return }
            selectedTab = .track
            recorder.handleLiveActivityOpen()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var recorder: RideRecorder
    @Environment(\.dismiss) private var dismiss

    private var sensitivityBinding: Binding<JumpSensitivity> {
        Binding(
            get: { recorder.jumpSensitivity },
            set: { recorder.setJumpSensitivity($0) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Jump detection") {
                    Picker("Sensitivity", selection: sensitivityBinding) {
                        ForEach(JumpSensitivity.allCases) { sensitivity in
                            VStack(alignment: .leading) {
                                Text(sensitivity.title)
                                Text(sensitivity.detail)
                                    .font(.caption)
                            }
                            .tag(sensitivity)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct TrackView: View {
    @ObservedObject var recorder: RideRecorder
    @Query private var trails: [Trail]
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var isFollowing = true
    @State private var showingStopConfirmation = false
    @State private var showingSettings = false
    let onDayFinished: (RideDay) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                BermsBackground()
                if recorder.isRecording {
                    recordingContent
                } else {
                    readyContent
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(alignment: .center) {
                    Text("Berms")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 16)
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title2.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settingsButton")
                }
                .foregroundStyle(Color.bermsTrail)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.bermsInk)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(recorder: recorder)
        }
        .alert("Finish session?", isPresented: $showingStopConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Finish", role: .destructive) {
                guard let finishedDay = recorder.stop() else { return }
                onDayFinished(finishedDay)
            }
        }
        .alert("Unfinished ride", isPresented: Binding(
            get: { recorder.needsRecoveryPrompt },
            set: { _ in }
        )) {
            Button("Resume") { recorder.resumePendingSession() }
            Button("Discard", role: .destructive) { recorder.discardPendingSession() }
        } message: {
            Text("Berms found a ride that was not finished. Resume it or discard the saved data.")
        }
        .alert("Recording issue", isPresented: Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
        .onAppear { centerOnLastSampleIfNeeded() }
        .onChange(of: recorder.lastSample?.timestamp) { _, _ in
            if isFollowing {
                centerOnLastSampleIfNeeded()
            }
        }
        .onChange(of: recorder.isRecording) { _, recording in
            if recording {
                isFollowing = true
                mapPosition = .automatic
                centerOnLastSampleIfNeeded()
            }
        }
    }

    private var readyContent: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(Color.bermsTrail)
            startButton
            if recorder.isRestoring {
                ProgressView("Restoring…")
            }
            if recorder.locationAuthorization == .denied || recorder.locationAuthorization == .restricted {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.bermsMuted)
            }
            Spacer()
        }
        .padding(24)
    }

    private var recordingContent: some View {
        VStack(spacing: 0) {
            liveMap
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal, 10)
                .padding(.top, 8)

            VStack(spacing: 14) {
                HStack {
                    HStack(spacing: 8) {
                        Circle().fill(Color.bermsTrail).frame(width: 9, height: 9)
                        Text(recorder.isPaused ? "PAUSED" : "REC")
                            .font(.caption.weight(.heavy))
                            .tracking(1.2)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(BermsFormat.duration(recorder.elapsed(at: timeline.date)))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .monospacedDigit()
                    }
                }

                HStack(spacing: 10) {
                    MetricTile(label: "Runs", value: "\(recorder.completedRunCount)", tint: .bermsTrail)
                    MetricTile(label: "Jumps", value: "\(recorder.activeJumpCount)", tint: .bermsTrail)
                    MetricTile(label: "Mode", value: recorder.isPaused ? "Paused" : recorder.phase.title,
                               tint: recorder.activeSegmentKind == .lift ? .bermsLift : .bermsTrail)
                }

                HStack(spacing: 10) {
                    MetricTile(label: "Speed", value: BermsFormat.speed(recorder.currentSpeed))
                    MetricTile(label: "Altitude", value: BermsFormat.elevation(recorder.currentAltitude))
                }

                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Label(gpsStatusText(at: timeline.date), systemImage: "location.fill")
                            .font(.caption)
                            .foregroundStyle(recorder.locationAuthorization == .denied
                                             || recorder.locationAuthorization == .restricted
                                             ? .red : Color.bermsMuted)
                    }
                    Spacer()
                    if !recorder.motionAvailable {
                        Text("MOTION OFF")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.bermsMuted)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        if recorder.isPaused {
                            recorder.resume()
                        } else {
                            recorder.pause()
                        }
                    } label: {
                        Label(recorder.isPaused ? "Resume" : "Pause",
                              systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                            .foregroundStyle(Color.bermsOnAccent)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.bermsTrail)

                    Button {
                        showingStopConfirmation = true
                    } label: {
                        Label("Finish", systemImage: "stop.fill")
                            .foregroundStyle(Color.bermsOnAccent)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.bermsTrail)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
            .padding(10)
        }
    }

    private func gpsStatusText(at date: Date) -> String {
        if recorder.isPaused { return "GPS PAUSED" }
        switch recorder.locationAuthorization {
        case .denied, .restricted:
            return "GPS OFF — CHECK SETTINGS"
        case .notDetermined:
            return "ALLOW LOCATION TO RECORD"
        default:
            guard let sample = recorder.lastSample else { return "WAITING FOR GPS" }
            return date.timeIntervalSince(sample.timestamp) > 15 ? "GPS SIGNAL LOST" : "GPS ON"
        }
    }

    private var startButton: some View {
        Button {
            recorder.start()
        } label: {
            Label("Start", systemImage: "play.fill")
                .foregroundStyle(Color.bermsOnAccent)
                .font(.headline)
                .frame(maxWidth: 260)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.bermsTrail)
        .controlSize(.large)
        .disabled(recorder.locationAuthorization == .denied
                  || recorder.locationAuthorization == .restricted)
    }

    private var liveMap: some View {
        ZStack(alignment: .topTrailing) {
            if recorder.lastSample == nil {
                VStack(spacing: 10) {
                    Image(systemName: "location.slash")
                        .font(.title2)
                    Text("Waiting for GPS")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.35))
                .foregroundStyle(.white)
            } else {
                Map(position: $mapPosition) {
                    UserAnnotation()
                    if mapLayerPreferences.showsActualTrails {
                        ForEach(nearbyTrails) { trail in
                            trailPathKeyline(for: trailCoordinates(for: trail))
                            MapPolyline(coordinates: trailCoordinates(for: trail))
                                .stroke(Color.bermsDifficulty(trail.difficulty).opacity(0.55), style: StrokeStyle(
                                    lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [7, 5]
                                ))
                        }
                    }
                    if mapLayerPreferences.showsRidePath {
                        ForEach(recorder.activeDay?.segments ?? []) { segment in
                            MapPolyline(coordinates: segment.points.map {
                                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                            })
                            .stroke(segment.kind == .run ? Color.bermsTrail : Color.bermsLift, lineWidth: 4)
                        }
                        if !recorder.currentMapPoints.isEmpty {
                            MapPolyline(coordinates: recorder.currentMapPoints.map {
                                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                            })
                            .stroke(recorder.activeSegmentKind == .lift ? Color.bermsLift : Color.bermsTrail, lineWidth: 5)
                        }
                    }
                }
                .mapStyle(.standard)
                .saturation(mapLayerPreferences.showsActualTrails ? 1 : 0)
                .mapControls {
                    MapCompass()
                }
                .onChange(of: mapPosition) { _, position in
                    if position.positionedByUser {
                        isFollowing = false
                    }
                }

                MapLayersMenu(preferences: mapLayerPreferences,
                              showsJumpsControl: false,
                              hasActualTrails: !nearbyTrails.isEmpty)
                    .padding(.top, 12)
                    .padding(.trailing, 12)

                Button {
                    isFollowing = true
                    centerOnLastSampleIfNeeded()
                } label: {
                    Image(systemName: isFollowing ? "location.fill" : "location")
                        .font(.headline)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black.opacity(0.65))
                .foregroundStyle(.white)
                .padding(12)
                .accessibilityLabel(isFollowing ? "Following GPS" : "Center GPS")
            }
        }
    }

    private func centerOnLastSampleIfNeeded() {
        guard let coordinate = recorder.lastSample?.coordinate else { return }
        mapPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
            latitudinalMeters: 900,
            longitudinalMeters: 900
        ))
    }

    private var nearbyTrails: [Trail] {
        guard let coordinate = recorder.lastSample?.coordinate else { return [] }
        return trails.filter { trail in
            !trail.points.isEmpty && trailDistance(from: coordinate, to: trail.points) <= 750
        }
    }
}

#if DEBUG
struct TrailMappingView: View {
    @Query(sort: \Trail.updatedAt, order: .reverse) private var trails: [Trail]
    @ObservedObject var mapper: TrailMapper
    @ObservedObject var recorder: RideRecorder
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showingStartSheet = false
    @State private var showingDiscardConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                BermsBackground()
                if mapper.isRecording {
                    mappingContent
                } else {
                    libraryContent
                }
            }
            .navigationTitle("Dev Map")
        }
        .sheet(isPresented: $showingStartSheet) {
            TrailStartSheet(trails: trails, mapper: mapper)
                .presentationDetents([.medium, .large])
        }
        .alert("Mapping issue", isPresented: Binding(
            get: { mapper.errorMessage != nil },
            set: { if !$0 { mapper.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { mapper.errorMessage = nil }
        } message: {
            Text(mapper.errorMessage ?? "")
        }
        .confirmationDialog("Discard this segment?", isPresented: $showingDiscardConfirmation) {
            Button("Discard", role: .destructive) { mapper.discard() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: mapper.isRecording) { _, isRecording in
            if isRecording {
                recenterActiveMap()
            }
        }
    }

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                authoredMap
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 22))

                Button {
                    showingStartSheet = true
                } label: {
                    Label("Start trail segment", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.bermsTrail, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(Color.bermsOnAccent)

                Text("Authored trails")
                    .font(.title3.weight(.bold))
                if trails.isEmpty {
                    Text("Map your first trail from the top, then save it at the bottom.")
                        .foregroundStyle(Color.bermsMuted)
                } else {
                    ForEach(trails) { trail in
                        Button {
                            _ = mapper.start(existingTrail: trail, name: trail.name, difficulty: trail.difficulty)
                        } label: {
                            TrailLibraryRow(trail: trail)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    private var mappingContent: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Map(position: $mapPosition, bounds: activeMapConfiguration?.bounds,
                    interactionModes: [.pan, .zoom]) {
                    if mapLayerPreferences.showsActualTrails,
                       mapper.activeTrailPoints.count > 1 {
                        let coordinates = trailCoordinates(for: mapper.activeTrailPoints)
                        trailPathKeyline(for: coordinates)
                        MapPolyline(coordinates: coordinates)
                            .stroke(Color.bermsDifficulty(mapper.activeDifficulty).opacity(0.55), style: StrokeStyle(
                                lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [7, 5]
                            ))
                    }
                    if mapLayerPreferences.showsRidePath, mapper.activeRoutePoints.count > 1 {
                        MapPolyline(coordinates: mapper.activeRoutePoints.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        })
                        .stroke(Color.bermsTrail, lineWidth: 5)
                    }
                }
                .mapStyle(.standard)
                .saturation(mapLayerPreferences.showsActualTrails ? 1 : 0)
                VStack(spacing: 8) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsJumpsControl: false,
                                  hasActualTrails: mapper.activeTrailPoints.count > 1)
                    recenterButton(action: recenterActiveMap)
                }
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))

            VStack(alignment: .leading, spacing: 8) {
                Text(mapper.activeTrailName)
                    .font(.title3.weight(.bold))
                Text("\(mapper.activeDifficulty.title) · \(mapper.activeStyle.title) · \(mapper.activePoints.count) GPS points")
                    .font(.subheadline)
                    .foregroundStyle(Color.bermsMuted)
                Text(mapper.lastSample == nil ? "Waiting for GPS…" : "Recording from the top — save at the bottom")
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    showingDiscardConfirmation = true
                } label: {
                    Label("Discard", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.bermsTrail)

                Button {
                    _ = mapper.save()
                } label: {
                    if mapper.isSaving {
                        ProgressView()
                            .tint(.bermsOnAccent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Save segment", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.bermsTrail)
                .foregroundStyle(Color.bermsOnAccent)
                .disabled(mapper.isSaving)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var authoredMap: some View {
        if trails.flatMap(\.points).isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "map")
                    .font(.title2)
                Text("No authored trails yet")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bermsCard)
        } else {
            ZStack(alignment: .topTrailing) {
                Map(position: $mapPosition, bounds: authoredMapConfiguration?.bounds,
                    interactionModes: [.pan, .zoom]) {
                    if mapLayerPreferences.showsActualTrails {
                        ForEach(trails) { trail in
                            if trail.points.count > 1 {
                                let coordinates = trailCoordinates(for: trail)
                                trailPathKeyline(for: coordinates)
                                MapPolyline(coordinates: coordinates)
                                    .stroke(color(for: trail.difficulty).opacity(0.9), style: StrokeStyle(
                                        lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [7, 5]
                                    ))
                            }
                            if let point = labelPoint(for: trail) {
                                // Keep the custom label as the only visible trail title.
                                // A non-empty Annotation title makes MapKit render a second
                                // subtitle below the custom content.
                                Annotation("", coordinate: CLLocationCoordinate2D(
                                    latitude: point.latitude, longitude: point.longitude
                                )) {
                                    TrailMapLabel(name: trail.name,
                                                  difficulty: trail.difficulty,
                                                  color: color(for: trail.difficulty))
                                }
                            }
                        }
                    }
                }
                .mapStyle(.standard)
                VStack(spacing: 8) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsRidePathControl: false,
                                  showsJumpsControl: false,
                                  hasActualTrails: !trails.isEmpty)
                    recenterButton(action: recenterAuthoredMap)
                }
                .padding(12)
            }
        }
    }

    private var activeMapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: mapper.activeRoutePoints + mapper.activeTrailPoints)
    }

    private var authoredMapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: trails.flatMap(\.points))
    }

    private func labelPoint(for trail: Trail) -> RoutePoint? {
        let points = trail.points
        guard !points.isEmpty else { return nil }
        return points[points.count / 2]
    }

    private func color(for difficulty: TrailDifficulty) -> Color {
        .bermsDifficulty(difficulty)
    }

    private func recenterAuthoredMap() {
        mapPosition = authoredMapConfiguration?.initialPosition ?? .automatic
    }

    private func recenterActiveMap() {
        mapPosition = activeMapConfiguration?.initialPosition ?? .automatic
    }

    private func recenterButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "scope")
                .font(.headline)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(.black.opacity(0.7))
        .foregroundStyle(.white)
        .accessibilityLabel("Recenter map")
    }
}

private struct TrailLibraryRow: View {
    let trail: Trail

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(trailColor)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(trail.name)
                    .font(.headline)
                Text("\(trail.resort) · \(trail.difficulty.title) · \(trail.style.title) · \(trail.passCount) pass\(trail.passCount == 1 ? "" : "es") · \(BermsFormat.distance(trailDistance))")
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
            }
            Spacer()
            Image(systemName: "plus.circle")
                .foregroundStyle(Color.bermsTrail)
        }
        .padding(12)
        .background(Color.bermsCard, in: RoundedRectangle(cornerRadius: 16))
    }

    private var trailColor: Color {
        .bermsDifficulty(trail.difficulty)
    }

    private var trailDistance: Double {
        zip(trail.points, trail.points.dropFirst()).reduce(0) { total, pair in
            let start = Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return total + start.distance(to: end)
        }
    }
}

private struct TrailStartSheet: View {
    let trails: [Trail]
    @ObservedObject var mapper: TrailMapper
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTrailID: UUID?
    @State private var name = ""
    @State private var difficulty: TrailDifficulty = .blue
    @State private var style: TrailStyle = .freeRide
    @State private var resortOverride = ""

    private var selectedTrail: Trail? {
        trails.first { $0.id == selectedTrailID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    Picker("Trail", selection: $selectedTrailID) {
                        Text("New trail").tag(nil as UUID?)
                        ForEach(trails) { trail in
                            Text("\(trail.name) (\(trail.passCount) pass\(trail.passCount == 1 ? "" : "es"))")
                                .tag(trail.id as UUID?)
                        }
                    }
                    if selectedTrail == nil {
                        TextField("Trail name", text: $name)
                        Picker("Difficulty", selection: $difficulty) {
                            ForEach(TrailDifficulty.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        Picker("Style", selection: $style) {
                            ForEach(TrailStyle.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        TextField("Resort override (optional)", text: $resortOverride)
                    } else if let selectedTrail {
                        LabeledContent("Difficulty", value: selectedTrail.difficulty.title)
                        LabeledContent("Style", value: selectedTrail.style.title)
                    }
                }

                Section {
                    Text("Start at the top. Berms will identify the resort from your location when you save. You can override it if needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Start segment") {
                        let trail = selectedTrail
                        let started = mapper.start(existingTrail: trail,
                                                   name: name,
                                                   difficulty: difficulty,
                                                   style: style,
                                                   resortOverride: resortOverride)
                        if started { dismiss() }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.bermsTrail, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Color.bermsOnAccent)
                    .disabled(selectedTrail == nil && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Map a trail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
#endif

struct RunMapDestination: Hashable {
    let dayID: UUID
    let runID: UUID
    let number: Int
}

struct DaysView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RideDay.startedAt, order: .reverse) private var days: [RideDay]
    @Binding private var pendingDayID: UUID?
    @State private var dayToDelete: RideDay?
    @State private var navigationPath = NavigationPath()

    init(pendingDayID: Binding<UUID?> = .constant(nil)) {
        self._pendingDayID = pendingDayID
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                BermsBackground()
                if days.isEmpty {
                    ContentUnavailableView("No days", systemImage: "mountain.2")
                } else {
                    List {
                        ForEach(days) { day in
                            NavigationLink {
                                DayDetailView(day: day) { destination in
                                    navigationPath.append(destination)
                                }
                            } label: {
                                DayRow(day: day)
                            }
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if day.isFinished {
                                    Button {
                                        dayToDelete = day
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Days")
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
                    RunMapView(number: destination.number, segment: run)
                }
            }
            .onAppear { openPendingDayIfNeeded() }
            .onChange(of: pendingDayID) { _, _ in openPendingDayIfNeeded() }
            .onChange(of: days.map(\.id)) { _, _ in openPendingDayIfNeeded() }
        }
        .alert("Delete day?", isPresented: Binding(
            get: { dayToDelete != nil },
            set: { if !$0 { dayToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { dayToDelete = nil }
            Button("Delete day", role: .destructive) {
                if let dayToDelete, dayToDelete.isFinished {
                    let diagnosticURL = RideRecorder.debugLogURL(for: dayToDelete.id)
                    modelContext.delete(dayToDelete)
                    try? modelContext.save()
                    try? FileManager.default.removeItem(at: diagnosticURL)
                }
                dayToDelete = nil
            }
        }
    }

    private func openPendingDayIfNeeded() {
        guard let pendingDayID,
              days.contains(where: { $0.id == pendingDayID }) else { return }
        navigationPath = NavigationPath([pendingDayID])
        self.pendingDayID = nil
    }
}

struct DayRow: View {
    let day: RideDay

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(day.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text("\(day.segments.filter { $0.kind == .run }.count) runs  ·  \(BermsFormat.distance(day.distanceMeters))")
                    .font(.subheadline)
                    .foregroundStyle(Color.bermsMuted)
            }
            Spacer()
            Text(BermsFormat.duration(day.duration))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.bermsTrail)
        }
        .padding(.vertical, 8)
    }
}

struct DayDetailView: View {
    let day: RideDay
    let onRunSelected: (RunMapDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var trails: [Trail]
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedSegmentID: UUID?
    @State private var showingFullScreenMap = false
    @State private var showingDeleteConfirmation = false

    init(day: RideDay, onRunSelected: @escaping (RunMapDestination) -> Void = { _ in }) {
        self.day = day
        self.onRunSelected = onRunSelected
    }

    private var runs: [RideSegment] {
        day.segments.filter { $0.kind == .run }.sorted { $0.startedAt < $1.startedAt }
    }

    var body: some View {
        ZStack {
            BermsBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summary
                    dayMap
                    Text("Runs")
                        .font(.title3.weight(.bold))
                    if runs.isEmpty {
                        Text("No runs")
                            .foregroundStyle(Color.bermsMuted)
                    } else {
                        ForEach(Array(runs.enumerated()), id: \.element.id) { index, segment in
                            NavigationLink {
                                RunMapView(number: index + 1, segment: segment)
                            } label: {
                                SegmentRow(number: index + 1, segment: segment,
                                           trailName: matchedTrailNames(for: segment),
                                           isLastRun: index == runs.count - 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(day.startedAt.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let debugURL = RideRecorder.shared.debugLogURL(for: day) {
                        ShareLink(item: debugURL) {
                            Label("Export diagnostics", systemImage: "arrow.up.doc")
                        }
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
                let diagnosticURL = RideRecorder.debugLogURL(for: day.id)
                modelContext.delete(day)
                try? modelContext.save()
                try? FileManager.default.removeItem(at: diagnosticURL)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the day and all of its runs, lifts, and map data.")
        }
        .onChange(of: selectedSegmentID) { _, segmentID in
            guard let segmentID,
                  let number = runs.firstIndex(where: { $0.id == segmentID }) else { return }
            onRunSelected(RunMapDestination(dayID: day.id, runID: segmentID, number: number + 1))
            selectedSegmentID = nil
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Today’s Stats")
                .font(.title2.weight(.bold))

            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    SummaryStat(label: "Time", value: BermsFormat.duration(day.duration), tint: .primary)
                    SummaryStat(label: "Runs", value: "\(runs.count)", tint: .primary)
                }
                HStack(spacing: 16) {
                    SummaryStat(label: "Descent", value: BermsFormat.elevation(day.descentMeters), tint: .primary)
                    SummaryStat(label: "Distance", value: BermsFormat.distance(day.distanceMeters))
                }
                HStack(spacing: 16) {
                    SummaryStat(label: "Riding time", value: BermsFormat.duration(day.activeSeconds))
                    SummaryStat(label: "Lift time", value: BermsFormat.duration(day.liftSeconds))
                }
                HStack(spacing: 16) {
                    SummaryStat(label: "Top speed", value: BermsFormat.speed(day.maximumSpeedMetersPerSecond))
                    SummaryStat(label: "Jumps", value: "\(day.jumpCount)", tint: .primary)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    @ViewBuilder
    private var dayMap: some View {
        if day.segments.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "map")
                    .font(.title2)
                Text("No route")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(Color.bermsCard, in: RoundedRectangle(cornerRadius: 22))
        } else {
            ZStack(alignment: .topTrailing) {
                Map(position: $mapPosition, bounds: mapConfiguration?.bounds,
                    interactionModes: [.pan, .zoom], selection: $selectedSegmentID) {
                    if mapLayerPreferences.showsActualTrails {
                        ForEach(day.segments) { segment in
                            ForEach(trailOverlays(for: segment, trails: trails)) { overlay in
                                trailPathKeyline(for: overlay.coordinates)
                                trailPath(for: overlay)
                            }
                        }
                    }
                    if mapLayerPreferences.showsRidePath {
                        ForEach(day.segments) { segment in
                            MapPolyline(coordinates: coordinates(for: segment))
                                .stroke(segment.kind == .run ? Color.bermsTrail : Color.bermsLift, lineWidth: 4)
                                .tag(segment.id)
                        }
                    }
                    if mapLayerPreferences.showsJumps {
                        ForEach(summaryMapJumps(for: day.segments)) { marker in
                            Annotation("", coordinate: marker.coordinate) {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                                    .accessibilityLabel("\(marker.label), \(BermsFormat.airtime(marker.airtime))")
                            }
                        }
                    }
                }
                .mapStyle(.standard)
                .saturation(mapLayerPreferences.showsActualTrails ? 1 : 0)
                .mapControls {
                    MapCompass()
                }
                VStack(spacing: 8) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  hasActualTrails: hasMatchedTrailOverlays)
                    recenterButton
                    Button { showingFullScreenMap = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.headline)
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Open full-screen ride map")
                }
                .padding(12)
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .onAppear { recenterMap() }
            .fullScreenCover(isPresented: $showingFullScreenMap) {
                FullScreenSummaryMap(title: "Ride Map", segments: day.segments,
                                     trails: trails, focusedSegmentID: nil)
            }
        }
    }

    private var mapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: day.segments.flatMap(\.points))
    }

    private var hasMatchedTrailOverlays: Bool {
        day.segments.contains { !trailOverlays(for: $0, trails: trails).isEmpty }
    }

    private func matchedTrailNames(for segment: RideSegment) -> String? {
        let names = TrailRouteMatchCache.shared
            .matchingSections(for: segment, trails: trails)
            .compactMap { section in trails.first { $0.id == section.trailID }?.name }
        return names.isEmpty ? nil : names.joined(separator: " → ")
    }

    private func coordinates(for segment: RideSegment) -> [CLLocationCoordinate2D] {
        segment.points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private var recenterButton: some View {
        Button(action: recenterMap) {
            Image(systemName: "scope")
                .font(.headline)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(.black.opacity(0.7))
        .foregroundStyle(.white)
        .accessibilityLabel("Recenter map")
    }

    private func recenterMap() {
        mapPosition = mapConfiguration?.initialPosition ?? .automatic
    }
}

struct FullScreenSummaryMap: View {
    let title: String
    let segments: [RideSegment]
    let trails: [Trail]
    let focusedSegmentID: UUID?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @State private var mapPosition: MapCameraPosition = .automatic

    private var visibleSegments: [RideSegment] {
        guard let focusedSegmentID else { return segments }
        return segments.filter { $0.id == focusedSegmentID }
    }

    private var mapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: visibleSegments.flatMap(\.points))
    }

    private var jumpMarkers: [SummaryMapJump] {
        summaryMapJumps(for: visibleSegments)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                Map(position: $mapPosition, bounds: mapConfiguration?.bounds,
                    interactionModes: [.pan, .zoom]) {
                    if mapLayerPreferences.showsActualTrails {
                        ForEach(visibleSegments) { segment in
                            ForEach(trailOverlays(for: segment, trails: trails)) { overlay in
                                trailPathKeyline(for: overlay.coordinates)
                                trailPath(for: overlay)
                                if focusedSegmentID != nil,
                                   let coordinate = coordinate(for: overlay) {
                                    Annotation("", coordinate: coordinate) {
                                        TrailMapLabel(name: overlay.name,
                                                      difficulty: overlay.difficulty,
                                                      color: overlay.color)
                                    }
                                }
                            }
                        }
                    }
                    if mapLayerPreferences.showsRidePath {
                        ForEach(visibleSegments) { segment in
                            if segment.points.count > 1 {
                                MapPolyline(coordinates: segment.points.map {
                                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                                })
                                .stroke(segment.kind == .run ? Color.bermsTrail : Color.bermsLift, lineWidth: 5)
                            }
                        }
                    }
                    if mapLayerPreferences.showsJumps {
                        ForEach(jumpMarkers) { marker in
                            Annotation("", coordinate: marker.coordinate) {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                                    .accessibilityLabel("\(marker.label), \(BermsFormat.airtime(marker.airtime))")
                            }
                        }
                    }
                }
                .mapStyle(.standard)
                .saturation(mapLayerPreferences.showsActualTrails || focusedSegmentID != nil ? 1 : 0)
                .mapControls { MapCompass() }
                VStack(spacing: 8) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  hasActualTrails: hasTrailOverlays)
                    Button { recenterMap() } label: {
                        Image(systemName: "scope")
                            .font(.headline)
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Recenter map")
                }
                .padding(12)
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

    private var hasTrailOverlays: Bool {
        visibleSegments.contains { !trailOverlays(for: $0, trails: trails).isEmpty }
    }

    private func coordinate(for overlay: TrailMapOverlay) -> CLLocationCoordinate2D? {
        guard !overlay.points.isEmpty else { return nil }
        let point = overlay.points[overlay.points.count / 2]
        return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private func recenterMap() {
        mapPosition = mapConfiguration?.initialPosition ?? .automatic
    }
}

private struct TrailRatingBadge: View {
    let difficulty: TrailDifficulty

    var body: some View {
        HStack(spacing: 2) {
            ratingShape
            if difficulty == .doubleBlack {
                ratingShape
            }
        }
        .frame(width: difficulty == .doubleBlack ? 16 : 9, height: 10)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ratingShape: some View {
        let color = Color.bermsDifficulty(difficulty)
        switch difficulty {
        case .green:
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        case .blue:
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 9, height: 9)
        case .black, .doubleBlack:
            TrailDiamond()
                .fill(color)
                .frame(width: 9, height: 9)
        }
    }
}

private struct TrailDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

private struct TrailMapLabel: View {
    let name: String
    let difficulty: TrailDifficulty
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            TrailRatingBadge(difficulty: difficulty)
            Text(name)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.primary)
        }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(color, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .accessibilityLabel(name)
    }
}

private struct SummaryMapJump: Identifiable {
    let id = UUID()
    let label: String
    let coordinate: CLLocationCoordinate2D
    let airtime: TimeInterval
}

private func summaryMapJumps(for segments: [RideSegment]) -> [SummaryMapJump] {
    segments.flatMap { segment in
        segment.jumps.enumerated().compactMap { index, jump in
            guard let point = segment.points.min(by: {
                abs($0.timestamp.timeIntervalSince(jump.takeoffTimestamp))
                    < abs($1.timestamp.timeIntervalSince(jump.takeoffTimestamp))
            }) else { return nil }
            return SummaryMapJump(
                label: "Jump \(index + 1)",
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                airtime: jump.airtime
            )
        }
    }
}

struct RunMapView: View {
    let number: Int
    let segment: RideSegment
    @Query private var trails: [Trail]
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showingFullScreenMap = false

    private var routePoints: [RoutePoint] {
        segment.points
    }

    private var mapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: routePoints)
    }

    private var jumpMarkers: [JumpMarker] {
        segment.jumps.enumerated().compactMap { index, jump in
            guard let point = routePoints.min(by: {
                abs($0.timestamp.timeIntervalSince(jump.takeoffTimestamp))
                    < abs($1.timestamp.timeIntervalSince(jump.takeoffTimestamp))
            }) else { return nil }
            return JumpMarker(number: index + 1,
                              coordinate: CLLocationCoordinate2D(latitude: point.latitude,
                                                                 longitude: point.longitude),
                              airtime: jump.airtime)
        }
    }

    var body: some View {
        ZStack {
            BermsBackground()
            if routePoints.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.title2)
                    Text("No route")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topTrailing) {
                    Map(position: $mapPosition, bounds: mapConfiguration?.bounds,
                        interactionModes: [.pan, .zoom]) {
                        if mapLayerPreferences.showsActualTrails {
                            ForEach(matchedOverlays) { overlay in
                                trailPathKeyline(for: overlay.coordinates)
                                trailPath(for: overlay)
                                if let coordinate = coordinate(for: overlay) {
                                    Annotation("", coordinate: coordinate) {
                                        TrailMapLabel(name: overlay.name,
                                                      difficulty: overlay.difficulty,
                                                      color: overlay.color)
                                    }
                                }
                            }
                        }

                        if mapLayerPreferences.showsRidePath {
                            MapPolyline(coordinates: routePoints.map {
                                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                            })
                            .stroke(Color.bermsTrail, lineWidth: 5)
                        }

                        if mapLayerPreferences.showsJumps {
                            ForEach(jumpMarkers) { marker in
                                Annotation("", coordinate: marker.coordinate) {
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 12, height: 12)
                                        .overlay(Circle().stroke(.white, lineWidth: 2))
                                        .accessibilityLabel("Jump \(marker.number), \(BermsFormat.airtime(marker.airtime))")
                                }
                            }
                        }
                    }
                    .mapStyle(.standard)
                    .mapControls {
                        MapCompass()
                    }
                    if !matchedOverlays.isEmpty, mapLayerPreferences.showsActualTrails {
                        trailLegend
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(12)
                    }
                    VStack(spacing: 8) {
                        MapLayersMenu(preferences: mapLayerPreferences,
                                      hasActualTrails: !matchedOverlays.isEmpty)
                        recenterButton
                        Button { showingFullScreenMap = true } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.headline)
                                .frame(width: 42, height: 42)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.black.opacity(0.7))
                        .foregroundStyle(.white)
                        .accessibilityLabel("Open full-screen run map")
                    }
                    .padding(12)
                }
                .padding(10)
                .fullScreenCover(isPresented: $showingFullScreenMap) {
                    FullScreenSummaryMap(title: "Run \(number)", segments: [segment],
                                         trails: trails, focusedSegmentID: segment.id)
                }
            }
        }
        .navigationTitle("Run \(number)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recenterMap() }
    }

    private var matchedOverlays: [TrailMapOverlay] {
        trailOverlays(for: segment, trails: trails)
    }

    private var trailSequence: String {
        matchedOverlays.map(\.name).joined(separator: " → ")
    }

    private func coordinate(for overlay: TrailMapOverlay) -> CLLocationCoordinate2D? {
        guard !overlay.points.isEmpty else { return nil }
        let point = overlay.points[overlay.points.count / 2]
        return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private var trailLegend: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Trail sequence")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.bermsMuted)
            Text(trailSequence)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trailSequence)
    }

    private var recenterButton: some View {
        Button(action: recenterMap) {
            Image(systemName: "scope")
                .font(.headline)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(.black.opacity(0.7))
        .foregroundStyle(.white)
        .accessibilityLabel("Recenter map")
    }

    private func recenterMap() {
        mapPosition = mapConfiguration?.initialPosition ?? .automatic
    }
}

private struct JumpMarker: Identifiable {
    let number: Int
    let coordinate: CLLocationCoordinate2D
    let airtime: TimeInterval

    var id: Int { number }
}

private struct RouteMapConfiguration {
    let initialPosition: MapCameraPosition
    let bounds: MapCameraBounds

    init?(points: [RoutePoint]) {
        let validPoints = points.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
                && (-90...90).contains($0.latitude)
                && (-180...180).contains($0.longitude)
        }
        guard let first = validPoints.first else { return nil }

        let minLatitude = validPoints.map(\.latitude).min() ?? first.latitude
        let maxLatitude = validPoints.map(\.latitude).max() ?? first.latitude
        let minLongitude = validPoints.map(\.longitude).min() ?? first.longitude
        let maxLongitude = validPoints.map(\.longitude).max() ?? first.longitude
        let centerLatitude = (minLatitude + maxLatitude) / 2
        let centerLongitude = (minLongitude + maxLongitude) / 2
        let latitudeMeters = max(100, (maxLatitude - minLatitude) * 111_000)
        let longitudeScale = max(0.1, cos(centerLatitude * .pi / 180))
        let longitudeMeters = max(100, (maxLongitude - minLongitude) * 111_000 * longitudeScale)
        let cameraLatitudeMeters = max(800, latitudeMeters * 1.25)
        let cameraLongitudeMeters = max(800, longitudeMeters * 1.25)
        let largestSpan = max(cameraLatitudeMeters, cameraLongitudeMeters)
        let cameraRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
            latitudinalMeters: cameraLatitudeMeters,
            longitudinalMeters: cameraLongitudeMeters
        )
        let boundsRegion = MKCoordinateRegion(
            center: cameraRegion.center,
            latitudinalMeters: max(1_500, cameraLatitudeMeters * 1.6),
            longitudinalMeters: max(1_500, cameraLongitudeMeters * 1.6)
        )

        initialPosition = .region(cameraRegion)
        bounds = MapCameraBounds(
            centerCoordinateBounds: boundsRegion,
            minimumDistance: max(150, largestSpan * 0.2),
            maximumDistance: max(5_000, largestSpan * 3)
        )
    }
}

struct SegmentRow: View {
    let number: Int
    let segment: RideSegment
    var trailName: String?
    var isLastRun: Bool

    init(number: Int, segment: RideSegment, trailName: String? = nil, isLastRun: Bool = false) {
        self.number = number
        self.segment = segment
        self.trailName = trailName
        self.isLastRun = isLastRun
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 28, height: 28)
                .background(Color.bermsInset, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(isLastRun ? "Last Run" : "Run \(number)")
                    .font(.headline)
                if let trailName {
                    Text(trailName)
                        .font(.subheadline)
                        .foregroundStyle(Color.bermsMuted)
                        .lineLimit(1)
                }
                Text(BermsFormat.duration(segment.duration))
                    .font(.subheadline.weight(.semibold))
                if segment.kind == .run, !segment.jumps.isEmpty {
                    Text("\(segment.jumps.count) jumps · \(BermsFormat.airtime(segment.jumps.map(\.airtime).max() ?? 0))")
                        .font(.caption)
                        .foregroundStyle(Color.bermsMuted)
                }
                Text(segment.kind == .run ? BermsFormat.elevation(segment.verticalMeters) + " descent" : BermsFormat.elevation(segment.verticalMeters) + " up")
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
            }
            Spacer()
            Text(BermsFormat.speed(segment.maximumSpeedMetersPerSecond))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.bermsMuted)
        }
        .padding(12)
        .background(Color.bermsCard, in: RoundedRectangle(cornerRadius: 16))
    }
}

enum BermsFormat {
    private static var isMetric: Bool { Locale.current.measurementSystem == .metric }

    static func duration(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func speed(_ metersPerSecond: Double) -> String {
        let value = isMetric ? metersPerSecond * 3.6 : metersPerSecond * 2.23694
        return String(format: "%.0f %@", value, isMetric ? "km/h" : "mph")
    }

    static func distance(_ meters: Double) -> String {
        if isMetric {
            return meters >= 1000 ? String(format: "%.1f km", meters / 1000) : String(format: "%.0f m", meters)
        }
        let miles = meters / 1609.344
        return miles >= 0.1 ? String(format: "%.1f mi", miles) : String(format: "%.0f ft", meters * 3.28084)
    }

    static func airtime(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", max(0, seconds))
    }

    static func elevation(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return elevation(meters)
    }

    static func elevation(_ meters: Double) -> String {
        isMetric ? String(format: "%.0f m", meters) : String(format: "%.0f ft", meters * 3.28084)
    }
}
