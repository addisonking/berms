// Compiled separately on macOS with the production watch model and protocol.
import Foundation

@MainActor
final class WatchConnectivityClient: WatchRideTransportClient {
    var state = WatchRideState.idle
    var isReachable = true
    var onStateChange: ((WatchRideState) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?
    var onCommandResult: ((Bool, WatchRideState?) -> Void)?
    var commands: [WatchRideCommand] = []
    func activate() {}
    func send(command: WatchRideCommand) -> Bool {
        commands.append(command)
        return isReachable
    }
    func push(_ status: WatchRideStatus, rideID: String = "ride-a", age: Double = 0) {
        state = WatchRideState(status: status, rideID: status == .idle ? nil : rideID,
                              phase: "run", startedAt: .now, elapsedSeconds: 90,
                              distanceMeters: 200, descentMeters: 20, speedMetersPerSecond: 5,
                              updatedAt: .now.addingTimeInterval(-age))
        onStateChange?(state)
    }
}

@MainActor
final class WatchHealthManager: WatchHealthProvider {
    var snapshot = WatchHealthSnapshot.unavailable
    var onSnapshotChange: ((WatchHealthSnapshot) -> Void)?
    var events: [String] = []
    func start() { events.append("start") }
    func pause() { events.append("pause") }
    func resume() { events.append("resume") }
    func stop() { events.append("stop") }
}

@main
struct WatchLifecycleChecks {
    @MainActor static func main() {
        let transport = WatchConnectivityClient()
        let health = WatchHealthManager()
        let model = WatchDashboardModel(transport: transport, healthProvider: health)
        precondition(!model.canTogglePause && health.events.isEmpty)

        transport.push(.recording, age: 60)
        precondition(!model.canTogglePause && !health.events.contains("start"), "Cached rides must not start health")
        transport.push(.recording)
        precondition(model.canTogglePause && health.events.last == "start")
        precondition(model.state.distanceMeters == 200 && model.health == .unavailable,
                     "Route metrics must work without health access")

        model.togglePause()
        precondition(model.state.status == .recording && model.commandInFlight,
                     "Pause must wait for iPhone confirmation")
        transport.push(.paused)
        transport.onCommandResult?(true, transport.state)
        precondition(model.canTogglePause && health.events.last == "pause")
        for _ in 0..<10 { transport.push(.paused) }
        precondition(model.canTogglePause, "Fresh paused state must keep Resume enabled")
        model.togglePause()
        precondition(transport.commands == [.pause, .resume])
        transport.push(.recording)
        transport.onCommandResult?(true, transport.state)
        precondition(health.events.last == "resume")

        transport.isReachable = false
        transport.onReachabilityChange?(false)
        model.reconcileHealth()
        let commandCount = transport.commands.count
        model.togglePause()
        precondition(!model.canTogglePause && transport.commands.count == commandCount)
        precondition(health.events.last == "pause")
        transport.isReachable = true
        transport.onReachabilityChange?(true)
        transport.push(.recording)
        precondition(model.canTogglePause && health.events.last == "resume")

        transport.push(.recording, rideID: "ride-b")
        precondition(Array(health.events.suffix(2)) == ["stop", "start"], "A new ride must reset health")
        model.finishRide()
        precondition(transport.commands.last == .finish && model.commandInFlight)
        precondition(model.state.isActive, "Finish must wait for iPhone confirmation")
        transport.onCommandResult?(false, transport.state)
        precondition(model.state.isActive && !model.commandInFlight && model.message != nil,
                     "A rejected finish must leave the ride available")
        model.finishRide()
        transport.push(.idle)
        transport.onCommandResult?(true, transport.state)
        precondition(!model.canTogglePause && health.events.last == "stop" && model.message == nil)
        let finishedCommandCount = transport.commands.count
        model.finishRide()
        precondition(transport.commands.count == finishedCommandCount, "Idle rides cannot be finished")
        print("PASS: idle, stale launch, unavailable health, confirmed pause/resume, long pause, disconnect/reconnect, new ride, rejected finish, confirmed finish")
    }
}
