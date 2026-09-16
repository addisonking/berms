import Foundation

/// The bundled resort manifest. Adding a resort means adding its entry here and
/// its trail resources to the bundle; no Swift changes are required.
struct ResortCatalogManifest: Sendable {
    static let empty = ResortCatalogManifest(resorts: [])

    let resorts: [ResortDescriptor]

    var catalogs: [TrailCatalogDescriptor] { resorts.flatMap(\.catalogs) }
}

struct ResortBoundary: Hashable, Sendable {
    let center: Coordinate
    let radiusMeters: Double

    func contains(_ coordinate: Coordinate) -> Bool {
        center.distance(to: coordinate) <= radiusMeters
    }
}

struct ResortDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let region: String?
    let boundary: ResortBoundary
    let catalogs: [TrailCatalogDescriptor]

    var displayName: String { name }

    var seasons: [SeasonBucket] {
        var seen: Set<SeasonBucket> = []
        return catalogs.map(\.season).filter { seen.insert($0).inserted }
    }
}

enum ResortCatalogLoader {
    static let resourceName = "resorts"
    static let supportedSchemaVersion = 1

    enum ManifestError: LocalizedError {
        case missingResource
        case unsupportedSchema(Int)
        case invalidManifest(String)

        var errorDescription: String? {
            switch self {
            case .missingResource:
                "The bundled resort manifest could not be found."
            case .unsupportedSchema(let version):
                "The bundled resort manifest uses an unsupported format (version \(version))."
            case .invalidManifest(let detail):
                "The bundled resort manifest could not be read: \(detail)"
            }
        }
    }

    static func load(bundle: Bundle = .main) throws -> ResortCatalogManifest {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw ManifestError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> ResortCatalogManifest {
        // Read the version first, so a future format reports its version
        // rather than a decode error about keys it renamed.
        let schema: SchemaDTO
        do {
            schema = try JSONDecoder().decode(SchemaDTO.self, from: data)
        } catch {
            throw ManifestError.invalidManifest(error.localizedDescription)
        }
        guard schema.schemaVersion == supportedSchemaVersion else {
            throw ManifestError.unsupportedSchema(schema.schemaVersion)
        }

        let manifest: ManifestDTO
        do {
            manifest = try JSONDecoder().decode(ManifestDTO.self, from: data)
        } catch {
            throw ManifestError.invalidManifest(error.localizedDescription)
        }
        return ResortCatalogManifest(
            resorts: manifest.resorts.map { resort in
                ResortDescriptor(
                    id: resort.id,
                    name: resort.name,
                    region: resort.region,
                    boundary: ResortBoundary(
                        center: resort.bounds.center,
                        radiusMeters: resort.bounds.radiusMeters),
                    catalogs: resort.catalogs.map { catalog in
                        TrailCatalogDescriptor(
                            id: catalog.id,
                            season: catalog.season,
                            resortID: resort.id,
                            resortName: resort.name,
                            bundledResourceName: catalog.resource,
                            importVersion: catalog.version,
                            stableIDNamespace: catalog.stableIDNamespace,
                            legacyImportVersionKeys: catalog.legacyVersionKeys ?? [],
                            difficultyOverrides: catalog.difficultyOverrides ?? [:],
                            aliases: catalog.aliases ?? [:]
                        )
                    })
            })
    }

    private struct SchemaDTO: Decodable {
        let schemaVersion: Int
    }

    private struct ManifestDTO: Decodable {
        let resorts: [ResortDTO]
    }

    private struct ResortDTO: Decodable {
        let id: String
        let name: String
        let region: String?
        let bounds: BoundaryDTO
        let catalogs: [CatalogDTO]
    }

    private struct BoundaryDTO: Decodable {
        let center: Coordinate
        let radiusMeters: Double
    }

    private struct CatalogDTO: Decodable {
        let id: String
        let season: SeasonBucket
        let resource: String?
        let version: String
        let stableIDNamespace: String
        let legacyVersionKeys: [String]?
        let difficultyOverrides: [String: TrailDifficulty]?
        let aliases: [String: String]?
    }
}
