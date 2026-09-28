import Combine
import CoreLocation
import Foundation
import SwiftData

extension RideRecorder {
    func finishOpenSegment(to day: RideDay, reason: String) {
        for event in jumpDetector.finish() {
            handleJumpEvent(event)
        }
        if let event = detector.finish(), case .finished(let draft) = event {
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "detector_finished", timestamp: draft.endedAt,
                    runNumber: draft.kind == .run ? completedRunCount + 1 : nil,
                    trailSequence: trailSequence(for: draft),
                    phaseBefore: draft.kind.rawValue, detail: reason))
            save(draft, to: day)
        }
    }

    func resetTrackingState(clearLastSample: Bool, resetAltitudeFusion: Bool = true) {
        detector.reset()
        activePoints = []
        if clearLastSample {
            lastSample = nil
        }
        lastSampleTimestamp = nil
        trackingBoundaryDate = nil
        normalizer.seed(with: nil)
        if resetAltitudeFusion {
            altitudeFusion.reset(barometerAvailable: false)
        }
        jumpDetector.reset()
        jumpsForCurrentRun.removeAll(keepingCapacity: true)
        latestTrackContext = nil
        lastCheckpointDate = nil
        phase = .idle
    }

    func clearCheckpoint(for day: RideDay) {
        day.checkpointData = nil
        day.checkpointKind = nil
        day.checkpointStartedAt = nil
    }

    func handleJumpEvent(_ event: JumpDetectorEvent) {
        switch event {
        case .detected(let jump):
            guard activeDay != nil, latestTrackContext?.phase == .run else { return }
            objectWillChange.send()
            jumpsForCurrentRun.append(jump)
            updateLiveActivity(force: true)
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "jump_detected",
                    timestamp: jump.landingTimestamp,
                    monotonicSeconds: jump.landingMonotonicSeconds,
                    runEligible: true,
                    accepted: true,
                    detectorVersion: jumpDetector.detectorVersion,
                    jumpAirtime: jump.airtime,
                    jumpTakeoffMonotonicSeconds: jump.takeoffMonotonicSeconds,
                    jumpLandingMonotonicSeconds: jump.landingMonotonicSeconds,
                    detail: "airborne interval confirmed"
                ))
        case .diagnostic(let kind, let timestamp, let monotonicSeconds, let detail):
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: kind,
                    timestamp: timestamp,
                    monotonicSeconds: monotonicSeconds,
                    runEligible: latestTrackContext?.phase == .run,
                    accepted: kind == "jump_candidate_started",
                    detectorVersion: jumpDetector.detectorVersion,
                    jumpReason: kind == "jump_candidate_rejected" ? detail : nil,
                    detail: detail
                ))
        }
    }

    func handle(_ event: DetectorEvent) {
        guard let day = activeDay else { return }
        switch event {
        case .started(let kind, let points):
            jumpDetector.reset()
            if kind == .run {
                jumpsForCurrentRun.removeAll(keepingCapacity: true)
            }
            phase = kind == .lift ? .lift : .run
            activePoints = points
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "detector_started",
                    timestamp: points.first?.timestamp ?? now(),
                    runNumber: kind == .run ? completedRunCount + 1 : nil,
                    phaseAfter: kind.rawValue,
                    detail: kind.title))
            checkpointIfNeeded(at: points.last?.timestamp ?? now(), force: true)
        case .updated:
            activePoints = detector.currentPoints
        case .finished(let draft):
            for jumpEvent in jumpDetector.finish() {
                handleJumpEvent(jumpEvent)
            }
            let runNumber = draft.kind == .run ? completedRunCount + 1 : nil
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "detector_finished", timestamp: draft.endedAt,
                    runNumber: runNumber,
                    trailSequence: trailSequence(for: draft),
                    phaseBefore: draft.kind.rawValue, detail: draft.kind.title))
            save(draft, to: day)
            updateTotals(for: day)
            saveContext(detail: "totals")
            jumpDetector.reset()
        }
    }

    func checkpointIfNeeded(at date: Date, force: Bool = false) {
        guard let day = activeDay, let kind = activeSegmentKind, !activePoints.isEmpty else { return }
        guard force || lastCheckpointDate.map({ date.timeIntervalSince($0) >= 12 }) ?? true else { return }
        guard
            let data = try? JSONEncoder().encode(
                RecorderCheckpoint(
                    points: activePoints,
                    jumps: activeSegmentKind == .run ? jumpsForCurrentRun : []
                ))
        else { return }
        day.checkpointKind = kind.rawValue
        day.checkpointStartedAt = activePoints.first?.timestamp
        day.checkpointData = data
        lastCheckpointDate = date
        saveContext(detail: "checkpoint")
    }

    private func save(_ draft: SegmentDraft, to day: RideDay) {
        let rawPoints = draft.points.map(\.routePoint)
        let cleanedPoints = RouteCleaner().clean(draft.points).map(\.routePoint)
        guard cleanedPoints.count >= 2, rawPoints.count >= 2,
            let data = try? RouteCodec.encode(cleanedPoints)
        else { return }
        let rawJumps = draft.kind == .run ? (draft.jumps.isEmpty ? jumpsForCurrentRun : draft.jumps) : []
        // Length comes from the cleaned route so it matches the map; the drop
        // comes from the raw accepted samples so smoothing cannot quietly
        // shrink the drop the live panel showed.
        let jumps = rawJumps.map { $0.resolved(in: cleanedPoints, altitudes: rawPoints) }
        let segment = RideSegment(
            kind: draft.kind, startedAt: draft.startedAt,
            endedAt: draft.endedAt, routeData: data, jumps: jumps)
        segment.distanceMeters = RouteMetrics.distance(of: cleanedPoints)
        segment.verticalMeters = RouteMetrics.vertical(of: cleanedPoints, kind: draft.kind)
        segment.maximumSpeedMetersPerSecond = RouteMetrics.maximumSpeed(of: cleanedPoints)
        segment.day = day
        day.segments.append(segment)
        context.insert(segment)
        if draft.kind == .run {
            jumpsForCurrentRun.removeAll(keepingCapacity: true)
        } else {
            learnLiftProfile(from: segment)
        }
        day.checkpointKind = nil
        day.checkpointStartedAt = nil
        day.checkpointData = nil
        saveContext(detail: "segment_\(draft.kind.rawValue)")
    }

    func learnLiftProfile(from segment: RideSegment) {
        let engine = LiftLearningEngine()
        guard let observation = engine.observations(from: [segment]).first,
            let storedLifts = try? context.fetch(FetchDescriptor<LearnedLift>())
        else { return }

        let profiles = engine.merge(observation: observation, into: storedLifts.map(\.profile))
        let storedByID = Dictionary(uniqueKeysWithValues: storedLifts.map { ($0.id, $0) })
        for profile in profiles {
            if let stored = storedByID[profile.id] {
                stored.bottomLatitude = profile.bottom.latitude
                stored.bottomLongitude = profile.bottom.longitude
                stored.topLatitude = profile.top.latitude
                stored.topLongitude = profile.top.longitude
                stored.bottomRadius = profile.bottomRadius
                stored.topRadius = profile.topRadius
                stored.observationCount = profile.observationCount
                stored.confidence = profile.confidence
                stored.lastObservedAt = now()
            } else {
                context.insert(LearnedLift(profile: profile))
            }
        }
        detector.setLearnedLifts(profiles)
    }

    private func trailSequence(for draft: SegmentDraft) -> [String]? {
        guard draft.kind == .run else { return nil }
        guard let trails = try? context.fetch(FetchDescriptor<Trail>()), !trails.isEmpty else {
            return nil
        }
        let candidates = trails.map {
            TrailRouteCandidate(
                id: $0.id, name: $0.name, difficulty: $0.difficulty,
                routes: $0.matcherRoutes)
        }
        let route = RouteCleaner().clean(draft.points).map(\.routePoint)
        let result = TrailRouteMatcher().matchResult(for: route, candidates: candidates)
        var names: [String] = []
        for name in result.sections.compactMap({ section in
            candidates.first(where: { $0.id == section.trailID })?.name
        }) where names.last != name {
            names.append(name)
        }
        return names.isEmpty ? nil : names
    }

    func updateTotals(for day: RideDay) {
        day.recalculateTotals()
    }
}
