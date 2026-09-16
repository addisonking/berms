import Foundation

/// Latitude/longitude box around a trail centerline. Maps and matching use it
/// to skip trails that are far from the rider or off screen before touching
/// their geometry. Assumes a trail does not cross the antimeridian.
struct GeoBounds: Hashable, Sendable {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    init?(points: [RoutePoint]) {
        var minLatitude = 0.0
        var maxLatitude = 0.0
        var minLongitude = 0.0
        var maxLongitude = 0.0
        var hasPoint = false
        for point in points {
            guard point.latitude.isFinite, point.longitude.isFinite,
                (-90...90).contains(point.latitude),
                (-180...180).contains(point.longitude)
            else { continue }
            if !hasPoint {
                minLatitude = point.latitude
                maxLatitude = point.latitude
                minLongitude = point.longitude
                maxLongitude = point.longitude
                hasPoint = true
                continue
            }
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }
        guard hasPoint else { return nil }
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

    var center: Coordinate {
        Coordinate(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2)
    }

    func union(_ other: GeoBounds) -> GeoBounds {
        GeoBounds(
            minLatitude: min(minLatitude, other.minLatitude),
            maxLatitude: max(maxLatitude, other.maxLatitude),
            minLongitude: min(minLongitude, other.minLongitude),
            maxLongitude: max(maxLongitude, other.maxLongitude))
    }

    func contains(_ coordinate: Coordinate, paddingMeters: Double = 0) -> Bool {
        let latitudePadding = paddingMeters / 111_000
        let longitudePadding =
            paddingMeters / (111_000 * max(0.1, cos(coordinate.latitude * .pi / 180)))
        return coordinate.latitude >= minLatitude - latitudePadding
            && coordinate.latitude <= maxLatitude + latitudePadding
            && coordinate.longitude >= minLongitude - longitudePadding
            && coordinate.longitude <= maxLongitude + longitudePadding
    }

    func intersects(
        centerLatitude: Double,
        centerLongitude: Double,
        latitudeSpan: Double,
        longitudeSpan: Double
    ) -> Bool {
        let regionMinLatitude = centerLatitude - latitudeSpan / 2
        let regionMaxLatitude = centerLatitude + latitudeSpan / 2
        let regionMinLongitude = centerLongitude - longitudeSpan / 2
        let regionMaxLongitude = centerLongitude + longitudeSpan / 2
        return minLatitude <= regionMaxLatitude && maxLatitude >= regionMinLatitude
            && minLongitude <= regionMaxLongitude && maxLongitude >= regionMinLongitude
    }

    private init(
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double
    ) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }
}

/// Decodes trail geometry once per (trail, updatedAt) and caches what the maps
/// and lists derive from it: length, label anchor, and bounds. Hundreds of
/// trails make the un-cached version of this the hot path on every render.
@MainActor
final class TrailGeometryStore {
    static let shared = TrailGeometryStore()

    struct Metrics {
        let pointCount: Int
        let distanceMeters: Double
        let labelCoordinate: Coordinate?
        let bounds: GeoBounds?

        /// A single point is not a drawable trail.
        var hasGeometry: Bool { pointCount >= 2 }
    }

    private struct Cached {
        let updatedAt: Date
        let metrics: Metrics
    }

    private var cache: [UUID: Cached] = [:]

    func metrics(for trail: Trail) -> Metrics {
        if let cached = cache[trail.id], cached.updatedAt == trail.updatedAt {
            return cached.metrics
        }
        let points = trail.points
        let metrics = Metrics(
            pointCount: points.count,
            distanceMeters: Self.distanceMeters(points),
            labelCoordinate: Self.labelCoordinate(points),
            bounds: GeoBounds(points: points))
        cache[trail.id] = Cached(updatedAt: trail.updatedAt, metrics: metrics)
        return metrics
    }

    func invalidateAll() {
        cache.removeAll()
    }

    private static func distanceMeters(_ points: [RoutePoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            let start = Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return total + start.distance(to: end)
        }
    }

    private static func labelCoordinate(_ points: [RoutePoint]) -> Coordinate? {
        guard !points.isEmpty else { return nil }
        let point = points[points.count / 2]
        return Coordinate(latitude: point.latitude, longitude: point.longitude)
    }
}
