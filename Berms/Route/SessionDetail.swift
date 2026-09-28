import Foundation
import SwiftData

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
