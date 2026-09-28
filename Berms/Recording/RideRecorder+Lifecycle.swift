import Combine
import CoreLocation
import Foundation
import SwiftData

extension RideRecorder {
    @discardableResult
    func start() -> Bool {
        start(mode: selectedActivityMode)
    }

    @discardableResult
    func start(mode: ActivityMode) -> Bool {
        guard activeDay == nil else { return false }
        guard effectiveAuthorizationStatus != .denied,
            effectiveAuthorizationStatus != .restricted
        else { return false }
        guard effectiveAuthorizationStatus != .notDetermined else {
            requestPermissionsIfNeeded()
            return false
        }

        let day = RideDay(startedAt: now())
        day.activityModeRawValue = mode.rawValue
        // The resort is resolved from GPS when the ride stops. Until then the
        // day stays untagged so per-run resolution can match every resort.
        day.catalogID = nil
        context.insert(day)
        do {
            try context.save()
            Self.pruneOldDiagnosticLogs()
            activeDay = day
            selectedActivityMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: Self.activityModeKey)
            diagnosticLogger = RawLogWriter(url: Self.debugLogURL(for: day.id))
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "session_started", timestamp: day.startedAt,
                    detectorVersion: jumpDetector.detectorVersion,
                    detail:
                        "Berms recording started; mode=\(mode.rawValue)"
                ))
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "jump_detector_config",
                    detectorVersion: jumpDetector.detectorVersion,
                    detail: jumpDetector.configurationSummary))
            jumpDetector.reset()
            jumpsForCurrentRun.removeAll(keepingCapacity: true)
            latestTrackContext = nil
            lastSample = nil
            lastSampleTimestamp = nil
            lastCheckpointDate = nil
            trackingBoundaryDate = day.startedAt
            activePoints = []
            phase = .idle
            UserDefaults.standard.set(true, forKey: "berms.recordingActive")
            BermsLiveActivityCoordinator.shared.start(
                rideID: day.id,
                startedAt: day.startedAt,
                metric: liveActivityMetric,
                activityModeRawValue: day.activityMode.rawValue
            )
            startSensors()
            updateLiveActivity(force: true)
            return true
        } catch {
            context.delete(day)
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            return false
        }
    }

    func appDidEnterBackground() {
        guard isRecording else {
            // A stale service must never keep the background location indicator
            // alive after the user is no longer recording a ride.
            locationService.stop()
            motionService.stop()
            UserDefaults.standard.set(false, forKey: "berms.recordingActive")
            BermsLiveActivityCoordinator.shared.endAll()
            return
        }
        diagnosticLogger?.append(RawDiagnosticRecord(kind: "app_background", detail: "Scene entered background"))
        logMemoryFootprint(force: true)
        checkpointIfNeeded(at: now(), force: true)
        diagnosticLogger?.flush()
    }

    @discardableResult
    func pause() -> Bool {
        guard let day = activeDay, !day.isPaused else { return false }
        let pauseDate = now()
        let phaseBefore = phase
        objectWillChange.send()
        locationService.stop()
        motionService.stop()
        finishOpenSegment(to: day, reason: "pause")
        updateTotals(for: day)
        resetTrackingState(clearLastSample: false)
        day.beginPause(at: pauseDate)
        clearCheckpoint(for: day)
        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "session_paused",
                timestamp: pauseDate,
                phaseBefore: phaseBefore.rawValue,
                detail: "Berms recording paused"
            ))
        saveContext(detail: "pause")
        updateLiveActivity(force: true)
        diagnosticLogger?.flush()
        return true
    }

    @discardableResult
    func resume() -> Bool {
        guard let day = activeDay, day.isPaused else { return false }
        guard effectiveAuthorizationStatus != .denied,
            effectiveAuthorizationStatus != .restricted
        else { return false }
        let resumeDate = now()
        let pausedDuration = day.endPause(at: resumeDate)
        objectWillChange.send()
        resetTrackingState(clearLastSample: true)
        trackingBoundaryDate = resumeDate
        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "session_resumed",
                timestamp: resumeDate,
                detail: "Berms recording resumed; paused_seconds=\(String(format: "%.1f", pausedDuration))"
            ))
        saveContext(detail: "resume")
        updateLiveActivity(force: true)
        startSensors()
        return true
    }

    @discardableResult
    func stop() -> RideDay? {
        guard let day = activeDay else { return nil }
        let stopDate = now()
        let wasPaused = day.isPaused
        locationService.stop()
        motionService.stop()

        if !wasPaused {
            finishOpenSegment(to: day, reason: "stop")
        } else {
            _ = day.endPause(at: stopDate)
        }
        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "session_stopped",
                timestamp: stopDate,
                detail: wasPaused ? "Berms recording stopped while paused" : "Berms recording stopped"
            ))

        day.endedAt = stopDate
        clearCheckpoint(for: day)
        updateTotals(for: day)
        guard saveContext(detail: "stop") else {
            day.endedAt = nil
            day.beginPause(at: stopDate)
            resetTrackingState(clearLastSample: false)
            updateLiveActivity(force: true)
            return nil
        }
        diagnosticLogger?.close()
        diagnosticLogger = nil
        BermsLiveActivityCoordinator.shared.end()

        resetTrackingState(clearLastSample: true)
        activeDay = nil
        watchStateSink?.publish(.idle, force: true)
        UserDefaults.standard.set(false, forKey: "berms.recordingActive")
        return day
    }

    func resumeIfNeeded(autoResume: Bool = false) {
        guard !hasResumed else { return }
        hasResumed = true

        startDiagnosticMigrationIfNeeded()

        isRestoring = true
        defer { isRestoring = false }
        guard UserDefaults.standard.bool(forKey: "berms.recordingActive"), activeDay == nil else {
            if !UserDefaults.standard.bool(forKey: "berms.recordingActive") {
                BermsLiveActivityCoordinator.shared.endAll()
            }
            hasResumed = true
            return
        }

        guard let days = try? context.fetch(FetchDescriptor<RideDay>()) else {
            errorMessage = "Could not restore the active session. Please try again."
            return
        }
        hasResumed = true
        guard let day = days.filter({ !$0.isFinished }).max(by: { $0.startedAt < $1.startedAt }) else {
            UserDefaults.standard.set(false, forKey: "berms.recordingActive")
            BermsLiveActivityCoordinator.shared.endAll()
            return
        }

        guard autoResume else {
            pendingRecoveryDay = day
            needsRecoveryPrompt = true
            return
        }
        restore(day: day)
    }

    func handleLiveActivityOpen() {
        // Opening the app from a Live Activity is not a request to end the ride.
        // Only clean up activities that no longer have a running session.
        if !isRecording {
            BermsLiveActivityCoordinator.shared.endAll()
        }
    }

    func resumePendingSession() {
        guard let day = pendingRecoveryDay else { return }
        pendingRecoveryDay = nil
        needsRecoveryPrompt = false
        restore(day: day)
    }

    func discardPendingSession() {
        guard let day = pendingRecoveryDay else { return }
        pendingRecoveryDay = nil
        needsRecoveryPrompt = false
        discardUnfinishedSession(day)
    }

    private func discardUnfinishedSession(_ day: RideDay) {
        locationService.stop()
        motionService.stop()
        diagnosticLogger?.close()
        diagnosticLogger = nil
        activeDay = nil
        watchStateSink?.publish(.idle, force: true)
        resetTrackingState(clearLastSample: true)
        context.delete(day)
        _ = saveContext(detail: "discard_unfinished_session")
        try? FileManager.default.removeItem(at: Self.debugLogURL(for: day.id))
        UserDefaults.standard.set(false, forKey: "berms.recordingActive")
        BermsLiveActivityCoordinator.shared.endAll()
    }

    private func restore(day: RideDay) {
        activeDay = day
        selectedActivityMode = day.activityMode
        UserDefaults.standard.set(day.activityMode.rawValue, forKey: Self.activityModeKey)
        lastSample = nil
        lastSampleTimestamp = nil
        lastCheckpointDate = nil
        trackingBoundaryDate = day.startedAt
        activePoints = []
        phase = .idle
        diagnosticLogger = RawLogWriter(url: Self.debugLogURL(for: day.id))
        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "session_recovered",
                detectorVersion: jumpDetector.detectorVersion,
                detail: day.isPaused
                    ? "Recovered paused day after relaunch"
                    : "Recovered active day after relaunch"))
        BermsLiveActivityCoordinator.shared.start(
            rideID: day.id,
            startedAt: day.startedAt,
            metric: liveActivityMetric,
            activityModeRawValue: day.activityMode.rawValue
        )
        if day.isPaused {
            resetTrackingState(clearLastSample: true)
            updateLiveActivity(force: true)
            return
        }
        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "jump_detector_config",
                detectorVersion: jumpDetector.detectorVersion,
                detail: jumpDetector.configurationSummary))
        if let data = day.checkpointData,
            let kind = day.checkpointKind.flatMap(SegmentKind.init(rawValue:))
        {
            let decoder = JSONDecoder()
            let checkpoint =
                (try? decoder.decode(RecorderCheckpoint.self, from: data))
                ?? (try? decoder.decode([TrackSample].self, from: data)).map {
                    RecorderCheckpoint(points: $0)
                }
            if let checkpoint {
                detector.restore(kind: kind, points: checkpoint.points)
                normalizer.seed(with: checkpoint.points.last)
                jumpsForCurrentRun = kind == .run ? checkpoint.jumps : []
                activePoints = checkpoint.points
                lastSample = checkpoint.points.last
                lastSampleTimestamp = checkpoint.points.last?.timestamp
                lastCheckpointDate = checkpoint.points.last?.timestamp
                phase = detector.phase
            }
        }
        jumpDetector.reset()
        latestTrackContext = nil
        startSensors()
        updateLiveActivity(force: true)
    }
}
