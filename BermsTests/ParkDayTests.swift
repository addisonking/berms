import Foundation
import XCTest

@testable import Berms

final class ParkDayTests: XCTestCase {
    func testFullDayStartsAndFinishesAtBottom() {
        let detector = ParkLapDetector()
        var finished: [SegmentDraft] = []
        var time = 0.0
        func feed(_ altitude: Double, speed: Double, cycling: Bool = false, stationary: Bool = false) {
            for event in detector.process(point(time, altitude, speed: speed, cycling: cycling, stationary: stationary))
            {
                if case .finished(let draft) = event { finished.append(draft) }
            }
            time += 1
        }

        for lap in 0..<4 {
            for _ in 0..<90 { feed(0, speed: 0, stationary: true) }
            for altitude in 0...120 { feed(Double(altitude), speed: 3) }
            for _ in 0..<90 { feed(120, speed: 0, stationary: true) }
            for altitude in stride(from: 120, through: 80, by: -1) { feed(Double(altitude), speed: 7) }
            for _ in 0..<90 { feed(80, speed: 0, stationary: true) }
            for altitude in stride(from: 80, through: 0, by: -1) { feed(Double(altitude), speed: 7) }
            if lap == 1 {
                if case .finished(let draft) = detector.finish() { finished.append(draft) }
                time += 45 * 60
            }
        }
        for _ in 0..<90 { feed(0, speed: 0, stationary: true) }
        if case .finished(let draft) = detector.finish() { finished.append(draft) }

        XCTAssertEqual(finished.map(\.kind), [.lift, .run, .lift, .run, .lift, .run, .lift, .run])
        for draft in finished {
            XCTAssertEqual(draft.points.last?.altitude, draft.kind == .run ? 0 : 120)
            XCTAssertGreaterThan(draft.netVerticalMeters, 110)
            XCTAssertTrue(draft.points.allSatisfy { !$0.isStationary })
            XCTAssertTrue(zip(draft.points, draft.points.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        }
        XCTAssertEqual(detector.phase, .idle)
        XCTAssertNil(detector.finish())
    }

    func testFinishIncludesLongFlatRolloutButNotBottomWait() {
        let detector = ParkLapDetector()
        for t in 0...120 { _ = detector.process(point(Double(t), 120 - Double(t), speed: 7)) }
        for t in 121...180 { _ = detector.process(point(Double(t), 0, speed: 5)) }
        for t in 181...240 { _ = detector.process(point(Double(t), 0, speed: 0, stationary: true)) }
        guard case .finished(let draft) = detector.finish() else { return XCTFail("Missing final run") }
        XCTAssertEqual(draft.kind, .run)
        XCTAssertEqual(draft.endedAt, Date(timeIntervalSince1970: 1_180))
        XCTAssertEqual(draft.points.last?.coordinate, point(180, 0, speed: 5).coordinate)
        XCTAssertTrue(draft.points.allSatisfy { !$0.isStationary })
    }

    func testOnTrailBreakResumesTheSameRun() {
        let detector = ParkLapDetector()
        var events: [DetectorEvent] = []
        for t in 0...30 {
            events += detector.process(point(Double(t), 100 - Double(t), speed: 7, cycling: true))
        }
        for t in 31...38 {
            events += detector.process(point(Double(t), 70, speed: 0, stationary: true))
        }
        for t in 39...45 {
            events += detector.process(point(Double(t), 70 - Double(t - 38), speed: 7, cycling: true))
        }

        XCTAssertEqual(detector.phase, .run)
        XCTAssertFalse(
            events.contains {
                if case .finished = $0 { return true }
                return false
            })
        XCTAssertEqual(detector.currentPoints.last?.altitude, 63)
    }

    func testLearnedLiftEndpointsFinishSegmentsIntoIdle() {
        let profile = LearnedLiftProfile(
            id: UUID(),
            bottom: Coordinate(latitude: 40.0005, longitude: -105),
            top: Coordinate(latitude: 40.0002, longitude: -105),
            bottomRadius: 30,
            topRadius: 30,
            observationCount: 3,
            confidence: 1
        )
        var configuration = ParkLapDetector.Configuration()
        configuration.learnedLifts = [profile]
        let detector = ParkLapDetector(configuration: configuration)
        var finished: [SegmentDraft] = []

        for t in 0...20 {
            let events = detector.process(point(Double(t), Double(t) * 6, speed: 3))
            finished += events.compactMap {
                if case .finished(let draft) = $0 { return draft }
                return nil
            }
        }
        for t in 21...29 {
            let events = detector.process(point(Double(t), 120, speed: 0, stationary: true))
            finished += events.compactMap {
                if case .finished(let draft) = $0 { return draft }
                return nil
            }
        }
        XCTAssertEqual(detector.phase, .idle)
        XCTAssertEqual(finished.map(\.kind), [.lift])

        for t in 30...50 {
            let events = detector.process(point(Double(t), 120 - Double(t - 30) * 6, speed: 7, cycling: true))
            finished += events.compactMap {
                if case .finished(let draft) = $0 { return draft }
                return nil
            }
        }
        for t in 51...59 {
            let events = detector.process(point(Double(t), 0, speed: 0, stationary: true))
            finished += events.compactMap {
                if case .finished(let draft) = $0 { return draft }
                return nil
            }
        }

        XCTAssertEqual(detector.phase, .idle)
        XCTAssertEqual(finished.map(\.kind), [.lift, .run])
    }

    func testSlowAscentOutsideKnownLiftZoneDoesNotSplitRun() {
        let profile = LearnedLiftProfile(
            id: UUID(),
            bottom: Coordinate(latitude: 40.02, longitude: -105),
            top: Coordinate(latitude: 40.03, longitude: -105),
            bottomRadius: 60,
            topRadius: 60,
            observationCount: 3,
            confidence: 1
        )
        var configuration = ParkLapDetector.Configuration()
        configuration.learnedLifts = [profile]
        let detector = ParkLapDetector(configuration: configuration)
        var events: [DetectorEvent] = []

        for t in 0...30 {
            events += detector.process(point(Double(t), 100 - Double(t), speed: 7, cycling: true))
        }
        for t in 31...38 {
            events += detector.process(point(Double(t), 70 - Double(t - 30) * 2, speed: 2))
        }
        for t in 39...55 {
            events += detector.process(point(Double(t), 54 + Double(t - 38) * 2, speed: 2))
        }
        for t in 56...80 {
            events += detector.process(point(Double(t), 88 - Double(t - 55) * 2, speed: 7, cycling: true))
        }

        XCTAssertEqual(detector.phase, .run)
        XCTAssertFalse(
            events.contains {
                if case .finished = $0 { return true }
                return false
            })
        guard case .finished(let draft) = detector.finish() else {
            return XCTFail("Expected the feature session to remain one run")
        }
        XCTAssertEqual(draft.kind, .run)
        let largestGap =
            zip(draft.points, draft.points.dropFirst()).map {
                $1.timestamp.timeIntervalSince($0.timestamp)
            }.max() ?? 0
        XCTAssertLessThanOrEqual(largestGap, 2, "Blocked lift candidates must stay in the run route")
    }

    func testLearnedLiftStartZoneEndsRunAtStationAfterAscent() {
        let profile = LearnedLiftProfile(
            id: UUID(),
            bottom: Coordinate(latitude: 40.0005, longitude: -105),
            top: Coordinate(latitude: 40.01, longitude: -105),
            bottomRadius: 30,
            topRadius: 30,
            observationCount: 3,
            confidence: 1
        )
        var configuration = ParkLapDetector.Configuration()
        configuration.learnedLifts = [profile]
        let detector = ParkLapDetector(configuration: configuration)
        var events: [DetectorEvent] = []

        for t in 0...30 {
            events += detector.process(point(Double(t), 100 - Double(t), speed: 7, cycling: true))
        }
        for t in 31...50 {
            events += detector.process(point(Double(t), 70 + Double(t - 30) * 2, speed: 2))
        }

        XCTAssertEqual(detector.phase, .lift)
        XCTAssertTrue(
            events.contains {
                if case .finished(let draft) = $0 { return draft.kind == .run }
                return false
            })
        XCTAssertTrue(
            events.contains {
                if case .started(kind: .lift, points: _) = $0 { return true }
                return false
            })
    }

    func testUnknownLiftCanStillBeLearnedFromFasterAscent() {
        let profile = LearnedLiftProfile(
            id: UUID(),
            bottom: Coordinate(latitude: 40.02, longitude: -105),
            top: Coordinate(latitude: 40.03, longitude: -105),
            bottomRadius: 60,
            topRadius: 60,
            observationCount: 3,
            confidence: 1
        )
        var configuration = ParkLapDetector.Configuration()
        configuration.learnedLifts = [profile]
        let detector = ParkLapDetector(configuration: configuration)
        var events: [DetectorEvent] = []

        for t in 0...30 {
            events += detector.process(point(Double(t), 100 - Double(t), speed: 7, cycling: true))
        }
        for t in 31...50 {
            events += detector.process(point(Double(t), 70 + Double(t - 30) * 4, speed: 4))
        }

        XCTAssertEqual(detector.phase, .lift)
        XCTAssertTrue(
            events.contains {
                if case .finished(let draft) = $0 { return draft.kind == .run }
                return false
            })
    }

    func testIdleWalkingAfterLearnedBottomDoesNotStartLift() {
        let profile = LearnedLiftProfile(
            id: UUID(),
            bottom: Coordinate(latitude: 40.0005, longitude: -105),
            top: Coordinate(latitude: 40.01, longitude: -105),
            bottomRadius: 20,
            topRadius: 20,
            observationCount: 3,
            confidence: 1
        )
        var configuration = ParkLapDetector.Configuration()
        configuration.learnedLifts = [profile]
        let detector = ParkLapDetector(configuration: configuration)
        var events: [DetectorEvent] = []

        for t in 0...50 {
            events += detector.process(point(Double(t), 120 - Double(t) * 2, speed: 7, cycling: true))
        }
        for t in 51...59 {
            events += detector.process(point(Double(t), 20, speed: 0, stationary: true))
        }
        for t in 60...80 {
            events += detector.process(point(Double(t), 20 + Double(t - 59) * 2, speed: 2))
        }

        XCTAssertEqual(detector.phase, .idle)
        XCTAssertTrue(
            events.contains {
                if case .finished(let draft) = $0 { return draft.kind == .run }
                return false
            })
        XCTAssertFalse(
            events.contains {
                if case .started(kind: .lift, points: _) = $0 { return true }
                return false
            })
    }

    func testRunResumesAfterLongStopWithoutTruncatingAtStop() {
        let detector = ParkLapDetector()
        for t in 0...30 { _ = detector.process(point(Double(t), 100 - Double(t), speed: 7)) }
        for t in 31...330 { _ = detector.process(point(Double(t), 70, speed: 0, stationary: true)) }
        for t in 331...390 { _ = detector.process(point(Double(t), 70 - Double(t - 330), speed: 7)) }

        guard case .finished(let draft) = detector.finish() else { return XCTFail("Missing run") }
        XCTAssertEqual(draft.kind, .run)
        XCTAssertEqual(draft.points.last?.altitude, 10)
        XCTAssertTrue(draft.points.allSatisfy { !$0.isStationary })
    }

    func testAbortedReversalDoesNotDuplicateAnchorOrKeepStationaryPoints() {
        let detector = ParkLapDetector()
        for t in 0...30 { _ = detector.process(point(Double(t), 100 - Double(t), speed: 7, cycling: true)) }
        for t in 31...34 { _ = detector.process(point(Double(t), 70 + Double(t - 30), speed: 3)) }
        for t in 35...37 { _ = detector.process(point(Double(t), 74, speed: 0, stationary: true)) }
        for t in 38...65 { _ = detector.process(point(Double(t), 74 - Double(t - 37), speed: 7, cycling: true)) }

        guard case .finished(let draft) = detector.finish() else { return XCTFail("Missing run") }
        XCTAssertEqual(draft.kind, .run)
        XCTAssertTrue(draft.points.allSatisfy { !$0.isStationary })
        XCTAssertTrue(zip(draft.points, draft.points.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        XCTAssertEqual(draft.points.last?.altitude, 46)
    }

    func testRestoreRunCanResumeAfterLongStop() {
        let detector = ParkLapDetector()
        detector.restore(kind: .run, points: (0...30).map { point(Double($0), 100 - Double($0), speed: 7) })
        for t in 31...330 { _ = detector.process(point(Double(t), 70, speed: 0, stationary: true)) }
        for t in 331...390 { _ = detector.process(point(Double(t), 70 - Double(t - 330), speed: 7)) }
        XCTAssertEqual(detector.currentPoints.last?.altitude, 10)
    }

    func testRecordedParkDayReachesBottomOnEveryRun() throws {
        guard let path = ProcessInfo.processInfo.environment["BERMS_PARK_DAY_LOG"] else {
            throw XCTSkip("Set BERMS_PARK_DAY_LOG to replay the user's diagnostic JSONL")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try DiagnosticLogReplayer().replay(data: data)
        let finished = result.segments
        XCTAssertEqual(finished.map(\.kind), [.lift, .run, .lift, .run, .lift, .run, .lift, .run])
        for draft in finished {
            XCTAssertGreaterThan(draft.netVerticalMeters, 230)
            if draft.kind == .run {
                XCTAssertLessThan(try XCTUnwrap(draft.points.last?.altitude), 180)
                XCTAssertGreaterThan(draft.points.count, 200)
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try String(data: data, encoding: .utf8)!.split(whereSeparator: \.isNewline)
            .map { try decoder.decode(RawDiagnosticRecord.self, from: Data($0.utf8)) }
        let start = try XCTUnwrap(records.first(where: { $0.kind == "session_started" })?.timestamp)
        let day = RideDay(startedAt: start)
        for record in records {
            switch record.kind {
            case "session_paused":
                day.beginPause(at: record.timestamp)
            case "session_resumed":
                _ = day.endPause(at: record.timestamp)
            case "session_stopped":
                if day.isPaused { _ = day.endPause(at: record.timestamp) }
                day.endedAt = record.timestamp
            default:
                continue
            }
        }
        for draft in finished {
            let segment = RideSegment(
                kind: draft.kind, startedAt: draft.startedAt, endedAt: draft.endedAt,
                routeData: try RouteCodec.encode(draft.routePoints), jumps: draft.jumps)
            segment.distanceMeters = draft.distanceMeters
            segment.verticalMeters = draft.netVerticalMeters
            segment.maximumSpeedMetersPerSecond = draft.maximumSpeed
            segment.day = day
            day.segments.append(segment)
        }
        day.recalculateTotals()
        let segmentSummary = day.segments.sorted { $0.startedAt < $1.startedAt }.enumerated().map { index, segment in
            "\(index + 1):\(segment.kind.title) \(BermsFormat.duration(segment.duration)) "
                + "\(BermsFormat.distance(segment.distanceMeters)) "
                + "\(BermsFormat.elevation(segment.verticalMeters)) "
                + "\(BermsFormat.speed(segment.maximumSpeedMetersPerSecond))"
        }.joined(separator: " | ")
        print(
            "PROGRAM_SUMMARY runs=\(finished.filter { $0.kind == .run }.count) "
                + "lifts=\(finished.filter { $0.kind == .lift }.count) "
                + "duration=\(BermsFormat.duration(day.duration)) "
                + "riding=\(BermsFormat.duration(day.activeSeconds)) "
                + "liftTime=\(BermsFormat.duration(day.liftSeconds)) "
                + "distance=\(BermsFormat.distance(day.distanceMeters)) "
                + "descent=\(BermsFormat.elevation(day.descentMeters)) "
                + "liftGain=\(BermsFormat.elevation(day.liftMeters)) "
                + "topSpeed=\(BermsFormat.speed(day.maximumSpeedMetersPerSecond)) "
                + "jumps=\(day.jumpCount) "
                + "longestAirtime=\(BermsFormat.airtime(day.longestJumpAirtime))")
        print("PROGRAM_SEGMENTS \(segmentSummary)")
    }

    private func point(
        _ seconds: Double, _ altitude: Double, speed: Double,
        cycling: Bool = false, stationary: Bool = false
    ) -> TrackSample {
        TrackSample(
            coordinate: Coordinate(latitude: 40 + seconds * 0.00001, longitude: -105),
            altitude: altitude, speed: speed,
            timestamp: Date(timeIntervalSince1970: 1_000 + seconds),
            isStationary: stationary, isCycling: cycling)
    }
}
