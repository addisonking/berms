import MapKit
import SwiftData
import SwiftUI
import UIKit

enum TrailLibrarySort: String, CaseIterable, Identifiable {
    case difficulty
    case name
    case length
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .difficulty: "Difficulty"
        case .name: "Name"
        case .length: "Length"
        case .recent: "Recently updated"
        }
    }
}

private struct TrailLibrarySection: Identifiable {
    let id: String
    let title: String?
    let trails: [Trail]
}

struct TrailLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Trail.updatedAt, order: .reverse) private var trails: [Trail]
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
    @Namespace private var mapScope
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var searchText = ""
    @State private var selectedDifficulty: TrailDifficulty?
    @State private var selectedTrailID: UUID?
    @State private var sort: TrailLibrarySort = .difficulty
    @State private var visibleRegion: MKCoordinateRegion?

    private var activeCatalog: TrailCatalogDescriptor {
        trailCatalogSelection.browseCatalog
    }

    private var selectableCatalogs: [TrailCatalogDescriptor] {
        var seenResortNames: Set<String> = []
        return TrailCatalogRegistry.catalogs.filter { seenResortNames.insert($0.resortName).inserted }
    }

    private var catalogSelection: Binding<String> {
        Binding(
            get: { activeCatalog.id },
            set: { trailCatalogSelection.setSelectionID($0) })
    }

    private var visibleTrails: [Trail] {
        let catalogTrails = trailCatalogSelection.trails(trails)
        return catalogTrails.filter { trail in
            let matchesSearch =
                searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || trail.name.localizedCaseInsensitiveContains(searchText)
                || trail.style.title.localizedCaseInsensitiveContains(searchText)
            let matchesDifficulty = selectedDifficulty == nil || trail.difficulty == selectedDifficulty
            return matchesSearch && matchesDifficulty
        }
    }

    private var sortedTrails: [Trail] {
        switch sort {
        case .difficulty, .name:
            return visibleTrails.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .length:
            return visibleTrails.sorted {
                TrailGeometryStore.shared.metrics(for: $0).distanceMeters
                    > TrailGeometryStore.shared.metrics(for: $1).distanceMeters
            }
        case .recent:
            return visibleTrails.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private var sections: [TrailLibrarySection] {
        let trails = sortedTrails
        guard sort == .difficulty else {
            guard !trails.isEmpty else { return [] }
            return [TrailLibrarySection(id: "all", title: nil, trails: trails)]
        }
        return TrailDifficulty.allCases.compactMap { difficulty in
            let matching = trails.filter { $0.difficulty == difficulty }
            guard !matching.isEmpty else { return nil }
            return TrailLibrarySection(
                id: difficulty.rawValue,
                title: "\(difficulty.title) · \(matching.count)",
                trails: matching)
        }
    }

    /// Off-screen trails are skipped so a several-hundred-trail catalog does
    /// not build every overlay on every camera move.
    private var renderedTrails: [Trail] {
        guard let visibleRegion else { return visibleTrails }
        return visibleTrails.filter { trail in
            let metrics = TrailGeometryStore.shared.metrics(for: trail)
            guard let bounds = metrics.bounds, metrics.hasGeometry else { return false }
            return trailBoundsIntersect(bounds, region: visibleRegion)
        }
    }

    private var visibleBounds: GeoBounds? {
        visibleTrails.compactMap { TrailGeometryStore.shared.metrics(for: $0).bounds }
            .reduce(nil as GeoBounds?) { total, bounds in
                total.map { $0.union(bounds) } ?? bounds
            }
    }

    private var mapConfiguration: RouteMapConfiguration? {
        guard let visibleBounds else { return nil }
        return RouteMapConfiguration(
            bounds: visibleBounds,
            boundary: TrailCatalogRegistry.resort(withID: activeCatalog.resortID)?.boundary)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    libraryMap
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                        .id("libraryMap")
                }
                Section {
                    Picker("Difficulty", selection: $selectedDifficulty) {
                        Text("All").tag(Optional<TrailDifficulty>.none)
                        ForEach(TrailDifficulty.allCases) { difficulty in
                            Text(difficulty.title).tag(Optional(difficulty))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                if visibleTrails.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No matching trails", systemImage: "map",
                            description: Text("Try a different search or difficulty filter."))
                    }
                } else {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.trails) { trail in
                                Button {
                                    selectedTrailID = trail.id
                                    withAnimation(reduceMotion ? nil : BermsMotion.recenter) {
                                        proxy.scrollTo("libraryMap", anchor: .top)
                                    }
                                } label: {
                                    ProductionTrailLibraryRow(
                                        trail: trail,
                                        isSelected: selectedTrailID == trail.id)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Shows this trail on the map")
                            }
                        } header: {
                            Text(section.title ?? "\(visibleTrails.count) trails · \(activeCatalog.resortName)")
                        }
                    }
                }
            }
            .listSectionSpacing(.compact)
        }
        .navigationTitle(activeCatalog.resortName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search trails")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Resort", selection: catalogSelection) {
                        ForEach(selectableCatalogs) { catalog in
                            Text(catalog.resortName).tag(catalog.id)
                        }
                    }
                } label: {
                    Label("Resort", systemImage: "mountain.2")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Resort, \(activeCatalog.resortName)")
                .accessibilityHint("Switches resorts")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(TrailLibrarySort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityHint("Changes the trail order")
            }
        }
        .onChange(of: visibleTrails.map(\.id)) { _, ids in
            if let selectedTrailID, !ids.contains(selectedTrailID) {
                self.selectedTrailID = nil
            }
            recenterMap()
        }
        .onChange(of: selectedTrailID) { _, id in
            guard let trail = visibleTrails.first(where: { $0.id == id }),
                let bounds = TrailGeometryStore.shared.metrics(for: trail).bounds
            else { return }
            let configuration = RouteMapConfiguration(bounds: bounds)
            mapLayerPreferences.showsActualTrails = true
            withAnimation(reduceMotion ? nil : BermsMotion.recenter) {
                mapPosition = configuration.initialPosition
            }
            visibleRegion = configuration.framingRegion
        }
    }

    @ViewBuilder
    private var libraryMap: some View {
        if mapConfiguration == nil {
            ContentUnavailableView(
                "No trail geometry", systemImage: "map",
                description: Text("Trail routes will appear here when the catalog is available."))
        } else {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Map(
                        position: $mapPosition, bounds: mapConfiguration?.bounds,
                        interactionModes: [.pan, .zoom, .rotate], selection: $selectedTrailID, scope: mapScope
                    ) {
                        if mapLayerPreferences.showsActualTrails {
                            ForEach(renderedTrails) { trail in
                                if trail.points.count > 1 {
                                    trailMapContent(
                                        coordinates: trailCoordinates(for: trail),
                                        difficulty: trail.difficulty,
                                        lineWidth: selectedTrailID == trail.id ? 5 : TrailMapRendering.lineWidth,
                                        tag: trail.id)
                                }
                            }

                            ForEach(Array(libraryLabelTrails)) { trail in
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
                    .onMapCameraChange(frequency: .onEnd) { context in
                        // The map reports the previous framing after a resort or
                        // filter change, and trusting it culls every trail.
                        guard mapConfiguration?.contains(cameraRegion: context.region) ?? true else { return }
                        visibleRegion = context.region
                    }

                }

                MapControlStack {
                    MapLayersMenu(
                        preferences: mapLayerPreferences,
                        showsRidePathControl: false,
                        actualTrailsAvailable: !visibleTrails.isEmpty,
                        showsJumpsControl: false)
                    MapRecenterButton { recenterMap() }
                }
                .padding(BermsSpacing.control)
            }
            .overlay(alignment: .topLeading) {
                MapCompass(scope: mapScope)
                    .padding(BermsSpacing.control)
            }
            .mapScope(mapScope)
            .onAppear { recenterMap() }
        }
    }

    private var libraryLabelTrails: [Trail] {
        guard let selectedTrailID else { return [] }
        return visibleTrails.filter { $0.id == selectedTrailID }
    }

    private func recenterMap() {
        guard let configuration = mapConfiguration else {
            mapPosition = .automatic
            visibleRegion = nil
            return
        }
        mapPosition = configuration.initialPosition
        visibleRegion = configuration.framingRegion
    }
}

struct ProductionTrailLibraryRow: View {
    let trail: Trail
    let isSelected: Bool

    var body: some View {
        HStack(spacing: BermsSpacing.control) {
            TrailRatingBadge(difficulty: trail.difficulty, size: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(trail.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(trail.difficulty.title) · \(trail.style.title) · \(BermsFormat.distance(distance))")
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: BermsSpacing.target)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var distance: Double {
        TrailGeometryStore.shared.metrics(for: trail).distanceMeters
    }
}
