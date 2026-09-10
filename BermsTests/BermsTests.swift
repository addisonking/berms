import Foundation
import SwiftData
import XCTest
import SwiftUI
import UIKit
@testable import Berms

final class BermsTests: XCTestCase {
    func testThemeContrastInLightAndDarkAppearance() {
        func luminance(_ color: Color, style: UIUserInterfaceStyle) -> Double {
            let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (foreground, background) in [
                (Color.bermsTrail, Color.bermsInk),
                (.bermsTrail, .bermsCard),
                (.bermsOnAccent, .bermsTrail)
            ] {
                let a = luminance(foreground, style: style)
                let b = luminance(background, style: style)
                XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5)
            }
        }
    }

    @MainActor
    func testMapLayerPreferencesDefaultAndPersist() {
        let suiteName = "BermsTests.mapLayers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = MapLayerPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showsRidePath)
        XCTAssertTrue(preferences.showsActualTrails)
        XCTAssertTrue(preferences.showsJumps)
        XCTAssertTrue(preferences.showsLiftPaths)

        preferences.showsRidePath = false
        preferences.showsActualTrails = false
        preferences.showsJumps = false
        preferences.showsLiftPaths = false

        let restored = MapLayerPreferences(defaults: defaults)
        XCTAssertFalse(restored.showsRidePath)
        XCTAssertFalse(restored.showsActualTrails)
        XCTAssertFalse(restored.showsJumps)
        XCTAssertFalse(restored.showsLiftPaths)
    }

    @MainActor
    func testPreviousRunsPreferenceDefaultsOffAndPersists() {
        let suiteName = "BermsTests.previousRuns.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = MapLayerPreferences(defaults: defaults)
        XCTAssertFalse(preferences.showsPreviousRunsInLiveMap)

        preferences.showsPreviousRunsInLiveMap = true
        let restored = MapLayerPreferences(defaults: defaults)
        XCTAssertTrue(restored.showsPreviousRunsInLiveMap)
    }

    @MainActor
    func testTrailCatalogImportIsIdempotentAndNamespacesIDs() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Trail.self, TrailPass.self,
                                            configurations: configuration)
        let context = container.mainContext
        let suiteName = "BermsTests.catalogImport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstCatalog = TrailCatalogDescriptor(
            id: "catalog-a", resortName: "Resort A", bundledResourceName: "a",
            importVersion: "a-v1", locationAnchor: Coordinate(latitude: 40, longitude: -105),
            stableIDNamespace: "berms:catalog-a", legacyImportVersionKeys: [])
        let secondCatalog = TrailCatalogDescriptor(
            id: "catalog-b", resortName: "Resort B", bundledResourceName: "b",
            importVersion: "b-v1", locationAnchor: Coordinate(latitude: 41, longitude: -106),
            stableIDNamespace: "berms:catalog-b", legacyImportVersionKeys: [])
        let data = Data("""
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Shared name","slug":"shared","difficulty":"green"},"geometry":{"type":"LineString","coordinates":[[-105,40],[-105,40.001]]}}]}
        """.utf8)

        let first = try TrailCatalogImporter.import(data: data, into: context,
                                                     defaults: defaults, catalog: firstCatalog)
        let second = try TrailCatalogImporter.import(data: data, into: context,
                                                      defaults: defaults, catalog: firstCatalog)
        XCTAssertEqual(first.trailsCreated, 1)
        XCTAssertEqual(first.passesCreated, 1)
        XCTAssertEqual(second.trailsCreated, 0)
        XCTAssertEqual(second.passesCreated, 0)

        let firstID = TrailCatalogImporter.stableID(for: "shared", catalog: firstCatalog)
        let secondID = TrailCatalogImporter.stableID(for: "shared", catalog: secondCatalog)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trail>()).count, 1)
    }

    @MainActor
    func testMountainCreekCatalogAppliesOfficialDifficultyCorrectionsAndMergesDuplicates() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Trail.self, TrailPass.self,
                                            configurations: configuration)
        let context = container.mainContext
        let suiteName = "BermsTests.mountainCreekCorrections.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let canonicalSlug = "lower-asylum-1f4u6s"
        let retiredSlug = "lower-asylum-196712"
        let duplicate = Trail(name: "Lower Asylum", difficulty: .black,
                              resort: TrailCatalogRegistry.mountainCreek.resortName)
        duplicate.id = TrailCatalogImporter.stableID(for: retiredSlug,
                                                      catalog: TrailCatalogRegistry.mountainCreek)
        let duplicatePass = TrailPass(routePoints: [
            RoutePoint(latitude: 41.1854, longitude: -74.5022, altitude: 0, speed: 0,
                       timestamp: .now),
            RoutePoint(latitude: 41.1867, longitude: -74.5027,
                       altitude: 0, speed: 0, timestamp: .now.addingTimeInterval(1))
        ])
        duplicatePass.trail = duplicate
        duplicate.passes.append(duplicatePass)
        context.insert(duplicate)
        context.insert(duplicatePass)
        try context.save()

        let data = Data("""
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"name":"Lower Asylum","slug":"\(canonicalSlug)","difficulty":"black"},"geometry":{"type":"LineString","coordinates":[[-74.5022,41.1854],[-74.5027,41.1867]]}},
          {"type":"Feature","properties":{"name":"Lower Asylum","slug":"\(retiredSlug)","difficulty":"black"},"geometry":{"type":"LineString","coordinates":[[-74.5022,41.1854],[-74.5027,41.1867]]}},
          {"type":"Feature","properties":{"name":"Progression Drops","slug":"progression-drops","difficulty":"blue"},"geometry":{"type":"LineString","coordinates":[[-74.50,41.18],[-74.501,41.181]]}},
          {"type":"Feature","properties":{"name":"Deviant","slug":"deviant-kg9399","difficulty":"blue"},"geometry":{"type":"LineString","coordinates":[[-74.50,41.18],[-74.501,41.181]]}},
          {"type":"Feature","properties":{"name":"Pipeline","slug":"pipeline-5y2v8p","difficulty":"doubleBlack"},"geometry":{"type":"LineString","coordinates":[[-74.50,41.18],[-74.501,41.181]]}},
          {"type":"Feature","properties":{"name":"Ripper","slug":"ripper-5ashmy","difficulty":"black"},"geometry":{"type":"LineString","coordinates":[[-74.50,41.18],[-74.501,41.181]]}},
          {"type":"Feature","properties":{"name":"The Pit","slug":"the-pit","difficulty":"black"},"geometry":{"type":"LineString","coordinates":[[-74.50,41.18],[-74.501,41.181]]}}
        ]}
        """.utf8)

        _ = try TrailCatalogImporter.import(data: data, into: context,
                                            defaults: defaults,
                                            catalog: TrailCatalogRegistry.mountainCreek,
                                            version: "mountain-creek-ridepal-v3")

        let trails = try context.fetch(FetchDescriptor<Trail>())
        XCTAssertEqual(trails.count, 6)
        XCTAssertNil(trails.first { $0.id == TrailCatalogImporter.stableID(
            for: retiredSlug, catalog: TrailCatalogRegistry.mountainCreek) })
        XCTAssertEqual(trails.first { $0.name == "Progression Drops" }?.difficulty, .green)
        XCTAssertEqual(trails.first { $0.name == "Deviant" }?.difficulty, .green)
        XCTAssertEqual(trails.first { $0.name == "Pipeline" }?.difficulty, .black)
        XCTAssertEqual(trails.first { $0.name == "Ripper" }?.difficulty, .doubleBlack)
        XCTAssertEqual(trails.first { $0.name == "The Pit" }?.difficulty, .doubleBlack)
        XCTAssertEqual(trails.first { $0.name == "Lower Asylum" }?.passCount, 2)
    }

    @MainActor
    func testManualTrailCatalogSelectionShowsTheSelectedResortAwayFromGPS() {
        let suiteName = "BermsTests.catalogSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let selection = TrailCatalogSelection(defaults: defaults)
        selection.setSelectionID(TrailCatalogRegistry.mountainCreek.id)

        let creekTrail = Trail(name: "Creek trail", difficulty: .green,
                               resort: TrailCatalogRegistry.mountainCreek.resortName)
        let otherTrail = Trail(name: "Other trail", difficulty: .blue, resort: "Other Resort")
        let visible = selection.trails(
            [creekTrail, otherTrail],
            near: Coordinate(latitude: 40.7128, longitude: -74.0060)
        )

        XCTAssertEqual(visible.map(\.name), ["Creek trail"])
    }

    @MainActor
    func testTrailSequenceResolverPreservesRideOrderAndFallsBack() throws {
        let base = Date(timeIntervalSince1970: 10_000)
        let route = (0...20).map { index in
            RoutePoint(latitude: 40 + Double(index) * 0.0001, longitude: -105,
                       altitude: 100 - Double(index), speed: 8,
                       timestamp: base.addingTimeInterval(Double(index)))
        }
        let firstTrail = Trail(name: "First", difficulty: .green, resort: "Test")
        let firstPass = TrailPass(routePoints: Array(route[0...10]))
        firstPass.trail = firstTrail
        firstTrail.passes.append(firstPass)
        let secondTrail = Trail(name: "Second", difficulty: .blue, resort: "Test")
        let secondPass = TrailPass(routePoints: Array(route[10...20]))
        secondPass.trail = secondTrail
        secondTrail.passes.append(secondPass)
        let segment = RideSegment(kind: .run, startedAt: base, endedAt: base.addingTimeInterval(20),
                                  routeData: try RouteCodec.encode(route))

        TrailRouteMatchCache.shared.invalidate()
        XCTAssertEqual(TrailSequenceResolver.names(for: segment,
                                                   trails: [firstTrail, secondTrail]),
                       ["First", "Second"])
        XCTAssertEqual(TrailSequenceResolver.title(for: segment,
                                                    trails: [firstTrail, secondTrail]),
                       "First → Second")
        XCTAssertNil(TrailSequenceResolver.title(for: segment, trails: []))
        TrailRouteMatchCache.shared.invalidate()
    }

    func testLiveMapPresentationSelectsOnlyTheRelevantPath() {
        let point = RoutePoint(latitude: 40, longitude: -105, altitude: 100, speed: 8,
                               timestamp: Date(timeIntervalSince1970: 1))
        let current = [point, RoutePoint(latitude: 40.001, longitude: -105, altitude: 90,
                                         speed: 8, timestamp: Date(timeIntervalSince1970: 2))]
        let older = [point, RoutePoint(latitude: 40.002, longitude: -105, altitude: 80,
                                       speed: 8, timestamp: Date(timeIntervalSince1970: 3))]
        let latest = [point, RoutePoint(latitude: 40.003, longitude: -105, altitude: 70,
                                        speed: 8, timestamp: Date(timeIntervalSince1970: 4))]

        XCTAssertEqual(RideMapPresentation.livePaths(activeKind: .run, currentPath: current,
                                                     completedRunPaths: [older, latest],
                                                     showsPreviousRuns: false).map(\.role),
                       [.activeSegment])
        XCTAssertEqual(RideMapPresentation.livePaths(activeKind: .lift, currentPath: current,
                                                     completedRunPaths: [older, latest],
                                                     showsPreviousRuns: false).map(\.role),
                       [.latestCompletedRun])
        XCTAssertEqual(RideMapPresentation.livePaths(activeKind: .lift, currentPath: current,
                                                     completedRunPaths: [],
                                                     showsPreviousRuns: false).map(\.role),
                       [.activeSegment])
        XCTAssertEqual(RideMapPresentation.livePaths(activeKind: .run, currentPath: current,
                                                     completedRunPaths: [older, latest],
                                                     showsPreviousRuns: true).map(\.role),
                       [.previousRun, .previousRun, .activeSegment])
    }

    func testSummaryRunOpacityGetsDarkerChronologically() {
        let opacities = (0..<4).map {
            RideMapPresentation.summaryRunOpacity(index: $0, count: 4)
        }
        XCTAssertEqual(opacities, opacities.sorted())
        XCTAssertLessThan(opacities[0], opacities[3])
    }

    func testLiftThenRunTransitionsWithoutKeepingIdle() {
        let detector = ParkLapDetector()
        let base = Date(timeIntervalSince1970: 1_000)
        var events: [DetectorEvent] = []

        for index in 0..<4 {
            events += detector.process(sample(at: base, index: index, altitude: Double(index * 5), speed: 4, cycling: false))
        }

        XCTAssertEqual(detector.phase, .lift)
        XCTAssertTrue(events.contains { event in
            if case .started(kind: .lift, points: _) = event { return true }
            return false
        })

        for index in 0..<4 {
            events += detector.process(sample(at: base, index: index + 4, altitude: Double(15 - index * 5), speed: 7, cycling: true))
        }

        XCTAssertEqual(detector.phase, .run)
        XCTAssertTrue(events.contains { event in
            if case .finished(let draft) = event { return draft.kind == .lift }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .started(kind: .run, points: _) = event { return true }
            return false
        })

        for index in 0..<3 {
            events += detector.process(sample(at: base, index: index + 8, altitude: 0, speed: 0, cycling: false, stationary: true))
        }
        let finished = detector.finish()
        guard case .finished(let draft) = finished else {
            XCTFail("Expected the active run to finish")
            return
        }
        XCTAssertEqual(draft.kind, .run)
        XCTAssertTrue(draft.points.allSatisfy { !$0.isStationary })
    }

    func testPoorAccuracyIsIgnored() {
        let detector = ParkLapDetector()
        let point = sample(at: .now, index: 0, altitude: 100, speed: 8, cycling: true, accuracy: 100)
        XCTAssertTrue(detector.process(point).isEmpty)
        XCTAssertEqual(detector.phase, .idle)
    }

    @MainActor
    func testTrailMatchCacheTracksTrailRevisions() throws {
        let base = Date(timeIntervalSince1970: 1_250)
        let route = [
            RoutePoint(latitude: 40, longitude: -105, altitude: 100, speed: 8, timestamp: base),
            RoutePoint(latitude: 40.001, longitude: -105, altitude: 80, speed: 8, timestamp: base.addingTimeInterval(10))
        ]
        let trail = Trail(name: "Cached", difficulty: .blue, resort: "Test")
        let pass = TrailPass(routePoints: route)
        pass.trail = trail
        trail.passes.append(pass)
        trail.recalculateAverage()
        let segment = RideSegment(kind: .run, startedAt: base, endedAt: base.addingTimeInterval(10),
                                  routeData: try RouteCodec.encode(route))

        TrailRouteMatchCache.shared.invalidate()
        XCTAssertEqual(TrailRouteMatchCache.shared.match(for: segment, trails: [trail])?.trailID, trail.id)
        trail.updatedAt = trail.updatedAt.addingTimeInterval(1)
        XCTAssertEqual(TrailRouteMatchCache.shared.match(for: segment, trails: [trail])?.trailID, trail.id)
        TrailRouteMatchCache.shared.invalidate()
    }

    func testTrailMatcherMatchesAPartialRideAgainstTheTrail() {
        let base = Date(timeIntervalSince1970: 1_250)
        let fullRoute = (0...10).map { index in
            RoutePoint(latitude: 40 + Double(index) * 0.0001, longitude: -105,
                       altitude: 100 - Double(index), speed: 8,
                       timestamp: base.addingTimeInterval(Double(index)))
        }
        let trail = Trail(name: "Partial", difficulty: .blue, resort: "Test")
        let pass = TrailPass(routePoints: fullRoute)
        pass.trail = trail
        trail.passes.append(pass)

        let partialRoute = Array(fullRoute[3...8])
        let match = TrailRouteMatcher().bestMatch(for: partialRoute, trails: [trail])

        XCTAssertEqual(match?.trailID, trail.id)
    }

    func testTrailMatcherAcceptsATrailRecordedInTheOppositeDirection() {
        let base = Date(timeIntervalSince1970: 1_260)
        let route = (0...10).map { index in
            RoutePoint(latitude: 40 + Double(index) * 0.0001, longitude: -105,
                       altitude: 100 - Double(index), speed: 8,
                       timestamp: base.addingTimeInterval(Double(index)))
        }
        let trail = Trail(name: "Reverse pass", difficulty: .blue, resort: "Test")
        let pass = TrailPass(routePoints: Array(route.reversed()))
        pass.trail = trail
        trail.passes.append(pass)

        let match = TrailRouteMatcher().bestMatch(for: route, trails: [trail])
        let section = TrailRouteMatcher().matchingSections(for: route, trails: [trail]).first

        XCTAssertEqual(match?.trailID, trail.id)
        XCTAssertEqual(section?.trailProgress.lowerBound ?? .nan, 0, accuracy: 0.03)
        XCTAssertEqual(section?.trailProgress.upperBound ?? .nan, 1, accuracy: 0.03)
    }

    func testTrailMatcherDoesNotCountAPerpendicularPassByAsRidingTheTrail() {
        let base = Date(timeIntervalSince1970: 1_265)
        let passBy = (0...20).map { index in
            RoutePoint(latitude: 40.0005,
                       longitude: -105 + Double(index - 10) * 0.0001,
                       altitude: 100,
                       speed: 8,
                       timestamp: base.addingTimeInterval(Double(index)))
        }
        let trailPoints = (0...10).map { index in
            RoutePoint(latitude: 40 + Double(index) * 0.0001,
                       longitude: -105,
                       altitude: 100,
                       speed: 8,
                       timestamp: base.addingTimeInterval(Double(index)))
        }
        let trail = Trail(name: "Crossing trail", difficulty: .black, resort: "Test")
        let pass = TrailPass(routePoints: trailPoints)
        pass.trail = trail
        trail.passes.append(pass)

        let matcher = TrailRouteMatcher()

        XCTAssertNil(matcher.bestMatch(for: passBy, trails: [trail]))
        XCTAssertTrue(matcher.matchingSections(for: passBy, trails: [trail]).isEmpty)
    }

    func testTrailMatcherReturnsTrailProgressForPartialRide() {
        let base = Date(timeIntervalSince1970: 1_275)
        let fullRoute = (0...10).map { index in
            RoutePoint(latitude: 40 + Double(index) * 0.0001, longitude: -105,
                       altitude: 100 - Double(index), speed: 8,
                       timestamp: base.addingTimeInterval(Double(index)))
        }
        let trail = Trail(name: "Partial progress", difficulty: .blue, resort: "Test")
        let pass = TrailPass(routePoints: fullRoute)
        pass.trail = trail
        trail.passes.append(pass)

        let partialRoute = Array(fullRoute[2...7])
        let sections = TrailRouteMatcher().matchingSections(for: partialRoute, trails: [trail])

        XCTAssertEqual(sections.count, 1)
        guard let section = sections.first else {
            return
        }
        XCTAssertEqual(section.trailStartProgress, 0.2, accuracy: 0.03)
        XCTAssertEqual(section.trailEndProgress, 0.7, accuracy: 0.03)
        XCTAssertGreaterThan(section.trailProgress.upperBound, section.trailProgress.lowerBound)
    }

    func testTrailRouteSliceUsesOnlyTheRequestedCenterlineProgress() {
        let base = Date(timeIntervalSince1970: 1_290)
        let points = (0...4).map { index in
            RoutePoint(latitude: 40 + Double(index) * 0.001, longitude: -105,
                       altitude: 100 - Double(index), speed: 8,
                       timestamp: base.addingTimeInterval(Double(index)))
        }

        let slice = TrailRouteSlice.slice(points, progress: 0.25...0.75)

        XCTAssertGreaterThanOrEqual(slice.count, 3)
        XCTAssertEqual(slice.first?.latitude ?? .nan, 40.001, accuracy: 0.0001)
        XCTAssertEqual(slice.last?.latitude ?? .nan, 40.003, accuracy: 0.0001)
        XCTAssertEqual(slice.first?.longitude ?? .nan, -105, accuracy: 0.0001)
        XCTAssertEqual(slice.last?.longitude ?? .nan, -105, accuracy: 0.0001)
    }

    func testTrailRouteSliceClampsOutOfRangeProgress() {
        let base = Date(timeIntervalSince1970: 1_295)
        let points = [
            RoutePoint(latitude: 40, longitude: -105, altitude: 100, speed: 8, timestamp: base),
            RoutePoint(latitude: 40.001, longitude: -105, altitude: 90, speed: 8,
                       timestamp: base.addingTimeInterval(1)),
            RoutePoint(latitude: 40.002, longitude: -105, altitude: 80, speed: 8,
                       timestamp: base.addingTimeInterval(2))
        ]

        let slice = TrailRouteSlice.slice(points, progress: -0.5...1.5)

        XCTAssertEqual(slice, points)
    }

    func testTrailMatcherUsesARealPassWhenAverageIsOffset() {
        let base = Date(timeIntervalSince1970: 1_300)
        let route = (0...4).map { index in
            RoutePoint(latitude: 40 + Double(index) * 0.0001, longitude: -105,
                       altitude: 100 - Double(index), speed: 8,
                       timestamp: base.addingTimeInterval(Double(index)))
        }
        let offsetRoute = route.map { point in
            RoutePoint(latitude: point.latitude + 0.002, longitude: point.longitude,
                       altitude: point.altitude, speed: point.speed, timestamp: point.timestamp)
        }
        let trail = Trail(name: "Offset", difficulty: .black, resort: "Test")
        let pass = TrailPass(routePoints: route)
        let offsetPass = TrailPass(routePoints: offsetRoute, recordedAt: base.addingTimeInterval(10))
        pass.trail = trail
        offsetPass.trail = trail
        trail.passes.append(contentsOf: [pass, offsetPass])
        trail.recalculateAverage()

        let match = TrailRouteMatcher().bestMatch(for: route, trails: [trail])

        XCTAssertEqual(match?.trailID, trail.id)
    }

    func testTrailMatcherReturnsMultipleContiguousTrailSections() {
        let base = Date(timeIntervalSince1970: 1_350)
        let route = (0...10).map { index in
            if index <= 5 {
                return RoutePoint(latitude: 40 + Double(index) * 0.0004,
                                  longitude: -105,
                                  altitude: 100 - Double(index), speed: 8,
                                  timestamp: base.addingTimeInterval(Double(index)))
            }
            return RoutePoint(latitude: 40.002,
                              longitude: -105 + Double(index - 5) * 0.001,
                              altitude: 95 - Double(index), speed: 8,
                              timestamp: base.addingTimeInterval(Double(index)))
        }

        let firstTrail = Trail(name: "First", difficulty: .green, resort: "Test")
        let firstPass = TrailPass(routePoints: Array(route[0...5]))
        firstPass.trail = firstTrail
        firstTrail.passes.append(firstPass)

        let secondTrail = Trail(name: "Second", difficulty: .blue, resort: "Test")
        let secondPass = TrailPass(routePoints: Array(route[5...10]))
        secondPass.trail = secondTrail
        secondTrail.passes.append(secondPass)

        let sections = TrailRouteMatcher().matchingSections(for: route,
                                                              trails: [firstTrail, secondTrail])

        XCTAssertEqual(sections.map(\.trailID), [firstTrail.id, secondTrail.id])
        guard sections.count == 2 else { return }
        XCTAssertLessThanOrEqual(sections[0].endIndex, sections[1].startIndex + 1)
    }

    func testRouteCodecRoundTripsPoints() throws {
        let points = [
            RoutePoint(latitude: 40.0, longitude: -105.0, altitude: 2_000, speed: 5, timestamp: Date(timeIntervalSince1970: 1_000)),
            RoutePoint(latitude: 40.001, longitude: -105.002, altitude: 1_900, speed: 8, timestamp: Date(timeIntervalSince1970: 1_005))
        ]
        let data = try RouteCodec.encode(points)
        let decoded = try RouteCodec.decode(data)
        XCTAssertEqual(decoded, points)
    }

    func testAltitudeFusionKeepsGPSAndBarometerOnOneReference() {
        var fusion = AltitudeFusion()
        fusion.reset(barometerAvailable: true)
        XCTAssertEqual(fusion.update(gpsAltitude: 1_000, relativeAltitude: nil)!, 1_000, accuracy: 0.001)
        XCTAssertEqual(fusion.update(gpsAltitude: 1_000, relativeAltitude: 0)!, 1_000, accuracy: 0.001)
        XCTAssertEqual(fusion.update(gpsAltitude: 1_030, relativeAltitude: 2)!, 1_002, accuracy: 0.001)
    }

    func testSegmentDurationCapsUnobservedGPSGap() throws {
        let points = [
            RoutePoint(latitude: 40, longitude: -105, altitude: 100, speed: 7,
                       timestamp: Date(timeIntervalSince1970: 1_000)),
            RoutePoint(latitude: 40.001, longitude: -105, altitude: 90, speed: 7,
                       timestamp: Date(timeIntervalSince1970: 1_005)),
            RoutePoint(latitude: 40.002, longitude: -105, altitude: 80, speed: 7,
                       timestamp: Date(timeIntervalSince1970: 1_305)),
            RoutePoint(latitude: 40.003, longitude: -105, altitude: 70, speed: 7,
                       timestamp: Date(timeIntervalSince1970: 1_310))
        ]
        let segment = RideSegment(kind: .run, startedAt: points[0].timestamp,
                                  endedAt: points[3].timestamp,
                                  routeData: try RouteCodec.encode(points))
        XCTAssertEqual(segment.duration, 20, accuracy: 0.001)
    }

    @MainActor
    func testAuthoredTrailPersistsPassesAndDistanceAverage() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Trail.self, TrailPass.self, configurations: configuration)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_000)
        let firstPass = [
            RoutePoint(latitude: 40, longitude: -105, altitude: 100, speed: 7,
                       timestamp: base),
            RoutePoint(latitude: 40.001, longitude: -105, altitude: 80, speed: 7,
                       timestamp: base.addingTimeInterval(10)),
            RoutePoint(latitude: 40.002, longitude: -105, altitude: 60, speed: 7,
                       timestamp: base.addingTimeInterval(20))
        ]
        let secondPass = [
            RoutePoint(latitude: 40, longitude: -105.0001, altitude: 100, speed: 7,
                       timestamp: base.addingTimeInterval(30)),
            RoutePoint(latitude: 40.0008, longitude: -105, altitude: 80, speed: 7,
                       timestamp: base.addingTimeInterval(38)),
            RoutePoint(latitude: 40.0021, longitude: -105.0001, altitude: 60, speed: 7,
                       timestamp: base.addingTimeInterval(48))
        ]
        let trail = Trail(name: "Test Trail", difficulty: .black, resort: "Mountain Creek Bike Park")
        let passOne = TrailPass(routePoints: firstPass, recordedAt: base)
        let passTwo = TrailPass(routePoints: secondPass, recordedAt: base.addingTimeInterval(30))
        passOne.trail = trail
        passTwo.trail = trail
        trail.passes.append(contentsOf: [passOne, passTwo])
        trail.recalculateAverage()
        context.insert(trail)
        context.insert(passOne)
        context.insert(passTwo)
        try context.save()

        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<Trail>()).first)
        XCTAssertEqual(saved.name, "Test Trail")
        XCTAssertEqual(saved.difficultyRawValue, TrailDifficulty.black.rawValue)
        XCTAssertEqual(saved.resort, "Mountain Creek Bike Park")
        XCTAssertEqual(saved.passCount, 2)
        XCTAssertGreaterThan(saved.points.count, 2)
        XCTAssertGreaterThan(saved.passes.reduce(0) { $0 + $1.distanceMeters }, 0)
    }

    @MainActor
    func testLearnedLiftProfilePersists() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LearnedLift.self, configurations: configuration)
        let context = ModelContext(container)
        let profile = LearnedLiftProfile(id: UUID(),
                                         bottom: Coordinate(latitude: 40, longitude: -105),
                                         top: Coordinate(latitude: 40.01, longitude: -105.01),
                                         bottomRadius: 60, topRadius: 70,
                                         observationCount: 3, confidence: 1)
        context.insert(LearnedLift(profile: profile))
        try context.save()
        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<LearnedLift>()).first)
        XCTAssertEqual(saved.profile, profile)
    }

    func testLiftLearningMergesRepeatedLiftSegments() throws {
        let engine = LiftLearningEngine()
        let base = Date(timeIntervalSince1970: 1_100)
        var profiles: [LearnedLiftProfile] = []
        for index in 0..<3 {
            let points = [
                RoutePoint(latitude: 40 + Double(index) * 0.00001, longitude: -105,
                           altitude: 100, speed: 4, timestamp: base),
                RoutePoint(latitude: 40.01 + Double(index) * 0.00001, longitude: -105,
                           altitude: 300, speed: 4, timestamp: base.addingTimeInterval(60))
            ]
            let segment = RideSegment(kind: .lift, startedAt: points[0].timestamp,
                                      endedAt: points[1].timestamp,
                                      routeData: try RouteCodec.encode(points))
            profiles = engine.merge(observation: try XCTUnwrap(engine.observations(from: [segment]).first),
                                    into: profiles)
        }

        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.observationCount, 3)
        XCTAssertEqual(profile.confidence, 1, accuracy: 0.001)
    }

    func testLiftLearningKeepsDistinctLiftsSeparate() {
        let engine = LiftLearningEngine()
        let first = engine.merge(observation: (
            bottom: Coordinate(latitude: 40, longitude: -105),
            top: Coordinate(latitude: 40.01, longitude: -105)
        ), into: [])
        let second = engine.merge(observation: (
            bottom: Coordinate(latitude: 40.01, longitude: -105.01),
            top: Coordinate(latitude: 40.02, longitude: -105.01)
        ), into: first)

        XCTAssertEqual(second.count, 2)
        XCTAssertTrue(second.allSatisfy { $0.observationCount == 1 })
    }

    func testActivityAttributesRoundTrip() throws {
        let attributes = BermsActivityAttributes(rideID: UUID())
        let state = BermsActivityAttributes.ContentState(
            phase: "run", isPaused: false, runCount: 2, startedAt: .now,
            elapsedSeconds: 120, distanceMeters: 2_000, descentMeters: 300,
            speedMetersPerSecond: 10
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BermsActivityAttributes.ContentState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertFalse(attributes.rideID.isEmpty)
    }

    func testWatchRideStateAndCommandsRoundTrip() throws {
        let state = WatchRideState(
            status: .recording,
            rideID: "ride-1",
            phase: "run",
            startedAt: Date(timeIntervalSince1970: 100),
            elapsedSeconds: 42,
            distanceMeters: 1_250,
            descentMeters: 210,
            speedMetersPerSecond: 12,
            updatedAt: Date(timeIntervalSince1970: 142)
        )

        XCTAssertEqual(try WatchRideCodec.decode(WatchRideState.self,
                                                 from: WatchRideCodec.encode(state)), state)
        XCTAssertEqual(try WatchRideCodec.decode(WatchRideCommand.self,
                                                 from: WatchRideCodec.encode(WatchRideCommand.pause)), .pause)
        XCTAssertTrue(state.isStale(at: Date(timeIntervalSince1970: 148)))
        XCTAssertFalse(state.isStale(at: Date(timeIntervalSince1970: 146)))
    }

    @MainActor
    func testManualLaunchPromptsForUnfinishedSession() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideDay.self, RideSegment.self,
                                           Trail.self, TrailPass.self, LearnedLift.self,
                                           configurations: configuration)
        let context = ModelContext(container)
        let day = RideDay(startedAt: Date(timeIntervalSince1970: 10_000))
        context.insert(day)
        try context.save()

        let previousVersion = UserDefaults.standard.string(forKey: "berms.diagnosticSummaryVersion")
        let previousRecordingState = UserDefaults.standard.bool(forKey: "berms.recordingActive")
        defer {
            if let previousVersion {
                UserDefaults.standard.set(previousVersion, forKey: "berms.diagnosticSummaryVersion")
            } else {
                UserDefaults.standard.removeObject(forKey: "berms.diagnosticSummaryVersion")
            }
            UserDefaults.standard.set(previousRecordingState, forKey: "berms.recordingActive")
        }
        UserDefaults.standard.set("6", forKey: "berms.diagnosticSummaryVersion")
        UserDefaults.standard.set(true, forKey: "berms.recordingActive")

        let recorder = RideRecorder(context: context)
        recorder.resumeIfNeeded()
        XCTAssertTrue(recorder.needsRecoveryPrompt)
        XCTAssertFalse(recorder.isRecording)

        XCTAssertEqual(try context.fetch(FetchDescriptor<RideDay>()).count, 1)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "berms.recordingActive"))

        recorder.discardPendingSession()
        XCTAssertFalse(recorder.needsRecoveryPrompt)
        XCTAssertTrue(try context.fetch(FetchDescriptor<RideDay>()).isEmpty)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "berms.recordingActive"))
    }

    func testAltitudeFusionRecordsGPSWhenBarometerNeverDelivers() {
        var fusion = AltitudeFusion()
        fusion.reset(barometerAvailable: true)
        for altitude in stride(from: 150.0, through: 400.0, by: 5) {
            XCTAssertEqual(fusion.update(gpsAltitude: altitude, relativeAltitude: nil), altitude)
        }
        fusion.reset(barometerAvailable: false)
        XCTAssertEqual(fusion.update(gpsAltitude: 150, relativeAltitude: nil), 150)
    }

    func testAltitudeFusionFallsBackAndReanchorsAfterBarometerGap() {
        var fusion = AltitudeFusion()
        fusion.reset(barometerAvailable: true)
        XCTAssertEqual(fusion.update(gpsAltitude: 1_000, relativeAltitude: 0), 1_000)
        XCTAssertEqual(fusion.update(gpsAltitude: 1_030, relativeAltitude: 2), 1_002)
        XCTAssertEqual(fusion.update(gpsAltitude: 1_032, relativeAltitude: nil), 1_004)
        XCTAssertEqual(fusion.update(gpsAltitude: 1_034, relativeAltitude: 200), 1_006)
        XCTAssertEqual(fusion.update(gpsAltitude: 1_040, relativeAltitude: 201), 1_007)
        fusion.reset(barometerAvailable: true)
        XCTAssertEqual(fusion.update(gpsAltitude: 150, relativeAltitude: nil), 150)
        XCTAssertEqual(fusion.update(gpsAltitude: 150, relativeAltitude: 0), 150)
    }

    func testNormalizerSmoothsAndRejectsImpossibleSamples() {
        var normalizer = TrackSampleNormalizer()
        let first = sample(at: Date(timeIntervalSince1970: 1_000), index: 0, altitude: 100, speed: 2, cycling: true)
        let second = sample(at: Date(timeIntervalSince1970: 1_000), index: 1, altitude: 110, speed: 10, cycling: true)
        let impossible = TrackSample(coordinate: Coordinate(latitude: 50, longitude: -110), altitude: 120,
                                     speed: 4, timestamp: Date(timeIntervalSince1970: 1_010), isCycling: true)

        XCTAssertNotNil(normalizer.normalize(first))
        let normalized = normalizer.normalize(second)
        XCTAssertEqual(normalized?.speed ?? 0, 4.8, accuracy: 0.001)
        XCTAssertEqual(normalized?.altitude ?? 0, 103, accuracy: 0.001)
        XCTAssertNil(normalizer.normalize(impossible))
    }

    func testNormalizerRejectsLowSpeedGPSDrift() {
        var normalizer = TrackSampleNormalizer()
        let base = Date(timeIntervalSince1970: 1_200)
        let first = TrackSample(coordinate: Coordinate(latitude: 40, longitude: -105), altitude: 100,
                                speed: 0.2, timestamp: base)
        let drift = TrackSample(coordinate: Coordinate(latitude: 40.0015, longitude: -105), altitude: 100,
                                speed: 0.1, timestamp: base.addingTimeInterval(1))
        let recovered = TrackSample(coordinate: Coordinate(latitude: 40.00001, longitude: -105), altitude: 100,
                                    speed: 0.3, timestamp: base.addingTimeInterval(2))

        XCTAssertNotNil(normalizer.normalize(first))
        XCTAssertNil(normalizer.normalize(drift))
        XCTAssertNotNil(normalizer.normalize(recovered))
    }

    func testNormalizerHoldsStablePointThroughStationaryBreak() {
        var normalizer = TrackSampleNormalizer()
        let base = Date(timeIntervalSince1970: 1_250)
        let moving = TrackSample(coordinate: Coordinate(latitude: 40, longitude: -105), altitude: 100,
                                 speed: 8, timestamp: base, isCycling: true)
        let firstStopped = TrackSample(coordinate: Coordinate(latitude: 40.0002, longitude: -105.0001), altitude: 99,
                                       speed: 0, timestamp: base.addingTimeInterval(5), isStationary: true)
        let wanderingStopped = TrackSample(coordinate: Coordinate(latitude: 40.0007, longitude: -104.9995), altitude: 95,
                                            speed: 0, timestamp: base.addingTimeInterval(10), isStationary: true)

        let normalizedMoving = normalizer.normalize(moving)
        let normalizedFirstStopped = normalizer.normalize(firstStopped)
        let normalizedWanderingStopped = normalizer.normalize(wanderingStopped)

        XCTAssertEqual(normalizedMoving?.speed ?? -1, 8, accuracy: 0.001)
        XCTAssertEqual(normalizedFirstStopped?.speed ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(normalizedWanderingStopped?.speed ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(normalizedWanderingStopped?.coordinate, normalizedFirstStopped?.coordinate)
        XCTAssertEqual(normalizedWanderingStopped?.altitude, normalizedFirstStopped?.altitude)
    }

    func testRouteCleanerCollapsesStationaryGPSStar() {
        let base = Date(timeIntervalSince1970: 1_300)
        let points = [
            RoutePoint(latitude: 40, longitude: -105, altitude: 100, speed: 8, timestamp: base),
            RoutePoint(latitude: 40.0002, longitude: -105.0001, altitude: 99, speed: 0.2, timestamp: base.addingTimeInterval(5)),
            RoutePoint(latitude: 40.0001, longitude: -104.9998, altitude: 99, speed: 0.1, timestamp: base.addingTimeInterval(10)),
            RoutePoint(latitude: 39.9999, longitude: -105.0001, altitude: 99, speed: 0.1, timestamp: base.addingTimeInterval(15)),
            RoutePoint(latitude: 40.0005, longitude: -105, altitude: 95, speed: 8, timestamp: base.addingTimeInterval(20))
        ]

        let cleaned = RouteCleaner().clean(points)

        XCTAssertLessThan(cleaned.count, points.count)
        XCTAssertEqual(cleaned[1].speed, 0, accuracy: 0.001)
    }

    func testRouteCleanerFiltersInaccurateTrackSamples() {
        let base = Date(timeIntervalSince1970: 1_350)
        let samples = [
            TrackSample(coordinate: Coordinate(latitude: 40, longitude: -105), altitude: 100,
                        speed: 7, horizontalAccuracy: 10, timestamp: base),
            TrackSample(coordinate: Coordinate(latitude: 40.0001, longitude: -105), altitude: 99,
                        speed: 7, horizontalAccuracy: 120, timestamp: base.addingTimeInterval(5)),
            TrackSample(coordinate: Coordinate(latitude: 40.0002, longitude: -105), altitude: 98,
                        speed: 7, horizontalAccuracy: 10, timestamp: base.addingTimeInterval(10))
        ]

        let cleaned = RouteCleaner().clean(samples)

        XCTAssertEqual(cleaned.count, 2)
        XCTAssertTrue(cleaned.allSatisfy { $0.horizontalAccuracy <= 80 })
    }

    func testAutomotiveAscentIsNotCalledALift() {
        let detector = ParkLapDetector()
        let base = Date(timeIntervalSince1970: 1_000)
        for index in 0..<5 {
            let point = sample(at: base, index: index, altitude: Double(index * 8), speed: 12,
                               cycling: false, automotive: true)
            XCTAssertTrue(detector.process(point).isEmpty)
        }
        XCTAssertEqual(detector.phase, .idle)
    }

    func testDescendingMovementCanStartRunWithoutCyclingActivity() {
        let detector = ParkLapDetector()
        let base = Date(timeIntervalSince1970: 1_000)
        for index in 0..<5 {
            _ = detector.process(sample(at: base, index: index, altitude: 100 - Double(index * 4),
                                         speed: 2, cycling: false))
        }
        XCTAssertEqual(detector.phase, .run)
    }

    func testDetectorResetDoesNotBridgePauseBoundary() {
        let detector = ParkLapDetector()
        let base = Date(timeIntervalSince1970: 1_500)
        for index in 0..<4 {
            _ = detector.process(sample(at: base, index: index, altitude: Double(index * 5), speed: 4, cycling: false))
        }
        XCTAssertEqual(detector.phase, .lift)

        detector.reset()
        XCTAssertEqual(detector.phase, .idle)
        XCTAssertNil(detector.lastSample)

        var events: [DetectorEvent] = []
        for index in 0..<5 {
            events += detector.process(sample(at: base, index: index + 10,
                                              altitude: Double(100 - index * 5), speed: 7, cycling: true))
        }
        XCTAssertEqual(detector.phase, .run)
        XCTAssertTrue(events.contains { if case .started(kind: .run, points: _) = $0 { return true }; return false })
    }

    func testDetectorTransitionsAtOneSecondGPSCadence() {
        let detector = ParkLapDetector()
        let base = Date(timeIntervalSince1970: 1_800)
        var events: [DetectorEvent] = []

        for index in 0...15 {
            events += detector.process(sample(at: base, index: index, altitude: Double(index), speed: 4,
                                              cycling: false, interval: 1))
        }
        XCTAssertEqual(detector.phase, .lift)

        for index in 16...34 {
            events += detector.process(sample(at: base, index: index,
                                              altitude: 16 - Double(index - 16), speed: 8,
                                              cycling: true, interval: 1))
        }
        XCTAssertEqual(detector.phase, .run)
        XCTAssertTrue(events.contains { event in
            if case .finished(let draft) = event { return draft.kind == .lift }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .started(kind: .run, points: _) = event { return true }
            return false
        })
    }

    func testRideDayPauseDurationExcludesOneAndMultiplePauses() {
        let start = Date(timeIntervalSince1970: 2_000)
        let day = RideDay(startedAt: start)
        day.beginPause(at: start.addingTimeInterval(30))
        XCTAssertEqual(day.duration(at: start.addingTimeInterval(90)), 30, accuracy: 0.001)

        XCTAssertEqual(day.endPause(at: start.addingTimeInterval(60)), 30, accuracy: 0.001)
        XCTAssertEqual(day.duration(at: start.addingTimeInterval(90)), 60, accuracy: 0.001)

        day.beginPause(at: start.addingTimeInterval(100))
        XCTAssertEqual(day.duration(at: start.addingTimeInterval(130)), 70, accuracy: 0.001)
        XCTAssertEqual(day.endPause(at: start.addingTimeInterval(120)), 20, accuracy: 0.001)
        XCTAssertEqual(day.duration(at: start.addingTimeInterval(150)), 100, accuracy: 0.001)
    }

    @MainActor
    func testRawLogWriterPersistsJSONLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("berms-test-\(UUID().uuidString).jsonl")
        let writer = RawLogWriter(url: url)
        writer.append(RawDiagnosticRecord(kind: "gps_raw", latitude: 40, longitude: -105))
        writer.append(RawDiagnosticRecord(kind: "detector_input", accepted: true, phaseAfter: "run"))
        writer.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(RawDiagnosticRecord.self, from: Data(lines[1].utf8))
        XCTAssertEqual(record.kind, "detector_input")
        XCTAssertEqual(record.phaseAfter, "run")
        try? FileManager.default.removeItem(at: url)
    }

    func testJumpDetectorConfirmsAirborneIntervalAndHonorsCooldown() {
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        configuration.cooldown = 1
        let detector = JumpDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 2_000)
        var detected: [JumpEvent] = []

        for index in 0..<10 {
            detected += detector.process(motion(at: Double(index) * 0.04, forceG: 1),
                                         context: runContext(at: Double(index) * 0.04, base: base))
                .compactMap { event in
                    if case .detected(let jump) = event { return jump }
                    return nil
                }
        }
        for index in 10..<15 {
            detected += detector.process(motion(at: Double(index) * 0.04, forceG: 0.2),
                                         context: runContext(at: Double(index) * 0.04, base: base))
                .compactMap { event in
                    if case .detected(let jump) = event { return jump }
                    return nil
                }
        }
        detected += detector.process(motion(at: 0.60, forceG: 1.8),
                                     context: runContext(at: 0.60, base: base))
            .compactMap { event in
                if case .detected(let jump) = event { return jump }
                return nil
            }
        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected[0].airtime, 0.20, accuracy: 0.001)

        for index in 16..<25 {
            let events = detector.process(motion(at: Double(index) * 0.04, forceG: 0.2),
                                          context: runContext(at: Double(index) * 0.04, base: base))
            XCTAssertFalse(events.contains { if case .detected = $0 { return true }; return false })
        }
    }

    func testJumpDetectorRejectsShortUnloadAndHighRotation() {
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        let detector = JumpDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 3_000)
        _ = detector.process(motion(at: 0, forceG: 1), context: runContext(at: 0, base: base))
        _ = detector.process(motion(at: 0.04, forceG: 0.2), context: runContext(at: 0.04, base: base))
        let shortEvents = detector.process(motion(at: 0.08, forceG: 1.8), context: runContext(at: 0.08, base: base))
        XCTAssertTrue(shortEvents.contains { if case .diagnostic(kind: "jump_candidate_rejected", _, _, let detail) = $0 { return detail == "airtime_too_short" }; return false })

        _ = detector.process(motion(at: 2, forceG: 1), context: runContext(at: 2, base: base))
        _ = detector.process(motion(at: 2.04, forceG: 1), context: runContext(at: 2.04, base: base))
        _ = detector.process(motion(at: 2.08, forceG: 0.2, rotation: 9), context: runContext(at: 2.08, base: base))
        _ = detector.process(motion(at: 2.20, forceG: 0.2, rotation: 9), context: runContext(at: 2.20, base: base))
        let rotationEvents = detector.process(motion(at: 2.24, forceG: 1.8, rotation: 9), context: runContext(at: 2.24, base: base))
        XCTAssertTrue(rotationEvents.contains { if case .diagnostic(kind: "jump_candidate_rejected", _, _, let detail) = $0 { return detail == "airborne_rotation_too_high" }; return false })
    }

    func testJumpDetectorRequiresRunAndRejectsMotionGap() {
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        let detector = JumpDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 4_000)
        let notRun = JumpTrackContext(timestamp: base, monotonicSeconds: 0, speed: 8, altitude: 100,
                                      phase: .lift, isStationary: false, isAutomotive: false)
        XCTAssertTrue(detector.process(motion(at: 0, forceG: 0.2), context: notRun).isEmpty)

        _ = detector.process(motion(at: 1, forceG: 1), context: runContext(at: 1, base: base))
        _ = detector.process(motion(at: 1.04, forceG: 1), context: runContext(at: 1.04, base: base))
        _ = detector.process(motion(at: 1.08, forceG: 1), context: runContext(at: 1.08, base: base))
        _ = detector.process(motion(at: 1.12, forceG: 0.2), context: runContext(at: 1.12, base: base))
        let events = detector.process(motion(at: 1.48, forceG: 0.2), context: runContext(at: 1.48, base: base))
        XCTAssertTrue(events.contains { if case .diagnostic(kind: "jump_candidate_rejected", _, _, let detail) = $0 { return detail.hasPrefix("motion_gap_") }; return false })
    }

    func testJumpDetectorRejectsImpactWithoutAirborneAndStaleOrSlowContext() {
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        let detector = JumpDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 4_500)

        _ = detector.process(motion(at: 0, forceG: 1), context: runContext(at: 0, base: base))
        let impact = detector.process(motion(at: 0.04, forceG: 1.8), context: runContext(at: 0.04, base: base))
        XCTAssertFalse(impact.contains { if case .detected = $0 { return true }; return false })

        _ = detector.process(motion(at: 0.08, forceG: 0.2), context: runContext(at: 0.08, base: base, speed: 1))
        let slowLanding = detector.process(motion(at: 0.24, forceG: 1.8), context: runContext(at: 0.24, base: base, speed: 1))
        XCTAssertFalse(slowLanding.contains { if case .detected = $0 { return true }; return false })

        _ = detector.process(motion(at: 1, forceG: 1), context: runContext(at: 1, base: base))
        _ = detector.process(motion(at: 1.04, forceG: 0.2), context: runContext(at: 1.04, base: base))
        let stale = detector.process(motion(at: 4, forceG: 1.8), context: runContext(at: 1, base: base))
        XCTAssertFalse(stale.contains { if case .detected = $0 { return true }; return false })
    }

    func testRawDiagnosticRecordDecodesLegacyLine() throws {
        let legacy = "{\"kind\":\"detector_input\",\"timestamp\":\"1970-01-01T00:16:40Z\",\"monotonicSeconds\":1,\"accepted\":true,\"phaseAfter\":\"run\"}"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(RawDiagnosticRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(record.kind, "detector_input")
        XCTAssertNil(record.fusedAltitude)
        XCTAssertNil(record.jumpAirtime)
    }

    func testJumpLogReplayUsesRecordedMotionAndTrackContext() throws {
        let base = Date(timeIntervalSince1970: 5_000)
        var records = [RawDiagnosticRecord(kind: "detector_input", timestamp: base,
                                            monotonicSeconds: 0, fusedAltitude: 100,
                                            trackMonotonicSeconds: 0, speed: 8,
                                            stationary: false, automotive: false,
                                            runEligible: true, accepted: true,
                                            phaseAfter: "run")]
        for index in 0..<10 {
            records.append(rawMotionRecord(at: Double(index) * 0.04, base: base, forceG: 1))
        }
        for index in 10..<15 {
            records.append(rawMotionRecord(at: Double(index) * 0.04, base: base, forceG: 0.2))
        }
        records.append(rawMotionRecord(at: 0.60, base: base, forceG: 1.8))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = records.map { try! encoder.encode($0) }.reduce(into: Data()) { result, line in
            result.append(line)
            result.append(0x0A)
        }
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        let result = try JumpLogReplayer().replay(data: data, configuration: configuration)
        XCTAssertEqual(result.jumps.count, 1)
        XCTAssertEqual(result.jumps[0].airtime, 0.20, accuracy: 0.001)
    }

    func testJumpLogReplayResetsAcrossPauseBoundary() throws {
        let base = Date(timeIntervalSince1970: 5_500)
        var records = [RawDiagnosticRecord(kind: "detector_input", timestamp: base,
                                            monotonicSeconds: 0, fusedAltitude: 100,
                                            trackMonotonicSeconds: 0, speed: 8,
                                            stationary: false, automotive: false,
                                            runEligible: true, accepted: true,
                                            phaseAfter: "run")]
        for index in 0..<10 {
            records.append(rawMotionRecord(at: Double(index) * 0.04, base: base, forceG: 1))
        }
        for index in 10..<15 {
            records.append(rawMotionRecord(at: Double(index) * 0.04, base: base, forceG: 0.2))
        }
        records.append(RawDiagnosticRecord(kind: "session_paused", timestamp: base.addingTimeInterval(0.58),
                                            monotonicSeconds: 0.58))
        records.append(rawMotionRecord(at: 0.60, base: base, forceG: 1.8))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = records.map { try! encoder.encode($0) }.reduce(into: Data()) { result, line in
            result.append(line)
            result.append(0x0A)
        }
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        let result = try JumpLogReplayer().replay(data: data, configuration: configuration)
        XCTAssertTrue(result.jumps.isEmpty)
    }

    func testCheckpointDecodesNewAndLegacyFormats() throws {
        let point = sample(at: Date(timeIntervalSince1970: 6_000), index: 0, altitude: 100, speed: 8, cycling: true)
        let jump = JumpEvent(takeoffTimestamp: point.timestamp, landingTimestamp: point.timestamp.addingTimeInterval(0.2),
                             takeoffMonotonicSeconds: 1, landingMonotonicSeconds: 1.2)
        let checkpoint = try JSONDecoder().decode(RecorderCheckpoint.self,
                                                   from: JSONEncoder().encode(RecorderCheckpoint(points: [point], jumps: [jump])))
        XCTAssertEqual(checkpoint.jumps.count, 1)
        let legacy = try JSONDecoder().decode([TrackSample].self, from: JSONEncoder().encode([point]))
        XCTAssertEqual(legacy, [point])
    }

    @MainActor
    func testSavedRoutesAndTrailPassesRepairDuringMigration() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideDay.self, RideSegment.self,
                                           Trail.self, TrailPass.self, LearnedLift.self,
                                           configurations: configuration)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 7_500)
        let route = [
            RoutePoint(latitude: 40, longitude: -105, altitude: 100, speed: 8, timestamp: base),
            RoutePoint(latitude: 40.0002, longitude: -105.0001, altitude: 99, speed: 0.2, timestamp: base.addingTimeInterval(5)),
            RoutePoint(latitude: 40.0001, longitude: -104.9998, altitude: 99, speed: 0.1, timestamp: base.addingTimeInterval(10)),
            RoutePoint(latitude: 39.9999, longitude: -105.0001, altitude: 99, speed: 0.1, timestamp: base.addingTimeInterval(15)),
            RoutePoint(latitude: 40.0005, longitude: -105, altitude: 95, speed: 8, timestamp: base.addingTimeInterval(20))
        ]
        let day = RideDay(startedAt: base)
        day.endedAt = base.addingTimeInterval(30)
        let segment = RideSegment(kind: .run, startedAt: base, endedAt: base.addingTimeInterval(20),
                                  routeData: try RouteCodec.encode(route))
        segment.distanceMeters = -1
        segment.day = day
        day.segments.append(segment)
        let trail = Trail(name: "Repairable", difficulty: .blue, resort: "Test")
        let pass = TrailPass(routePoints: route)
        pass.trail = trail
        trail.passes.append(pass)
        context.insert(day)
        context.insert(segment)
        context.insert(trail)
        context.insert(pass)
        try context.save()

        let previousVersion = UserDefaults.standard.string(forKey: "berms.diagnosticSummaryVersion")
        let previousRecordingState = UserDefaults.standard.bool(forKey: "berms.recordingActive")
        defer {
            if let previousVersion {
                UserDefaults.standard.set(previousVersion, forKey: "berms.diagnosticSummaryVersion")
            } else {
                UserDefaults.standard.removeObject(forKey: "berms.diagnosticSummaryVersion")
            }
            UserDefaults.standard.set(previousRecordingState, forKey: "berms.recordingActive")
        }
        UserDefaults.standard.set("5", forKey: "berms.diagnosticSummaryVersion")
        UserDefaults.standard.set(false, forKey: "berms.recordingActive")

        RideRecorder(context: context).resumeIfNeeded()

        let savedSegment = try XCTUnwrap(context.fetch(FetchDescriptor<RideSegment>()).first)
        XCTAssertLessThan(savedSegment.points.count, route.count)
        XCTAssertGreaterThan(savedSegment.distanceMeters, 0)
        let savedPass = try XCTUnwrap(context.fetch(FetchDescriptor<TrailPass>()).first)
        XCTAssertLessThan(savedPass.points.count, route.count)
        XCTAssertGreaterThan(savedPass.distanceMeters, 0)
    }

    @MainActor
    func testSwiftDataPersistsDayAndCascadeSegment() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideDay.self, RideSegment.self, configurations: configuration)
        let context = ModelContext(container)
        let day = RideDay(startedAt: Date(timeIntervalSince1970: 1_000))
        let jump = JumpEvent(takeoffTimestamp: day.startedAt, landingTimestamp: day.startedAt.addingTimeInterval(0.2),
                             takeoffMonotonicSeconds: 1, landingMonotonicSeconds: 1.2)
        let segment = RideSegment(kind: .run, startedAt: day.startedAt, endedAt: day.startedAt.addingTimeInterval(20),
                                  routeData: Data([1, 2, 3]), jumps: [jump])
        day.segments.append(segment)
        segment.day = day
        context.insert(day)
        context.insert(segment)
        try context.save()

        let savedDays = try context.fetch(FetchDescriptor<RideDay>())
        XCTAssertEqual(savedDays.count, 1)
        XCTAssertEqual(savedDays.first?.segments.count, 1)
        XCTAssertEqual(savedDays.first?.jumpCount, 1)
        XCTAssertEqual(savedDays.first?.longestJumpAirtime ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(savedDays.first?.segments.first?.jumps.count, 1)
        savedDays[0].beginPause(at: day.startedAt.addingTimeInterval(30))
        try context.save()
        let pausedDay = try context.fetch(FetchDescriptor<RideDay>()).first
        XCTAssertTrue(pausedDay?.isPaused == true)
        XCTAssertEqual(pausedDay?.duration(at: day.startedAt.addingTimeInterval(90)) ?? 0, 30, accuracy: 0.001)
        context.delete(savedDays[0])
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<RideSegment>()).isEmpty)
    }

    @MainActor
    func testRideDayNameFallsBackAndPersists() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideDay.self, configurations: configuration)
        let context = container.mainContext
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let day = RideDay(startedAt: startedAt)
        let fallback = startedAt.formatted(date: .abbreviated, time: .shortened)

        XCTAssertFalse(day.hasCustomName)
        XCTAssertEqual(day.displayName, fallback)

        day.setName("  Powder laps  ")
        XCTAssertEqual(day.name, "Powder laps")
        XCTAssertTrue(day.hasCustomName)
        XCTAssertEqual(day.displayName, "Powder laps")

        context.insert(day)
        try context.save()

        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<RideDay>()).first)
        XCTAssertEqual(saved.name, "Powder laps")
        XCTAssertEqual(saved.displayName, "Powder laps")

        saved.setName("  \\n  ")
        try context.save()

        let cleared = try XCTUnwrap(context.fetch(FetchDescriptor<RideDay>()).first)
        XCTAssertNil(cleared.name)
        XCTAssertFalse(cleared.hasCustomName)
        XCTAssertEqual(cleared.displayName, fallback)
    }

    @MainActor
    func testRecorderLunchResumeAndFinishPersistSummary() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideDay.self, RideSegment.self, configurations: configuration)
        let context = ModelContext(container)
        let recorder = RideRecorder(context: context)
        let wasRecording = UserDefaults.standard.bool(forKey: "berms.recordingActive")
        defer { UserDefaults.standard.set(wasRecording, forKey: "berms.recordingActive") }
        XCTAssertTrue(recorder.start())
        let day = try XCTUnwrap(recorder.activeDay)
        let run = RideSegment(kind: .run, startedAt: day.startedAt,
                              endedAt: day.startedAt.addingTimeInterval(180), routeData: Data())
        run.distanceMeters = 1_200
        run.verticalMeters = 250
        run.maximumSpeedMetersPerSecond = 12
        run.day = day
        day.segments.append(run)
        context.insert(run)
        let lift = RideSegment(kind: .lift, startedAt: day.startedAt,
                               endedAt: day.startedAt.addingTimeInterval(300), routeData: Data())
        lift.maximumSpeedMetersPerSecond = 15
        lift.day = day
        day.segments.append(lift)
        context.insert(lift)

        XCTAssertTrue(recorder.pause())
        XCTAssertTrue(recorder.isPaused)
        XCTAssertFalse(recorder.locationService.isRunning)
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertTrue(recorder.activePoints.isEmpty)
        XCTAssertTrue(recorder.resume())
        XCTAssertFalse(recorder.isPaused)
        XCTAssertNil(recorder.lastSample)
        XCTAssertTrue(recorder.pause())
        let finished = try XCTUnwrap(recorder.stop())
        XCTAssertEqual(finished.id, day.id)
        XCTAssertTrue(finished.isFinished)
        XCTAssertFalse(finished.isPaused)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(finished.distanceMeters, 1_200)
        XCTAssertEqual(finished.descentMeters, 250)
        XCTAssertEqual(finished.activeSeconds, 180)
        XCTAssertEqual(finished.maximumSpeedMetersPerSecond, 12)
        XCTAssertNil(finished.checkpointData)
        XCTAssertNil(recorder.errorMessage)
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<RideDay>()).first)
        XCTAssertTrue(saved.isFinished)
        XCTAssertEqual(saved.segments.count, 2)
        XCTAssertEqual(saved.distanceMeters, 1_200)
    }

    @MainActor
    func testRecorderStartAndStopSurvivesMotionCallbacks() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideDay.self, RideSegment.self,
                                           Trail.self, TrailPass.self,
                                           configurations: configuration)
        let recorder = RideRecorder(context: ModelContext(container))
        let previousRecordingState = UserDefaults.standard.bool(forKey: "berms.recordingActive")
        defer { UserDefaults.standard.set(previousRecordingState, forKey: "berms.recordingActive") }

        XCTAssertTrue(recorder.start())
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNotNil(recorder.stop())
        XCTAssertFalse(recorder.isRecording)
    }

    @MainActor
    func testDiagnosticLogRebuildPersistsAllSegments() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideDay.self, RideSegment.self, configurations: configuration)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 7_000)
        let day = RideDay(startedAt: base)
        day.endedAt = base.addingTimeInterval(60)
        let oldSegment = RideSegment(kind: .lift, startedAt: base, endedAt: base.addingTimeInterval(20),
                                     routeData: Data([1, 2, 3]))
        oldSegment.day = day
        day.segments.append(oldSegment)
        context.insert(day)
        context.insert(oldSegment)
        try context.save()

        var records = [RawDiagnosticRecord(kind: "session_started", timestamp: base, monotonicSeconds: 0)]
        for index in 0...4 {
            let seconds = Double(index) * 5
            records.append(RawDiagnosticRecord(
                kind: "detector_input", timestamp: base.addingTimeInterval(seconds),
                monotonicSeconds: seconds, latitude: 40 + Double(index) * 0.0001,
                longitude: -105, fusedAltitude: Double(index * 5),
                trackMonotonicSeconds: seconds, speed: 4, horizontalAccuracy: 5,
                stationary: false, cycling: false, automotive: false, accepted: true
            ))
        }
        for index in 1...5 {
            let seconds = 20 + Double(index) * 5
            records.append(RawDiagnosticRecord(
                kind: "detector_input", timestamp: base.addingTimeInterval(seconds),
                monotonicSeconds: seconds, latitude: 40.001 + Double(index) * 0.0001,
                longitude: -105, fusedAltitude: Double(20 - index * 5),
                trackMonotonicSeconds: seconds, speed: 7, horizontalAccuracy: 5,
                stationary: false, cycling: false, automotive: false, accepted: true
            ))
        }
        records.append(RawDiagnosticRecord(kind: "session_stopped", timestamp: base.addingTimeInterval(60),
                                            monotonicSeconds: 60))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("berms-rebuild-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = RideRecorder(context: context)
        XCTAssertTrue(recorder.rebuildSummaryFromDiagnosticLog(for: day, from: url))
        XCTAssertEqual(day.segments.sorted { $0.startedAt < $1.startedAt }.map(\.kind), [.lift, .run])
        XCTAssertGreaterThan(day.distanceMeters, 0)
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<RideDay>()).first)
        XCTAssertEqual(saved.segments.sorted { $0.startedAt < $1.startedAt }.map(\.kind), [.lift, .run])
        XCTAssertGreaterThan(saved.descentMeters, 0)
    }

    private func runContext(at seconds: Double, base: Date, speed: Double = 8,
                             phase: DetectorPhase = .run) -> JumpTrackContext {
        JumpTrackContext(timestamp: base.addingTimeInterval(seconds), monotonicSeconds: seconds,
                         speed: speed, altitude: 100, phase: phase, isStationary: false, isAutomotive: false)
    }

    private func motion(at seconds: Double, forceG: Double, rotation: Double = 0,
                        base: Date = Date(timeIntervalSince1970: 2_000)) -> DeviceMotionSample {
        DeviceMotionSample(recordedAt: base.addingTimeInterval(seconds), monotonicSeconds: seconds,
                           userAccelerationX: 0, userAccelerationY: 0, userAccelerationZ: 1 - forceG,
                           rotationRateX: rotation, rotationRateY: 0, rotationRateZ: 0,
                           gravityX: 0, gravityY: 0, gravityZ: -1,
                           quaternionW: 1, quaternionX: 0, quaternionY: 0, quaternionZ: 0)
    }

    private func rawMotionRecord(at seconds: Double, base: Date, forceG: Double) -> RawDiagnosticRecord {
        let sample = motion(at: seconds, forceG: forceG, base: base)
        return RawDiagnosticRecord(kind: "device_motion_raw", timestamp: sample.recordedAt,
                                   monotonicSeconds: sample.monotonicSeconds,
                                   userAccelerationZ: sample.userAccelerationZ,
                                   gravityZ: sample.gravityZ, quaternionW: 1)
    }

    private func sample(at base: Date, index: Int, altitude: Double, speed: Double,
                        cycling: Bool, stationary: Bool = false, automotive: Bool = false,
                        accuracy: Double = 8, interval: Double = 5) -> TrackSample {
        TrackSample(
            coordinate: Coordinate(latitude: 40 + Double(index) * 0.0001, longitude: -105),
            altitude: altitude,
            speed: speed,
            horizontalAccuracy: accuracy,
            timestamp: base.addingTimeInterval(Double(index) * interval),
            isStationary: stationary,
            isCycling: cycling,
            isAutomotive: automotive
        )
    }
}
