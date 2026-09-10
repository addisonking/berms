import Combine
import CoreLocation
import Foundation
import SwiftData

struct RawDiagnosticRecord: Codable, Sendable {
    let kind: String
    let timestamp: Date
    let monotonicSeconds: Double
    let latitude: Double?
    let longitude: Double?
    let gpsAltitude: Double?
    let fusedAltitude: Double?
    let relativeAltitude: Double?
    let pressureKPa: Double?
    let trackMonotonicSeconds: Double?
    let speed: Double?
    let course: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    let userAccelerationX: Double?
    let userAccelerationY: Double?
    let userAccelerationZ: Double?
    let rotationRateX: Double?
    let rotationRateY: Double?
    let rotationRateZ: Double?
    let gravityX: Double?
    let gravityY: Double?
    let gravityZ: Double?
    let quaternionW: Double?
    let quaternionX: Double?
    let quaternionY: Double?
    let quaternionZ: Double?
    let stationary: Bool?
    let cycling: Bool?
    let automotive: Bool?
    let runEligible: Bool?
    let accepted: Bool?
    let phaseBefore: String?
    let phaseAfter: String?
    let detectorVersion: String?
    let jumpAirtime: Double?
    let jumpTakeoffMonotonicSeconds: Double?
    let jumpLandingMonotonicSeconds: Double?
    let jumpReason: String?
    let detail: String?

    init(kind: String, timestamp: Date = .now, monotonicSeconds: Double = ProcessInfo.processInfo.systemUptime,
         latitude: Double? = nil, longitude: Double? = nil, gpsAltitude: Double? = nil,
         fusedAltitude: Double? = nil, relativeAltitude: Double? = nil, pressureKPa: Double? = nil,
         trackMonotonicSeconds: Double? = nil, speed: Double? = nil,
         course: Double? = nil, horizontalAccuracy: Double? = nil, verticalAccuracy: Double? = nil,
         userAccelerationX: Double? = nil, userAccelerationY: Double? = nil, userAccelerationZ: Double? = nil,
         rotationRateX: Double? = nil, rotationRateY: Double? = nil, rotationRateZ: Double? = nil,
         gravityX: Double? = nil, gravityY: Double? = nil, gravityZ: Double? = nil,
         quaternionW: Double? = nil, quaternionX: Double? = nil, quaternionY: Double? = nil,
         quaternionZ: Double? = nil, stationary: Bool? = nil, cycling: Bool? = nil, automotive: Bool? = nil,
         runEligible: Bool? = nil, accepted: Bool? = nil, phaseBefore: String? = nil, phaseAfter: String? = nil,
         detectorVersion: String? = nil, jumpAirtime: Double? = nil,
         jumpTakeoffMonotonicSeconds: Double? = nil, jumpLandingMonotonicSeconds: Double? = nil,
         jumpReason: String? = nil, detail: String? = nil) {
        self.kind = kind
        self.timestamp = timestamp
        self.monotonicSeconds = monotonicSeconds
        self.latitude = latitude
        self.longitude = longitude
        self.gpsAltitude = gpsAltitude
        self.fusedAltitude = fusedAltitude
        self.relativeAltitude = relativeAltitude
        self.pressureKPa = pressureKPa
        self.trackMonotonicSeconds = trackMonotonicSeconds
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.userAccelerationX = userAccelerationX
        self.userAccelerationY = userAccelerationY
        self.userAccelerationZ = userAccelerationZ
        self.rotationRateX = rotationRateX
        self.rotationRateY = rotationRateY
        self.rotationRateZ = rotationRateZ
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.quaternionW = quaternionW
        self.quaternionX = quaternionX
        self.quaternionY = quaternionY
        self.quaternionZ = quaternionZ
        self.stationary = stationary
        self.cycling = cycling
        self.automotive = automotive
        self.runEligible = runEligible
        self.accepted = accepted
        self.phaseBefore = phaseBefore
        self.phaseAfter = phaseAfter
        self.detectorVersion = detectorVersion
        self.jumpAirtime = jumpAirtime
        self.jumpTakeoffMonotonicSeconds = jumpTakeoffMonotonicSeconds
        self.jumpLandingMonotonicSeconds = jumpLandingMonotonicSeconds
        self.jumpReason = jumpReason
        self.detail = detail
    }
}

final class RawLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.addis.berms.raw-log", qos: .utility)
    private var handle: FileHandle?

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func append(_ record: RawDiagnosticRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
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
final class PersistenceController {
    static let shared = PersistenceController()
    let container: ModelContainer

    private init() {
        do {
            let schema = Schema([RideDay.self, RideSegment.self, Trail.self, TrailPass.self, LearnedLift.self])
            let configuration = ModelConfiguration("Berms", schema: schema, isStoredInMemoryOnly: false)
            container = try ModelContainer(for: schema, configurations: [configuration])
            do {
                for result in try TrailCatalogImporter.importCatalogsIfNeeded(
                    into: container.mainContext
                ) {
                    print("Imported \(result.catalog.resortName) trails: "
                        + "\(result.summary.trailsCreated) trails, "
                        + "\(result.summary.passesCreated) passes")
                }
            } catch {
                print("Trail catalog import skipped: \(error.localizedDescription)")
            }
        } catch {
            fatalError("Could not create Berms storage: \(error)")
        }
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

@MainActor
final class RideRecorder: ObservableObject {
    static let shared = RideRecorder()
    private static let diagnosticSummaryVersion = "6"

    @Published private(set) var activeDay: RideDay?
    @Published private(set) var phase: DetectorPhase = .idle
    @Published private(set) var activePoints: [TrackSample] = []
    @Published private(set) var lastSample: TrackSample?
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var motionAvailable = true
    @Published private(set) var jumpSensitivity: JumpSensitivity
    @Published private(set) var isRestoring = false
    @Published private(set) var needsRecoveryPrompt = false
    @Published var errorMessage: String?

    let locationService = LocationService()
    let motionService = MotionService()

    private let context: ModelContext
    private let watchStateSink: WatchRideStateSink?
    private let detector = ParkLapDetector()
    private let jumpDetector: JumpDetector
    private var normalizer = TrackSampleNormalizer()
    private var altitudeFusion = AltitudeFusion()
    private var latestTrackContext: JumpTrackContext?
    private var jumpsForCurrentRun: [JumpEvent] = []
    private var diagnosticLogger: RawLogWriter?
    private var lastSampleTimestamp: Date?
    private var lastCheckpointDate: Date?
    private var trackingBoundaryDate: Date?
    private let maximumTrackingGap: TimeInterval = 60
    private var hasResumed = false
    private var authorizationSubscription: AnyCancellable?
    private var liveActivityNotificationObserver: NSObjectProtocol?
    private var pendingRecoveryDay: RideDay?
    private var automaticallyRestoredOnLaunch = false

    init(context: ModelContext? = nil,
         watchStateSink: WatchRideStateSink? = WatchConnectivityCoordinator.shared) {
        let storedSensitivity = JumpSensitivity(rawValue: UserDefaults.standard.string(forKey: "berms.jumpSensitivity") ?? "")
            ?? .standard
        jumpSensitivity = storedSensitivity
        jumpDetector = JumpDetector(configuration: storedSensitivity.configuration)
        self.context = context ?? PersistenceController.shared.container.mainContext
        self.watchStateSink = watchStateSink
        if let lifts = try? self.context.fetch(FetchDescriptor<LearnedLift>()) {
            detector.setLearnedLifts(lifts.map(\.profile))
        }
        locationAuthorization = locationService.authorizationStatus
        authorizationSubscription = locationService.$authorizationStatus.sink { [weak self] status in
            self?.locationAuthorization = status
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

    static func debugLogURL(for dayID: UUID) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Berms Diagnostics", isDirectory: true)
            .appendingPathComponent("Berms-\(dayID.uuidString).jsonl")
    }

    func debugLogURL(for day: RideDay) -> URL? {
        let url = Self.debugLogURL(for: day.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var isRecording: Bool { activeDay != nil }

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
            updatedAt: .now
        )
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
        diagnosticLogger?.append(RawDiagnosticRecord(
            kind: "jump_detector_sensitivity_changed",
            detail: "sensitivity=\(sensitivity.rawValue),\(jumpDetector.configurationSummary)"
        ))
    }

    @discardableResult
    func start() -> Bool {
        guard activeDay == nil else { return false }
        guard locationService.authorizationStatus != .denied,
              locationService.authorizationStatus != .restricted else { return false }

        let day = RideDay()
        context.insert(day)
        do {
            try context.save()
            activeDay = day
            diagnosticLogger = RawLogWriter(url: Self.debugLogURL(for: day.id))
            diagnosticLogger?.append(RawDiagnosticRecord(kind: "session_started", timestamp: day.startedAt,
                                                         detectorVersion: jumpDetector.detectorVersion,
                                                         detail: "Berms recording started"))
            diagnosticLogger?.append(RawDiagnosticRecord(kind: "jump_detector_config",
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
            BermsLiveActivityCoordinator.shared.start(rideID: day.id, startedAt: day.startedAt)
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
        diagnosticLogger?.append(RawDiagnosticRecord(
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
        guard locationService.authorizationStatus != .denied,
              locationService.authorizationStatus != .restricted else { return false }
        let resumeDate = Date.now
        let pausedDuration = day.endPause(at: resumeDate)
        objectWillChange.send()
        resetTrackingState(clearLastSample: true)
        trackingBoundaryDate = resumeDate
        diagnosticLogger?.append(RawDiagnosticRecord(
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
        diagnosticLogger?.append(RawDiagnosticRecord(
            kind: "session_stopped",
            timestamp: stopDate,
            detail: wasPaused ? "Berms recording stopped while paused" : "Berms recording stopped"
        ))

        day.endedAt = stopDate
        clearCheckpoint(for: day)
        updateTotals(for: day)
        guard saveContext(detail: "stop") else {
            day.endedAt = nil
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
            diagnosticLogger?.append(RawDiagnosticRecord(kind: "detector_finished", timestamp: draft.endedAt,
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
              let data = try? Data(contentsOf: url),
              let result = try? DiagnosticLogReplayer().replay(data: data),
              !result.segments.isEmpty else {
            return false
        }

        var rebuiltSegments: [RideSegment] = []
        for draft in result.segments {
            let cleanedPoints = RouteCleaner().clean(draft.points).map(\.routePoint)
            guard cleanedPoints.count >= 2,
                  let routeData = try? RouteCodec.encode(cleanedPoints) else {
                return false
            }
            let segment = RideSegment(kind: draft.kind, startedAt: draft.startedAt,
                                      endedAt: draft.endedAt, routeData: routeData,
                                      jumps: draft.jumps)
            segment.distanceMeters = RouteMetrics.distance(of: cleanedPoints)
            segment.verticalMeters = RouteMetrics.vertical(of: cleanedPoints, kind: draft.kind)
            segment.maximumSpeedMetersPerSecond = RouteMetrics.maximumSpeed(of: cleanedPoints)
            rebuiltSegments.append(segment)
        }

        for segment in day.segments {
            context.delete(segment)
        }
        day.segments.removeAll()
        for segment in rebuiltSegments {
            segment.day = day
            day.segments.append(segment)
            context.insert(segment)
        }
        day.recalculateTotals()
        return saveContext(detail: "diagnostic_summary_rebuild")
    }

    private func migrateDiagnosticSummariesIfNeeded() -> Bool {
        guard UserDefaults.standard.string(forKey: "berms.diagnosticSummaryVersion")
                != Self.diagnosticSummaryVersion else { return true }
        guard let days = try? context.fetch(FetchDescriptor<RideDay>()) else {
            errorMessage = "Could not update saved session summaries. Please try again."
            return false
        }

        for day in days where day.isFinished {
            if let url = debugLogURL(for: day) {
                _ = rebuildSummaryFromDiagnosticLog(for: day, from: url)
            }
            for segment in day.segments where segment.kind == .lift {
                learnLiftProfile(from: segment)
            }
        }
        repairStoredRoutes()
        guard saveContext(detail: "diagnostic_summary_migration") else { return false }
        UserDefaults.standard.set(Self.diagnosticSummaryVersion,
                                   forKey: "berms.diagnosticSummaryVersion")
        return true
    }

    private func repairStoredRoutes() {
        let cleaner = RouteCleaner()
        if let segments = try? context.fetch(FetchDescriptor<RideSegment>()) {
            for segment in segments {
                let cleaned = cleaner.clean(segment.points)
                guard cleaned.count >= 2, let data = try? RouteCodec.encode(cleaned) else { continue }
                segment.routeData = data
                segment.distanceMeters = RouteMetrics.distance(of: cleaned)
                segment.verticalMeters = RouteMetrics.vertical(of: cleaned, kind: segment.kind)
                segment.maximumSpeedMetersPerSecond = RouteMetrics.maximumSpeed(of: cleaned)
                segment.day?.recalculateTotals()
            }
        }

        if let passes = try? context.fetch(FetchDescriptor<TrailPass>()) {
            for pass in passes {
                let cleaned = cleaner.clean(pass.points)
                guard cleaned.count >= 2, let data = try? RouteCodec.encode(cleaned) else { continue }
                pass.routeData = data
                pass.distanceMeters = RouteMetrics.distance(of: cleaned)
            }
        }
        if let trails = try? context.fetch(FetchDescriptor<Trail>()) {
            trails.forEach { $0.recalculateAverage() }
        }
    }

    func resumeIfNeeded(autoResume: Bool = false) {
        guard !hasResumed else { return }

        isRestoring = true
        defer { isRestoring = false }
        guard migrateDiagnosticSummariesIfNeeded() else { return }
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
            // A manual launch after the process was killed means the user
            // dismissed the app. Treat the unfinished ride as abandoned and
            // clear its Live Activity instead of resurrecting it from the
            // Dynamic Island.
            discardUnfinishedSession(day)
            return
        }
        automaticallyRestoredOnLaunch = true
        restore(day: day)
    }

    func handleLiveActivityOpen() {
        if automaticallyRestoredOnLaunch, let day = activeDay {
            automaticallyRestoredOnLaunch = false
            discardUnfinishedSession(day)
        } else if !isRecording {
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
        lastSample = nil
        lastSampleTimestamp = nil
        lastCheckpointDate = nil
        trackingBoundaryDate = day.startedAt
        activePoints = []
        phase = .idle
        diagnosticLogger = RawLogWriter(url: Self.debugLogURL(for: day.id))
        diagnosticLogger?.append(RawDiagnosticRecord(kind: "session_recovered",
                                                     detectorVersion: jumpDetector.detectorVersion,
                                                     detail: day.isPaused
                                                     ? "Recovered paused day after relaunch"
                                                     : "Recovered active day after relaunch"))
        BermsLiveActivityCoordinator.shared.start(rideID: day.id, startedAt: day.startedAt)
        if day.isPaused {
            resetTrackingState(clearLastSample: true)
            updateLiveActivity(force: true)
            return
        }
        diagnosticLogger?.append(RawDiagnosticRecord(kind: "jump_detector_config",
                                                     detectorVersion: jumpDetector.detectorVersion,
                                                     detail: jumpDetector.configurationSummary))
        if let data = day.checkpointData,
           let kind = day.checkpointKind.flatMap(SegmentKind.init(rawValue:)) {
            let decoder = JSONDecoder()
            let checkpoint = (try? decoder.decode(RecorderCheckpoint.self, from: data))
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
            self?.diagnosticLogger?.append(RawDiagnosticRecord(
                kind: "location_authorization",
                detail: String(describing: status)
            ))
        }
        locationService.diagnosticHandler = { [weak self] detail in
            self?.diagnosticLogger?.append(RawDiagnosticRecord(kind: "location_service_error", detail: detail))
        }
        if let logger = diagnosticLogger {
            motionService.rawAltitudeHandler = { sample in
                logger.append(RawDiagnosticRecord(
                    kind: "barometer_raw",
                    timestamp: sample.timestamp,
                    relativeAltitude: sample.relativeAltitude,
                    pressureKPa: sample.pressureKPa
                ))
            }
            motionService.rawActivityHandler = { sample in
                logger.append(RawDiagnosticRecord(
                    kind: "motion_activity_raw",
                    timestamp: sample.recordedAt,
                    stationary: sample.stationary,
                    cycling: sample.cycling,
                    automotive: sample.automotive,
                    detail: "start=\(sample.activityStart.timeIntervalSince1970),walking=\(sample.walking),running=\(sample.running),unknown=\(sample.unknown),confidence=\(sample.confidence)"
                ))
            }
        }
        let logger = diagnosticLogger
        motionService.rawDeviceMotionHandler = { [weak self] sample in
            logger?.append(RawDiagnosticRecord(
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
            Task { @MainActor [weak self] in
                self?.consume(deviceMotion: sample)
            }
        }
        motionService.start()
        motionAvailable = motionService.motionAvailable
        altitudeFusion.reset(barometerAvailable: motionService.altimeterAvailable)
        locationService.start { [weak self] location, stationary in
            self?.consume(location: location, isStationary: stationary)
        }
        locationAuthorization = locationService.authorizationStatus
        diagnosticLogger?.append(RawDiagnosticRecord(
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
        diagnosticLogger?.append(RawDiagnosticRecord(
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
            diagnosticLogger?.append(RawDiagnosticRecord(kind: "gps_rejected", timestamp: location.timestamp,
                                                         accepted: false, detail: "before_session_start"))
            return
        }
        if let trackingBoundaryDate, location.timestamp < trackingBoundaryDate {
            diagnosticLogger?.append(RawDiagnosticRecord(kind: "gps_rejected", timestamp: location.timestamp,
                                                         accepted: false, detail: "before_tracking_boundary"))
            return
        }
        guard location.timestamp <= arrivalDate.addingTimeInterval(10) else {
            diagnosticLogger?.append(RawDiagnosticRecord(kind: "gps_rejected", timestamp: location.timestamp,
                                                         accepted: false, detail: "future_timestamp"))
            return
        }
        guard lastSampleTimestamp.map({ location.timestamp > $0 }) ?? true else {
            diagnosticLogger?.append(RawDiagnosticRecord(kind: "gps_rejected", timestamp: location.timestamp,
                                                         accepted: false, detail: "duplicate_or_out_of_order"))
            return
        }

        if let lastSampleTimestamp {
            let gap = location.timestamp.timeIntervalSince(lastSampleTimestamp)
            if gap > maximumTrackingGap {
                diagnosticLogger?.append(RawDiagnosticRecord(
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
        let hasFreshBarometer = motionService.relativeAltitudeTimestamp.map {
            abs(location.timestamp.timeIntervalSince($0)) <= 10
        } ?? false
        guard let altitude = altitudeFusion.update(
            gpsAltitude: gpsAltitude,
            relativeAltitude: hasFreshBarometer ? motionService.relativeAltitude : nil
        ) else {
            diagnosticLogger?.append(RawDiagnosticRecord(
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
            diagnosticLogger?.append(RawDiagnosticRecord(
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
        diagnosticLogger?.append(RawDiagnosticRecord(
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
            speed: currentSpeed,
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
            diagnosticLogger?.append(RawDiagnosticRecord(
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
            diagnosticLogger?.append(RawDiagnosticRecord(
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
            diagnosticLogger?.append(RawDiagnosticRecord(kind: "detector_started",
                                                         timestamp: points.first?.timestamp ?? .now,
                                                         phaseAfter: kind.rawValue,
                                                         detail: kind.title))
            checkpointIfNeeded(at: points.last?.timestamp ?? .now, force: true)
        case .updated:
            activePoints = detector.currentPoints
        case .finished(let draft):
            for jumpEvent in jumpDetector.finish() {
                handleJumpEvent(jumpEvent)
            }
            diagnosticLogger?.append(RawDiagnosticRecord(kind: "detector_finished", timestamp: draft.endedAt,
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
        guard let data = try? JSONEncoder().encode(RecorderCheckpoint(
            points: activePoints,
            jumps: activeSegmentKind == .run ? jumpsForCurrentRun : []
        )) else { return }
        day.checkpointKind = kind.rawValue
        day.checkpointStartedAt = activePoints.first?.timestamp
        day.checkpointData = data
        lastCheckpointDate = date
        saveContext(detail: "checkpoint")
    }

    private func save(_ draft: SegmentDraft, to day: RideDay) {
        let cleanedPoints = RouteCleaner().clean(draft.points).map(\.routePoint)
        guard cleanedPoints.count >= 2, let data = try? RouteCodec.encode(cleanedPoints) else { return }
        let jumps = draft.kind == .run ? (draft.jumps.isEmpty ? jumpsForCurrentRun : draft.jumps) : []
        let segment = RideSegment(kind: draft.kind, startedAt: draft.startedAt,
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
              let storedLifts = try? context.fetch(FetchDescriptor<LearnedLift>()) else { return }

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

    @discardableResult
    private func saveContext(detail: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            errorMessage = "Could not save your session. Keep Berms open and try Finish again. \(error.localizedDescription)"
            diagnosticLogger?.append(RawDiagnosticRecord(
                kind: "persistence_error",
                accepted: false,
                detail: "\(detail): \(error.localizedDescription)"
            ))
            return false
        }
    }

    private func updateTotals(for day: RideDay) {
        day.recalculateTotals()
    }
}
