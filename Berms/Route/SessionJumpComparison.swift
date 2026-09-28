import Foundation
import SwiftData

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
