import MapKit
import SwiftData
import SwiftUI
import UIKit

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
                TrailStartSheet(
                    trails: visibleTrails, mapper: mapper,
                    defaultResort: activeCatalog.resortName
                )
                .presentationDetents([.large, .medium])
            }
            .sheet(item: $selectedTrail) { trail in
                TrailEditorSheet(trail: trail, mapper: mapper)
                    .presentationDetents([.large, .medium])
            }
            .alert(
                "Mapping issue",
                isPresented: Binding(
                    get: { mapper.errorMessage != nil },
                    set: { if !$0 { mapper.errorMessage = nil } }
                )
            ) {
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
                    let trail = visibleTrails.first(where: { $0.id == trailID })
                else { return }
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
                    Map(
                        position: $mapPosition, bounds: activeMapConfiguration?.bounds,
                        interactionModes: [.pan, .zoom]
                    ) {
                        if mapLayerPreferences.showsRidePath, mapper.activeRoutePoints.count > 1 {
                            MapPolyline(
                                coordinates: mapper.activeRoutePoints.map {
                                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                                }
                            )
                            .stroke(Color.bermsTrail, lineWidth: 5)
                        }
                        if mapLayerPreferences.showsActualTrails,
                            mapper.activeTrailPoints.count > 1
                        {
                            trailMapContent(
                                coordinates: trailCoordinates(for: mapper.activeTrailPoints),
                                difficulty: mapper.activeDifficulty)
                        }
                    }
                    .mapStyle(.bermsMonochrome)
                    .frame(maxWidth: .infinity, minHeight: 300)
                    VStack(spacing: 8) {
                        MapLayersMenu(
                            preferences: mapLayerPreferences,
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
                    Text(
                        "\(mapper.activeDifficulty.title) · \(mapper.activeStyle.title) · \(BermsFormat.gpsPoints(mapper.activePoints.count))"
                    )
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
                    Map(
                        position: $mapPosition, bounds: authoredMapConfiguration?.bounds,
                        interactionModes: [.pan, .zoom], selection: $selectedTrailID
                    ) {
                        if mapLayerPreferences.showsActualTrails {
                            ForEach(visibleTrails) { trail in
                                if trail.points.count > 1 {
                                    trailMapContent(
                                        coordinates: trailCoordinates(for: trail),
                                        difficulty: trail.difficulty,
                                        tag: trail.id)
                                }
                            }

                            ForEach(Array(authoredMapLabelTrails)) { trail in
                                if let coordinate = trailLabelCoordinate(for: trail.points) {
                                    Annotation("", coordinate: coordinate) {
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
                    .onMapCameraChange(frequency: .onEnd) { context in
                        authoredMapCameraDistance = context.camera.distance
                    }
                    VStack(spacing: 8) {
                        MapLayersMenu(
                            preferences: mapLayerPreferences,
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
                authoredMapCameraDistance < initialDistance * 0.85
            else {
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
            .bermsMapControl()
            .accessibilityLabel("Recenter map")
        }
    }

    struct TrailLibraryRow: View {
        let trail: Trail

        var body: some View {
            HStack(spacing: 12) {
                TrailRatingBadge(difficulty: trail.difficulty, size: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(trail.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(
                        "\(trail.resort) · \(trail.difficulty.title) · \(trail.style.title) · \(trail.passCount) pass\(trail.passCount == 1 ? "" : "es") · \(BermsFormat.distance(trailDistance))"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    struct TrailEditorSheet: View {
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
                        Text(
                            "The imported centerline is the first pass. New GPS passes are added and averaged with it."
                        )
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
            .alert(
                "Trail update failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
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
            if mapper.start(
                existingTrail: trail,
                name: trail.name,
                difficulty: trail.difficulty,
                style: trail.style)
            {
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

    struct TrailStartSheet: View {
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
                        Text(
                            "Start at the top. New trails are assigned to \(defaultResort); you can override it if needed."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        Button("Start segment") {
                            let trail = selectedTrail
                            let started = mapper.start(
                                existingTrail: trail,
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
