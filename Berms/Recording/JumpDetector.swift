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

struct JumpEvent: Codable, Hashable, Sendable {
    let takeoffTimestamp: Date
    let landingTimestamp: Date
    let takeoffMonotonicSeconds: Double
    let landingMonotonicSeconds: Double
    let airtime: TimeInterval

    init(
        takeoffTimestamp: Date, landingTimestamp: Date,
        takeoffMonotonicSeconds: Double, landingMonotonicSeconds: Double
    ) {
        self.takeoffTimestamp = takeoffTimestamp
        self.landingTimestamp = landingTimestamp
        self.takeoffMonotonicSeconds = takeoffMonotonicSeconds
        self.landingMonotonicSeconds = landingMonotonicSeconds
        self.airtime = max(0, landingMonotonicSeconds - takeoffMonotonicSeconds)
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
        var minimumAirtime: TimeInterval = 0.12
        var maximumAirtime: TimeInterval = 1.25
        var landingImpactThresholdG: Double = 1.35
        var maximumAirborneRotationRate: Double = 8.0
        var cooldown: TimeInterval = 1.5

        var version: String { "jump-detector-v1" }

        var summary: String {
            "version=\(version),minSpeed=\(minimumRidingSpeed),minRun=\(minimumRunContextSeconds),"
                + "contextAge=\(maximumTrackContextAge),lowForceG=\(lowForceThresholdG),"
                + "minAir=\(minimumAirtime),maxAir=\(maximumAirtime),landingG=\(landingImpactThresholdG),"
                + "maxRotation=\(maximumAirborneRotationRate),cooldown=\(cooldown)"
        }
    }

    private(set) var configuration: Configuration
    private var previousSample: DeviceMotionSample?
    private var candidateStart: DeviceMotionSample?
    private var candidateMaximumRotationRate = 0.0
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
            cooldownUntil = sample.monotonicSeconds + configuration.cooldown
            return [.detected(event)]
        }

        guard forceG <= configuration.lowForceThresholdG else { return [] }
        self.candidateStart = sample
        candidateMaximumRotationRate = rotationRate
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
            configuration.minimumAirtime = 0.16
            configuration.landingImpactThresholdG = 1.5
            configuration.cooldown = 2
        case .standard:
            break
        case .high:
            configuration.minimumRidingSpeed = 2.5
            configuration.lowForceThresholdG = 0.65
            configuration.minimumAirtime = 0.1
            configuration.landingImpactThresholdG = 1.2
            configuration.cooldown = 1
        }
        return configuration
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
