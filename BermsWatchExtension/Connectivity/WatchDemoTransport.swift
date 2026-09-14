#if DEBUG
import Foundation

@MainActor
final class WatchDemoTransport: WatchRideTransportClient {
    private(set) var state = WatchRideState(
        status: .recording,
        rideID: "demo-ride",
        phase: "run",
        startedAt: .now.addingTimeInterval(-82),
        elapsedSeconds: 82,
        distanceMeters: 1640,
        descentMeters: 248,
        speedMetersPerSecond: 11.8,
        run: .init(number: 1, distanceMeters: 1640, descentMeters: 248, topSpeedMetersPerSecond: 14.8, longestJumpAirtime: 0.84),
        updatedAt: .now
    )
    private(set) var isReachable = true

    var onStateChange: ((WatchRideState) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?
    var onCommandResult: ((Bool, WatchRideState?) -> Void)?

    private var timerTask: Task<Void, Never>?
    private var tick = 0

    func activate() {
        onStateChange?(state)
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                updateMetrics()
            }
        }
    }

    @discardableResult
    func send(command: WatchRideCommand) -> Bool {
        guard isReachable, state.isActive else { return false }
        if command == .finish {
            finish()
            onCommandResult?(true, state)
            return true
        }
        let nextStatus: WatchRideStatus = command == .pause ? .paused : .recording
        guard state.status != nextStatus else {
            onCommandResult?(false, state)
            return true
        }
        state = stateWith(status: nextStatus, updatedAt: .now)
        onStateChange?(state)
        onCommandResult?(true, state)
        return true
    }

    func toggleReachable() {
        isReachable.toggle()
        onReachabilityChange?(isReachable)
        if isReachable { refresh() }
    }

    func refresh() {
        state = stateWith(updatedAt: .now)
        onStateChange?(state)
    }

    func finish() {
        state = .idle
        onStateChange?(state)
    }

    private func updateMetrics() {
        guard state.isActive else { return }
        guard state.status == .recording else {
            refresh()
            return
        }
        tick += 1
        let isLift = tick % 18 >= 14
        let speed = isLift ? 3.4 : 10.0 + Double(tick % 7) * 0.8
        let elapsed = state.elapsedSeconds + (state.status == .paused ? 0 : 1)
        let distance = state.distanceMeters + (state.status == .paused ? 0 : speed)
        let descent = state.descentMeters + (isLift || state.status == .paused ? 0 : 1.8)
        let startsRun = !isLift && state.phase != "run"
        let previousRun = state.run
        let run = WatchRideState.RunMetrics(
            number: (previousRun?.number ?? 1) + (startsRun ? 1 : 0),
            distanceMeters: startsRun ? speed : (previousRun?.distanceMeters ?? 0) + (isLift ? 0 : speed),
            descentMeters: startsRun ? 1.8 : (previousRun?.descentMeters ?? 0) + (isLift ? 0 : 1.8),
            topSpeedMetersPerSecond: startsRun ? speed : max(previousRun?.topSpeedMetersPerSecond ?? 0, isLift ? 0 : speed),
            longestJumpAirtime: startsRun ? 0 : max(previousRun?.longestJumpAirtime ?? 0, tick % 18 == 8 ? 0.92 : 0)
        )
        state = WatchRideState(
            status: state.status,
            rideID: state.rideID,
            phase: isLift ? "lift" : "run",
            startedAt: state.startedAt,
            elapsedSeconds: elapsed,
            distanceMeters: distance,
            descentMeters: descent,
            speedMetersPerSecond: speed,
            run: run,
            updatedAt: .now
        )
        onStateChange?(state)
    }

    private func stateWith(status: WatchRideStatus? = nil, updatedAt: Date) -> WatchRideState {
        WatchRideState(
            status: status ?? state.status,
            rideID: state.rideID,
            phase: state.phase,
            startedAt: state.startedAt,
            elapsedSeconds: state.elapsedSeconds,
            distanceMeters: state.distanceMeters,
            descentMeters: state.descentMeters,
            speedMetersPerSecond: state.speedMetersPerSecond,
            run: state.run,
            updatedAt: updatedAt
        )
    }
}

@MainActor
final class WatchDemoHealthProvider: WatchHealthProvider {
    private(set) var snapshot = WatchHealthSnapshot(
        heartRateBeatsPerMinute: 118,
        activeCalories: 36,
        availability: .available
    )
    var onSnapshotChange: ((WatchHealthSnapshot) -> Void)?

    private var timerTask: Task<Void, Never>?
    private var isPaused = false
    private var tick = 0

    func start() {
        guard timerTask == nil else { return }
        onSnapshotChange?(snapshot)
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                tick += 1
                snapshot.heartRateBeatsPerMinute = 108 + Double((tick * 7) % 38)
                if !isPaused { snapshot.activeCalories = (snapshot.activeCalories ?? 0) + 0.7 }
                onSnapshotChange?(snapshot)
            }
        }
    }

    func pause() { isPaused = true }

    func resume() { isPaused = false }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        isPaused = false
    }
}
#endif
