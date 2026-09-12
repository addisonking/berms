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

struct TrailRouteCandidate: Sendable {
    let id: UUID
    let name: String
    let difficulty: TrailDifficulty
    let routes: [[RoutePoint]]
    let primaryRoute: [RoutePoint]
}

struct TrailRouteMatchResult: Sendable {
    let match: TrailMatch?
    let sections: [TrailMatchSection]
}

struct SessionDetailSegmentInput: Sendable {
    let id: UUID
    let kind: SegmentKind
    let startedAt: Date
    let endedAt: Date
    let distanceMeters: Double
    let verticalMeters: Double
    let maximumSpeedMetersPerSecond: Double
    let routeData: Data
    let jumpData: Data?
}

struct SessionDetailTrailInput: Sendable {
    let id: UUID
    let name: String
    let difficulty: TrailDifficulty
    let resort: String
    let averagedRouteData: Data?
    let passRouteData: [Data]
}

struct SessionDetailPreparationInput: Sendable {
    let segments: [SessionDetailSegmentInput]
    let trails: [SessionDetailTrailInput]
    let manualCatalogID: String?
}

struct SessionDetailSegment: Identifiable, Sendable {
    let id: UUID
    let kind: SegmentKind
    let startedAt: Date
    let endedAt: Date
    let distanceMeters: Double
    let verticalMeters: Double
    let maximumSpeedMetersPerSecond: Double
    let routePoints: [RoutePoint]
    let jumps: [JumpEvent]
    let activeResort: String

    var duration: TimeInterval {
        guard routePoints.count >= 2 else {
            return max(0, endedAt.timeIntervalSince(startedAt))
        }
        return zip(routePoints, routePoints.dropFirst()).reduce(0) { total, pair in
            let interval = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            return total + min(max(0, interval), 10)
        }
    }
}

struct SessionDetailJumpMarker: Identifiable, Sendable {
    let id: String
    let segmentID: UUID
    let number: Int
    let coordinate: Coordinate
    let airtime: TimeInterval
}

struct SessionDetailTrailOverlay: Identifiable, Sendable {
    let id: String
    let segmentID: UUID
    let trailID: UUID
    let name: String
    let difficulty: TrailDifficulty
    let points: [RoutePoint]
    let score: Double
}

struct SessionDetailBase: Sendable {
    // Keep overview maps readable and responsive; focused run maps retain every jump.
    static let summaryJumpMarkerLimit = 24

    let runs: [SessionDetailSegment]
    let mapSegments: [SessionDetailSegment]
    let jumpMarkers: [SessionDetailJumpMarker]
    let segmentsByID: [UUID: SessionDetailSegment]

    var summaryJumpMarkers: [SessionDetailJumpMarker] {
        let maximumCount = Self.summaryJumpMarkerLimit
        guard jumpMarkers.count > maximumCount else { return jumpMarkers }
        return (0..<maximumCount).map { index in
            let sourceIndex = Int((Double(index) * Double(jumpMarkers.count - 1)
                / Double(maximumCount - 1)).rounded())
            return jumpMarkers[sourceIndex]
        }
    }
}

struct SessionDetailTrailDetails: Sendable {
    let overlays: [SessionDetailTrailOverlay]
    let sequenceBySegmentID: [UUID: String]
}

enum SessionDetailPresentationBuilder {
    static func buildBase(_ input: SessionDetailPreparationInput) throws -> SessionDetailBase {
        let decoder = JSONDecoder()
        var segments: [SessionDetailSegment] = []
        segments.reserveCapacity(input.segments.count)

        for segment in input.segments {
            try Task.checkCancellation()
            let routePoints = (try? RouteCodec.decode(segment.routeData)) ?? []
            let jumps = segment.jumpData.flatMap { try? decoder.decode([JumpEvent].self, from: $0) } ?? []
            segments.append(SessionDetailSegment(
                id: segment.id,
                kind: segment.kind,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                distanceMeters: segment.distanceMeters,
                verticalMeters: segment.verticalMeters,
                maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond,
                routePoints: routePoints,
                jumps: jumps,
                activeResort: activeResort(for: routePoints.first,
                                           manualCatalogID: input.manualCatalogID)
            ))
        }

        let mapSegments = segments.sorted { $0.startedAt < $1.startedAt }
        let runs = mapSegments.filter { $0.kind == .run }
        let jumpMarkers = runs.flatMap { segment in
            segment.jumps.enumerated().compactMap { index, jump -> SessionDetailJumpMarker? in
                guard let point = segment.routePoints.min(by: {
                    abs($0.timestamp.timeIntervalSince(jump.takeoffTimestamp))
                        < abs($1.timestamp.timeIntervalSince(jump.takeoffTimestamp))
                }) else {
                    return nil
                }
                return SessionDetailJumpMarker(
                    id: "\(segment.id.uuidString)-\(index)",
                    segmentID: segment.id,
                    number: index + 1,
                    coordinate: Coordinate(latitude: point.latitude, longitude: point.longitude),
                    airtime: jump.airtime
                )
            }
        }

        return SessionDetailBase(
            runs: runs,
            mapSegments: mapSegments,
            jumpMarkers: jumpMarkers,
            segmentsByID: Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        )
    }

    static func buildTrailDetails(
        base: SessionDetailBase,
        input: SessionDetailPreparationInput
    ) throws -> SessionDetailTrailDetails {
        let candidatesByResort = Dictionary(grouping: input.trails, by: \.resort).mapValues { trails in
            trails.compactMap(makeCandidate(for:))
        }
        let candidatesByID = Dictionary(
            uniqueKeysWithValues: candidatesByResort.values.flatMap { $0 }.map { ($0.id, $0) }
        )
        let matcher = TrailRouteMatcher()
        var overlays: [SessionDetailTrailOverlay] = []
        var sequenceBySegmentID: [UUID: String] = [:]

        for run in base.runs {
            try Task.checkCancellation()
            let candidates = candidatesByResort[run.activeResort] ?? []
            let result = matcher.matchResult(for: run.routePoints, candidates: candidates)
            let names = result.sections.compactMap { candidatesByID[$0.trailID]?.name }
            if !names.isEmpty {
                sequenceBySegmentID[run.id] = names.joined(separator: " → ")
            }

            overlays.append(contentsOf: result.sections.compactMap { section in
                guard let candidate = candidatesByID[section.trailID],
                      candidate.primaryRoute.count > 1 else {
                    return nil
                }
                return SessionDetailTrailOverlay(
                    id: "\(run.id.uuidString)-\(section.id)",
                    segmentID: run.id,
                    trailID: candidate.id,
                    name: candidate.name,
                    difficulty: candidate.difficulty,
                    points: TrailRouteSlice.slice(candidate.primaryRoute,
                                                  progress: section.trailProgress),
                    score: section.score
                )
            })
        }

        return SessionDetailTrailDetails(
            overlays: overlays,
            sequenceBySegmentID: sequenceBySegmentID
        )
    }

    private static func activeResort(for firstPoint: RoutePoint?, manualCatalogID: String?) -> String {
        if let manualCatalogID,
           let manualCatalog = TrailCatalogRegistry.catalog(withID: manualCatalogID) {
            return manualCatalog.resortName
        }
        guard let firstPoint else {
            return TrailCatalogRegistry.defaultCatalog.resortName
        }
        let coordinate = Coordinate(latitude: firstPoint.latitude, longitude: firstPoint.longitude)
        return TrailCatalogRegistry.nearestCatalog(to: coordinate).resortName
    }

    private static func makeCandidate(for input: SessionDetailTrailInput) -> TrailRouteCandidate? {
        let decodedPasses = input.passRouteData.compactMap { try? RouteCodec.decode($0) }
        let averaged = input.averagedRouteData.flatMap { try? RouteCodec.decode($0) }
        let primaryRoute: [RoutePoint]
        if let averaged, !averaged.isEmpty {
            primaryRoute = averaged
        } else {
            primaryRoute = decodedPasses.first ?? []
        }
        let routes = [primaryRoute] + decodedPasses
        guard routes.contains(where: { $0.count >= 2 }) else { return nil }
        return TrailRouteCandidate(
            id: input.id,
            name: input.name,
            difficulty: input.difficulty,
            routes: routes,
            primaryRoute: primaryRoute
        )
    }
}

struct TrailRouteMatcher: Sendable {
    // A wide proximity radius can make a ride on a neighboring connector look
    // like a trail match. Keep enough room for normal phone GPS drift, but make
    // the score depend on progress along the trail too.
    var maximumDistance: Double = 50
    var minimumScore: Double = 0.58
    var minimumWinningMargin: Double = 0.08

    private struct ScoredSection: Sendable {
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

        let scoredCandidates = candidates.compactMap { candidate -> (UUID, ScoredSection)? in
            let best = candidate.routes
                .filter { $0.count >= 2 }
                .flatMap { candidateRoute in
                    [
                        score(route: route, against: candidateRoute, isReversed: false),
                        score(route: route, against: Array(candidateRoute.reversed()), isReversed: true)
                    ].compactMap { $0 }
                }
                .max { $0.score < $1.score }
            guard let best else { return nil }
            return (candidate.id, best)
        }
        .sorted { $0.1.score > $1.1.score }

        let match: TrailMatch?
        if let winner = scoredCandidates.first,
           winner.1.score >= minimumScore,
           scoredCandidates.dropFirst().first.map({ winner.1.score - $0.1.score >= minimumWinningMargin }) ?? true {
            match = TrailMatch(trailID: winner.0,
                               score: winner.1.score,
                               averageDistance: winner.1.averageDistance)
        } else {
            match = nil
        }

        let candidates = scoredCandidates.compactMap { trailID, best -> TrailMatchSection? in
            guard best.score >= minimumScore else { return nil }
            return TrailMatchSection(trailID: trailID,
                                     startIndex: best.range.lowerBound,
                                     endIndex: best.range.upperBound - 1,
                                     trailStartProgress: best.trailStartProgress,
                                     trailEndProgress: best.trailEndProgress,
                                     score: best.score,
                                     averageDistance: best.averageDistance)
        }

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

        return TrailRouteMatchResult(
            match: match,
            sections: accepted.sorted { $0.startIndex < $1.startIndex }
        )
    }

    private func candidate(for trail: Trail) -> TrailRouteCandidate {
        let primaryRoute = trail.points
        return TrailRouteCandidate(
            id: trail.id,
            name: trail.name,
            difficulty: trail.difficulty,
            routes: [primaryRoute] + trail.passes.map(\.points),
            primaryRoute: primaryRoute
        )
    }

    private func score(
        route: [RoutePoint],
        against trail: [RoutePoint],
        isReversed: Bool
    ) -> ScoredSection? {
        let cumulativeTrailDistances = cumulativeDistances(for: trail)
        let trailLength = cumulativeTrailDistances.last ?? 0
        let projections = route.map {
            nearestProjection(to: $0, in: trail,
                              cumulativeDistances: cumulativeTrailDistances,
                              totalLength: trailLength)
        }
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
              let maximumProgress = matchedProgresses.max() else {
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
                if best == nil || RouteMetrics.distance(of: Array(route[candidate]))
                    > RouteMetrics.distance(of: Array(route[best!])) {
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
              abs(projections[lowerBound].progress - projections[lowerBound + 1].progress) <= 0.001 {
            lowerBound += 1
        }
        while upperBound - 2 >= lowerBound,
              projections[upperBound - 1].progress >= 0.999,
              abs(projections[upperBound - 1].progress - projections[upperBound - 2].progress) <= 0.001 {
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
        return (max(0, 1 - endpointDistance / (maximumDistance * 2)), compatible,
                first.progress, last.progress)
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
            let fraction = denominator > 0
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
            cumulative.append(cumulative.last! + coordinate(for: pair.0)
                .distance(to: coordinate(for: pair.1)))
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
        let result = matcher.matchResult(for: segment.points, trails: trails)
        let newEntry = Entry(trailRevision: revision,
                             match: result.match,
                             sections: result.sections)
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

enum LiveMapPathRole: Equatable, Sendable {
    case previousRun
    case latestCompletedRun
    case activeSegment
}

struct LiveMapPath: Equatable, Sendable {
    let role: LiveMapPathRole
    let points: [RoutePoint]
}

enum RideMapPresentation {
    static func livePaths(
        activeKind: SegmentKind?,
        currentPath: [RoutePoint],
        completedRunPaths: [[RoutePoint]],
        showsPreviousRuns: Bool
    ) -> [LiveMapPath] {
        var paths: [LiveMapPath] = []
        if showsPreviousRuns {
            paths.append(contentsOf: completedRunPaths.filter { $0.count > 1 }.map {
                LiveMapPath(role: .previousRun, points: $0)
            })
        }

        switch activeKind {
        case .run:
            if currentPath.count > 1 {
                paths.append(LiveMapPath(role: .activeSegment, points: currentPath))
            }
        case .lift:
            if let latest = completedRunPaths.last, latest.count > 1 {
                paths.append(LiveMapPath(role: .latestCompletedRun, points: latest))
            } else if currentPath.count > 1 {
                paths.append(LiveMapPath(role: .activeSegment, points: currentPath))
            }
        case .none:
            if currentPath.count > 1 {
                paths.append(LiveMapPath(role: .activeSegment, points: currentPath))
            }
        }
        return paths
    }

    static func summaryRunOpacity(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0.82 }
        let clampedIndex = min(max(index, 0), count - 1)
        return 0.28 + 0.54 * Double(clampedIndex) / Double(count - 1)
    }
}
