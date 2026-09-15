import CryptoKit
import Combine
import Foundation
import SwiftData

struct TrailCatalogDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let season: SeasonBucket
    let resortID: String
    let resortName: String
    let bundledResourceName: String?
    let importVersion: String
    let locationAnchor: Coordinate

    // Mountain Creek's original IDs were generated in the RidePal namespace.
    // Keep that namespace for this catalog so existing device records match.
    let stableIDNamespace: String
    let legacyImportVersionKeys: [String]

    var displayName: String { resortName }
}

enum TrailCatalogRegistry {
    static let automaticSelectionID = "automatic"
    static let mountainCreekResortID = "mountain-creek"

    static let mountainCreek = TrailCatalogDescriptor(
        id: "mountain-creek-resort",
        season: .summer,
        resortID: mountainCreekResortID,
        resortName: "Mountain Creek Resort",
        bundledResourceName: "mountain-creek-ridepal-trails-with-metadata",
        importVersion: "mountain-creek-ridepal-v3",
        locationAnchor: Coordinate(latitude: 41.2505, longitude: -74.5012),
        stableIDNamespace: "berms:ridepal",
        legacyImportVersionKeys: ["berms.trailSeedImport.version"]
    )

    static let mountainCreekWinter = TrailCatalogDescriptor(
        id: "mountain-creek-winter",
        season: .winter,
        resortID: mountainCreekResortID,
        resortName: "Mountain Creek Resort",
        bundledResourceName: nil,
        importVersion: "mountain-creek-winter-v1",
        locationAnchor: Coordinate(latitude: 41.2505, longitude: -74.5012),
        stableIDNamespace: "berms:mountain-creek-winter",
        legacyImportVersionKeys: []
    )

    /// Catalogs with bundled geometry are imported into SwiftData. Seasonal
    /// placeholders remain resolvable even before their map resource ships.
    static let catalogs: [TrailCatalogDescriptor] = [mountainCreek]
    static let catalogsBySeason: [SeasonBucket: [TrailCatalogDescriptor]] = [
        .summer: [mountainCreek],
        .winter: [mountainCreekWinter]
    ]

    static var defaultCatalog: TrailCatalogDescriptor { catalogs[0] }

    static func catalog(withID id: String?) -> TrailCatalogDescriptor? {
        guard let id else { return nil }
        return [mountainCreek, mountainCreekWinter].first { $0.id == id }
    }

    static func nearestCatalog(to coordinate: Coordinate) -> TrailCatalogDescriptor {
        catalogs.min {
            coordinate.distance(to: $0.locationAnchor)
                < coordinate.distance(to: $1.locationAnchor)
        } ?? defaultCatalog
    }

    static func catalog(for mode: ActivityMode,
                        coordinate: Coordinate? = nil) -> TrailCatalogDescriptor? {
        let candidates = catalogsBySeason[mode.season] ?? []
        guard !candidates.isEmpty else { return nil }
        guard let coordinate else { return candidates.first }
        return candidates.min {
            coordinate.distance(to: $0.locationAnchor)
                < coordinate.distance(to: $1.locationAnchor)
        }
    }

    static func trails(_ trails: [Trail], for catalog: TrailCatalogDescriptor) -> [Trail] {
        trails.filter { trail in
            if let trailCatalogID = trail.catalogID {
                return trailCatalogID == catalog.id
            }
            // Trails created before seasonal catalog IDs existed belong to the
            // original summer Mountain Creek catalog when their resort matches.
            return catalog.id == mountainCreek.id && trail.resort == catalog.resortName
        }
    }
}

@MainActor
final class TrailCatalogSelection: ObservableObject {
    private static let selectionKey = "berms.trailCatalog.activeSelection"

    private let defaults: UserDefaults
    @Published private(set) var manualCatalogID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.selectionKey)
        manualCatalogID = TrailCatalogRegistry.catalog(withID: stored)?.id
    }

    var isAutomatic: Bool { manualCatalogID == nil }

    var selectionID: String {
        manualCatalogID ?? TrailCatalogRegistry.automaticSelectionID
    }

    var selectionLabel: String {
        manualCatalogID.flatMap(TrailCatalogRegistry.catalog(withID:))?.resortName
            ?? "Automatic"
    }

    func setSelectionID(_ id: String) {
        let newValue = id == TrailCatalogRegistry.automaticSelectionID
            ? nil
            : TrailCatalogRegistry.catalog(withID: id)?.id
        manualCatalogID = newValue
        if let newValue {
            defaults.set(newValue, forKey: Self.selectionKey)
        } else {
            defaults.removeObject(forKey: Self.selectionKey)
        }
    }

    func catalog(for coordinate: Coordinate?) -> TrailCatalogDescriptor {
        if let manualCatalogID,
           let manualCatalog = TrailCatalogRegistry.catalog(withID: manualCatalogID) {
            return manualCatalog
        }
        guard let coordinate else { return TrailCatalogRegistry.defaultCatalog }
        return TrailCatalogRegistry.nearestCatalog(to: coordinate)
    }

    func catalog(for mode: ActivityMode,
                 coordinate: Coordinate? = nil) -> TrailCatalogDescriptor? {
        if let manualCatalogID,
           let manualCatalog = TrailCatalogRegistry.catalog(withID: manualCatalogID),
           manualCatalog.season == mode.season {
            return manualCatalog
        }
        return TrailCatalogRegistry.catalog(for: mode, coordinate: coordinate)
    }

    func trails(_ trails: [Trail], near coordinate: Coordinate? = nil) -> [Trail] {
        self.trails(trails, mode: .bikePark, near: coordinate)
    }

    func trails(_ trails: [Trail], mode: ActivityMode,
                near coordinate: Coordinate? = nil) -> [Trail] {
        guard let catalog = catalog(for: mode, coordinate: coordinate) else { return [] }
        return TrailCatalogRegistry.trails(trails, for: catalog)
    }
}

@MainActor
enum TrailCatalogImporter {
    // Compatibility constants for code that used the original importer API.
    static let mountainCreekResourceName = TrailCatalogRegistry.mountainCreek.bundledResourceName!
    static let mountainCreekImportVersion = TrailCatalogRegistry.mountainCreek.importVersion

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

    static func importMountainCreekIfNeeded(
        into context: ModelContext,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) throws -> Summary? {
        try importCatalogIfNeeded(TrailCatalogRegistry.mountainCreek,
                                  into: context, bundle: bundle,
                                  defaults: defaults, now: now)
    }

    static func importCatalogsIfNeeded(
        into context: ModelContext,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) throws -> [(catalog: TrailCatalogDescriptor, summary: Summary)] {
        try TrailCatalogRegistry.catalogs.compactMap { catalog in
            guard let summary = try importCatalogIfNeeded(catalog, into: context,
                                                           bundle: bundle,
                                                           defaults: defaults,
                                                           now: now) else {
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
        guard let resourceName = catalog.bundledResourceName,
              let url = bundle.url(forResource: resourceName,
                                   withExtension: "geojson") else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try `import`(data: data, into: context, defaults: defaults,
                            now: now, catalog: catalog)
    }

    static func `import`(
        data: Data,
        into context: ModelContext,
        defaults: UserDefaults = .standard,
        now: Date = .now,
        catalog: TrailCatalogDescriptor = TrailCatalogRegistry.mountainCreek,
        version: String? = nil
    ) throws -> Summary {
        let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
        guard collection.type == "FeatureCollection" else {
            throw ImportError.invalidCollectionType(collection.type)
        }

        let existingTrails = try context.fetch(FetchDescriptor<Trail>())
        var trailsByID = Dictionary(existingTrails.map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        var trailsCreated = 0
        var passesCreated = 0
        var existingTrailsSkipped = 0
        var invalidFeaturesSkipped = 0
        let retiredSlugs = retiredTrailSlugs(for: catalog)

        for feature in collection.features {
            guard let slug = feature.properties.slug?.trimmedNonEmpty,
                  let name = feature.properties.name?.trimmedNonEmpty else {
                invalidFeaturesSkipped += 1
                continue
            }
            if retiredSlugs.contains(slug) {
                continue
            }
            guard let difficulty = difficulty(from: feature.properties, catalog: catalog),
                  let points = feature.geometry.routePoints(referenceDate: now),
                  points.count >= 2 else {
                invalidFeaturesSkipped += 1
                continue
            }

            let id = stableID(for: slug, catalog: catalog)
            let trail: Trail
            if let existing = trailsByID[id] {
                trail = existing
                existing.catalogID = catalog.id
                if existing.name != name || existing.difficultyRawValue != difficulty.rawValue {
                    existing.name = name
                    existing.difficultyRawValue = difficulty.rawValue
                    existing.updatedAt = now
                }
                guard existing.passes.isEmpty else {
                    existingTrailsSkipped += 1
                    continue
                }
            } else {
                trail = Trail(name: name, difficulty: difficulty, resort: catalog.resortName,
                              catalogID: catalog.id)
                trail.id = id
                context.insert(trail)
                trailsByID[id] = trail
                trailsCreated += 1
            }

            let pass = TrailPass(routePoints: points, recordedAt: now)
            pass.trail = trail
            trail.passes.append(pass)
            trail.recalculateAverage()
            context.insert(pass)
            passesCreated += 1
        }

        reconcileRetiredTrails(for: catalog, trailsByID: trailsByID, context: context)
        try context.save()
        let importVersion = version ?? catalog.importVersion
        defaults.set(importVersion, forKey: versionKey(for: catalog))
        for legacyKey in catalog.legacyImportVersionKeys {
            defaults.set(importVersion, forKey: legacyKey)
        }
        return Summary(
            trailsCreated: trailsCreated,
            passesCreated: passesCreated,
            existingTrailsSkipped: existingTrailsSkipped,
            invalidFeaturesSkipped: invalidFeaturesSkipped
        )
    }

    private static func difficulty(from properties: GeoJSONProperties,
                                   catalog: TrailCatalogDescriptor) -> TrailDifficulty? {
        if catalog.id == TrailCatalogRegistry.mountainCreek.id,
           let slug = properties.slug?.trimmedNonEmpty,
           let officialDifficulty = mountainCreekOfficialDifficultyBySlug[slug] {
            return officialDifficulty
        }

        if let rawValue = properties.difficulty,
           let difficulty = TrailDifficulty(rawValue: rawValue) {
            return difficulty
        }

        return switch properties.difficultyLabel?.trimmedNonEmpty {
        case "Green Circle": TrailDifficulty.green
        case "Blue Square": TrailDifficulty.blue
        case "Black Diamond": TrailDifficulty.black
        case "Double Black Diamond": TrailDifficulty.doubleBlack
        default: nil
        }
    }

    // These corrections follow the supplied Mountain Creek Bike Park map.
    // Its PRO LINE and EXPERT routes are represented as Double Black in
    // Berms. ADVANCED routes remain regular Black.
    private static let mountainCreekOfficialDifficultyBySlug: [String: TrailDifficulty] = [
        "progression-drops": .green,
        "deviant-kg9399": .green,
        "fat-lip-rf8hz9": .blue,
        "ripper-5ashmy": .doubleBlack,
        "dmlh-abz5gf": .doubleBlack,
        "utah": .doubleBlack,
        "flipper-bfr3vr": .doubleBlack,
        "pipeline-5y2v8p": .black,
        "the-pit": .doubleBlack,
        "covenant-d2z0pq": .doubleBlack,
        "anthem-2cky0y": .doubleBlack,
        "phantom-drop": .doubleBlack
    ]

    // RidePal published the same Lower Asylum centerline three times. Keep
    // the first stable ID as the canonical record and merge old records into
    // it during the v2 catalog migration.
    private static let mountainCreekRetiredTrailSlugs: [String: String] = [
        "lower-asylum-196712": "lower-asylum-1f4u6s",
        "lower-asylum-dud3va": "lower-asylum-1f4u6s"
    ]

    private static func retiredTrailSlugs(for catalog: TrailCatalogDescriptor) -> Set<String> {
        guard catalog.id == TrailCatalogRegistry.mountainCreek.id else { return [] }
        return Set(mountainCreekRetiredTrailSlugs.keys)
    }

    private static func reconcileRetiredTrails(for catalog: TrailCatalogDescriptor,
                                               trailsByID: [UUID: Trail],
                                               context: ModelContext) {
        guard catalog.id == TrailCatalogRegistry.mountainCreek.id else { return }

        for (retiredSlug, canonicalSlug) in mountainCreekRetiredTrailSlugs {
            let retiredID = stableID(for: retiredSlug, catalog: catalog)
            let canonicalID = stableID(for: canonicalSlug, catalog: catalog)
            guard let retiredTrail = trailsByID[retiredID],
                  let canonicalTrail = trailsByID[canonicalID],
                  retiredTrail.id != canonicalTrail.id else {
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
        return UUID(uuid: (
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
              let url = bundle.url(forResource: resourceName,
                                   withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let collection = try? JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data) else {
            return [:]
        }
        let reference = Date(timeIntervalSince1970: 0)
        var routes: [UUID: [RoutePoint]] = [:]
        for feature in collection.features {
            guard let slug = feature.properties.slug?.trimmedNonEmpty,
                  let points = feature.geometry.routePoints(referenceDate: reference),
                  points.count >= 2 else { continue }
            routes[stableID(for: slug, catalog: catalog)] = points
        }
        return routes
    }

    private static func versionKey(for catalog: TrailCatalogDescriptor) -> String {
        "\(versionKeyPrefix).\(catalog.id).version"
    }

    private static func isImported(_ catalog: TrailCatalogDescriptor,
                                   defaults: UserDefaults) -> Bool {
        let current = defaults.string(forKey: versionKey(for: catalog))
        if current == catalog.importVersion { return true }
        return catalog.legacyImportVersionKeys.contains {
            defaults.string(forKey: $0) == catalog.importVersion
        }
    }
}

// Keep source compatibility for the first version of the importer while all
// new code uses catalog terminology.
typealias TrailSeedImporter = TrailCatalogImporter

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

        let coordinates = coordinateLines.reduce(into: [[Double]]()) { result, line in
            result.append(contentsOf: line)
        }
        guard coordinates.count >= 2 else { return nil }

        let startDate = referenceDate.addingTimeInterval(-Double(coordinates.count - 1))
        let points = coordinates.enumerated().compactMap { index, coordinate -> RoutePoint? in
            guard coordinate.count >= 2,
                  coordinate[0].isFinite,
                  coordinate[1].isFinite,
                  (-180...180).contains(coordinate[0]),
                  (-90...90).contains(coordinate[1]) else {
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

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
