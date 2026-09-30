import CoreLocation
import Foundation
import SwiftData
import XCTest

@testable import Berms

@MainActor
final class TrailSurveyTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "berms.survey-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testRawQualityRecoveryBoundariesAndRepeatExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = LocationCapture(usesHardware: false)
        var date = Date(timeIntervalSince1970: 1_800_000_000.125)
        let store = TrailSurveyStore(
            directory: directory, locationService: LocationService(capture: capture), now: { date })
        let id = try store.create(
            catalog: TrailCatalogRegistry.mountainCreek, slug: nil, name: "Roundtrip", difficulty: "blue")
        try store.resume(id)
        let first = try XCTUnwrap(store.active?.passes.last?.id)
        for index in 0..<3 {
            date = date.addingTimeInterval(1)
            capture.deliver(
                CLLocation(
                    coordinate: .init(latitude: 41.18 + Double(index) * 0.0001, longitude: -74.5),
                    altitude: 500, horizontalAccuracy: 4.5, verticalAccuracy: -1,
                    course: -1, speed: -1, timestamp: date))
        }
        try store.pause()
        var draft = try XCTUnwrap(store.drafts.first)
        draft.selectedPassID = first
        draft.passes[0].direction = "reverse"
        draft.passes[0].exclusions = [1]
        try store.update(draft)
        let fixes = try store.files.fixes(first)
        XCTAssertEqual(fixes.count, 3)
        XCTAssertEqual(fixes[0].timestamp.timeIntervalSince1970, 1_800_000_001.125, accuracy: 0.001)
        XCTAssertEqual(fixes[0].horizontalAccuracy, 4.5)
        XCTAssertNil(fixes[0].verticalAccuracy)
        XCTAssertNil(fixes[0].altitude)
        XCTAssertNil(fixes[0].speed)
        XCTAssertNil(fixes[0].course)
        let export = try await store.export(id)
        let firstBytes = try Data(contentsOf: export)
        XCTAssertFalse(firstBytes.isEmpty)
        _ = try await store.export(id)
        XCTAssertEqual(store.drafts.first?.id, id)
        XCTAssertEqual(store.drafts.first?.exportedVersion, store.drafts.first?.contentVersion)
        // Shared end-to-end fixture for the repository importer (copied out after XCTest).
        try Data(contentsOf: export).write(to: URL(fileURLWithPath: "/tmp/berms-phone-survey-fixture.zip"))
        date = date.addingTimeInterval(100)
        try store.resume(id)
        capture.deliver(
            CLLocation(
                coordinate: .init(latitude: 41.19, longitude: -74.5), altitude: 510,
                horizontalAccuracy: 7, verticalAccuracy: 3, course: 90, speed: 6, timestamp: date))
        store.locationService.stop()
        let recovered = TrailSurveyStore(
            directory: directory, locationService: LocationService(capture: capture), now: { date })
        XCTAssertFalse(recovered.isActive)
        XCTAssertEqual(recovered.drafts.first?.state, "interrupted")
        XCTAssertEqual(recovered.drafts.first?.passes.count, 2)
        XCTAssertEqual(recovered.drafts.first?.passes[0].exclusions, [1])
        XCTAssertEqual(recovered.drafts.first?.passes[0].direction, "reverse")
        try recovered.resume(id)
        XCTAssertEqual(recovered.active?.passes.count, 3)
        capture.report("stream error")
        XCTAssertFalse(recovered.isActive)
        XCTAssertEqual(capture.consumerCount, 0)
        XCTAssertEqual(recovered.errorMessage, "stream error")
        try recovered.discard(id)
        XCTAssertTrue(recovered.drafts.isEmpty)
    }

    func testMetadataOnlyPhoneExportRetainsApprovedLine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = LocationCapture(usesHardware: false)
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TrailSurveyStore(
            directory: directory, locationService: LocationService(capture: capture), now: { date })
        let catalog = TrailCatalogRegistry.mountainCreek
        let data = try CatalogSnapshotStore.shared.catalogData(catalog)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try XCTUnwrap(object["features"] as? [[String: Any]])
        let feature = try XCTUnwrap(
            features.first { value in
                guard let properties = value["properties"] as? [String: Any], let slug = properties["slug"] as? String
                else { return false }
                return catalog.aliases[slug] == nil
            })
        let properties = try XCTUnwrap(feature["properties"] as? [String: Any])
        let slug = try XCTUnwrap(properties["slug"] as? String)
        let id = try store.create(catalog: catalog, slug: slug, name: "", difficulty: "blue")
        try store.resume(id)
        for index in 0..<3 {
            date = date.addingTimeInterval(1)
            capture.deliver(
                CLLocation(
                    coordinate: .init(latitude: 41.18 + Double(index) * 0.0001, longitude: -74.5),
                    altitude: 500, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: date))
        }
        try store.pause()
        var draft = try XCTUnwrap(store.drafts.first)
        draft.kind = "editTrail"
        draft.name = "Metadata-only fixture rename"
        try store.update(draft)
        let url = try await store.export(id)
        try Data(contentsOf: url).write(to: URL(fileURLWithPath: "/tmp/berms-phone-metadata-fixture.zip"))
        XCTAssertNil(store.drafts.first?.selectedPassID)
        XCTAssertEqual(store.drafts.first?.trailID, TrailCatalogImporter.stableID(for: slug, catalog: catalog))
    }

    func testLocationGapSplitsPassAndErrorsOnlyInterruptSurvey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = LocationCapture(usesHardware: false)
        let ride = LocationService(capture: capture)
        var fixes = 0
        ride.start { _, _ in fixes += 1 }
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TrailSurveyStore(
            directory: directory, locationService: LocationService(capture: capture), now: { date })
        let id = try store.create(
            catalog: TrailCatalogRegistry.mountainCreek, slug: nil, name: "Gap", difficulty: "blue")
        try store.resume(id)
        capture.deliver(
            CLLocation(
                coordinate: .init(latitude: 41, longitude: -74), altitude: 10,
                horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: date))
        date = date.addingTimeInterval(61)
        capture.deliver(
            CLLocation(
                coordinate: .init(latitude: 41.1, longitude: -74), altitude: 10,
                horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: date))
        XCTAssertEqual(store.active?.passes.count, 2)
        XCTAssertEqual(store.active?.passes[0].interruption, "GPS gap")
        capture.report("error")
        XCTAssertTrue(ride.isRunning)
        XCTAssertEqual(capture.consumerCount, 1)
        XCTAssertEqual(fixes, 2)
        ride.stop()
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testAuthorizationRevocationAndDiscardPreserveOtherLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = LocationCapture(usesHardware: false)
        let ride = LocationService(capture: capture)
        ride.start { _, _ in }
        let survey = TrailSurveyStore(directory: directory, locationService: LocationService(capture: capture))
        let id = try survey.create(
            catalog: TrailCatalogRegistry.mountainCreek, slug: nil, name: "Permission", difficulty: "blue")
        try survey.resume(id)
        capture.authorizationChanged(.denied)
        XCTAssertFalse(survey.isActive)
        XCTAssertTrue(ride.isRunning)
        XCTAssertEqual(capture.consumerCount, 1)
        XCTAssertThrowsError(try survey.resume(id))
        capture.authorizationChanged(.authorizedAlways)
        try survey.resume(id)
        try survey.discard(id)
        XCTAssertTrue(survey.drafts.isEmpty)
        XCTAssertTrue(ride.isRunning)
        XCTAssertEqual(capture.consumerCount, 1)
        XCTAssertEqual(capture.startCount, 1)
        ride.stop()
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testMalformedApprovedMetadataIsRejectedBeforeAnyMutation() throws {
        let schema = Schema([Trail.self, TrailPass.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let catalog = TrailCatalogRegistry.mountainCreek
        let feature: [String: Any] = [
            "type": "Feature", "properties": ["slug": "validation-fixture", "name": "Original", "difficulty": "blue"],
            "geometry": ["type": "LineString", "coordinates": [[-74.0, 41.0], [-74.001, 41.001]]],
        ]
        let valid = try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": [feature]])
        _ = try TrailCatalogImporter.import(
            data: valid, into: context, catalog: catalog, approvedGeometry: true, saveChanges: false)
        try context.save()
        let trail = try XCTUnwrap(context.fetch(FetchDescriptor<Trail>()).first)
        let original = trail.catalogRouteData
        for (key, value) in [("name", "   " as Any), ("difficulty", 42 as Any), ("difficultyLabel", true as Any)] {
            var invalidFeature = feature
            var properties = try XCTUnwrap(feature["properties"] as? [String: Any])
            properties[key] = value
            invalidFeature["properties"] = properties
            let invalid = try JSONSerialization.data(withJSONObject: [
                "type": "FeatureCollection", "features": [invalidFeature],
            ])
            XCTAssertThrowsError(try TrailCatalogImporter.validateApprovedCatalog(invalid))
            XCTAssertThrowsError(
                try TrailCatalogImporter.import(
                    data: invalid, into: context, catalog: catalog, approvedGeometry: true, saveChanges: false))
            XCTAssertEqual(trail.catalogRouteData, original)
            XCTAssertEqual(trail.name, "Original")
        }
    }

    func testApprovedCatalogUpdatePreservesLegacyPassesAndMultilineRoutes() throws {
        let schema = Schema([RideDay.self, RideSegment.self, Trail.self, TrailPass.self, LearnedLift.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let defaults = try isolatedDefaults()
        let catalog = TrailCatalogRegistry.mountainCreek
        let trail = Trail(name: "Old", difficulty: .blue, resort: catalog.resortName, catalogID: catalog.id)
        trail.id = TrailCatalogImporter.stableID(for: "fixture", catalog: catalog)
        context.insert(trail)
        let point = RoutePoint(latitude: 41, longitude: -74, altitude: 10, speed: 0, timestamp: .now)
        let pass = TrailPass(routePoints: [point, point])
        pass.trail = trail
        trail.passes.append(pass)
        context.insert(pass)
        let oldData = pass.routeData
        let json = Data(
            """
            {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"slug":"fixture","name":"New","difficulty":"black"},"geometry":{"type":"MultiLineString","coordinates":[[[-74,41],[-74.1,41.1]],[[-75,42],[-75.1,42.1]]]}}]}
            """.utf8)
        let summary = try TrailCatalogImporter.import(
            data: json, into: context, defaults: defaults, catalog: catalog, approvedGeometry: true)
        XCTAssertEqual(summary.passesCreated, 0)
        XCTAssertEqual(trail.id, TrailCatalogImporter.stableID(for: "fixture", catalog: catalog))
        XCTAssertEqual(trail.name, "New")
        XCTAssertEqual(trail.passes.count, 1)
        XCTAssertEqual(pass.routeData, oldData)
        XCTAssertEqual(trail.matcherRoutes.count, 2)
        XCTAssertEqual(trail.matcherRoutes.map(\.count), [2, 2])
        trail.recalculateAverage()
        XCTAssertEqual(trail.matcherRoutes.count, 2)
        XCTAssertEqual(trail.points.last?.longitude, -75.1)
        let empty = Data("{\"type\":\"FeatureCollection\",\"features\":[]}".utf8)
        _ = try TrailCatalogImporter.import(
            data: empty, into: context, defaults: defaults, catalog: catalog, approvedGeometry: true)
        XCTAssertTrue(trail.matcherRoutes.isEmpty)
        XCTAssertEqual(trail.passes.count, 1)
        XCTAssertEqual(pass.routeData, oldData)
    }

    func testRepositoryRoundTripFixtureImportsWithPhoneIdentity() throws {
        let root = URL(fileURLWithPath: "/tmp/berms-survey-roundtrip")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("trail-id.txt").path) else {
            throw XCTSkip("Run the documented phone-to-repository roundtrip first.")
        }
        let manifest = try Data(contentsOf: root.appendingPathComponent("packages/catalog-manifest.json"))
        let descriptors = try ResortCatalogLoader.decode(manifest).catalogs
        var packages: [String: Data] = [:]
        for catalog in descriptors {
            packages[catalog.id] = try Data(contentsOf: root.appendingPathComponent("packages/\(catalog.id).geojson"))
        }
        let storage = root.appendingPathComponent("phone-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) }
        let store = CatalogSnapshotStore(directory: storage)
        try store.activate(manifest: manifest, packages: packages)
        let schema = Schema([RideDay.self, RideSegment.self, Trail.self, TrailPass.self, LearnedLift.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for catalog in descriptors {
            _ = try TrailCatalogImporter.import(
                data: try XCTUnwrap(packages[catalog.id]), into: context,
                catalog: catalog, approvedGeometry: true, saveChanges: false)
        }
        try context.save()
        let identity = try String(contentsOf: root.appendingPathComponent("trail-id.txt"), encoding: .utf8)
        let trail = try XCTUnwrap(context.fetch(FetchDescriptor<Trail>()).first { $0.id.uuidString == identity })
        XCTAssertEqual(trail.name, "Roundtrip")
        XCTAssertEqual(trail.points.count, 2)
        XCTAssertEqual(trail.passes.count, 0)
        XCTAssertEqual(trail.points.first?.latitude, 41.18)
        XCTAssertEqual(trail.points.last?.latitude, 41.1802)
    }

    func testCatalogChecksumSchemaAndInterruptedActivationKeepOfflineRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CatalogSnapshotStore(directory: directory)
        let manifest = try CatalogSnapshotStore.shared.manifestData()
        let snapshot = try JSONDecoder().decode(CatalogSnapshot.self, from: manifest)
        var packages: [String: Data] = [:]
        for catalog in TrailCatalogRegistry.catalogs {
            packages[catalog.id] = try CatalogSnapshotStore.shared.catalogData(catalog)
        }
        try store.activate(manifest: manifest, packages: packages)
        XCTAssertEqual(try store.snapshot().revision, snapshot.revision)
        let active = store.activeDirectory
        let manifestURL = try XCTUnwrap(active).appendingPathComponent("catalog-manifest.json")
        try FileManager.default.removeItem(at: manifestURL)
        XCTAssertEqual(store.registryManifest()?.catalogs.map(\.id), snapshot.catalogs.map(\.id))
        try manifest.write(to: manifestURL)
        var next = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        next["revision"] = String(repeating: "a", count: 64)
        let nextManifest = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
        XCTAssertThrowsError(
            try store.withActivatedSnapshot(manifest: nextManifest, packages: packages) {
                throw CocoaError(.fileWriteOutOfSpace)
            })
        XCTAssertEqual(store.activeDirectory, active)
        packages[TrailCatalogRegistry.defaultCatalog.id] = Data("corrupt".utf8)
        XCTAssertThrowsError(try store.activate(manifest: manifest, packages: packages))
        XCTAssertEqual(store.activeDirectory, active)
        XCTAssertEqual(try CatalogSnapshotStore(directory: directory).snapshot().revision, snapshot.revision)
        var unsupported = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        unsupported["schemaVersion"] = 2
        XCTAssertThrowsError(
            try store.activate(manifest: JSONSerialization.data(withJSONObject: unsupported), packages: packages))
        XCTAssertThrowsError(try store.activate(manifest: manifest, packages: [:]))
        XCTAssertEqual(store.activeDirectory, active)
    }
}
