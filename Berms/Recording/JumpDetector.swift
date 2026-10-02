import Foundation

struct JumpTrackContext: Sendable, Equatable {
    let timestamp: Date
    let monotonicSeconds: Double
    let speed: Double
    let altitude: Double?
    let phase: DetectorPhase
    let isStationary: Bool
    let isAutomotive: Bool
}

/// Measured jump size. Length is the horizontal gap between takeoff and
/// landing, drop is the elevation lost across the jump, and height is the
/// estimated peak height above the landing.
struct JumpMetrics: Hashable, Sendable {
    let takeoffCoordinate: Coordinate
    let landingCoordinate: Coordinate
    let lengthMeters: Double
    let heightMeters: Double
    let dropMeters: Double

    static let gravity = 9.80665
    /// The longest route gap that still counts as a bracket for interpolation.
    /// A jump is short, so a wider gap would interpolate position and altitude
    /// across ground the rider never covered.
    static let maximumInterpolationGap: TimeInterval = 2
    static let maximumHeightMeters: Double = 25
    /// A measured length implying a ground speed this far above the fastest
    /// recorded nearby speed is GPS position noise rather than a jump.
    static let maximumLengthSpeedFactor: Double = 1.5
    static let maximumLengthSpeedSlackMetersPerSecond: Double = 6

    static func resolve(
        takeoffTimestamp: Date,
        landingTimestamp: Date,
        airtime: TimeInterval,
        positions: [RoutePoint],
        altitudes: [RoutePoint]? = nil
    ) -> JumpMetrics? {
        let altitudePoints = altitudes ?? positions
        guard positions.count >= 2, altitudePoints.count >= 2,
            let takeoff = interpolatedPoint(at: takeoffTimestamp, in: positions),
            let landing = interpolatedPoint(at: landingTimestamp, in: positions),
            let takeoffAltitude = interpolatedPoint(at: takeoffTimestamp, in: altitudePoints),
            let landingAltitude = interpolatedPoint(at: landingTimestamp, in: altitudePoints)
        else { return nil }

        let takeoffCoordinate = Coordinate(latitude: takeoff.latitude, longitude: takeoff.longitude)
        let landingCoordinate = Coordinate(latitude: landing.latitude, longitude: landing.longitude)
        let drop = takeoffAltitude.altitude - landingAltitude.altitude
        let length = takeoffCoordinate.distance(to: landingCoordinate)
        if airtime > 0,
            let maximumSpeed = maximumNearbySpeed(from: takeoffTimestamp, to: landingTimestamp, in: positions)
        {
            let plausibleSpeed = max(
                maximumSpeed * maximumLengthSpeedFactor,
                maximumSpeed + maximumLengthSpeedSlackMetersPerSecond)
            if length / airtime > plausibleSpeed {
                return nil
            }
        }
        // Height is peak height above the landing, the number riders compare to
        // the size of the drop or booter they hit. On a pure drop-off the arc
        // adds almost nothing and the height is the drop itself; a step-up
        // lands above the takeoff, so the climb subtracts from the arc.
        let height = min(maximumHeightMeters, max(0, airHeight(airtime: airtime, dropMeters: drop) + drop))
        return JumpMetrics(
            takeoffCoordinate: takeoffCoordinate,
            landingCoordinate: landingCoordinate,
            lengthMeters: length,
            heightMeters: height,
            dropMeters: drop)
    }

    private static func maximumNearbySpeed(
        from takeoffTimestamp: Date,
        to landingTimestamp: Date,
        in points: [RoutePoint]
    ) -> Double? {
        let lowerBound = takeoffTimestamp.addingTimeInterval(-maximumInterpolationGap)
        let upperBound = landingTimestamp.addingTimeInterval(maximumInterpolationGap)
        return
            points
            .filter { $0.timestamp >= lowerBound && $0.timestamp <= upperBound }
            .map(\.speed)
            .filter { $0.isFinite && $0 > 0 }
            .max()
    }

    /// Peak height of a ballistic arc that is airborne for `airtime` and lands
    /// `dropMeters` below the takeoff. A launch aimed downward earns no height.
    static func airHeight(airtime: TimeInterval, dropMeters: Double) -> Double {
        guard airtime.isFinite, airtime > 0, dropMeters.isFinite else { return 0 }
        let launchVelocity = (gravity * airtime * airtime / 2 - dropMeters) / airtime
        guard launchVelocity > 0 else { return 0 }
        let height = launchVelocity * launchVelocity / (2 * gravity)
        return height
    }

    static func interpolatedPoint(at date: Date, in points: [RoutePoint]) -> RoutePoint? {
        guard let first = points.first, let last = points.last else { return nil }
        if date <= first.timestamp {
            return first.timestamp.timeIntervalSince(date) <= maximumInterpolationGap ? first : nil
        }
        if date >= last.timestamp {
            return date.timeIntervalSince(last.timestamp) <= maximumInterpolationGap ? last : nil
        }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            guard date >= start.timestamp, date <= end.timestamp else { continue }
            let interval = end.timestamp.timeIntervalSince(start.timestamp)
            guard interval <= maximumInterpolationGap else { return nil }
            let fraction = interval > 0 ? date.timeIntervalSince(start.timestamp) / interval : 0
            return RoutePoint(
                latitude: interpolate(start.latitude, end.latitude, fraction),
                longitude: interpolate(start.longitude, end.longitude, fraction),
                altitude: interpolate(start.altitude, end.altitude, fraction),
                speed: interpolate(start.speed, end.speed, fraction),
                timestamp: date)
        }
        return nil
    }

    private static func interpolate(_ start: Double, _ end: Double, _ fraction: Double) -> Double {
        start + (end - start) * fraction
    }
}

struct JumpEvent: Codable, Hashable, Sendable {
    let takeoffTimestamp: Date
    let landingTimestamp: Date
    let takeoffMonotonicSeconds: Double
    let landingMonotonicSeconds: Double
    let airtime: TimeInterval
    let takeoffCoordinate: Coordinate?
    let landingCoordinate: Coordinate?
    let lengthMeters: Double?
    let heightMeters: Double?
    let dropMeters: Double?

    init(
        takeoffTimestamp: Date, landingTimestamp: Date,
        takeoffMonotonicSeconds: Double, landingMonotonicSeconds: Double,
        metrics: JumpMetrics? = nil
    ) {
        self.takeoffTimestamp = takeoffTimestamp
        self.landingTimestamp = landingTimestamp
        self.takeoffMonotonicSeconds = takeoffMonotonicSeconds
        self.landingMonotonicSeconds = landingMonotonicSeconds
        self.airtime = max(0, landingMonotonicSeconds - takeoffMonotonicSeconds)
        self.takeoffCoordinate = metrics?.takeoffCoordinate
        self.landingCoordinate = metrics?.landingCoordinate
        self.lengthMeters = metrics?.lengthMeters
        self.heightMeters = metrics?.heightMeters
        self.dropMeters = metrics?.dropMeters
    }

    var metrics: JumpMetrics? {
        guard let takeoffCoordinate, let landingCoordinate,
            let lengthMeters, let heightMeters, let dropMeters
        else { return nil }
        return JumpMetrics(
            takeoffCoordinate: takeoffCoordinate,
            landingCoordinate: landingCoordinate,
            lengthMeters: lengthMeters,
            heightMeters: heightMeters,
            dropMeters: dropMeters)
    }

    var isResolved: Bool { metrics != nil }

    /// Returns a copy carrying measured size when the route around the jump is
    /// known. Already-resolved jumps are returned untouched. Positions and
    /// altitudes can come from different point sets so a cleaned route supplies
    /// the length while the raw altitude series supplies the drop.
    func resolved(in routePoints: [RoutePoint], altitudes altitudePoints: [RoutePoint]? = nil) -> JumpEvent {
        guard !isResolved,
            let metrics = JumpMetrics.resolve(
                takeoffTimestamp: takeoffTimestamp,
                landingTimestamp: landingTimestamp,
                airtime: airtime,
                positions: routePoints,
                altitudes: altitudePoints)
        else { return self }
        return JumpEvent(
            takeoffTimestamp: takeoffTimestamp,
            landingTimestamp: landingTimestamp,
            takeoffMonotonicSeconds: takeoffMonotonicSeconds,
            landingMonotonicSeconds: landingMonotonicSeconds,
            metrics: metrics)
    }
}

enum JumpDetectorEvent: Sendable {
    case detected(JumpEvent)
    case diagnostic(kind: String, timestamp: Date, monotonicSeconds: Double, detail: String)
}

final class JumpDetector: @unchecked Sendable {
    struct Configuration: Sendable, Equatable {
        var minimumRidingSpeed: Double = 3.0
        var minimumRunContextSeconds: TimeInterval = 1.5
        var maximumTrackContextAge: TimeInterval = 2.5
        var maximumMotionGap: TimeInterval = 0.25
        var lowForceThresholdG: Double = 0.55
        /// Force above this means the wheels are back on the ground. A sample
        /// this high before the landing impact ends the candidate instead of
        /// letting ordinary riding stretch the airtime.
        var airborneCeilingG: Double = 0.85
        /// Minimum share of samples in the window that must be below
        /// `lowForceThresholdG` for the window to stay open.
        var minimumLowForceCoverage: Double = 0.7
        var minimumAirtime: TimeInterval = 0.28
        var maximumAirtime: TimeInterval = 1.25
        var landingImpactThresholdG: Double = 1.35
        var maximumAirborneRotationRate: Double = 8.0
        var cooldown: TimeInterval = 1.5

        var version: String { "jump-detector-v2" }

        var summary: String {
            "version=\(version),minSpeed=\(minimumRidingSpeed),minRun=\(minimumRunContextSeconds),"
                + "contextAge=\(maximumTrackContextAge),lowForceG=\(lowForceThresholdG),"
                + "airCeilingG=\(airborneCeilingG),minCoverage=\(minimumLowForceCoverage),"
                + "minAir=\(minimumAirtime),maxAir=\(maximumAirtime),landingG=\(landingImpactThresholdG),"
                + "maxRotation=\(maximumAirborneRotationRate),cooldown=\(cooldown)"
        }
    }

    private(set) var configuration: Configuration
    private var previousSample: DeviceMotionSample?
    private var candidateStart: DeviceMotionSample?
    private var candidateMaximumRotationRate = 0.0
    private var candidateSampleCount = 0
    private var candidateLowForceSamples = 0
    private var runContextStart: Double?
    private var cooldownUntil: Double?

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    var detectorVersion: String { configuration.version }
    var configurationSummary: String { configuration.summary }

    func update(configuration: Configuration) {
        self.configuration = configuration
        reset()
    }

    func reset() {
        previousSample = nil
        candidateStart = nil
        candidateMaximumRotationRate = 0
        candidateSampleCount = 0
        candidateLowForceSamples = 0
        runContextStart = nil
        cooldownUntil = nil
    }

    func finish() -> [JumpDetectorEvent] {
        guard let candidateStart else {
            reset()
            return []
        }
        let event = diagnostic("jump_candidate_rejected", candidateStart, "detector_finished_before_landing")
        reset()
        return [event]
    }

    func process(_ sample: DeviceMotionSample, context: JumpTrackContext) -> [JumpDetectorEvent] {
        guard sample.monotonicSeconds.isFinite else { return [] }

        if let previousSample {
            let gap = sample.monotonicSeconds - previousSample.monotonicSeconds
            guard gap > 0 else {
                self.previousSample = sample
                runContextStart = nil
                return rejectCandidate(sample, reason: "motion_out_of_order")
            }
            guard gap <= configuration.maximumMotionGap else {
                self.previousSample = sample
                runContextStart = nil
                return rejectCandidate(sample, reason: "motion_gap_\(format(gap))")
            }
        }
        previousSample = sample

        guard context.phase == .run,
            context.speed.isFinite,
            context.speed >= configuration.minimumRidingSpeed,
            !context.isStationary,
            !context.isAutomotive
        else {
            runContextStart = nil
            return rejectCandidate(sample, reason: "run_context_invalid")
        }

        let contextAge = sample.monotonicSeconds - context.monotonicSeconds
        guard contextAge <= configuration.maximumTrackContextAge,
            contextAge >= -configuration.maximumMotionGap
        else {
            runContextStart = nil
            return rejectCandidate(sample, reason: "track_context_stale")
        }

        if runContextStart == nil {
            runContextStart = sample.monotonicSeconds
            return []
        }
        guard
            sample.monotonicSeconds - (runContextStart ?? sample.monotonicSeconds)
                >= configuration.minimumRunContextSeconds
        else {
            return []
        }

        if let cooldownUntil, sample.monotonicSeconds < cooldownUntil {
            return []
        }
        self.cooldownUntil = nil

        guard let forceG = totalAccelerationG(for: sample),
            forceG.isFinite
        else {
            return rejectCandidate(sample, reason: "invalid_gravity")
        }

        let rotationRate = rotationRateMagnitude(of: sample)
        if let candidateStart {
            candidateMaximumRotationRate = max(candidateMaximumRotationRate, rotationRate)
            candidateSampleCount += 1
            if forceG <= configuration.lowForceThresholdG {
                candidateLowForceSamples += 1
            }
            let airtime = sample.monotonicSeconds - candidateStart.monotonicSeconds
            guard airtime <= configuration.maximumAirtime else {
                return rejectCandidate(sample, reason: "airtime_too_long")
            }

            if forceG <= configuration.lowForceThresholdG {
                return []
            }

            guard airtime >= configuration.minimumAirtime else {
                return rejectCandidate(sample, reason: "airtime_too_short")
            }
            guard forceG >= configuration.landingImpactThresholdG else {
                // Force this high means the wheels are back on the ground. An
                // unweighting only counts as airtime while the window stays
                // mostly low-force; ordinary riding must not stretch it.
                let coverage = Double(candidateLowForceSamples) / Double(max(candidateSampleCount, 1))
                guard forceG <= configuration.airborneCeilingG,
                    coverage >= configuration.minimumLowForceCoverage
                else {
                    return rejectCandidate(sample, reason: "force_recovered_before_landing")
                }
                return []
            }
            guard candidateMaximumRotationRate <= configuration.maximumAirborneRotationRate else {
                return rejectCandidate(sample, reason: "airborne_rotation_too_high")
            }

            let event = JumpEvent(
                takeoffTimestamp: candidateStart.recordedAt,
                landingTimestamp: sample.recordedAt,
                takeoffMonotonicSeconds: candidateStart.monotonicSeconds,
                landingMonotonicSeconds: sample.monotonicSeconds
            )
            self.candidateStart = nil
            candidateMaximumRotationRate = 0
            candidateSampleCount = 0
            candidateLowForceSamples = 0
            cooldownUntil = sample.monotonicSeconds + configuration.cooldown
            return [.detected(event)]
        }

        guard forceG <= configuration.lowForceThresholdG else { return [] }
        self.candidateStart = sample
        candidateMaximumRotationRate = rotationRate
        candidateSampleCount = 1
        candidateLowForceSamples = 1
        return [
            diagnostic(
                "jump_candidate_started", sample,
                "low_force_g=\(format(forceG))")
        ]
    }

    private func rejectCandidate(_ sample: DeviceMotionSample, reason: String) -> [JumpDetectorEvent] {
        guard candidateStart != nil else { return [] }
        candidateStart = nil
        candidateMaximumRotationRate = 0
        candidateSampleCount = 0
        candidateLowForceSamples = 0
        return [diagnostic("jump_candidate_rejected", sample, reason)]
    }

    private func diagnostic(_ kind: String, _ sample: DeviceMotionSample, _ detail: String) -> JumpDetectorEvent {
        .diagnostic(
            kind: kind, timestamp: sample.recordedAt,
            monotonicSeconds: sample.monotonicSeconds, detail: detail)
    }

    private func totalAccelerationG(for sample: DeviceMotionSample) -> Double? {
        let x = sample.gravityX + sample.userAccelerationX
        let y = sample.gravityY + sample.userAccelerationY
        let z = sample.gravityZ + sample.userAccelerationZ
        let gravityMagnitude = sqrt(
            sample.gravityX * sample.gravityX
                + sample.gravityY * sample.gravityY
                + sample.gravityZ * sample.gravityZ)
        guard gravityMagnitude.isFinite, gravityMagnitude >= 0.65, gravityMagnitude <= 1.35 else {
            return nil
        }
        return sqrt(x * x + y * y + z * z)
    }

    private func rotationRateMagnitude(of sample: DeviceMotionSample) -> Double {
        sqrt(
            sample.rotationRateX * sample.rotationRateX
                + sample.rotationRateY * sample.rotationRateY
                + sample.rotationRateZ * sample.rotationRateZ)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

enum JumpSensitivity: String, CaseIterable, Identifiable, Equatable, Sendable {
    case low
    case standard
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Less sensitive"
        case .standard: "Standard"
        case .high: "More sensitive"
        }
    }

    var detail: String {
        switch self {
        case .low: "Fewer detections, fewer false positives"
        case .standard: "Balanced detection"
        case .high: "More detections, more false positives"
        }
    }

    var configuration: JumpDetector.Configuration {
        var configuration = JumpDetector.Configuration()
        switch self {
        case .low:
            configuration.minimumRidingSpeed = 3.8
            configuration.lowForceThresholdG = 0.48
            configuration.airborneCeilingG = 0.75
            configuration.minimumLowForceCoverage = 0.8
            configuration.minimumAirtime = 0.35
            configuration.landingImpactThresholdG = 1.5
            configuration.cooldown = 2
        case .standard:
            break
        case .high:
            configuration.minimumRidingSpeed = 2.5
            configuration.lowForceThresholdG = 0.65
            configuration.airborneCeilingG = 0.9
            configuration.minimumLowForceCoverage = 0.6
            configuration.minimumAirtime = 0.22
            configuration.landingImpactThresholdG = 1.2
            configuration.cooldown = 1
        }
        return configuration
    }

    /// The rider's saved choice, shared by the recorder and the day screen.
    static var stored: JumpSensitivity {
        JumpSensitivity(rawValue: UserDefaults.standard.string(forKey: "berms.jumpSensitivity") ?? "")
            ?? .standard
    }
}

struct JumpReplayResult: Sendable {
    let jumps: [JumpEvent]
    let diagnostics: [String]
}

enum JumpLogReplayError: Error {
    case unreadableLine(Int)
}

struct JumpLogReplayer {
    func replay(data: Data, configuration: JumpDetector.Configuration = .init()) throws -> JumpReplayResult {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw JumpLogReplayError.unreadableLine(1)
        }
        return try replay(contents: contents, configuration: configuration)
    }

    func replay(contents: String, configuration: JumpDetector.Configuration = .init()) throws -> JumpReplayResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [(index: Int, record: RawDiagnosticRecord)] = []
        for (index, line) in contents.split(whereSeparator: \.isNewline).enumerated() {
            guard let record = try? decoder.decode(RawDiagnosticRecord.self, from: Data(line.utf8)) else {
                throw JumpLogReplayError.unreadableLine(index + 1)
            }
            records.append((index, record))
        }

        let ordered = records.sorted {
            if $0.record.monotonicSeconds == $1.record.monotonicSeconds {
                return $0.index < $1.index
            }
            return $0.record.monotonicSeconds < $1.record.monotonicSeconds
        }
        let detector = JumpDetector(configuration: configuration)
        var context: JumpTrackContext?
        var jumps: [JumpEvent] = []
        var diagnostics: [String] = []

        for item in ordered {
            let record = item.record
            if ["session_paused", "session_resumed", "session_recovered", "session_stopped"].contains(record.kind) {
                context = nil
                detector.reset()
                continue
            }
            if record.kind == "detector_input", record.accepted == true,
                let phase = record.phaseAfter.flatMap(DetectorPhase.init(rawValue:)),
                let monotonic = record.trackMonotonicSeconds ?? Optional(record.monotonicSeconds)
            {
                context = JumpTrackContext(
                    timestamp: record.timestamp,
                    monotonicSeconds: monotonic,
                    speed: record.speed ?? 0,
                    altitude: record.fusedAltitude ?? record.gpsAltitude,
                    phase: phase,
                    isStationary: record.stationary ?? false,
                    isAutomotive: record.automotive ?? false
                )
                if phase != .run { detector.reset() }
                continue
            }
            guard record.kind == "device_motion_raw", let context else { continue }
            let sample = DeviceMotionSample(
                recordedAt: record.timestamp,
                monotonicSeconds: record.monotonicSeconds,
                userAccelerationX: record.userAccelerationX ?? 0,
                userAccelerationY: record.userAccelerationY ?? 0,
                userAccelerationZ: record.userAccelerationZ ?? 0,
                rotationRateX: record.rotationRateX ?? 0,
                rotationRateY: record.rotationRateY ?? 0,
                rotationRateZ: record.rotationRateZ ?? 0,
                gravityX: record.gravityX ?? 0,
                gravityY: record.gravityY ?? 0,
                gravityZ: record.gravityZ ?? 0,
                quaternionW: record.quaternionW ?? 1,
                quaternionX: record.quaternionX ?? 0,
                quaternionY: record.quaternionY ?? 0,
                quaternionZ: record.quaternionZ ?? 0
            )
            for event in detector.process(sample, context: context) {
                switch event {
                case .detected(let jump): jumps.append(jump)
                case .diagnostic(_, _, _, let detail): diagnostics.append(detail)
                }
            }
        }
        return JumpReplayResult(jumps: jumps, diagnostics: diagnostics)
    }
}
