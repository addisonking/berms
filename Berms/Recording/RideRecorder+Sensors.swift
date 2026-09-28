import Combine
import CoreLocation
import Darwin
import Foundation
import SwiftData

extension RideRecorder {
    func requestPermissionsIfNeeded() {
        locationService.start { [weak self] location, stationary in
            self?.consume(location: location, isStationary: stationary)
        }
        locationService.stop()
        locationAuthorization = locationService.authorizationStatus
    }

    func startSensors() {
        locationService.authorizationChangeHandler = { [weak self] status in
            self?.locationAuthorization = status
            self?.diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "location_authorization",
                    detail: String(describing: status)
                ))
        }
        locationService.diagnosticHandler = { [weak self] detail in
            self?.diagnosticLogger?.append(RawDiagnosticRecord(kind: "location_service_error", detail: detail))
        }
        if let logger = diagnosticLogger {
            motionService.rawAltitudeHandler = { sample in
                logger.append(
                    RawDiagnosticRecord(
                        kind: "barometer_raw",
                        timestamp: sample.timestamp,
                        relativeAltitude: sample.relativeAltitude,
                        pressureKPa: sample.pressureKPa
                    ))
            }
            motionService.rawActivityHandler = { sample in
                logger.append(
                    RawDiagnosticRecord(
                        kind: "motion_activity_raw",
                        timestamp: sample.recordedAt,
                        stationary: sample.stationary,
                        cycling: sample.cycling,
                        automotive: sample.automotive,
                        detail:
                            "start=\(sample.activityStart.timeIntervalSince1970),walking=\(sample.walking),running=\(sample.running),unknown=\(sample.unknown),confidence=\(sample.confidence)"
                    ))
            }
        }
        let logger = diagnosticLogger
        let logsRawMotion = rawMotionLoggingEnabled
        motionService.rawDeviceMotionHandler = { [weak self] sample in
            if logsRawMotion {
                logger?.append(
                    RawDiagnosticRecord(
                        kind: "device_motion_raw",
                        timestamp: sample.recordedAt,
                        monotonicSeconds: sample.monotonicSeconds,
                        userAccelerationX: sample.userAccelerationX,
                        userAccelerationY: sample.userAccelerationY,
                        userAccelerationZ: sample.userAccelerationZ,
                        rotationRateX: sample.rotationRateX,
                        rotationRateY: sample.rotationRateY,
                        rotationRateZ: sample.rotationRateZ,
                        gravityX: sample.gravityX,
                        gravityY: sample.gravityY,
                        gravityZ: sample.gravityZ,
                        quaternionW: sample.quaternionW,
                        quaternionX: sample.quaternionX,
                        quaternionY: sample.quaternionY,
                        quaternionZ: sample.quaternionZ
                    ))
            }
            Task { @MainActor [weak self] in
                self?.consume(deviceMotion: sample)
            }
        }
        motionService.start()
        motionAvailable = motionService.motionAvailable
        altitudeFusion.reset(barometerAvailable: motionService.altimeterAvailable)
        let backgroundAccess: BackgroundLocationAccess =
            BermsLiveActivityCoordinator.shared.isActivityActive ? .liveActivity : .activitySession
        locationService.start(backgroundAccess: backgroundAccess) { [weak self] location, stationary in
            self?.consume(location: location, isStationary: stationary)
        }
        locationAuthorization = locationService.authorizationStatus
        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "location_service_started",
                detail: "authorization=\(String(describing: locationAuthorization))"
            ))
    }

    /// One accepted location fix, straight from Core Location. Internal so
    /// integration tests can replay a whole ride without a location manager.
    func consume(location: CLLocation, isStationary: Bool) {
        guard let day = activeDay, !day.isPaused else { return }
        let arrivalDate = now()
        let arrivalMonotonicSeconds = uptime()
        let locationAge = max(0, arrivalDate.timeIntervalSince(location.timestamp))
        let trackMonotonicSeconds = arrivalMonotonicSeconds - locationAge
        let cycling = motionService.isCycling
        let automotive = motionService.isAutomotive
        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "gps_raw",
                timestamp: location.timestamp,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                gpsAltitude: location.altitude,
                relativeAltitude: motionService.relativeAltitude,
                speed: location.speed,
                course: location.course,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy,
                stationary: isStationary,
                cycling: cycling,
                automotive: automotive
            ))

        guard location.timestamp >= day.startedAt else {
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "gps_rejected", timestamp: location.timestamp,
                    accepted: false, detail: "before_session_start"))
            return
        }
        if let trackingBoundaryDate, location.timestamp < trackingBoundaryDate {
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "gps_rejected", timestamp: location.timestamp,
                    accepted: false, detail: "before_tracking_boundary"))
            return
        }
        guard location.timestamp <= arrivalDate.addingTimeInterval(10) else {
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "gps_rejected", timestamp: location.timestamp,
                    accepted: false, detail: "future_timestamp"))
            return
        }
        guard lastSampleTimestamp.map({ location.timestamp > $0 }) ?? true else {
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "gps_rejected", timestamp: location.timestamp,
                    accepted: false, detail: "duplicate_or_out_of_order"))
            return
        }

        if let lastSampleTimestamp {
            let gap = location.timestamp.timeIntervalSince(lastSampleTimestamp)
            if gap > maximumTrackingGap {
                diagnosticLogger?.append(
                    RawDiagnosticRecord(
                        kind: "tracking_gap",
                        timestamp: location.timestamp,
                        accepted: false,
                        phaseBefore: detector.phase.rawValue,
                        detail: "gap_seconds=\(String(format: "%.1f", gap)); segment boundary inserted"
                    ))
                finishOpenSegment(to: day, reason: "tracking_gap")
                updateTotals(for: day)
                saveContext(detail: "tracking_gap")
                resetTrackingState(clearLastSample: true, resetAltitudeFusion: false)
                altitudeFusion.reset(barometerAvailable: motionService.altimeterAvailable)
            }
        }

        let speed = location.speed >= 0 ? location.speed : 0
        let course = location.course >= 0 ? location.course : -1
        let gpsAltitude = location.verticalAccuracy >= 0 ? location.altitude : nil
        let hasFreshBarometer =
            motionService.relativeAltitudeTimestamp.map {
                abs(location.timestamp.timeIntervalSince($0)) <= 2.5
            } ?? false
        guard
            let altitude = altitudeFusion.update(
                gpsAltitude: gpsAltitude,
                relativeAltitude: hasFreshBarometer ? motionService.relativeAltitude : nil
            )
        else {
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "detector_waiting",
                    timestamp: location.timestamp,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    gpsAltitude: gpsAltitude,
                    relativeAltitude: motionService.relativeAltitude,
                    accepted: false,
                    detail: "altitude_baseline_pending"
                ))
            return
        }

        let rawSample = TrackSample(
            coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            altitude: altitude,
            speed: speed,
            course: course,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp,
            isStationary: isStationary,
            isCycling: cycling,
            isAutomotive: automotive
        )
        let phaseBefore = detector.phase
        guard let sample = normalizer.normalize(rawSample, smoothAltitude: !hasFreshBarometer) else {
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "gps_rejected",
                    timestamp: location.timestamp,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    gpsAltitude: location.altitude,
                    speed: speed,
                    course: course,
                    horizontalAccuracy: location.horizontalAccuracy,
                    accepted: false,
                    phaseBefore: phaseBefore.rawValue,
                    detail: "normalizer_rejected"
                ))
            return
        }
        lastSampleTimestamp = sample.timestamp

        let events = detector.process(sample)
        lastSample = sample
        phase = detector.phase

        for event in events {
            handle(event)
        }

        latestTrackContext = JumpTrackContext(
            timestamp: sample.timestamp,
            monotonicSeconds: trackMonotonicSeconds,
            speed: sample.speed,
            altitude: sample.altitude,
            phase: detector.phase,
            isStationary: sample.isStationary,
            isAutomotive: sample.isAutomotive
        )
        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "detector_input",
                timestamp: sample.timestamp,
                monotonicSeconds: trackMonotonicSeconds,
                latitude: sample.coordinate.latitude,
                longitude: sample.coordinate.longitude,
                gpsAltitude: sample.altitude,
                fusedAltitude: sample.altitude,
                relativeAltitude: motionService.relativeAltitude,
                trackMonotonicSeconds: trackMonotonicSeconds,
                speed: sample.speed,
                course: sample.course,
                horizontalAccuracy: sample.horizontalAccuracy,
                stationary: sample.isStationary,
                cycling: sample.isCycling,
                automotive: sample.isAutomotive,
                runEligible: detector.phase == .run,
                accepted: true,
                phaseBefore: phaseBefore.rawValue,
                phaseAfter: detector.phase.rawValue,
                detectorVersion: jumpDetector.detectorVersion
            ))

        if detector.phase != .idle {
            activePoints = detector.currentPoints
            phase = detector.phase
            checkpointIfNeeded(at: location.timestamp)
        } else {
            activePoints = []
        }
        updateLiveActivity(force: phaseBefore != phase)
        logMemoryFootprint(at: arrivalDate)
    }

    /// One device-motion sample, straight from Core Motion. Internal for the
    /// same reason as `consume(location:isStationary:)`.
    func consume(deviceMotion sample: DeviceMotionSample) {
        guard activeDay != nil, !isPaused, let context = latestTrackContext else { return }
        if let trackingBoundaryDate, sample.recordedAt < trackingBoundaryDate { return }
        for event in jumpDetector.process(sample, context: context) {
            handleJumpEvent(event)
        }
    }

    /// Periodic footprint sampling so a background session leaves evidence if
    /// the system terminates it for memory.
    func logMemoryFootprint(at date: Date? = nil, force: Bool = false) {
        let date = date ?? now()
        guard force || lastFootprintLogDate.map({ date.timeIntervalSince($0) >= 30 }) ?? true else { return }
        lastFootprintLogDate = date

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "memory_footprint",
                timestamp: date,
                detail: String(
                    format: "footprint_mb=%.1f,points=%d,segments=%d,phase=%@",
                    Double(info.phys_footprint) / 1_048_576,
                    activePoints.count,
                    activeDay?.segments.count ?? 0,
                    phase.rawValue)
            ))
    }
}
