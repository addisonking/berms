import MapKit
import SwiftData
import SwiftUI
import UIKit

private extension MapStyle {
    // Keep the system basemap subdued so route and trail overlays stay legible.
    static var bermsMonochrome: MapStyle {
        .standard(elevation: .flat,
                  emphasis: .muted,
                  pointsOfInterest: .excludingAll,
                  showsTraffic: false)
    }
}

@MainActor
final class MapLayerPreferences: ObservableObject {
    private enum Key {
        static let ridePath = "berms.mapLayers.ridePath"
        static let actualTrails = "berms.mapLayers.actualTrails"
        static let jumps = "berms.mapLayers.jumps"
        static let previousRuns = "berms.mapLayers.previousRuns"
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

    @Published var showsPreviousRunsInLiveMap: Bool {
        didSet { defaults.set(showsPreviousRunsInLiveMap, forKey: Key.previousRuns) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsRidePath = defaults.object(forKey: Key.ridePath) as? Bool ?? true
        showsActualTrails = defaults.object(forKey: Key.actualTrails) as? Bool ?? true
        showsJumps = defaults.object(forKey: Key.jumps) as? Bool ?? true
        showsPreviousRunsInLiveMap = defaults.object(forKey: Key.previousRuns) as? Bool ?? false
    }
}

private struct MapLayersMenu: View {
    @ObservedObject var preferences: MapLayerPreferences
    var showsRidePathControl = true
    var showsActualTrailsControl = true
    var showsJumpsControl = true
    var showsPreviousRunsControl = false

    var body: some View {
        Menu {
            Toggle("Ride path", isOn: $preferences.showsRidePath)
                .disabled(!showsRidePathControl)
            if showsActualTrailsControl {
                Toggle("Actual trails", isOn: $preferences.showsActualTrails)
            }
            Toggle("Jumps", isOn: $preferences.showsJumps)
                .disabled(!showsJumpsControl)
            if showsPreviousRunsControl {
                Toggle("Previous runs", isOn: $preferences.showsPreviousRunsInLiveMap)
            }
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

private struct TrailMapLabelPlacement: Identifiable {
    let id: UUID
    let name: String
    let difficulty: TrailDifficulty
    let point: CGPoint
}

private func trailCoordinates(for trail: Trail) -> [CLLocationCoordinate2D] {
    trailCoordinates(for: trail.points)
}

private func trailCoordinates(for points: [RoutePoint]) -> [CLLocationCoordinate2D] {
    points.map {
        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
    }
}

@MainActor
private struct ProjectedTrailHitTarget: View {
    let coordinates: [CLLocationCoordinate2D]
    let proxy: MapProxy
    let refreshID: Int
    let onTap: () -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(refreshID)
            .contentShape(projectedPath.strokedPath(StrokeStyle(
                lineWidth: 26,
                lineCap: .round,
                lineJoin: .round
            )))
            .onTapGesture(perform: onTap)
    }

    private var projectedPath: Path {
        var path = Path()
        var hasPoint = false

        for coordinate in coordinates {
            guard let point = proxy.convert(coordinate, to: .local) else {
                hasPoint = false
                continue
            }
            if hasPoint {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                hasPoint = true
            }
        }

        return path
    }
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
    @StateObject private var trailCatalogSelection = TrailCatalogSelection()
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
        .environmentObject(trailCatalogSelection)
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
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection

    private var sensitivityBinding: Binding<JumpSensitivity> {
        Binding(
            get: { recorder.jumpSensitivity },
            set: { recorder.setJumpSensitivity($0) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trail catalog") {
                    Picker("Resort", selection: Binding(
                        get: { trailCatalogSelection.selectionID },
                        set: { trailCatalogSelection.setSelectionID($0) }
                    )) {
                        Text("Automatic").tag(TrailCatalogRegistry.automaticSelectionID)
                        ForEach(TrailCatalogRegistry.catalogs) { catalog in
                            Text(catalog.resortName).tag(catalog.id)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(trailCatalogSelection.isAutomatic
                         ? "Automatic chooses the nearest bundled resort from GPS."
                         : "Using this resort until you switch back to Automatic.")
                        .font(.caption)
                        .foregroundStyle(Color.bermsMuted)
                }
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
                    if mapLayerPreferences.showsRidePath {
                        ForEach(Array(liveMapPaths.enumerated()), id: \.offset) { _, path in
                            MapPolyline(coordinates: path.points.map {
                                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                            })
                            .stroke(color(for: path.role), lineWidth: path.role == .previousRun ? 3 : 5)
                        }
                    }
                }
                .mapStyle(.bermsMonochrome)
                .saturation(0)
                .mapControls {
                    MapCompass()
                }
                .onChange(of: mapPosition) { _, position in
                    if position.positionedByUser {
                        isFollowing = false
                    }
                }

                MapLayersMenu(preferences: mapLayerPreferences,
                              showsActualTrailsControl: false,
                              showsJumpsControl: false,
                              showsPreviousRunsControl: true)
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

    private var liveMapPaths: [LiveMapPath] {
        let completedRuns = (recorder.activeDay?.segments ?? [])
            .filter { $0.kind == .run }
            .sorted { $0.startedAt < $1.startedAt }
            .map(\.points)
        return RideMapPresentation.livePaths(
            activeKind: recorder.activeSegmentKind,
            currentPath: recorder.currentMapPoints,
            completedRunPaths: completedRuns,
            showsPreviousRuns: mapLayerPreferences.showsPreviousRunsInLiveMap
        )
    }

    private func color(for role: LiveMapPathRole) -> Color {
        switch role {
        case .previousRun:
            return .gray.opacity(0.45)
        case .latestCompletedRun:
            return .bermsTrail
        case .activeSegment:
            return recorder.activeSegmentKind == .lift ? .bermsLift : .bermsTrail
        }
    }
}

#if DEBUG
struct TrailMappingView: View {
    @Query(sort: \Trail.updatedAt, order: .reverse) private var trails: [Trail]
    @ObservedObject var mapper: TrailMapper
    @ObservedObject var recorder: RideRecorder
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var mapProjectionRevision = 0
    @State private var showingStartSheet = false
    @State private var showingDiscardConfirmation = false
    @State private var selectedTrail: Trail?
    @State private var authoredMapCameraDistance: CLLocationDistance = .greatestFiniteMagnitude

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
            TrailStartSheet(trails: visibleTrails, mapper: mapper,
                            defaultResort: activeCatalog.resortName)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedTrail) { trail in
            TrailEditorSheet(trail: trail, mapper: mapper)
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

                Text("Authored trails · \(activeCatalog.resortName)")
                    .font(.title3.weight(.bold))
                if !visibleTrails.isEmpty {
                    Text("Tap a trail to edit it, delete it, or record another pass for averaging.")
                        .font(.footnote)
                        .foregroundStyle(Color.bermsMuted)
                }
                if visibleTrails.isEmpty {
                    Text("Map your first trail from the top, then save it at the bottom.")
                        .foregroundStyle(Color.bermsMuted)
                } else {
                    ForEach(visibleTrails) { trail in
                        Button {
                            selectedTrail = trail
                        } label: {
                            TrailLibraryRow(trail: trail)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Edit, delete, or record a pass for this trail")
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
                    if mapLayerPreferences.showsRidePath, mapper.activeRoutePoints.count > 1 {
                        MapPolyline(coordinates: mapper.activeRoutePoints.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        })
                        .stroke(Color.bermsTrail, lineWidth: 5)
                    }
                    if mapLayerPreferences.showsActualTrails,
                       mapper.activeTrailPoints.count > 1 {
                        MapPolyline(coordinates: trailCoordinates(for: mapper.activeTrailPoints))
                            .stroke(Color.bermsDifficulty(mapper.activeDifficulty).opacity(0.65), lineWidth: 3)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 300)
                VStack(spacing: 8) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsActualTrailsControl: true,
                                  showsJumpsControl: false)
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
        if visibleTrails.flatMap(\.points).isEmpty {
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
                MapReader { proxy in
                    ZStack {
                        Map(position: $mapPosition, bounds: authoredMapConfiguration?.bounds,
                            interactionModes: [.pan, .zoom]) {
                            if mapLayerPreferences.showsActualTrails {
                                ForEach(visibleTrails) { trail in
                                    if trail.points.count > 1 {
                                        MapPolyline(coordinates: trailCoordinates(for: trail))
                                            .stroke(color(for: trail.difficulty), lineWidth: 3)
                                    }
                                }
                            }
                        }
                        .mapStyle(.bermsMonochrome)
                        .saturation(0)
                        .onMapCameraChange(frequency: .onEnd) { context in
                            authoredMapCameraDistance = context.camera.distance
                            mapProjectionRevision &+= 1
                        }

                        if mapLayerPreferences.showsActualTrails {
                            ForEach(visibleTrails) { trail in
                                if trail.points.count > 1 {
                                    ProjectedTrailHitTarget(
                                        coordinates: interactionCoordinates(for: trail),
                                        proxy: proxy,
                                        refreshID: mapProjectionRevision,
                                        onTap: { selectedTrail = trail }
                                    )
                                }
                            }
                            if authoredMapCameraDistance < 2_500 {
                                ForEach(labelPlacements(for: visibleTrails, proxy: proxy)) { placement in
                                    TrailMapLabel(name: placement.name,
                                                  difficulty: placement.difficulty,
                                                  color: color(for: placement.difficulty))
                                        .position(placement.point)
                                }
                            }
                        }
                    }
                }
                VStack(spacing: 8) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsRidePathControl: false,
                                  showsActualTrailsControl: true,
                                  showsJumpsControl: false)
                    recenterButton(action: recenterAuthoredMap)
                }
                .padding(12)
            }
            .onAppear { recenterAuthoredMap() }
        }
    }

    private var activeMapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: mapper.activeRoutePoints + mapper.activeTrailPoints)
    }

    private var authoredMapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: visibleTrails.flatMap(\.points))
    }

    private var activeCatalog: TrailCatalogDescriptor {
        trailCatalogSelection.catalog(for: activeLocation)
    }

    private var visibleTrails: [Trail] {
        trailCatalogSelection.trails(trails, near: activeLocation)
    }

    private var activeLocation: Coordinate? {
        if let coordinate = recorder.lastSample?.coordinate {
            return coordinate
        }
        guard let coordinate = recorder.locationService.lastLocation?.coordinate else { return nil }
        return Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private func labelPoint(for trail: Trail) -> RoutePoint? {
        let points = trail.points
        guard !points.isEmpty else { return nil }
        return points[points.count / 2]
    }

    private func interactionCoordinates(for trail: Trail) -> [CLLocationCoordinate2D] {
        let coordinates = trailCoordinates(for: trail)
        guard coordinates.count > 120 else { return coordinates }

        let stride = max(1, coordinates.count / 120)
        var reduced = Array(coordinates.enumerated().compactMap { index, coordinate in
            index.isMultiple(of: stride) ? coordinate : nil
        })
        if let last = coordinates.last,
           reduced.last?.latitude != last.latitude || reduced.last?.longitude != last.longitude {
            reduced.append(last)
        }
        return reduced
    }

    private func labelPlacements(for trails: [Trail], proxy: MapProxy) -> [TrailMapLabelPlacement] {
        var acceptedPoints: [CGPoint] = []
        var placements: [TrailMapLabelPlacement] = []

        for trail in trails {
            guard placements.count < 10,
                  let point = labelPoint(for: trail),
                  let screenPoint = proxy.convert(
                      CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                      to: .local
                  ) else {
                continue
            }

            let isSeparated = acceptedPoints.allSatisfy { accepted in
                hypot(screenPoint.x - accepted.x, screenPoint.y - accepted.y) >= 72
            }
            guard isSeparated else { continue }

            acceptedPoints.append(screenPoint)
            placements.append(TrailMapLabelPlacement(id: trail.id,
                                                     name: trail.name,
                                                     difficulty: trail.difficulty,
                                                     point: screenPoint))
        }
        return placements
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
            Image(systemName: "pencil.circle")
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

private struct TrailEditorSheet: View {
    let trail: Trail
    @ObservedObject var mapper: TrailMapper
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name: String
    @State private var difficulty: TrailDifficulty
    @State private var style: TrailStyle
    @State private var resort: String
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?

    init(trail: Trail, mapper: TrailMapper) {
        self.trail = trail
        self._mapper = ObservedObject(wrappedValue: mapper)
        _name = State(initialValue: trail.name)
        _difficulty = State(initialValue: trail.difficulty)
        _style = State(initialValue: trail.style)
        _resort = State(initialValue: trail.resort)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trail data") {
                    TextField("Name", text: $name)
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
                    TextField("Resort", text: $resort)
                }

                Section("Route data") {
                    LabeledContent("Centerline points", value: "\(trail.points.count)")
                    LabeledContent("Distance", value: BermsFormat.distance(trailDistance))
                    LabeledContent("Recorded passes", value: "\(trail.passCount)")
                    Text("The imported centerline is the first pass. New GPS passes are added and averaged with it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        recordPass()
                    } label: {
                        Label("Record pass for average", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(mapper.isRecording)
                } footer: {
                    Text("Start at the top of the trail and save the segment when you reach the bottom.")
                }

                Section {
                    Button("Save changes") {
                        _ = saveChanges()
                    }
                    .frame(maxWidth: .infinity)
                }

                Section {
                    Button("Delete trail", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
            }
            .navigationTitle("Edit Trail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Delete \(trail.name)?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Trail", role: .destructive) {
                deleteTrail()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the trail and all of its recorded passes from the local database.")
        }
        .alert("Trail update failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func saveChanges() -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a trail name first."
            return false
        }

        trail.name = trimmedName
        trail.difficultyRawValue = difficulty.rawValue
        trail.styleRawValue = style.rawValue
        trail.resort = resort.trimmingCharacters(in: .whitespacesAndNewlines)
        trail.updatedAt = .now

        do {
            try modelContext.save()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func recordPass() {
        guard saveChanges() else { return }
        if mapper.start(existingTrail: trail,
                        name: trail.name,
                        difficulty: trail.difficulty,
                        style: trail.style) {
            dismiss()
        }
    }

    private func deleteTrail() {
        guard !mapper.isRecording else {
            errorMessage = "Finish the active recording before deleting a trail."
            return
        }

        modelContext.delete(trail)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
    let defaultResort: String
    @ObservedObject var mapper: TrailMapper
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTrailID: UUID?
    @State private var name = ""
    @State private var difficulty: TrailDifficulty = .blue
    @State private var style: TrailStyle = .freeRide
    @State private var resortOverride = ""

    init(trails: [Trail], mapper: TrailMapper, defaultResort: String) {
        self.trails = trails
        self.defaultResort = defaultResort
        self._mapper = ObservedObject(wrappedValue: mapper)
        self._resortOverride = State(initialValue: defaultResort)
    }

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
                        TextField("Resort override", text: $resortOverride)
                    } else if let selectedTrail {
                        LabeledContent("Difficulty", value: selectedTrail.difficulty.title)
                        LabeledContent("Style", value: selectedTrail.style.title)
                    }
                }

                Section {
                    Text("Start at the top. New trails are assigned to \(defaultResort); you can override it if needed.")
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
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
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
                                           trailName: trailSequence(for: segment))
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
        if runs.isEmpty {
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
                    if mapLayerPreferences.showsRidePath {
                        ForEach(Array(runs.enumerated()), id: \.element.id) { index, segment in
                            MapPolyline(coordinates: coordinates(for: segment))
                                .stroke(Color.gray.opacity(RideMapPresentation.summaryRunOpacity(
                                    index: index, count: runs.count)), lineWidth: 4)
                                .tag(segment.id)
                        }
                    }
                    if mapLayerPreferences.showsJumps {
                        ForEach(summaryMapJumps(for: runs)) { marker in
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
                .mapStyle(.bermsMonochrome)
                .saturation(0)
                .mapControls {
                    MapCompass()
                }
                VStack(spacing: 8) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsActualTrailsControl: false)
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
                                     focusedSegmentID: nil)
            }
        }
    }

    private var mapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: runs.flatMap(\.points))
    }

    private func trailSequence(for segment: RideSegment) -> String? {
        let coordinate = segment.points.first.map {
            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        let activeTrails = trailCatalogSelection.trails(trails, near: coordinate)
        return TrailSequenceResolver.title(for: segment, trails: activeTrails)
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
    let focusedSegmentID: UUID?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @State private var mapPosition: MapCameraPosition = .automatic

    private var visibleSegments: [RideSegment] {
        if let focusedSegmentID {
            return segments.filter { $0.id == focusedSegmentID }
        }
        return segments.filter { $0.kind == .run }.sorted { $0.startedAt < $1.startedAt }
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
                    if mapLayerPreferences.showsRidePath {
                        ForEach(Array(visibleSegments.enumerated()), id: \.element.id) { index, segment in
                            if segment.points.count > 1 {
                                MapPolyline(coordinates: segment.points.map {
                                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                                })
                                .stroke(focusedSegmentID == nil
                                        ? Color.gray.opacity(RideMapPresentation.summaryRunOpacity(
                                            index: index, count: visibleSegments.count))
                                        : Color.bermsTrail, lineWidth: 5)
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
                .mapStyle(.bermsMonochrome)
                .saturation(0)
                .mapControls { MapCompass() }
                VStack(spacing: 8) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsActualTrailsControl: false)
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
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
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
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        Map(position: $mapPosition, bounds: mapConfiguration?.bounds,
                            interactionModes: [.pan, .zoom]) {
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
                        .mapStyle(.bermsMonochrome)
                        .saturation(0)
                        .mapControls {
                            MapCompass()
                        }
                        VStack(spacing: 8) {
                            MapLayersMenu(preferences: mapLayerPreferences,
                                          showsActualTrailsControl: false)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)

                    TrailSequenceCard(sequence: trailSequence, runNumber: number)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                .fullScreenCover(isPresented: $showingFullScreenMap) {
                    FullScreenSummaryMap(title: trailSequence, segments: [segment],
                                         focusedSegmentID: segment.id)
                }
            }
        }
        .navigationTitle(trailSequence)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recenterMap() }
    }

    private var trailSequence: String {
        let coordinate = routePoints.first.map {
            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        let activeTrails = trailCatalogSelection.trails(trails, near: coordinate)
        return TrailSequenceResolver.title(for: segment, trails: activeTrails) ?? "Unmatched run"
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

private struct TrailSequenceCard: View {
    let sequence: String
    let runNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(sequence)
                .font(.headline)
                .lineLimit(2)
            Text("Run \(runNumber)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.bermsMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.bermsCard, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sequence), Run \(runNumber)")
    }
}

struct SegmentRow: View {
    let number: Int
    let segment: RideSegment
    var trailName: String?

    init(number: Int, segment: RideSegment, trailName: String? = nil) {
        self.number = number
        self.segment = segment
        self.trailName = trailName
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 28, height: 28)
                .background(Color.bermsInset, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(trailName ?? "Unmatched run")
                    .font(.headline)
                Text("Run \(number) · \(BermsFormat.duration(segment.duration))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bermsMuted)
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
