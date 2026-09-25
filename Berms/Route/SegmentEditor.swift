import Foundation
import SwiftData

/// Rider corrections to automatic segmentation. Each edit rewrites the stored
/// segment in place, records a `SegmentCorrection` on the day, and drops every
/// derived cache so the day screen re-reads the new shape.
@MainActor
enum SegmentEditor {
    enum EditError: LocalizedError {
        case segmentDetached
        case notEnoughPoints
        case invalidSplitIndex
        case saveFailed(Error)

        var errorDescription: String? {
            switch self {
            case .segmentDetached:
                "This segment is no longer part of a day."
            case .notEnoughPoints:
                "This segment has too few GPS points to edit."
            case .invalidSplitIndex:
                "Pick a split point inside the run, not at its edges."
            case .saveFailed(let error):
                "The correction could not be saved. \(error.localizedDescription)"
            }
        }
    }

    struct SplitCandidate: Identifiable, Sendable {
        let index: Int
        let timestamp: Date
        let stoppedSeconds: TimeInterval
        let distanceFromStart: Double

        var id: Int { index }
    }

    static func mark(_ segment: RideSegment, as kind: SegmentKind, in context: ModelContext) throws {
        guard segment.kind != kind else { return }
        let original = segment.kind
        segment.kindRawValue = kind.rawValue
        segment.verticalMeters = RouteMetrics.vertical(of: segment.points, kind: kind)
        segment.day?.appendCorrection(
            SegmentCorrection(
                kind: kind == .lift ? .markLift : .markRun,
                segmentID: segment.id,
                originalKind: original,
                correctedKind: kind))
        segment.day?.recalculateTotals()
        invalidate(dayID: segment.day?.id, segmentIDs: [segment.id])
        try save(context)
    }

    @discardableResult
    static func split(_ segment: RideSegment, at index: Int, in context: ModelContext) throws -> RideSegment {
        let points = segment.points
        guard points.count >= 4 else { throw EditError.notEnoughPoints }
        guard index >= 2, index <= points.count - 2 else { throw EditError.invalidSplitIndex }
        guard let day = segment.day else { throw EditError.segmentDetached }

        let boundary = points[index].timestamp
        let first = Array(points[..<index])
        let second = Array(points[index...])
        guard let firstData = try? RouteCodec.encode(first),
            let secondData = try? RouteCodec.encode(second)
        else { throw EditError.notEnoughPoints }

        let firstJumps = segment.jumps.filter { $0.takeoffTimestamp < boundary }
        let secondJumps = segment.jumps.filter { $0.takeoffTimestamp >= boundary }

        let newSegment = RideSegment(
            kind: segment.kind,
            startedAt: second[0].timestamp,
            endedAt: segment.endedAt,
            routeData: secondData,
            jumps: secondJumps)
        applyMetrics(for: second, to: newSegment)

        segment.routeData = firstData
        segment.endedAt = first[first.count - 1].timestamp
        segment.jumpData = try? JSONEncoder().encode(firstJumps)
        applyMetrics(for: first, to: segment)

        newSegment.day = day
        day.segments.append(newSegment)
        context.insert(newSegment)

        day.appendCorrection(
            SegmentCorrection(
                kind: .split,
                segmentID: segment.id,
                originalKind: segment.kind,
                correctedKind: segment.kind,
                splitTimestamp: boundary))
        day.recalculateTotals()
        invalidate(dayID: day.id, segmentIDs: [segment.id, newSegment.id])
        try save(context)
        return newSegment
    }

    /// Stops long enough to be a plausible split point, best first. Long
    /// stationary stretches are what a missed run boundary usually looks like.
    static func splitCandidates(for segment: RideSegment) -> [SplitCandidate] {
        let points = segment.points
        guard points.count >= 4 else { return [] }
        let minimumStop: TimeInterval = 15

        var candidates: [SplitCandidate] = []
        var stopStart: Int?
        for index in points.indices {
            let slow = points[index].speed < 1.0
            if slow, stopStart == nil {
                stopStart = index
            }
            if !slow, let start = stopStart {
                stopStart = nil
                appendCandidate(start: start, end: index, points: points, minimumStop: minimumStop, into: &candidates)
            }
        }

        return candidates.sorted { $0.stoppedSeconds > $1.stoppedSeconds }
    }

    static func midpointCandidate(for segment: RideSegment) -> SplitCandidate? {
        let points = segment.points
        guard points.count >= 4 else { return nil }
        let index = points.count / 2
        return SplitCandidate(
            index: index,
            timestamp: points[index].timestamp,
            stoppedSeconds: 0,
            distanceFromStart: RouteMetrics.distance(of: Array(points[...index])))
    }

    private static func appendCandidate(
        start: Int,
        end: Int,
        points: [RoutePoint],
        minimumStop: TimeInterval,
        into candidates: inout [SplitCandidate]
    ) {
        guard end - start >= 2 else { return }
        let stopped = points[end].timestamp.timeIntervalSince(points[start].timestamp)
        guard stopped >= minimumStop else { return }
        let index = min(max((start + end) / 2, 2), points.count - 2)
        candidates.append(
            SplitCandidate(
                index: index,
                timestamp: points[index].timestamp,
                stoppedSeconds: stopped,
                distanceFromStart: RouteMetrics.distance(of: Array(points[...index]))))
    }

    private static func applyMetrics(for points: [RoutePoint], to segment: RideSegment) {
        segment.distanceMeters = RouteMetrics.distance(of: points)
        segment.verticalMeters = RouteMetrics.vertical(of: points, kind: segment.kind)
        segment.maximumSpeedMetersPerSecond = RouteMetrics.maximumSpeed(of: points)
    }

    private static func invalidate(dayID: UUID?, segmentIDs: [UUID]) {
        if let dayID {
            SessionDetailPresentationCache.shared.invalidate(dayID: dayID)
        }
        for id in segmentIDs {
            TrailRouteMatchCache.shared.invalidate(segmentID: id)
        }
    }

    private static func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw EditError.saveFailed(error)
        }
    }
}
