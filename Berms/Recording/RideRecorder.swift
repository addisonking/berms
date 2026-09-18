import Combine
import CoreLocation
import Darwin
import Foundation
import SwiftData

final class RawLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.addis.berms.raw-log", qos: .utility)
    private var handle: FileHandle?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(url: URL) {
        var directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func append(_ record: RawDiagnosticRecord) {
        guard let encoded = try? encoder.encode(record) else { return }
        var lineData = encoded
        lineData.append(0x0A)
        queue.async { [weak self, lineData] in
            guard let self, let handle = self.handle else { return }
            try? handle.write(contentsOf: lineData)
        }
    }

    func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    func close() {
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }
}

@MainActor
final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    struct StoreIssue: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    let container: ModelContainer
    private(set) var storeIssue: StoreIssue?
    @Published private(set) var catalogImportIssue: String?

    private init() {
        let schema = Schema([RideDay.self, RideSegment.self, Trail.self, TrailPass.self, LearnedLift.self])
        let configuration = ModelConfiguration("Berms", schema: schema, isStoredInMemoryOnly: false)

        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            self.container = container
            importCatalogs(in: container)
            return
        }

        let movedAside = Self.moveStoreAside()
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            self.container = container
            storeIssue = StoreIssue(
                message: movedAside
                    ? "Berms could not open its saved data, so it started fresh. The previous data was kept on this device."
                    : "Berms could not open its saved data, so it started fresh."
            )
            importCatalogs(in: container)
            return
        }

        let memoryConfiguration = ModelConfiguration("Berms", schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [memoryConfiguration]) else {
            fatalError("Could not create Berms storage schema")
        }
        self.container = container
        storeIssue = StoreIssue(
            message: "Berms could not open its saved data and is running without saving. Restart the app to try again."
        )
        importCatalogs(in: container)
    }

    /// Catalogs are imported on their own context off the main actor. A resort
    /// catalog is megabytes of geometry, so doing this during launch would
    /// stall the first frame.
    private func importCatalogs(in container: ModelContainer) {
        if let manifestError = TrailCatalogRegistry.manifestError {
            catalogImportIssue = manifestError
            print("Trail catalog import skipped: \(manifestError)")
            return
        }
        Task.detached(priority: .utility) { [weak self, container] in
            let context = ModelContext(container)
            do {
                for result in try TrailCatalogImporter.importCatalogsIfNeeded(into: context) {
                    print(
                        "Imported \(result.catalog.resortName) trails: "
                            + "\(result.summary.trailsCreated) trails, "
                            + "\(result.summary.passesCreated) passes")
                }
            } catch {
                print("Trail catalog import skipped: \(error.localizedDescription)")
                await MainActor.run {
                    self?.catalogImportIssue = "Trail catalog import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func moveStoreAside() -> Bool {
        let fileManager = FileManager.default
        guard
            let support = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        else {
            return false
        }
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        var movedAny = false
        for suffix in ["", "-shm", "-wal"] {
            let source = support.appendingPathComponent("Berms.store\(suffix)")
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = support.appendingPathComponent("Berms-recovered-\(stamp).store\(suffix)")
            do {
                try fileManager.moveItem(at: source, to: destination)
                movedAny = true
            } catch {
                print("Could not move store file \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return movedAny
    }
}

struct RecorderCheckpoint: Codable, Sendable {
    let version: Int
    let points: [TrackSample]
    let jumps: [JumpEvent]

    init(points: [TrackSample], jumps: [JumpEvent] = []) {
        self.version = 1
        self.points = points
        self.jumps = jumps
    }
}

struct RebuiltSegmentSummary: Sendable {
    let kind: SegmentKind
    let runNumber: Int?
    let trailSequence: [String]?
    let startedAt: Date
    let endedAt: Date
    let routeData: Data
    let distanceMeters: Double
    let verticalMeters: Double
    let maximumSpeedMetersPerSecond: Double
    let jumps: [JumpEvent]
}

struct RebuiltDaySummary: Sendable {
    let dayID: UUID
    let segments: [RebuiltSegmentSummary]
}

struct RepairedRoute: Sendable {
    let id: UUID
    let routeData: Data
    let distanceMeters: Double
    let verticalMeters: Double
    let maximumSpeedMetersPerSecond: Double
}

struct CatalogPassRepairInput: Sendable {
    let id: UUID
    let trailID: UUID
    let trailCreatedAt: Date
    let recordedAt: Date
}

/// Catalog trail passes store centerlines, not rides. Version 10 of the
/// diagnostic migration re-cleaned them with the ride cleaner, which collapsed
/// their zero-speed points into long straight chords. Restore the bundled
/// catalog geometry for passes created together with their trail.
enum CatalogPassRepair {
    static let creationTolerance: TimeInterval = 300

    static func repairs(
        inputs: [CatalogPassRepairInput],
        catalogRoutes: [UUID: [RoutePoint]]
    ) -> [RepairedRoute] {
        inputs.compactMap { input in
            guard abs(input.recordedAt.timeIntervalSince(input.trailCreatedAt)) < creationTolerance,
                let points = catalogRoutes[input.trailID],
                points.count >= 2,
                let routeData = try? RouteCodec.encode(points)
            else {
                return nil
            }
            return RepairedRoute(
                id: input.id,
                routeData: routeData,
                distanceMeters: RouteMetrics.distance(of: points),
                verticalMeters: 0,
                maximumSpeedMetersPerSecond: 0)
        }
    }
}

enum DiagnosticSummaryRebuilder {
    static func rebuild(dayID: UUID, logURL: URL) -> RebuiltDaySummary? {
        guard let data = try? Data(contentsOf: logURL),
            let result = try? DiagnosticLogReplayer().replay(data: data),
            !result.segments.isEmpty
        else {
            return nil
        }

        let summaries = result.segments.compactMap { draft -> RebuiltSegmentSummary? in
            guard let cleaned = cleanedRoute(samples: draft.points, kind: draft.kind) else {
                return nil
            }
            return RebuiltSegmentSummary(
                kind: draft.kind,
                runNumber: draft.runNumber,
                trailSequence: draft.trailSequence,
                startedAt: draft.startedAt,
                endedAt: draft.endedAt,
                routeData: cleaned.routeData,
                distanceMeters: cleaned.distance,
                verticalMeters: cleaned.vertical,
                maximumSpeedMetersPerSecond: cleaned.maximumSpeed,
                jumps: draft.jumps.map { $0.resolved(in: cleaned.points) }
            )
        }
        guard !summaries.isEmpty else { return nil }
        return RebuiltDaySummary(dayID: dayID, segments: summaries)
    }

    static func rebuild(dayID: UUID, logURLs: [URL]) -> RebuiltDaySummary? {
        let candidates =
            logURLs
            .compactMap { rebuild(dayID: dayID, logURL: $0) }
            .flatMap(\.segments)
            .sorted { $0.startedAt < $1.startedAt }

        var unique: [RebuiltSegmentSummary] = []
        for candidate in candidates {
            let isDuplicate = unique.contains { existing in
                existing.kind == candidate.kind
                    && abs(existing.startedAt.timeIntervalSince(candidate.startedAt)) < 3
                    && abs(existing.endedAt.timeIntervalSince(candidate.endedAt)) < 3
            }
            if !isDuplicate {
                unique.append(candidate)
            }
        }

        guard !unique.isEmpty else { return nil }
        var nextRunNumber = 1
        let numbered = unique.map { segment -> RebuiltSegmentSummary in
            guard segment.kind == .run else { return segment }
            let runNumber = segment.runNumber ?? nextRunNumber
            nextRunNumber = max(nextRunNumber + 1, runNumber + 1)
            return RebuiltSegmentSummary(
                kind: segment.kind,
                runNumber: runNumber,
                trailSequence: segment.trailSequence,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                routeData: segment.routeData,
                distanceMeters: segment.distanceMeters,
                verticalMeters: segment.verticalMeters,
                maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond,
                jumps: segment.jumps
            )
        }
        return RebuiltDaySummary(dayID: dayID, segments: numbered)
    }

    static func logURLs(dayID: UUID, startedAt: Date, endedAt: Date) -> [URL] {
        let expectedName = "Berms-\(dayID.uuidString).jsonl"
        let range = startedAt.addingTimeInterval(-5)...endedAt.addingTimeInterval(5)
        return allLogURLs()
            .filter { url in
                if url.lastPathComponent.caseInsensitiveCompare(expectedName) == .orderedSame {
                    return true
                }
                guard let firstTimestamp = firstRecordTimestamp(in: url) else { return false }
                return range.contains(firstTimestamp)
            }
            .sorted {
                firstRecordTimestamp(in: $0) ?? .distantPast
                    < firstRecordTimestamp(in: $1) ?? .distantPast
            }
    }

    private static func allLogURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: RideRecorder.diagnosticsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "jsonl" } ?? []
    }

    private static func firstRecordTimestamp(in url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
            let firstLine = data.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }).first
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RawDiagnosticRecord.self, from: Data(firstLine)).timestamp
    }

    static func cleanedRoute(
        samples: [TrackSample],
        kind: SegmentKind
    ) -> (
        routeData: Data, distance: Double,
        vertical: Double, maximumSpeed: Double, points: [RoutePoint]
    )? {
        let cleanedPoints = RouteCleaner().clean(samples).map(\.routePoint)
        guard cleanedPoints.count >= 2, let routeData = try? RouteCodec.encode(cleanedPoints) else {
            return nil
        }
        return (
            routeData,
            RouteMetrics.distance(of: cleanedPoints),
            RouteMetrics.vertical(of: cleanedPoints, kind: kind),
            RouteMetrics.maximumSpeed(of: cleanedPoints),
            cleanedPoints
        )
    }

    static func cleanedRoute(
        points: [RoutePoint],
        kind: SegmentKind
    ) -> (
        routeData: Data, distance: Double,
        vertical: Double, maximumSpeed: Double
    )? {
        let cleanedPoints = RouteCleaner().clean(points)
        guard cleanedPoints.count >= 2, let routeData = try? RouteCodec.encode(cleanedPoints) else {
            return nil
        }
        return (
            routeData,
            RouteMetrics.distance(of: cleanedPoints),
            RouteMetrics.vertical(of: cleanedPoints, kind: kind),
            RouteMetrics.maximumSpeed(of: cleanedPoints)
        )
    }
}

@MainActor
final class RideRecorder: ObservableObject {
    static let shared = RideRecorder()
    private static let diagnosticSummaryVersion = "12"
    private static let diagnosticSummaryVersionKey = "berms.diagnosticSummaryVersion"
    private static let rawMotionLoggingKey = "berms.rawMotionLogging"
    private static let liveActivityMetricKey = "berms.liveActivityMetric"
    private static let liveStatMetricsKey = "berms.liveStatMetrics"
    private static let activityModeKey = "berms.activityMode"

    @Published private(set) var activeDay: RideDay?
    @Published private(set) var phase: DetectorPhase = .idle
    @Published private(set) var activePoints: [TrackSample] = []
    @Published private(set) var lastSample: TrackSample?
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var motionAvailable = true
    @Published private(set) var jumpSensitivity: JumpSensitivity
    @Published private(set) var rawMotionLoggingEnabled: Bool
    @Published private(set) var liveActivityMetric: BermsLiveActivityMetric
    @Published private(set) var liveStatMetrics: [LiveStatMetric]
    @Published private(set) var selectedActivityMode: ActivityMode
    @Published private(set) var isRestoring = false
    @Published private(set) var needsRecoveryPrompt = false
    @Published var errorMessage: String?

    let locationService = LocationService()
    let motionService = MotionService()

    private let context: ModelContext
    private let watchStateSink: WatchRideStateSink?
    private let authorizationOverride: CLAuthorizationStatus?
    private let detector = ParkLapDetector()
    private let jumpDetector: JumpDetector
    private var normalizer = TrackSampleNormalizer()
    private var altitudeFusion = AltitudeFusion()
    private var latestTrackContext: JumpTrackContext?
    private var jumpsForCurrentRun: [JumpEvent] = []
    private var diagnosticLogger: RawLogWriter?
    private var lastSampleTimestamp: Date?
    private var lastCheckpointDate: Date?
    private var lastFootprintLogDate: Date?
    private var trackingBoundaryDate: Date?
    private let maximumTrackingGap: TimeInterval = 60
    private var hasResumed = false
    private var authorizationSubscription: AnyCancellable?
    private var liveActivityNotificationObserver: NSObjectProtocol?
    private var pendingRecoveryDay: RideDay?
    private(set) var migrationTask: Task<Void, Never>?

    init(
        context: ModelContext? = nil,
        watchStateSink: WatchRideStateSink? = WatchConnectivityCoordinator.shared,
        authorizationOverride: CLAuthorizationStatus? = nil
    ) {
        selectedActivityMode =
            ActivityMode(
                rawValue: UserDefaults.standard.string(forKey: Self.activityModeKey) ?? ""
            ) ?? .bikePark
        let storedSensitivity =
            JumpSensitivity(rawValue: UserDefaults.standard.string(forKey: "berms.jumpSensitivity") ?? "")
            ?? .standard
        jumpSensitivity = storedSensitivity
        rawMotionLoggingEnabled = UserDefaults.standard.bool(forKey: Self.rawMotionLoggingKey)
        liveActivityMetric =
            BermsLiveActivityMetric(
                rawValue: UserDefaults.standard.string(forKey: Self.liveActivityMetricKey) ?? ""
            ) ?? .descent
        liveStatMetrics = Self.storedLiveStatMetrics()
        jumpDetector = JumpDetector(configuration: storedSensitivity.configuration)
        self.context = context ?? PersistenceController.shared.container.mainContext
        self.watchStateSink = watchStateSink
        self.authorizationOverride = authorizationOverride
        if let lifts = try? self.context.fetch(FetchDescriptor<LearnedLift>()) {
            detector.setLearnedLifts(lifts.map(\.profile))
        }
        locationAuthorization = authorizationOverride ?? locationService.authorizationStatus
        authorizationSubscription = locationService.$authorizationStatus.sink { [weak self] status in
            self?.locationAuthorization = self?.authorizationOverride ?? status
        }
        liveActivityNotificationObserver = NotificationCenter.default.addObserver(
            forName: BermsLiveActivityCoordinator.togglePauseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = self?.togglePauseFromLiveActivity()
            }
        }
        BermsLiveActivityCoordinator.shared.reconcile()
    }

    nonisolated static var diagnosticsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Berms Diagnostics", isDirectory: true)
    }

    nonisolated static func debugLogURL(for dayID: UUID) -> URL {
        diagnosticsDirectory.appendingPathComponent("Berms-\(dayID.uuidString).jsonl")
    }

    func debugLogURL(for day: RideDay) -> URL? {
        let url = Self.debugLogURL(for: day.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Every diagnostic log that overlaps the day. Stopping and restarting the
    /// recorder during one riding day can leave the day's runs split across
    /// several files, and only one of them carries the day's ID.
    nonisolated static func diagnosticLogURLs(
        for dayID: UUID,
        startedAt: Date,
        endedAt: Date?
    ) -> [URL] {
        DiagnosticSummaryRebuilder.logURLs(
            dayID: dayID,
            startedAt: startedAt,
            endedAt: endedAt ?? startedAt)
    }

    var isRecording: Bool { activeDay != nil }

    var activeActivityMode: ActivityMode {
        activeDay?.activityMode ?? selectedActivityMode
    }

    func setSelectedActivityMode(_ mode: ActivityMode) {
        guard !isRecording, mode != selectedActivityMode else { return }
        selectedActivityMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.activityModeKey)
    }

    private var effectiveAuthorizationStatus: CLAuthorizationStatus {
        authorizationOverride ?? locationService.authorizationStatus
    }

    var currentWatchRideState: WatchRideState {
        guard let day = activeDay else { return .idle }
        let currentRunPoints = phase == .run ? activePoints.map(\.routePoint) : []
        let liveDistance = day.distanceMeters + RouteMetrics.distance(of: currentRunPoints)
        let liveDescent = day.descentMeters + RouteMetrics.vertical(of: currentRunPoints, kind: .run)
        return WatchRideState(
            status: day.isPaused ? .paused : .recording,
            rideID: day.id.uuidString,
            phase: phase.rawValue,
            startedAt: day.startedAt,
            elapsedSeconds: day.duration,
            distanceMeters: liveDistance,
            descentMeters: liveDescent,
            speedMetersPerSecond: currentSpeed,
            run: currentRunMetrics,
            updatedAt: .now,
            activityModeRawValue: day.activityMode.rawValue
        )
    }

    var currentRunMetrics: WatchRideState.RunMetrics? {
        guard let day = activeDay else { return nil }
        let runs = day.segments.filter { $0.kind == .run }
        if phase == .run {
            let points = RouteCleaner().clean(activePoints.map(\.routePoint))
            return .init(
                number: runs.count + 1,
                distanceMeters: RouteMetrics.distance(of: points),
                descentMeters: RouteMetrics.vertical(of: points, kind: .run),
                topSpeedMetersPerSecond: RouteMetrics.maximumSpeed(of: points),
                longestJumpAirtime: jumpsForCurrentRun.map(\.airtime).max() ?? 0,
                jumpCount: jumpsForCurrentRun.count)
        }
        guard let lastRun = runs.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        return .init(
            number: runs.count,
            distanceMeters: lastRun.distanceMeters,
            descentMeters: lastRun.verticalMeters,
            topSpeedMetersPerSecond: lastRun.maximumSpeedMetersPerSecond,
            longestJumpAirtime: lastRun.jumps.map(\.airtime).max() ?? 0,
            jumpCount: lastRun.jumps.count)
    }

    var isPaused: Bool { activeDay?.isPaused == true }

    var activeSegmentKind: SegmentKind? {
        switch phase {
        case .run: .run
        case .lift: .lift
        case .idle: nil
        }
    }

    var currentAltitude: Double? { lastSample?.altitude }

    var currentSpeed: Double { isPaused ? 0 : (lastSample?.speed ?? 0) }

    var currentRelativeAltitude: Double? { motionService.relativeAltitude }

    var completedRunCount: Int {
        (activeDay?.segments ?? []).filter { $0.kind == .run }.count
    }

    var completedLiftCount: Int {
        (activeDay?.segments ?? []).filter { $0.kind == .lift }.count
    }

    var activeJumpCount: Int {
        (activeDay?.jumpCount ?? 0) + jumpsForCurrentRun.count
    }

    var activeLongestJumpAirtime: TimeInterval {
        max(activeDay?.longestJumpAirtime ?? 0, jumpsForCurrentRun.map(\.airtime).max() ?? 0)
    }

    var activeTotalJumpAirtime: TimeInterval {
        let completed = (activeDay?.segments ?? [])
            .filter { $0.kind == .run }
            .flatMap(\.jumps)
            .reduce(0) { $0 + $1.airtime }
        return completed + jumpsForCurrentRun.reduce(0) { $0 + $1.airtime }
    }

    var activeLongestJumpLength: Double {
        max(completedJumpMaximum(\.lengthMeters), currentRunJumpMaximum(\.lengthMeters))
    }

    var activeHighestJump: Double {
        max(completedJumpMaximum(\.heightMeters), currentRunJumpMaximum(\.heightMeters))
    }

    var activeBiggestJumpDrop: Double {
        max(completedJumpMaximum(\.dropMeters), currentRunJumpMaximum(\.dropMeters))
    }

    /// Jumps from the in-progress run, measured against the route so far. A jump
    /// detected seconds ago gains its landing point as GPS catches up.
    private var resolvedLiveJumps: [JumpEvent] {
        guard !jumpsForCurrentRun.isEmpty else { return [] }
        let routePoints = activePoints.map(\.routePoint)
        guard routePoints.count >= 2 else { return jumpsForCurrentRun }
        return jumpsForCurrentRun.map { $0.resolved(in: routePoints) }
    }

    private func completedJumpMaximum(_ keyPath: KeyPath<JumpEvent, Double?>) -> Double {
        (activeDay?.segments ?? [])
            .filter { $0.kind == .run }
            .flatMap(\.jumps)
            .compactMap { $0[keyPath: keyPath] }
            .max() ?? 0
    }

    private func currentRunJumpMaximum(_ keyPath: KeyPath<JumpEvent, Double?>) -> Double {
        resolvedLiveJumps.compactMap { $0[keyPath: keyPath] }.max() ?? 0
    }

    var activeTopSpeed: Double {
        let currentRunPoints = phase == .run ? activePoints.map(\.routePoint) : []
        return max(
            activeDay?.maximumSpeedMetersPerSecond ?? 0,
            RouteMetrics.maximumSpeed(of: currentRunPoints))
    }

    var currentMapPoints: [RoutePoint] {
        RouteCleaner().clean(activePoints.map(\.routePoint))
    }

    func elapsed(at date: Date = .now) -> TimeInterval {
        activeDay?.duration(at: date) ?? 0
    }

    func setJumpSensitivity(_ sensitivity: JumpSensitivity) {
        guard sensitivity != jumpSensitivity else { return }
        jumpSensitivity = sensitivity
        UserDefaults.standard.set(sensitivity.rawValue, forKey: "berms.jumpSensitivity")
        jumpDetector.update(configuration: sensitivity.configuration)
        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "jump_detector_sensitivity_changed",
                detail: "sensitivity=\(sensitivity.rawValue),\(jumpDetector.configurationSummary)"
            ))
    }

    func setRawMotionLoggingEnabled(_ enabled: Bool) {
        guard enabled != rawMotionLoggingEnabled else { return }
        rawMotionLoggingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.rawMotionLoggingKey)
        diagnosticLogger?.append(
            RawDiagnosticRecord(
                kind: "raw_motion_logging_changed",
                detail: "enabled=\(enabled)"
            ))
    }

    func setLiveActivityMetric(_ metric: BermsLiveActivityMetric) {
        guard metric != liveActivityMetric else { return }
        liveActivityMetric = metric
        UserDefaults.standard.set(metric.rawValue, forKey: Self.liveActivityMetricKey)
        updateLiveActivity(force: true)
    }

    func setLiveStatMetric(_ metric: LiveStatMetric, enabled: Bool) {
        var metrics = liveStatMetrics
        if enabled {
            guard !metrics.contains(metric) else { return }
            metrics.append(metric)
        } else {
            guard metrics.contains(metric) else { return }
            metrics.removeAll { $0 == metric }
        }
        metrics.sort { lhs, rhs in
            let left = LiveStatMetric.allCases.firstIndex(of: lhs) ?? 0
            let right = LiveStatMetric.allCases.firstIndex(of: rhs) ?? 0
            return left < right
        }
        liveStatMetrics = metrics
        UserDefaults.standard.set(metrics.map(\.rawValue), forKey: Self.liveStatMetricsKey)
    }

    private static func storedLiveStatMetrics() -> [LiveStatMetric] {
        guard UserDefaults.standard.object(forKey: liveStatMetricsKey) != nil else {
            return LiveStatMetric.defaultSelection
        }
        let stored = UserDefaults.standard.stringArray(forKey: liveStatMetricsKey) ?? []
        return stored.compactMap(LiveStatMetric.init(rawValue:))
    }

    private static func pruneOldDiagnosticLogs() {
        let fileManager = FileManager.default
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: diagnosticsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return }
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
        for url in urls where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let modified = values.contentModificationDate,
                modified < cutoff
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

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

        let day = RideDay()
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
                        "Berms recording started; mode=\(mode.rawValue),catalog=\(TrailCatalogSelection.persistedCatalogID() ?? "automatic")"
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
        checkpointIfNeeded(at: .now, force: true)
        diagnosticLogger?.flush()
    }

    @discardableResult
    func pause() -> Bool {
        guard let day = activeDay, !day.isPaused else { return false }
        let pauseDate = Date.now
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
        let resumeDate = Date.now
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
        let stopDate = Date.now
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
        day.catalogID = TrailCatalogRegistry.resolvedCatalogID(
            mode: day.activityMode,
            manualSelectionID: TrailCatalogSelection.persistedCatalogID(),
            firstPoint: day.firstRecordedCoordinate)
        clearCheckpoint(for: day)
        updateTotals(for: day)
        guard saveContext(detail: "stop") else {
            day.endedAt = nil
            day.catalogID = nil
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

    private func finishOpenSegment(to day: RideDay, reason: String) {
        for event in jumpDetector.finish() {
            handleJumpEvent(event)
        }
        if let event = detector.finish(), case .finished(let draft) = event {
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "detector_finished", timestamp: draft.endedAt,
                    runNumber: draft.kind == .run ? completedRunCount + 1 : nil,
                    trailSequence: trailSequence(for: draft),
                    phaseBefore: draft.kind.rawValue, detail: reason))
            save(draft, to: day)
        }
    }

    private func resetTrackingState(clearLastSample: Bool, resetAltitudeFusion: Bool = true) {
        detector.reset()
        activePoints = []
        if clearLastSample {
            lastSample = nil
        }
        lastSampleTimestamp = nil
        trackingBoundaryDate = nil
        normalizer.seed(with: nil)
        if resetAltitudeFusion {
            altitudeFusion.reset(barometerAvailable: false)
        }
        jumpDetector.reset()
        jumpsForCurrentRun.removeAll(keepingCapacity: true)
        latestTrackContext = nil
        lastCheckpointDate = nil
        phase = .idle
    }

    private func clearCheckpoint(for day: RideDay) {
        day.checkpointData = nil
        day.checkpointKind = nil
        day.checkpointStartedAt = nil
    }

    @discardableResult
    func rebuildSummaryFromDiagnosticLog(for day: RideDay, from url: URL) -> Bool {
        guard day.isFinished,
            let summary = DiagnosticSummaryRebuilder.rebuild(dayID: day.id, logURL: url),
            reconcile(summary, to: day)
        else {
            return false
        }
        return saveContext(detail: "diagnostic_summary_rebuild")
    }

    private func reconcile(_ summary: RebuiltDaySummary, to day: RideDay) -> Bool {
        let existing = day.segments.sorted { $0.startedAt < $1.startedAt }
        let rebuilt = summary.segments.sorted { $0.startedAt < $1.startedAt }
        guard !rebuilt.isEmpty,
            existing.count == rebuilt.count,
            zip(existing, rebuilt).allSatisfy({ $0.kind == $1.kind })
        else {
            return false
        }

        for (segment, replacement) in zip(existing, rebuilt) {
            segment.startedAt = replacement.startedAt
            segment.endedAt = replacement.endedAt
            segment.routeData = replacement.routeData
            segment.jumpData = try? JSONEncoder().encode(replacement.jumps)
            segment.distanceMeters = replacement.distanceMeters
            segment.verticalMeters = replacement.verticalMeters
            segment.maximumSpeedMetersPerSecond = replacement.maximumSpeedMetersPerSecond
        }
        day.segments = existing
        day.recalculateTotals()
        return true
    }

    private struct SegmentRepairInput: Sendable {
        let id: UUID
        let kind: SegmentKind
        let routeData: Data
    }

    private struct RepairDayInput: Sendable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let segmentKinds: [SegmentKind]
    }

    private func startDiagnosticMigrationIfNeeded() {
        guard
            UserDefaults.standard.string(forKey: Self.diagnosticSummaryVersionKey)
                != Self.diagnosticSummaryVersion,
            migrationTask == nil
        else { return }

        let dayInputs: [RepairDayInput]
        let segmentInputs: [SegmentRepairInput]
        let passInputs: [CatalogPassRepairInput]
        do {
            let days = try context.fetch(FetchDescriptor<RideDay>()).filter(\.isFinished)
            dayInputs = days.map {
                RepairDayInput(
                    id: $0.id,
                    startedAt: $0.startedAt,
                    endedAt: $0.endedAt ?? $0.startedAt,
                    segmentKinds: $0.segments.sorted { $0.startedAt < $1.startedAt }.map(\.kind)
                )
            }
            segmentInputs = try context.fetch(FetchDescriptor<RideSegment>()).map {
                SegmentRepairInput(id: $0.id, kind: $0.kind, routeData: $0.routeData)
            }
            passInputs = try context.fetch(FetchDescriptor<TrailPass>()).compactMap { pass in
                guard let trail = pass.trail else { return nil }
                return CatalogPassRepairInput(
                    id: pass.id, trailID: trail.id,
                    trailCreatedAt: trail.createdAt,
                    recordedAt: pass.recordedAt)
            }
        } catch {
            errorMessage = "Could not update saved session summaries. Please try again."
            return
        }

        migrationTask = Task { [weak self] in
            let work = await Task.detached(priority: .utility) {
                () -> ([RebuiltDaySummary], [RepairedRoute], [RepairedRoute]) in
                let rebuiltDays = dayInputs.compactMap { input -> RebuiltDaySummary? in
                    let logURLs = DiagnosticSummaryRebuilder.logURLs(
                        dayID: input.id,
                        startedAt: input.startedAt,
                        endedAt: input.endedAt
                    )
                    guard
                        let summary = DiagnosticSummaryRebuilder.rebuild(
                            dayID: input.id,
                            logURLs: logURLs
                        ),
                        summary.segments.count == input.segmentKinds.count,
                        summary.segments.sorted(by: { $0.startedAt < $1.startedAt }).map(\.kind)
                            == input.segmentKinds
                    else {
                        return nil
                    }
                    return summary
                }
                let repairedSegments = segmentInputs.compactMap { input -> RepairedRoute? in
                    guard let points = try? RouteCodec.decode(input.routeData),
                        let cleaned = DiagnosticSummaryRebuilder.cleanedRoute(
                            points: points,
                            kind: input.kind)
                    else {
                        return nil
                    }
                    return RepairedRoute(
                        id: input.id,
                        routeData: cleaned.routeData,
                        distanceMeters: cleaned.distance,
                        verticalMeters: cleaned.vertical,
                        maximumSpeedMetersPerSecond: cleaned.maximumSpeed)
                }
                let catalogRoutePoints = TrailCatalogRegistry.catalogs.reduce(
                    into: [UUID: [RoutePoint]]()
                ) { routes, catalog in
                    routes.merge(TrailCatalogImporter.bundledRoutePoints(catalog: catalog)) {
                        current, _ in current
                    }
                }
                let repairedPasses = CatalogPassRepair.repairs(
                    inputs: passInputs,
                    catalogRoutes: catalogRoutePoints
                )
                return (rebuiltDays, repairedSegments, repairedPasses)
            }.value
            guard let self else { return }
            self.applyDiagnosticMigration(
                rebuiltDays: work.0,
                repairedSegments: work.1,
                repairedPasses: work.2)
        }
    }

    private func applyDiagnosticMigration(
        rebuiltDays: [RebuiltDaySummary],
        repairedSegments: [RepairedRoute],
        repairedPasses: [RepairedRoute]
    ) {
        defer { migrationTask = nil }

        if let segments = try? context.fetch(FetchDescriptor<RideSegment>()) {
            let segmentsByID = Dictionary(
                segments.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            for repair in repairedSegments {
                guard let segment = segmentsByID[repair.id] else { continue }
                segment.routeData = repair.routeData
                segment.distanceMeters = repair.distanceMeters
                segment.verticalMeters = repair.verticalMeters
                segment.maximumSpeedMetersPerSecond = repair.maximumSpeedMetersPerSecond
            }
        }

        var repairedTrailIDs = Set<UUID>()
        if let passes = try? context.fetch(FetchDescriptor<TrailPass>()) {
            let passesByID = Dictionary(passes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for repair in repairedPasses {
                guard let pass = passesByID[repair.id] else { continue }
                if let trailID = pass.trail?.id {
                    repairedTrailIDs.insert(trailID)
                }
                pass.routeData = repair.routeData
                pass.distanceMeters = repair.distanceMeters
            }
        }

        // Trail.points prefers the cached average over its passes. Rebuilding a
        // repaired pass without rebuilding that average leaves the old, thinned
        // centerline on every map that reads Trail.points.
        if !repairedTrailIDs.isEmpty,
            let trails = try? context.fetch(FetchDescriptor<Trail>())
        {
            for trail in trails where repairedTrailIDs.contains(trail.id) {
                trail.recalculateAverage()
            }
        }

        if let days = try? context.fetch(FetchDescriptor<RideDay>()) {
            let daysByID = Dictionary(
                days.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            for summary in rebuiltDays {
                guard let day = daysByID[summary.dayID] else { continue }
                _ = reconcile(summary, to: day)
            }
        }

        if let days = try? context.fetch(FetchDescriptor<RideDay>()) {
            for day in days where day.isFinished {
                day.recalculateTotals()
                for segment in day.segments where segment.kind == .lift {
                    learnLiftProfile(from: segment)
                }
            }
        }

        guard saveContext(detail: "diagnostic_summary_migration") else { return }
        UserDefaults.standard.set(
            Self.diagnosticSummaryVersion,
            forKey: Self.diagnosticSummaryVersionKey)
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

    func requestPermissionsIfNeeded() {
        locationService.start { [weak self] location, stationary in
            self?.consume(location: location, isStationary: stationary)
        }
        locationService.stop()
        locationAuthorization = locationService.authorizationStatus
    }

    private func startSensors() {
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

    private func consume(location: CLLocation, isStationary: Bool) {
        guard let day = activeDay, !day.isPaused else { return }
        let arrivalDate = Date.now
        let arrivalMonotonicSeconds = ProcessInfo.processInfo.systemUptime
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
                abs(location.timestamp.timeIntervalSince($0)) <= 10
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
        guard let sample = normalizer.normalize(rawSample) else {
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

    private func consume(deviceMotion sample: DeviceMotionSample) {
        guard activeDay != nil, !isPaused, let context = latestTrackContext else { return }
        if let trackingBoundaryDate, sample.recordedAt < trackingBoundaryDate { return }
        for event in jumpDetector.process(sample, context: context) {
            handleJumpEvent(event)
        }
    }

    @discardableResult
    func togglePauseFromLiveActivity() -> Bool {
        guard activeDay != nil else { return false }
        return isPaused ? resume() : pause()
    }

    private func updateLiveActivity(force: Bool = false) {
        guard let day = activeDay else { return }
        BermsLiveActivityCoordinator.shared.update(
            phase: phase,
            isPaused: day.isPaused,
            runCount: completedRunCount,
            startedAt: day.startedAt,
            elapsed: day.duration,
            distance: day.distanceMeters,
            descent: day.descentMeters,
            topSpeed: activeTopSpeed,
            metric: liveActivityMetric,
            jumpCount: activeJumpCount,
            liftCount: completedLiftCount,
            longestAirtime: activeLongestJumpAirtime,
            totalAirtime: activeTotalJumpAirtime,
            activityModeRawValue: day.activityMode.rawValue,
            force: force
        )
        watchStateSink?.publish(currentWatchRideState, force: force)
    }

    private func handleJumpEvent(_ event: JumpDetectorEvent) {
        switch event {
        case .detected(let jump):
            guard activeDay != nil, latestTrackContext?.phase == .run else { return }
            objectWillChange.send()
            jumpsForCurrentRun.append(jump)
            updateLiveActivity(force: true)
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "jump_detected",
                    timestamp: jump.landingTimestamp,
                    monotonicSeconds: jump.landingMonotonicSeconds,
                    runEligible: true,
                    accepted: true,
                    detectorVersion: jumpDetector.detectorVersion,
                    jumpAirtime: jump.airtime,
                    jumpTakeoffMonotonicSeconds: jump.takeoffMonotonicSeconds,
                    jumpLandingMonotonicSeconds: jump.landingMonotonicSeconds,
                    detail: "airborne interval confirmed"
                ))
        case .diagnostic(let kind, let timestamp, let monotonicSeconds, let detail):
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: kind,
                    timestamp: timestamp,
                    monotonicSeconds: monotonicSeconds,
                    runEligible: latestTrackContext?.phase == .run,
                    accepted: kind == "jump_candidate_started",
                    detectorVersion: jumpDetector.detectorVersion,
                    jumpReason: kind == "jump_candidate_rejected" ? detail : nil,
                    detail: detail
                ))
        }
    }

    private func handle(_ event: DetectorEvent) {
        guard let day = activeDay else { return }
        switch event {
        case .started(let kind, let points):
            jumpDetector.reset()
            if kind == .run {
                jumpsForCurrentRun.removeAll(keepingCapacity: true)
            }
            phase = kind == .lift ? .lift : .run
            activePoints = points
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "detector_started",
                    timestamp: points.first?.timestamp ?? .now,
                    runNumber: kind == .run ? completedRunCount + 1 : nil,
                    phaseAfter: kind.rawValue,
                    detail: kind.title))
            checkpointIfNeeded(at: points.last?.timestamp ?? .now, force: true)
        case .updated:
            activePoints = detector.currentPoints
        case .finished(let draft):
            for jumpEvent in jumpDetector.finish() {
                handleJumpEvent(jumpEvent)
            }
            let runNumber = draft.kind == .run ? completedRunCount + 1 : nil
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "detector_finished", timestamp: draft.endedAt,
                    runNumber: runNumber,
                    trailSequence: trailSequence(for: draft),
                    phaseBefore: draft.kind.rawValue, detail: draft.kind.title))
            save(draft, to: day)
            updateTotals(for: day)
            saveContext(detail: "totals")
            jumpDetector.reset()
        }
    }

    private func checkpointIfNeeded(at date: Date, force: Bool = false) {
        guard let day = activeDay, let kind = activeSegmentKind, !activePoints.isEmpty else { return }
        guard force || lastCheckpointDate.map({ date.timeIntervalSince($0) >= 12 }) ?? true else { return }
        guard
            let data = try? JSONEncoder().encode(
                RecorderCheckpoint(
                    points: activePoints,
                    jumps: activeSegmentKind == .run ? jumpsForCurrentRun : []
                ))
        else { return }
        day.checkpointKind = kind.rawValue
        day.checkpointStartedAt = activePoints.first?.timestamp
        day.checkpointData = data
        lastCheckpointDate = date
        saveContext(detail: "checkpoint")
    }

    private func save(_ draft: SegmentDraft, to day: RideDay) {
        let cleanedPoints = RouteCleaner().clean(draft.points).map(\.routePoint)
        guard cleanedPoints.count >= 2, let data = try? RouteCodec.encode(cleanedPoints) else { return }
        let rawJumps = draft.kind == .run ? (draft.jumps.isEmpty ? jumpsForCurrentRun : draft.jumps) : []
        let jumps = rawJumps.map { $0.resolved(in: cleanedPoints) }
        let segment = RideSegment(
            kind: draft.kind, startedAt: draft.startedAt,
            endedAt: draft.endedAt, routeData: data, jumps: jumps)
        segment.distanceMeters = RouteMetrics.distance(of: cleanedPoints)
        segment.verticalMeters = RouteMetrics.vertical(of: cleanedPoints, kind: draft.kind)
        segment.maximumSpeedMetersPerSecond = RouteMetrics.maximumSpeed(of: cleanedPoints)
        segment.day = day
        day.segments.append(segment)
        context.insert(segment)
        if draft.kind == .run {
            jumpsForCurrentRun.removeAll(keepingCapacity: true)
        } else {
            learnLiftProfile(from: segment)
        }
        day.checkpointKind = nil
        day.checkpointStartedAt = nil
        day.checkpointData = nil
        saveContext(detail: "segment_\(draft.kind.rawValue)")
    }

    private func learnLiftProfile(from segment: RideSegment) {
        let engine = LiftLearningEngine()
        guard let observation = engine.observations(from: [segment]).first,
            let storedLifts = try? context.fetch(FetchDescriptor<LearnedLift>())
        else { return }

        let profiles = engine.merge(observation: observation, into: storedLifts.map(\.profile))
        let storedByID = Dictionary(uniqueKeysWithValues: storedLifts.map { ($0.id, $0) })
        for profile in profiles {
            if let stored = storedByID[profile.id] {
                stored.bottomLatitude = profile.bottom.latitude
                stored.bottomLongitude = profile.bottom.longitude
                stored.topLatitude = profile.top.latitude
                stored.topLongitude = profile.top.longitude
                stored.bottomRadius = profile.bottomRadius
                stored.topRadius = profile.topRadius
                stored.observationCount = profile.observationCount
                stored.confidence = profile.confidence
                stored.lastObservedAt = .now
            } else {
                context.insert(LearnedLift(profile: profile))
            }
        }
        detector.setLearnedLifts(profiles)
    }

    /// Periodic footprint sampling so a background session leaves evidence if
    /// the system terminates it for memory.
    private func logMemoryFootprint(at date: Date = .now, force: Bool = false) {
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

    @discardableResult
    private func saveContext(detail: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            errorMessage =
                "Could not save your session. Keep Berms open and try Finish again. \(error.localizedDescription)"
            diagnosticLogger?.append(
                RawDiagnosticRecord(
                    kind: "persistence_error",
                    accepted: false,
                    detail: "\(detail): \(error.localizedDescription)"
                ))
            return false
        }
    }

    private func trailSequence(for draft: SegmentDraft) -> [String]? {
        guard draft.kind == .run else { return nil }
        guard let trails = try? context.fetch(FetchDescriptor<Trail>()), !trails.isEmpty else {
            return nil
        }
        let candidates = trails.map {
            TrailRouteCandidate(
                id: $0.id, name: $0.name, difficulty: $0.difficulty,
                routes: $0.matcherRoutes)
        }
        let route = RouteCleaner().clean(draft.points).map(\.routePoint)
        let result = TrailRouteMatcher().matchResult(for: route, candidates: candidates)
        var names: [String] = []
        for name in result.sections.compactMap({ section in
            candidates.first(where: { $0.id == section.trailID })?.name
        }) where names.last != name {
            names.append(name)
        }
        return names.isEmpty ? nil : names
    }

    private func updateTotals(for day: RideDay) {
        day.recalculateTotals()
    }
}
