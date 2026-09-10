import Foundation
@preconcurrency import WatchConnectivity

@MainActor
final class WatchConnectivityClient: NSObject, WatchRideTransportClient, WCSessionDelegate {
    private let session = WCSession.default
    private var refreshTask: Task<Void, Never>?

    private(set) var state = WatchRideState.idle
    private(set) var isReachable = false

    var onStateChange: ((WatchRideState) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?
    var onCommandResult: ((Bool, WatchRideState?) -> Void)?

    override init() {
        super.init()
        session.delegate = self
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        updateReachability(session.isReachable)
        if let data = session.receivedApplicationContext[WatchRideWire.state] as? Data {
            receive(stateData: data)
        }
        session.activate()
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.requestLatestState()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func requestLatestState() {
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage([WatchRideWire.requestState: true], replyHandler: { @Sendable [weak self] message in
            guard let data = message[WatchRideWire.state] as? Data else { return }
            Task { @MainActor in self?.receive(stateData: data) }
        }, errorHandler: { @Sendable _ in })
    }

    @discardableResult
    func send(command: WatchRideCommand) -> Bool {
        guard isReachable, session.activationState == .activated, let rideID = state.rideID,
              let data = try? WatchRideCodec.encode(WatchRideCommandRequest(command: command, rideID: rideID)) else { return false }

        session.sendMessage([WatchRideWire.command: data], replyHandler: { @Sendable [weak self] message in
            guard let data = message[WatchRideWire.reply] as? Data else {
                Task { @MainActor [weak self] in
                    self?.onCommandResult?(false, nil)
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.receive(replyData: data)
            }
        }, errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onCommandResult?(false, nil)
            }
        })
        return true
    }

    private func updateReachability(_ reachable: Bool) {
        guard isReachable != reachable else { return }
        isReachable = reachable
        onReachabilityChange?(reachable)
    }

    private func receive(stateData: Data) {
        guard let state = try? WatchRideCodec.decode(WatchRideState.self, from: stateData) else { return }
        guard state.updatedAt >= self.state.updatedAt else { return }
        self.state = state
        onStateChange?(state)
    }

    private func receive(replyData: Data) {
        guard let reply = try? WatchRideCodec.decode(WatchRideCommandReply.self, from: replyData) else {
            onCommandResult?(false, nil)
            return
        }
        if reply.state.updatedAt >= state.updatedAt { state = reply.state }
        onCommandResult?(reply.accepted, state)
        onStateChange?(state)
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.updateReachability(reachable)
            self?.requestLatestState()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.updateReachability(reachable)
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchRideWire.state] as? Data else { return }
        Task { @MainActor [weak self] in
            self?.receive(stateData: data)
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchRideWire.state] as? Data else { return }
        Task { @MainActor [weak self] in
            self?.receive(stateData: data)
        }
    }
}
