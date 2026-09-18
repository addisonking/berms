import ActivityKit
import Foundation

private final class BermsActivityHandle: @unchecked Sendable {
    let activity: Activity<BermsActivityAttributes>

    init(_ activity: Activity<BermsActivityAttributes>) {
        self.activity = activity
    }
}

@MainActor
final class BermsLiveActivityCoordinator {
    static let shared = BermsLiveActivityCoordinator()
    static let togglePauseNotification = Notification.Name("berms.liveActivity.togglePause")

    private var activity: BermsActivityHandle?
    private var lastUpdate = Date.distantPast
    private var isEndingAllActivities = false

    /// Whether a Live Activity is running and can carry background location updates.
    var isActivityActive: Bool {
        activity != nil || !Activity<BermsActivityAttributes>.activities.isEmpty
    }

    private init() {}

    func start(
        rideID: UUID, startedAt: Date,
        metrics: [BermsLiveActivityMetric],
        activityModeRawValue: String? = nil
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let existing = Activity<BermsActivityAttributes>.activities.first(where: {
            $0.attributes.rideID == rideID.uuidString
        }) {
            activity = BermsActivityHandle(existing)
            lastUpdate = .distantPast
            endActivities(where: { $0.attributes.rideID != rideID.uuidString })
            return
        }
        endActivities(where: { $0.attributes.rideID != rideID.uuidString })
        let attributes = BermsActivityAttributes(rideID: rideID)
        let state = BermsActivityAttributes.ContentState(
            phase: DetectorPhase.idle.rawValue,
            isPaused: false,
            runCount: 0,
            startedAt: startedAt,
            elapsedSeconds: 0,
            distanceMeters: 0,
            descentMeters: 0,
            topSpeedMetersPerSecond: 0,
            metric: metrics.first ?? .descent,
            metrics: metrics,
            activityModeRawValue: activityModeRawValue
        )
        do {
            let requested = try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: state,
                    staleDate: .now.addingTimeInterval(45)),
                pushType: nil
            )
            activity = BermsActivityHandle(requested)
            lastUpdate = .distantPast
        } catch {
            activity = nil
        }
    }

    private func endActivities(where matches: (Activity<BermsActivityAttributes>) -> Bool) {
        for other in Activity<BermsActivityAttributes>.activities where matches(other) {
            let handle = BermsActivityHandle(other)
            Task.detached {
                await handle.activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func update(
        phase: DetectorPhase, isPaused: Bool, runCount: Int, startedAt: Date,
        elapsed: TimeInterval, distance: Double, descent: Double, topSpeed: Double,
        metrics: [BermsLiveActivityMetric], jumpCount: Int, liftCount: Int,
        longestAirtime: TimeInterval, totalAirtime: TimeInterval,
        maximumJumpLength: Double, maximumJumpHeight: Double, maximumJumpDrop: Double,
        activityModeRawValue: String? = nil, force: Bool = false
    ) {
        guard let handle = activity,
            force || Date.now.timeIntervalSince(lastUpdate) >= 10
        else { return }
        lastUpdate = .now
        let state = BermsActivityAttributes.ContentState(
            phase: isPaused ? "paused" : phase.rawValue,
            isPaused: isPaused,
            runCount: runCount,
            startedAt: startedAt,
            elapsedSeconds: elapsed,
            distanceMeters: distance,
            descentMeters: descent,
            topSpeedMetersPerSecond: topSpeed,
            metric: metrics.first ?? .descent,
            jumpCount: jumpCount,
            liftCount: liftCount,
            longestAirtime: longestAirtime,
            totalAirtime: totalAirtime,
            maximumJumpLengthMeters: maximumJumpLength,
            maximumJumpHeightMeters: maximumJumpHeight,
            maximumJumpDropMeters: maximumJumpDrop,
            metrics: metrics,
            activityModeRawValue: activityModeRawValue
        )
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(30))
        Task.detached {
            await handle.activity.update(content)
        }
    }

    func end() {
        endAllActivities()
    }

    func endAll() {
        endAllActivities()
    }

    private func endAllActivities() {
        activity = nil
        lastUpdate = .distantPast
        isEndingAllActivities = true
        Task { @MainActor [weak self] in
            let activities = Activity<BermsActivityAttributes>.activities
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            self?.isEndingAllActivities = false
        }
    }

    func reconcile() {
        guard !isEndingAllActivities else { return }
        let activities = Activity<BermsActivityAttributes>.activities
        activity = activities.first.map(BermsActivityHandle.init)
        if activities.count > 1 {
            for stale in activities.dropFirst() {
                let handle = BermsActivityHandle(stale)
                Task.detached {
                    await handle.activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }
}
