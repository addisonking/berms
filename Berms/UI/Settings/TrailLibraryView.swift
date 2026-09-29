#if DEBUG
    import MapKit
    import SwiftData
    import SwiftUI

    private enum TrailCatalogSort: String, CaseIterable, Identifiable {
        case name
        case difficulty
        case length

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: "Name"
            case .difficulty: "Difficulty"
            case .length: "Length"
            }
        }
    }

    struct TrailLibraryView: View {
        @Query(sort: \Trail.name) private var trails: [Trail]
        @State private var selectedCatalogID = TrailCatalogRegistry.allCatalogs.first?.id ?? ""
        @State private var searchText = ""
        @State private var selectedDifficulty: TrailDifficulty?
        @State private var sort: TrailCatalogSort = .name

        private var catalog: TrailCatalogDescriptor? {
            TrailCatalogRegistry.catalog(withID: selectedCatalogID)
        }

        private var catalogTrails: [Trail] {
            guard let catalog else { return [] }
            return TrailCatalogRegistry.trails(trails, for: catalog)
        }

        private var geometryCount: Int {
            catalogTrails.filter { TrailGeometryStore.shared.metrics(for: $0).hasGeometry }.count
        }

        private var filteredTrails: [Trail] {
            let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return catalogTrails.filter { trail in
                (search.isEmpty || trail.name.localizedCaseInsensitiveContains(search))
                    && (selectedDifficulty == nil || trail.difficulty == selectedDifficulty)
            }
        }

        private var sortedTrails: [Trail] {
            switch sort {
            case .name:
                filteredTrails.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .difficulty:
                filteredTrails.sorted {
                    let first = TrailDifficulty.allCases.firstIndex(of: $0.difficulty) ?? 0
                    let second = TrailDifficulty.allCases.firstIndex(of: $1.difficulty) ?? 0
                    return first == second
                        ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        : first < second
                }
            case .length:
                filteredTrails.sorted {
                    TrailGeometryStore.shared.metrics(for: $0).distanceMeters
                        > TrailGeometryStore.shared.metrics(for: $1).distanceMeters
                }
            }
        }

        private var emptyDescription: String {
            guard let catalog else { return "The resort manifest has no catalogs." }
            if catalog.bundledResourceName == nil { return "This season has no bundled trail geometry." }
            if catalogTrails.isEmpty { return "The catalog may still be importing." }
            return "Try a different search or difficulty."
        }

        var body: some View {
            List {
                if TrailCatalogRegistry.allCatalogs.isEmpty {
                    ContentUnavailableView(
                        "No catalogs", systemImage: "map",
                        description: Text(emptyDescription))
                } else {
                    Section {
                        Picker("Catalog", selection: $selectedCatalogID) {
                            ForEach(TrailCatalogRegistry.allCatalogs) { option in
                                Text(option.resortName)
                                    .tag(option.id)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    } footer: {
                        if let catalog {
                            VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                                Text("\(catalogTrails.count) imported · \(geometryCount) with geometry")
                                if catalog.bundledResourceName == nil {
                                    Text("No bundled resource")
                                }
                            }
                        }
                    }

                    Section {
                        Picker("Difficulty", selection: $selectedDifficulty) {
                            Text("All").tag(Optional<TrailDifficulty>.none)
                            ForEach(TrailDifficulty.allCases) { difficulty in
                                Text(difficulty.title).tag(Optional(difficulty))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Section {
                        if sortedTrails.isEmpty {
                            ContentUnavailableView(
                                "No trails", systemImage: "map",
                                description: Text(emptyDescription))
                        } else {
                            ForEach(sortedTrails) { trail in
                                NavigationLink {
                                    TrailCatalogDetailView(trail: trail)
                                } label: {
                                    TrailCatalogRow(trail: trail)
                                }
                                .accessibilityHint("Opens the trail map and catalog details")
                            }
                        }
                    } header: {
                        Text("Trails (\(sortedTrails.count))")
                    }
                }
            }
            .navigationTitle("Trail Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search this catalog")
            .toolbar {
                if let catalog, geometryCount > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            TrailCatalogMapView(catalog: catalog, trails: catalogTrails)
                        } label: {
                            Label("Catalog map", systemImage: "map")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(TrailCatalogSort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort trails", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .onChange(of: selectedCatalogID) { _, _ in
                searchText = ""
                selectedDifficulty = nil
            }
        }
    }

    private struct TrailCatalogRow: View {
        let trail: Trail

        var body: some View {
            HStack(spacing: BermsSpacing.control) {
                TrailRatingBadge(difficulty: trail.difficulty, size: 12)
                VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                    Text(trail.name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(trail.difficulty.title) · \(trail.style.title) · \(BermsFormat.distance(distance))")
                        .font(.subheadline)
                        .foregroundStyle(Color.bermsMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: BermsSpacing.target)
            .accessibilityElement(children: .combine)
        }

        private var distance: Double {
            TrailGeometryStore.shared.metrics(for: trail).distanceMeters
        }
    }

    private struct TrailCatalogMapView: View {
        let catalog: TrailCatalogDescriptor
        let trails: [Trail]

        @State private var mapPosition: MapCameraPosition = .automatic
        @State private var visibleRegion: MKCoordinateRegion?
        @State private var selectedTrailID: UUID?

        private var mapConfiguration: RouteMapConfiguration? {
            let bounds = trails.compactMap { TrailGeometryStore.shared.metrics(for: $0).bounds }
                .reduce(nil as GeoBounds?) { total, next in total.map { $0.union(next) } ?? next }
            guard let bounds else { return nil }
            return RouteMapConfiguration(
                bounds: bounds,
                boundary: TrailCatalogRegistry.resort(withID: catalog.resortID)?.boundary)
        }

        private var renderedTrails: [Trail] {
            guard let visibleRegion else {
                return trails.filter { TrailGeometryStore.shared.metrics(for: $0).hasGeometry }
            }
            return trails.filter { trail in
                let metrics = TrailGeometryStore.shared.metrics(for: trail)
                guard let bounds = metrics.bounds, metrics.hasGeometry else { return false }
                return trailBoundsIntersect(bounds, region: visibleRegion)
            }
        }

        private var selectedTrail: Trail? {
            trails.first { $0.id == selectedTrailID }
        }

        var body: some View {
            Group {
                if let mapConfiguration {
                    Map(
                        position: $mapPosition, bounds: mapConfiguration.bounds,
                        interactionModes: [.pan, .zoom, .rotate], selection: $selectedTrailID
                    ) {
                        ForEach(renderedTrails) { trail in
                            trailMapContent(
                                coordinates: trailCoordinates(for: trail),
                                difficulty: trail.difficulty,
                                lineWidth: selectedTrailID == trail.id ? 5 : TrailMapRendering.lineWidth,
                                tag: trail.id)
                        }
                    }
                    .mapStyle(.bermsMonochrome)
                    .mapControls { MapScaleView() }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        guard mapConfiguration.contains(cameraRegion: context.region) else { return }
                        visibleRegion = context.region
                    }
                    .overlay(alignment: .topTrailing) {
                        MapRecenterButton {
                            mapPosition = mapConfiguration.initialPosition
                            visibleRegion = mapConfiguration.framingRegion
                        }
                        .padding(BermsSpacing.control)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let selectedTrail {
                            NavigationLink {
                                TrailCatalogDetailView(trail: selectedTrail)
                            } label: {
                                HStack(spacing: BermsSpacing.control) {
                                    TrailRatingBadge(difficulty: selectedTrail.difficulty, size: 12)
                                    VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                                        Text(selectedTrail.name)
                                            .font(.headline)
                                        Text(selectedTrail.difficulty.title)
                                            .font(.subheadline)
                                            .foregroundStyle(Color.bermsMuted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                .padding(BermsSpacing.content)
                                .frame(minHeight: BermsSpacing.target)
                            }
                            .buttonStyle(.plain)
                            .background(Color.bermsCard)
                            .accessibilityHint("Opens the trail map and catalog details")
                        }
                    }
                    .onAppear {
                        mapPosition = mapConfiguration.initialPosition
                        visibleRegion = mapConfiguration.framingRegion
                    }
                } else {
                    ContentUnavailableView(
                        "No trail geometry", systemImage: "map",
                        description: Text("This catalog has no trails to show on a map."))
                }
            }
            .navigationTitle(catalog.resortName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private struct TrailCatalogDetailView: View {
        private static let mapHeight: CGFloat = 320

        let trail: Trail
        @State private var mapPosition: MapCameraPosition = .automatic

        private var metrics: TrailGeometryStore.Metrics {
            TrailGeometryStore.shared.metrics(for: trail)
        }

        private var mapConfiguration: RouteMapConfiguration? {
            metrics.bounds.map { RouteMapConfiguration(bounds: $0) }
        }

        var body: some View {
            List {
                Section {
                    if let mapConfiguration, metrics.hasGeometry {
                        Map(position: $mapPosition, bounds: mapConfiguration.bounds) {
                            trailMapContent(
                                coordinates: trailCoordinates(for: trail),
                                difficulty: trail.difficulty)
                        }
                        .mapStyle(.bermsMonochrome)
                        .frame(height: Self.mapHeight)
                        .overlay(alignment: .topTrailing) {
                            MapRecenterButton { mapPosition = mapConfiguration.initialPosition }
                                .padding(BermsSpacing.control)
                        }
                        .listRowInsets(EdgeInsets())
                        .onAppear { mapPosition = mapConfiguration.initialPosition }
                    } else {
                        ContentUnavailableView(
                            "No trail geometry", systemImage: "map",
                            description: Text("This trail has no route to inspect."))
                    }
                }

                Section("Trail") {
                    LabeledContent("Difficulty", value: trail.difficulty.title)
                    LabeledContent("Style", value: trail.style.title)
                    LabeledContent("Length", value: BermsFormat.distance(metrics.distanceMeters))
                    LabeledContent("Points", value: "\(metrics.pointCount)")
                }

                Section("Record") {
                    LabeledContent("Resort", value: trail.resort)
                    LabeledContent("Catalog", value: trail.catalogID ?? "Unassigned")
                    LabeledContent("Passes", value: "\(trail.passCount)")
                    VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                        Text("Trail ID")
                            .font(.subheadline)
                            .foregroundStyle(Color.bermsMuted)
                        Text(verbatim: trail.id.uuidString)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(trail.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
#endif
