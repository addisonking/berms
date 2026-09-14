import Foundation
import SwiftUI

@MainActor
final class WatchDashboardModel: ObservableObject {
    @Published private(set) var state = WatchRideState.idle
    @Published private(set) var health = WatchHealthSnapshot.unavailable
    @Published private(set) var isReachable = false
    @Published private(set) var commandInFlight = false
    @Published private(set) var message: String?

    let isDemo: Bool

    private let transport: WatchRideTransportClient
    private let healthProvider: WatchHealthProvider
    private var healthStatus: WatchRideStatus = .idle
    private var healthRideID: String?
    private var healthTask: Task<Void, Never>?
    private var commandTimeoutTask: Task<Void, Never>?

    init(transport: WatchRideTransportClient? = nil,
         healthProvider: WatchHealthProvider? = nil) {
#if DEBUG
        let demoEnabled = ProcessInfo.processInfo.arguments.contains("-BermsWatchDemo")
        isDemo = demoEnabled
        self.transport = transport ?? (demoEnabled ? WatchDemoTransport() : WatchConnectivityClient())
        self.healthProvider = healthProvider ?? (demoEnabled ? WatchDemoHealthProvider() : WatchHealthManager())
#else
        isDemo = false
        self.transport = transport ?? WatchConnectivityClient()
        self.healthProvider = healthProvider ?? WatchHealthManager()
#endif

        state = self.transport.state
        isReachable = self.transport.isReachable
        health = self.healthProvider.snapshot
        self.transport.onStateChange = { [weak self] state in
            self?.apply(state: state)
        }
        self.transport.onReachabilityChange = { [weak self] reachable in
            self?.isReachable = reachable
        }
        self.transport.onCommandResult = { [weak self] accepted, state in
            self?.receiveCommandResult(accepted: accepted, state: state)
        }
        self.healthProvider.onSnapshotChange = { [weak self] snapshot in
            self?.health = snapshot
        }
        self.transport.activate()
        apply(state: state)
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.reconcileHealth()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    var isStale: Bool {
        guard state.isActive else { return false }
        return !isReachable || state.isStale()
    }

    var canTogglePause: Bool {
        state.isActive && isReachable && !isStale && !commandInFlight
    }

    var statusTitle: String {
        switch state.status {
        case .idle: "IDLE"
        case .recording: "REC"
        case .paused: "PAUSED"
        }
    }

    var actionTitle: String {
        state.status == .paused ? "Resume" : "Pause"
    }

    func togglePause() {
        send(state.status == .paused ? .resume : .pause)
    }

    func finishRide() {
        send(.finish)
    }

    private func send(_ command: WatchRideCommand) {
        guard canTogglePause else { return }
        message = nil
        commandInFlight = true
        if !transport.send(command: command) {
            commandInFlight = false
            message = "Phone unavailable"
            return
        }
        commandTimeoutTask?.cancel()
        commandTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.commandInFlight else { return }
            self.commandInFlight = false
            self.message = "Phone did not respond"
        }
    }

    private func apply(state: WatchRideState) {
        self.state = state
        reconcileHealth()
    }

    func reconcileHealth() {
        if healthRideID != state.rideID {
            healthProvider.stop()
            healthStatus = .idle
            healthRideID = state.rideID
        }
        if state.status == .idle {
            syncHealth(to: .idle)
        } else if isStale {
            if healthStatus == .recording { syncHealth(to: .paused) }
        } else {
            syncHealth(to: state.status)
        }
    }

    private func receiveCommandResult(accepted: Bool, state: WatchRideState?) {
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        commandInFlight = false
        if let state {
            apply(state: state)
        }
        message = accepted ? nil : "Phone did not accept that change"
    }

    private func syncHealth(to status: WatchRideStatus) {
        guard status != healthStatus else { return }
        switch status {
        case .idle:
            healthProvider.stop()
        case .recording:
            if healthStatus == .paused {
                healthProvider.resume()
            } else {
                healthProvider.start()
            }
        case .paused:
            if healthStatus == .idle {
                healthProvider.start()
            }
            healthProvider.pause()
        }
        healthStatus = status
    }

#if DEBUG
    func demoToggleReachable() {
        (transport as? WatchDemoTransport)?.toggleReachable()
    }

    func demoRefresh() {
        (transport as? WatchDemoTransport)?.refresh()
    }

    func demoFinish() {
        (transport as? WatchDemoTransport)?.finish()
    }
#endif
}
