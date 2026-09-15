import CryptoKit
import Foundation

/// Loads the bundled RidePal trail catalog into `TrailRouteCandidate` values so
/// Berms Studio can name runs with the same matcher the iOS app uses.
enum TrailCatalog {
    static func loadBundled() -> [TrailRouteCandidate] {
        guard let url = Bundle.main.url(forResource: "mountain-creek-ridepal-trails-with-metadata",
                                        withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let candidates = try? candidates(from: data) else {
            return []
        }
        return candidates
    }

    static func candidates(from data: Data) throws -> [TrailRouteCandidate] {
        let collection = try JSONDecoder().decode(FeatureCollection.self, from: data)
        let reference = Date(timeIntervalSince1970: 0)
        return collection.features.compactMap { feature -> TrailRouteCandidate? in
            guard let slug = feature.properties.slug?.trimmedNonEmpty,
                  let name = feature.properties.name?.trimmedNonEmpty,
                  let difficulty = difficulty(from: feature.properties),
                  let routes = feature.geometry.routeLines(referenceDate: reference) else {
                return nil
            }
            return TrailRouteCandidate(id: stableID(for: slug), name: name,
                                       difficulty: difficulty, routes: routes)
        }
    }

    private static func difficulty(from properties: Properties) -> TrailDifficulty? {
        if let slug = properties.slug?.trimmedNonEmpty,
           let official = officialDifficultyBySlug[slug] {
            return official
        }
        if let raw = properties.difficulty, let value = TrailDifficulty(rawValue: raw) {
            return value
        }
        switch properties.difficultyLabel?.trimmedNonEmpty {
        case "Green Circle": return .green
        case "Blue Square": return .blue
        case "Black Diamond": return .black
        case "Double Black Diamond": return .doubleBlack
        default: return nil
        }
    }

    private static func stableID(for slug: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("berms:ridepal:\(slug)".utf8)).prefix(16))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                           digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }

    // Mountain Creek map corrections: PRO/EXPERT lines are Double Black in Berms.
    private static let officialDifficultyBySlug: [String: TrailDifficulty] = [
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

    private struct FeatureCollection: Decodable {
        let features: [Feature]
    }

    private struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry
    }

    private struct Properties: Decodable {
        let name: String?
        let slug: String?
        let difficulty: String?
        let difficultyLabel: String?
    }

    private enum Geometry: Decodable {
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

        func routeLines(referenceDate: Date) -> [[RoutePoint]]? {
            let lines: [[[Double]]]
            switch self {
            case .lineString(let coordinates): lines = [coordinates]
            case .multiLineString(let coordinates): lines = coordinates
            }
            let routes = lines.compactMap { route(referenceDate: referenceDate, coordinates: $0) }
            return routes.isEmpty ? nil : routes
        }

        private func route(referenceDate: Date, coordinates: [[Double]]) -> [RoutePoint]? {
            guard coordinates.count >= 2 else { return nil }
            let start = referenceDate.addingTimeInterval(-Double(coordinates.count - 1))
            let points = coordinates.enumerated().compactMap { index, coordinate -> RoutePoint? in
                guard coordinate.count >= 2,
                      (-180...180).contains(coordinate[0]),
                      (-90...90).contains(coordinate[1]) else { return nil }
                return RoutePoint(latitude: coordinate[1], longitude: coordinate[0],
                                  altitude: 0, speed: 0,
                                  timestamp: start.addingTimeInterval(Double(index)))
            }
            return points.count >= 2 ? points : nil
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
