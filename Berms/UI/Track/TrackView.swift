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
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var mapWasBackgrounded = false
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
                recenterMapPosition()
            }
        }
        // The live map leaves the hierarchy while the app is backgrounded, so
        // the camera is rebuilt on the way back. Assert the follow position
        // again, otherwise reopening the app leaves the map where MapKit last
        // put it instead of on the rider.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                mapWasBackgrounded = true
            case .active:
                guard mapWasBackgrounded, recorder.isRecording else { return }
                mapWasBackgrounded = false
                recenterMapPosition()
            default:
                break
            }
        }
        .onChange(of: isPreviewingResort) { _, _ in
            recenterMapPosition()
        }
        .onChange(of: trailCatalogSelection.manualCatalogID) { _, _ in
            recenterMapPosition()
        }
        .onAppear {
            // Preview framing only. A rider who panned the live map keeps it.
            guard isPreviewingResort else { return }
            recenterMapPosition()
        }
    }

    /// Follows the rider, or frames the selected resort while previewing one
    /// the rider is not standing in.
    private func recenterMapPosition() {
        if isPreviewingResort, let configuration = liveMapConfiguration {
            withAnimation(reduceMotion ? nil : BermsMotion.recenter) {
                mapPosition = configuration.initialPosition
            }
            visibleRegion = configuration.framingRegion
        } else {
            mapPosition = .userLocation(
                followsHeading: mapPosition.followsUserHeading,
                fallback: .automatic)
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

    /// The resort the rider is standing in, from GPS.
    private var riderResort: ResortDescriptor? {
        guard let coordinate = currentCoordinate else { return nil }
        return TrailCatalogRegistry.resort(containing: coordinate)
    }

    /// The resort chosen in Settings, when it matches the activity season.
    private var selectedCatalog: TrailCatalogDescriptor? {
        guard let manualID = trailCatalogSelection.manualCatalogID,
            let catalog = TrailCatalogRegistry.catalog(withID: manualID),
            catalog.season == recorder.activeActivityMode.season
        else { return nil }
        return catalog
    }

    /// Outside every resort the selection previews that resort, so a rider can
    /// line up trails before they arrive. Inside a resort GPS always wins, and a
    /// rider who is recording always follows their own position.
    private var isPreviewingResort: Bool {
        !recorder.isRecording && riderResort == nil && selectedCatalog != nil
    }

    private var liveCatalog: TrailCatalogDescriptor? {
        if riderResort != nil {
            return TrailCatalogRegistry.catalog(
                for: recorder.activeActivityMode,
                coordinate: currentCoordinate)
        }
        return selectedCatalog
    }

    /// Only bound the camera to a resort the rider is actually looking at:
    /// the previewed one, or the one they are standing in.
    private var liveResort: ResortDescriptor? {
        if isPreviewingResort {
            guard let catalog = selectedCatalog else { return nil }
            return TrailCatalogRegistry.resort(withID: catalog.resortID)
        }
        return riderResort
    }

    private var liveMapConfiguration: RouteMapConfiguration? {
        RouteMapConfiguration(
            points: isPreviewingResort ? [] : liveMapPaths.flatMap(\.points),
            boundary: liveResort?.boundary)
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
                ForEach(renderedTrails) { trail in
                    trailMapContent(coordinates: trailCoordinates(for: trail), difficulty: trail.difficulty)
                }
                ForEach(labeledTrails) { trail in
                    if let coordinate = TrailGeometryStore.shared.metrics(for: trail).labelCoordinate {
                        Annotation(
                            "",
                            coordinate: CLLocationCoordinate2D(
                                latitude: coordinate.latitude,
                                longitude: coordinate.longitude)
                        ) {
                            TrailMapLabel(
                                name: trail.name,
                                difficulty: trail.difficulty,
                                color: .bermsDifficulty(trail.difficulty))
                        }
                    }
                }
            }
        }
        .mapStyle(.bermsMonochrome)
        .mapControls { MapScaleView() }
        .ignoresSafeArea()
        .onMapCameraChange(frequency: .onEnd) { context in
            // The map reports the previous framing after a resort change, and
            // trusting it culls every trail.
            guard liveMapConfiguration?.contains(cameraRegion: context.region) ?? true else { return }
            visibleRegion = context.region
        }
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
            if isPreviewingResort {
                MapActionButton(title: "Show resort", systemImage: "mountain.2") {
                    recenterMapPosition()
                }
            } else {
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
        guard let catalog = liveCatalog else { return [] }
        let catalogTrails = TrailCatalogRegistry.trails(trails, for: catalog)
        guard !isPreviewingResort, let coordinate = currentCoordinate else {
            return catalogTrails.filter { TrailGeometryStore.shared.metrics(for: $0).hasGeometry }
        }
        // Bounds first, so only the trails around the rider get an exact
        // distance over every point.
        return
            catalogTrails
            .compactMap { trail -> (trail: Trail, distance: Double)? in
                let metrics = TrailGeometryStore.shared.metrics(for: trail)
                guard let bounds = metrics.bounds,
                    bounds.contains(coordinate, paddingMeters: 750)
                else { return nil }
                let distance = trailDistance(from: coordinate, to: trail.points)
                guard distance <= 750 else { return nil }
                return (trail, distance)
            }
            .sorted { $0.distance < $1.distance }
            .map(\.trail)
    }

    /// Trails on screen, so a resort-wide view never builds overlays for the
    /// whole catalog.
    private var renderedTrails: [Trail] {
        guard let visibleRegion else { return nearbyTrails }
        return nearbyTrails.filter { trail in
            let metrics = TrailGeometryStore.shared.metrics(for: trail)
            guard let bounds = metrics.bounds, metrics.hasGeometry else { return false }
            return trailBoundsIntersect(bounds, region: visibleRegion)
        }
    }

    /// Names only appear once the rider zooms in past a resort-wide view, and
    /// only for trails on screen. Hundreds of trails would otherwise stack
    /// pills across the whole map.
    private var labeledTrails: [Trail] {
        guard let visibleRegion, regionSpanMeters(visibleRegion) <= 2_000 else { return [] }
        let center = Coordinate(
            latitude: visibleRegion.center.latitude,
            longitude: visibleRegion.center.longitude)
        return
            trailMapLabelRepresentatives(renderedTrails)
            .compactMap { trail -> (trail: Trail, distance: Double)? in
                guard let coordinate = TrailGeometryStore.shared.metrics(for: trail).labelCoordinate,
                    coordinateIsVisible(coordinate, in: visibleRegion)
                else { return nil }
                return (trail, center.distance(to: coordinate))
            }
            .sorted { $0.distance < $1.distance }
            .prefix(TrailMapRendering.labelLimit)
            .map(\.trail)
    }

    private func coordinateIsVisible(
        _ coordinate: Coordinate,
        in region: MKCoordinateRegion
    ) -> Bool {
        let halfLatitude = region.span.latitudeDelta / 2
        let halfLongitude = region.span.longitudeDelta / 2
        return abs(coordinate.latitude - region.center.latitude) <= halfLatitude
            && abs(coordinate.longitude - region.center.longitude) <= halfLongitude
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
