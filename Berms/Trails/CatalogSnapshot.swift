import CryptoKit
import Foundation

struct CatalogSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let revision: String
    let resorts: [Park]

    struct Park: Codable, Sendable {
        let id: String
        let catalogs: [Catalog]
    }

    struct Catalog: Codable, Sendable {
        let id: String
        let resource: String?
        let version: String
        let stableIDNamespace: String
        let checksum: String
        let url: String
        let trailHashes: [String: String]
        let aliases: [String: String]?
    }

    var catalogs: [Catalog] { resorts.flatMap(\.catalogs) }
}

/// A pointer file activates a complete immutable directory in one atomic write.
final class CatalogSnapshotStore: @unchecked Sendable {
    static let shared = CatalogSnapshotStore()
    let directory: URL
    private let lock = NSLock()
    private var cachedDirectory: URL?
    private var cachedRegistry: ResortCatalogManifest?

    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trail catalogs", isDirectory: true)
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("active.json")),
            let revision = try? JSONDecoder().decode(String.self, from: data), Self.isHash(revision)
        {
            cachedDirectory = self.directory.appendingPathComponent(revision, isDirectory: true)
        }
    }

    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var activeDirectory: URL? {
        lock.lock()
        defer { lock.unlock() }
        return cachedDirectory
    }

    func registryManifest() -> ResortCatalogManifest? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedRegistry { return cachedRegistry }
        let url =
            cachedDirectory?.appendingPathComponent("catalog-manifest.json")
            ?? Bundle.main.url(forResource: "trail-baselines", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
            let manifest = try? ResortCatalogLoader.decode(data)
        else { return nil }
        cachedRegistry = manifest
        return manifest
    }

    func manifestData(bundle: Bundle = .main) throws -> Data {
        if let activeDirectory {
            return try Data(contentsOf: activeDirectory.appendingPathComponent("catalog-manifest.json"))
        }
        guard let url = bundle.url(forResource: "trail-baselines", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    func snapshot(bundle: Bundle = .main) throws -> CatalogSnapshot {
        try JSONDecoder().decode(CatalogSnapshot.self, from: manifestData(bundle: bundle))
    }

    func catalogData(_ catalog: TrailCatalogDescriptor, bundle: Bundle = .main) throws -> Data {
        if let activeDirectory {
            return try Data(contentsOf: activeDirectory.appendingPathComponent(catalog.id + ".geojson"))
        }
        guard let resource = catalog.bundledResourceName,
            let url = bundle.url(forResource: resource, withExtension: "geojson")
        else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: url)
    }

    static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    func validate(manifest: Data, packages: [String: Data]) throws -> CatalogSnapshot {
        let snapshot = try JSONDecoder().decode(CatalogSnapshot.self, from: manifest)
        guard snapshot.schemaVersion == 1, Self.isHash(snapshot.revision), !snapshot.catalogs.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        _ = try ResortCatalogLoader.decode(manifest)
        var ids = Set<String>()
        var namespaces = Set<String>()
        for catalog in snapshot.catalogs {
            guard catalog.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                !catalog.id.isEmpty, ids.insert(catalog.id).inserted,
                namespaces.insert(catalog.stableIDNamespace).inserted,
                let data = packages[catalog.id], Self.checksum(data) == catalog.checksum,
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "FeatureCollection",
                let features = object["features"] as? [[String: Any]]
            else { throw CocoaError(.fileReadCorruptFile) }
            try TrailCatalogImporter.validateApprovedCatalog(data)
            var slugs = Set<String>()
            for feature in features {
                guard let properties = feature["properties"] as? [String: Any],
                    let slug = properties["slug"] as? String, !slug.isEmpty,
                    slugs.insert(slug).inserted,
                    let name = properties["name"] as? String, !name.isEmpty,
                    let geometry = feature["geometry"] as? [String: Any],
                    Self.validGeometry(geometry)
                else { throw CocoaError(.fileReadCorruptFile) }
                if catalog.aliases?[slug] == nil {
                    guard let hash = catalog.trailHashes[slug], Self.isHash(hash) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
            }
            guard Set(catalog.trailHashes.keys) == slugs.subtracting(Set(catalog.aliases?.keys.map { $0 } ?? [])) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Existing namespaces and aliases are identity contracts, even across snapshots.
            if let previous = try? self.snapshot().catalogs.first(where: { $0.id == catalog.id }) {
                guard previous.stableIDNamespace == catalog.stableIDNamespace,
                    (previous.aliases ?? [:]).allSatisfy({ catalog.aliases?[$0.key] == $0.value })
                else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        return snapshot
    }

    static func validGeometry(_ geometry: [String: Any]) -> Bool {
        let lines: [[[Double]]]
        switch geometry["type"] as? String {
        case "LineString":
            guard let line = geometry["coordinates"] as? [[Double]] else { return false }
            lines = [line]
        case "MultiLineString":
            guard let value = geometry["coordinates"] as? [[[Double]]] else { return false }
            lines = value
        default: return false
        }
        return !lines.isEmpty
            && lines.allSatisfy { line in
                line.count >= 2
                    && line.allSatisfy { point in
                        (2...3).contains(point.count) && point.allSatisfy(\.isFinite)
                            && (-180...180).contains(point[0]) && (-90...90).contains(point[1])
                    }
            }
    }

    func withActivatedSnapshot(manifest: Data, packages: [String: Data], apply: () throws -> Void) throws {
        let pointer = directory.appendingPathComponent("active.json")
        let previous = try? Data(contentsOf: pointer)
        let previousDirectory = activeDirectory
        try activate(manifest: manifest, packages: packages)
        do {
            try apply()
        } catch {
            if let previous {
                try previous.write(to: pointer, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: pointer)
            }
            lock.lock()
            cachedDirectory = previousDirectory
            cachedRegistry = nil
            lock.unlock()
            throw error
        }
    }

    func activate(manifest: Data, packages: [String: Data]) throws {
        let snapshot = try validate(manifest: manifest, packages: packages)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for catalog in snapshot.catalogs {
            try packages[catalog.id]?.write(
                to: staging.appendingPathComponent(catalog.id + ".geojson"), options: .atomic)
        }
        try manifest.write(to: staging.appendingPathComponent("catalog-manifest.json"), options: .atomic)
        let destination = directory.appendingPathComponent(snapshot.revision, isDirectory: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: staging, to: destination)
        } else {
            let existingManifest = try Data(contentsOf: destination.appendingPathComponent("catalog-manifest.json"))
            guard existingManifest == manifest else { throw CocoaError(.fileReadCorruptFile) }
            for catalog in snapshot.catalogs {
                let data = try Data(contentsOf: destination.appendingPathComponent(catalog.id + ".geojson"))
                guard Self.checksum(data) == catalog.checksum else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        try JSONEncoder().encode(snapshot.revision).write(
            to: directory.appendingPathComponent("active.json"), options: .atomic)
        cachedDirectory = destination
        cachedRegistry = try ResortCatalogLoader.decode(manifest)
    }
}
