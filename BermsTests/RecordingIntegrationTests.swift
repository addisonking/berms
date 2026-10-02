import CoreLocation
import Foundation
import SwiftData
import XCTest

@testable import Berms

/// Drives `RideRecorder` through its real sensor boundary with synthetic GPS
/// and device motion: fixes and motion go in, persisted days and watch states
/// come out. These tests exercise the whole phone recording pipeline so the
/// detectors and recorder internals can be refactored underneath them.
@MainActor
final class RecordingIntegrationTests: XCTestCase {
    func testFullParkDayRecordsLiftRunLapsAndPersistsTotals() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }

        let day = try ride.start()
        ride.feedParkDay(laps: 2)
        let finished = try ride.stop()

        XCTAssertEqual(finished.id, day.id)
        XCTAssertTrue(finished.isFinished)
        XCTAssertNil(finished.checkpointData)

        let segments = finished.segments.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(segments.map(\.kind), [.lift, .run, .lift, .run])
        XCTAssertEqual(finished.distanceMeters, 840, accuracy: 40)
        XCTAssertEqual(finished.descentMeters, 236, accuracy: 25)
        XCTAssertEqual(finished.liftMeters, 236, accuracy: 25)
        XCTAssertEqual(finished.maximumSpeedMetersPerSecond, 7, accuracy: 0.5)

        // The detector pins each segment's ends to nearby ride samples, so the
        // seconds are not exact. Riding time still has to track distance and
        // speed, and each run has to start at the top and finish at the base.
        XCTAssertEqual(finished.activeSeconds, finished.distanceMeters / 7, accuracy: 35)
        XCTAssertEqual(finished.liftSeconds, 118, accuracy: 20)
        let runs = segments.filter { $0.kind == .run }
        let lifts = segments.filter { $0.kind == .lift }
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(lifts.count, 2)
        for run in runs {
            XCTAssertGreaterThan(try XCTUnwrap(run.points.first?.altitude), 1_300)
            XCTAssertLessThan(try XCTUnwrap(run.points.last?.altitude), 1_210)
            XCTAssertGreaterThan(run.distanceMeters, 380)
        }
        for lift in lifts {
            XCTAssertLessThan(try XCTUnwrap(lift.points.first?.altitude), 1_210)
            XCTAssertGreaterThan(try XCTUnwrap(lift.points.last?.altitude), 1_300)
            XCTAssertGreaterThan(lift.distanceMeters, 190)
        }

        // The whole day survives a fresh read of the store.
        let saved = try XCTUnwrap(ModelContext(ride.container).fetch(FetchDescriptor<RideDay>()).first)
        XCTAssertEqual(saved.segments.count, 4)
        XCTAssertEqual(saved.distanceMeters, finished.distanceMeters, accuracy: 0.001)
        XCTAssertTrue(saved.segments.allSatisfy { $0.points.count >= 2 })

        // The watch contract: a recording state tied to the day, live phases as
        // they happen, and an idle state once the recording stops.
        XCTAssertEqual(ride.watchSink.states.first?.status, .recording)
        XCTAssertEqual(ride.watchSink.states.first?.rideID, day.id.uuidString)
        XCTAssertTrue(ride.watchSink.states.contains { $0.phase == "lift" })
        XCTAssertTrue(ride.watchSink.states.contains { $0.phase == "run" && $0.run?.number == 1 })
        XCTAssertEqual(ride.watchSink.states.last?.status, .idle)
    }

    func testPauseResumeKeepsPausedTimeOutOfTheDay() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }

        _ = try ride.start()
        ride.idle(5)
        ride.descend(40)
        XCTAssertEqual(ride.recorder.phase, .run)

        XCTAssertTrue(ride.recorder.pause())
        XCTAssertTrue(ride.recorder.isPaused)
        XCTAssertEqual(ride.recorder.phase, .idle)
        XCTAssertTrue(ride.recorder.activePoints.isEmpty)

        // Fixes while paused must not enter the day.
        ride.idle(30)
        XCTAssertTrue(ride.recorder.resume())
        XCTAssertFalse(ride.recorder.isPaused)

        ride.climb(40)
        XCTAssertEqual(ride.recorder.phase, .lift)
        let finished = try ride.stop()

        let segments = finished.segments.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(segments.map(\.kind), [.run, .lift])
        XCTAssertEqual(finished.accumulatedPausedSeconds ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(finished.distanceMeters, 273, accuracy: 40)
        let run = try XCTUnwrap(segments.first)
        let lift = try XCTUnwrap(segments.last)
        XCTAssertGreaterThan(lift.startedAt.timeIntervalSince(run.endedAt), 25)
        XCTAssertTrue(ride.watchSink.states.contains { $0.status == .paused })
        XCTAssertEqual(ride.watchSink.states.last?.status, .idle)
    }

    func testTrackingGapEndsTheOpenSegmentAndKeepsBothHalves() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }

        let day = try ride.start()
        ride.idle(5)
        ride.climb(40)
        XCTAssertEqual(ride.recorder.phase, .lift)

        // More than the 60 s tracking gap: the lift must close and the next fix
        // has to start a fresh segment instead of bridging the hole.
        ride.skipAhead(160)
        ride.descend(40)
        let finished = try ride.stop()

        let segments = finished.segments.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(segments.map(\.kind), [.lift, .run])
        let lift = try XCTUnwrap(segments.first)
        let run = try XCTUnwrap(segments.last)
        XCTAssertGreaterThan(run.startedAt.timeIntervalSince(lift.endedAt), 150)
        XCTAssertTrue(try ride.diagnosticLog(for: day).contains("tracking_gap"))
    }

    func testRelaunchRestoresCheckpointAndCompletesTheRun() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }

        _ = try ride.start()
        ride.idle(5)
        ride.climb(60)
        ride.descend(40)
        XCTAssertEqual(ride.recorder.phase, .run)

        let activeDay = try XCTUnwrap(ride.recorder.activeDay)
        let checkpointData = try XCTUnwrap(activeDay.checkpointData)
        let checkpoint = try JSONDecoder().decode(RecorderCheckpoint.self, from: checkpointData)
        XCTAssertEqual(activeDay.checkpointKind, "run")
        XCTAssertFalse(checkpoint.points.isEmpty)

        // A fresh recorder over the same store is a relaunch: restoring has to
        // bring the open run back instead of dropping it.
        let relaunched = ride.relaunchRecorder()
        XCTAssertNil(relaunched.errorMessage)
        XCTAssertEqual(relaunched.phase, .run)
        XCTAssertEqual(relaunched.activePoints.count, checkpoint.points.count)
        XCTAssertEqual(relaunched.lastSample?.timestamp, checkpoint.points.last?.timestamp)

        ride.descend(20)
        let finished = try ride.stop()

        XCTAssertEqual(finished.segments.sorted { $0.startedAt < $1.startedAt }.map(\.kind), [.lift, .run])
        let run = try XCTUnwrap(finished.segments.first { $0.kind == .run })
        XCTAssertGreaterThan(run.points.count, checkpoint.points.count)
        XCTAssertGreaterThan(run.distanceMeters, 0)
    }

    func testRawMotionLoggingCanBeEnabledAndDisabledWithoutRestartingSensors() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }
        let previous = UserDefaults.standard.object(forKey: "berms.rawMotionLogging")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "berms.rawMotionLogging")
            } else {
                UserDefaults.standard.removeObject(forKey: "berms.rawMotionLogging")
            }
        }
        ride.recorder.setRawMotionLoggingEnabled(false)
        let day = try ride.start()
        ride.feedMotion(at: 0, forceG: 1)
        ride.recorder.setRawMotionLoggingEnabled(true)
        ride.feedMotion(at: 0.04, forceG: 1)
        ride.recorder.setRawMotionLoggingEnabled(false)
        ride.feedMotion(at: 0.08, forceG: 1)
        _ = try ride.stop()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try ride.diagnosticLog(for: day).split(whereSeparator: \.isNewline).map {
            try decoder.decode(RawDiagnosticRecord.self, from: Data($0.utf8))
        }
        let motion = records.filter { $0.kind == "device_motion_raw" }
        XCTAssertEqual(motion.count, 1)
        XCTAssertEqual(try XCTUnwrap(motion.first?.monotonicSeconds), 5_000.04, accuracy: 0.001)
    }

    func testFailedDiagnosticRebuildRetriesAfterGlobalMigrationCompletes() async throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }
        let day = try ride.start()
        ride.feedParkDay(laps: 1)
        _ = try ride.stop()
        let url = RideRecorder.debugLogURL(for: day.id)
        let original = try Data(contentsOf: url)
        try Data("unreadable log".utf8).write(to: url)
        UserDefaults.standard.set("old", forKey: RideRecorder.diagnosticSummaryVersionKey)

        ride.recorder.startDiagnosticMigrationIfNeeded()
        await ride.recorder.migrationTask?.value
        XCTAssertNil(day.diagnosticSummaryVersion)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: RideRecorder.diagnosticSummaryVersionKey),
            RideRecorder.diagnosticSummaryVersion)
        let liftCount = try ride.recorder.context.fetch(FetchDescriptor<LearnedLift>()).first?.observationCount

        try original.write(to: url)
        ride.recorder.startDiagnosticMigrationIfNeeded()
        await ride.recorder.migrationTask?.value
        XCTAssertEqual(day.diagnosticSummaryVersion, RideRecorder.diagnosticSummaryVersion)
        let saved = try XCTUnwrap(ModelContext(ride.container).fetch(FetchDescriptor<RideDay>()).first)
        XCTAssertEqual(saved.diagnosticSummaryVersion, RideRecorder.diagnosticSummaryVersion)
        XCTAssertEqual(
            try ride.recorder.context.fetch(FetchDescriptor<LearnedLift>()).first?.observationCount,
            liftCount)

        ride.recorder.startDiagnosticMigrationIfNeeded()
        XCTAssertNil(ride.recorder.migrationTask)
    }

    func testMigrationRetriesWhenSegmentsChangeBeforeReconciliation() async throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }
        let day = try ride.start()
        ride.descend(40)
        _ = try ride.stop()
        let segment = try XCTUnwrap(day.segments.first)
        XCTAssertEqual(segment.kind, .run)

        ride.recorder.startDiagnosticMigrationIfNeeded()
        segment.kindRawValue = SegmentKind.lift.rawValue
        await ride.recorder.migrationTask?.value
        XCTAssertNil(day.diagnosticSummaryVersion)

        segment.kindRawValue = SegmentKind.run.rawValue
        ride.recorder.startDiagnosticMigrationIfNeeded()
        await ride.recorder.migrationTask?.value
        XCTAssertEqual(day.diagnosticSummaryVersion, RideRecorder.diagnosticSummaryVersion)
    }

    func testTrailNamesAreResolvedOnExportInsteadOfRunCompletion() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }
        let day = try ride.start()
        ride.descend(40)
        let trail = Trail(name: "Test run", difficulty: .blue, resort: "Test")
        trail.averagedRouteData = try RouteCodec.encode(ride.recorder.currentMapPoints)
        ride.recorder.context.insert(trail)
        let finished = try ride.stop()

        XCTAssertFalse(try ride.diagnosticLog(for: day).contains("trailSequence"))
        let export = BermsDataExport(day: finished, trails: [trail])
        XCTAssertEqual(export.parsed.runs.first?.trails, ["Test run"])
    }

    func testInvalidCheckpointIsArchivedBeforeNewSamplesOverwriteIt() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }
        let day = try ride.start()
        ride.climb(60)
        ride.descend(40)
        let completedCount = day.segments.count
        let invalid = Data("invalid checkpoint".utf8)
        day.checkpointData = invalid
        try ride.recorder.context.save()

        let restored = ride.relaunchRecorder()
        XCTAssertNotNil(restored.errorMessage)
        XCTAssertTrue(restored.isRecording)
        XCTAssertEqual(restored.phase, .idle)
        let backup = RideRecorder.failedCheckpointURL(for: day.id)
        XCTAssertEqual(try Data(contentsOf: backup), invalid)
        ride.descend(40)
        XCTAssertNotEqual(restored.activeDay?.checkpointData, invalid)
        XCTAssertEqual(try Data(contentsOf: backup), invalid)
        let finished = try ride.stop()
        XCTAssertGreaterThan(finished.segments.count, completedCount)
        XCTAssertTrue(try ride.diagnosticLog(for: day).contains("checkpoint_recovery_failed"))
    }

    func testCheckpointArchiveFailureKeepsRecoveryPending() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }
        let day = try ride.start()
        let invalid = Data("invalid checkpoint".utf8)
        day.checkpointKind = "run"
        day.checkpointData = invalid
        try ride.recorder.context.save()
        let backup = RideRecorder.failedCheckpointURL(for: day.id)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)

        let restored = ride.relaunchRecorder()
        XCTAssertNotNil(restored.errorMessage)
        XCTAssertFalse(restored.isRecording)
        XCTAssertTrue(restored.needsRecoveryPrompt)
        XCTAssertEqual(restored.pendingRecoveryDay?.checkpointData, invalid)
        XCTAssertEqual(ride.capture.consumerCount, 0)

        try FileManager.default.removeItem(at: backup)
        restored.resumePendingSession()
        XCTAssertTrue(restored.isRecording)
        XCTAssertEqual(try Data(contentsOf: backup), invalid)
        _ = try ride.stop()
    }

    func testLiftLearningOnlyUpdatesTheObservedLiftTimestamp() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }
        _ = try ride.start()
        ride.climb(60)
        let finished = try ride.stop()
        let segment = try XCTUnwrap(finished.segments.first)
        let context = ride.recorder.context
        let matched = try XCTUnwrap(context.fetch(FetchDescriptor<LearnedLift>()).first)
        let oldDate = segment.startedAt.addingTimeInterval(-100)
        let unrelated = LearnedLift(
            profile: LearnedLiftProfile(
                id: UUID(), bottom: Coordinate(latitude: 45, longitude: -105),
                top: Coordinate(latitude: 45.01, longitude: -105),
                bottomRadius: 70, topRadius: 70, observationCount: 1, confidence: 0.3),
            lastObservedAt: oldDate)
        context.insert(unrelated)
        matched.lastObservedAt = oldDate
        let unrelatedProfile = unrelated.profile

        ride.recorder.learnLiftProfile(from: segment)
        XCTAssertEqual(matched.lastObservedAt, segment.endedAt)
        XCTAssertEqual(unrelated.lastObservedAt, oldDate)
        XCTAssertEqual(unrelated.profile, unrelatedProfile)

        matched.lastObservedAt = segment.endedAt.addingTimeInterval(100)
        ride.recorder.learnLiftProfile(from: segment)
        XCTAssertEqual(matched.lastObservedAt, segment.endedAt.addingTimeInterval(100))
    }

    func testJumpHeightCapAppliesAfterTheLandingElevation() throws {
        let base = Date(timeIntervalSince1970: 40_000)
        for (drop, expected) in [(30.0, 25.0), (-12.0, 23.67428474626434), (-20.0, 25.0)] {
            let points = [
                RoutePoint(latitude: 40, longitude: -105, altitude: 100, speed: 9, timestamp: base),
                RoutePoint(
                    latitude: 40, longitude: -105, altitude: 100 - drop, speed: 9,
                    timestamp: base.addingTimeInterval(0.5)),
            ]
            let metrics = try XCTUnwrap(
                JumpMetrics.resolve(
                    takeoffTimestamp: base, landingTimestamp: base.addingTimeInterval(0.5),
                    airtime: 0.5, positions: points))
            XCTAssertEqual(metrics.heightMeters, expected, accuracy: 0.001)
            XCTAssertEqual(metrics.dropMeters, drop, accuracy: 0.001)
        }
    }

    func testRawLogWriterDrainsConcurrentAppendsOnClose() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = RawLogWriter(url: url)
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            writer.append(RawDiagnosticRecord(kind: "probe", runNumber: index))
        }
        writer.close()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try decoder.decode(RawDiagnosticRecord.self, from: Data($0.utf8))
        }
        XCTAssertEqual(records.count, 1_000)
        XCTAssertEqual(Set(records.compactMap(\.runNumber)), Set(0..<1_000))
    }

    func testDeviceMotionJumpIsPersistedWithMeasuredSize() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }

        _ = try ride.start()
        ride.idle(5)
        ride.climb(60)
        ride.idle(10)
        ride.descend(40)
        XCTAssertEqual(ride.recorder.phase, .run)

        ride.jumpAndLand()
        ride.descend(18)
        ride.idle(10)
        let finished = try ride.stop()

        let run = try XCTUnwrap(finished.segments.first { $0.kind == .run })
        XCTAssertEqual(run.jumps.count, 1)
        let jump = try XCTUnwrap(run.jumps.first)
        XCTAssertEqual(jump.airtime, 0.32, accuracy: 0.02)
        // Size is measured from smoothed route and altitude samples, so the
        // exact number moves with the filters. It has to land in the
        // neighborhood of the 2.2 m, 0.6 m synthetic jump.
        let length = try XCTUnwrap(jump.lengthMeters)
        XCTAssertGreaterThan(length, 1.0)
        XCTAssertLessThan(length, 2.6)
        let drop = try XCTUnwrap(jump.dropMeters)
        XCTAssertGreaterThan(drop, 0.2)
        XCTAssertLessThan(drop, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(jump.heightMeters), 0)
        XCTAssertEqual(finished.jumpCount, 1)
        XCTAssertEqual(finished.longestJumpAirtime, 0.32, accuracy: 0.02)
        XCTAssertTrue(ride.watchSink.states.contains { $0.run?.jumpCount == 1 })
    }

    func testSurveyingDoesNotChangeRideSegmentsTotalsOrWatchStates() async throws {
        let plain = try RecordingHarness()
        defer { plain.cleanup() }
        _ = try plain.start()
        plain.feedParkDay(laps: 2)
        let original = try plain.stop()
        let surveyed = try RecordingHarness()
        defer { surveyed.cleanup() }
        _ = try surveyed.start()
        surveyed.idle(5)
        surveyed.climb(60)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let survey = TrailSurveyStore(
            directory: directory, locationService: LocationService(capture: surveyed.capture),
            now: { surveyed.clock.now })
        await survey.loadDrafts()
        let id = try survey.create(
            catalog: TrailCatalogRegistry.mountainCreek, slug: nil, name: "Test", difficulty: "blue")
        try survey.resume(id)
        XCTAssertEqual(surveyed.capture.startCount, 1)
        surveyed.idle(10)
        surveyed.descend(60)
        try survey.pause()
        XCTAssertEqual(surveyed.capture.consumerCount, 1)
        surveyed.idle(10)
        surveyed.climb(60)
        surveyed.idle(10)
        surveyed.descend(60)
        surveyed.idle(10)
        let result = try surveyed.stop()
        XCTAssertEqual(
            result.segments.sorted { $0.startedAt < $1.startedAt }.map(\.kind),
            original.segments.sorted { $0.startedAt < $1.startedAt }.map(\.kind))
        XCTAssertEqual(result.distanceMeters, original.distanceMeters, accuracy: 0.00001)
        XCTAssertEqual(result.descentMeters, original.descentMeters, accuracy: 0.00001)
        XCTAssertEqual(result.liftMeters, original.liftMeters, accuracy: 0.00001)
        XCTAssertEqual(result.maximumSpeedMetersPerSecond, original.maximumSpeedMetersPerSecond, accuracy: 0.00001)
        let originalStates = plain.watchSink.states.map {
            "\($0.status):\($0.phase):\($0.distanceMeters):\($0.descentMeters):\($0.run?.number ?? 0)"
        }
        let surveyedStates = surveyed.watchSink.states.map {
            "\($0.status):\($0.phase):\($0.distanceMeters):\($0.descentMeters):\($0.run?.number ?? 0)"
        }
        XCTAssertEqual(surveyedStates, originalStates)
        XCTAssertEqual(surveyed.capture.stopCount, 1)
        XCTAssertTrue(try ModelContext(surveyed.container).fetch(FetchDescriptor<Trail>()).isEmpty)
    }

    func testSurveyFirstRidePauseFinishAndBackgroundPreserveSurvey() async throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let survey = TrailSurveyStore(
            directory: directory, locationService: LocationService(capture: ride.capture),
            now: { ride.clock.now })
        await survey.loadDrafts()
        let id = try survey.create(
            catalog: TrailCatalogRegistry.mountainCreek, slug: nil, name: "Test", difficulty: "blue")
        try survey.resume(id)
        _ = try ride.start()
        XCTAssertEqual(ride.capture.startCount, 1)
        ride.descend(40)
        XCTAssertTrue(ride.recorder.pause())
        let before = survey.active?.pointCount ?? 0
        ride.idle(5)
        XCTAssertEqual(survey.active?.pointCount, before + 5)
        XCTAssertEqual(ride.capture.consumerCount, 1)
        XCTAssertTrue(ride.recorder.resume())
        ride.climb(40)
        _ = try ride.stop()
        XCTAssertEqual(ride.capture.consumerCount, 1)
        ride.recorder.appDidEnterBackground()
        XCTAssertEqual(ride.capture.consumerCount, 1)
        ride.idle(5)
        try survey.save(id)
        XCTAssertEqual(ride.capture.consumerCount, 0)
        XCTAssertEqual(ride.capture.stopCount, 1)
        XCTAssertEqual(ride.watchSink.states.last?.status, .idle)
    }

    func testDiagnosticLogReplayReproducesTheRecordedDay() throws {
        let ride = try RecordingHarness()
        defer { ride.cleanup() }

        let day = try ride.start()
        ride.feedParkDay(laps: 2)
        let finished = try ride.stop()

        let logURL = try XCTUnwrap(ride.recorder.debugLogURL(for: day))
        let rebuilt = try XCTUnwrap(DiagnosticSummaryRebuilder.rebuild(dayID: day.id, logURL: logURL))
        let persisted = finished.segments.sorted { $0.startedAt < $1.startedAt }

        XCTAssertEqual(rebuilt.segments.map(\.kind), persisted.map(\.kind))
        XCTAssertEqual(rebuilt.segments.compactMap(\.runNumber), [1, 2])
        for (segment, saved) in zip(rebuilt.segments, persisted) {
            XCTAssertEqual(segment.startedAt.timeIntervalSince(saved.startedAt), 0, accuracy: 0.001)
            XCTAssertEqual(segment.endedAt.timeIntervalSince(saved.endedAt), 0, accuracy: 0.001)
            // A replayed segment also carries the samples that were buffered
            // around a transition, so its route only has to be at least as
            // long as the live one.
            XCTAssertGreaterThanOrEqual(segment.distanceMeters, saved.distanceMeters * 0.95)
            XCTAssertLessThanOrEqual(segment.distanceMeters, saved.distanceMeters * 1.35)
            XCTAssertGreaterThan(segment.verticalMeters, 0)
            XCTAssertGreaterThan(segment.maximumSpeedMetersPerSecond, 0)
        }
    }
}

@MainActor
private final class WatchStateSpy: WatchRideStateSink {
    private(set) var states: [WatchRideState] = []

    func publish(_ state: WatchRideState, force: Bool) {
        states.append(state)
    }
}

@MainActor
private final class RideClock {
    var now: Date
    var uptime: TimeInterval

    init(now: Date, uptime: TimeInterval) {
        self.now = now
        self.uptime = uptime
    }
}

/// A recorder wired to an in-memory store, a fake clock, and a watch spy, plus
/// a small synthetic ride generator. Every fix is one virtual second apart and
/// moves due north; altitude changes linearly at the requested rate.
@MainActor
private final class RecordingHarness {
    private static let sessionStart = Date(timeIntervalSince1970: 1_800_000_000)
    private static let baseUptime: TimeInterval = 5_000
    private static let latitudePerMeter = 9.0e-6
    private static let summaryVersionKey = "berms.diagnosticSummaryVersion"

    let container: ModelContainer
    let capture = LocationCapture(usesHardware: false)
    let clock: RideClock
    let watchSink: WatchStateSpy
    private(set) var recorder: RideRecorder

    private let previousRecordingActive: Bool
    private let previousSummaryVersion: String?
    private let previousSensitivity: String?
    private var latitude = 40.0
    private var altitude = 1_200.0
    private var seconds: TimeInterval = 0
    private var diagnosticLogURLs: [URL] = []

    init() throws {
        let schema = Schema([RideDay.self, RideSegment.self, Trail.self, TrailPass.self, LearnedLift.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        self.container = container

        let clock = RideClock(now: Self.sessionStart, uptime: Self.baseUptime)
        self.clock = clock
        let watchSink = WatchStateSpy()
        self.watchSink = watchSink

        previousRecordingActive = UserDefaults.standard.bool(forKey: "berms.recordingActive")
        previousSummaryVersion = UserDefaults.standard.string(forKey: Self.summaryVersionKey)
        previousSensitivity = UserDefaults.standard.string(forKey: "berms.jumpSensitivity")
        // Keep relaunch tests from kicking off the diagnostic migration and the
        // jump detector on the standard sensitivity.
        UserDefaults.standard.set("12", forKey: Self.summaryVersionKey)
        UserDefaults.standard.removeObject(forKey: "berms.jumpSensitivity")

        recorder = RideRecorder(
            context: ModelContext(container),
            watchStateSink: watchSink,
            authorizationOverride: .authorizedAlways,
            now: { clock.now },
            uptime: { clock.uptime },
            locationService: LocationService(capture: capture))
    }

    @discardableResult
    func start() throws -> RideDay {
        move(to: 0)
        XCTAssertTrue(recorder.start())
        let day = try XCTUnwrap(recorder.activeDay)
        diagnosticLogURLs.append(RideRecorder.debugLogURL(for: day.id))
        return day
    }

    @discardableResult
    func stop() throws -> RideDay {
        try XCTUnwrap(recorder.stop())
    }

    /// Swaps in a recorder built over a fresh context, the way a relaunch
    /// would, and restores the unfinished session onto it.
    @discardableResult
    func relaunchRecorder() -> RideRecorder {
        recorder.locationService.stop()
        recorder.motionService.stop()
        recorder.diagnosticLogger?.close()
        let relaunched = RideRecorder(
            context: ModelContext(container),
            watchStateSink: watchSink,
            authorizationOverride: .authorizedAlways,
            now: { [clock] in clock.now },
            uptime: { [clock] in clock.uptime },
            locationService: LocationService(capture: capture))
        relaunched.resumeIfNeeded(autoResume: true)
        recorder = relaunched
        return relaunched
    }

    func cleanup() {
        recorder.locationService.stop()
        recorder.motionService.stop()
        UserDefaults.standard.set(previousRecordingActive, forKey: "berms.recordingActive")
        if let previousSummaryVersion {
            UserDefaults.standard.set(previousSummaryVersion, forKey: Self.summaryVersionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.summaryVersionKey)
        }
        if let previousSensitivity {
            UserDefaults.standard.set(previousSensitivity, forKey: "berms.jumpSensitivity")
        } else {
            UserDefaults.standard.removeObject(forKey: "berms.jumpSensitivity")
        }
        for url in diagnosticLogURLs {
            try? FileManager.default.removeItem(at: url)
            let backup = url.deletingLastPathComponent().appendingPathComponent(
                "\(url.deletingPathExtension().lastPathComponent)-checkpoint.json")
            try? FileManager.default.removeItem(at: backup)
        }
    }

    func diagnosticLog(for day: RideDay) throws -> String {
        let url = try XCTUnwrap(recorder.debugLogURL(for: day))
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Synthetic ride

    func feedParkDay(laps: Int) {
        idle(5)
        for _ in 0..<laps {
            climb(60)
            idle(10)
            descend(60)
            idle(10)
        }
    }

    func idle(_ duration: Int) {
        for _ in 0..<duration {
            seconds += 1
            feedGPS(speed: 0, verticalRate: 0, stationary: true)
        }
    }

    func climb(_ duration: Int, speed: Double = 4, verticalRate: Double = 2) {
        for _ in 0..<duration {
            seconds += 1
            feedGPS(speed: speed, verticalRate: verticalRate, stationary: false)
        }
    }

    func descend(_ duration: Int, speed: Double = 7, verticalRate: Double = -2) {
        for _ in 0..<duration {
            seconds += 1
            feedGPS(speed: speed, verticalRate: verticalRate, stationary: false)
        }
    }

    func skipAhead(_ duration: TimeInterval) {
        move(to: seconds + duration)
    }

    /// Assumes `seconds` is the timestamp of the last fix. Feeds 1.52 s of
    /// riding motion, 0.32 s of unweighting, and a landing impact, then the
    /// next fix two seconds after the last one so the jump resolves against
    /// the route. The airtime stays clear of the detector's 0.28 s floor,
    /// which an exactly-0.28 s test window sits on the wrong side of once the
    /// float arithmetic rounds.
    func jumpAndLand() {
        let start = seconds
        for index in 0..<38 {
            feedMotion(at: start + Double(index) * 0.04, forceG: 1.0)
        }
        var offset = start + 1.52
        for _ in 0..<8 {
            feedMotion(at: offset, forceG: 0.2)
            offset += 0.04
        }
        feedMotion(at: offset, forceG: 1.8)
        seconds = start + 2
        feedGPS(speed: 7, verticalRate: -4, stationary: false, meters: 14)
    }

    private func feedGPS(
        speed: Double,
        verticalRate: Double,
        stationary: Bool,
        meters: Double? = nil
    ) {
        if !stationary {
            latitude += (meters ?? speed) * Self.latitudePerMeter
        }
        altitude += verticalRate
        move(to: seconds)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -105),
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: -1,
            speed: speed,
            timestamp: clock.now)
        capture.deliver(location, stationary: stationary)
    }

    func feedMotion(at offset: TimeInterval, forceG: Double) {
        let sample = DeviceMotionSample(
            recordedAt: Self.sessionStart.addingTimeInterval(offset),
            monotonicSeconds: Self.baseUptime + offset,
            userAccelerationX: 0,
            userAccelerationY: 0,
            userAccelerationZ: 1 - forceG,
            rotationRateX: 0,
            rotationRateY: 0,
            rotationRateZ: 0,
            gravityX: 0,
            gravityY: 0,
            gravityZ: -1,
            quaternionW: 1,
            quaternionX: 0,
            quaternionY: 0,
            quaternionZ: 0)
        recorder.consume(deviceMotion: sample)
    }

    private func move(to offset: TimeInterval) {
        seconds = offset
        clock.now = Self.sessionStart.addingTimeInterval(offset)
        clock.uptime = Self.baseUptime + offset
    }
}
