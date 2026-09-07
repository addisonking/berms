import Foundation

struct RouteCleaner: Sendable {
    struct Configuration: Sendable {
        var lowSpeedThreshold: Double = 1.5
        var minimumDwellDuration: TimeInterval = 4
        var maximumDwellExtent: Double = 80
        var maximumHorizontalAccuracy: Double = 80
        var maximumSpikeDistance: Double = 45
        var smoothingDistance: Double = 80
    }

    let configuration: Configuration

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func clean(_ samples: [TrackSample]) -> [TrackSample] {
        let valid = samples.filter {
            $0.horizontalAccuracy.isFinite
                && $0.horizontalAccuracy >= 0
                && $0.horizontalAccuracy <= configuration.maximumHorizontalAccuracy
        }
        let cleanedPoints = clean(valid.map(\.routePoint))
        return cleanedPoints.map { point in
            let source = valid.min {
                abs($0.timestamp.timeIntervalSince(point.timestamp))
                    < abs($1.timestamp.timeIntervalSince(point.timestamp))
            }
            return TrackSample(
                coordinate: Coordinate(latitude: point.latitude, longitude: point.longitude),
                altitude: point.altitude,
                speed: point.speed,
                course: source?.course ?? -1,
                horizontalAccuracy: source?.horizontalAccuracy ?? configuration.maximumHorizontalAccuracy,
                timestamp: point.timestamp,
                isStationary: source?.isStationary ?? false,
                isCycling: source?.isCycling ?? false,
                isAutomotive: source?.isAutomotive ?? false
            )
        }
    }

    func clean(_ points: [RoutePoint]) -> [RoutePoint] {
        let valid = points.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
                && (-90...90).contains($0.latitude)
                && (-180...180).contains($0.longitude)
        }
        guard valid.count >= 3 else { return valid }

        let withoutSpikes = removeSpikes(from: valid)
        let withoutStars = collapseDwellClusters(in: withoutSpikes)
        return smoothSmallCorrections(in: withoutStars)
    }

    private func removeSpikes(from points: [RoutePoint]) -> [RoutePoint] {
        guard points.count >= 3 else { return points }
        var result = [points[0]]
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]
            let shortcut = coordinate(for: previous).distance(to: coordinate(for: next))
            let detour = coordinate(for: previous).distance(to: coordinate(for: current))
                + coordinate(for: current).distance(to: coordinate(for: next))
            if detour > max(configuration.maximumSpikeDistance * 2, shortcut * 2.8 + 15),
               current.speed <= configuration.lowSpeedThreshold * 2 {
                continue
            }
            result.append(current)
        }
        result.append(points[points.count - 1])
        return result
    }

    private func collapseDwellClusters(in points: [RoutePoint]) -> [RoutePoint] {
        var result: [RoutePoint] = []
        var index = 0

        while index < points.count {
            guard points[index].speed <= configuration.lowSpeedThreshold else {
                result.append(points[index])
                index += 1
                continue
            }

            var end = index
            while end + 1 < points.count,
                  points[end + 1].speed <= configuration.lowSpeedThreshold,
                  coordinate(for: points[index]).distance(to: coordinate(for: points[end + 1]))
                    <= configuration.maximumDwellExtent {
                end += 1
            }

            let cluster = Array(points[index...end])
            let duration = (cluster.last?.timestamp ?? .distantPast)
                .timeIntervalSince(cluster.first?.timestamp ?? .distantPast)
            if cluster.count >= 2 && duration >= configuration.minimumDwellDuration {
                if let before = result.last, end + 1 < points.count {
                    // Bridge a break with one stable point between the last point
                    // before the stop and the first point after it. Averaging the
                    // GPS wander itself can move the route off the trail.
                    result.append(interpolatedPoint(from: before, to: points[end + 1],
                                                    timestamp: cluster[cluster.count / 2].timestamp))
                } else {
                    result.append(representative(of: cluster))
                }
            } else {
                result.append(contentsOf: cluster)
            }
            index = end + 1
        }
        return result
    }

    private func smoothSmallCorrections(in points: [RoutePoint]) -> [RoutePoint] {
        guard points.count >= 3 else { return points }
        return points.indices.map { index in
            guard index > 0, index + 1 < points.count else { return points[index] }
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]
            let previousDistance = coordinate(for: previous).distance(to: coordinate(for: current))
            let nextDistance = coordinate(for: current).distance(to: coordinate(for: next))
            guard previousDistance <= configuration.smoothingDistance,
                  nextDistance <= configuration.smoothingDistance else { return current }
            return RoutePoint(
                latitude: previous.latitude * 0.2 + current.latitude * 0.6 + next.latitude * 0.2,
                longitude: previous.longitude * 0.2 + current.longitude * 0.6 + next.longitude * 0.2,
                altitude: previous.altitude * 0.2 + current.altitude * 0.6 + next.altitude * 0.2,
                speed: current.speed,
                timestamp: current.timestamp
            )
        }
    }

    private func representative(of points: [RoutePoint]) -> RoutePoint {
        let divisor = Double(points.count)
        return RoutePoint(
            latitude: points.reduce(0) { $0 + $1.latitude } / divisor,
            longitude: points.reduce(0) { $0 + $1.longitude } / divisor,
            altitude: points.reduce(0) { $0 + $1.altitude } / divisor,
            speed: 0,
            timestamp: points[points.count / 2].timestamp
        )
    }

    private func interpolatedPoint(from start: RoutePoint, to end: RoutePoint,
                                   timestamp: Date) -> RoutePoint {
        RoutePoint(
            latitude: (start.latitude + end.latitude) / 2,
            longitude: (start.longitude + end.longitude) / 2,
            altitude: (start.altitude + end.altitude) / 2,
            speed: 0,
            timestamp: timestamp
        )
    }

    private func coordinate(for point: RoutePoint) -> Coordinate {
        Coordinate(latitude: point.latitude, longitude: point.longitude)
    }
}

struct RouteMetrics: Sendable {
    static func distance(of points: [RoutePoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(to: Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    static func vertical(of points: [RoutePoint], kind: SegmentKind) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let change = pair.1.altitude - pair.0.altitude
            return total + (kind == .run ? max(0, -change) : max(0, change))
        }
    }

    static func maximumSpeed(of points: [RoutePoint]) -> Double {
        points.map(\.speed).max() ?? 0
    }
}

struct TrailMatch: Sendable {
    let trailID: UUID
    let score: Double
    let averageDistance: Double
}

struct TrailMatchSection: Identifiable, Sendable {
    let trailID: UUID
    let startIndex: Int
    let endIndex: Int
    let trailStartProgress: Double
    let trailEndProgress: Double
    let score: Double
    let averageDistance: Double

    var id: String {
        "\(trailID.uuidString)-\(startIndex)-\(endIndex)-"
            + "\(trailStartProgress)-\(trailEndProgress)"
    }

    var range: Range<Int> { startIndex..<(endIndex + 1) }
    var trailProgress: ClosedRange<Double> {
        min(trailStartProgress, trailEndProgress)...max(trailStartProgress, trailEndProgress)
    }
}

struct TrailRouteMatcher: Sendable {
    var maximumDistance: Double = 75
    var minimumScore: Double = 0.55
    var minimumWinningMargin: Double = 0.08

    private struct ScoredSection: Sendable {
        let range: Range<Int>
        let trailStartProgress: Double
        let trailEndProgress: Double
        let score: Double
        let averageDistance: Double
    }

    func matchingSections(for route: [RoutePoint], trails: [Trail]) -> [TrailMatchSection] {
        guard route.count >= 2 else { return [] }

        let candidates = trails.compactMap { trail -> TrailMatchSection? in
            var candidateRoutes = [trail.points]
            candidateRoutes.append(contentsOf: trail.passes.map(\.points))
            let scoredRoutes = candidateRoutes
                .filter { $0.count >= 2 }
                .compactMap { score(route: route, against: $0) }
            let best = scoredRoutes.max { $0.score < $1.score }
            guard let best, best.score >= minimumScore else { return nil }
            return TrailMatchSection(trailID: trail.id,
                                     startIndex: best.range.lowerBound,
                                     endIndex: best.range.upperBound - 1,
                                     trailStartProgress: best.trailStartProgress,
                                     trailEndProgress: best.trailEndProgress,
                                     score: best.score,
                                     averageDistance: best.averageDistance)
        }
        .sorted { $0.score > $1.score }

        // The same GPS points can be close to neighboring trails. Keep the
        // strongest evidence for each section, while allowing a small shared
        // boundary at a trail junction.
        var accepted: [TrailMatchSection] = []
        for candidate in candidates {
            let overlap = accepted.map { overlapCount(candidate.range, $0.range) }.max() ?? 0
            let allowedOverlap = max(2, Int(Double(candidate.range.count) * 0.35))
            guard overlap <= allowedOverlap else { continue }
            accepted.append(candidate)
        }
        return accepted.sorted { $0.startIndex < $1.startIndex }
    }

    func bestMatch(for route: [RoutePoint], trails: [Trail]) -> TrailMatch? {
        guard route.count >= 2 else { return nil }
        let candidates = trails.compactMap { trail -> TrailMatch? in
            // A trail's average is useful for a stable centerline, but a single
            // noisy or offset pass can pull that average away from a real ride.
            // Score the original passes too and keep the strongest evidence.
            let candidateRoutes = [trail.points] + trail.passes.map(\.points)
            let scores = candidateRoutes
                .filter { candidate in candidate.count >= 2 }
                .compactMap { candidate in self.score(route: route, against: candidate) }
            guard let score = scores.max(by: { left, right in left.score < right.score }) else {
                return nil
            }
            return TrailMatch(trailID: trail.id, score: score.score, averageDistance: score.averageDistance)
        }.sorted { $0.score > $1.score }
        guard let winner = candidates.first, winner.score >= minimumScore else { return nil }
        if let runnerUp = candidates.dropFirst().first,
           winner.score - runnerUp.score < minimumWinningMargin {
            return nil
        }
        return winner
    }

    private func score(route: [RoutePoint], against trail: [RoutePoint]) -> ScoredSection? {
        let distances = route.map { nearestDistance(from: $0, to: trail) }
        guard let range = bestContiguousMatchRange(in: route, distances: distances) else { return nil }
        let matchedRoute = Array(route[range])
        let matchedDistances = Array(distances[range])
        let trailLength = RouteMetrics.distance(of: trail)
        let matchedLength = RouteMetrics.distance(of: matchedRoute)
        let minimumOverlap = min(250, max(40, trailLength * 0.4))
        guard matchedLength >= minimumOverlap else { return nil }

        let overlapScore = min(1, matchedLength / max(trailLength, 1))
        let routeCoverage = Double(matchedRoute.count) / Double(route.count)
        let averageDistance = matchedDistances.reduce(0, +) / Double(matchedDistances.count)
        let distanceScore = max(0, 1 - averageDistance / (maximumDistance * 2))
        let endpoint = endpointScore(route: matchedRoute, trail: trail)
        guard endpoint.directionIsCompatible else { return nil }
        let lengthScore = 1 - min(1, abs(matchedLength - trailLength) / max(trailLength, 1))
        return ScoredSection(
            range: range,
            trailStartProgress: progress(at: endpoint.firstIndex, in: trail),
            trailEndProgress: progress(at: endpoint.lastIndex, in: trail),
            score: overlapScore * 0.45 + routeCoverage * 0.1 + distanceScore * 0.2
                + endpoint.score * 0.15 + lengthScore * 0.1,
            averageDistance: averageDistance
        )
    }

    private func overlapCount(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Int {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }

    private func bestContiguousMatchRange(in route: [RoutePoint], distances: [Double]) -> Range<Int>? {
        guard route.count == distances.count, route.count >= 2 else { return nil }
        var best: Range<Int>?
        var start: Int?

        for index in 0...distances.count {
            let isCovered = index < distances.count && distances[index] <= maximumDistance
            if isCovered {
                start = start ?? index
                continue
            }

            if let start, index - start >= 2 {
                let candidate = start..<index
                if best == nil || RouteMetrics.distance(of: Array(route[candidate]))
                    > RouteMetrics.distance(of: Array(route[best!])) {
                    best = candidate
                }
            }
            start = nil
        }
        return best
    }

    private func endpointScore(route: [RoutePoint], trail: [RoutePoint]) -> (
        score: Double,
        directionIsCompatible: Bool,
        firstIndex: Int,
        lastIndex: Int
    ) {
        guard let first = route.first, let last = route.last,
              !trail.isEmpty,
              let firstIndex = nearestPointIndex(to: first, in: trail),
              let lastIndex = nearestPointIndex(to: last, in: trail) else {
            return (0, false, 0, 0)
        }
        let firstDistance = nearestDistance(from: first, to: trail)
        let lastDistance = nearestDistance(from: last, to: trail)
        let endpointDistance = (firstDistance + lastDistance) / 2
        let compatible = lastIndex >= firstIndex
        return (max(0, 1 - endpointDistance / (maximumDistance * 2)), compatible,
                firstIndex, lastIndex)
    }

    private func nearestPointIndex(to point: RoutePoint, in route: [RoutePoint]) -> Int? {
        guard !route.isEmpty else { return nil }
        let pointCoordinate = coordinate(for: point)
        return route.indices.min { left, right in
            pointCoordinate.distance(to: coordinate(for: route[left]))
                < pointCoordinate.distance(to: coordinate(for: route[right]))
        }
    }

    private func nearestDistance(from point: RoutePoint, to route: [RoutePoint]) -> Double {
        guard route.count >= 2 else {
            return route.first.map { coordinate(for: point).distance(to: coordinate(for: $0)) }
                ?? .greatestFiniteMagnitude
        }
        let origin = coordinate(for: point)
        let projectedPoint = project(origin, relativeTo: origin)
        return zip(route, route.dropFirst()).map { start, end in
            let a = project(coordinate(for: start), relativeTo: origin)
            let b = project(coordinate(for: end), relativeTo: origin)
            let dx = b.x - a.x
            let dy = b.y - a.y
            let denominator = dx * dx + dy * dy
            let fraction = denominator > 0
                ? max(0, min(1, ((projectedPoint.x - a.x) * dx + (projectedPoint.y - a.y) * dy) / denominator))
                : 0
            let closestX = a.x + dx * fraction
            let closestY = a.y + dy * fraction
            return hypot(projectedPoint.x - closestX, projectedPoint.y - closestY)
        }.min() ?? .greatestFiniteMagnitude
    }

    private func project(_ coordinate: Coordinate, relativeTo origin: Coordinate) -> (x: Double, y: Double) {
        let latitudeScale = cos(origin.latitude * .pi / 180)
        return (
            (coordinate.longitude - origin.longitude) * 111_000 * latitudeScale,
            (coordinate.latitude - origin.latitude) * 111_000
        )
    }

    private func coordinate(for point: RoutePoint) -> Coordinate {
        Coordinate(latitude: point.latitude, longitude: point.longitude)
    }

    private func progress(at index: Int, in route: [RoutePoint]) -> Double {
        guard route.count >= 2 else { return 0 }
        let clampedIndex = min(max(index, 0), route.count - 1)
        let total = RouteMetrics.distance(of: route)
        guard total > 0 else {
            return Double(clampedIndex) / Double(route.count - 1)
        }
        let distance = zip(route, route.dropFirst())
            .prefix(clampedIndex)
            .reduce(0) { total, pair in
                total + coordinate(for: pair.0).distance(to: coordinate(for: pair.1))
            }
        return max(0, min(1, distance / total))
    }
}

struct TrailRouteSlice {
    static func slice(_ points: [RoutePoint], progress: ClosedRange<Double>) -> [RoutePoint] {
        guard points.count >= 2 else { return points }

        let total = RouteMetrics.distance(of: points)
        guard total > 0 else { return points }

        let startProgress = max(0, min(1, progress.lowerBound))
        let endProgress = max(startProgress, min(1, progress.upperBound))
        let startDistance = total * startProgress
        let endDistance = total * endProgress

        var cumulative = [0.0]
        cumulative.reserveCapacity(points.count)
        for pair in zip(points, points.dropFirst()) {
            let start = Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude)
            cumulative.append(cumulative.last! + start.distance(to: end))
        }

        func point(at distance: Double) -> RoutePoint {
            if distance <= 0 { return points[0] }
            if distance >= total { return points[points.count - 1] }

            var segmentIndex = points.count - 2
            for index in 0..<(points.count - 1) {
                if cumulative[index + 1] >= distance {
                    segmentIndex = index
                    break
                }
            }
            let segmentStart = cumulative[segmentIndex]
            let segmentEnd = cumulative[segmentIndex + 1]
            let fraction = segmentEnd > segmentStart
                ? (distance - segmentStart) / (segmentEnd - segmentStart)
                : 0
            let start = points[segmentIndex]
            let end = points[segmentIndex + 1]
            return RoutePoint(
                latitude: interpolate(start.latitude, end.latitude, fraction),
                longitude: interpolate(start.longitude, end.longitude, fraction),
                altitude: interpolate(start.altitude, end.altitude, fraction),
                speed: interpolate(start.speed, end.speed, fraction),
                timestamp: start.timestamp.addingTimeInterval(
                    end.timestamp.timeIntervalSince(start.timestamp) * fraction
                )
            )
        }

        var result = [point(at: startDistance)]
        for index in 1..<(points.count - 1) {
            if cumulative[index] > startDistance && cumulative[index] < endDistance {
                result.append(points[index])
            }
        }
        result.append(point(at: endDistance))
        return result
    }

    private static func interpolate(_ start: Double, _ end: Double, _ fraction: Double) -> Double {
        start + (end - start) * fraction
    }
}

@MainActor
final class TrailRouteMatchCache {
    static let shared = TrailRouteMatchCache()

    private struct Entry {
        let trailRevision: String
        let match: TrailMatch?
        let sections: [TrailMatchSection]
    }

    private var entries: [UUID: Entry] = [:]
    private let matcher = TrailRouteMatcher()

    private init() {}

    func match(for segment: RideSegment, trails: [Trail]) -> TrailMatch? {
        entry(for: segment, trails: trails).match
    }

    func matchingSections(for segment: RideSegment, trails: [Trail]) -> [TrailMatchSection] {
        entry(for: segment, trails: trails).sections
    }

    private func entry(for segment: RideSegment, trails: [Trail]) -> Entry {
        let revision = trails
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }
            .joined(separator: "|")
        if let entry = entries[segment.id], entry.trailRevision == revision {
            return entry
        }
        let match = matcher.bestMatch(for: segment.points, trails: trails)
        let sections = matcher.matchingSections(for: segment.points, trails: trails)
        let newEntry = Entry(trailRevision: revision, match: match, sections: sections)
        entries[segment.id] = newEntry
        return newEntry
    }

    func invalidate(segmentID: UUID? = nil) {
        if let segmentID {
            entries[segmentID] = nil
        } else {
            entries.removeAll()
        }
    }
}
