import Combine
import Foundation

extension RideRecorder {
    @discardableResult
    func togglePauseFromLiveActivity() -> Bool {
        guard activeDay != nil else { return false }
        return isPaused ? resume() : pause()
    }

    func updateLiveActivity(force: Bool = false) {
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
}
