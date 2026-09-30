#if DEBUG
    import Combine
    import CoreLocation
    import Foundation

    struct SurveyFix: Codable, Sendable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double?
        let verticalAccuracy: Double?
        let altitude: Double?
        let speed: Double?
        let course: Double?

        init(_ location: CLLocation) {
            timestamp = location.timestamp
            latitude = location.coordinate.latitude
            longitude = location.coordinate.longitude
            horizontalAccuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
            verticalAccuracy = location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil
            altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
            speed = location.speed >= 0 ? location.speed : nil
            course = location.course >= 0 ? location.course : nil
        }

        var json: [String: Any] {
            [
                "timestamp": SurveyCoding.date(timestamp), "timestampSeconds": timestamp.timeIntervalSince1970,
                "latitude": latitude, "longitude": longitude,
                "horizontalAccuracy": horizontalAccuracy as Any? ?? NSNull(),
                "verticalAccuracy": verticalAccuracy as Any? ?? NSNull(), "altitude": altitude as Any? ?? NSNull(),
                "speed": speed as Any? ?? NSNull(), "course": course as Any? ?? NSNull(),
            ]
        }
    }

    enum SurveyCoding {
        static func encoder() -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            return encoder
        }

        static func decoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return decoder
        }

        static func date(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }
    }

    struct SurveyPass: Codable, Identifiable, Sendable {
        let id: UUID
        let startedAt: Date
        var endedAt: Date
        var direction = "unknown"
        var exclusions: [Int] = []
        var pointCount = 0
        var interruption: String?
    }

    struct SurveyDraft: Codable, Identifiable, Sendable {
        let id: UUID
        let createdAt: Date
        let catalogID: String
        let baseRevision: String
        let baseChecksum: String
        let slug: String
        let trailID: UUID
        let baselineHash: String?
        let baselineJSON: Data?
        var name: String
        var difficulty: String
        var kind: String
        var note = ""
        var passes: [SurveyPass] = []
        var state = "paused"
        var selectedPassID: UUID?
        var replacesGeometry: Bool?
        var contentVersion = 1
        var exportedVersion: Int?
        var pointCount: Int { passes.reduce(0) { $0 + $1.pointCount } }
    }

    /// Serial disk writes run off the ride's main-actor sensor path.
    final class SurveyFiles: @unchecked Sendable {
        let directory: URL
        private let queue = DispatchQueue(label: "berms.survey-files", qos: .utility)
        private let lock = NSLock()
        private var failure: String?

        init(directory: URL) { self.directory = directory }

        func sampleURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".jsonl") }

        func append(_ fix: SurveyFix, passID: UUID, draft: SurveyDraft) {
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                    let url = self.sampleURL(passID)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        FileManager.default.createFile(
                            atPath: url.path, contents: nil,
                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                    }
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    var data = try SurveyCoding.encoder().encode(fix)
                    data.append(10)
                    try handle.write(contentsOf: data)
                    try self.write(draft)
                } catch {
                    self.lock.lock()
                    self.failure = error.localizedDescription
                    self.lock.unlock()
                }
            }
        }

        private func write(_ draft: SurveyDraft) throws {
            try SurveyCoding.encoder().encode(draft).write(
                to: directory.appendingPathComponent(draft.id.uuidString + ".json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }

        func save(_ draft: SurveyDraft) throws {
            try queue.sync {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try write(draft)
                try checkFailure()
            }
        }

        func checkFailure() throws {
            lock.lock()
            defer { lock.unlock() }
            if let failure {
                throw NSError(domain: "Survey storage", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
            }
        }

        func fixes(_ id: UUID) throws -> [SurveyFix] {
            try queue.sync {
                try checkFailure()
                let url = sampleURL(id)
                guard FileManager.default.fileExists(atPath: url.path) else { return [] }
                let data = try Data(contentsOf: url)
                let complete =
                    data.last == 10 ? data : Data(data.prefix(upTo: data.lastIndex(of: 10).map { $0 + 1 } ?? 0))
                return try complete.split(separator: 10).map {
                    try SurveyCoding.decoder().decode(SurveyFix.self, from: Data($0))
                }
            }
        }
    }

    @MainActor
    final class TrailSurveyStore: ObservableObject {
        static let shared = TrailSurveyStore()
        @Published private(set) var drafts: [SurveyDraft] = []
        @Published private(set) var activeID: UUID?
        @Published var errorMessage: String?
        let locationService: LocationService
        let files: SurveyFiles
        private let now: () -> Date
        private var previousTimestamp: Date?
        private var exportingIDs = Set<UUID>()
        var isActive: Bool { activeID != nil }
        var active: SurveyDraft? { drafts.first { $0.id == activeID } }

        init(directory: URL? = nil, locationService: LocationService? = nil, now: @escaping () -> Date = { .now }) {
            self.locationService = locationService ?? LocationService()
            self.now = now
            files = SurveyFiles(
                directory: directory
                    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Trail surveys", isDirectory: true))
            do {
                guard FileManager.default.fileExists(atPath: files.directory.path) else { return }
                for url in try FileManager.default.contentsOfDirectory(
                    at: files.directory, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" {
                    var draft = try SurveyCoding.decoder().decode(SurveyDraft.self, from: Data(contentsOf: url))
                    for index in draft.passes.indices {
                        let fixes = try files.fixes(draft.passes[index].id)
                        draft.passes[index].pointCount = fixes.count
                        if let last = fixes.last { draft.passes[index].endedAt = last.timestamp }
                    }
                    if draft.state == "recording" {
                        draft.state = "interrupted"
                        if !draft.passes.isEmpty {
                            draft.passes[draft.passes.count - 1].interruption = "process interrupted"
                        }
                        try files.save(draft)
                    }
                    drafts.append(draft)
                }
                drafts.sort { $0.createdAt > $1.createdAt }
            } catch { errorMessage = "Could not recover survey drafts: \(error.localizedDescription)" }
        }

        func create(catalog: TrailCatalogDescriptor, slug: String?, name: String, difficulty: String) throws -> UUID {
            guard !isActive else { throw CocoaError(.validationMultipleErrors) }
            let snapshot = try CatalogSnapshotStore.shared.snapshot()
            guard let baseline = snapshot.catalogs.first(where: { $0.id == catalog.id }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let canonicalSlug = slug.map { catalog.aliases[$0] ?? $0 }
            let data = try CatalogSnapshotStore.shared.catalogData(catalog)
            guard CatalogSnapshotStore.checksum(data) == baseline.checksum else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let collection = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let feature = (collection?["features"] as? [[String: Any]])?.first {
                ($0["properties"] as? [String: Any])?["slug"] as? String == canonicalSlug
            }
            if canonicalSlug != nil, feature == nil { throw CocoaError(.fileReadCorruptFile) }
            let newSlug = canonicalSlug ?? "survey-\(UUID().uuidString.lowercased())"
            let properties = feature?["properties"] as? [String: Any]
            let draft = SurveyDraft(
                id: UUID(), createdAt: now(), catalogID: catalog.id, baseRevision: snapshot.revision,
                baseChecksum: baseline.checksum, slug: newSlug,
                trailID: TrailCatalogImporter.stableID(for: newSlug, catalog: catalog),
                baselineHash: baseline.trailHashes[newSlug],
                baselineJSON: try feature.map {
                    try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
                },
                name: properties?["name"] as? String ?? name,
                difficulty: properties?["difficulty"] as? String ?? difficulty,
                kind: canonicalSlug == nil ? "addTrail" : "corroborateTrail")
            try files.save(draft)
            drafts.insert(draft, at: 0)
            return draft.id
        }

        func resume(_ id: UUID) throws {
            guard !isActive, let index = drafts.firstIndex(where: { $0.id == id }) else { return }
            guard locationService.authorizationStatus != .denied, locationService.authorizationStatus != .restricted
            else {
                throw NSError(
                    domain: "Survey", code: 1, userInfo: [NSLocalizedDescriptionKey: "Location access is disabled."])
            }
            var draft = drafts[index]
            draft.state = "recording"
            draft.contentVersion += 1
            draft.passes.append(SurveyPass(id: UUID(), startedAt: now(), endedAt: now()))
            try files.save(draft)
            drafts[index] = draft
            activeID = id
            previousTimestamp = nil
            locationService.authorizationChangeHandler = { [weak self] status in
                guard status == .denied || status == .restricted else { return }
                self?.interrupt("Location access was revoked.")
            }
            locationService.diagnosticHandler = { [weak self] detail in self?.interrupt(detail) }
            locationService.start { [weak self] location, _ in self?.consume(location) }
        }

        func consume(_ location: CLLocation) {
            do { try files.checkFailure() } catch {
                interrupt(error.localizedDescription)
                return
            }
            guard let index = drafts.firstIndex(where: { $0.id == activeID }),
                let pass = drafts[index].passes.last,
                location.timestamp >= pass.startedAt, location.timestamp <= now().addingTimeInterval(10),
                previousTimestamp.map({ location.timestamp > $0 }) ?? true,
                CLLocationCoordinate2DIsValid(location.coordinate)
            else { return }
            if let previousTimestamp, location.timestamp.timeIntervalSince(previousTimestamp) > 60 {
                drafts[index].passes[drafts[index].passes.count - 1].interruption = "GPS gap"
                drafts[index].passes.append(
                    SurveyPass(id: UUID(), startedAt: location.timestamp, endedAt: location.timestamp))
            }
            let passIndex = drafts[index].passes.count - 1
            drafts[index].passes[passIndex].pointCount += 1
            drafts[index].passes[passIndex].endedAt = location.timestamp
            previousTimestamp = location.timestamp
            files.append(SurveyFix(location), passID: drafts[index].passes[passIndex].id, draft: drafts[index])
        }

        func checkpoint() {
            guard let active else { return }
            do { try files.save(active) } catch { errorMessage = error.localizedDescription }
        }

        func pause() throws {
            guard let index = drafts.firstIndex(where: { $0.id == activeID }) else { return }
            locationService.stop()
            activeID = nil
            drafts[index].state = "paused"
            try files.save(drafts[index])
        }

        func interrupt(_ reason: String) {
            errorMessage = reason
            guard let index = drafts.firstIndex(where: { $0.id == activeID }) else { return }
            locationService.stop()
            activeID = nil
            drafts[index].state = "interrupted"
            if !drafts[index].passes.isEmpty {
                drafts[index].passes[drafts[index].passes.count - 1].interruption = reason
            }
            do { try files.save(drafts[index]) } catch { errorMessage = error.localizedDescription }
        }

        func save(_ id: UUID) throws {
            if activeID == id { try pause() }
            guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
            drafts[index].state = "saved"
            try files.save(drafts[index])
        }

        func update(_ draft: SurveyDraft) throws {
            guard activeID != draft.id, let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
            var updated = draft
            updated.contentVersion = drafts[index].contentVersion + 1
            try files.save(updated)
            drafts[index] = updated
        }

        func discard(_ id: UUID) throws {
            if activeID == id { try pause() }
            guard let draft = drafts.first(where: { $0.id == id }) else { return }
            try FileManager.default.removeItem(at: files.directory.appendingPathComponent(id.uuidString + ".json"))
            for pass in draft.passes { try? FileManager.default.removeItem(at: files.sampleURL(pass.id)) }
            drafts.removeAll { $0.id == id }
        }

        func export(_ id: UUID) async throws -> URL {
            guard activeID != id, let index = drafts.firstIndex(where: { $0.id == id }) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard exportingIDs.insert(id).inserted else { throw CocoaError(.fileWriteUnknown) }
            defer { exportingIDs.remove(id) }
            let draft = drafts[index]
            let files = files
            let destination = try await Task.detached(priority: .utility) {
                try Self.buildArchive(draft: draft, files: files)
            }.value
            if let current = drafts.firstIndex(where: { $0.id == id }) {
                drafts[current].exportedVersion = draft.contentVersion
                try files.save(drafts[current])
            }
            return destination
        }

        nonisolated private static func buildArchive(draft: SurveyDraft, files: SurveyFiles) throws -> URL {
            let id = draft.id
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Survey-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("passes"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var passes: [[String: Any]] = []
            var selectedFixes: [SurveyFix] = []
            let selected = draft.selectedPassID
            for pass in draft.passes {
                let fixes = try files.fixes(pass.id)
                if pass.id == selected {
                    selectedFixes = fixes.enumerated().filter { !pass.exclusions.contains($0.offset) }.map(\.element)
                }
                let data = try JSONSerialization.data(withJSONObject: fixes.map(\.json), options: [.sortedKeys])
                let filename = "passes/\(pass.id.uuidString).json"
                try data.write(to: folder.appendingPathComponent(filename))
                passes.append([
                    "id": pass.id.uuidString, "startedAt": SurveyCoding.date(pass.startedAt),
                    "endedAt": SurveyCoding.date(pass.endedAt), "direction": pass.direction,
                    "exclusions": pass.exclusions, "gaps": [], "interruption": pass.interruption as Any? ?? NSNull(),
                    "samplesFile": filename, "checksum": CatalogSnapshotStore.checksum(data),
                ])
            }
            guard !passes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let baseline: Any = try draft.baselineJSON.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            var proposed: Any = NSNull()
            if draft.kind != "corroborateTrail" {
                var feature = baseline as? [String: Any] ?? ["type": "Feature"]
                var properties = feature["properties"] as? [String: Any] ?? [:]
                properties["slug"] = draft.slug
                properties["name"] = draft.name
                properties["difficulty"] = draft.difficulty
                feature["properties"] = properties
                if draft.kind == "addTrail" || draft.replacesGeometry == true {
                    guard selectedFixes.count >= 2 else { throw CocoaError(.fileReadCorruptFile) }
                    feature["geometry"] = [
                        "type": "LineString", "coordinates": selectedFixes.map { [$0.longitude, $0.latitude] },
                    ]
                }
                proposed = feature
            }
            let operation: [String: Any] = [
                "kind": draft.kind, "slug": draft.slug, "trailID": draft.trailID.uuidString,
                "baselineHash": draft.baselineHash as Any? ?? NSNull(), "baseline": baseline,
                "proposed": proposed, "selectedPassID": selected?.uuidString as Any? ?? NSNull(),
                "passIDs": draft.passes.map { $0.id.uuidString },
            ]
            let contribution: [String: Any] = [
                "schemaVersion": 1, "id": draft.id.uuidString, "createdAt": SurveyCoding.date(draft.createdAt),
                "catalogID": draft.catalogID, "baseRevision": draft.baseRevision, "baseChecksum": draft.baseChecksum,
                "provenance": "developerGPS", "contentVersion": draft.contentVersion, "note": draft.note,
                "operations": [operation], "passes": passes,
            ]
            try JSONSerialization.data(withJSONObject: contribution, options: [.sortedKeys]).write(
                to: folder.appendingPathComponent("contribution.json"))
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Survey-\(id.uuidString)-v\(draft.contentVersion).zip")
            try? FileManager.default.removeItem(at: destination)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) {
                archive in
                do { try FileManager.default.copyItem(at: archive, to: destination) } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            return destination
        }
    }
#endif
