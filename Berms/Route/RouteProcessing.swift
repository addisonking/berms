import Foundation
import SwiftData

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
        var result: [TrackSample] = []
        result.reserveCapacity(cleanedPoints.count)
        var searchIndex = 0
        for point in cleanedPoints {
            // Both arrays are time-ordered, so walk a single cursor instead of
            // scanning every source sample for each cleaned point.
            while searchIndex + 1 < valid.count,
                abs(valid[searchIndex + 1].timestamp.timeIntervalSince(point.timestamp))
                    <= abs(valid[searchIndex].timestamp.timeIntervalSince(point.timestamp))
            {
                searchIndex += 1
            }
            let source = valid.indices.contains(searchIndex) ? valid[searchIndex] : nil
            result.append(
                TrackSample(
                    coordinate: Coordinate(latitude: point.latitude, longitude: point.longitude),
                    altitude: point.altitude,
                    speed: point.speed,
                    course: source?.course ?? -1,
                    horizontalAccuracy: source?.horizontalAccuracy ?? configuration.maximumHorizontalAccuracy,
                    timestamp: point.timestamp,
                    isStationary: source?.isStationary ?? false,
                    isCycling: source?.isCycling ?? false,
                    isAutomotive: source?.isAutomotive ?? false
                ))
        }
        return result
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
            let detour =
                coordinate(for: previous).distance(to: coordinate(for: current))
                + coordinate(for: current).distance(to: coordinate(for: next))
            if detour > max(configuration.maximumSpikeDistance * 2, shortcut * 2.8 + 15),
                current.speed <= configuration.lowSpeedThreshold * 2
            {
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
                    <= configuration.maximumDwellExtent
            {
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
                    result.append(
                        interpolatedPoint(
                            from: before, to: points[end + 1],
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
                nextDistance <= configuration.smoothingDistance
            else { return current }
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

    private func interpolatedPoint(
        from start: RoutePoint, to end: RoutePoint,
        timestamp: Date
    ) -> RoutePoint {
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
            total
                + Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
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
    let resortID: String?
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
            let sourceIndex = Int(
                (Double(index) * Double(jumpMarkers.count - 1)
                    / Double(maximumCount - 1)).rounded())
            return jumpMarkers[sourceIndex]
        }
    }

    /// Jumps recorded on the day's runs, independent of whether each jump found a map anchor.
    var jumpCount: Int {
        runs.reduce(0) { $0 + $1.jumps.count }
    }

    var jumps: [JumpEvent] {
        runs.flatMap(\.jumps)
    }

    var totalJumpAirtime: TimeInterval {
        jumps.reduce(0) { $0 + $1.airtime }
    }

    var totalJumpDistanceMeters: Double {
        jumps.compactMap(\.lengthMeters).reduce(0, +)
    }

    var longestJumpLengthMeters: Double? {
        jumps.compactMap(\.lengthMeters).max()
    }

    var highestJumpMeters: Double? {
        jumps.compactMap(\.heightMeters).max()
    }
}

struct SessionJumpAttempt: Identifiable, Sendable, Hashable {
    let id: String
    let segmentID: UUID
    let runNumber: Int
    let jumpNumber: Int
    let jump: JumpEvent
}

struct SessionJumpFeature: Identifiable, Sendable {
    let id: String
    let attempts: [SessionJumpAttempt]
}

struct SessionJumpComparisons: Sendable {
    let features: [SessionJumpFeature]
    let featureIDByAttemptID: [String: String]

    static let empty = SessionJumpComparisons(features: [], featureIDByAttemptID: [:])

    func feature(forAttemptID id: String) -> SessionJumpFeature? {
        guard let featureID = featureIDByAttemptID[id] else { return nil }
        return features.first { $0.id == featureID }
    }
}

/// Groups jumps that landed in the same spot across the runs of one session.
/// Jumps from different sessions are never compared because a rebuilt jump is
/// rarely in the same place.
enum SessionJumpComparisonBuilder {
    struct RunJumps: Sendable {
        let segmentID: UUID
        let runNumber: Int
        let jumps: [JumpEvent]
    }

    /// Same jumps across runs land within normal GPS drift of each other.
    /// Distinct jumps on one trail are farther apart than this.
    static let matchingRadiusMeters: Double = 12
    /// Direction and length only discriminate once the jump is big enough for
    /// GPS drift not to dominate its takeoff-to-landing vector.
    static let discriminatingLengthMeters: Double = 3
    static let minimumDirectionDotProduct: Double = 0.5
    static let maximumLengthRatio: Double = 2.5

    private struct FeatureSeed {
        /// The first attempt's measurements anchor the feature. Averaging every
        /// attempt would let a cluster walk away from the jump it belongs to.
        let anchor: JumpMetrics?
        var attempts: [SessionJumpAttempt] = []
    }

    static func build(dayID: UUID, container: ModelContainer) -> SessionJumpComparisons? {
        let context = ModelContext(container)
        guard
            let day = try? context.fetch(
                FetchDescriptor<RideDay>(predicate: #Predicate { $0.id == dayID })
            ).first
        else { return nil }

        let runs = day.segments
            .filter { $0.kind == .run }
            .sorted { $0.startedAt < $1.startedAt }
        let inputs = runs.enumerated().map { index, segment in
            let routePoints = (try? RouteCodec.decode(segment.routeData)) ?? []
            return RunJumps(
                segmentID: segment.id,
                runNumber: index + 1,
                jumps: segment.jumps.map { $0.resolved(in: routePoints) })
        }
        return build(runs: inputs)
    }

    static func build(runs: [RunJumps]) -> SessionJumpComparisons {
        var seeds: [FeatureSeed] = []

        for run in runs {
            for (index, jump) in run.jumps.enumerated() {
                let attempt = SessionJumpAttempt(
                    id: "\(run.segmentID.uuidString)-\(index)",
                    segmentID: run.segmentID,
                    runNumber: run.runNumber,
                    jumpNumber: index + 1,
                    jump: jump)
                guard let metrics = jump.metrics else {
                    // Without a location the jump cannot compare with anything.
                    seeds.append(FeatureSeed(anchor: nil, attempts: [attempt]))
                    continue
                }
                if let matchIndex = matchingSeedIndex(for: metrics, in: seeds) {
                    seeds[matchIndex].attempts.append(attempt)
                } else {
                    seeds.append(FeatureSeed(anchor: metrics, attempts: [attempt]))
                }
            }
        }

        var features: [SessionJumpFeature] = []
        var featureIDByAttemptID: [String: String] = [:]
        for (index, seed) in seeds.enumerated() {
            let id = seed.attempts.first?.id ?? "jump-feature-\(index)"
            let feature = SessionJumpFeature(id: id, attempts: seed.attempts)
            features.append(feature)
            for attempt in seed.attempts {
                featureIDByAttemptID[attempt.id] = id
            }
        }
        return SessionJumpComparisons(features: features, featureIDByAttemptID: featureIDByAttemptID)
    }

    private static func matchingSeedIndex(
        for metrics: JumpMetrics,
        in seeds: [FeatureSeed]
    ) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, seed) in seeds.enumerated() {
            guard let anchor = seed.anchor else { continue }
            let takeoffDistance = metrics.takeoffCoordinate.distance(to: anchor.takeoffCoordinate)
            let landingDistance = metrics.landingCoordinate.distance(to: anchor.landingCoordinate)
            guard takeoffDistance <= matchingRadiusMeters, landingDistance <= matchingRadiusMeters
            else { continue }
            if metrics.lengthMeters >= discriminatingLengthMeters,
                anchor.lengthMeters >= discriminatingLengthMeters
            {
                guard directionIsCompatible(metrics, with: anchor) else { continue }
                let lengths = [metrics.lengthMeters, anchor.lengthMeters]
                guard (lengths.max() ?? 0) / max(lengths.min() ?? 0, 0.1) <= maximumLengthRatio else {
                    continue
                }
            }
            let score = takeoffDistance + landingDistance
            if score < (best?.score ?? .greatestFiniteMagnitude) {
                best = (index, score)
            }
        }
        return best?.index
    }

    private static func directionIsCompatible(_ metrics: JumpMetrics, with anchor: JumpMetrics) -> Bool {
        let candidate = direction(
            from: metrics.takeoffCoordinate, to: metrics.landingCoordinate)
        let anchorDirection = direction(from: anchor.takeoffCoordinate, to: anchor.landingCoordinate)
        let candidateMagnitude = hypot(candidate.x, candidate.y)
        let anchorMagnitude = hypot(anchorDirection.x, anchorDirection.y)
        guard candidateMagnitude > 0, anchorMagnitude > 0 else { return true }
        let dot =
            (candidate.x * anchorDirection.x + candidate.y * anchorDirection.y)
            / (candidateMagnitude * anchorMagnitude)
        return dot >= minimumDirectionDotProduct
    }

    private static func direction(from start: Coordinate, to end: Coordinate) -> (x: Double, y: Double) {
        let latitudeScale = cos(start.latitude * .pi / 180)
        return (
            (end.longitude - start.longitude) * latitudeScale,
            end.latitude - start.latitude
        )
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
            let decodedJumps = segment.jumpData.flatMap { try? decoder.decode([JumpEvent].self, from: $0) } ?? []
            let jumps = decodedJumps.map { $0.resolved(in: routePoints) }
            let resort = resolvedResort(
                for: routePoints.first,
                manualCatalogID: input.manualCatalogID)
            segments.append(
                SessionDetailSegment(
                    id: segment.id,
                    kind: segment.kind,
                    startedAt: segment.startedAt,
                    endedAt: segment.endedAt,
                    distanceMeters: segment.distanceMeters,
                    verticalMeters: segment.verticalMeters,
                    maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond,
                    routePoints: routePoints,
                    jumps: jumps,
                    resortID: resort?.id,
                    activeResort: resort?.name ?? ""
                ))
        }

        let mapSegments = segments.sorted { $0.startedAt < $1.startedAt }
        let runs = mapSegments.filter { $0.kind == .run }
        let jumpMarkers = runs.flatMap { segment in
            segment.jumps.enumerated().compactMap { index, jump -> SessionDetailJumpMarker? in
                guard
                    let point = segment.routePoints.min(by: {
                        abs($0.timestamp.timeIntervalSince(jump.takeoffTimestamp))
                            < abs($1.timestamp.timeIntervalSince(jump.takeoffTimestamp))
                    })
                else {
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

    static func makeInput(
        day: RideDay,
        trails: [Trail],
        manualCatalogID: String?
    ) -> SessionDetailPreparationInput {
        let catalogTrails = trailsForCatalog(trails, catalogID: manualCatalogID)
        let segments = day.segments
            .filter { $0.kind == .run || $0.kind == .lift }
            .sorted { $0.startedAt < $1.startedAt }
            .map(makeSegmentInput)
        return SessionDetailPreparationInput(
            segments: segments,
            trails: makeTrailInputs(catalogTrails),
            manualCatalogID: manualCatalogID
        )
    }

    static func makeInput(
        segment: RideSegment,
        trails: [Trail],
        manualCatalogID: String?
    ) -> SessionDetailPreparationInput {
        let routePoints = (try? RouteCodec.decode(segment.routeData)) ?? []
        let resort = resolvedResort(
            for: routePoints.first,
            manualCatalogID: manualCatalogID)
        let catalogTrails = trailsForCatalog(trails, catalogID: manualCatalogID)
        guard let resort else {
            return SessionDetailPreparationInput(
                segments: [makeSegmentInput(segment)],
                trails: [],
                manualCatalogID: manualCatalogID
            )
        }
        return SessionDetailPreparationInput(
            segments: [makeSegmentInput(segment)],
            trails: makeTrailInputs(catalogTrails.filter { $0.resort == resort.name }),
            manualCatalogID: manualCatalogID
        )
    }

    /// Reads the day and its trail data on a context owned by this call, so the
    /// caller's actor never touches route storage. Returns nil when the day is gone.
    static func makeInput(
        dayID: UUID,
        manualCatalogID: String?,
        container: ModelContainer
    ) -> SessionDetailPreparationInput? {
        let context = ModelContext(container)
        guard
            let day = try? context.fetch(
                FetchDescriptor<RideDay>(predicate: #Predicate { $0.id == dayID })
            ).first
        else { return nil }
        let trails = (try? context.fetch(FetchDescriptor<Trail>())) ?? []
        return makeInput(day: day, trails: trails, manualCatalogID: manualCatalogID)
    }

    /// Reads the run and its trail data on a context owned by this call, so the
    /// caller's actor never touches route storage. Returns nil when the run is gone.
    static func makeInput(
        segmentID: UUID,
        manualCatalogID: String?,
        container: ModelContainer
    ) -> SessionDetailPreparationInput? {
        let context = ModelContext(container)
        guard
            let segment = try? context.fetch(
                FetchDescriptor<RideSegment>(predicate: #Predicate { $0.id == segmentID })
            ).first
        else { return nil }
        let trails = (try? context.fetch(FetchDescriptor<Trail>())) ?? []
        return makeInput(segment: segment, trails: trails, manualCatalogID: manualCatalogID)
    }

    private static func makeSegmentInput(_ segment: RideSegment) -> SessionDetailSegmentInput {
        SessionDetailSegmentInput(
            id: segment.id,
            kind: segment.kind,
            startedAt: segment.startedAt,
            endedAt: segment.endedAt,
            distanceMeters: segment.distanceMeters,
            verticalMeters: segment.verticalMeters,
            maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond,
            routeData: segment.routeData,
            jumpData: segment.jumpData
        )
    }

    private static func makeTrailInputs(_ trails: [Trail]) -> [SessionDetailTrailInput] {
        trails.map { trail in
            SessionDetailTrailInput(
                id: trail.id,
                name: trail.name,
                difficulty: trail.difficulty,
                resort: trail.resort,
                averagedRouteData: trail.averagedRouteData,
                passRouteData: trail.orderedPasses.map(\.routeData)
            )
        }
    }

    private static func trailsForCatalog(_ trails: [Trail], catalogID: String?) -> [Trail] {
        guard let catalogID,
            let catalog = TrailCatalogRegistry.catalog(withID: catalogID)
        else {
            return trails
        }
        return TrailCatalogRegistry.trails(trails, for: catalog)
    }

    static func buildTrailDetails(
        base: SessionDetailBase,
        input: SessionDetailPreparationInput
    ) throws -> SessionDetailTrailDetails {
        let activeResorts = Set(base.runs.map(\.activeResort))
        let candidatesByResort = Dictionary(
            grouping: input.trails.filter { activeResorts.contains($0.resort) },
            by: \.resort
        ).mapValues { trails in
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

            overlays.append(
                contentsOf: result.sections.compactMap { section in
                    guard let candidate = candidatesByID[section.trailID],
                        candidate.routes.indices.contains(section.routeIndex)
                    else {
                        return nil
                    }
                    let matchedRoute = candidate.routes[section.routeIndex]
                    guard matchedRoute.count > 1 else { return nil }
                    return SessionDetailTrailOverlay(
                        id: "\(run.id.uuidString)-\(section.id)",
                        segmentID: run.id,
                        trailID: candidate.id,
                        name: candidate.name,
                        difficulty: candidate.difficulty,
                        points: TrailRouteSlice.slice(
                            matchedRoute,
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

    /// The resort a run belongs to: a manual catalog choice wins, otherwise the
    /// first GPS point must land inside a resort boundary. Nil means no known
    /// resort, so no catalog trails are offered for that run.
    static func resolvedResort(
        for firstPoint: RoutePoint?,
        manualCatalogID: String?
    ) -> ResortDescriptor? {
        if let manualCatalogID,
            let manualCatalog = TrailCatalogRegistry.catalog(withID: manualCatalogID),
            let resort = TrailCatalogRegistry.resort(withID: manualCatalog.resortID)
        {
            return resort
        }
        guard let firstPoint else { return nil }
        return TrailCatalogRegistry.resort(
            containing: Coordinate(latitude: firstPoint.latitude, longitude: firstPoint.longitude))
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
            routes: routes
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
            paths.append(
                contentsOf: completedRunPaths.filter { $0.count > 1 }.map {
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
