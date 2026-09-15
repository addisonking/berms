import Foundation

struct DiagnosticReplayResult: Sendable {
    let segments: [SegmentDraft]
}

enum DiagnosticReplayError: Error {
    case unreadableLine(Int)
}

private struct LoggedSegment {
    let kind: SegmentKind
    let startedAt: Date
    let endedAt: Date
    let runNumber: Int?
    let trailSequence: [String]?
    let points: [TrackSample]
    let jumps: [JumpEvent]
}

private struct OpenLoggedSegment {
    let kind: SegmentKind
    let startedAt: Date
    var runNumber: Int?
    var trailSequence: [String]?
    var points: [TrackSample] = []
    var jumps: [JumpEvent] = []
}

struct DiagnosticLogReplayer {
    func replay(data: Data) throws -> DiagnosticReplayResult {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw DiagnosticReplayError.unreadableLine(1)
        }
        return try replay(contents: contents)
    }

    func replay(contents: String) throws -> DiagnosticReplayResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detector = ParkLapDetector()
        let jumpDetector = JumpDetector()
        var context: JumpTrackContext?
        var previousTrackSample: TrackSample?
        var jumpsForCurrentRun: [JumpEvent] = []
        var segments: [SegmentDraft] = []
        var loggedSegments: [LoggedSegment] = []
        var openLoggedSegment: OpenLoggedSegment?
        var recentAcceptedSamples: [TrackSample] = []
        var lastRecordTimestamp: Date?

        func appendFinishedSegment() {
            _ = jumpDetector.finish()
            guard let event = detector.finish(), case .finished(let draft) = event else { return }
            let jumps = draft.kind == .run ? jumpsForCurrentRun : []
            segments.append(SegmentDraft(kind: draft.kind, points: draft.points,
                                         startedAt: draft.startedAt, endedAt: draft.endedAt,
                                         jumps: jumps))
            jumpsForCurrentRun.removeAll(keepingCapacity: true)
        }

        func closeLoggedSegment(at endedAt: Date) {
            guard let current = openLoggedSegment else { return }
            loggedSegments.append(LoggedSegment(
                kind: current.kind,
                startedAt: current.startedAt,
                endedAt: max(current.startedAt, endedAt),
                runNumber: current.runNumber,
                trailSequence: current.trailSequence,
                points: current.points,
                jumps: current.jumps
            ))
            openLoggedSegment = nil
        }

        func startLoggedSegment(from record: RawDiagnosticRecord) {
            closeLoggedSegment(at: record.timestamp)
            guard let kind = Self.segmentKind(from: record) else { return }

            let runNumber: Int?
            if kind == .run {
                runNumber = record.runNumber ?? Self.runNumber(from: record.detail)
            } else {
                runNumber = nil
            }
            openLoggedSegment = OpenLoggedSegment(kind: kind, startedAt: record.timestamp,
                                                  runNumber: runNumber,
                                                  trailSequence: record.trailSequence)
            let pending = recentAcceptedSamples.filter { $0.timestamp >= record.timestamp }
            openLoggedSegment?.points.append(contentsOf: pending)
        }

        func resetDetectors() {
            detector.reset()
            jumpDetector.reset()
            context = nil
            previousTrackSample = nil
            recentAcceptedSamples.removeAll(keepingCapacity: true)
            jumpsForCurrentRun.removeAll(keepingCapacity: true)
        }

        let records = contents.split(whereSeparator: \.isNewline).compactMap {
            line -> RawDiagnosticRecord? in
            // Skip torn or unknown lines instead of discarding the whole log.
            guard let record = try? decoder.decode(RawDiagnosticRecord.self, from: Data(line.utf8)) else {
                return nil
            }
            return record
        }

        for record in records {
            lastRecordTimestamp = record.timestamp

            switch record.kind {
            case "session_paused", "session_stopped":
                closeLoggedSegment(at: record.timestamp)
                appendFinishedSegment()
                resetDetectors()
            case "tracking_gap":
                appendFinishedSegment()
                resetDetectors()
            case "session_resumed", "session_recovered":
                resetDetectors()
            case "detector_started":
                startLoggedSegment(from: record)
            case "detector_finished":
                if record.runNumber != nil, openLoggedSegment?.kind == .run {
                    openLoggedSegment?.runNumber = record.runNumber
                }
                if record.trailSequence != nil, openLoggedSegment?.kind == .run {
                    openLoggedSegment?.trailSequence = record.trailSequence
                }
                closeLoggedSegment(at: record.timestamp)
            case "jump_detector_config", "jump_detector_sensitivity_changed":
                if let sensitivity = Self.sensitivity(from: record.detail) {
                    jumpDetector.update(configuration: sensitivity.configuration)
                }
            case "detector_input":
                guard record.accepted == true,
                      let latitude = record.latitude,
                      let longitude = record.longitude,
                      let speed = record.speed else { continue }
                let sample = TrackSample(
                    coordinate: Coordinate(latitude: latitude, longitude: longitude),
                    altitude: record.fusedAltitude ?? record.gpsAltitude ?? previousTrackSample?.altitude,
                    speed: speed,
                    course: record.course ?? -1,
                    horizontalAccuracy: record.horizontalAccuracy ?? 0,
                    timestamp: record.timestamp,
                    isStationary: record.stationary ?? false,
                    isCycling: record.cycling ?? false,
                    isAutomotive: record.automotive ?? false
                )
                recentAcceptedSamples.append(sample)
                if recentAcceptedSamples.count > 120 {
                    recentAcceptedSamples.removeFirst(recentAcceptedSamples.count - 120)
                }
                if openLoggedSegment?.points.isEmpty == true
                    || sample.timestamp > (openLoggedSegment?.points.last?.timestamp ?? .distantPast) {
                    openLoggedSegment?.points.append(sample)
                }
                guard previousTrackSample.map({ sample.timestamp > $0.timestamp }) ?? true,
                      !TrackSampleNormalizer.isLowSpeedDrift(previous: previousTrackSample,
                                                             current: sample) else { continue }
                previousTrackSample = sample
                for event in detector.process(sample) {
                    guard case .finished(let draft) = event else {
                        if case .started(kind: .run, points: _) = event {
                            jumpsForCurrentRun.removeAll(keepingCapacity: true)
                        }
                        continue
                    }
                    let jumps = draft.kind == .run ? jumpsForCurrentRun : []
                    segments.append(SegmentDraft(kind: draft.kind, points: draft.points,
                                                 startedAt: draft.startedAt, endedAt: draft.endedAt,
                                                 jumps: jumps))
                    jumpsForCurrentRun.removeAll(keepingCapacity: true)
                    jumpDetector.reset()
                }

                let phase = detector.phase
                context = JumpTrackContext(
                    timestamp: sample.timestamp,
                    monotonicSeconds: record.trackMonotonicSeconds ?? record.monotonicSeconds,
                    speed: sample.speed,
                    altitude: sample.altitude,
                    phase: phase,
                    isStationary: sample.isStationary,
                    isAutomotive: sample.isAutomotive
                )
                if phase != .run {
                    jumpDetector.reset()
                }
            case "jump_detected":
                guard record.accepted == true,
                      openLoggedSegment?.kind == .run else { continue }
                let airtime = max(0, record.jumpAirtime ?? 0)
                let landingMonotonic = record.jumpLandingMonotonicSeconds
                    ?? record.monotonicSeconds
                let takeoffMonotonic = record.jumpTakeoffMonotonicSeconds
                    ?? landingMonotonic - airtime
                openLoggedSegment?.jumps.append(JumpEvent(
                    takeoffTimestamp: record.timestamp.addingTimeInterval(-airtime),
                    landingTimestamp: record.timestamp,
                    takeoffMonotonicSeconds: takeoffMonotonic,
                    landingMonotonicSeconds: landingMonotonic
                ))
            case "device_motion_raw":
                guard let context, context.phase == .run else { continue }
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
                for event in jumpDetector.process(sample, context: context) {
                    if case .detected(let jump) = event {
                        jumpsForCurrentRun.append(jump)
                    }
                }
            default:
                continue
            }
        }

        if openLoggedSegment != nil {
            closeLoggedSegment(at: lastRecordTimestamp ?? openLoggedSegment!.startedAt)
        }
        appendFinishedSegment()
        if loggedSegments.isEmpty {
            return DiagnosticReplayResult(segments: Self.numberReplayedSegments(segments))
        }
        return DiagnosticReplayResult(segments: loggedSegments.map {
            SegmentDraft(kind: $0.kind, points: $0.points,
                         startedAt: $0.startedAt, endedAt: $0.endedAt,
                         runNumber: $0.runNumber,
                         trailSequence: $0.trailSequence,
                         jumps: $0.jumps)
        })
    }

    static func sensitivity(from detail: String?) -> JumpSensitivity? {
        guard let detail,
              let range = detail.range(of: "sensitivity=") else { return nil }
        let value = detail[range.upperBound...].prefix { $0 != "," }
        return JumpSensitivity(rawValue: String(value))
    }

    private static func segmentKind(from record: RawDiagnosticRecord) -> SegmentKind? {
        let value = record.phaseAfter ?? record.detail
        guard let value else { return nil }
        return SegmentKind(rawValue: value.lowercased())
    }

    private static func runNumber(from detail: String?) -> Int? {
        guard let detail,
              let range = detail.range(of: #"(?i)run(?:_number|number)?\s*(?:=|#|:)?\s*([0-9]+)"#,
                                       options: .regularExpression) else {
            return nil
        }
        return Int(detail[range].filter(\.isNumber))
    }

    private static func numberReplayedSegments(_ segments: [SegmentDraft]) -> [SegmentDraft] {
        var nextRunNumber = 1
        return segments.sorted { $0.startedAt < $1.startedAt }.map { segment in
            guard segment.kind == .run else { return segment }
            let runNumber = segment.runNumber ?? nextRunNumber
            nextRunNumber = max(nextRunNumber + 1, runNumber + 1)
            return SegmentDraft(
                kind: segment.kind,
                points: segment.points,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                runNumber: runNumber,
                trailSequence: segment.trailSequence,
                jumps: segment.jumps
            )
        }
    }
}
