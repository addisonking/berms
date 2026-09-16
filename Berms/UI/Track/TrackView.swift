import MapKit
import SwiftData
import SwiftUI
import UIKit

struct TrackView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var recorder: RideRecorder
    @Query private var trails: [Trail]
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
    @Namespace private var mapScope
    @State private var mapPosition: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
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
            .navigationBarTitleDisplayMode(recorder.isRecording ? .inline : .large)
            .navigationSubtitle(
                recorder.isRecording
                    ? Text("")
                    : Text("\(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())) · Beta")
            )
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarVisibility(recorder.isRecording ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                        activityModePicker
                        settingsButton
                    }
                }
            }
            .animation(reduceMotion ? nil : BermsMotion.content, value: recorder.isRecording)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(recorder: recorder)
        }
        .alert("Finish session?", isPresented: $showingStopConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Finish") {
                guard let finishedDay = recorder.stop() else { return }
                BermsMotion.recordingFeedback()
                onDayFinished(finishedDay)
            }
        }
        .alert(
            "Unfinished ride",
            isPresented: Binding(
                get: { recorder.needsRecoveryPrompt },
                set: { _ in }
            )
        ) {
            Button("Resume") { recorder.resumePendingSession() }
            Button("Discard", role: .destructive) { recorder.discardPendingSession() }
        } message: {
            Text("Berms found a ride that was not finished. Resume it or discard the saved data.")
        }
        .alert(
            "Recording issue",
            isPresented: Binding(
                get: { recorder.errorMessage != nil },
                set: { if !$0 { recorder.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
        .onChange(of: recorder.isRecording) { _, recording in
            if recording {
                mapPosition = .userLocation(followsHeading: false, fallback: .automatic)
            }
        }
    }

    private var readyContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: BermsSpacing.section) {
                    VStack(spacing: BermsSpacing.compact) {
                        Image(systemName: recorder.selectedActivityMode.systemImage)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(Color.bermsTrail)
                            .accessibilityHidden(true)
                        Text(recorder.selectedActivityMode.readyTitle)
                            .font(.title2.weight(.semibold))
                        Text(recorder.selectedActivityMode.readyDescription)
                            .font(.subheadline)
                            .foregroundStyle(Color.bermsMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }

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
                        Button("Open Settings", action: openLocationSettings)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
                .padding(.horizontal, BermsSpacing.content)
                .padding(.vertical, BermsSpacing.section)
                .frame(
                    maxWidth: .infinity,
                    minHeight: geometry.size.height,
                    alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var recordingContent: some View {
        GeometryReader { geometry in
            let panelHeight = min(liveStatsHeight, max(0, geometry.size.height * 0.65))
            let statusAreaHeight = max(0, geometry.size.height - panelHeight - BermsSpacing.content)
            ZStack(alignment: .bottom) {
                // MapKit keeps rendering offscreen while the app records in the
                // background, which balloons memory until iOS jetsams the app.
                // The map is not visible then, so leave it out of the hierarchy.
                if scenePhase == .background {
                    BermsBackground()
                } else if recorder.lastSample == nil {
                    ScrollView {
                        ContentUnavailableView {
                            Label(gpsEmptyTitle, systemImage: "location.slash")
                        } description: {
                            Text(gpsEmptyMessage)
                        } actions: {
                            if recorder.locationAuthorization == .denied
                                || recorder.locationAuthorization == .restricted
                            {
                                Button("Open Settings", action: openLocationSettings)
                                    .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: statusAreaHeight)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: statusAreaHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    liveMap
                }

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
                .frame(height: panelHeight)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .padding(.horizontal, BermsSpacing.content)
                .padding(.bottom, BermsSpacing.content)
            }
            .overlay(alignment: .topTrailing) {
                liveMapControls
            }
        }
    }

    private var liveStatsOverlay: some View {
        let run = recorder.currentRunMetrics
        let runTitle =
            run.map {
                recorder.activeSegmentKind == .run ? "Run \($0.number)" : "Last run \($0.number)"
            } ?? "Waiting for a run"
        let bestJump = run?.longestJumpAirtime ?? 0

        return VStack(spacing: BermsSpacing.control) {
            AdaptiveStatRow {
                Label(
                    runTitle,
                    systemImage: recorder.isPaused ? "pause.circle.fill" : "record.circle"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityValue(recorder.isPaused ? "Paused" : "Recording")
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text("Session \(BermsFormat.duration(recorder.elapsed(at: timeline.date)))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel("Session time")
                        .accessibilityValue(BermsFormat.duration(recorder.elapsed(at: timeline.date)))
                }
            }

            VStack(spacing: BermsSpacing.control) {
                AdaptiveStatRow {
                    SummaryStat(
                        animatesValue: true, numericValue: true, label: "Top speed",
                        value: run.map { BermsFormat.speed($0.topSpeedMetersPerSecond) } ?? "—")
                    SummaryStat(
                        animatesValue: true, numericValue: true, label: "Best jump",
                        value: bestJump > 0 ? BermsFormat.airtime(bestJump) : "—"
                    )
                    .accessibilityLabel("Best jump airtime")
                }
                AdaptiveStatRow {
                    SummaryStat(
                        animatesValue: true, numericValue: true, label: "Jumps",
                        value: run?.jumpCount.map { String($0) } ?? "—")
                    SummaryStat(
                        animatesValue: true, numericValue: true, label: "Distance",
                        value: run.map { BermsFormat.distance($0.distanceMeters) } ?? "—")
                }
            }

            AdaptiveStatRow {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Label(gpsStatusText(at: timeline.date), systemImage: "location.fill")
                        .font(.caption)
                        .foregroundStyle(
                            recorder.locationAuthorization == .denied
                                || recorder.locationAuthorization == .restricted
                                ? .red : Color.bermsMuted)
                }
                if !recorder.motionAvailable {
                    Text("Motion off")
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
                    Label(
                        recorder.isPaused ? "Resume" : "Pause",
                        systemImage: recorder.isPaused ? "play.fill" : "pause.fill"
                    )
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
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, BermsSpacing.content)
        .padding(.vertical, BermsSpacing.content)

    }

    private func gpsStatusText(at date: Date) -> String {
        if recorder.isPaused { return "GPS paused" }
        switch recorder.locationAuthorization {
        case .denied, .restricted:
            return "GPS off — check Settings"
        case .notDetermined:
            return "Allow location to record"
        default:
            guard let sample = recorder.lastSample else { return "Waiting for GPS" }
            return date.timeIntervalSince(sample.timestamp) > 15 ? "GPS signal lost" : "GPS on"
        }
    }

    private var startButton: some View {
        let needsLocationPermission = recorder.locationAuthorization == .notDetermined

        return Button {
            if needsLocationPermission {
                recorder.requestPermissionsIfNeeded()
            } else if recorder.start() {
                BermsMotion.recordingFeedback()
            }
        } label: {
            Label(
                needsLocationPermission ? "Allow Location" : recorder.selectedActivityMode.startTitle,
                systemImage: needsLocationPermission ? "location.fill" : "play.fill"
            )
            .foregroundStyle(Color.bermsOnAccent)
            .font(.headline)
            .frame(maxWidth: 260)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.bermsTrail)
        .controlSize(.large)
        .disabled(
            recorder.locationAuthorization == .denied
                || recorder.locationAuthorization == .restricted)
    }

    private var currentResort: ResortDescriptor? {
        if let coordinate = currentCoordinate,
            let resort = TrailCatalogRegistry.resort(containing: coordinate)
        {
            return resort
        }
        guard !trailCatalogSelection.isAutomatic,
            let catalog = trailCatalogSelection.catalog(for: recorder.activeActivityMode)
        else { return nil }
        return TrailCatalogRegistry.resort(withID: catalog.resortID)
    }

    private var liveMapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(
            points: liveMapPaths.flatMap(\.points),
            boundary: currentResort?.boundary)
    }

    private var liveMap: some View {
        Map(
            position: $mapPosition, bounds: liveMapConfiguration?.bounds,
            interactionModes: [.pan, .zoom, .rotate], scope: mapScope
        ) {
            UserAnnotation()
            if mapLayerPreferences.showsRidePath {
                ForEach(Array(liveMapPaths.enumerated()), id: \.offset) { _, path in
                    MapPolyline(coordinates: trailCoordinates(for: path.points))
                        .stroke(color(for: path.role), lineWidth: path.role == .previousRun ? 3 : 5)
                }
            }
            if mapLayerPreferences.showsActualTrails {
                ForEach(nearbyTrails) { trail in
                    if trail.points.count > 1 {
                        trailMapContent(coordinates: trailCoordinates(for: trail), difficulty: trail.difficulty)
                    }
                }
            }
        }
        .mapStyle(.bermsMonochrome)
        .mapControls { MapScaleView() }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            MapCompass(scope: mapScope)
                .padding(BermsSpacing.content)
        }
        .mapScope(mapScope)
    }

    private var liveMapControls: some View {
        MapControlStack {
            MapLayersMenu(
                preferences: mapLayerPreferences,
                actualTrailsAvailable: !nearbyTrails.isEmpty,
                showsJumpsControl: false,
                showsPreviousRunsControl: true,
                onSettings: { showingSettings = true })
            MapActionButton(
                title: "My location",
                systemImage: mapPosition.followsUserLocation ? "location.fill" : "location"
            ) {
                withAnimation(reduceMotion ? nil : BermsMotion.recenter) {
                    mapPosition = .userLocation(
                        followsHeading: !mapPosition.followsUserHeading
                            && mapPosition.followsUserLocation,
                        fallback: .automatic)
                }
            }
            .accessibilityValue(
                mapPosition.followsUserHeading
                    ? "Following heading"
                    : mapPosition.followsUserLocation ? "Following location" : "Not following")
        }
        .padding(.top, BermsSpacing.control)
        .padding(.trailing, BermsSpacing.content)
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") {
            showingSettings = true
        }
        .accessibilityIdentifier("settingsButton")
    }

    private var activityModeBinding: Binding<ActivityMode> {
        Binding(
            get: { recorder.selectedActivityMode },
            set: { recorder.setSelectedActivityMode($0) }
        )
    }

    private var activityModePicker: some View {
        Picker(selection: activityModeBinding) {
            ForEach(ActivityMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage)
                    .tag(mode)
            }
        } label: {
            Image(systemName: recorder.selectedActivityMode.systemImage)
                .frame(width: BermsSpacing.target, height: BermsSpacing.target)
                .contentShape(.rect)
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Activity mode")
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

    private var currentCoordinate: Coordinate? {
        recorder.lastSample?.coordinate
    }

    private var nearbyTrails: [Trail] {
        let catalogTrails = trailCatalogSelection.trails(
            trails,
            mode: recorder.activeActivityMode,
            near: currentCoordinate
        )
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
