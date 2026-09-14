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
            .navigationSubtitle(recorder.isRecording
                                ? Text("")
                                : Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                    + Text(" · Beta"))
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
            Button("Finish") {
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
                        Image(systemName: "mountain.2.fill")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(Color.bermsTrail)
                            .accessibilityHidden(true)
                        Text("Ready to track")
                            .font(.title2.weight(.semibold))
                        Text("Track runs, lifts, and routes.")
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
                .frame(maxWidth: .infinity,
                       minHeight: geometry.size.height,
                       alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var recordingContent: some View {
        GeometryReader { geometry in
            let panelHeight = min(liveStatsHeight, max(0, geometry.size.height * 0.65))
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
                            if recorder.locationAuthorization == .denied || recorder.locationAuthorization == .restricted {
                                Button("Open Settings", action: openLocationSettings)
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: max(0, geometry.size.height - panelHeight - BermsSpacing.content))
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
        }
    }

    private var liveStatsOverlay: some View {
        VStack(spacing: BermsSpacing.control) {
            AdaptiveStatRow {
                Label(recorder.isPaused ? "Paused" : "Recording",
                      systemImage: recorder.isPaused ? "pause.circle.fill" : "record.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(BermsFormat.duration(recorder.elapsed(at: timeline.date)))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .accessibilityLabel("Elapsed time")
                        .accessibilityValue(BermsFormat.duration(recorder.elapsed(at: timeline.date)))
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

            AdaptiveStatRow {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Label(gpsStatusText(at: timeline.date), systemImage: "location.fill")
                        .font(.caption)
                        .foregroundStyle(recorder.locationAuthorization == .denied
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
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
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
            Label(needsLocationPermission ? "Allow Location" : "Start",
                  systemImage: needsLocationPermission ? "location.fill" : "play.fill")
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
        Map(position: $mapPosition, scope: mapScope) {
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
        .overlay(alignment: .topTrailing) {
            MapControlStack {
                MapLayersMenu(preferences: mapLayerPreferences,
                              actualTrailsAvailable: !nearbyTrails.isEmpty,
                              showsJumpsControl: false,
                              showsPreviousRunsControl: true)
                MapUserLocationButton(scope: mapScope)
                MapCompass(scope: mapScope)
            }
            .padding(.top, BermsSpacing.control)
            .padding(.trailing, BermsSpacing.content)
        }
        .mapScope(mapScope)
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
