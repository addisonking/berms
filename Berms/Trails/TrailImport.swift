import Combine
import CryptoKit
import Foundation
import SwiftData

struct TrailCatalogDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let resortID: String
    let resortName: String
    let bundledResourceName: String?
    let importVersion: String

    /// Prefix for the catalog's stable trail IDs, `SHA256(namespace:slug)`.
    /// Every catalog needs its own namespace: slugs repeat across parks
    /// (`candyland` exists at three resorts), and an ID is only as unique as
    /// this prefix. Bundled RidePal catalogs use `berms:ridepal:<park-slug>`;
    /// `berms:ridepal` alone is reserved for the original Mountain Creek
    /// records so they keep matching.
    let stableIDNamespace: String
    let legacyImportVersionKeys: [String]

    /// Slugs whose published difficulty differs from the official map.
    let difficultyOverrides: [String: TrailDifficulty]

    /// Retired slug to canonical slug. Retired records merge into the canonical
    /// trail during import.
    let aliases: [String: String]

    var displayName: String { resortName }
}

enum TrailCatalogRegistry {
    static let automaticSelectionID = "automatic"
    static let mountainCreekResortID = "mountain-creek"
    static let mountainCreekCatalogID = "mountain-creek-resort"

    private static let manifestResult: Result<ResortCatalogManifest, any Error> = Result {
        try ResortCatalogLoader.load()
    }

    static var manifest: ResortCatalogManifest {
        #if os(iOS)
            if let downloaded = CatalogSnapshotStore.shared.registryManifest() { return downloaded }
        #endif
        return (try? manifestResult.get()) ?? .empty
    }

    /// Set when the bundled manifest could not be read. Surfaced to the rider
    /// instead of silently running with no catalogs.
    static var manifestError: String? {
        guard case .failure(let error) = manifestResult else { return nil }
        return error.localizedDescription
    }

    static var resorts: [ResortDescriptor] { manifest.resorts }
    static var allCatalogs: [TrailCatalogDescriptor] { manifest.catalogs }

    /// Catalogs with bundled geometry are imported into SwiftData. Placeholders
    /// remain resolvable even before their map resource ships.
    static var catalogs: [TrailCatalogDescriptor] {
        #if os(iOS)
            if CatalogSnapshotStore.shared.activeDirectory != nil { return allCatalogs }
        #endif
        return allCatalogs.filter { $0.bundledResourceName != nil }
    }

    static var defaultCatalog: TrailCatalogDescriptor { catalogs.first ?? fallbackCatalog }

    // Compatibility accessors for the original single-resort API.
    static var mountainCreek: TrailCatalogDescriptor {
        catalog(withID: mountainCreekCatalogID) ?? fallbackCatalog
    }

    static func resort(withID id: String?) -> ResortDescriptor? {
        guard let id else { return nil }
        return resorts.first { $0.id == id }
    }

    /// The resort whose boundary contains the coordinate. Nil means the rider
    /// is not at a known resort, which keeps trail matching from guessing.
    static func resort(containing coordinate: Coordinate) -> ResortDescriptor? {
        resorts
            .filter { $0.boundary.contains(coordinate) }
            .min { coordinate.distance(to: $0.boundary.center) < coordinate.distance(to: $1.boundary.center) }
    }

    /// Nearest resort when the rider is not inside one, so the live map can
    /// preview trails on the drive in without anyone picking a resort.
    static func resort(nearest coordinate: Coordinate, withinMeters meters: Double) -> ResortDescriptor? {
        resorts
            .map { ($0, coordinate.distance(to: $0.boundary.center)) }
            .filter { $0.1 <= meters }
            .min { $0.1 < $1.1 }?
            .0
    }

    static func catalog(withID id: String?) -> TrailCatalogDescriptor? {
        guard let id else { return nil }
        return allCatalogs.first { $0.id == id }
    }

    /// The catalog a resort ships, ignoring GPS.
    static func catalog(forResortID id: String) -> TrailCatalogDescriptor? {
        allCatalogs.first { $0.resortID == id }
    }

    /// Safety net when the manifest resource is missing. Match the original
    /// catalog so callers resolve a sensible default instead of crashing.
    private static let fallbackCatalog = TrailCatalogDescriptor(
        id: mountainCreekCatalogID,
        resortID: mountainCreekResortID,
        resortName: "Mountain Creek Resort",
        bundledResourceName: nil,
        importVersion: "mountain-creek-ridepal-v4",
        stableIDNamespace: "berms:ridepal",
        legacyImportVersionKeys: [],
        difficultyOverrides: [:],
        aliases: [:]
    )

    /// The catalog a recorded day belongs to. A rider override wins; otherwise
    /// the route votes on resorts, so starting in the parking lot or stopping
    /// outside the boundary still resolves the day the rider actually rode.
    static func resolvedCatalogID(
        manualSelectionID: String?,
        routePoints: [Coordinate]
    ) -> String? {
        if let manual = catalog(withID: manualSelectionID) {
            return manual.id
        }
        guard !allCatalogs.isEmpty else { return nil }
        let minimumVotes = max(1, routePoints.count / 20)
        var votes: [String: Int] = [:]
        for point in routePoints {
            guard let resort = resort(containing: point) else { continue }
            votes[resort.id, default: 0] += 1
        }
        guard let best = votes.max(by: { $0.value < $1.value }), best.value >= minimumVotes else {
            return nil
        }
        return allCatalogs.first { $0.resortID == best.key }?.id
    }

    /// Single-point convenience used where only the start is known.
    static func resolvedCatalogID(
        manualSelectionID: String?,
        firstPoint: Coordinate?
    ) -> String? {
        resolvedCatalogID(
            manualSelectionID: manualSelectionID,
            routePoints: firstPoint.map { [$0] } ?? [])
    }

    static func trails(_ trails: [Trail], for catalog: TrailCatalogDescriptor) -> [Trail] {
        trails.filter { trail in
            if let trailCatalogID = trail.catalogID {
                return trailCatalogID == catalog.id
            }
            // Trails created before seasonal catalog IDs existed belong to the
            // original summer Mountain Creek catalog when their resort matches.
            return catalog.id == mountainCreekCatalogID && trail.resort == catalog.resortName
        }
    }
}

extension TrailCatalogRegistry {
    /// The catalog a recorded day presents with: the rider's override when set,
    /// otherwise the resort the ride mostly happened in. Nil means the day is
    /// not tied to any resort, so nothing is assumed.
    static func resolvedCatalog(for day: RideDay) -> TrailCatalogDescriptor? {
        resolvedCatalogID(
            manualSelectionID: day.catalogID,
            routePoints: day.sampledRouteCoordinates()
        ).flatMap(catalog(withID:))
    }
}

enum TrailCatalogImporter {
    private static let versionKeyPrefix = "berms.trailCatalogImport"

    struct Summary: Sendable {
        let trailsCreated: Int
        let passesCreated: Int
        let existingTrailsSkipped: Int
        let invalidFeaturesSkipped: Int
    }

    enum ImportError: LocalizedError {
        case missingResource
        case invalidCollectionType(String)

        var errorDescription: String? {
            switch self {
            case .missingResource:
                "The selected trail catalog resource is missing."
            case .invalidCollectionType(let type):
                "Expected a GeoJSON FeatureCollection, received \(type)."
            }
        }
    }

    static func importCatalogsIfNeeded(
        into context: ModelContext,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) throws -> [(catalog: TrailCatalogDescriptor, summary: Summary)] {
        try TrailCatalogRegistry.catalogs.compactMap { catalog in
            guard
                let summary = try importCatalogIfNeeded(
                    catalog, into: context,
                    bundle: bundle,
                    defaults: defaults,
                    now: now)
            else {
                return nil
            }
            return (catalog: catalog, summary: summary)
        }
    }

    static func importCatalogIfNeeded(
        _ catalog: TrailCatalogDescriptor,
        into context: ModelContext,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) throws -> Summary? {
        guard !isImported(catalog, defaults: defaults) else { return nil }
        let data: Data
        #if os(iOS)
            data = try CatalogSnapshotStore.shared.catalogData(catalog, bundle: bundle)
        #else
            guard let resourceName = catalog.bundledResourceName,
                let url = bundle.url(forResource: resourceName, withExtension: "geojson")
            else { return nil }
            data = try Data(contentsOf: url)
        #endif
        return try `import`(
            data: data, into: context, defaults: defaults,
            now: now, catalog: catalog, approvedGeometry: true)
    }

    static func `import`(
        data: Data,
        into context: ModelContext,
        defaults: UserDefaults = .standard,
        now: Date = .now,
        catalog: TrailCatalogDescriptor = TrailCatalogRegistry.mountainCreek,
        version: String? = nil,
        approvedGeometry: Bool = false,
        saveChanges: Bool = true
    ) throws -> Summary {
        let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
        guard collection.type == "FeatureCollection" else {
            throw ImportError.invalidCollectionType(collection.type)
        }

        let existingTrails = try context.fetch(FetchDescriptor<Trail>())
        var trailsByID = Dictionary(
            existingTrails.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var trailsCreated = 0
        var passesCreated = 0
        var existingTrailsSkipped = 0
        var invalidFeaturesSkipped = 0
        var approvedIDs = Set<UUID>()
        let retiredSlugs = retiredTrailSlugs(for: catalog)

        for feature in collection.features {
            guard let slug = feature.properties.slug?.trimmedNonEmpty,
                let name = feature.properties.name?.trimmedNonEmpty
            else {
                invalidFeaturesSkipped += 1
                continue
            }
            if retiredSlugs.contains(slug) {
                continue
            }
            let difficulty = difficulty(from: feature.properties, catalog: catalog)
            guard let points = feature.geometry.routePoints(referenceDate: now),
                points.count >= 2
            else {
                invalidFeaturesSkipped += 1
                continue
            }

            let id = stableID(for: slug, catalog: catalog)
            approvedIDs.insert(id)
            let trail: Trail
            if let existing = trailsByID[id] {
                trail = existing
                existing.catalogID = catalog.id
                if existing.name != name || existing.difficultyRawValue != difficulty.rawValue {
                    existing.name = name
                    existing.difficultyRawValue = difficulty.rawValue
                    existing.updatedAt = now
                }
                guard approvedGeometry || existing.passes.isEmpty else {
                    existingTrailsSkipped += 1
                    continue
                }
            } else {
                trail = Trail(
                    name: name, difficulty: difficulty, resort: catalog.resortName,
                    catalogID: catalog.id)
                trail.id = id
                context.insert(trail)
                trailsByID[id] = trail
                trailsCreated += 1
            }

            if approvedGeometry, let lines = feature.geometry.routeLines(referenceDate: now) {
                try trail.setCatalogRoutes(lines, at: now)
                continue
            }
            let pass = TrailPass(routePoints: points, recordedAt: now)
            pass.trail = trail
            trail.passes.append(pass)
            trail.recalculateAverage()
            context.insert(pass)
            passesCreated += 1
        }

        if approvedGeometry {
            for trail in existingTrails
            where trail.catalogID == catalog.id && trail.catalogRouteData != nil
                && !approvedIDs.contains(trail.id)
            {
                try trail.setCatalogRoutes([], at: now)
            }
        }
        reconcileRetiredTrails(for: catalog, trailsByID: trailsByID, context: context)
        if saveChanges { try context.save() }
        let importVersion = version ?? catalog.importVersion
        if saveChanges { defaults.set(importVersion, forKey: versionKey(for: catalog)) }
        for legacyKey in catalog.legacyImportVersionKeys {
            if saveChanges { defaults.set(importVersion, forKey: legacyKey) }
        }
        return Summary(
            trailsCreated: trailsCreated,
            passesCreated: passesCreated,
            existingTrailsSkipped: existingTrailsSkipped,
            invalidFeaturesSkipped: invalidFeaturesSkipped
        )
    }

    /// Unknown ratings become `.unrated` instead of dropping the trail.
    nonisolated private static func difficulty(
        from properties: GeoJSONProperties,
        catalog: TrailCatalogDescriptor
    ) -> TrailDifficulty {
        if let slug = properties.slug?.trimmedNonEmpty,
            let officialDifficulty = catalog.difficultyOverrides[slug]
        {
            return officialDifficulty
        }

        if let rawValue = properties.difficulty,
            let difficulty = TrailDifficulty(rawValue: rawValue)
        {
            return difficulty
        }

        return switch properties.difficultyLabel?.trimmedNonEmpty {
        case "Green Circle": TrailDifficulty.green
        case "Blue Square": TrailDifficulty.blue
        case "Black Diamond": TrailDifficulty.black
        case "Double Black Diamond": TrailDifficulty.doubleBlack
        default: TrailDifficulty.unrated
        }
    }

    private static func retiredTrailSlugs(for catalog: TrailCatalogDescriptor) -> Set<String> {
        Set(catalog.aliases.keys)
    }

    private static func reconcileRetiredTrails(
        for catalog: TrailCatalogDescriptor,
        trailsByID: [UUID: Trail],
        context: ModelContext
    ) {
        for (retiredSlug, canonicalSlug) in catalog.aliases {
            let retiredID = stableID(for: retiredSlug, catalog: catalog)
            let canonicalID = stableID(for: canonicalSlug, catalog: catalog)
            guard let retiredTrail = trailsByID[retiredID],
                let canonicalTrail = trailsByID[canonicalID],
                retiredTrail.id != canonicalTrail.id
            else {
                continue
            }

            let retiredPasses = retiredTrail.passes
            retiredTrail.passes.removeAll()
            for pass in retiredPasses {
                pass.trail = canonicalTrail
                if !canonicalTrail.passes.contains(where: { $0.id == pass.id }) {
                    canonicalTrail.passes.append(pass)
                }
            }
            canonicalTrail.recalculateAverage()
            context.delete(retiredTrail)
        }
    }

    nonisolated static func stableID(for slug: String, catalog: TrailCatalogDescriptor) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(catalog.stableIDNamespace):\(slug)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    /// Catalog centerlines keyed by the stable trail ID the importer assigns.
    /// Used to restore catalog geometry that an older migration re-cleaned.
    nonisolated static func bundledRoutePoints(
        catalog: TrailCatalogDescriptor,
        bundle: Bundle = .main
    ) -> [UUID: [RoutePoint]] {
        guard let resourceName = catalog.bundledResourceName,
            let url = bundle.url(
                forResource: resourceName,
                withExtension: "geojson"),
            let data = try? Data(contentsOf: url),
            let collection = try? JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
        else {
            return [:]
        }
        let reference = Date(timeIntervalSince1970: 0)
        var routes: [UUID: [RoutePoint]] = [:]
        for feature in collection.features {
            guard let slug = feature.properties.slug?.trimmedNonEmpty,
                let points = feature.geometry.routePoints(referenceDate: reference),
                points.count >= 2
            else { continue }
            routes[stableID(for: slug, catalog: catalog)] = points
        }
        return routes
    }

    /// Bundled centerlines as matcher candidates. Berms Studio names runs with
    /// this so its results match the iOS app.
    nonisolated static func bundledRouteCandidates(
        bundle: Bundle = .main
    ) -> [TrailRouteCandidate] {
        guard let manifest = try? ResortCatalogLoader.load(bundle: bundle) else { return [] }
        return manifest.catalogs.filter { $0.bundledResourceName != nil }.flatMap {
            catalog -> [TrailRouteCandidate] in
            guard
                let resourceName = catalog.bundledResourceName,
                let url = bundle.url(
                    forResource: resourceName,
                    withExtension: "geojson"),
                let data = try? Data(contentsOf: url),
                let collection = try? JSONDecoder().decode(
                    GeoJSONFeatureCollection.self, from: data)
            else {
                return []
            }

            let reference = Date(timeIntervalSince1970: 0)
            return collection.features.compactMap { feature in
                guard let slug = feature.properties.slug?.trimmedNonEmpty,
                    let name = feature.properties.name?.trimmedNonEmpty,
                    !catalog.aliases.keys.contains(slug),
                    let routes = feature.geometry.routeLines(referenceDate: reference)
                else {
                    return nil
                }
                let difficulty = difficulty(from: feature.properties, catalog: catalog)
                return TrailRouteCandidate(
                    id: stableID(for: slug, catalog: catalog),
                    name: name,
                    difficulty: difficulty,
                    routes: routes)
            }
        }
    }

    static func markImported(_ catalog: TrailCatalogDescriptor, defaults: UserDefaults) {
        defaults.set(catalog.importVersion, forKey: versionKey(for: catalog))
    }

    private static func versionKey(for catalog: TrailCatalogDescriptor) -> String {
        "\(versionKeyPrefix).\(catalog.id).version"
    }

    private static func isImported(
        _ catalog: TrailCatalogDescriptor,
        defaults: UserDefaults
    ) -> Bool {
        let current = defaults.string(forKey: versionKey(for: catalog))
        if current == catalog.importVersion { return true }
        return catalog.legacyImportVersionKeys.contains {
            defaults.string(forKey: $0) == catalog.importVersion
        }
    }
}

private struct GeoJSONFeatureCollection: Decodable {
    let type: String
    let features: [GeoJSONFeature]

    private enum CodingKeys: String, CodingKey {
        case type
        case features
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        // Decode features lossily so one malformed entry cannot abort the catalog.
        features = try container.decode([LossyFeature].self, forKey: .features)
            .compactMap(\.feature)
    }
}

private struct LossyFeature: Decodable {
    let feature: GeoJSONFeature?

    init(from decoder: Decoder) throws {
        feature = try? GeoJSONFeature(from: decoder)
    }
}

private struct GeoJSONFeature: Decodable {
    let properties: GeoJSONProperties
    let geometry: GeoJSONGeometry
}

private struct GeoJSONProperties: Decodable {
    let name: String?
    let slug: String?
    let difficulty: String?
    let difficultyLabel: String?
}

private enum GeoJSONGeometry: Decodable {
    case lineString([[Double]])
    case multiLineString([[[Double]]])

    private enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "LineString":
            self = .lineString(try container.decode([[Double]].self, forKey: .coordinates))
        case "MultiLineString":
            self = .multiLineString(try container.decode([[[Double]]].self, forKey: .coordinates))
        default:
            self = .lineString([])
        }
    }

    func routePoints(referenceDate: Date) -> [RoutePoint]? {
        let coordinateLines: [[[Double]]]
        switch self {
        case .lineString(let coordinates):
            coordinateLines = [coordinates]
        case .multiLineString(let coordinates):
            coordinateLines = coordinates
        }

        // Catalog centerlines concatenate multi-line geometries into one path.
        let coordinates = coordinateLines.reduce(into: [[Double]]()) { result, line in
            result.append(contentsOf: line)
        }
        return route(referenceDate: referenceDate, coordinates: coordinates)
    }

    /// Each LineString kept separate. Matcher candidates score one route at a
    /// time, so multi-line features must not be stitched together.
    func routeLines(referenceDate: Date) -> [[RoutePoint]]? {
        let coordinateLines: [[[Double]]]
        switch self {
        case .lineString(let coordinates):
            coordinateLines = [coordinates]
        case .multiLineString(let coordinates):
            coordinateLines = coordinates
        }
        let lines = coordinateLines.compactMap {
            route(referenceDate: referenceDate, coordinates: $0)
        }
        return lines.isEmpty ? nil : lines
    }

    private func route(referenceDate: Date, coordinates: [[Double]]) -> [RoutePoint]? {
        guard coordinates.count >= 2 else { return nil }

        let startDate = referenceDate.addingTimeInterval(-Double(coordinates.count - 1))
        let points = coordinates.enumerated().compactMap { index, coordinate -> RoutePoint? in
            guard coordinate.count >= 2,
                coordinate[0].isFinite,
                coordinate[1].isFinite,
                (-180...180).contains(coordinate[0]),
                (-90...90).contains(coordinate[1])
            else {
                return nil
            }
            return RoutePoint(
                latitude: coordinate[1],
                longitude: coordinate[0],
                altitude: 0,
                speed: 0,
                timestamp: startDate.addingTimeInterval(Double(index))
            )
        }
        return points.count >= 2 ? points : nil
    }
}

extension String {
    fileprivate var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
