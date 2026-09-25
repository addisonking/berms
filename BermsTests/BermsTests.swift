import Foundation
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Berms

final class BermsTests: XCTestCase {
    func testThemeContrastInLightAndDarkAppearance() {
        func luminance(_ color: Color, style: UIUserInterfaceStyle) -> Double {
            let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
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
                (.bermsOnAccent, .bermsTrail),
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

    func testTrailMapLabelsCollapseRepeatedTrailNames() {
        func overlay(id: String, name: String, pointCount: Int) -> TrailMapOverlay {
            let points = (0..<pointCount).map {
                RoutePoint(
                    latitude: 40 + Double($0) * 0.001,
                    longitude: -111,
                    altitude: 0,
                    speed: 0,
                    timestamp: Date(timeIntervalSince1970: Double($0)))
            }
            return TrailMapOverlay(
                id: id,
                trailID: UUID(),
                name: name,
                difficulty: .blue,
                points: points,
                score: 1)
        }

        let overlays = [
            overlay(id: "a", name: "Salvation", pointCount: 4),
            overlay(id: "b", name: "Salvation", pointCount: 10),
            overlay(id: "c", name: "Deviant", pointCount: 6),
            overlay(id: "d", name: " salvation ", pointCount: 8),
        ]

        let labels = trailMapLabelItems(for: overlays)
        XCTAssertEqual(labels.map(\.name), ["Salvation", "Deviant"])
        XCTAssertEqual(labels[0].id, "salvation")
        XCTAssertEqual(labels[0].coordinate.latitude, 40 + 5 * 0.001, accuracy: 1e-9)
        XCTAssertEqual(labels[1].coordinate.latitude, 40 + 3 * 0.001, accuracy: 1e-9)

        let limited = trailMapLabelItems(for: overlays, limit: 1)
        XCTAssertEqual(limited.map(\.name), ["Salvation"])
    }

    @MainActor
    func testTrailCatalogImportIsIdempotentAndNamespacesIDs() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Trail.self, TrailPass.self,
            configurations: configuration)
        let context = container.mainContext
        let suiteName = "BermsTests.catalogImport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstCatalog = TrailCatalogDescriptor(
            id: "catalog-a", season: .summer, resortID: "resort-a",
            resortName: "Resort A", bundledResourceName: "a",
            importVersion: "a-v1",
            stableIDNamespace: "berms:catalog-a", legacyImportVersionKeys: [],
            difficultyOverrides: [:], aliases: [:])
        let secondCatalog = TrailCatalogDescriptor(
            id: "catalog-b", season: .summer, resortID: "resort-b",
            resortName: "Resort B", bundledResourceName: "b",
            importVersion: "b-v1",
            stableIDNamespace: "berms:catalog-b", legacyImportVersionKeys: [],
            difficultyOverrides: [:], aliases: [:])
        let data = Data(
            """
            {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Shared name","slug":"shared","difficulty":"green"},"geometry":{"type":"LineString","coordinates":[[-105,40],[-105,40.001]]}}]}
            """.utf8)

        let first = try TrailCatalogImporter.import(
            data: data, into: context,
            defaults: defaults, catalog: firstCatalog)
        let second = try TrailCatalogImporter.import(
            data: data, into: context,
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
    func testTrailCatalogImportSkipsMalformedFeatures() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Trail.self, TrailPass.self,
            configurations: configuration)
        let context = container.mainContext
        let suiteName = "BermsTests.lossyImport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let data = Data(
            """
            {"type":"FeatureCollection","features":[
            {"type":"Feature","properties":{"name":"Broken","slug":"broken","difficulty":"green"},"geometry":null},
            {"type":"Feature","properties":null,"geometry":{"type":"LineString","coordinates":[[-105,40],[-105,40.001]]}},
            {"type":"Feature","properties":{"name":"Good","slug":"good","difficulty":"blue"},"geometry":{"type":"LineString","coordinates":[[-105,40],[-105,40.002]]}}
            ]}
            """.utf8)

        let summary = try TrailCatalogImporter.import(
            data: data, into: context,
            defaults: defaults)
        XCTAssertEqual(summary.trailsCreated, 1)
        XCTAssertEqual(summary.passesCreated, 1)
        let trails = try context.fetch(FetchDescriptor<Trail>())
        XCTAssertEqual(trails.count, 1)
        XCTAssertEqual(trails.first?.name, "Good")
    }

    @MainActor
    func testMountainCreekCatalogAppliesOfficialDifficultyCorrectionsAndMergesDuplicates() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Trail.self, TrailPass.self,
            configurations: configuration)
        let context = container.mainContext
        let suiteName = "BermsTests.mountainCreekCorrections.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let canonicalSlug = "lower-asylum-1f4u6s"
        let retiredSlug = "lower-asylum-196712"
        let duplicate = Trail(
            name: "Lower Asylum", difficulty: .black,
            resort: TrailCatalogRegistry.mountainCreek.resortName)
        duplicate.id = TrailCatalogImporter.stableID(
            for: retiredSlug,
            catalog: TrailCatalogRegistry.mountainCreek)
        let duplicatePass = TrailPass(routePoints: [
            RoutePoint(
                latitude: 41.1854, longitude: -74.5022, altitude: 0, speed: 0,
                timestamp: .now),
            RoutePoint(
                latitude: 41.1867, longitude: -74.5027,
                altitude: 0, speed: 0, timestamp: .now.addingTimeInterval(1)),
        ])
        duplicatePass.trail = duplicate
        duplicate.passes.append(duplicatePass)
        context.insert(duplicate)
        context.insert(duplicatePass)
        try context.save()

        let data = Data(
            """
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

        _ = try TrailCatalogImporter.import(
            data: data, into: context,
            defaults: defaults,
            catalog: TrailCatalogRegistry.mountainCreek,
            version: "mountain-creek-ridepal-v3")

        let trails = try context.fetch(FetchDescriptor<Trail>())
        XCTAssertEqual(trails.count, 6)
        XCTAssertNil(
            trails.first {
                $0.id
                    == TrailCatalogImporter.stableID(
                        for: retiredSlug, catalog: TrailCatalogRegistry.mountainCreek)
            })
        XCTAssertEqual(trails.first { $0.name == "Progression Drops" }?.difficulty, .green)
        XCTAssertEqual(trails.first { $0.name == "Deviant" }?.difficulty, .green)
        XCTAssertEqual(trails.first { $0.name == "Pipeline" }?.difficulty, .black)
        XCTAssertEqual(trails.first { $0.name == "Ripper" }?.difficulty, .doubleBlack)
        XCTAssertEqual(trails.first { $0.name == "The Pit" }?.difficulty, .doubleBlack)
        XCTAssertEqual(trails.first { $0.name == "Lower Asylum" }?.passCount, 2)
    }

    func testDayCatalogResolutionVotesAcrossTheWholeRoute() {
        let creek = Coordinate(latitude: 41.1844, longitude: -74.5033)
        let city = Coordinate(latitude: 40.7128, longitude: -74.0060)

        let ride =
            Array(repeating: city, count: 40)
            + Array(repeating: creek, count: 40)
        XCTAssertEqual(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .bikePark, manualSelectionID: nil, routePoints: ride),
            TrailCatalogRegistry.mountainCreekCatalogID,
            "A ride that starts outside the boundary still resolves the resort it rode in")

        let strayPoint =
            Array(repeating: city, count: 40)
            + [creek]
        XCTAssertNil(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .bikePark, manualSelectionID: nil, routePoints: strayPoint),
            "One stray point near a boundary does not claim the day")
    }

    func testDayCatalogResolutionHonoursTheRiderOverride() {
        let creek = Coordinate(latitude: 41.1844, longitude: -74.5033)
        let whistler = Coordinate(latitude: 50.0891, longitude: -122.9634)

        XCTAssertEqual(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .bikePark,
                manualSelectionID: TrailCatalogRegistry.mountainCreekCatalogID,
                routePoints: Array(repeating: whistler, count: 20)),
            TrailCatalogRegistry.mountainCreekCatalogID,
            "A rider override beats the route vote")
    }

    func testNearestResortOnlyPreviewsWithinRange() {
        let creek = Coordinate(latitude: 41.1844, longitude: -74.5033)
        let nearby = TrailCatalogRegistry.resort(nearest: creek, withinMeters: 5_000)
        XCTAssertEqual(nearby?.id, TrailCatalogRegistry.mountainCreekResortID)

        let city = Coordinate(latitude: 40.7128, longitude: -74.0060)
        XCTAssertNil(TrailCatalogRegistry.resort(nearest: city, withinMeters: 5_000))
    }

    func testActivityModeResolvesSeasonalMountainCreekCatalogs() {
        XCTAssertEqual(ActivityMode.bikePark.season, .summer)
        XCTAssertEqual(ActivityMode.ski.season, .winter)
        XCTAssertEqual(
            TrailCatalogRegistry.catalog(for: .bikePark)?.id,
            TrailCatalogRegistry.mountainCreek.id)
        XCTAssertEqual(
            TrailCatalogRegistry.catalog(for: .ski)?.id,
            TrailCatalogRegistry.mountainCreekWinter.id)
        XCTAssertNil(TrailCatalogRegistry.mountainCreekWinter.bundledResourceName)
    }

    func testBundledResortManifestLoadsAndResolvesResources() throws {
        let manifest = try ResortCatalogLoader.load(bundle: .main)
        XCTAssertFalse(manifest.resorts.isEmpty)
        XCTAssertNotNil(TrailCatalogRegistry.catalog(withID: "mountain-creek-resort"))
        XCTAssertNotNil(TrailCatalogRegistry.catalog(withID: "whistler-resort"))

        let catalogIDs = manifest.catalogs.map(\.id)
        XCTAssertEqual(Set(catalogIDs).count, catalogIDs.count)

        for resort in manifest.resorts {
            XCTAssertFalse(resort.id.isEmpty)
            XCTAssertFalse(resort.name.isEmpty)
            XCTAssertFalse(resort.catalogs.isEmpty)
            XCTAssertGreaterThan(resort.boundary.radiusMeters, 0)
            XCTAssertLessThanOrEqual(
                resort.boundary.radiusMeters, 25_000,
                "\(resort.id) boundary is larger than any resort; a stray coordinate would do this")
            for catalog in resort.catalogs {
                XCTAssertEqual(catalog.resortID, resort.id)
                XCTAssertEqual(catalog.resortName, resort.name)
                XCTAssertFalse(catalog.stableIDNamespace.isEmpty)
                guard let resource = catalog.bundledResourceName else { continue }
                XCTAssertNotNil(
                    Bundle.main.url(forResource: resource, withExtension: "geojson"),
                    "Missing bundled trail resource \(resource)")

                // The boundary has to cover the catalog geometry, since it
                // decides both camera limits and whether a ride is "at" the resort.
                let routes = TrailCatalogImporter.bundledRoutePoints(catalog: catalog)
                XCTAssertFalse(routes.isEmpty, "Missing bundled geometry for \(resource)")
                for points in routes.values {
                    for point in points {
                        XCTAssertTrue(
                            resort.boundary.contains(
                                Coordinate(latitude: point.latitude, longitude: point.longitude)),
                            "\(resort.id) boundary misses a \(catalog.id) point")
                    }
                }
            }
        }

        let summer = TrailCatalogRegistry.mountainCreek
        XCTAssertEqual(summer.resortID, TrailCatalogRegistry.mountainCreekResortID)
        XCTAssertEqual(summer.difficultyOverrides.count, 12)
        XCTAssertEqual(summer.aliases.count, 2)
        XCTAssertEqual(
            TrailCatalogRegistry.catalogsBySeason[.winter]?.first?.id,
            TrailCatalogRegistry.mountainCreekWinter.id)
    }

    func testResortManifestDecodesMultipleResorts() throws {
        let data = Data(
            """
            {"schemaVersion":1,"resorts":[
              {"id":"resort-a","name":"Resort A","anchor":{"latitude":40,"longitude":-105},
               "bounds":{"center":{"latitude":40,"longitude":-105},"radiusMeters":1500},
               "catalogs":[{"id":"a-summer","season":"summer","resource":"a","version":"a-v1","stableIDNamespace":"berms:a"}]},
              {"id":"resort-b","name":"Resort B","region":"Utah","anchor":{"latitude":41,"longitude":-106},
               "bounds":{"center":{"latitude":41,"longitude":-106},"radiusMeters":2500},
               "catalogs":[{"id":"b-winter","season":"winter","version":"b-v1","stableIDNamespace":"berms:b",
                 "difficultyOverrides":{"x":"black"},"aliases":{"old-x":"x"}}]}
            ]}
            """.utf8)

        let manifest = try ResortCatalogLoader.decode(data)
        XCTAssertEqual(manifest.resorts.map(\.id), ["resort-a", "resort-b"])
        XCTAssertEqual(manifest.catalogs.map(\.id), ["a-summer", "b-winter"])
        XCTAssertEqual(manifest.resorts[0].seasons, [.summer])
        XCTAssertEqual(manifest.resorts[1].seasons, [.winter])
        XCTAssertEqual(manifest.resorts[1].region, "Utah")
        XCTAssertEqual(manifest.catalogs[0].resortID, "resort-a")
        XCTAssertEqual(manifest.catalogs[0].resortName, "Resort A")
        XCTAssertEqual(manifest.resorts[0].boundary.center.latitude, 40, accuracy: 1e-9)
        XCTAssertEqual(manifest.resorts[0].boundary.radiusMeters, 1500)
        XCTAssertEqual(manifest.resorts[1].boundary.radiusMeters, 2500)
        XCTAssertEqual(manifest.catalogs[0].bundledResourceName, "a")
        XCTAssertEqual(manifest.catalogs[1].difficultyOverrides["x"], .black)
        XCTAssertEqual(manifest.catalogs[1].aliases["old-x"], "x")
        XCTAssertEqual(manifest.catalogs[1].legacyImportVersionKeys, [])
    }

    @MainActor
    func testCatalogImportAppliesDescriptorOverridesAndMergesAliases() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Trail.self, TrailPass.self,
            configurations: configuration)
        let context = container.mainContext
        let suiteName = "BermsTests.descriptorCorrections.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let catalog = TrailCatalogDescriptor(
            id: "test-resort-summer", season: .summer, resortID: "test-resort",
            resortName: "Test Resort", bundledResourceName: nil,
            importVersion: "test-v1",
            stableIDNamespace: "berms:test-resort",
            legacyImportVersionKeys: [],
            difficultyOverrides: ["new-line": .doubleBlack],
            aliases: ["old-line": "new-line"])

        let retiredTrail = Trail(
            name: "New Line", difficulty: .green,
            resort: catalog.resortName, catalogID: catalog.id)
        retiredTrail.id = TrailCatalogImporter.stableID(for: "old-line", catalog: catalog)
        let retiredPass = TrailPass(
            routePoints: [
                RoutePoint(
                    latitude: 40, longitude: -105, altitude: 0, speed: 0,
                    timestamp: .now),
                RoutePoint(
                    latitude: 40.001, longitude: -105, altitude: 0, speed: 0,
                    timestamp: .now.addingTimeInterval(1)),
            ], recordedAt: .now)
        retiredPass.trail = retiredTrail
        retiredTrail.passes.append(retiredPass)
        context.insert(retiredTrail)
        context.insert(retiredPass)
        try context.save()

        let data = Data(
            """
            {"type":"FeatureCollection","features":[
              {"type":"Feature","properties":{"name":"New Line","slug":"new-line","difficulty":"green"},"geometry":{"type":"LineString","coordinates":[[-105,40],[-105,40.001]]}},
              {"type":"Feature","properties":{"name":"New Line","slug":"old-line","difficulty":"green"},"geometry":{"type":"LineString","coordinates":[[-105,40],[-105,40.001]]}}
            ]}
            """.utf8)

        _ = try TrailCatalogImporter.import(
            data: data, into: context, defaults: defaults, catalog: catalog)

        let trails = try context.fetch(FetchDescriptor<Trail>())
        XCTAssertEqual(trails.count, 1)
        XCTAssertEqual(trails.first?.id, TrailCatalogImporter.stableID(for: "new-line", catalog: catalog))
        XCTAssertEqual(trails.first?.difficulty, .doubleBlack)
        XCTAssertEqual(trails.first?.passCount, 2)
    }

    @MainActor
    func testWhistlerCatalogImportsBundledGeometryWithAliases() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Trail.self, TrailPass.self,
            configurations: configuration)
        let context = container.mainContext
        let suiteName = "BermsTests.whistlerImport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let catalog = try XCTUnwrap(TrailCatalogRegistry.catalog(withID: "whistler-resort"))
        XCTAssertEqual(catalog.resortName, "Whistler Mountain Bike Park")
        XCTAssertEqual(catalog.aliases.count, 20)
        let resource = try XCTUnwrap(catalog.bundledResourceName)
        let url = try XCTUnwrap(Bundle.main.url(forResource: resource, withExtension: "geojson"))

        let summary = try TrailCatalogImporter.import(
            data: Data(contentsOf: url), into: context,
            defaults: defaults, catalog: catalog)

        XCTAssertEqual(summary.trailsCreated, 100)
        XCTAssertEqual(summary.invalidFeaturesSkipped, 0)

        let trails = try context.fetch(FetchDescriptor<Trail>())
        XCTAssertEqual(trails.count, 100)
        XCTAssertEqual(trails.filter { $0.name == "Una Moss" }.count, 1)
        XCTAssertEqual(trails.filter { $0.name == "Expressway" }.count, 1)
        XCTAssertEqual(trails.first { $0.name == "Expressway" }?.difficulty, .blue)
        XCTAssertEqual(trails.first { $0.name == "Blue Velvet" }?.difficulty, .blue)
        XCTAssertEqual(
            trails.first { $0.name == "Northwest Passage" }?.difficulty, .unrated,
            "RidePal has no rating for this trail, so it imports as unrated")
        XCTAssertTrue(
            trails.allSatisfy {
                $0.resort == "Whistler Mountain Bike Park"
                    && $0.catalogID == "whistler-resort"
            })
    }

    func testDayCatalogResolutionRequiresAResortBoundary() {
        let whistler = Coordinate(latitude: 50.0891, longitude: -122.9634)
        let creek = Coordinate(latitude: 41.1844, longitude: -74.5033)
        let city = Coordinate(latitude: 40.7128, longitude: -74.0060)

        XCTAssertEqual(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .bikePark, manualSelectionID: nil, firstPoint: whistler),
            "whistler-resort")
        XCTAssertEqual(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .bikePark, manualSelectionID: nil, firstPoint: creek),
            TrailCatalogRegistry.mountainCreekCatalogID)
        XCTAssertNil(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .bikePark, manualSelectionID: nil, firstPoint: city),
            "A ride outside every resort boundary stays unassigned")
        XCTAssertEqual(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .bikePark,
                manualSelectionID: TrailCatalogRegistry.mountainCreekCatalogID,
                firstPoint: whistler),
            TrailCatalogRegistry.mountainCreekCatalogID)
        XCTAssertNil(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .bikePark, manualSelectionID: nil, firstPoint: nil))
        // A winter selection does not apply to a summer ride.
        XCTAssertEqual(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .bikePark,
                manualSelectionID: TrailCatalogRegistry.mountainCreekWinterCatalogID,
                firstPoint: whistler),
            "whistler-resort")
        // GPS resolution has to respect the activity's season.
        XCTAssertEqual(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .ski, manualSelectionID: nil, firstPoint: creek),
            TrailCatalogRegistry.mountainCreekWinterCatalogID)
        XCTAssertEqual(
            TrailCatalogRegistry.resolvedCatalogID(
                mode: .bikePark,
                manualSelectionID: TrailCatalogRegistry.mountainCreekWinterCatalogID,
                firstPoint: creek),
            TrailCatalogRegistry.mountainCreekCatalogID)
    }

    /// Slugs repeat across parks, so a shared namespace silently merges two
    /// trails into one ID. Catch that before a bundle ships.
    func testBundledCatalogStableIDsDoNotCollide() {
        let candidates = TrailCatalogImporter.bundledRouteCandidates()
        XCTAssertFalse(candidates.isEmpty)

        var catalogsByID: [UUID: Set<String>] = [:]
        for candidate in candidates {
            catalogsByID[candidate.id, default: []].insert(candidate.name)
        }
        let collisions = catalogsByID.filter { $0.value.count > 1 }
        XCTAssertTrue(
            collisions.isEmpty,
            "Stable ID collisions across catalog namespaces: \(collisions.map { $0.value.sorted().joined(separator: "/") }.sorted())"
        )

        XCTAssertEqual(
            Set(candidates.map(\.id)).count, candidates.count,
            "Two bundled trails share a stable ID")
    }

    func testManifestRejectsAnUnsupportedSchemaVersion() throws {
        let data = Data(
            """
            {"schemaVersion":2,"resorts":[
              {"id":"resort-a","name":"Resort A",
               "bounds":{"center":{"latitude":40,"longitude":-105},"radiusMeters":1500},
               "catalogs":[]}
            ]}
            """.utf8)

        XCTAssertThrowsError(try ResortCatalogLoader.decode(data)) { error in
            guard case ResortCatalogLoader.ManifestError.unsupportedSchema(2) = error else {
                return XCTFail("Expected an unsupported schema error, got \(error)")
            }
        }
    }

    func testManifestReportsMalformedEntries() throws {
        let data = Data(
            """
            {"schemaVersion":1,"resorts":[{"id":"resort-a","name":"Resort A","catalogs":[]}]}
            """.utf8)

        XCTAssertThrowsError(try ResortCatalogLoader.decode(data)) { error in
            guard case ResortCatalogLoader.ManifestError.invalidManifest = error else {
                return XCTFail("Expected an invalid manifest error, got \(error)")
            }
        }
    }

    func testResortBoundaryResolvesOnlyInsideTheResort() throws {
        let creek = try XCTUnwrap(TrailCatalogRegistry.resort(withID: "mountain-creek"))
        XCTAssertTrue(creek.boundary.contains(Coordinate(latitude: 41.1844, longitude: -74.5033)))
        XCTAssertNil(
            TrailCatalogRegistry.resort(
                containing: Coordinate(latitude: 40.7128, longitude: -74.0060)),
            "Rides far from every resort do not resolve")
        XCTAssertEqual(
            TrailCatalogRegistry.resort(
                containing: Coordinate(latitude: 50.0891, longitude: -122.9634))?.id,
            "whistler")
    }

    func testResortMapConfigurationKeepsTheCameraAtTheResort() throws {
        let resort = try XCTUnwrap(TrailCatalogRegistry.resort(withID: "mountain-creek"))
        let route = [
            RoutePoint(
                latitude: 41.1844, longitude: -74.5033, altitude: 0, speed: 0, timestamp: .now)
        ]
        let configuration = try XCTUnwrap(
            RouteMapConfiguration(points: route, boundary: resort.boundary))
        let diameter = resort.boundary.radiusMeters * 2

        XCTAssertGreaterThanOrEqual(configuration.minimumDistance, 60)
        XCTAssertLessThanOrEqual(configuration.maximumDistance, diameter * 2.1)
        XCTAssertGreaterThanOrEqual(
            configuration.maximumDistance, diameter * 1.5,
            "Zooming out has to fit the whole resort")
        XCTAssertLessThanOrEqual(
            configuration.panRegion.span.latitudeDelta * 111_000, diameter * 1.5,
            "Panning has to stay at the resort")
    }

    func testGeoBoundsPruneAndMerge() throws {
        let points = [
            RoutePoint(latitude: 41.18, longitude: -74.50, altitude: 0, speed: 0, timestamp: .now),
            RoutePoint(latitude: 41.19, longitude: -74.49, altitude: 0, speed: 0, timestamp: .now),
        ]
        let bounds = try XCTUnwrap(GeoBounds(points: points))
        XCTAssertTrue(bounds.contains(Coordinate(latitude: 41.185, longitude: -74.495)))
        XCTAssertFalse(bounds.contains(Coordinate(latitude: 41.30, longitude: -74.495)))
        XCTAssertTrue(
            bounds.contains(Coordinate(latitude: 41.30, longitude: -74.495), paddingMeters: 20_000))
        XCTAssertTrue(
            bounds.intersects(
                centerLatitude: 41.185, centerLongitude: -74.495,
                latitudeSpan: 0.001, longitudeSpan: 0.001))
        XCTAssertFalse(
            bounds.intersects(
                centerLatitude: 42.0, centerLongitude: -74.495,
                latitudeSpan: 0.01, longitudeSpan: 0.01))
        XCTAssertNil(GeoBounds(points: []))

        let far = try XCTUnwrap(
            GeoBounds(points: [
                RoutePoint(latitude: 40, longitude: -75, altitude: 0, speed: 0, timestamp: .now)
            ]))
        let union = bounds.union(far)
        XCTAssertEqual(union.minLatitude, 40)
        XCTAssertEqual(union.maxLatitude, 41.19)
        XCTAssertEqual(union.minLongitude, -75)
        XCTAssertEqual(union.maxLongitude, -74.49)
    }

    @MainActor
    func testTrailGeometryStoreRefreshesWhenATrailChanges() throws {
        TrailGeometryStore.shared.invalidateAll()
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Trail.self, TrailPass.self,
            configurations: configuration)
        let context = container.mainContext

        let trail = Trail(name: "Cache Test", difficulty: .blue, resort: "Test Resort", catalogID: "test")
        let shortPass = TrailPass(
            routePoints: [
                RoutePoint(latitude: 40, longitude: -105, altitude: 0, speed: 0, timestamp: .now),
                RoutePoint(
                    latitude: 40.001, longitude: -105, altitude: 0, speed: 0,
                    timestamp: .now.addingTimeInterval(1)),
            ], recordedAt: .now)
        shortPass.trail = trail
        trail.passes.append(shortPass)
        context.insert(trail)
        trail.recalculateAverage()

        let first = TrailGeometryStore.shared.metrics(for: trail)
        XCTAssertGreaterThan(first.distanceMeters, 0)
        XCTAssertNotNil(first.bounds)
        XCTAssertNotNil(first.labelCoordinate)
        XCTAssertEqual(TrailGeometryStore.shared.metrics(for: trail).distanceMeters, first.distanceMeters)

        context.delete(shortPass)
        let longPass = TrailPass(
            routePoints: [
                RoutePoint(latitude: 40, longitude: -105, altitude: 0, speed: 0, timestamp: .now),
                RoutePoint(
                    latitude: 40.01, longitude: -105, altitude: 0, speed: 0,
                    timestamp: .now.addingTimeInterval(1)),
            ], recordedAt: .now)
        longPass.trail = trail
        trail.passes.append(longPass)
        trail.recalculateAverage()
        trail.updatedAt = Date().addingTimeInterval(120)

        XCTAssertGreaterThan(
            TrailGeometryStore.shared.metrics(for: trail).distanceMeters, first.distanceMeters,
            "A changed trail has to refresh its cached metrics")
    }

    func testSessionMapConfigurationCannotZoomToTheGlobe() throws {
        let points = (0...10).map { index in
            RoutePoint(
                latitude: 40 + Double(index) * 0.001, longitude: -105,
                altitude: 0, speed: 0, timestamp: .now)
        }
        let configuration = try XCTUnwrap(RouteMapConfiguration(points: points))

        XCTAssertLessThan(configuration.maximumDistance, 20_000)
        XCTAssertLessThanOrEqual(
            configuration.panRegion.span.latitudeDelta * 111_000, 12_000,
            "A short ride must not allow a regional camera")
    }

    func testSeasonalTrailSelectionDoesNotLeakSummerTrailsIntoWinter() {
        let summerTrail = Trail(
            name: "Summer trail", difficulty: .green,
            resort: TrailCatalogRegistry.mountainCreek.resortName,
            catalogID: TrailCatalogRegistry.mountainCreek.id)
        let legacyTrail = Trail(
            name: "Legacy trail", difficulty: .blue,
            resort: TrailCatalogRegistry.mountainCreek.resortName)
        let winterTrail = Trail(
            name: "Winter trail", difficulty: .blue,
            resort: TrailCatalogRegistry.mountainCreekWinter.resortName,
            catalogID: TrailCatalogRegistry.mountainCreekWinter.id)

        XCTAssertEqual(
            TrailCatalogRegistry.trails(
                [summerTrail, legacyTrail], for: TrailCatalogRegistry.mountainCreek
            ).map(\.name),
            ["Summer trail", "Legacy trail"]
        )
        XCTAssertEqual(
            TrailCatalogRegistry.trails(
                [summerTrail, legacyTrail, winterTrail],
                for: TrailCatalogRegistry.mountainCreekWinter
            ).map(\.name),
            ["Winter trail"]
        )
    }

    func testRideDayDefaultsToBikeAndExportsSeasonalMetadata() throws {
        let day = RideDay(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(day.activityMode, .bikePark)

        day.activityModeRawValue = ActivityMode.ski.rawValue
        day.catalogID = TrailCatalogRegistry.mountainCreekWinter.id

        XCTAssertEqual(day.activityMode, .ski)
        let export = BermsDataExport(day: day)
        XCTAssertEqual(export.days.first?.activityMode, .ski)
        XCTAssertEqual(export.days.first?.catalogID, TrailCatalogRegistry.mountainCreekWinter.id)
    }

    @MainActor
    func testTrailSequenceResolverPreservesRideOrderAndFallsBack() throws {
        let base = Date(timeIntervalSince1970: 10_000)
        let route = (0...20).map { index in
            RoutePoint(
                latitude: 40 + Double(index) * 0.0001, longitude: -105,
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
        let segment = RideSegment(
            kind: .run, startedAt: base, endedAt: base.addingTimeInterval(20),
            routeData: try RouteCodec.encode(route))

        TrailRouteMatchCache.shared.invalidate()
        XCTAssertEqual(
            TrailSequenceResolver.names(
                for: segment,
                trails: [firstTrail, secondTrail]),
            ["First", "Second"])
        XCTAssertEqual(
            TrailSequenceResolver.title(
                for: segment,
                trails: [firstTrail, secondTrail]),
            "First → Second")
        XCTAssertNil(TrailSequenceResolver.title(for: segment, trails: []))
        TrailRouteMatchCache.shared.invalidate()
    }

    func testSessionDetailPresentationBuilderBuildsStableBaseMarkers() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let base = Date(timeIntervalSince1970: 10_000)
        let route = (0...10).map { index in
            RoutePoint(
                latitude: 41.2505 + Double(index) * 0.0001,
                longitude: -74.5012,
                altitude: 100 - Double(index),
                speed: 8,
                timestamp: base.addingTimeInterval(Double(index)))
        }
        let jump = JumpEvent(
            takeoffTimestamp: base.addingTimeInterval(5),
            landingTimestamp: base.addingTimeInterval(5.2),
            takeoffMonotonicSeconds: 5,
            landingMonotonicSeconds: 5.2)
        let input = SessionDetailPreparationInput(
            segments: [
                SessionDetailSegmentInput(
                    id: id,
                    kind: .run,
                    startedAt: route[0].timestamp,
                    endedAt: route[10].timestamp,
                    distanceMeters: 1_000,
                    verticalMeters: 100,
                    maximumSpeedMetersPerSecond: 8,
                    routeData: try RouteCodec.encode(route),
                    jumpData: try JSONEncoder().encode([jump])
                )
            ],
            trails: [],
            manualCatalogID: nil
        )

        let result = try SessionDetailPresentationBuilder.buildBase(input)

        XCTAssertEqual(result.runs.map(\.id), [id])
        XCTAssertEqual(result.runs.first?.routePoints, route)
        XCTAssertEqual(result.runs.first?.jumps.count, 1)
        XCTAssertEqual(result.runs.first?.jumps.first?.airtime ?? .nan, 0.2, accuracy: 0.001)
        // The builder resolves jump size from the run's route.
        XCTAssertEqual(result.runs.first?.jumps.first?.lengthMeters ?? .nan, 2.2, accuracy: 0.4)
        XCTAssertEqual(result.runs.first?.jumps.first?.dropMeters ?? .nan, 0.2, accuracy: 0.05)
        XCTAssertEqual(result.runs.first?.duration ?? .nan, 10, accuracy: 0.001)
        XCTAssertEqual(result.jumpMarkers.map(\.id), ["\(id.uuidString)-0"])
        XCTAssertEqual(result.jumpMarkers.first?.segmentID, id)
    }

    func testSessionDetailPresentationBuilderBuildsTrailNamesAndOverlays() throws {
        let segmentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let trailID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let base = Date(timeIntervalSince1970: 20_000)
        let route = (0...10).map { index in
            RoutePoint(
                latitude: 41.1844 + Double(index) * 0.0001,
                longitude: -74.5012,
                altitude: 100 - Double(index),
                speed: 8,
                timestamp: base.addingTimeInterval(Double(index)))
        }
        let routeData = try RouteCodec.encode(route)
        let offsetRoute = route.map { point in
            RoutePoint(
                latitude: point.latitude + 0.002,
                longitude: point.longitude,
                altitude: point.altitude,
                speed: point.speed,
                timestamp: point.timestamp)
        }
        let input = SessionDetailPreparationInput(
            segments: [
                SessionDetailSegmentInput(
                    id: segmentID,
                    kind: .run,
                    startedAt: route[0].timestamp,
                    endedAt: route[10].timestamp,
                    distanceMeters: 1_000,
                    verticalMeters: 100,
                    maximumSpeedMetersPerSecond: 8,
                    routeData: routeData,
                    jumpData: nil
                )
            ],
            trails: [
                SessionDetailTrailInput(
                    id: trailID,
                    name: "Test Trail",
                    difficulty: .blue,
                    resort: TrailCatalogRegistry.defaultCatalog.resortName,
                    averagedRouteData: try RouteCodec.encode(offsetRoute),
                    passRouteData: [routeData]
                )
            ],
            manualCatalogID: nil
        )
        let baseResult = try SessionDetailPresentationBuilder.buildBase(input)

        let details = try SessionDetailPresentationBuilder.buildTrailDetails(
            base: baseResult,
            input: input
        )

        XCTAssertEqual(details.sequenceBySegmentID[segmentID], "Test Trail")
        XCTAssertEqual(details.overlays.count, 1)
        XCTAssertEqual(details.overlays.first?.trailID, trailID)
        XCTAssertEqual(details.overlays.first?.name, "Test Trail")
        XCTAssertGreaterThan(details.overlays.first?.points.count ?? 0, 1)
        XCTAssertEqual(
            details.overlays.first?.points.first?.latitude ?? .nan,
            route.first?.latitude ?? .nan,
            accuracy: 0.0001)
    }

    func testSessionDetailBaseLimitsOverviewJumpMarkersDeterministically() {
        let markers = (0..<100).map { index in
            SessionDetailJumpMarker(
                id: "jump-\(index)",
                segmentID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                number: index + 1,
                coordinate: Coordinate(
                    latitude: 41.25 + Double(index) * 0.0001,
                    longitude: -74.50),
                airtime: 0.2
            )
        }
        let base = SessionDetailBase(runs: [], mapSegments: [], jumpMarkers: markers, segmentsByID: [:])

        XCTAssertEqual(base.jumpMarkers.count, 100)
        XCTAssertEqual(base.summaryJumpMarkers.count, SessionDetailBase.summaryJumpMarkerLimit)
        XCTAssertEqual(base.summaryJumpMarkers.first?.id, "jump-0")
        XCTAssertEqual(base.summaryJumpMarkers.last?.id, "jump-99")
    }

    @MainActor
    func testLatestRunPreheatSkipsEmptyLiftOnlyAndUnfinishedDays() throws {
        let start = Date(timeIntervalSince1970: 30_000)
        let olderDay = RideDay(startedAt: start)
        let newerDay = RideDay(startedAt: start.addingTimeInterval(100))
        let emptyDay = RideDay(startedAt: start.addingTimeInterval(200))
        let liftOnlyDay = RideDay(startedAt: start.addingTimeInterval(300))
        let unfinishedDay = RideDay(startedAt: start.addingTimeInterval(400))
        for day in [olderDay, newerDay, emptyDay, liftOnlyDay] {
            day.endedAt = day.startedAt.addingTimeInterval(60)
        }
        for day in [olderDay, newerDay, liftOnlyDay, unfinishedDay] {
            day.segments = [
                RideSegment(
                    kind: day === liftOnlyDay ? .lift : .run,
                    startedAt: day.startedAt,
                    endedAt: day.startedAt.addingTimeInterval(30),
                    routeData: Data()
                )
            ]
        }
        let days = [unfinishedDay, emptyDay, olderDay, liftOnlyDay, newerDay]

        let target = try XCTUnwrap(SessionDetailPresentationPreheater.latestCompletedRun(in: days))

        XCTAssertEqual(target.day.id, newerDay.id)
        XCTAssertEqual(target.run.id, newerDay.segments[0].id)
        XCTAssertNil(
            SessionDetailPresentationPreheater.latestCompletedRun(
                in: [emptyDay, liftOnlyDay, unfinishedDay]
            ))
    }

    @MainActor
    func testRunPreheatSnapshotsOnlyTheActiveResort() throws {
        let start = Date(timeIntervalSince1970: 31_000)
        let point = RoutePoint(
            latitude: 41.1844, longitude: -74.5033,
            altitude: 100, speed: 8, timestamp: start)
        let segment = RideSegment(
            kind: .run, startedAt: start, endedAt: start,
            routeData: try RouteCodec.encode([point]))
        let local = Trail(
            name: "Local", difficulty: .blue,
            resort: TrailCatalogRegistry.defaultCatalog.resortName)
        let unrelated = Trail(name: "Unrelated", difficulty: .black, resort: "Other resort")
        local.averagedRouteData = segment.routeData
        unrelated.averagedRouteData = Data([0xFF])

        for catalogID in [nil, TrailCatalogRegistry.defaultCatalog.id] as [String?] {
            let input = SessionDetailPresentationBuilder.makeInput(
                segment: segment, trails: [unrelated, local], manualCatalogID: catalogID
            )

            XCTAssertEqual(input.segments.map(\.id), [segment.id])
            XCTAssertEqual(input.trails.map(\.id), [local.id])
            XCTAssertEqual(input.trails.first?.averagedRouteData, segment.routeData)
        }
    }

    @MainActor
    func testRunPreheatCacheRejectsEditedAndRemovedTrails() async throws {
        let start = Date(timeIntervalSince1970: 32_000)
        let segment = RideSegment(
            kind: .run, startedAt: start, endedAt: start,
            routeData: try RouteCodec.encode([]))
        let trail = Trail(
            name: "Original", difficulty: .blue,
            resort: TrailCatalogRegistry.defaultCatalog.resortName,
            createdAt: start)
        let dayID = UUID()
        let selectionID = TrailCatalogRegistry.automaticSelectionID
        let key = SessionDetailPresentationPreheater.runCacheKey(
            dayID: dayID, segmentID: segment.id, selectionID: selectionID, trails: [trail]
        )
        let input = SessionDetailPresentationBuilder.makeInput(
            segment: segment, trails: [trail], manualCatalogID: nil
        )
        let entry = try await SessionDetailPresentationPreheater.build(input)
        let cache = SessionDetailPresentationCache()
        let detail = try XCTUnwrap(entry.base.segmentsByID[segment.id])
        cache.storeRun(
            .init(base: entry.base, detail: detail, trailDetails: entry.trailDetails),
            for: key)
        XCTAssertNotNil(cache.runEntry(for: key))

        trail.name = "Renamed"
        trail.updatedAt = start.addingTimeInterval(1)
        let editedKey = SessionDetailPresentationPreheater.runCacheKey(
            dayID: dayID, segmentID: segment.id, selectionID: selectionID, trails: [trail]
        )
        let removedKey = SessionDetailPresentationPreheater.runCacheKey(
            dayID: dayID, segmentID: segment.id, selectionID: selectionID, trails: []
        )

        XCTAssertNil(cache.runEntry(for: editedKey))
        XCTAssertNil(cache.runEntry(for: removedKey))
    }

    @MainActor
    func testRunPreheatCancellationDoesNotPublishAPresentation() async throws {
        let input = SessionDetailPreparationInput(segments: [], trails: [], manualCatalogID: nil)
        let preparation = Task { @MainActor in
            try await SessionDetailPresentationPreheater.build(input)
        }
        preparation.cancel()

        do {
            _ = try await preparation.value
            XCTFail("Cancelled preheating must not return a presentation")
        } catch is CancellationError {
            // Expected when navigation cancels a pending preheat.
        }
    }

    @MainActor
    func testRunPreparationReadsItsOwnModelContext() async throws {
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self,
            Trail.self, TrailPass.self, LearnedLift.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 33_000)
        let route = (0...4).map { index in
            RoutePoint(
                latitude: 41.1844 + Double(index) * 0.0001, longitude: -74.5033,
                altitude: 100 - Double(index), speed: 8,
                timestamp: base.addingTimeInterval(Double(index)))
        }
        let day = RideDay(startedAt: base)
        day.endedAt = base.addingTimeInterval(60)
        let segment = RideSegment(
            kind: .run, startedAt: base,
            endedAt: base.addingTimeInterval(5),
            routeData: try RouteCodec.encode(route))
        let trail = Trail(
            name: "Stored trail", difficulty: .blue,
            resort: TrailCatalogRegistry.defaultCatalog.resortName)
        let pass = TrailPass(routePoints: route, recordedAt: base)
        segment.day = day
        day.segments = [segment]
        pass.trail = trail
        trail.passes.append(pass)
        trail.recalculateAverage()
        context.insert(day)
        context.insert(trail)
        try context.save()
        TrailRouteMatchCache.shared.invalidate()

        let entry = try await SessionDetailPresentationPreheater.prepareRun(
            segmentID: segment.id,
            manualCatalogID: nil,
            container: container
        )

        XCTAssertEqual(entry?.detail.id, segment.id)
        XCTAssertEqual(entry?.trailDetails.sequenceBySegmentID[segment.id], trail.name)
    }

    func testLiveMapPresentationSelectsOnlyTheRelevantPath() {
        let point = RoutePoint(
            latitude: 40, longitude: -105, altitude: 100, speed: 8,
            timestamp: Date(timeIntervalSince1970: 1))
        let current = [
            point,
            RoutePoint(
                latitude: 40.001, longitude: -105, altitude: 90,
                speed: 8, timestamp: Date(timeIntervalSince1970: 2)),
        ]
        let older = [
            point,
            RoutePoint(
                latitude: 40.002, longitude: -105, altitude: 80,
                speed: 8, timestamp: Date(timeIntervalSince1970: 3)),
        ]
        let latest = [
            point,
            RoutePoint(
                latitude: 40.003, longitude: -105, altitude: 70,
                speed: 8, timestamp: Date(timeIntervalSince1970: 4)),
        ]

        XCTAssertEqual(
            RideMapPresentation.livePaths(
                activeKind: .run, currentPath: current,
                completedRunPaths: [older, latest],
                showsPreviousRuns: false
            ).map(\.role),
            [.activeSegment])
        XCTAssertEqual(
            RideMapPresentation.livePaths(
                activeKind: .lift, currentPath: current,
                completedRunPaths: [older, latest],
                showsPreviousRuns: false
            ).map(\.role),
            [.latestCompletedRun])
        XCTAssertEqual(
            RideMapPresentation.livePaths(
                activeKind: .lift, currentPath: current,
                completedRunPaths: [],
                showsPreviousRuns: false
            ).map(\.role),
            [.activeSegment])
        XCTAssertEqual(
            RideMapPresentation.livePaths(
                activeKind: .run, currentPath: current,
                completedRunPaths: [older, latest],
                showsPreviousRuns: true
            ).map(\.role),
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
            events += detector.process(
                sample(at: base, index: index, altitude: Double(index * 5), speed: 4, cycling: false))
        }

        XCTAssertEqual(detector.phase, .lift)
        XCTAssertTrue(
            events.contains { event in
                if case .started(kind: .lift, points: _) = event { return true }
                return false
            })

        for index in 0..<4 {
            events += detector.process(
                sample(at: base, index: index + 4, altitude: Double(15 - index * 5), speed: 7, cycling: true))
        }

        XCTAssertEqual(detector.phase, .run)
        XCTAssertTrue(
            events.contains { event in
                if case .finished(let draft) = event { return draft.kind == .lift }
                return false
            })
        XCTAssertTrue(
            events.contains { event in
                if case .started(kind: .run, points: _) = event { return true }
                return false
            })

        for index in 0..<3 {
            events += detector.process(
                sample(at: base, index: index + 8, altitude: 0, speed: 0, cycling: false, stationary: true))
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
            RoutePoint(
                latitude: 40.001, longitude: -105, altitude: 80, speed: 8, timestamp: base.addingTimeInterval(10)),
        ]
        let trail = Trail(name: "Cached", difficulty: .blue, resort: "Test")
        let pass = TrailPass(routePoints: route)
        pass.trail = trail
        trail.passes.append(pass)
        trail.recalculateAverage()
        let segment = RideSegment(
            kind: .run, startedAt: base, endedAt: base.addingTimeInterval(10),
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
            RoutePoint(
                latitude: 40 + Double(index) * 0.0001, longitude: -105,
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
            RoutePoint(
                latitude: 40 + Double(index) * 0.0001, longitude: -105,
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
            RoutePoint(
                latitude: 40.0005,
                longitude: -105 + Double(index - 10) * 0.0001,
                altitude: 100,
                speed: 8,
                timestamp: base.addingTimeInterval(Double(index)))
        }
        let trailPoints = (0...10).map { index in
            RoutePoint(
                latitude: 40 + Double(index) * 0.0001,
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
            RoutePoint(
                latitude: 40 + Double(index) * 0.0001, longitude: -105,
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
            RoutePoint(
                latitude: 40 + Double(index) * 0.001, longitude: -105,
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
            RoutePoint(
                latitude: 40.001, longitude: -105, altitude: 90, speed: 8,
                timestamp: base.addingTimeInterval(1)),
            RoutePoint(
                latitude: 40.002, longitude: -105, altitude: 80, speed: 8,
                timestamp: base.addingTimeInterval(2)),
        ]

        let slice = TrailRouteSlice.slice(points, progress: -0.5...1.5)

        XCTAssertEqual(slice, points)
    }

    func testTrailMatcherUsesARealPassWhenAverageIsOffset() {
        let base = Date(timeIntervalSince1970: 1_300)
        let route = (0...4).map { index in
            RoutePoint(
                latitude: 40 + Double(index) * 0.0001, longitude: -105,
                altitude: 100 - Double(index), speed: 8,
                timestamp: base.addingTimeInterval(Double(index)))
        }
        let offsetRoute = route.map { point in
            RoutePoint(
                latitude: point.latitude + 0.002, longitude: point.longitude,
                altitude: point.altitude, speed: point.speed, timestamp: point.timestamp)
        }
        let trail = Trail(name: "Offset", difficulty: .black, resort: "Test")
        let pass = TrailPass(routePoints: route, recordedAt: base)
        let offsetPass = TrailPass(routePoints: offsetRoute, recordedAt: base.addingTimeInterval(10))
        pass.trail = trail
        offsetPass.trail = trail
        trail.passes.append(contentsOf: [pass, offsetPass])
        trail.recalculateAverage()

        let match = TrailRouteMatcher().bestMatch(for: route, trails: [trail])
        let section = TrailRouteMatcher().matchingSections(for: route, trails: [trail]).first

        XCTAssertEqual(match?.trailID, trail.id)
        XCTAssertEqual(section?.routeIndex, 1)
    }

    func testTrailMatcherRouteIndexFollowsRecordedPassOrder() {
        let base = Date(timeIntervalSince1970: 1_320)
        let route = (0...4).map { index in
            RoutePoint(
                latitude: 40 + Double(index) * 0.0001, longitude: -105,
                altitude: 100 - Double(index), speed: 8,
                timestamp: base.addingTimeInterval(Double(index)))
        }
        let offsetRoute = route.map { point in
            RoutePoint(
                latitude: point.latitude + 0.002, longitude: point.longitude,
                altitude: point.altitude, speed: point.speed, timestamp: point.timestamp)
        }
        let trail = Trail(name: "Out of order", difficulty: .black, resort: "Test")
        let olderPass = TrailPass(routePoints: route, recordedAt: base)
        let newerPass = TrailPass(routePoints: offsetRoute, recordedAt: base.addingTimeInterval(20))
        olderPass.trail = trail
        newerPass.trail = trail
        // Stored newest first so the raw relationship order disagrees with recorded date.
        trail.passes.append(contentsOf: [newerPass, olderPass])
        trail.recalculateAverage()

        let section = TrailRouteMatcher().matchingSections(for: route, trails: [trail]).first

        XCTAssertEqual(section?.routeIndex, 1)
        guard let section else { return }
        XCTAssertEqual(trail.matcherRoutes[section.routeIndex], route)
    }

    func testTrailMatcherReturnsMultipleContiguousTrailSections() {
        let base = Date(timeIntervalSince1970: 1_350)
        let route = (0...10).map { index in
            if index <= 5 {
                return RoutePoint(
                    latitude: 40 + Double(index) * 0.0004,
                    longitude: -105,
                    altitude: 100 - Double(index), speed: 8,
                    timestamp: base.addingTimeInterval(Double(index)))
            }
            return RoutePoint(
                latitude: 40.002,
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

        let sections = TrailRouteMatcher().matchingSections(
            for: route,
            trails: [firstTrail, secondTrail])

        XCTAssertEqual(sections.map(\.trailID), [firstTrail.id, secondTrail.id])
        guard sections.count == 2 else { return }
        XCTAssertLessThanOrEqual(sections[0].endIndex, sections[1].startIndex + 1)
    }

    func testTrailMatcherAttributesSharedStretchToTheCloserParallelTrail() {
        let base = Date(timeIntervalSince1970: 1_400)
        func points(startLatitude: Double, longitude: Double, count: Int) -> [RoutePoint] {
            (0..<count).map { index in
                RoutePoint(
                    latitude: startLatitude + Double(index) * 0.0001,
                    longitude: longitude,
                    altitude: 100 - Double(index), speed: 8,
                    timestamp: base.addingTimeInterval(Double(index)))
            }
        }

        // The rider runs along the middle of a long trail.
        let route = points(startLatitude: 40.0005, longitude: -105, count: 11)
        let riddenTrail = Trail(name: "Ridden", difficulty: .green, resort: "Test")
        let riddenPass = TrailPass(routePoints: points(startLatitude: 40.0000, longitude: -105, count: 21))
        riddenPass.trail = riddenTrail
        riddenTrail.passes.append(riddenPass)

        // A trail of the ride's exact length runs parallel 22 m away. It
        // scores higher because the ride covers its whole length, but the
        // rider was never on it.
        let neighborTrail = Trail(name: "Neighbor", difficulty: .blue, resort: "Test")
        let neighborPass = TrailPass(
            routePoints: points(
                startLatitude: 40.0005,
                longitude: -105.0003, count: 11))
        neighborPass.trail = neighborTrail
        neighborTrail.passes.append(neighborPass)

        let sections = TrailRouteMatcher().matchingSections(
            for: route,
            trails: [riddenTrail, neighborTrail])

        XCTAssertEqual(sections.map(\.trailID), [riddenTrail.id])
    }

    func testTrailMatcherDoesNotLetAParallelNeighborStealTheRiddenStretch() {
        let base = Date(timeIntervalSince1970: 1_420)
        func points(startLatitude: Double, longitude: Double, count: Int) -> [RoutePoint] {
            (0..<count).map { index in
                RoutePoint(
                    latitude: startLatitude + Double(index) * 0.0001,
                    longitude: longitude,
                    altitude: 100 - Double(index), speed: 8,
                    timestamp: base.addingTimeInterval(Double(index)))
            }
        }

        // The rider is exactly on the short trail, with a long centerline
        // running parallel 22 m away.
        let route = points(startLatitude: 40.0005, longitude: -105, count: 11)
        let riddenTrail = Trail(name: "Ridden", difficulty: .blue, resort: "Test")
        let riddenPass = TrailPass(routePoints: points(startLatitude: 40.0005, longitude: -105, count: 11))
        riddenPass.trail = riddenTrail
        riddenTrail.passes.append(riddenPass)

        let neighborTrail = Trail(name: "Neighbor", difficulty: .green, resort: "Test")
        let neighborPass = TrailPass(
            routePoints: points(
                startLatitude: 40.0000,
                longitude: -105.0003, count: 21))
        neighborPass.trail = neighborTrail
        neighborTrail.passes.append(neighborPass)

        let sections = TrailRouteMatcher().matchingSections(
            for: route,
            trails: [riddenTrail, neighborTrail])

        XCTAssertEqual(sections.map(\.trailID), [riddenTrail.id])
    }

    func testTrailMatcherIgnoresAShortTrailTheRiderOnlyPassedNear() {
        let base = Date(timeIntervalSince1970: 1_440)
        let route = (0...20).map { index in
            RoutePoint(
                latitude: 40 + Double(index) * 0.0001, longitude: -105,
                altitude: 100 - Double(index), speed: 8,
                timestamp: base.addingTimeInterval(Double(index)))
        }
        let riddenTrail = Trail(name: "Ridden", difficulty: .blue, resort: "Test")
        let riddenPass = TrailPass(routePoints: route)
        riddenPass.trail = riddenTrail
        riddenTrail.passes.append(riddenPass)

        // A 60 m connector runs parallel 25 m away. It covers ride-length
        // progress, so it scores well without ever being ridden.
        let connectorRoute = (0...6).map { index in
            RoutePoint(
                latitude: 40.0006 + Double(index) * 0.0001, longitude: -105.0003,
                altitude: 100, speed: 0, timestamp: base.addingTimeInterval(Double(index)))
        }
        let connectorTrail = Trail(name: "Connector", difficulty: .doubleBlack, resort: "Test")
        let connectorPass = TrailPass(routePoints: connectorRoute)
        connectorPass.trail = connectorTrail
        connectorTrail.passes.append(connectorPass)

        let sections = TrailRouteMatcher().matchingSections(
            for: route,
            trails: [riddenTrail, connectorTrail])

        XCTAssertEqual(sections.map(\.trailID), [riddenTrail.id])
    }

    func testTrailMatcherRejectsAParallelTieBetweenTwoTrails() {
        let base = Date(timeIntervalSince1970: 1_460)
        func points(startLatitude: Double) -> [RoutePoint] {
            (0...15).map { index in
                RoutePoint(
                    latitude: startLatitude,
                    longitude: -105 + Double(index) * 0.0001,
                    altitude: 100 - Double(index), speed: 8,
                    timestamp: base.addingTimeInterval(Double(index)))
            }
        }

        // The rider runs between two centerlines, both about 18 m away.
        let route = points(startLatitude: 40.0005)
        let north = Trail(name: "North", difficulty: .blue, resort: "Test")
        let northPass = TrailPass(routePoints: points(startLatitude: 40.00066))
        northPass.trail = north
        north.passes.append(northPass)

        let south = Trail(name: "South", difficulty: .black, resort: "Test")
        let southPass = TrailPass(routePoints: points(startLatitude: 40.00034))
        southPass.trail = south
        south.passes.append(southPass)

        let sections = TrailRouteMatcher().matchingSections(for: route, trails: [north, south])

        XCTAssertTrue(sections.isEmpty)
    }

    func testCatalogPassRepairRestoresBundledCenterline() throws {
        let catalog = TrailCatalogRegistry.mountainCreek
        let routes = TrailCatalogImporter.bundledRoutePoints(catalog: catalog)
        let salvationID = TrailCatalogImporter.stableID(for: "salvation-u41zh8", catalog: catalog)
        let geometry = try XCTUnwrap(routes[salvationID])
        let createdAt = Date(timeIntervalSince1970: 3_000)

        // The ride cleaner treats zero-speed centerline points as a dwell and
        // collapses them into straight chords; this is the v10 damage.
        let thinned = RouteCleaner().clean(geometry)
        XCTAssertLessThan(thinned.count, geometry.count)

        let repairs = CatalogPassRepair.repairs(
            inputs: [
                CatalogPassRepairInput(
                    id: UUID(), trailID: salvationID,
                    trailCreatedAt: createdAt,
                    recordedAt: createdAt.addingTimeInterval(5))
            ],
            catalogRoutes: routes
        )
        let repaired = try XCTUnwrap(repairs.first)
        XCTAssertEqual(try RouteCodec.decode(repaired.routeData), geometry)
    }

    func testCatalogPassRepairRestoresAThinnedCenterline() throws {
        let trailID = UUID()
        let createdAt = Date(timeIntervalSince1970: 2_000)
        let catalogRoute = (0...20).map { index in
            RoutePoint(
                latitude: 40 + Double(index) * 0.0001, longitude: -105,
                altitude: 100, speed: 0,
                timestamp: createdAt.addingTimeInterval(Double(index)))
        }
        // What the ride cleaner leaves behind: only the far endpoints.
        let thinned = [catalogRoute[0], catalogRoute[20]]
        let passID = UUID()

        let repairs = CatalogPassRepair.repairs(
            inputs: [
                CatalogPassRepairInput(
                    id: passID, trailID: trailID,
                    trailCreatedAt: createdAt,
                    recordedAt: createdAt.addingTimeInterval(5))
            ],
            catalogRoutes: [trailID: catalogRoute]
        )

        XCTAssertEqual(repairs.count, 1)
        let repaired = try XCTUnwrap(repairs.first)
        XCTAssertEqual(try RouteCodec.decode(repaired.routeData), catalogRoute)
        XCTAssertEqual(
            repaired.distanceMeters,
            RouteMetrics.distance(of: catalogRoute), accuracy: 0.001)

        // A pass recorded long after the trail was created is a rider pass.
        let riderPass = CatalogPassRepair.repairs(
            inputs: [
                CatalogPassRepairInput(
                    id: UUID(), trailID: trailID,
                    trailCreatedAt: createdAt,
                    recordedAt: createdAt.addingTimeInterval(86_400))
            ],
            catalogRoutes: [trailID: catalogRoute]
        )
        XCTAssertTrue(riderPass.isEmpty)
    }

    @MainActor
    func testCatalogPassRepairRebuildsTheTrailAverageDuringMigration() async throws {
        let catalog = TrailCatalogRegistry.mountainCreek
        let routes = TrailCatalogImporter.bundledRoutePoints(catalog: catalog)
        let trailID = TrailCatalogImporter.stableID(for: "salvation-u41zh8", catalog: catalog)
        let geometry = try XCTUnwrap(routes[trailID])
        let damaged = RouteCleaner().clean(geometry)
        XCTAssertLessThan(damaged.count, geometry.count)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self,
            Trail.self, TrailPass.self, LearnedLift.self,
            configurations: configuration)
        let context = ModelContext(container)
        let createdAt = Date(timeIntervalSince1970: 8_000)
        let trail = Trail(
            name: "Salvation", difficulty: .blue,
            resort: catalog.resortName, createdAt: createdAt)
        trail.id = trailID
        let pass = TrailPass(
            routePoints: damaged,
            recordedAt: createdAt.addingTimeInterval(5))
        pass.trail = trail
        trail.passes.append(pass)
        trail.averagedRouteData = try RouteCodec.encode(damaged)
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
        UserDefaults.standard.set("11", forKey: "berms.diagnosticSummaryVersion")
        UserDefaults.standard.set(false, forKey: "berms.recordingActive")

        let recorder = RideRecorder(context: context, watchStateSink: nil)
        recorder.resumeIfNeeded()
        await recorder.migrationTask?.value

        let savedTrail = try XCTUnwrap(context.fetch(FetchDescriptor<Trail>()).first)
        XCTAssertGreaterThan(savedTrail.points.count, damaged.count)
        XCTAssertEqual(savedTrail.points.count, geometry.count)
        let savedFirst = try XCTUnwrap(savedTrail.points.first)
        let expectedFirst = try XCTUnwrap(geometry.first)
        let savedLast = try XCTUnwrap(savedTrail.points.last)
        let expectedLast = try XCTUnwrap(geometry.last)
        XCTAssertEqual(savedFirst.latitude, expectedFirst.latitude, accuracy: 1e-9)
        XCTAssertEqual(savedFirst.longitude, expectedFirst.longitude, accuracy: 1e-9)
        XCTAssertEqual(savedLast.latitude, expectedLast.latitude, accuracy: 1e-9)
        XCTAssertEqual(savedLast.longitude, expectedLast.longitude, accuracy: 1e-9)
    }

    func testRouteCodecRoundTripsPoints() throws {
        let points = [
            RoutePoint(
                latitude: 40.0, longitude: -105.0, altitude: 2_000, speed: 5,
                timestamp: Date(timeIntervalSince1970: 1_000)),
            RoutePoint(
                latitude: 40.001, longitude: -105.002, altitude: 1_900, speed: 8,
                timestamp: Date(timeIntervalSince1970: 1_005)),
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
            RoutePoint(
                latitude: 40, longitude: -105, altitude: 100, speed: 7,
                timestamp: Date(timeIntervalSince1970: 1_000)),
            RoutePoint(
                latitude: 40.001, longitude: -105, altitude: 90, speed: 7,
                timestamp: Date(timeIntervalSince1970: 1_005)),
            RoutePoint(
                latitude: 40.002, longitude: -105, altitude: 80, speed: 7,
                timestamp: Date(timeIntervalSince1970: 1_305)),
            RoutePoint(
                latitude: 40.003, longitude: -105, altitude: 70, speed: 7,
                timestamp: Date(timeIntervalSince1970: 1_310)),
        ]
        let segment = RideSegment(
            kind: .run, startedAt: points[0].timestamp,
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
            RoutePoint(
                latitude: 40, longitude: -105, altitude: 100, speed: 7,
                timestamp: base),
            RoutePoint(
                latitude: 40.001, longitude: -105, altitude: 80, speed: 7,
                timestamp: base.addingTimeInterval(10)),
            RoutePoint(
                latitude: 40.002, longitude: -105, altitude: 60, speed: 7,
                timestamp: base.addingTimeInterval(20)),
        ]
        let secondPass = [
            RoutePoint(
                latitude: 40, longitude: -105.0001, altitude: 100, speed: 7,
                timestamp: base.addingTimeInterval(30)),
            RoutePoint(
                latitude: 40.0008, longitude: -105, altitude: 80, speed: 7,
                timestamp: base.addingTimeInterval(38)),
            RoutePoint(
                latitude: 40.0021, longitude: -105.0001, altitude: 60, speed: 7,
                timestamp: base.addingTimeInterval(48)),
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
        let profile = LearnedLiftProfile(
            id: UUID(),
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
                RoutePoint(
                    latitude: 40 + Double(index) * 0.00001, longitude: -105,
                    altitude: 100, speed: 4, timestamp: base),
                RoutePoint(
                    latitude: 40.01 + Double(index) * 0.00001, longitude: -105,
                    altitude: 300, speed: 4, timestamp: base.addingTimeInterval(60)),
            ]
            let segment = RideSegment(
                kind: .lift, startedAt: points[0].timestamp,
                endedAt: points[1].timestamp,
                routeData: try RouteCodec.encode(points))
            profiles = engine.merge(
                observation: try XCTUnwrap(engine.observations(from: [segment]).first),
                into: profiles)
        }

        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.observationCount, 3)
        XCTAssertEqual(profile.confidence, 1, accuracy: 0.001)
    }

    func testLiftLearningKeepsDistinctLiftsSeparate() {
        let engine = LiftLearningEngine()
        let first = engine.merge(
            observation: (
                bottom: Coordinate(latitude: 40, longitude: -105),
                top: Coordinate(latitude: 40.01, longitude: -105)
            ), into: [])
        let second = engine.merge(
            observation: (
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
            topSpeedMetersPerSecond: 14, metric: .totalAirtime, jumpCount: 4,
            liftCount: 1, longestAirtime: 0.84, totalAirtime: 2.4,
            activityModeRawValue: ActivityMode.ski.rawValue
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BermsActivityAttributes.ContentState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertTrue(decoded.isSkiDay)
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
            run: .init(
                number: 2, distanceMeters: 450, descentMeters: 90, topSpeedMetersPerSecond: 18,
                longestJumpAirtime: 0.84, jumpCount: 2),
            updatedAt: Date(timeIntervalSince1970: 142),
            activityModeRawValue: ActivityMode.ski.rawValue
        )

        XCTAssertEqual(
            try WatchRideCodec.decode(
                WatchRideState.self,
                from: WatchRideCodec.encode(state)), state)
        XCTAssertTrue(state.isSkiDay)
        XCTAssertEqual(
            try WatchRideCodec.decode(
                WatchRideCommand.self,
                from: WatchRideCodec.encode(WatchRideCommand.pause)), .pause)
        XCTAssertEqual(
            try WatchRideCodec.decode(
                WatchRideCommand.self,
                from: WatchRideCodec.encode(WatchRideCommand.finish)), .finish)
        XCTAssertTrue(state.isStale(at: Date(timeIntervalSince1970: 148)))
        XCTAssertFalse(state.isStale(at: Date(timeIntervalSince1970: 146)))
    }

    @MainActor
    func testWatchRestoresCurrentRunWithoutUsingDayTopSpeed() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self,
            Trail.self, TrailPass.self, LearnedLift.self,
            configurations: configuration)
        let context = ModelContext(container)
        let day = RideDay(startedAt: .now.addingTimeInterval(-60))
        let samples = (0..<4).map { index in
            sample(
                at: day.startedAt, index: index, altitude: 100 - Double(index) * 3,
                speed: index == 1 ? 12 : 5, cycling: true)
        }
        day.checkpointKind = "run"
        let jumps = [0.72, 0.4].enumerated().map { index, airtime in
            let takeoff = day.startedAt.addingTimeInterval(Double(index + 1) * 5)
            return JumpEvent(
                takeoffTimestamp: takeoff, landingTimestamp: takeoff.addingTimeInterval(airtime),
                takeoffMonotonicSeconds: 0, landingMonotonicSeconds: airtime)
        }
        day.checkpointData = try JSONEncoder().encode(RecorderCheckpoint(points: samples, jumps: jumps))
        day.maximumSpeedMetersPerSecond = 30
        day.distanceMeters = 8_000
        context.insert(day)
        try context.save()
        let wasRecording = UserDefaults.standard.bool(forKey: "berms.recordingActive")
        defer { UserDefaults.standard.set(wasRecording, forKey: "berms.recordingActive") }
        UserDefaults.standard.set(true, forKey: "berms.recordingActive")
        let recorder = RideRecorder(
            context: context, watchStateSink: nil,
            authorizationOverride: .authorizedAlways)
        recorder.resumeIfNeeded()
        recorder.resumePendingSession()
        let run = try XCTUnwrap(recorder.currentWatchRideState.run)
        XCTAssertEqual(run.number, 1)
        XCTAssertEqual(run.topSpeedMetersPerSecond, 12)
        XCTAssertEqual(run.jumpCount, 2)
        XCTAssertEqual(recorder.currentRunMetrics, run)
        XCTAssertEqual(try XCTUnwrap(run.longestJumpAirtime), 0.72, accuracy: 0.001)
        XCTAssertEqual(recorder.currentSpeed, 5)
        XCTAssertEqual(run.descentMeters, 9)
        XCTAssertLessThan(run.distanceMeters, 100)
        _ = recorder.stop()
        XCTAssertNil(recorder.currentWatchRideState.run)
    }

    func testWatchRideStateDecodesLegacyPayloadWithoutVersion() throws {
        let payload = Data(
            """
            {"status":"recording","rideID":"ride-1","phase":"run","elapsedSeconds":42,
             "distanceMeters":1250,"descentMeters":210,"speedMetersPerSecond":12}
            """.utf8)
        let state = try WatchRideCodec.decode(WatchRideState.self, from: payload)
        XCTAssertNil(state.run, "Legacy ride totals must not be presented as run metrics")
        XCTAssertEqual(state.version, 1)
        XCTAssertEqual(state.status, .recording)
        XCTAssertEqual(state.updatedAt, .distantPast)
        XCTAssertTrue(state.isStale(at: Date(timeIntervalSince1970: 10_000)))
    }

    func testWatchRunMetricsDecodesWithoutJumpData() throws {
        let payload = Data(#"{"number":1,"distanceMeters":100,"descentMeters":20,"topSpeedMetersPerSecond":12}"#.utf8)
        let run = try WatchRideCodec.decode(WatchRideState.RunMetrics.self, from: payload)
        XCTAssertNil(run.longestJumpAirtime)
        XCTAssertNil(run.jumpCount)
        XCTAssertEqual(run.topSpeedMetersPerSecond, 12)
    }

    func testWatchCommandRequestDecodesLegacyPayloadWithoutVersion() throws {
        let payload = Data(#"{"command":"pause","rideID":"ride-1"}"#.utf8)
        let request = try WatchRideCodec.decode(WatchRideCommandRequest.self, from: payload)
        XCTAssertEqual(request.version, 1)
        XCTAssertEqual(request.command, .pause)
        XCTAssertEqual(request.rideID, "ride-1")
    }

    @MainActor
    func testManualLaunchPromptsForUnfinishedSession() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self,
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
        let impossible = TrackSample(
            coordinate: Coordinate(latitude: 50, longitude: -110), altitude: 120,
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
        let first = TrackSample(
            coordinate: Coordinate(latitude: 40, longitude: -105), altitude: 100,
            speed: 0.2, timestamp: base)
        let drift = TrackSample(
            coordinate: Coordinate(latitude: 40.0015, longitude: -105), altitude: 100,
            speed: 0.1, timestamp: base.addingTimeInterval(1))
        let recovered = TrackSample(
            coordinate: Coordinate(latitude: 40.00001, longitude: -105), altitude: 100,
            speed: 0.3, timestamp: base.addingTimeInterval(2))

        XCTAssertNotNil(normalizer.normalize(first))
        XCTAssertNil(normalizer.normalize(drift))
        XCTAssertNotNil(normalizer.normalize(recovered))
    }

    func testNormalizerHoldsStablePointThroughStationaryBreak() {
        var normalizer = TrackSampleNormalizer()
        let base = Date(timeIntervalSince1970: 1_250)
        let moving = TrackSample(
            coordinate: Coordinate(latitude: 40, longitude: -105), altitude: 100,
            speed: 8, timestamp: base, isCycling: true)
        let firstStopped = TrackSample(
            coordinate: Coordinate(latitude: 40.0002, longitude: -105.0001), altitude: 99,
            speed: 0, timestamp: base.addingTimeInterval(5), isStationary: true)
        let wanderingStopped = TrackSample(
            coordinate: Coordinate(latitude: 40.0007, longitude: -104.9995), altitude: 95,
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
            RoutePoint(
                latitude: 40.0002, longitude: -105.0001, altitude: 99, speed: 0.2, timestamp: base.addingTimeInterval(5)
            ),
            RoutePoint(
                latitude: 40.0001, longitude: -104.9998, altitude: 99, speed: 0.1,
                timestamp: base.addingTimeInterval(10)),
            RoutePoint(
                latitude: 39.9999, longitude: -105.0001, altitude: 99, speed: 0.1,
                timestamp: base.addingTimeInterval(15)),
            RoutePoint(
                latitude: 40.0005, longitude: -105, altitude: 95, speed: 8, timestamp: base.addingTimeInterval(20)),
        ]

        let cleaned = RouteCleaner().clean(points)

        XCTAssertLessThan(cleaned.count, points.count)
        XCTAssertEqual(cleaned[1].speed, 0, accuracy: 0.001)
    }

    func testRouteCleanerFiltersInaccurateTrackSamples() {
        let base = Date(timeIntervalSince1970: 1_350)
        let samples = [
            TrackSample(
                coordinate: Coordinate(latitude: 40, longitude: -105), altitude: 100,
                speed: 7, horizontalAccuracy: 10, timestamp: base),
            TrackSample(
                coordinate: Coordinate(latitude: 40.0001, longitude: -105), altitude: 99,
                speed: 7, horizontalAccuracy: 120, timestamp: base.addingTimeInterval(5)),
            TrackSample(
                coordinate: Coordinate(latitude: 40.0002, longitude: -105), altitude: 98,
                speed: 7, horizontalAccuracy: 10, timestamp: base.addingTimeInterval(10)),
        ]

        let cleaned = RouteCleaner().clean(samples)

        XCTAssertEqual(cleaned.count, 2)
        XCTAssertTrue(cleaned.allSatisfy { $0.horizontalAccuracy <= 80 })
    }

    func testAutomotiveAscentIsNotCalledALift() {
        let detector = ParkLapDetector()
        let base = Date(timeIntervalSince1970: 1_000)
        for index in 0..<5 {
            let point = sample(
                at: base, index: index, altitude: Double(index * 8), speed: 12,
                cycling: false, automotive: true)
            XCTAssertTrue(detector.process(point).isEmpty)
        }
        XCTAssertEqual(detector.phase, .idle)
    }

    func testDescendingMovementCanStartRunWithoutCyclingActivity() {
        let detector = ParkLapDetector()
        let base = Date(timeIntervalSince1970: 1_000)
        for index in 0..<5 {
            _ = detector.process(
                sample(
                    at: base, index: index, altitude: 100 - Double(index * 4),
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
            events += detector.process(
                sample(
                    at: base, index: index + 10,
                    altitude: Double(100 - index * 5), speed: 7, cycling: true))
        }
        XCTAssertEqual(detector.phase, .run)
        XCTAssertTrue(
            events.contains {
                if case .started(kind: .run, points: _) = $0 { return true }
                return false
            })
    }

    func testDetectorTransitionsAtOneSecondGPSCadence() {
        let detector = ParkLapDetector()
        let base = Date(timeIntervalSince1970: 1_800)
        var events: [DetectorEvent] = []

        for index in 0...15 {
            events += detector.process(
                sample(
                    at: base, index: index, altitude: Double(index), speed: 4,
                    cycling: false, interval: 1))
        }
        XCTAssertEqual(detector.phase, .lift)

        for index in 16...34 {
            events += detector.process(
                sample(
                    at: base, index: index,
                    altitude: 16 - Double(index - 16), speed: 8,
                    cycling: true, interval: 1))
        }
        XCTAssertEqual(detector.phase, .run)
        XCTAssertTrue(
            events.contains { event in
                if case .finished(let draft) = event { return draft.kind == .lift }
                return false
            })
        XCTAssertTrue(
            events.contains { event in
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
        configuration.minimumAirtime = 0.12
        configuration.cooldown = 1
        let detector = JumpDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 2_000)
        var detected: [JumpEvent] = []

        for index in 0..<10 {
            detected += detector.process(
                motion(at: Double(index) * 0.04, forceG: 1),
                context: runContext(at: Double(index) * 0.04, base: base)
            )
            .compactMap { event in
                if case .detected(let jump) = event { return jump }
                return nil
            }
        }
        for index in 10..<15 {
            detected += detector.process(
                motion(at: Double(index) * 0.04, forceG: 0.2),
                context: runContext(at: Double(index) * 0.04, base: base)
            )
            .compactMap { event in
                if case .detected(let jump) = event { return jump }
                return nil
            }
        }
        detected += detector.process(
            motion(at: 0.60, forceG: 1.8),
            context: runContext(at: 0.60, base: base)
        )
        .compactMap { event in
            if case .detected(let jump) = event { return jump }
            return nil
        }
        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected[0].airtime, 0.20, accuracy: 0.001)

        for index in 16..<25 {
            let events = detector.process(
                motion(at: Double(index) * 0.04, forceG: 0.2),
                context: runContext(at: Double(index) * 0.04, base: base))
            XCTAssertFalse(
                events.contains {
                    if case .detected = $0 { return true }
                    return false
                })
        }
    }

    /// A brief unweighting must not stretch into a long airtime: ordinary
    /// riding force before the impact ends the candidate.
    func testJumpDetectorDoesNotStretchAirtimeThroughOrdinaryRiding() {
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        let detector = JumpDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 2_400)
        var detected: [JumpEvent] = []
        var rejectionReasons: [String] = []

        func feed(at seconds: Double, forceG: Double) {
            for event in detector.process(
                motion(at: seconds, forceG: forceG, base: base),
                context: runContext(at: seconds, base: base))
            {
                switch event {
                case .detected(let jump): detected.append(jump)
                case .diagnostic(kind: "jump_candidate_rejected", _, _, let detail):
                    rejectionReasons.append(detail)
                case .diagnostic: break
                }
            }
        }

        for step in 0..<9 {
            feed(at: 0.04 + Double(step) * 0.04, forceG: 0.30)
        }
        for step in 0..<20 {
            feed(at: 0.40 + Double(step) * 0.04, forceG: 1.05)
        }
        feed(at: 1.20, forceG: 1.40)

        XCTAssertTrue(detected.isEmpty, "riding force must end the airborne candidate")
        XCTAssertTrue(
            rejectionReasons.contains("force_recovered_before_landing"),
            "expected the window to end when force recovered, got \(rejectionReasons)")
    }

    func testJumpDetectorDetectsSustainedLowForceWithDefaultAirtime() {
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        let detector = JumpDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 2_600)
        var detected: [JumpEvent] = []

        _ = detector.process(
            motion(at: 0, forceG: 1, base: base),
            context: runContext(at: 0, base: base))
        for step in 0..<12 {
            for event in detector.process(
                motion(at: 0.04 + Double(step) * 0.04, forceG: 0.30, base: base),
                context: runContext(at: 0.04 + Double(step) * 0.04, base: base))
            {
                if case .detected(let jump) = event { detected.append(jump) }
            }
        }
        for event in detector.process(
            motion(at: 0.52, forceG: 1.60, base: base),
            context: runContext(at: 0.52, base: base))
        {
            if case .detected(let jump) = event { detected.append(jump) }
        }

        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.airtime ?? .nan, 0.48, accuracy: 0.001)
    }

    func testJumpDetectorRejectsShortUnloadAndHighRotation() {
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        configuration.minimumAirtime = 0.12
        let detector = JumpDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 3_000)
        _ = detector.process(motion(at: 0, forceG: 1), context: runContext(at: 0, base: base))
        _ = detector.process(motion(at: 0.04, forceG: 0.2), context: runContext(at: 0.04, base: base))
        let shortEvents = detector.process(motion(at: 0.08, forceG: 1.8), context: runContext(at: 0.08, base: base))
        XCTAssertTrue(
            shortEvents.contains {
                if case .diagnostic(kind: "jump_candidate_rejected", _, _, let detail) = $0 {
                    return detail == "airtime_too_short"
                }
                return false
            })

        _ = detector.process(motion(at: 2, forceG: 1), context: runContext(at: 2, base: base))
        _ = detector.process(motion(at: 2.04, forceG: 1), context: runContext(at: 2.04, base: base))
        _ = detector.process(motion(at: 2.08, forceG: 0.2, rotation: 9), context: runContext(at: 2.08, base: base))
        _ = detector.process(motion(at: 2.20, forceG: 0.2, rotation: 9), context: runContext(at: 2.20, base: base))
        let rotationEvents = detector.process(
            motion(at: 2.24, forceG: 1.8, rotation: 9), context: runContext(at: 2.24, base: base))
        XCTAssertTrue(
            rotationEvents.contains {
                if case .diagnostic(kind: "jump_candidate_rejected", _, _, let detail) = $0 {
                    return detail == "airborne_rotation_too_high"
                }
                return false
            })
    }

    func testJumpDetectorRequiresRunAndRejectsMotionGap() {
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        let detector = JumpDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 4_000)
        let notRun = JumpTrackContext(
            timestamp: base, monotonicSeconds: 0, speed: 8, altitude: 100,
            phase: .lift, isStationary: false, isAutomotive: false)
        XCTAssertTrue(detector.process(motion(at: 0, forceG: 0.2), context: notRun).isEmpty)

        _ = detector.process(motion(at: 1, forceG: 1), context: runContext(at: 1, base: base))
        _ = detector.process(motion(at: 1.04, forceG: 1), context: runContext(at: 1.04, base: base))
        _ = detector.process(motion(at: 1.08, forceG: 1), context: runContext(at: 1.08, base: base))
        _ = detector.process(motion(at: 1.12, forceG: 0.2), context: runContext(at: 1.12, base: base))
        let events = detector.process(motion(at: 1.48, forceG: 0.2), context: runContext(at: 1.48, base: base))
        XCTAssertTrue(
            events.contains {
                if case .diagnostic(kind: "jump_candidate_rejected", _, _, let detail) = $0 {
                    return detail.hasPrefix("motion_gap_")
                }
                return false
            })
    }

    func testJumpDetectorRejectsImpactWithoutAirborneAndStaleOrSlowContext() {
        var configuration = JumpDetector.Configuration()
        configuration.minimumRunContextSeconds = 0
        let detector = JumpDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 4_500)

        _ = detector.process(motion(at: 0, forceG: 1), context: runContext(at: 0, base: base))
        let impact = detector.process(motion(at: 0.04, forceG: 1.8), context: runContext(at: 0.04, base: base))
        XCTAssertFalse(
            impact.contains {
                if case .detected = $0 { return true }
                return false
            })

        _ = detector.process(motion(at: 0.08, forceG: 0.2), context: runContext(at: 0.08, base: base, speed: 1))
        let slowLanding = detector.process(
            motion(at: 0.24, forceG: 1.8), context: runContext(at: 0.24, base: base, speed: 1))
        XCTAssertFalse(
            slowLanding.contains {
                if case .detected = $0 { return true }
                return false
            })

        _ = detector.process(motion(at: 1, forceG: 1), context: runContext(at: 1, base: base))
        _ = detector.process(motion(at: 1.04, forceG: 0.2), context: runContext(at: 1.04, base: base))
        let stale = detector.process(motion(at: 4, forceG: 1.8), context: runContext(at: 1, base: base))
        XCTAssertFalse(
            stale.contains {
                if case .detected = $0 { return true }
                return false
            })
    }

    func testRawDiagnosticRecordDecodesLegacyLine() throws {
        let legacy =
            "{\"kind\":\"detector_input\",\"timestamp\":\"1970-01-01T00:16:40Z\",\"monotonicSeconds\":1,\"accepted\":true,\"phaseAfter\":\"run\"}"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(RawDiagnosticRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(record.kind, "detector_input")
        XCTAssertNil(record.fusedAltitude)
        XCTAssertNil(record.jumpAirtime)
    }

    func testJumpLogReplayUsesRecordedMotionAndTrackContext() throws {
        let base = Date(timeIntervalSince1970: 5_000)
        var records = [
            RawDiagnosticRecord(
                kind: "detector_input", timestamp: base,
                monotonicSeconds: 0, fusedAltitude: 100,
                trackMonotonicSeconds: 0, speed: 8,
                stationary: false, automotive: false,
                runEligible: true, accepted: true,
                phaseAfter: "run")
        ]
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
        configuration.minimumAirtime = 0.12
        let result = try JumpLogReplayer().replay(data: data, configuration: configuration)
        XCTAssertEqual(result.jumps.count, 1)
        XCTAssertEqual(result.jumps[0].airtime, 0.20, accuracy: 0.001)
    }

    func testJumpLogReplayResetsAcrossPauseBoundary() throws {
        let base = Date(timeIntervalSince1970: 5_500)
        var records = [
            RawDiagnosticRecord(
                kind: "detector_input", timestamp: base,
                monotonicSeconds: 0, fusedAltitude: 100,
                trackMonotonicSeconds: 0, speed: 8,
                stationary: false, automotive: false,
                runEligible: true, accepted: true,
                phaseAfter: "run")
        ]
        for index in 0..<10 {
            records.append(rawMotionRecord(at: Double(index) * 0.04, base: base, forceG: 1))
        }
        for index in 10..<15 {
            records.append(rawMotionRecord(at: Double(index) * 0.04, base: base, forceG: 0.2))
        }
        records.append(
            RawDiagnosticRecord(
                kind: "session_paused", timestamp: base.addingTimeInterval(0.58),
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
        configuration.minimumAirtime = 0.12
        let result = try JumpLogReplayer().replay(data: data, configuration: configuration)
        XCTAssertTrue(result.jumps.isEmpty)
    }

    func testCheckpointDecodesNewAndLegacyFormats() throws {
        let point = sample(at: Date(timeIntervalSince1970: 6_000), index: 0, altitude: 100, speed: 8, cycling: true)
        let jump = JumpEvent(
            takeoffTimestamp: point.timestamp, landingTimestamp: point.timestamp.addingTimeInterval(0.2),
            takeoffMonotonicSeconds: 1, landingMonotonicSeconds: 1.2)
        let checkpoint = try JSONDecoder().decode(
            RecorderCheckpoint.self,
            from: JSONEncoder().encode(RecorderCheckpoint(points: [point], jumps: [jump])))
        XCTAssertEqual(checkpoint.jumps.count, 1)
        let legacy = try JSONDecoder().decode([TrackSample].self, from: JSONEncoder().encode([point]))
        XCTAssertEqual(legacy, [point])
    }

    @MainActor
    func testSavedRoutesAndTrailPassesRepairDuringMigration() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self,
            Trail.self, TrailPass.self, LearnedLift.self,
            configurations: configuration)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 7_500)
        let route = [
            RoutePoint(latitude: 40, longitude: -105, altitude: 100, speed: 8, timestamp: base),
            RoutePoint(
                latitude: 40.0002, longitude: -105.0001, altitude: 99, speed: 0.2, timestamp: base.addingTimeInterval(5)
            ),
            RoutePoint(
                latitude: 40.0001, longitude: -104.9998, altitude: 99, speed: 0.1,
                timestamp: base.addingTimeInterval(10)),
            RoutePoint(
                latitude: 39.9999, longitude: -105.0001, altitude: 99, speed: 0.1,
                timestamp: base.addingTimeInterval(15)),
            RoutePoint(
                latitude: 40.0005, longitude: -105, altitude: 95, speed: 8, timestamp: base.addingTimeInterval(20)),
        ]
        let day = RideDay(startedAt: base)
        day.endedAt = base.addingTimeInterval(30)
        let segment = RideSegment(
            kind: .run, startedAt: base, endedAt: base.addingTimeInterval(20),
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

        let recorder = RideRecorder(context: context, watchStateSink: nil)
        recorder.resumeIfNeeded()
        await recorder.migrationTask?.value

        let savedSegment = try XCTUnwrap(context.fetch(FetchDescriptor<RideSegment>()).first)
        XCTAssertLessThan(savedSegment.points.count, route.count)
        XCTAssertGreaterThan(savedSegment.distanceMeters, 0)
        // Trail passes hold centerlines; the migration must not re-clean them
        // with the ride cleaner and collapse them into straight chords.
        let savedPass = try XCTUnwrap(context.fetch(FetchDescriptor<TrailPass>()).first)
        XCTAssertEqual(savedPass.points.count, route.count)
        XCTAssertGreaterThan(savedPass.distanceMeters, 0)
    }

    @MainActor
    func testSwiftDataPersistsDayAndCascadeSegment() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideDay.self, RideSegment.self, configurations: configuration)
        let context = ModelContext(container)
        let day = RideDay(startedAt: Date(timeIntervalSince1970: 1_000))
        let jump = JumpEvent(
            takeoffTimestamp: day.startedAt, landingTimestamp: day.startedAt.addingTimeInterval(0.2),
            takeoffMonotonicSeconds: 1, landingMonotonicSeconds: 1.2)
        let segment = RideSegment(
            kind: .run, startedAt: day.startedAt, endedAt: day.startedAt.addingTimeInterval(20),
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
        XCTAssertFalse(day.hasNotes)

        day.setName("  Powder laps  ")
        day.setNotes("  Fresh snow  ")
        XCTAssertEqual(day.name, "Powder laps")
        XCTAssertEqual(day.notes, "Fresh snow")
        XCTAssertTrue(day.hasCustomName)
        XCTAssertTrue(day.hasNotes)
        XCTAssertEqual(day.displayName, "Powder laps")

        context.insert(day)
        try context.save()

        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<RideDay>()).first)
        XCTAssertEqual(saved.name, "Powder laps")
        XCTAssertEqual(saved.notes, "Fresh snow")
        XCTAssertEqual(saved.displayName, "Powder laps")

        saved.setName("  \n  ")
        saved.setNotes("  \n  ")
        try context.save()

        let cleared = try XCTUnwrap(context.fetch(FetchDescriptor<RideDay>()).first)
        XCTAssertNil(cleared.name)
        XCTAssertNil(cleared.notes)
        XCTAssertFalse(cleared.hasCustomName)
        XCTAssertFalse(cleared.hasNotes)
        XCTAssertEqual(cleared.displayName, fallback)
    }

    @MainActor
    func testRecorderLunchResumeAndFinishPersistSummary() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideDay.self, RideSegment.self, configurations: configuration)
        let context = ModelContext(container)
        let recorder = RideRecorder(
            context: context,
            watchStateSink: nil,
            authorizationOverride: .authorizedAlways)
        let wasRecording = UserDefaults.standard.bool(forKey: "berms.recordingActive")
        defer { UserDefaults.standard.set(wasRecording, forKey: "berms.recordingActive") }
        XCTAssertTrue(recorder.start())
        let day = try XCTUnwrap(recorder.activeDay)
        let run = RideSegment(
            kind: .run, startedAt: day.startedAt,
            endedAt: day.startedAt.addingTimeInterval(180), routeData: Data())
        run.jumpData = try JSONEncoder().encode([
            JumpEvent(
                takeoffTimestamp: day.startedAt, landingTimestamp: day.startedAt.addingTimeInterval(0.8),
                takeoffMonotonicSeconds: 0, landingMonotonicSeconds: 0.8)
        ])
        run.distanceMeters = 1_200
        run.verticalMeters = 250
        run.maximumSpeedMetersPerSecond = 12
        run.day = day
        day.segments.append(run)
        context.insert(run)
        let lift = RideSegment(
            kind: .lift, startedAt: day.startedAt,
            endedAt: day.startedAt.addingTimeInterval(300), routeData: Data())
        lift.maximumSpeedMetersPerSecond = 15
        lift.day = day
        day.segments.append(lift)
        context.insert(lift)

        XCTAssertEqual(recorder.currentWatchRideState.run?.topSpeedMetersPerSecond, 12)
        XCTAssertEqual(recorder.currentWatchRideState.run?.distanceMeters, 1_200)
        XCTAssertEqual(recorder.currentRunMetrics?.jumpCount, 1)
        XCTAssertEqual(try XCTUnwrap(recorder.currentWatchRideState.run?.longestJumpAirtime), 0.8, accuracy: 0.001)
        let newerRun = RideSegment(
            kind: .run, startedAt: day.startedAt.addingTimeInterval(400),
            endedAt: day.startedAt.addingTimeInterval(500), routeData: Data())
        newerRun.maximumSpeedMetersPerSecond = 8
        newerRun.distanceMeters = 400
        newerRun.verticalMeters = 80
        newerRun.day = day
        day.segments.insert(newerRun, at: 0)
        context.insert(newerRun)
        XCTAssertEqual(recorder.currentWatchRideState.run?.number, 2)
        XCTAssertEqual(
            recorder.currentWatchRideState.run?.topSpeedMetersPerSecond, 8,
            "Watch must show the latest run, not the fastest run or lift")
        XCTAssertEqual(recorder.currentWatchRideState.run?.distanceMeters, 400)
        XCTAssertEqual(recorder.currentRunMetrics?.jumpCount, 0)
        XCTAssertEqual(
            recorder.currentWatchRideState.run?.longestJumpAirtime, 0,
            "A run without jumps must not inherit an earlier run’s best jump")
        day.segments.removeAll { $0.id == newerRun.id }
        context.delete(newerRun)

        XCTAssertTrue(recorder.pause())
        XCTAssertEqual(recorder.currentWatchRideState.run?.topSpeedMetersPerSecond, 12)
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
    func testLiveActivityOpenKeepsAutoRestoredRide() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideDay.self, RideSegment.self, configurations: configuration)
        let context = ModelContext(container)
        let day = RideDay(startedAt: Date(timeIntervalSince1970: 2_000))
        context.insert(day)
        try context.save()

        let previousRecordingState = UserDefaults.standard.bool(forKey: "berms.recordingActive")
        defer { UserDefaults.standard.set(previousRecordingState, forKey: "berms.recordingActive") }
        UserDefaults.standard.set(true, forKey: "berms.recordingActive")

        let recorder = RideRecorder(
            context: context,
            watchStateSink: nil,
            authorizationOverride: .authorizedAlways)
        recorder.resumeIfNeeded(autoResume: true)
        XCTAssertTrue(recorder.isRecording)

        recorder.handleLiveActivityOpen()

        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RideDay>()), 1)
        XCTAssertNotNil(recorder.stop())
    }

    @MainActor
    func testRecorderStartAndStopSurvivesMotionCallbacks() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self,
            Trail.self, TrailPass.self,
            configurations: configuration)
        let recorder = RideRecorder(
            context: ModelContext(container),
            watchStateSink: nil,
            authorizationOverride: .authorizedAlways)
        let previousRecordingState = UserDefaults.standard.bool(forKey: "berms.recordingActive")
        defer { UserDefaults.standard.set(previousRecordingState, forKey: "berms.recordingActive") }

        XCTAssertTrue(recorder.start())
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
        let oldSegment = RideSegment(
            kind: .lift, startedAt: base, endedAt: base.addingTimeInterval(20),
            routeData: Data([1, 2, 3]))
        let oldRun = RideSegment(
            kind: .run, startedAt: base.addingTimeInterval(20),
            endedAt: base.addingTimeInterval(60), routeData: Data([1, 2, 3]))
        oldSegment.day = day
        oldRun.day = day
        day.segments.append(oldSegment)
        day.segments.append(oldRun)
        context.insert(day)
        context.insert(oldSegment)
        context.insert(oldRun)
        try context.save()

        var records = [RawDiagnosticRecord(kind: "session_started", timestamp: base, monotonicSeconds: 0)]
        for index in 0...4 {
            let seconds = Double(index) * 5
            records.append(
                RawDiagnosticRecord(
                    kind: "detector_input", timestamp: base.addingTimeInterval(seconds),
                    monotonicSeconds: seconds, latitude: 40 + Double(index) * 0.0001,
                    longitude: -105, fusedAltitude: Double(index * 5),
                    trackMonotonicSeconds: seconds, speed: 4, horizontalAccuracy: 5,
                    stationary: false, cycling: false, automotive: false, accepted: true
                ))
        }
        for index in 1...5 {
            let seconds = 20 + Double(index) * 5
            records.append(
                RawDiagnosticRecord(
                    kind: "detector_input", timestamp: base.addingTimeInterval(seconds),
                    monotonicSeconds: seconds, latitude: 40.001 + Double(index) * 0.0001,
                    longitude: -105, fusedAltitude: Double(20 - index * 5),
                    trackMonotonicSeconds: seconds, speed: 7, horizontalAccuracy: 5,
                    stationary: false, cycling: false, automotive: false, accepted: true
                ))
        }
        records.append(
            RawDiagnosticRecord(
                kind: "session_stopped", timestamp: base.addingTimeInterval(60),
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

    func testDiagnosticReplaySkipsMalformedLines() throws {
        let contents = """
            {"kind":"session_started","timestamp":7000,"monotonicSeconds":0}
            not json at all
            {"kind":"detector_input","timestamp":7001,"monotonicSeconds":1,"latitude":40,"longitude":-105,
             "fusedAltitude":100,"trackMonotonicSeconds":1,"speed":7,"horizontalAccuracy":5,"accepted":true}
            """
        let result = try DiagnosticLogReplayer().replay(contents: contents)
        XCTAssertNotNil(result)
    }

    func testDiagnosticReplayParsesJumpSensitivity() {
        XCTAssertEqual(DiagnosticLogReplayer.sensitivity(from: "sensitivity=high,summary"), .high)
        XCTAssertEqual(DiagnosticLogReplayer.sensitivity(from: "sensitivity=low"), .low)
        XCTAssertNil(DiagnosticLogReplayer.sensitivity(from: nil))
        XCTAssertNil(DiagnosticLogReplayer.sensitivity(from: "no hint here"))
    }

    func testBermsDataExportCarriesParsedRunNumbers() throws {
        let base = Date(timeIntervalSince1970: 10_000)
        let route = [
            RoutePoint(
                latitude: 40, longitude: -105, altitude: 100, speed: 5,
                timestamp: base),
            RoutePoint(
                latitude: 40.001, longitude: -105, altitude: 90, speed: 8,
                timestamp: base.addingTimeInterval(10)),
        ]
        let routeData = try RouteCodec.encode(route)
        let day = RideDay(startedAt: base)
        let jump = JumpEvent(
            takeoffTimestamp: base.addingTimeInterval(1.25),
            landingTimestamp: base.addingTimeInterval(1.75),
            takeoffMonotonicSeconds: 1.25,
            landingMonotonicSeconds: 1.75)
        let firstRun = RideSegment(
            kind: .run, startedAt: base,
            endedAt: base.addingTimeInterval(10), routeData: routeData, jumps: [jump])
        let lift = RideSegment(
            kind: .lift, startedAt: base.addingTimeInterval(20),
            endedAt: base.addingTimeInterval(30), routeData: routeData)
        let secondRun = RideSegment(
            kind: .run, startedAt: base.addingTimeInterval(40),
            endedAt: base.addingTimeInterval(50), routeData: routeData)
        day.segments = [firstRun, lift, secondRun]

        let export = BermsDataExport(
            day: day, exportedAt: base,
            rawDiagnosticsFilename: "Berms-day.jsonl")
        XCTAssertEqual(export.version, 6)
        XCTAssertEqual(export.days[0].segments.compactMap(\.runNumber), [1, 2])
        XCTAssertEqual(export.parsed.runCount, 2)
        XCTAssertEqual(export.parsed.runs.map(\.number), [1, 2])
        XCTAssertEqual(export.rawDiagnostics?.filename, "Berms-day.jsonl")

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional.string(from: date))
        }
        let data = try encoder.encode(export)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad date \(value)")
            }
            return date
        }
        let decoded = try decoder.decode(BermsDataExport.self, from: data)
        XCTAssertEqual(decoded.parsed.runs.map(\.segmentID), export.parsed.runs.map(\.segmentID))
        // Jump timestamps and airtime must survive the round trip together.
        let decodedJump = try XCTUnwrap(decoded.days[0].segments.first?.jumps.first)
        XCTAssertEqual(
            decodedJump.takeoffAt.timeIntervalSince(base), 1.25, accuracy: 0.001)
        XCTAssertEqual(
            decodedJump.landingAt.timeIntervalSince(decodedJump.takeoffAt), 0.5, accuracy: 0.001)
    }

    func testDiagnosticSummaryRebuildCombinesLogsInChronologicalOrder() throws {
        let dayID = UUID()
        let base = Date(timeIntervalSince1970: 11_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        func writeLog(start: Date) throws -> URL {
            let records = [
                RawDiagnosticRecord(kind: "session_started", timestamp: start, monotonicSeconds: 0),
                RawDiagnosticRecord(
                    kind: "detector_started", timestamp: start.addingTimeInterval(1),
                    monotonicSeconds: 1, phaseAfter: "run", detail: "Run"),
                RawDiagnosticRecord(
                    kind: "detector_input", timestamp: start.addingTimeInterval(1),
                    monotonicSeconds: 1, latitude: 40, longitude: -105,
                    fusedAltitude: 100, trackMonotonicSeconds: 1, speed: 5,
                    horizontalAccuracy: 5, accepted: true),
                RawDiagnosticRecord(
                    kind: "detector_input", timestamp: start.addingTimeInterval(2),
                    monotonicSeconds: 2, latitude: 40.001, longitude: -105,
                    fusedAltitude: 90, trackMonotonicSeconds: 2, speed: 5,
                    horizontalAccuracy: 5, accepted: true),
                RawDiagnosticRecord(
                    kind: "detector_finished", timestamp: start.addingTimeInterval(3),
                    monotonicSeconds: 3, phaseBefore: "run", detail: "Run"),
                RawDiagnosticRecord(
                    kind: "session_stopped", timestamp: start.addingTimeInterval(4),
                    monotonicSeconds: 4),
            ]
            var data = Data()
            for record in records {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("berms-rebuild-\(UUID().uuidString).jsonl")
            try data.write(to: url)
            return url
        }

        let firstURL = try writeLog(start: base)
        let secondURL = try writeLog(start: base.addingTimeInterval(20))
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let summary = try XCTUnwrap(
            DiagnosticSummaryRebuilder.rebuild(dayID: dayID, logURLs: [secondURL, firstURL])
        )
        XCTAssertEqual(summary.segments.filter { $0.kind == .run }.count, 2)
        XCTAssertEqual(summary.segments.compactMap(\.runNumber), [1, 2])
        XCTAssertEqual(
            summary.segments.map(\.startedAt),
            [
                base.addingTimeInterval(1),
                base.addingTimeInterval(21),
            ])
    }

    func testLearnedEndpointBufferedPointsReturnToRoute() {
        let profile = LearnedLiftProfile(
            id: UUID(),
            bottom: Coordinate(latitude: 40.0, longitude: -105.0),
            top: Coordinate(latitude: 40.01, longitude: -105.0),
            bottomRadius: 50,
            topRadius: 50,
            observationCount: 3,
            confidence: 1
        )
        var configuration = ParkLapDetector.Configuration()
        configuration.learnedLifts = [profile]
        let detector = ParkLapDetector(configuration: configuration)
        let base = Date(timeIntervalSince1970: 9_000)
        detector.restore(
            kind: .run,
            points: [
                TrackSample(
                    coordinate: Coordinate(latitude: 40.0, longitude: -105.0001),
                    altitude: 100, speed: 7, timestamp: base)
            ])

        var dwellTimestamps: [Date] = []
        for t in 1...3 {
            let sample = TrackSample(
                coordinate: Coordinate(latitude: 40.0, longitude: -105.0),
                altitude: 100, speed: 0.5,
                timestamp: base.addingTimeInterval(Double(t)))
            dwellTimestamps.append(sample.timestamp)
            _ = detector.process(sample)
        }
        XCTAssertFalse(
            dwellTimestamps.allSatisfy { timestamp in
                detector.currentPoints.contains { $0.timestamp == timestamp }
            })

        _ = detector.process(
            TrackSample(
                coordinate: Coordinate(latitude: 40.02, longitude: -105.0),
                altitude: 95, speed: 7,
                timestamp: base.addingTimeInterval(4)))

        XCTAssertTrue(
            dwellTimestamps.allSatisfy { timestamp in
                detector.currentPoints.contains { $0.timestamp == timestamp }
            })
    }

    func testJumpMetricsResolveLengthDropAndAirHeightFromRoute() throws {
        let base = Date(timeIntervalSince1970: 40_000)
        let route = (0...10).map { index in
            RoutePoint(
                latitude: 50 + Double(index) * 0.00009,
                longitude: -122.9,
                altitude: 100 - Double(index),
                speed: 9,
                timestamp: base.addingTimeInterval(Double(index)))
        }
        let jump = JumpEvent(
            takeoffTimestamp: base.addingTimeInterval(2),
            landingTimestamp: base.addingTimeInterval(2.5),
            takeoffMonotonicSeconds: 2,
            landingMonotonicSeconds: 2.5)

        let resolved = jump.resolved(in: route)
        let metrics = try XCTUnwrap(resolved.metrics)
        // Half a second at roughly 10 m/s per latitude step.
        XCTAssertEqual(metrics.lengthMeters, 5, accuracy: 0.6)
        XCTAssertEqual(metrics.dropMeters, 0.5, accuracy: 0.05)
        // Height is the arc's rise plus the measured drop to the landing.
        XCTAssertEqual(
            metrics.heightMeters,
            JumpMetrics.airHeight(airtime: 0.5, dropMeters: 0.5) + 0.5,
            accuracy: 0.001)
        XCTAssertEqual(resolved.resolved(in: []), resolved, "Resolving is idempotent")
    }

    func testNormalizerPreservesBarometerAltitudeForJumpDrops() {
        var normalizer = TrackSampleNormalizer()
        let base = Date(timeIntervalSince1970: 95_000)
        func sample(altitude: Double, at seconds: Double) -> TrackSample {
            TrackSample(
                coordinate: Coordinate(latitude: 50 + seconds * 0.00009, longitude: -122.9),
                altitude: altitude, speed: 8, timestamp: base.addingTimeInterval(seconds))
        }

        XCTAssertNotNil(normalizer.normalize(sample(altitude: 100, at: 0), smoothAltitude: false))
        let dropped = normalizer.normalize(sample(altitude: 98, at: 1), smoothAltitude: false)
        XCTAssertEqual(dropped?.altitude ?? 0, 98, accuracy: 0.001)

        var smoothingNormalizer = TrackSampleNormalizer()
        XCTAssertNotNil(smoothingNormalizer.normalize(sample(altitude: 100, at: 10)))
        let smoothed = smoothingNormalizer.normalize(sample(altitude: 98, at: 11))
        XCTAssertEqual(smoothed?.altitude ?? 0, 99.4, accuracy: 0.001)
    }

    func testJumpAirHeightFollowsBallisticModel() {
        // A level landing peaks at g * t^2 / 8.
        let level = JumpMetrics.airHeight(airtime: 0.9, dropMeters: 0)
        XCTAssertEqual(level, 9.80665 * 0.9 * 0.9 / 8, accuracy: 0.01)
        // Landing below takeoff means less air for the same flight time.
        XCTAssertLessThan(JumpMetrics.airHeight(airtime: 0.9, dropMeters: 2), level)
        // A pure drop-off never reports negative height.
        XCTAssertEqual(JumpMetrics.airHeight(airtime: 0.4, dropMeters: 5), 0)
    }

    func testJumpMetricsStepUpSubtractsTheClimbToTheLanding() throws {
        let base = Date(timeIntervalSince1970: 41_000)
        let route = [
            RoutePoint(
                latitude: 50, longitude: -122.9, altitude: 100, speed: 9,
                timestamp: base),
            RoutePoint(
                latitude: 50, longitude: -122.9, altitude: 101, speed: 9,
                timestamp: base.addingTimeInterval(1)),
        ]
        let jump = JumpEvent(
            takeoffTimestamp: base,
            landingTimestamp: base.addingTimeInterval(0.5),
            takeoffMonotonicSeconds: 0,
            landingMonotonicSeconds: 0.5)

        let metrics = try XCTUnwrap(jump.resolved(in: route).metrics)
        XCTAssertEqual(metrics.dropMeters, -0.5, accuracy: 0.001)
        // The landing sits above the takeoff, so the climb subtracts from the
        // arc instead of being credited as height.
        let arc = JumpMetrics.airHeight(airtime: 0.5, dropMeters: -0.5)
        XCTAssertEqual(metrics.heightMeters, arc - 0.5, accuracy: 0.001)
        XCTAssertLessThan(metrics.heightMeters, arc)
    }

    func testJumpEventDecodesLegacyPayloadWithoutMetrics() throws {
        struct LegacyJump: Codable {
            let takeoffTimestamp: Date
            let landingTimestamp: Date
            let takeoffMonotonicSeconds: Double
            let landingMonotonicSeconds: Double
            let airtime: TimeInterval
        }
        let legacy = LegacyJump(
            takeoffTimestamp: Date(timeIntervalSince1970: 1_000),
            landingTimestamp: Date(timeIntervalSince1970: 1_000.4),
            takeoffMonotonicSeconds: 1,
            landingMonotonicSeconds: 1.4,
            airtime: 0.4)

        let decoded = try JSONDecoder().decode(
            JumpEvent.self,
            from: try JSONEncoder().encode(legacy))

        XCTAssertEqual(decoded.airtime, 0.4, accuracy: 0.001)
        XCTAssertNil(decoded.metrics)
        XCTAssertFalse(decoded.isResolved)
    }

    func testRideDayAggregatesJumpSize() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self, configurations: configuration)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 60_000)
        let day = RideDay(startedAt: base)
        let metrics = JumpMetrics(
            takeoffCoordinate: Coordinate(latitude: 50, longitude: -122),
            landingCoordinate: Coordinate(latitude: 50.0001, longitude: -122),
            lengthMeters: 12,
            heightMeters: 1.2,
            dropMeters: 0.8)
        let jump = JumpEvent(
            takeoffTimestamp: base,
            landingTimestamp: base.addingTimeInterval(0.6),
            takeoffMonotonicSeconds: 0,
            landingMonotonicSeconds: 0.6,
            metrics: metrics)
        let segment = RideSegment(
            kind: .run, startedAt: base, endedAt: base.addingTimeInterval(30),
            routeData: Data(), jumps: [jump])
        segment.day = day
        day.segments.append(segment)
        context.insert(day)
        context.insert(segment)
        try context.save()

        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<RideDay>()).first)
        XCTAssertEqual(saved.maximumJumpLengthMeters, 12, accuracy: 0.001)
        XCTAssertEqual(saved.maximumJumpHeightMeters, 1.2, accuracy: 0.001)
        XCTAssertEqual(saved.totalJumpDistanceMeters, 12, accuracy: 0.001)
        XCTAssertEqual(saved.totalJumpAirtime, 0.6, accuracy: 0.001)
    }

    func testJumpComparisonBuilderMatchesAcrossRunsByLocation() throws {
        let base = Date(timeIntervalSince1970: 70_000)
        func route(start: Date, latitudeOffset: Double) -> [RoutePoint] {
            (0...20).map { index in
                RoutePoint(
                    latitude: 50 + latitudeOffset + Double(index) * 0.00009,
                    longitude: -122.9,
                    altitude: 200 - Double(index),
                    speed: 9,
                    timestamp: start.addingTimeInterval(Double(index)))
            }
        }
        func resolvedJumps(points: [RoutePoint], indices: [Int], airtime: TimeInterval) -> [JumpEvent] {
            indices.map { index in
                let takeoff = points[index]
                return JumpEvent(
                    takeoffTimestamp: takeoff.timestamp,
                    landingTimestamp: takeoff.timestamp.addingTimeInterval(airtime),
                    takeoffMonotonicSeconds: takeoff.timestamp.timeIntervalSinceReferenceDate,
                    landingMonotonicSeconds: takeoff.timestamp.timeIntervalSinceReferenceDate + airtime
                ).resolved(in: points)
            }
        }

        let firstID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
        let firstRoute = route(start: base, latitudeOffset: 0)
        let secondRoute = route(start: base.addingTimeInterval(600), latitudeOffset: 0.00002)
        let farRoute = route(start: base.addingTimeInterval(1_200), latitudeOffset: 0.01)

        let comparisons = SessionJumpComparisonBuilder.build(runs: [
            .init(
                segmentID: firstID, runNumber: 1,
                jumps: resolvedJumps(points: firstRoute, indices: [4, 12], airtime: 0.5)),
            .init(
                segmentID: secondID, runNumber: 2,
                jumps: resolvedJumps(points: secondRoute, indices: [4, 12], airtime: 0.6)),
            .init(
                segmentID: thirdID, runNumber: 3,
                jumps: resolvedJumps(points: farRoute, indices: [4], airtime: 0.5)),
        ])

        XCTAssertEqual(comparisons.features.count, 3)
        let firstJump = try XCTUnwrap(
            comparisons.feature(forAttemptID: "\(firstID.uuidString)-0"))
        XCTAssertEqual(firstJump.attempts.map(\.runNumber), [1, 2])
        let secondJump = try XCTUnwrap(
            comparisons.feature(forAttemptID: "\(secondID.uuidString)-1"))
        XCTAssertEqual(secondJump.attempts.map(\.runNumber), [1, 2])
        let farJump = try XCTUnwrap(
            comparisons.feature(forAttemptID: "\(thirdID.uuidString)-0"))
        XCTAssertEqual(farJump.attempts.map(\.runNumber), [3])
    }

    @MainActor
    func testLiveStatMetricsDefaultAndToggle() throws {
        let key = "berms.liveStatMetrics"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self, configurations: configuration)
        let recorder = RideRecorder(
            context: ModelContext(container),
            watchStateSink: nil,
            authorizationOverride: .authorizedAlways)

        XCTAssertEqual(recorder.liveStatMetrics, LiveStatMetric.defaultSelection)
        recorder.setLiveStatMetric(.topSpeed, enabled: false)
        XCTAssertFalse(recorder.liveStatMetrics.contains(.topSpeed))
        recorder.setLiveStatMetric(.bestAirtime, enabled: true)
        XCTAssertEqual(recorder.liveStatMetrics.last, .bestAirtime, "Selection stays in case order")

        let restored = RideRecorder(
            context: ModelContext(container),
            watchStateSink: nil,
            authorizationOverride: .authorizedAlways)
        XCTAssertEqual(restored.liveStatMetrics, recorder.liveStatMetrics)
    }

    // MARK: - Segment corrections

    @MainActor
    func testSegmentEditorMarkReclassifiesAndRecordsCorrection() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self, configurations: configuration)
        let context = ModelContext(container)

        let day = RideDay(startedAt: Date(timeIntervalSince1970: 1_000))
        let points = correctionRoutePoints(from: day.startedAt, count: 10, altitudeStep: 2)
        let segment = RideSegment(
            kind: .run, startedAt: day.startedAt, endedAt: points[points.count - 1].timestamp,
            routeData: try RouteCodec.encode(points))
        segment.distanceMeters = RouteMetrics.distance(of: points)
        segment.verticalMeters = RouteMetrics.vertical(of: points, kind: .run)
        segment.day = day
        day.segments.append(segment)
        context.insert(day)
        context.insert(segment)
        try context.save()
        day.recalculateTotals()
        XCTAssertEqual(day.descentMeters, 0, accuracy: 0.001)

        try SegmentEditor.mark(segment, as: .lift, in: context)

        XCTAssertEqual(segment.kind, .lift)
        XCTAssertGreaterThan(segment.verticalMeters, 0)
        XCTAssertEqual(day.liftSeconds, segment.duration, accuracy: 0.001)
        XCTAssertEqual(day.activeSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(day.corrections.map(\.kind), [.markLift])
        XCTAssertEqual(day.corrections.first?.originalKind, .run)
        XCTAssertEqual(day.corrections.first?.correctedKind, .lift)
        XCTAssertEqual(day.corrections.first?.segmentID, segment.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RideSegment>()).count, 1)
    }

    @MainActor
    func testSegmentEditorSplitPartitionsRouteJumpsAndTotals() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RideDay.self, RideSegment.self, configurations: configuration)
        let context = ModelContext(container)

        let day = RideDay(startedAt: Date(timeIntervalSince1970: 2_000))
        let points = correctionRoutePoints(from: day.startedAt, count: 11, altitudeStep: -2)
        let earlyJump = JumpEvent(
            takeoffTimestamp: points[2].timestamp,
            landingTimestamp: points[2].timestamp.addingTimeInterval(0.4),
            takeoffMonotonicSeconds: 2, landingMonotonicSeconds: 2.4)
        let lateJump = JumpEvent(
            takeoffTimestamp: points[8].timestamp,
            landingTimestamp: points[8].timestamp.addingTimeInterval(0.5),
            takeoffMonotonicSeconds: 8, landingMonotonicSeconds: 8.5)
        let segment = RideSegment(
            kind: .run, startedAt: day.startedAt, endedAt: points[points.count - 1].timestamp,
            routeData: try RouteCodec.encode(points), jumps: [earlyJump, lateJump])
        segment.distanceMeters = RouteMetrics.distance(of: points)
        segment.verticalMeters = RouteMetrics.vertical(of: points, kind: .run)
        segment.day = day
        day.segments.append(segment)
        context.insert(day)
        context.insert(segment)
        try context.save()
        day.recalculateTotals()

        let originalDuration = segment.duration
        let splitSegment = try SegmentEditor.split(segment, at: 5, in: context)

        XCTAssertEqual(day.segments.count, 2)
        XCTAssertEqual(segment.points.count, 5)
        XCTAssertEqual(splitSegment.points.count, 6)
        XCTAssertEqual(segment.jumps.count, 1)
        XCTAssertEqual(splitSegment.jumps.count, 1)
        XCTAssertEqual(segment.endedAt, points[4].timestamp)
        XCTAssertEqual(splitSegment.startedAt, points[5].timestamp)
        XCTAssertEqual(splitSegment.endedAt, points[10].timestamp)
        XCTAssertGreaterThan(segment.distanceMeters, 0)
        XCTAssertGreaterThan(splitSegment.distanceMeters, 0)
        XCTAssertEqual(
            day.activeSeconds, segment.duration + splitSegment.duration, accuracy: 0.001)
        XCTAssertLessThan(day.activeSeconds, originalDuration)
        XCTAssertEqual(day.corrections.map(\.kind), [.split])
        XCTAssertEqual(day.corrections.first?.splitTimestamp, points[5].timestamp)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RideSegment>()).count, 2)
    }

    @MainActor
    func testSegmentEditorFindsLongStopsAsSplitCandidates() throws {
        let day = RideDay(startedAt: Date(timeIntervalSince1970: 3_000))
        var points = correctionRoutePoints(from: day.startedAt, count: 12, speed: 8)
        for index in 4..<9 {
            points[index] = RoutePoint(
                latitude: points[index].latitude,
                longitude: points[index].longitude,
                altitude: points[index].altitude,
                speed: 0.2,
                timestamp: points[index].timestamp)
        }
        let segment = RideSegment(
            kind: .run, startedAt: day.startedAt, endedAt: points[points.count - 1].timestamp,
            routeData: try RouteCodec.encode(points))

        let candidates = SegmentEditor.splitCandidates(for: segment)

        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertGreaterThanOrEqual(candidate.stoppedSeconds, 15)
        XCTAssertEqual(candidate.timestamp, points[6].timestamp)
        XCTAssertTrue((2...(points.count - 2)).contains(candidate.index))
        XCTAssertFalse(SegmentEditor.splitCandidates(for: segment).isEmpty)
    }

    func testDayTimeBreakdownSplitsWallClockIntoFourBuckets() {
        let day = RideDay(startedAt: Date(timeIntervalSince1970: 4_000))
        day.endedAt = day.startedAt.addingTimeInterval(3_600)
        day.activeSeconds = 1_200
        day.liftSeconds = 600
        day.accumulatedPausedSeconds = 300

        let breakdown = DayTimeBreakdown(day: day)

        XCTAssertEqual(breakdown.riding, 1_200, accuracy: 0.001)
        XCTAssertEqual(breakdown.lifts, 600, accuracy: 0.001)
        XCTAssertEqual(breakdown.paused, 300, accuracy: 0.001)
        XCTAssertEqual(breakdown.stopped, 1_500, accuracy: 0.001)
        XCTAssertEqual(breakdown.total, 3_600, accuracy: 0.001)
    }

    private func correctionRoutePoints(
        from start: Date, count: Int, speed: Double = 6, altitudeStep: Double = 0
    ) -> [RoutePoint] {
        (0..<count).map { index in
            RoutePoint(
                latitude: 40 + Double(index) * 0.0002,
                longitude: -105,
                altitude: Double(index) * altitudeStep,
                speed: speed,
                timestamp: start.addingTimeInterval(Double(index) * 5))
        }
    }

    func testRouteTitleBuilderCompactsLongSequences() {
        let a = UUID()
        let b = UUID()
        let titles = RouteTitleBuilder.titles(from: [
            a: ["Upper Dominion", "Pipeline", "Progression Drops"],
            b: ["Domboo"],
        ])
        XCTAssertEqual(titles[a], "Upper Dominion → … → Progression Drops")
        XCTAssertEqual(titles[b], "Domboo")
    }

    func testRouteTitleBuilderDisambiguatesLookalikeRuns() {
        let a = UUID()
        let b = UUID()
        let titles = RouteTitleBuilder.titles(from: [
            a: ["Upper Dominion", "Pipeline", "Lower Dominion", "Progression Drops"],
            b: ["Upper Dominion", "Crap Chute", "Lower Dominion", "Progression Drops"],
        ])
        XCTAssertEqual(titles[a], "Upper Dominion → Pipeline → Progression Drops")
        XCTAssertEqual(titles[b], "Upper Dominion → Crap Chute → Progression Drops")
    }

    func testRouteTitleBuilderLeavesIdenticalRoutesIdentical() {
        let a = UUID()
        let b = UUID()
        let titles = RouteTitleBuilder.titles(from: [
            a: ["Upper Dominion", "Pipeline", "Progression Drops"],
            b: ["Upper Dominion", "Pipeline", "Progression Drops"],
        ])
        XCTAssertEqual(titles[a], titles[b])
        XCTAssertEqual(titles[a], "Upper Dominion → … → Progression Drops")
    }

    private func runContext(
        at seconds: Double, base: Date, speed: Double = 8,
        phase: DetectorPhase = .run
    ) -> JumpTrackContext {
        JumpTrackContext(
            timestamp: base.addingTimeInterval(seconds), monotonicSeconds: seconds,
            speed: speed, altitude: 100, phase: phase, isStationary: false, isAutomotive: false)
    }

    private func motion(
        at seconds: Double, forceG: Double, rotation: Double = 0,
        base: Date = Date(timeIntervalSince1970: 2_000)
    ) -> DeviceMotionSample {
        DeviceMotionSample(
            recordedAt: base.addingTimeInterval(seconds), monotonicSeconds: seconds,
            userAccelerationX: 0, userAccelerationY: 0, userAccelerationZ: 1 - forceG,
            rotationRateX: rotation, rotationRateY: 0, rotationRateZ: 0,
            gravityX: 0, gravityY: 0, gravityZ: -1,
            quaternionW: 1, quaternionX: 0, quaternionY: 0, quaternionZ: 0)
    }

    private func rawMotionRecord(at seconds: Double, base: Date, forceG: Double) -> RawDiagnosticRecord {
        let sample = motion(at: seconds, forceG: forceG, base: base)
        return RawDiagnosticRecord(
            kind: "device_motion_raw", timestamp: sample.recordedAt,
            monotonicSeconds: sample.monotonicSeconds,
            userAccelerationZ: sample.userAccelerationZ,
            gravityZ: sample.gravityZ, quaternionW: 1)
    }

    private func sample(
        at base: Date, index: Int, altitude: Double, speed: Double,
        cycling: Bool, stationary: Bool = false, automotive: Bool = false,
        accuracy: Double = 8, interval: Double = 5
    ) -> TrackSample {
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
