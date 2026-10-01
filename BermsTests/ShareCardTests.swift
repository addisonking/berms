import Foundation
import SwiftData
import XCTest

@testable import Berms

final class ShareCardTests: XCTestCase {
    func testPresetPixelSizes() {
        XCTAssertEqual(ShareCardPreset.story.pixelSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(ShareCardPreset.post.pixelSize, CGSize(width: 1080, height: 1080))
        XCTAssertEqual(ShareCardPreset.portrait.pixelSize, CGSize(width: 1080, height: 1350))
    }

    func testStoryMapFrameFillsCanvas() {
        XCTAssertEqual(ShareCardPreset.story.mapFrameSize, ShareCardPreset.story.canvasSize)
        XCTAssertLessThan(
            ShareCardPreset.post.mapFrameSize.height,
            ShareCardPreset.post.canvasSize.height)
    }

    func testStatSelectionCapsAtFourAndKeepsAtLeastOne() {
        var configuration = ShareCardConfiguration()
        XCTAssertEqual(configuration.stats, ShareStatKind.defaultSelection)

        configuration.toggleStat(.distance)
        XCTAssertEqual(configuration.stats.count, ShareCardConfiguration.maximumStats)
        XCTAssertFalse(configuration.canToggleStat(.topSpeed))

        for kind in configuration.stats {
            configuration.toggleStat(kind)
        }
        XCTAssertEqual(configuration.stats.count, 1)
    }

    func testConfigurationStoreRoundTripAndEmptyStatsFallback() throws {
        let suiteName = "berms.tests.share-card-configuration"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var configuration = ShareCardConfiguration()
        configuration.preset = .portrait
        configuration.mapStyle = .satellite
        configuration.showsWatermark = false
        configuration.showsTrails = true
        configuration.stats = [.jumps, .distance]
        ShareCardConfigurationStore.save(configuration, to: defaults)
        XCTAssertEqual(ShareCardConfigurationStore.load(from: defaults), configuration)

        let empty = ShareCardConfiguration(stats: [])
        ShareCardConfigurationStore.save(empty, to: defaults)
        XCTAssertEqual(
            ShareCardConfigurationStore.load(from: defaults).stats,
            ShareStatKind.defaultSelection)

        var legacy = ShareCardConfiguration()
        legacy.stats = [.descent, .distance, .topSpeed, .runs]
        defaults.set(try JSONEncoder().encode(legacy), forKey: ShareCardConfigurationStore.key)
        XCTAssertEqual(
            ShareCardConfigurationStore.load(from: defaults).stats,
            ShareStatKind.defaultSelection)
    }

    func testContentBuilderUsesDayNameResortAndSelectedStats() {
        let day = makeDay()
        day.setName("Powder day")

        var configuration = ShareCardConfiguration()
        configuration.stats = [.runs, .descent, .jumps]
        let content = ShareCardContentBuilder.build(
            day: day,
            base: nil,
            trailDetails: nil,
            manualCatalogID: nil,
            configuration: configuration)

        XCTAssertEqual(content.title, "Powder day")
        XCTAssertTrue(content.meta.contains(content.resortName))
        XCTAssertEqual(content.stats.map(\.kind), [.runs, .descent])
        XCTAssertEqual(content.stats.first?.value, "1")
        XCTAssertEqual(content.stats.last?.value, "492 ft")
        XCTAssertFalse(content.hasRoute)
        XCTAssertTrue(content.accessibilitySummary.contains("Powder day"))
    }

    func testShortSessionShareCardUsesDurationInsteadOfEmptyStats() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let day = RideDay(startedAt: start)
        day.endedAt = start.addingTimeInterval(4)

        let content = ShareCardContentBuilder.build(
            day: day,
            base: nil,
            trailDetails: nil,
            manualCatalogID: nil,
            configuration: ShareCardConfiguration())

        XCTAssertEqual(content.title, "Unknown bike park")
        XCTAssertEqual(content.stats.map(\.kind), [.duration])
        XCTAssertEqual(content.stats.first?.value, "00:04")
        XCTAssertEqual(ShareCardContentBuilder.availableStats(day: day, base: nil), [.duration])
        XCTAssertFalse(content.hasRoute)
    }

    func testRunStatsHideUnavailableJumpMetrics() {
        let day = makeDay()
        let segment = day.segments[0]
        let detail = SessionDetailSegment(
            id: segment.id,
            kind: .run,
            startedAt: day.startedAt,
            endedAt: day.startedAt.addingTimeInterval(30),
            distanceMeters: segment.distanceMeters,
            verticalMeters: segment.verticalMeters,
            maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond,
            routePoints: segment.points,
            jumps: [],
            resortID: nil,
            activeResort: "")

        let metrics = RunStatsPresentation.metrics(segment: segment, detail: detail)

        XCTAssertEqual(metrics.map(\.label), ["Duration", "Distance", "Descent", "Top speed"])
    }

    func testJumpStatsKeepAvailableAirtimeWithoutEmptyMeasurements() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let jump = JumpEvent(
            takeoffTimestamp: start,
            landingTimestamp: start.addingTimeInterval(0.44),
            takeoffMonotonicSeconds: 0,
            landingMonotonicSeconds: 0.44)

        let metrics = JumpStatsPresentation.metrics(jump: jump)

        XCTAssertEqual(metrics.map(\.label), ["Airtime"])
        XCTAssertEqual(metrics.first?.value, "0.44s")
    }

    func testFramingNeedsValidPointsAndCentersOnRoute() throws {
        XCTAssertNil(ShareMapFraming.make(points: [], size: CGSize(width: 360, height: 216)))

        let points = [
            RoutePoint(latitude: 41.25, longitude: -74.50, altitude: 100, speed: 5, timestamp: .now),
            RoutePoint(latitude: 41.26, longitude: -74.49, altitude: 120, speed: 6, timestamp: .now),
        ]
        let framing = try XCTUnwrap(
            ShareMapFraming.make(
                points: points,
                size: CGSize(width: 360, height: 216)))
        XCTAssertEqual(framing.region.center.latitude, 41.255, accuracy: 0.0001)
        XCTAssertEqual(framing.region.center.longitude, -74.495, accuracy: 0.0001)
        XCTAssertGreaterThan(framing.largestSpan, 0)
    }

    @MainActor
    func testRendererProducesExactPixelSize() throws {
        let content = ShareCardContent(
            resortName: "Mountain Creek Resort",
            title: "Mountain Creek Resort",
            meta: "Feb 14, 2026",
            stats: [ShareCardStat(kind: .descent, value: "1,200 ft")],
            routes: [],
            jumps: [],
            trails: [])
        for preset in ShareCardPreset.allCases {
            let configuration = ShareCardConfiguration(preset: preset)
            let image = try XCTUnwrap(
                ShareCardRenderer.render(
                    content: content,
                    configuration: configuration,
                    mapImage: nil))
            XCTAssertEqual(image.size.width * image.scale, preset.pixelSize.width, accuracy: 0.5)
            XCTAssertEqual(image.size.height * image.scale, preset.pixelSize.height, accuracy: 0.5)
            XCTAssertNotNil(image.pngData())
        }
    }

    @MainActor
    func testFileNameSanitizesResortName() {
        let content = ShareCardContent(
            resortName: "Mountain Creek Resort",
            title: "Mountain Creek Resort",
            meta: "Feb 14, 2026",
            stats: [],
            routes: [],
            jumps: [],
            trails: [])
        let name = ShareCardRenderer.fileName(
            content: content,
            preset: .post,
            date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(name, "Berms-Mountain-Creek-Resort-1970-01-01-post.png")
    }

    private func makeDay() -> RideDay {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0...30).map { index in
            RoutePoint(
                latitude: 41.25 + Double(index) * 0.0001,
                longitude: -74.50,
                altitude: 500 - Double(index) * 5,
                speed: 8,
                timestamp: start.addingTimeInterval(Double(index)))
        }
        let day = RideDay(startedAt: start)
        let segment = RideSegment(
            kind: .run,
            startedAt: start,
            endedAt: start.addingTimeInterval(30),
            routeData: (try? RouteCodec.encode(points)) ?? Data())
        segment.distanceMeters = 900
        segment.verticalMeters = 150
        segment.maximumSpeedMetersPerSecond = 12
        segment.day = day
        day.segments.append(segment)
        day.recalculateTotals()
        return day
    }
}

final class SessionLoadingTests: XCTestCase {
    @MainActor
    func testCompletedPreparationsDoNotInvalidateActiveLoading() {
        let cache = SessionDetailPresentationCache()
        let base = SessionDetailBase(runs: [], mapSegments: [], jumpMarkers: [], segmentsByID: [:])
        let details = SessionDetailTrailDetails(overlays: [], sequenceBySegmentID: [:])
        let dayID = UUID()
        cache.store(.init(base: base, trailDetails: details), for: dayID.uuidString)
        let detail = SessionDetailSegment(
            id: UUID(), kind: .run, startedAt: .now, endedAt: .now,
            distanceMeters: 0, verticalMeters: 0, maximumSpeedMetersPerSecond: 0,
            routePoints: [], jumps: [], resortID: nil, activeResort: "")
        cache.storeRun(.init(base: base, detail: detail, trailDetails: details), for: "other-run")
        XCTAssertEqual(cache.invalidationRevision, 0)
        cache.invalidate(dayID: dayID)
        XCTAssertEqual(cache.invalidationRevision, 1)
        XCTAssertNil(cache.entry(for: dayID.uuidString))
        // Corrections during a cold load must restart it even before anything is cached.
        cache.invalidate(dayID: dayID)
        XCTAssertEqual(cache.invalidationRevision, 2)
    }

    @MainActor
    func testBackgroundCatalogResolutionReadsSavedDayAndHonorsOverride() async throws {
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let day = RideDay()
        let startedAt = day.startedAt
        let points: [RoutePoint] = (0..<120).map { index in
            return RoutePoint(
                latitude: index == 0 ? 0 : 41.1844,
                longitude: index == 0 ? 0 : -74.5033,
                altitude: 100, speed: 8,
                timestamp: startedAt.addingTimeInterval(Double(index)))
        }
        let segment = RideSegment(
            kind: .run, startedAt: day.startedAt, endedAt: day.startedAt.addingTimeInterval(120),
            routeData: try RouteCodec.encode(points))
        segment.day = day
        day.segments = [segment]
        context.insert(day)
        try context.save()
        let automatic = await SessionDetailPresentationPreheater.resolvedCatalog(
            dayID: day.id, container: container)
        XCTAssertEqual(automatic?.id, TrailCatalogRegistry.mountainCreekCatalogID)
        day.catalogID = TrailCatalogRegistry.defaultCatalog.id
        try context.save()
        let catalog = await SessionDetailPresentationPreheater.resolvedCatalog(
            dayID: day.id, container: container)
        XCTAssertEqual(catalog?.id, day.catalogID)
        let missing = await SessionDetailPresentationPreheater.resolvedCatalog(
            dayID: UUID(), container: container)
        XCTAssertNil(missing)
    }
}
