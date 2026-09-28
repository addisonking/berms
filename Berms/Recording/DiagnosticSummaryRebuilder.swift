import Foundation

struct RebuiltSegmentSummary: Sendable {
    let kind: SegmentKind
    let runNumber: Int?
    let trailSequence: [String]?
    let startedAt: Date
    let endedAt: Date
    let routeData: Data
    let distanceMeters: Double
    let verticalMeters: Double
    let maximumSpeedMetersPerSecond: Double
    let jumps: [JumpEvent]
}

struct RebuiltDaySummary: Sendable {
    let dayID: UUID
    let segments: [RebuiltSegmentSummary]
}

struct RepairedRoute: Sendable {
    let id: UUID
    let routeData: Data
    let distanceMeters: Double
    let verticalMeters: Double
    let maximumSpeedMetersPerSecond: Double
}

struct CatalogPassRepairInput: Sendable {
    let id: UUID
    let trailID: UUID
    let trailCreatedAt: Date
    let recordedAt: Date
}

/// Catalog trail passes store centerlines, not rides. Version 10 of the
/// diagnostic migration re-cleaned them with the ride cleaner, which collapsed
/// their zero-speed points into long straight chords. Restore the bundled
/// catalog geometry for passes created together with their trail.
enum CatalogPassRepair {
    static let creationTolerance: TimeInterval = 300

    static func repairs(
        inputs: [CatalogPassRepairInput],
        catalogRoutes: [UUID: [RoutePoint]]
    ) -> [RepairedRoute] {
        inputs.compactMap { input in
            guard abs(input.recordedAt.timeIntervalSince(input.trailCreatedAt)) < creationTolerance,
                let points = catalogRoutes[input.trailID],
                points.count >= 2,
                let routeData = try? RouteCodec.encode(points)
            else {
                return nil
            }
            return RepairedRoute(
                id: input.id,
                routeData: routeData,
                distanceMeters: RouteMetrics.distance(of: points),
                verticalMeters: 0,
                maximumSpeedMetersPerSecond: 0)
        }
    }
}

enum DiagnosticSummaryRebuilder {
    static func rebuild(dayID: UUID, logURL: URL) -> RebuiltDaySummary? {
        guard let data = try? Data(contentsOf: logURL),
            let result = try? DiagnosticLogReplayer().replay(data: data),
            !result.segments.isEmpty
        else {
            return nil
        }

        let summaries = result.segments.compactMap { draft -> RebuiltSegmentSummary? in
            guard let cleaned = cleanedRoute(samples: draft.points, kind: draft.kind) else {
                return nil
            }
            return RebuiltSegmentSummary(
                kind: draft.kind,
                runNumber: draft.runNumber,
                trailSequence: draft.trailSequence,
                startedAt: draft.startedAt,
                endedAt: draft.endedAt,
                routeData: cleaned.routeData,
                distanceMeters: cleaned.distance,
                verticalMeters: cleaned.vertical,
                maximumSpeedMetersPerSecond: cleaned.maximumSpeed,
                // Raw samples: cleanup smoothing would shrink measured drops.
                jumps: draft.jumps.map { $0.resolved(in: draft.points.map(\.routePoint)) }
            )
        }
        guard !summaries.isEmpty else { return nil }
        return RebuiltDaySummary(dayID: dayID, segments: summaries)
    }

    static func rebuild(dayID: UUID, logURLs: [URL]) -> RebuiltDaySummary? {
        let candidates =
            logURLs
            .compactMap { rebuild(dayID: dayID, logURL: $0) }
            .flatMap(\.segments)
            .sorted { $0.startedAt < $1.startedAt }

        var unique: [RebuiltSegmentSummary] = []
        for candidate in candidates {
            let isDuplicate = unique.contains { existing in
                existing.kind == candidate.kind
                    && abs(existing.startedAt.timeIntervalSince(candidate.startedAt)) < 3
                    && abs(existing.endedAt.timeIntervalSince(candidate.endedAt)) < 3
            }
            if !isDuplicate {
                unique.append(candidate)
            }
        }

        guard !unique.isEmpty else { return nil }
        var nextRunNumber = 1
        let numbered = unique.map { segment -> RebuiltSegmentSummary in
            guard segment.kind == .run else { return segment }
            let runNumber = segment.runNumber ?? nextRunNumber
            nextRunNumber = max(nextRunNumber + 1, runNumber + 1)
            return RebuiltSegmentSummary(
                kind: segment.kind,
                runNumber: runNumber,
                trailSequence: segment.trailSequence,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                routeData: segment.routeData,
                distanceMeters: segment.distanceMeters,
                verticalMeters: segment.verticalMeters,
                maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond,
                jumps: segment.jumps
            )
        }
        return RebuiltDaySummary(dayID: dayID, segments: numbered)
    }

    static func logURLs(dayID: UUID, startedAt: Date, endedAt: Date) -> [URL] {
        let expectedName = "Berms-\(dayID.uuidString).jsonl"
        let range = startedAt.addingTimeInterval(-5)...endedAt.addingTimeInterval(5)
        return allLogURLs()
            .filter { url in
                if url.lastPathComponent.caseInsensitiveCompare(expectedName) == .orderedSame {
                    return true
                }
                guard let firstTimestamp = firstRecordTimestamp(in: url) else { return false }
                return range.contains(firstTimestamp)
            }
            .sorted {
                firstRecordTimestamp(in: $0) ?? .distantPast
                    < firstRecordTimestamp(in: $1) ?? .distantPast
            }
    }

    private static func allLogURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: RideRecorder.diagnosticsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "jsonl" } ?? []
    }

    private static func firstRecordTimestamp(in url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
            let firstLine = data.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }).first
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RawDiagnosticRecord.self, from: Data(firstLine)).timestamp
    }

    static func cleanedRoute(
        samples: [TrackSample],
        kind: SegmentKind
    ) -> (
        routeData: Data, distance: Double,
        vertical: Double, maximumSpeed: Double
    )? {
        let cleanedPoints = RouteCleaner().clean(samples).map(\.routePoint)
        guard cleanedPoints.count >= 2, let routeData = try? RouteCodec.encode(cleanedPoints) else {
            return nil
        }
        return (
            routeData,
            RouteMetrics.distance(of: cleanedPoints),
            RouteMetrics.vertical(of: cleanedPoints, kind: kind),
            RouteMetrics.maximumSpeed(of: cleanedPoints)
        )
    }

    static func cleanedRoute(
        points: [RoutePoint],
        kind: SegmentKind
    ) -> (
        routeData: Data, distance: Double,
        vertical: Double, maximumSpeed: Double
    )? {
        let cleanedPoints = RouteCleaner().clean(points)
        guard cleanedPoints.count >= 2, let routeData = try? RouteCodec.encode(cleanedPoints) else {
            return nil
        }
        return (
            routeData,
            RouteMetrics.distance(of: cleanedPoints),
            RouteMetrics.vertical(of: cleanedPoints, kind: kind),
            RouteMetrics.maximumSpeed(of: cleanedPoints)
        )
    }
}
