import Foundation

struct DiagnosticReplayResult: Sendable {
    let segments: [SegmentDraft]
}

enum DiagnosticReplayError: Error {
    case unreadableLine(Int)
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

        func appendFinishedSegment() {
            _ = jumpDetector.finish()
            guard let event = detector.finish(), case .finished(let draft) = event else { return }
            let jumps = draft.kind == .run ? jumpsForCurrentRun : []
            segments.append(SegmentDraft(kind: draft.kind, points: draft.points,
                                         startedAt: draft.startedAt, endedAt: draft.endedAt,
                                         jumps: jumps))
            jumpsForCurrentRun.removeAll(keepingCapacity: true)
        }

        for (index, line) in contents.split(whereSeparator: \.isNewline).enumerated() {
            guard let record = try? decoder.decode(RawDiagnosticRecord.self, from: Data(line.utf8)) else {
                throw DiagnosticReplayError.unreadableLine(index + 1)
            }

            switch record.kind {
            case "session_paused", "session_stopped":
                appendFinishedSegment()
                context = nil
                previousTrackSample = nil
                jumpsForCurrentRun.removeAll(keepingCapacity: true)
            case "session_resumed", "session_recovered":
                detector.reset()
                jumpDetector.reset()
                context = nil
                previousTrackSample = nil
                jumpsForCurrentRun.removeAll(keepingCapacity: true)
            case "detector_input":
                guard record.accepted == true,
                      let latitude = record.latitude,
                      let longitude = record.longitude,
                      let speed = record.speed else { continue }
                let sample = TrackSample(
                    coordinate: Coordinate(latitude: latitude, longitude: longitude),
                    altitude: record.fusedAltitude ?? record.gpsAltitude,
                    speed: speed,
                    course: record.course ?? -1,
                    horizontalAccuracy: record.horizontalAccuracy ?? 0,
                    timestamp: record.timestamp,
                    isStationary: record.stationary ?? false,
                    isCycling: record.cycling ?? false,
                    isAutomotive: record.automotive ?? false
                )
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

        appendFinishedSegment()
        return DiagnosticReplayResult(segments: segments)
    }
}
