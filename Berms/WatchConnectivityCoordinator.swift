import Combine
import Foundation
import HealthKit
@preconcurrency import WatchConnectivity

private final class WatchReplyHandler: @unchecked Sendable {
    let send: ([String: Any]) -> Void

    init(_ send: @escaping ([String: Any]) -> Void) {
        self.send = send
    }
}

@MainActor
protocol WatchRideStateSink: AnyObject {
    func publish(_ state: WatchRideState, force: Bool)
}

@MainActor
final class WatchConnectivityCoordinator: NSObject, ObservableObject, WatchRideStateSink, WCSessionDelegate {
    static let shared = WatchConnectivityCoordinator()

    @Published private(set) var isReachable = false

    private let session: WCSession?
    private var latestState = WatchRideState.idle
    private var lastImmediateSend = Date.distantPast
    private var launchedRideID: String?

    private override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()

        guard let session else { return }
        session.delegate = self
        isReachable = session.isReachable
        session.activate()
    }

    func publish(_ state: WatchRideState, force: Bool = false) {
        latestState = state
        guard let session, session.activationState == .activated else { return }

        guard let encodedState = try? WatchRideCodec.encode(state) else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext([WatchRideWire.state: encodedState])
        if state.status == .recording, let rideID = state.rideID, launchedRideID != rideID {
            launchedRideID = rideID
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .snowSports
            configuration.locationType = .outdoor
            HKHealthStore().startWatchApp(with: configuration) { _, error in
                if let error { print("Watch launch unavailable: \(error.localizedDescription)") }
            }
        }

        guard session.isReachable else { return }
        let now = Date.now
        guard force || now.timeIntervalSince(lastImmediateSend) >= 1 else { return }
        lastImmediateSend = now
        session.sendMessage([WatchRideWire.state: encodedState], replyHandler: nil) { @Sendable error in
            print("Watch live update unavailable: \(error.localizedDescription)")
        }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            isReachable = reachable
            if activationState == .activated {
                publish(latestState, force: true)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isReachable = reachable
            if reachable {
                self?.publish(self?.latestState ?? .idle, force: true)
            }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        // The phone is the source of truth. The watch sends no state back through context.
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        if message[WatchRideWire.requestState] as? Bool == true {
            let reply = WatchReplyHandler(replyHandler)
            Task { @MainActor in
                let state = RideRecorder.shared.currentWatchRideState
                reply.send([WatchRideWire.state: (try? WatchRideCodec.encode(state)) ?? Data()])
            }
            return
        }
        guard let data = message[WatchRideWire.command] as? Data,
              let request = try? WatchRideCodec.decode(WatchRideCommandRequest.self, from: data) else {
            // Never answer with a fresh idle state: that would clobber whatever
            // the watch is showing. Reply with the recorder's real state instead.
            let reply = WatchReplyHandler(replyHandler)
            Task { @MainActor in
                let response = WatchRideCommandReply(accepted: false,
                                                     state: RideRecorder.shared.currentWatchRideState)
                reply.send([WatchRideWire.reply: (try? WatchRideCodec.encode(response)) ?? Data()])
            }
            return
        }

        let reply = WatchReplyHandler(replyHandler)
        Task { @MainActor [reply] in
            let accepted: Bool
            if RideRecorder.shared.currentWatchRideState.rideID != request.rideID {
                accepted = false
            } else {
                switch request.command {
                case .pause:
                    accepted = RideRecorder.shared.pause()
                case .resume:
                    accepted = RideRecorder.shared.resume()
                }
            }

            let state = RideRecorder.shared.currentWatchRideState
            let response = WatchRideCommandReply(accepted: accepted, state: state)
            if let encodedResponse = try? WatchRideCodec.encode(response) {
                reply.send([WatchRideWire.reply: encodedResponse])
            } else {
                reply.send([WatchRideWire.reply: Data()])
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
