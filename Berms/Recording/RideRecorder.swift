import Combine
import CoreLocation
import Darwin
import Foundation
import SwiftData

@MainActor
final class RideRecorder: ObservableObject {
    static let shared = RideRecorder()
    static let diagnosticSummaryVersion = "12"
    static let diagnosticSummaryVersionKey = "berms.diagnosticSummaryVersion"
    private static let rawMotionLoggingKey = "berms.rawMotionLogging"
    private static let liveActivityMetricKey = "berms.liveActivityMetric"
    private static let liveStatMetricsKey = "berms.liveStatMetrics"
    static let activityModeKey = "berms.activityMode"

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

    let context: ModelContext
    let watchStateSink: WatchRideStateSink?
    private let authorizationOverride: CLAuthorizationStatus?
    let now: () -> Date
    let uptime: () -> TimeInterval
    let detector = ParkLapDetector()
    let jumpDetector: JumpDetector
    var normalizer = TrackSampleNormalizer()
    var altitudeFusion = AltitudeFusion()
    var latestTrackContext: JumpTrackContext?
    var jumpsForCurrentRun: [JumpEvent] = []
    var diagnosticLogger: RawLogWriter?
    var lastSampleTimestamp: Date?
    var lastCheckpointDate: Date?
    var lastFootprintLogDate: Date?
    var trackingBoundaryDate: Date?
    let maximumTrackingGap: TimeInterval = 60
    var hasResumed = false
    private var authorizationSubscription: AnyCancellable?
    private var liveActivityNotificationObserver: NSObjectProtocol?
    var pendingRecoveryDay: RideDay?
    private(set) var migrationTask: Task<Void, Never>?

    init(
        context: ModelContext? = nil,
        watchStateSink: WatchRideStateSink? = WatchConnectivityCoordinator.shared,
        authorizationOverride: CLAuthorizationStatus? = nil,
        now: (() -> Date)? = nil,
        uptime: (() -> TimeInterval)? = nil
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
        self.now = now ?? { .now }
        self.uptime = uptime ?? { ProcessInfo.processInfo.systemUptime }
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

    var effectiveAuthorizationStatus: CLAuthorizationStatus {
        authorizationOverride ?? locationService.authorizationStatus
    }

    // The recorder extensions write this session state, and `private` setters
    // do not cross files. Keep those writes funneled through these mutators so
    // no other file can move recording state around directly.
    func adoptSession(_ day: RideDay) {
        activeDay = day
    }

    func clearActiveSession() {
        activeDay = nil
    }

    func adoptActivityMode(_ mode: ActivityMode) {
        selectedActivityMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.activityModeKey)
    }

    func setPhase(_ phase: DetectorPhase) {
        self.phase = phase
    }

    func setActivePoints(_ points: [TrackSample]) {
        activePoints = points
    }

    func setLastSample(_ sample: TrackSample?) {
        lastSample = sample
    }

    func setLocationAuthorization(_ status: CLAuthorizationStatus) {
        locationAuthorization = status
    }

    func setMotionAvailable(_ available: Bool) {
        motionAvailable = available
    }

    func setRestoring(_ restoring: Bool) {
        isRestoring = restoring
    }

    func setNeedsRecoveryPrompt(_ needsPrompt: Bool) {
        needsRecoveryPrompt = needsPrompt
    }

    func setMigrationTask(_ task: Task<Void, Never>?) {
        migrationTask = task
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
            updatedAt: now(),
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
            guard !metrics.contains(metric),
                metrics.count < LiveStatMetric.selectionLimit
            else { return }
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
        return Array(
            stored.compactMap(LiveStatMetric.init(rawValue:))
                .prefix(LiveStatMetric.selectionLimit))
    }

    @discardableResult
    func saveContext(detail: String) -> Bool {
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
}
