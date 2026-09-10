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
        static let liftPaths = "berms.mapLayers.liftPaths"
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

    @Published var showsLiftPaths: Bool {
        didSet { defaults.set(showsLiftPaths, forKey: Key.liftPaths) }
    }

    @Published var showsPreviousRunsInLiveMap: Bool {
        didSet { defaults.set(showsPreviousRunsInLiveMap, forKey: Key.previousRuns) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsRidePath = defaults.object(forKey: Key.ridePath) as? Bool ?? true
        showsActualTrails = defaults.object(forKey: Key.actualTrails) as? Bool ?? true
        showsJumps = defaults.object(forKey: Key.jumps) as? Bool ?? true
        showsLiftPaths = defaults.object(forKey: Key.liftPaths) as? Bool ?? true
        showsPreviousRunsInLiveMap = defaults.object(forKey: Key.previousRuns) as? Bool ?? false
    }
}

// Match the standard circular Settings toolbar control.
private let liveControlWidth: CGFloat = 44
// The map content's trailing edge sits inside the navigation toolbar's
// trailing edge. This inset keeps the two controls on the same center line.
private let liveControlsTrailingInset: CGFloat = 20

private struct MapLayersMenu: View {
    @ObservedObject var preferences: MapLayerPreferences
    var showsRidePathControl = true
    var showsActualTrailsControl = true
    var actualTrailsAvailable = true
    var showsJumpsControl = true
    var showsLiftPathsControl = false
    var liftPathsAvailable = true
    var showsPreviousRunsControl = false

    var body: some View {
        Menu {
            if showsRidePathControl {
                Toggle("Ride path", isOn: $preferences.showsRidePath)
            }
            if showsActualTrailsControl {
                Toggle("Actual trails", isOn: $preferences.showsActualTrails)
                    .disabled(!actualTrailsAvailable)
            }
            if showsJumpsControl {
                Toggle("Jumps", isOn: $preferences.showsJumps)
            }
            if showsLiftPathsControl {
                Toggle("Lift paths", isOn: $preferences.showsLiftPaths)
                    .disabled(!liftPathsAvailable)
            }
            if showsPreviousRunsControl {
                Toggle("Previous runs", isOn: $preferences.showsPreviousRunsInLiveMap)
            }
        } label: {
            Label("Layers", systemImage: "square.3.layers.3d")
                .labelStyle(.iconOnly)
                .font(.headline)
                .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
        }
        .buttonStyle(.glass)
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

private enum TrailMapRendering {
    static let lineWidth: CGFloat = 2.25
    static let accentLineWidth: CGFloat = 1.1
    static let doubleBlackDash: [CGFloat] = [7, 5]
    static let accentDash: [CGFloat] = [3, 5]
}

private func trailMapStrokeStyle(for difficulty: TrailDifficulty,
                                 lineWidth: CGFloat = TrailMapRendering.lineWidth) -> StrokeStyle {
    StrokeStyle(lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round,
                dash: difficulty == .doubleBlack ? TrailMapRendering.doubleBlackDash : [])
}

private func trailMapAccentStrokeStyle(lineWidth: CGFloat = TrailMapRendering.accentLineWidth) -> StrokeStyle {
    StrokeStyle(lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round,
                dash: TrailMapRendering.accentDash)
}

private func trailLabelCoordinate(for points: [RoutePoint]) -> CLLocationCoordinate2D? {
    guard !points.isEmpty else { return nil }
    let point = points[points.count / 2]
    return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
}

@MainActor
@MapContentBuilder
private func trailMapContent(coordinates: [CLLocationCoordinate2D],
                             difficulty: TrailDifficulty,
                             color: Color? = nil,
                             lineWidth: CGFloat = TrailMapRendering.lineWidth,
                             tag: UUID? = nil) -> some MapContent {
    if let tag {
        MapPolyline(coordinates: coordinates)
            .stroke(color ?? .bermsDifficulty(difficulty),
                    style: trailMapStrokeStyle(for: difficulty, lineWidth: lineWidth))
            .tag(tag)
    } else {
        MapPolyline(coordinates: coordinates)
            .stroke(color ?? .bermsDifficulty(difficulty),
                    style: trailMapStrokeStyle(for: difficulty, lineWidth: lineWidth))
    }

    if difficulty == .doubleBlack {
        MapPolyline(coordinates: coordinates)
            .stroke(.red, style: trailMapAccentStrokeStyle())
    }
}

private func trailDistance(from coordinate: Coordinate, to points: [RoutePoint]) -> Double {
    guard points.count >= 2 else {
        guard let point = points.first else { return .greatestFiniteMagnitude }
        return Coordinate(latitude: point.latitude, longitude: point.longitude).distance(to: coordinate)
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

private struct RunNumberMarker: View {
    let number: Int
    let isSelected: Bool

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.heavy))
            .foregroundStyle(isSelected ? Color.bermsOnAccent : Color.bermsTrail)
            .frame(width: 26, height: 26)
            .background(isSelected ? Color.bermsTrail : Color.bermsCard, in: Circle())
            .overlay(Circle().stroke(Color.bermsTrail, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .accessibilityLabel("Run \(number)")
    }
}

private struct JumpMapMarker: View {
    let number: Int
    let airtime: TimeInterval
    var showsAirtime = false

    var body: some View {
        HStack(spacing: 4) {
            Text("\(number)")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.orange, in: Circle())
            if showsAirtime {
                Text(BermsFormat.airtime(airtime))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, showsAirtime ? 5 : 0)
        .padding(.vertical, showsAirtime ? 3 : 0)
        .background {
            if showsAirtime {
                Capsule().fill(.regularMaterial)
            }
        }
        .overlay {
            if showsAirtime {
                Capsule().stroke(.orange, lineWidth: 1.5)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .accessibilityLabel("Jump \(number), \(BermsFormat.airtime(airtime))")
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
            DaysView(pendingDayID: $pendingDayID) {
                selectedTab = .track
            }
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
                    NavigationLink {
                        TrailLibraryView()
                    } label: {
                        Label("Trail Library", systemImage: "map")
                    }

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var recorder: RideRecorder
    @Query private var trails: [Trail]
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var isFollowing = true
    @State private var lastFollowedCoordinate: Coordinate?
    @State private var liveStatsHeight: CGFloat = 320
    @State private var showingStopConfirmation = false
    @State private var showingSettings = false
    let onDayFinished: (RideDay) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                BermsBackground()
                if recorder.isRecording {
                    recordingContent
                        .transition(.opacity)
                } else {
                    readyContent
                        .transition(.opacity)
                }
            }
            .navigationTitle(recorder.isRecording ? "" : "Berms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    settingsButton
                }
            }
            .animation(reduceMotion ? nil : BermsMotion.content, value: recorder.isRecording)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(recorder: recorder)
        }
        .alert("Finish session?", isPresented: $showingStopConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Finish", role: .destructive) {
                guard let finishedDay = recorder.stop() else { return }
                BermsMotion.recordingFeedback()
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
        .onAppear {
            centerOnLastSampleIfNeeded(force: true)
        }
        .onChange(of: recorder.lastSample?.timestamp) { _, _ in
            if isFollowing {
                centerOnLastSampleIfNeeded()
            }
        }
        .onChange(of: recorder.isRecording) { _, recording in
            if recording {
                isFollowing = true
                mapPosition = .automatic
                lastFollowedCoordinate = nil
                centerOnLastSampleIfNeeded(force: true)
            } else {
                lastFollowedCoordinate = nil
            }
        }
    }

    private var readyContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: BermsSpacing.section) {
                    Image(systemName: "mountain.2.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.bermsTrail)
                    Text("Track runs, lifts, jumps, and your route throughout the day.")
                        .font(.subheadline)
                        .foregroundStyle(Color.bermsMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    startButton
                    Text("Berms uses location only while you are recording.")
                        .font(.caption)
                        .foregroundStyle(Color.bermsMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
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
                }
                .padding(.vertical, BermsSpacing.section)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.horizontal, BermsSpacing.content, for: .scrollContent)
        }
    }

    private var recordingContent: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                liveMap

                // Fit the panel to its content. Scroll only when large text or
                // landscape leaves too little room for all the metrics.
                ScrollView {
                    liveStatsOverlay
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            liveStatsHeight = height
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(liveStatsHeight, max(0, geometry.size.height * 0.65)))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .padding(.horizontal, BermsSpacing.content)
                .padding(.bottom, BermsSpacing.content)
            }
        }
    }

    private var liveStatsOverlay: some View {
        VStack(spacing: BermsSpacing.control) {
            HStack {
                HStack(spacing: BermsSpacing.compact) {
                    Circle()
                        .fill(recorder.isPaused ? Color.bermsMuted : Color.bermsTrail)
                        .frame(width: 9, height: 9)
                    Text(recorder.isPaused ? "PAUSED" : "REC")
                        .bermsValueMotion(recorder.isPaused ? "PAUSED" : "REC")
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

            VStack(spacing: BermsSpacing.control) {
                AdaptiveStatRow {
                    SummaryStat(animatesValue: true, numericValue: true, label: "Runs", value: "\(recorder.completedRunCount)", tint: .bermsTrail)
                    SummaryStat(animatesValue: true, numericValue: true, label: "Jumps", value: "\(recorder.activeJumpCount)", tint: .bermsTrail)
                    SummaryStat(animatesValue: true, label: "Mode", value: liveModeTitle,
                                tint: recorder.activeSegmentKind == .lift ? .bermsLift : .bermsTrail)
                }

                AdaptiveStatRow {
                    SummaryStat(label: "Speed", value: BermsFormat.speed(recorder.currentSpeed))
                    SummaryStat(label: "Altitude", value: BermsFormat.elevation(recorder.currentAltitude))
                }
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

            AdaptiveStatRow {
                Button {
                    if recorder.isPaused {
                        if recorder.resume() { BermsMotion.recordingFeedback() }
                    } else {
                        if recorder.pause() { BermsMotion.recordingFeedback() }
                    }
                } label: {
                    Label(recorder.isPaused ? "Resume" : "Pause",
                          systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                        .bermsValueMotion(recorder.isPaused ? "Resume" : "Pause")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.bermsTrail)
                .foregroundStyle(Color.bermsOnAccent)

                Button {
                    showingStopConfirmation = true
                } label: {
                    Label("Finish", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.bermsTrail)
                .foregroundStyle(Color.bermsOnAccent)
            }
        }
        .padding(.horizontal, BermsSpacing.content)
        .padding(.vertical, BermsSpacing.content)

    }

    private var liveModeTitle: String {
        if recorder.isPaused { return "Paused" }
        if recorder.lastSample == nil { return "Waiting" }
        return recorder.phase.title
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
            if recorder.start() { BermsMotion.recordingFeedback() }
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
        ZStack {
            if recorder.lastSample == nil {
                VStack(spacing: BermsSpacing.control) {
                    Image(systemName: "location.slash")
                        .font(.title2)
                    Text(gpsEmptyTitle)
                        .font(.headline)
                    Text(gpsEmptyMessage)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(maxWidth: 230)
                    if recorder.locationAuthorization == .denied
                        || recorder.locationAuthorization == .restricted {
                        Button("Open Settings", action: openLocationSettings)
                            .buttonStyle(.borderedProminent)
                            .tint(.white)
                            .foregroundStyle(.black)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.35))
                .foregroundStyle(.white)
            } else {
                ZStack {
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
                        if mapLayerPreferences.showsActualTrails {
                            ForEach(nearbyTrails) { trail in
                                if trail.points.count > 1 {
                                    trailMapContent(coordinates: trailCoordinates(for: trail),
                                                    difficulty: trail.difficulty)
                                }
                            }
                        }
                    }
                    .mapStyle(.bermsMonochrome)
                    .ignoresSafeArea()
                    .onChange(of: mapPosition) { _, position in
                        if position.positionedByUser {
                            isFollowing = false
                        }
                    }

                }

                liveMapControls
            }
        }
    }

    private var liveMapControls: some View {
        GlassEffectContainer(spacing: BermsSpacing.compact) {
            VStack(spacing: 0) {
                    Menu {
                        Toggle("Ride path", isOn: $mapLayerPreferences.showsRidePath)
                        Toggle("Actual trails", isOn: $mapLayerPreferences.showsActualTrails)
                            .disabled(nearbyTrails.isEmpty)
                        Toggle("Previous runs", isOn: $mapLayerPreferences.showsPreviousRunsInLiveMap)
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                            .font(.headline)
                            .frame(width: liveControlWidth, height: liveControlWidth)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Map layers")

                    Divider()
                        .frame(width: 28)
                        .overlay(.primary.opacity(0.18))
                        .accessibilityHidden(true)

                    Button {
                        isFollowing = true
                        withAnimation(reduceMotion ? nil : BermsMotion.recenter) {
                            centerOnLastSampleIfNeeded(force: true)
                        }
                    } label: {
                        Image(systemName: isFollowing ? "location.fill" : "location")
                            .font(.headline)
                            .frame(width: liveControlWidth, height: liveControlWidth)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(isFollowing ? "Following GPS" : "Center GPS")
                }
                .padding(.vertical, 4)
                .frame(width: liveControlWidth)
                .glassEffect(.regular, in: .capsule)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 12)
            .padding(.trailing, liveControlsTrailingInset)
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") {
            showingSettings = true
        }
        .accessibilityIdentifier("settingsButton")
    }

    private var gpsEmptyTitle: String {
        switch recorder.locationAuthorization {
        case .denied, .restricted:
            return "Location is off"
        case .notDetermined:
            return "Allow location to record"
        default:
            return "Waiting for GPS"
        }
    }

    private var gpsEmptyMessage: String {
        switch recorder.locationAuthorization {
        case .denied, .restricted:
            return "Enable Location Services in Settings to record your route."
        case .notDetermined:
            return "Berms needs a location fix before it can draw your route."
        default:
            return "Keep the app open for a moment while GPS finds your position."
        }
    }

    private func openLocationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func centerOnLastSampleIfNeeded(force: Bool = false) {
        guard let coordinate = recorder.lastSample?.coordinate else { return }
        if !force,
           let lastFollowedCoordinate,
           lastFollowedCoordinate.distance(to: coordinate) < 250 {
            return
        }
        mapPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
            latitudinalMeters: 900,
            longitudinalMeters: 900
        ))
        lastFollowedCoordinate = coordinate
    }

    private var currentCoordinate: Coordinate? {
        recorder.lastSample?.coordinate
    }

    private var nearbyTrails: [Trail] {
        let catalogTrails = trailCatalogSelection.trails(trails, near: currentCoordinate)
        guard !trailCatalogSelection.isAutomatic else {
            guard let coordinate = currentCoordinate else { return [] }
            return catalogTrails.filter { trail in
                trail.points.count > 1 && trailDistance(from: coordinate, to: trail.points) <= 750
            }
        }

        // A manually selected resort is a deliberate map preview. Keep its
        // full catalog available even when the rider is somewhere else, so
        // panning from a city to the resort actually reveals the trails.
        return catalogTrails.filter { $0.points.count > 1 }
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

struct TrailLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Trail.updatedAt, order: .reverse) private var trails: [Trail]
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var mapCameraDistance: CLLocationDistance = .greatestFiniteMagnitude
    @State private var searchText = ""
    @State private var selectedDifficulty: TrailDifficulty?
    @State private var selectedTrailID: UUID?

    private var activeCatalog: TrailCatalogDescriptor {
        trailCatalogSelection.catalog(for: nil)
    }

    private var visibleTrails: [Trail] {
        let catalogTrails = trailCatalogSelection.trails(trails)
        return catalogTrails.filter { trail in
            let matchesSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || trail.name.localizedCaseInsensitiveContains(searchText)
                || trail.style.title.localizedCaseInsensitiveContains(searchText)
            let matchesDifficulty = selectedDifficulty == nil || trail.difficulty == selectedDifficulty
            return matchesSearch && matchesDifficulty
        }
    }

    private var mapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: visibleTrails.flatMap(\.points))
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryMap
                .frame(height: 350)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, BermsSpacing.content)
                .padding(.top, BermsSpacing.content)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: BermsSpacing.section) {
                    difficultyFilters

                    HStack(alignment: .firstTextBaseline) {
                        Text("Trails")
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text("\(visibleTrails.count) · \(activeCatalog.resortName)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.bermsMuted)
                    }

                    if visibleTrails.isEmpty {
                        ContentUnavailableView("No matching trails", systemImage: "map",
                                               description: Text("Try a different search or difficulty filter."))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(visibleTrails) { trail in
                            Button {
                                selectedTrailID = trail.id
                            } label: {
                                ProductionTrailLibraryRow(trail: trail,
                                                          isSelected: selectedTrailID == trail.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Highlights this trail on the map")
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, BermsSpacing.content, for: .scrollContent)
            .contentMargins(.vertical, BermsSpacing.content, for: .scrollContent)
        }
        .background(BermsBackground())
        .navigationTitle("Trail Library")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search trails")
    }

    @ViewBuilder
    private var libraryMap: some View {
        if visibleTrails.flatMap(\.points).isEmpty {
            VStack(spacing: BermsSpacing.compact) {
                Image(systemName: "map")
                    .font(.title2)
                Text("No trail geometry")
                    .font(.headline)
                Text("Trail routes will appear here when the catalog is available.")
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bermsCard)
        } else {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Map(position: $mapPosition, bounds: mapConfiguration?.bounds,
                        interactionModes: [.pan, .zoom], selection: $selectedTrailID) {
                        if mapLayerPreferences.showsActualTrails {
                            ForEach(visibleTrails) { trail in
                                if trail.points.count > 1 {
                                    trailMapContent(coordinates: trailCoordinates(for: trail),
                                                    difficulty: trail.difficulty,
                                                    color: selectedTrailID == trail.id ? Color.bermsTrail : nil,
                                                    tag: trail.id)
                                }
                            }

                            ForEach(Array(libraryLabelTrails)) { trail in
                                if let coordinate = trailLabelCoordinate(for: trail.points) {
                                    Annotation("", coordinate: coordinate) {
                                        TrailMapLabel(name: trail.name,
                                                      difficulty: trail.difficulty,
                                                      color: .bermsDifficulty(trail.difficulty))
                                    }
                                }
                            }
                        }
                    }
                    .mapStyle(.bermsMonochrome)
                    .mapControls { MapCompass() }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        mapCameraDistance = context.camera.distance
                    }

                }

                VStack(spacing: BermsSpacing.compact) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsRidePathControl: false,
                                  showsActualTrailsControl: true,
                                  actualTrailsAvailable: !visibleTrails.isEmpty,
                                  showsJumpsControl: false)
                    Button {
                        withAnimation(reduceMotion ? nil : BermsMotion.recenter) { recenterMap() }
                    } label: {
                        Image(systemName: "scope")
                            .font(.headline)
                            .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Recenter map")
                }
                .padding(BermsSpacing.control)
            }
            .onAppear { recenterMap() }
        }
    }

    private var difficultyFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BermsSpacing.compact) {
                difficultyFilter("All", difficulty: nil)
                ForEach(TrailDifficulty.allCases) { difficulty in
                    difficultyFilter(difficulty.title, difficulty: difficulty)
                }
            }
        }
    }

    private var libraryLabelTrails: [Trail] {
        guard let initialDistance = mapConfiguration?.initialDistance,
              initialDistance.isFinite,
              mapCameraDistance.isFinite,
              mapCameraDistance < initialDistance * 0.85 else {
            return Array(visibleTrails.prefix(12))
        }
        return visibleTrails
    }

    private func difficultyFilter(_ title: String, difficulty: TrailDifficulty?) -> some View {
        Button {
            selectedDifficulty = difficulty
        } label: {
            HStack(spacing: 6) {
                if let difficulty {
                    TrailRatingBadge(difficulty: difficulty)
                }
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .tint(selectedDifficulty == difficulty ? .bermsTrail : .bermsMuted)
        .accessibilityAddTraits(selectedDifficulty == difficulty ? .isSelected : [])
    }

    private func recenterMap() {
        mapPosition = mapConfiguration?.initialPosition ?? .automatic
        mapCameraDistance = mapConfiguration?.initialDistance ?? .greatestFiniteMagnitude
    }
}

private struct ProductionTrailLibraryRow: View {
    let trail: Trail
    let isSelected: Bool

    var body: some View {
        HStack(spacing: BermsSpacing.control) {
            TrailRatingBadge(difficulty: trail.difficulty, size: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(trail.name)
                    .font(.headline)
                Text("\(trail.difficulty.title) · \(trail.style.title) · \(BermsFormat.distance(distance))")
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
            }
            Spacer(minLength: 8)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(isSelected ? Color.bermsTrail : Color.bermsMuted)
                .accessibilityHidden(true)
        }
        .padding(BermsSpacing.control)
        .background(isSelected ? Color.bermsInset : Color.bermsCard,
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.bermsTrail, lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(trail.name), \(trail.difficulty.title) trail")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var distance: Double {
        zip(trail.points, trail.points.dropFirst()).reduce(0) { total, pair in
            let start = Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return total + start.distance(to: end)
        }
    }
}

#if DEBUG
struct TrailMappingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Trail.updatedAt, order: .reverse) private var trails: [Trail]
    @ObservedObject var mapper: TrailMapper
    @ObservedObject var recorder: RideRecorder
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var authoredMapCameraDistance: CLLocationDistance = .greatestFiniteMagnitude
    @State private var showingStartSheet = false
    @State private var showingDiscardConfirmation = false
    @State private var selectedTrail: Trail?
    @State private var selectedTrailID: UUID?

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
                .presentationDetents([.large, .medium])
        }
        .sheet(item: $selectedTrail) { trail in
            TrailEditorSheet(trail: trail, mapper: mapper)
                .presentationDetents([.large, .medium])
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
        .onChange(of: selectedTrailID) { _, trailID in
            guard let trailID,
                  let trail = visibleTrails.first(where: { $0.id == trailID }) else { return }
            selectedTrail = trail
            selectedTrailID = nil
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

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
                        trailMapContent(coordinates: trailCoordinates(for: mapper.activeTrailPoints),
                                        difficulty: mapper.activeDifficulty)
                    }
                }
                .mapStyle(.bermsMonochrome)
                .frame(maxWidth: .infinity, minHeight: 300)
                VStack(spacing: 8) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsActualTrailsControl: true,
                                  actualTrailsAvailable: mapper.activeTrailPoints.count > 1,
                                  showsJumpsControl: false)
                    recenterButton {
                        withAnimation(reduceMotion ? nil : BermsMotion.recenter) { recenterActiveMap() }
                    }
                }
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))

            VStack(alignment: .leading, spacing: 8) {
                Text(mapper.activeTrailName)
                    .font(.title3.weight(.bold))
                Text("\(mapper.activeDifficulty.title) · \(mapper.activeStyle.title) · \(BermsFormat.gpsPoints(mapper.activePoints.count))")
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
                Map(position: $mapPosition, bounds: authoredMapConfiguration?.bounds,
                    interactionModes: [.pan, .zoom], selection: $selectedTrailID) {
                    if mapLayerPreferences.showsActualTrails {
                        ForEach(visibleTrails) { trail in
                            if trail.points.count > 1 {
                                trailMapContent(coordinates: trailCoordinates(for: trail),
                                                difficulty: trail.difficulty,
                                                tag: trail.id)
                            }
                        }

                        ForEach(Array(authoredMapLabelTrails)) { trail in
                            if let coordinate = trailLabelCoordinate(for: trail.points) {
                                Annotation("", coordinate: coordinate) {
                                    TrailMapLabel(name: trail.name,
                                                  difficulty: trail.difficulty,
                                                  color: .bermsDifficulty(trail.difficulty))
                                }
                            }
                        }
                    }
                }
                .mapStyle(.bermsMonochrome)
                .onMapCameraChange(frequency: .onEnd) { context in
                    authoredMapCameraDistance = context.camera.distance
                }
                VStack(spacing: 8) {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsRidePathControl: false,
                                  showsActualTrailsControl: true,
                                  showsJumpsControl: false)
                    recenterButton {
                        withAnimation(reduceMotion ? nil : BermsMotion.recenter) { recenterAuthoredMap() }
                    }
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

    private var authoredMapLabelTrails: [Trail] {
        guard let initialDistance = authoredMapConfiguration?.initialDistance,
              initialDistance.isFinite,
              authoredMapCameraDistance.isFinite,
              authoredMapCameraDistance < initialDistance * 0.85 else {
            return Array(visibleTrails.prefix(10))
        }
        return visibleTrails
    }

    private func recenterAuthoredMap() {
        mapPosition = authoredMapConfiguration?.initialPosition ?? .automatic
        authoredMapCameraDistance = authoredMapConfiguration?.initialDistance ?? .greatestFiniteMagnitude
    }

    private func recenterActiveMap() {
        mapPosition = activeMapConfiguration?.initialPosition ?? .automatic
    }

    private func recenterButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "scope")
                .font(.headline)
                .frame(minWidth: 44, minHeight: 44)
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
            TrailRatingBadge(difficulty: trail.difficulty, size: 12)
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

    private var trailDistance: Double {
        zip(trail.points, trail.points.dropFirst()).reduce(0) { total, pair in
            let start = Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return total + start.distance(to: end)
        }
    }
}

private struct TrailEditorSheet: View {
    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
    }

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
    @State private var saveState = SaveState.idle

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
                            HStack(spacing: 8) {
                                TrailRatingBadge(difficulty: value, size: 12)
                                Text(value.title)
                            }
                            .tag(value)
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
                    Button(action: saveEdits) {
                        HStack(spacing: 8) {
                            switch saveState {
                            case .idle:
                                Label("Save changes", systemImage: "checkmark")
                            case .saving:
                                ProgressView()
                                    .tint(Color.bermsOnAccent)
                                Text("Saving…")
                            case .saved:
                                Label("Saved", systemImage: "checkmark.circle.fill")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.bermsTrail)
                    .foregroundStyle(Color.bermsOnAccent)
                    .disabled(saveState != .idle)
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

    private func saveEdits() {
        guard saveState == .idle else { return }
        saveState = .saving

        Task { @MainActor in
            // Give the button a frame to render its in-progress state even when
            // the local SwiftData save completes immediately.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            guard saveChanges() else {
                saveState = .idle
                return
            }

            saveState = .saved
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            dismiss()
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
                                HStack(spacing: 8) {
                                    TrailRatingBadge(difficulty: value, size: 12)
                                    Text(value.title)
                                }
                                .tag(value)
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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RideDay.startedAt, order: .reverse) private var days: [RideDay]
    @Binding private var pendingDayID: UUID?
    let onStartTracking: () -> Void
    @State private var dayToDelete: RideDay?
    @State private var editMode: EditMode = .inactive
    @State private var selectedDayIDs = Set<UUID>()
    @State private var showingBulkDeleteConfirmation = false
    @State private var navigationPath = NavigationPath()

    init(pendingDayID: Binding<UUID?> = .constant(nil),
         onStartTracking: @escaping () -> Void = {}) {
        self._pendingDayID = pendingDayID
        self.onStartTracking = onStartTracking
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                BermsBackground()
                if days.isEmpty {
                    VStack(spacing: BermsSpacing.section) {
                        ContentUnavailableView(
                            "No days",
                            systemImage: "mountain.2",
                            description: Text("Start tracking to build a day of runs, lifts, and jumps.")
                        )
                        Button("Track a ride", action: onStartTracking)
                            .buttonStyle(.borderedProminent)
                            .tint(.bermsTrail)
                            .foregroundStyle(Color.bermsOnAccent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    List(selection: $selectedDayIDs) {
                        ForEach(days) { day in
                            NavigationLink {
                                DayDetailView(day: day) { destination in
                                    navigationPath.append(destination)
                                }
                            } label: {
                                DayRow(day: day)
                            }
                            .tag(day.id)
                            .selectionDisabled(!day.isFinished)
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
                    .environment(\.editMode, $editMode)
                    .scrollContentBackground(.hidden)
                    .animation(reduceMotion ? nil : BermsMotion.content, value: days.map(\.id))
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : BermsMotion.content, value: days.isEmpty)
            .safeAreaInset(edge: .top, spacing: 0) {
                daysHeader
            }
            .toolbar(.hidden, for: .navigationBar)
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
            .onChange(of: days.map(\.id)) { _, ids in
                selectedDayIDs.formIntersection(ids)
                openPendingDayIfNeeded()
            }
            .onChange(of: editMode) { _, mode in
                if mode == .inactive {
                    selectedDayIDs.removeAll()
                }
            }
        }
        .environment(\.editMode, $editMode)
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
        .alert("Delete \(selectedDays.count) days?", isPresented: $showingBulkDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedDays()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the selected days, their runs, lifts, and map data.")
        }
    }

    private var daysHeader: some View {
        HStack(alignment: .center, spacing: BermsSpacing.control) {
            Text("Days")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: BermsSpacing.control)

            GlassEffectContainer(spacing: 0) {
                HStack(spacing: BermsSpacing.control) {
                    if editMode == .active && !selectedDays.isEmpty {
                        Button(role: .destructive) {
                            showingBulkDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .medium))
                                .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.regular)
                        .tint(.red)
                        .accessibilityLabel("Delete \(selectedDays.count) selected days")
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }

                    Button {
                        editMode = editMode == .active ? .inactive : .active
                    } label: {
                        Text(editMode == .active ? "Done" : "Edit")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityLabel(editMode == .active ? "Done editing days" : "Edit days")
                }
            }
            .animation(reduceMotion ? nil : BermsMotion.content, value: selectedDays.map(\.id))
        }
        .padding(.horizontal, BermsSpacing.content)
        .padding(.vertical, BermsSpacing.compact)
        .background(Color.bermsInk)
    }

    private var selectedDays: [RideDay] {
        days.filter { $0.isFinished && selectedDayIDs.contains($0.id) }
    }

    private func deleteSelectedDays() {
        let daysToDelete = selectedDays
        guard !daysToDelete.isEmpty else { return }

        let diagnosticURLs = daysToDelete.map { RideRecorder.debugLogURL(for: $0.id) }
        for day in daysToDelete {
            modelContext.delete(day)
        }
        try? modelContext.save()
        for diagnosticURL in diagnosticURLs {
            try? FileManager.default.removeItem(at: diagnosticURL)
        }
        selectedDayIDs.removeAll()
        editMode = .inactive
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
        HStack(spacing: BermsSpacing.control) {
            VStack(alignment: .leading, spacing: 5) {
                Text(day.displayName)
                    .font(.headline)
                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(Color.bermsMuted)
            }
            Spacer()
            Text(BermsFormat.duration(day.duration))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.bermsTrail)
        }
    }

    private var metadata: String {
        let stats = "\(day.segments.filter { $0.kind == .run }.count) runs  ·  \(BermsFormat.distance(day.distanceMeters))"
        guard day.hasCustomName else { return stats }
        return "\(day.startedAt.formatted(date: .abbreviated, time: .shortened))  ·  \(stats)"
    }
}

struct DayDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var showingNameEditor = false
    @State private var nameDraft = ""
    @State private var showingDeleteConfirmation = false

    init(day: RideDay, onRunSelected: @escaping (RunMapDestination) -> Void = { _ in }) {
        self.day = day
        self.onRunSelected = onRunSelected
    }

    private var runs: [RideSegment] {
        day.segments.filter { $0.kind == .run }.sorted { $0.startedAt < $1.startedAt }
    }

    private var mapSegments: [RideSegment] {
        day.segments
            .filter { $0.kind == .run || $0.kind == .lift }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private var matchedTrailOverlays: [TrailMapOverlay] {
        runs.flatMap { trailOverlays(for: $0, trails: activeTrails(for: $0)) }
    }

    private var visibleMapSegments: [RideSegment] {
        mapSegments.filter { $0.kind == .run || mapLayerPreferences.showsLiftPaths }
    }

    private var hasMatchedTrailOverlays: Bool {
        !matchedTrailOverlays.isEmpty
    }

    var body: some View {
        List {
            Section {
                summary
            }
            Section {
                dayMap
                    .listRowInsets(EdgeInsets())
            }
            Section("Runs") {
                if runs.isEmpty {
                    Text("No runs")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, segment in
                        NavigationLink {
                            RunMapView(number: index + 1, segment: segment)
                        } label: {
                            SegmentRow(number: index + 1, segment: segment,
                                       trailName: trailSequence(for: segment))
                        }
                    }
                }
            }
        }
        .navigationTitle(day.displayName)
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
        .sheet(isPresented: $showingNameEditor) {
            NavigationStack {
                Form {
                    TextField("Session name", text: $nameDraft)
                        .textInputAutocapitalization(.words)
                }
                .navigationTitle(day.hasCustomName ? "Edit name" : "Add name")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showingNameEditor = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveName()
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .onChange(of: selectedSegmentID) { _, segmentID in
            guard let segmentID,
                  let number = runs.firstIndex(where: { $0.id == segmentID }) else { return }
            onRunSelected(RunMapDestination(dayID: day.id, runID: segmentID, number: number + 1))
            selectedSegmentID = nil
        }
    }

    private func saveName() {
        day.setName(nameDraft)
        try? modelContext.save()
        showingNameEditor = false
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.control) {
            Text("Day summary")
                .font(.title2.weight(.bold))

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
                    SummaryStat(label: "Jumps", value: "\(day.jumpCount)", tint: .primary)
                }
            }
        }
    }

    @ViewBuilder
    private var dayMap: some View {
        if runs.isEmpty {
            VStack(spacing: BermsSpacing.compact) {
                Image(systemName: "map")
                    .font(.title2)
                Text("No route")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(Color.bermsCard, in: RoundedRectangle(cornerRadius: 22))
        } else {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Map(position: $mapPosition, bounds: mapConfiguration?.bounds,
                        interactionModes: [.pan, .zoom], selection: $selectedSegmentID) {
                        if mapLayerPreferences.showsRidePath {
                            ForEach(Array(runs.enumerated()), id: \.element.id) { index, segment in
                                if segment.points.count > 1 {
                                    MapPolyline(coordinates: coordinates(for: segment))
                                        .stroke(Color.gray.opacity(RideMapPresentation.summaryRunOpacity(
                                            index: index, count: runs.count)), lineWidth: 4)
                                        .tag(segment.id)
                                }
                            }
                            ForEach(Array(runs.enumerated()), id: \.element.id) { index, segment in
                                if let coordinate = coordinates(for: segment).first {
                                    Annotation("", coordinate: coordinate) {
                                        RunNumberMarker(number: index + 1,
                                                        isSelected: selectedSegmentID == segment.id)
                                            .onTapGesture { selectedSegmentID = segment.id }
                                    }
                                }
                            }
                        }
                        if mapLayerPreferences.showsLiftPaths {
                            ForEach(mapSegments.filter { $0.kind == .lift }) { segment in
                                if segment.points.count > 1 {
                                    MapPolyline(coordinates: coordinates(for: segment))
                                        .stroke(Color.bermsLift.opacity(0.78), style: StrokeStyle(
                                            lineWidth: 2.25, lineCap: .round, lineJoin: .round, dash: [5, 4]
                                        ))
                                }
                            }
                        }
                        if mapLayerPreferences.showsJumps {
                            ForEach(summaryMapJumps(for: runs)) { marker in
                                Annotation("", coordinate: marker.coordinate) {
                                    JumpMapMarker(number: marker.number, airtime: marker.airtime)
                                }
                            }
                        }
                        if mapLayerPreferences.showsActualTrails {
                            ForEach(Array(matchedTrailOverlays.prefix(12))) { overlay in
                                trailMapContent(coordinates: overlay.coordinates,
                                                difficulty: overlay.difficulty)
                                if let coordinate = trailLabelCoordinate(for: overlay.points) {
                                    Annotation("", coordinate: coordinate) {
                                        TrailMapLabel(name: overlay.name,
                                                      difficulty: overlay.difficulty,
                                                      color: overlay.color)
                                    }
                                }
                            }
                            ForEach(Array(matchedTrailOverlays.dropFirst(12))) { overlay in
                                trailMapContent(coordinates: overlay.coordinates,
                                                difficulty: overlay.difficulty)
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
                                  showsJumpsControl: !summaryMapJumps(for: runs).isEmpty,
                                  showsLiftPathsControl: true,
                                  liftPathsAvailable: mapSegments.contains { $0.kind == .lift })
                    recenterButton
                    Button { showingFullScreenMap = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.headline)
                            .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Open full-screen ride map")
                }
                .padding(BermsSpacing.control)
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .onAppear { recenterMap() }
            .fullScreenCover(isPresented: $showingFullScreenMap) {
                FullScreenSummaryMap(title: "Ride Map", segments: day.segments,
                                     trails: trails, focusedSegmentID: nil,
                                     focusedRunNumber: nil)
            }
        }
    }

    private var mapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: visibleMapSegments.flatMap(\.points))
    }

    private func trailSequence(for segment: RideSegment) -> String? {
        let coordinate = segment.points.first.map {
            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        return TrailSequenceResolver.title(for: segment, trails: activeTrails(for: segment, coordinate: coordinate))
    }

    private func activeTrails(for segment: RideSegment,
                              coordinate: Coordinate? = nil) -> [Trail] {
        let coordinate = coordinate ?? segment.points.first.map {
            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        return trailCatalogSelection.trails(trails, near: coordinate)
    }

    private func coordinates(for segment: RideSegment) -> [CLLocationCoordinate2D] {
        segment.points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let segments: [RideSegment]
    let trails: [Trail]
    let focusedSegmentID: UUID?
    let focusedRunNumber: Int?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
    @State private var mapPosition: MapCameraPosition = .automatic

    private var visibleSegments: [RideSegment] {
        if let focusedSegmentID {
            return segments.filter { $0.id == focusedSegmentID }
        }
        return segments
            .filter { $0.kind == .run || (mapLayerPreferences.showsLiftPaths && $0.kind == .lift) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private var mapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(points: visibleSegments.flatMap(\.points))
    }

    private var jumpMarkers: [SummaryMapJump] {
        summaryMapJumps(for: visibleSegments)
    }

    private var matchedTrailOverlays: [TrailMapOverlay] {
        visibleSegments.flatMap { segment in
            trailOverlays(for: segment, trails: trailsFor(segment))
        }
    }

    private var hasMatchedTrailOverlays: Bool {
        !matchedTrailOverlays.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Map(position: $mapPosition, bounds: mapConfiguration?.bounds,
                        interactionModes: [.pan, .zoom]) {
                        ForEach(Array(visibleSegments.enumerated()), id: \.element.id) { index, segment in
                            if segment.points.count > 1 {
                                if segment.kind == .lift {
                                    if mapLayerPreferences.showsLiftPaths {
                                        MapPolyline(coordinates: segment.points.map {
                                            CLLocationCoordinate2D(latitude: $0.latitude,
                                                                   longitude: $0.longitude)
                                        })
                                        .stroke(Color.bermsLift.opacity(0.78), style: StrokeStyle(
                                            lineWidth: 2.25, lineCap: .round, lineJoin: .round, dash: [5, 4]
                                        ))
                                    }
                                } else if mapLayerPreferences.showsRidePath {
                                    MapPolyline(coordinates: segment.points.map {
                                        CLLocationCoordinate2D(latitude: $0.latitude,
                                                               longitude: $0.longitude)
                                    })
                                    .stroke(focusedSegmentID == nil
                                            ? Color.gray.opacity(RideMapPresentation.summaryRunOpacity(
                                                index: index, count: visibleSegments.count))
                                            : Color.bermsTrail, lineWidth: 4)
                                }
                            }
                        }
                        ForEach(Array(visibleSegments.filter { $0.kind == .run }.enumerated()), id: \.element.id) { index, segment in
                            if let coordinate = segment.points.first.map({
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
                                  liftPathsAvailable: segments.contains { $0.kind == .lift })
                    Button {
                        withAnimation(reduceMotion ? nil : BermsMotion.recenter) { recenterMap() }
                    } label: {
                        Image(systemName: "scope")
                            .font(.headline)
                            .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.7))
                    .foregroundStyle(.white)
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

    private func recenterMap() {
        mapPosition = mapConfiguration?.initialPosition ?? .automatic
    }

    private func trailsFor(_ segment: RideSegment) -> [Trail] {
        let coordinate = segment.points.first.map {
            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        return trailCatalogSelection.trails(trails, near: coordinate)
    }

}

private struct TrailRatingBadge: View {
    let difficulty: TrailDifficulty
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 2) {
            ratingShape
            if difficulty == .doubleBlack {
                ratingShape
            }
        }
        .frame(width: difficulty == .doubleBlack ? (size * 2 + 2) : size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ratingShape: some View {
        let color = Color.bermsDifficulty(difficulty)
        switch difficulty {
        case .green:
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        case .blue:
            Rectangle()
                .fill(color)
                .frame(width: size, height: size)
        case .black, .doubleBlack:
            TrailDiamond()
                .fill(color)
                .frame(width: size, height: size)
                .overlay {
                    TrailDiamond()
                        .stroke(Color.bermsMuted.opacity(0.7), lineWidth: 0.75)
                }
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
            .overlay(Capsule().stroke(color.opacity(0.65), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .accessibilityLabel("\(name), \(difficulty.title) trail")
            .allowsHitTesting(false)
    }
}

private struct SummaryMapJump: Identifiable {
    let id = UUID()
    let number: Int
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
                number: index + 1,
                label: "Jump \(index + 1)",
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                airtime: jump.airtime
            )
        }
    }
}

struct RunMapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    private var activeTrails: [Trail] {
        let coordinate = routePoints.first.map {
            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        return trailCatalogSelection.trails(trails, near: coordinate)
    }

    private var matchedTrailOverlays: [TrailMapOverlay] {
        trailOverlays(for: segment, trails: activeTrails)
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
                            .buttonStyle(.borderedProminent)
                            .tint(.black.opacity(0.7))
                            .foregroundStyle(.white)
                            .accessibilityLabel("Open full-screen run map")
                        }
                        .padding(BermsSpacing.control)
                    }
                    .frame(minHeight: 380, idealHeight: 460, maxHeight: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    RunStatsCard(segment: segment)

                    TrailSequenceCard(sequence: trailSequence, runNumber: number)
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, BermsSpacing.content, for: .scrollContent)
                .contentMargins(.vertical, BermsSpacing.content, for: .scrollContent)
                .fullScreenCover(isPresented: $showingFullScreenMap) {
                    FullScreenSummaryMap(title: trailSequence, segments: [segment],
                                         trails: trails, focusedSegmentID: segment.id,
                                         focusedRunNumber: number)
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
        return TrailSequenceResolver.title(for: segment, trails: activeTrails) ?? "Trail not identified"
    }

    private var recenterButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : BermsMotion.recenter) { recenterMap() }
        } label: {
            Image(systemName: "scope")
                .font(.headline)
                .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
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

private struct RunStatsCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let segment: RideSegment

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.control) {
            Text("Run stats")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: BermsSpacing.content) {
                SummaryStat(label: "Duration", value: BermsFormat.duration(segment.duration))
                SummaryStat(label: "Distance", value: BermsFormat.distance(segment.distanceMeters))
                SummaryStat(label: "Descent", value: BermsFormat.elevation(segment.verticalMeters))
                SummaryStat(label: "Top speed", value: BermsFormat.speed(segment.maximumSpeedMetersPerSecond))
                SummaryStat(label: "Jumps", value: "\(segment.jumps.count)")
                SummaryStat(label: "Best airtime", value: segment.jumps.isEmpty
                            ? "—"
                            : BermsFormat.airtime(segment.jumps.map(\.airtime).max() ?? 0))
            }
        }
        .padding(BermsSpacing.content)
        .accessibilityElement(children: .contain)
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
    let initialDistance: CLLocationDistance
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
            latitudinalMeters: max(2_500, cameraLatitudeMeters * 3.0),
            longitudinalMeters: max(2_500, cameraLongitudeMeters * 3.0)
        )

        initialPosition = .region(cameraRegion)
        initialDistance = largestSpan
        bounds = MapCameraBounds(
            centerCoordinateBounds: boundsRegion,
            minimumDistance: max(60, largestSpan * 0.08),
            maximumDistance: max(20_000, largestSpan * 8)
        )
    }
}

private struct TrailSequenceCard: View {
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
    var trailName: String?

    init(number: Int, segment: RideSegment, trailName: String? = nil) {
        self.number = number
        self.segment = segment
        self.trailName = trailName
    }

    var body: some View {
        AdaptiveStatRow {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .accessibilityLabel("Run \(number)")
            VStack(alignment: .leading, spacing: 3) {
                Text(trailName ?? "Trail not identified")
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
        }
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

    static func gpsPoints(_ count: Int) -> String {
        "\(count) GPS point\(count == 1 ? "" : "s")"
    }

    static func elevation(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return elevation(meters)
    }

    static func elevation(_ meters: Double) -> String {
        isMetric ? String(format: "%.0f m", meters) : String(format: "%.0f ft", meters * 3.28084)
    }
}
