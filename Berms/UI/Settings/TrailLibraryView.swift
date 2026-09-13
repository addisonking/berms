import MapKit
import SwiftData
import SwiftUI
import UIKit

struct TrailLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Trail.updatedAt, order: .reverse) private var trails: [Trail]
    @EnvironmentObject private var mapLayerPreferences: MapLayerPreferences
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection
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
                    .bermsMapControl()
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
        guard let selectedTrailID else { return [] }
        return visibleTrails.filter { $0.id == selectedTrailID }
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
        .controlSize(.large)
        .tint(selectedDifficulty == difficulty ? .bermsTrail : .bermsMuted)
        .accessibilityAddTraits(selectedDifficulty == difficulty ? .isSelected : [])
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
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(trail.difficulty.title) · \(trail.style.title) · \(BermsFormat.distance(distance))")
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
