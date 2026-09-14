import MapKit
import SwiftData
import SwiftUI
import UIKit

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
                        Text("All difficulties").tag(Optional<TrailDifficulty>.none)
                        ForEach(TrailDifficulty.allCases) { difficulty in
                            Text(difficulty.title).tag(Optional(difficulty))
                        }
                    }
                }
                Section {
                    if visibleTrails.isEmpty {
                        ContentUnavailableView("No matching trails", systemImage: "map",
                                               description: Text("Try a different search or difficulty filter."))
                    } else {
                        ForEach(visibleTrails) { trail in
                            Button {
                                selectedTrailID = trail.id
                                withAnimation(reduceMotion ? nil : BermsMotion.recenter) {
                                    proxy.scrollTo("libraryMap", anchor: .top)
                                }
                            } label: {
                                ProductionTrailLibraryRow(trail: trail,
                                                          isSelected: selectedTrailID == trail.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows this trail on the map")
                        }
                    }
                } header: {
                    Text("\(visibleTrails.count) trails · \(activeCatalog.resortName)")
                }
            }
        }
        .navigationTitle("Trail Library")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search trails")
        .onChange(of: visibleTrails.map(\.id)) { _, ids in
            if let selectedTrailID, !ids.contains(selectedTrailID) {
                self.selectedTrailID = nil
            }
            recenterMap()
        }
        .onChange(of: selectedTrailID) { _, id in
            guard let trail = visibleTrails.first(where: { $0.id == id }),
                  let configuration = RouteMapConfiguration(points: trail.points) else { return }
            mapLayerPreferences.showsActualTrails = true
            withAnimation(reduceMotion ? nil : BermsMotion.recenter) {
                mapPosition = configuration.initialPosition
            }
        }
    }

    @ViewBuilder
    private var libraryMap: some View {
        if visibleTrails.flatMap(\.points).isEmpty {
            ContentUnavailableView("No trail geometry", systemImage: "map",
                                   description: Text("Trail routes will appear here when the catalog is available."))
        } else {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Map(position: $mapPosition, bounds: mapConfiguration?.bounds,
                        interactionModes: [.pan, .zoom, .rotate], selection: $selectedTrailID, scope: mapScope) {
                        if mapLayerPreferences.showsActualTrails {
                            ForEach(visibleTrails) { trail in
                                if trail.points.count > 1 {
                                    trailMapContent(coordinates: trailCoordinates(for: trail),
                                                    difficulty: trail.difficulty,
                                                    lineWidth: selectedTrailID == trail.id ? 5 : TrailMapRendering.lineWidth,
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
                    .mapControls { MapScaleView() }

                }

                MapControlStack {
                    MapLayersMenu(preferences: mapLayerPreferences,
                                  showsRidePathControl: false,
                                  actualTrailsAvailable: !visibleTrails.isEmpty,
                                  showsJumpsControl: false)
                    MapRecenterButton { recenterMap() }
                    MapCompass(scope: mapScope)
                }
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
        mapPosition = mapConfiguration?.initialPosition ?? .automatic
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
        zip(trail.points, trail.points.dropFirst()).reduce(0) { total, pair in
            let start = Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return total + start.distance(to: end)
        }
    }
}
