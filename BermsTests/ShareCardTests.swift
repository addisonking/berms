import Foundation
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
        XCTAssertLessThan(ShareCardPreset.post.mapFrameSize.height,
                          ShareCardPreset.post.canvasSize.height)
    }

    func testStatSelectionCapsAtFourAndKeepsAtLeastOne() {
        var configuration = ShareCardConfiguration()
        XCTAssertEqual(configuration.stats, ShareStatKind.defaultSelection)

        for kind in ShareStatKind.allCases {
            configuration.toggleStat(kind)
        }
        XCTAssertEqual(configuration.stats.count, ShareCardConfiguration.maximumStats)

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
        XCTAssertEqual(ShareCardConfigurationStore.load(from: defaults).stats,
                       ShareStatKind.defaultSelection)
    }

    func testContentBuilderUsesDayNameResortAndSelectedStats() {
        let day = makeDay()
        day.setName("Powder day")

        var configuration = ShareCardConfiguration()
        configuration.stats = [.runs, .descent, .jumps]
        let content = ShareCardContentBuilder.build(day: day,
                                                    base: nil,
                                                    trailDetails: nil,
                                                    manualCatalogID: nil,
                                                    configuration: configuration)

        XCTAssertEqual(content.title, "Powder day")
        XCTAssertTrue(content.meta.contains(content.resortName))
        XCTAssertEqual(content.stats.map(\.kind), [.runs, .descent, .jumps])
        XCTAssertEqual(content.stats.first?.value, "1")
        XCTAssertEqual(content.stats.last?.value, "—")
        XCTAssertFalse(content.hasRoute)
        XCTAssertTrue(content.accessibilitySummary.contains("Powder day"))
    }

    func testFramingNeedsValidPointsAndCentersOnRoute() throws {
        XCTAssertNil(ShareMapFraming.make(points: [], size: CGSize(width: 360, height: 216)))

        let points = [
            RoutePoint(latitude: 41.25, longitude: -74.50, altitude: 100, speed: 5, timestamp: .now),
            RoutePoint(latitude: 41.26, longitude: -74.49, altitude: 120, speed: 6, timestamp: .now)
        ]
        let framing = try XCTUnwrap(ShareMapFraming.make(points: points,
                                                         size: CGSize(width: 360, height: 216)))
        XCTAssertEqual(framing.region.center.latitude, 41.255, accuracy: 0.0001)
        XCTAssertEqual(framing.region.center.longitude, -74.495, accuracy: 0.0001)
        XCTAssertGreaterThan(framing.largestSpan, 0)
    }

    @MainActor
    func testRendererProducesExactPixelSize() throws {
        let content = ShareCardContent(resortName: "Mountain Creek Resort",
                                       title: "Mountain Creek Resort",
                                       meta: "Feb 14, 2026",
                                       stats: [ShareCardStat(kind: .descent, value: "1,200 ft")],
                                       routes: [],
                                       jumps: [],
                                       trails: [])
        for preset in ShareCardPreset.allCases {
            let configuration = ShareCardConfiguration(preset: preset)
            let image = try XCTUnwrap(ShareCardRenderer.render(content: content,
                                                               configuration: configuration,
                                                               mapImage: nil))
            XCTAssertEqual(image.size.width * image.scale, preset.pixelSize.width, accuracy: 0.5)
            XCTAssertEqual(image.size.height * image.scale, preset.pixelSize.height, accuracy: 0.5)
            XCTAssertNotNil(image.pngData())
        }
    }

    @MainActor
    func testFileNameSanitizesResortName() {
        let content = ShareCardContent(resortName: "Mountain Creek Resort",
                                       title: "Mountain Creek Resort",
                                       meta: "Feb 14, 2026",
                                       stats: [],
                                       routes: [],
                                       jumps: [],
                                       trails: [])
        let name = ShareCardRenderer.fileName(content: content,
                                              preset: .post,
                                              date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(name, "Berms-Mountain-Creek-Resort-1970-01-01-post.png")
    }

    private func makeDay() -> RideDay {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0...30).map { index in
            RoutePoint(latitude: 41.25 + Double(index) * 0.0001,
                       longitude: -74.50,
                       altitude: 500 - Double(index) * 5,
                       speed: 8,
                       timestamp: start.addingTimeInterval(Double(index)))
        }
        let day = RideDay(startedAt: start)
        let segment = RideSegment(kind: .run,
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
