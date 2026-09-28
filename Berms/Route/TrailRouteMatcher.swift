import Foundation

struct TrailMatch: Sendable {
    let trailID: UUID
    let score: Double
    let averageDistance: Double
}

struct TrailMatchSection: Identifiable, Sendable {
    let trailID: UUID
    let routeIndex: Int
    let startIndex: Int
    let endIndex: Int
    let trailStartProgress: Double
    let trailEndProgress: Double
    let score: Double
    let averageDistance: Double

    var id: String {
        "\(trailID.uuidString)-\(routeIndex)-\(startIndex)-\(endIndex)-"
            + "\(trailStartProgress)-\(trailEndProgress)"
    }

    var range: Range<Int> { startIndex..<(endIndex + 1) }
    var trailProgress: ClosedRange<Double> {
        min(trailStartProgress, trailEndProgress)...max(trailStartProgress, trailEndProgress)
    }
}

struct TrailRouteCandidate: Sendable {
    let id: UUID
    let name: String
    let difficulty: TrailDifficulty
    let routes: [[RoutePoint]]
}

extension Trail {
    var orderedPasses: [TrailPass] {
        passes.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Routes in matcher order: the primary route, then recorded passes by date.
    /// Every consumer must use this order because `TrailMatchSection.routeIndex`
    /// indexes into it.
    var matcherRoutes: [[RoutePoint]] {
        [points] + orderedPasses.map(\.points)
    }
}

struct TrailRouteMatchResult: Sendable {
    let match: TrailMatch?
    let sections: [TrailMatchSection]
}

struct TrailRouteMatcher: Sendable {
    // A wide proximity radius can make a ride on a neighboring connector look
    // like a trail match. Keep enough room for normal phone GPS drift, but make
    // the score depend on progress along the trail too.
    var maximumDistance: Double = 50
    var minimumScore: Double = 0.58
    var minimumWinningMargin: Double = 0.08
    // Parallel trails (for example a shared fall line) land inside the same
    // proximity radius. A route stretch only belongs to a trail when it stayed
    // closer than every other centerline across the whole stretch.
    var parallelTieMargin: Double = 2

    private struct ScoredSection: Sendable {
        let routeIndex: Int
        let range: Range<Int>
        let trailStartProgress: Double
        let trailEndProgress: Double
        let score: Double
        let averageDistance: Double
    }

    private struct TrailProjection: Sendable {
        let distance: Double
        let progress: Double
    }

    func matchingSections(for route: [RoutePoint], trails: [Trail]) -> [TrailMatchSection] {
        matchResult(for: route, trails: trails).sections
    }

    func bestMatch(for route: [RoutePoint], trails: [Trail]) -> TrailMatch? {
        matchResult(for: route, trails: trails).match
    }

    func matchResult(for route: [RoutePoint], trails: [Trail]) -> TrailRouteMatchResult {
        matchResult(for: route, candidates: trails.map(candidate(for:)))
    }

    func matchResult(
        for route: [RoutePoint],
        candidates: [TrailRouteCandidate]
    ) -> TrailRouteMatchResult {
        guard route.count >= 2 else {
            return TrailRouteMatchResult(match: nil, sections: [])
        }

        var scoredCandidates: [(UUID, ScoredSection)] = []
        var distancesByCandidate: [(UUID, [Double])] = []
        for candidate in candidates {
            if Task.isCancelled { break }
            var nearestDistances: [Double]?
            var best: ScoredSection?
            for (routeIndex, candidateRoute) in candidate.routes.enumerated()
            where candidateRoute.count >= 2 {
                if Task.isCancelled { break }
                let cumulativeTrailDistances = cumulativeDistances(for: candidateRoute)
                let trailLength = cumulativeTrailDistances.last ?? 0
                let projections = route.map {
                    nearestProjection(
                        to: $0, in: candidateRoute,
                        cumulativeDistances: cumulativeTrailDistances,
                        totalLength: trailLength)
                }
                let distances = projections.map(\.distance)
                if var nearest = nearestDistances {
                    for index in nearest.indices {
                        nearest[index] = min(nearest[index], distances[index])
                    }
                    nearestDistances = nearest
                } else {
                    nearestDistances = distances
                }
                for isReversed in [false, true] {
                    let directional =
                        isReversed
                        ? projections.map {
                            TrailProjection(
                                distance: $0.distance,
                                progress: 1 - $0.progress)
                        }
                        : projections
                    guard
                        let section = score(
                            route: route, projections: directional,
                            trailLength: trailLength,
                            routeIndex: routeIndex,
                            isReversed: isReversed)
                    else { continue }
                    if section.score > (best?.score ?? -.infinity) {
                        best = section
                    }
                }
            }
            if let nearestDistances {
                distancesByCandidate.append((candidate.id, nearestDistances))
            }
            guard let best else { continue }
            scoredCandidates.append((candidate.id, best))
        }
        scoredCandidates.sort { $0.1.score > $1.1.score }

        let match: TrailMatch?
        if let winner = scoredCandidates.first,
            winner.1.score >= minimumScore,
            scoredCandidates.dropFirst().first.map({ winner.1.score - $0.1.score >= minimumWinningMargin }) ?? true
        {
            match = TrailMatch(
                trailID: winner.0,
                score: winner.1.score,
                averageDistance: winner.1.averageDistance)
        } else {
            match = nil
        }

        let matchedSections = scoredCandidates.compactMap { trailID, best -> TrailMatchSection? in
            guard best.score >= minimumScore else { return nil }
            return TrailMatchSection(
                trailID: trailID,
                routeIndex: best.routeIndex,
                startIndex: best.range.lowerBound,
                endIndex: best.range.upperBound - 1,
                trailStartProgress: best.trailStartProgress,
                trailEndProgress: best.trailEndProgress,
                score: best.score,
                averageDistance: best.averageDistance)
        }

        // The same GPS points can be close to neighboring trails. A trail only
        // owns a stretch when it stayed closer than every other centerline
        // across it, which removes crossings, short connectors, and nearby
        // parallels that happen to score well.
        var accepted: [TrailMatchSection] = []
        for candidate in matchedSections {
            guard ownsStretch(candidate, distancesByCandidate: distancesByCandidate) else {
                continue
            }

            let overlap = accepted.map { overlapCount(candidate.range, $0.range) }.max() ?? 0
            let allowedOverlap = max(2, Int(Double(candidate.range.count) * 0.35))
            guard overlap <= allowedOverlap else { continue }
            accepted.append(candidate)
        }

        return TrailRouteMatchResult(
            match: match,
            sections: accepted.sorted { $0.startIndex < $1.startIndex }
        )
    }

    /// True when the section's own centerline stayed closer than every other
    /// candidate across the whole stretch. Crossings and nearby parallels
    /// average out to the same distance as the ridden trail, so a tie or a
    /// closer rival rejects the section.
    private func ownsStretch(
        _ section: TrailMatchSection,
        distancesByCandidate: [(UUID, [Double])]
    ) -> Bool {
        let range = section.range
        guard !range.isEmpty else { return false }
        let own = distancesByCandidate.first { $0.0 == section.trailID }?.1
        let ownAverage =
            own.map { distances in
                range.reduce(0.0) { $0 + distances[$1] } / Double(range.count)
            } ?? section.averageDistance
        var nearestRival = Double.greatestFiniteMagnitude
        for entry in distancesByCandidate where entry.0 != section.trailID {
            let average = range.reduce(0.0) { $0 + entry.1[$1] } / Double(range.count)
            nearestRival = min(nearestRival, average)
        }
        return ownAverage + parallelTieMargin <= nearestRival
    }

    private func candidate(for trail: Trail) -> TrailRouteCandidate {
        TrailRouteCandidate(
            id: trail.id,
            name: trail.name,
            difficulty: trail.difficulty,
            routes: trail.matcherRoutes
        )
    }

    private func score(
        route: [RoutePoint],
        projections: [TrailProjection],
        trailLength: Double,
        routeIndex: Int,
        isReversed: Bool
    ) -> ScoredSection? {
        guard route.count == projections.count, route.count >= 2 else { return nil }
        let distances = projections.map(\.distance)
        guard let range = bestContiguousMatchRange(in: route, projections: projections) else { return nil }
        let matchedRoute = Array(route[range])
        let matchedDistances = Array(distances[range])
        let matchedLength = RouteMetrics.distance(of: matchedRoute)
        let minimumOverlap = min(250, max(40, trailLength * 0.4))
        guard matchedLength >= minimumOverlap else { return nil }

        let matchedProgresses = projections[range].map(\.progress)
        guard let firstProgress = matchedProgresses.first,
            let lastProgress = matchedProgresses.last,
            let minimumProgress = matchedProgresses.min(),
            let maximumProgress = matchedProgresses.max()
        else {
            return nil
        }
        let trailProgressSpan = maximumProgress - minimumProgress
        // Travel distance alone cannot distinguish riding a trail from
        // crossing it or running along a nearby connector. Require meaningful
        // progress along the trail centerline in the match score.
        let overlapScore = min(1, trailProgressSpan)
        let routeCoverage = Double(matchedRoute.count) / Double(route.count)
        let averageDistance = matchedDistances.reduce(0, +) / Double(matchedDistances.count)
        let distanceScore = max(0, 1 - averageDistance / (maximumDistance * 2))
        let endpoint = endpointScore(projections: Array(projections[range]))
        guard endpoint.directionIsCompatible else { return nil }
        let lengthScore = 1 - min(1, abs(matchedLength - trailLength) / max(trailLength, 1))
        let canonicalStart = isReversed ? 1 - firstProgress : firstProgress
        let canonicalEnd = isReversed ? 1 - lastProgress : lastProgress
        return ScoredSection(
            routeIndex: routeIndex,
            range: range,
            trailStartProgress: canonicalStart,
            trailEndProgress: canonicalEnd,
            score: overlapScore * 0.45 + routeCoverage * 0.1 + distanceScore * 0.2
                + endpoint.score * 0.15 + lengthScore * 0.1,
            averageDistance: averageDistance
        )
    }

    private func overlapCount(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Int {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }

    private func bestContiguousMatchRange(
        in route: [RoutePoint],
        projections: [TrailProjection]
    ) -> Range<Int>? {
        guard route.count == projections.count, route.count >= 2 else { return nil }
        var best: Range<Int>?
        var start: Int?

        for index in 0...projections.count {
            let isCovered = index < projections.count && projections[index].distance <= maximumDistance
            if isCovered {
                start = start ?? index
                continue
            }

            if let segmentStart = start, index - segmentStart >= 2 {
                guard let candidate = trimEndpointPadding(segmentStart..<index, projections: projections) else {
                    start = nil
                    continue
                }
                let candidateDistance = RouteMetrics.distance(of: Array(route[candidate]))
                let bestDistance = best.map { RouteMetrics.distance(of: Array(route[$0])) } ?? -.infinity
                if candidateDistance > bestDistance {
                    best = candidate
                }
            }
            start = nil
        }
        return best
    }

    private func trimEndpointPadding(
        _ range: Range<Int>,
        projections: [TrailProjection]
    ) -> Range<Int>? {
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound

        while lowerBound + 1 < upperBound,
            projections[lowerBound].progress <= 0.001,
            abs(projections[lowerBound].progress - projections[lowerBound + 1].progress) <= 0.001
        {
            lowerBound += 1
        }
        while upperBound - 2 >= lowerBound,
            projections[upperBound - 1].progress >= 0.999,
            abs(projections[upperBound - 1].progress - projections[upperBound - 2].progress) <= 0.001
        {
            upperBound -= 1
        }

        guard upperBound - lowerBound >= 2 else { return nil }
        return lowerBound..<upperBound
    }

    private func endpointScore(projections: [TrailProjection]) -> (
        score: Double,
        directionIsCompatible: Bool,
        firstProgress: Double,
        lastProgress: Double
    ) {
        guard let first = projections.first, let last = projections.last else {
            return (0, false, 0, 0)
        }
        let endpointDistance = (first.distance + last.distance) / 2
        let compatible = last.progress >= first.progress
        return (
            max(0, 1 - endpointDistance / (maximumDistance * 2)), compatible,
            first.progress, last.progress
        )
    }

    private func nearestProjection(
        to point: RoutePoint,
        in route: [RoutePoint],
        cumulativeDistances: [Double],
        totalLength: Double
    ) -> TrailProjection {
        guard route.count >= 2 else {
            return TrailProjection(
                distance: route.first.map { coordinate(for: point).distance(to: coordinate(for: $0)) }
                    ?? .greatestFiniteMagnitude,
                progress: 0
            )
        }

        let origin = coordinate(for: point)
        let projectedPoint = project(origin, relativeTo: origin)
        var best = TrailProjection(distance: .greatestFiniteMagnitude, progress: 0)
        for (index, pair) in zip(route, route.dropFirst()).enumerated() {
            let start = pair.0
            let end = pair.1
            let a = project(coordinate(for: start), relativeTo: origin)
            let b = project(coordinate(for: end), relativeTo: origin)
            let dx = b.x - a.x
            let dy = b.y - a.y
            let denominator = dx * dx + dy * dy
            let fraction =
                denominator > 0
                ? max(0, min(1, ((projectedPoint.x - a.x) * dx + (projectedPoint.y - a.y) * dy) / denominator))
                : 0
            let closestX = a.x + dx * fraction
            let closestY = a.y + dy * fraction
            let distance = hypot(projectedPoint.x - closestX, projectedPoint.y - closestY)
            guard distance < best.distance else { continue }
            let segmentLength = cumulativeDistances[index + 1] - cumulativeDistances[index]
            let distanceAlongTrail = cumulativeDistances[index] + segmentLength * fraction
            best = TrailProjection(
                distance: distance,
                progress: totalLength > 0 ? distanceAlongTrail / totalLength : 0
            )
        }
        return best
    }

    private func cumulativeDistances(for route: [RoutePoint]) -> [Double] {
        var cumulative = [0.0]
        cumulative.reserveCapacity(route.count)
        for pair in zip(route, route.dropFirst()) {
            let distance =
                cumulative[cumulative.count - 1]
                + coordinate(for: pair.0).distance(to: coordinate(for: pair.1))
            cumulative.append(distance)
        }
        return cumulative
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
            cumulative.append(cumulative[cumulative.count - 1] + start.distance(to: end))
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
            let fraction =
                segmentEnd > segmentStart
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
        let revision =
            trails
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }
            .joined(separator: "|")
        if let entry = entries[segment.id], entry.trailRevision == revision {
            return entry
        }
        let result = matcher.matchResult(for: segment.points, trails: trails)
        let newEntry = Entry(
            trailRevision: revision,
            match: result.match,
            sections: result.sections)
        // A cancelled match stops early, so its partial result must not be cached.
        if !Task.isCancelled {
            entries[segment.id] = newEntry
        }
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

@MainActor
enum TrailSequenceResolver {
    static func matchedTrails(for segment: RideSegment, trails: [Trail]) -> [Trail] {
        let trailsByID = Dictionary(uniqueKeysWithValues: trails.map { ($0.id, $0) })
        return TrailRouteMatchCache.shared
            .matchingSections(for: segment, trails: trails)
            .compactMap { trailsByID[$0.trailID] }
    }

    static func names(for segment: RideSegment, trails: [Trail]) -> [String] {
        matchedTrails(for: segment, trails: trails).map(\.name)
    }

    static func title(for segment: RideSegment, trails: [Trail]) -> String? {
        let names = names(for: segment, trails: trails)
        return names.isEmpty ? nil : names.joined(separator: " → ")
    }
}
