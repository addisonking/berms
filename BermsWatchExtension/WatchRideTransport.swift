import Foundation

enum WatchHealthAvailability: Equatable, Sendable {
    case unavailable
    case waiting
    case available
}

struct WatchHealthSnapshot: Equatable, Sendable {
    var heartRateBeatsPerMinute: Double?
    var activeCalories: Double?
    var availability: WatchHealthAvailability

    static let unavailable = WatchHealthSnapshot(
        heartRateBeatsPerMinute: nil,
        activeCalories: nil,
        availability: .unavailable
    )
}

@MainActor
protocol WatchRideTransportClient: AnyObject {
    var state: WatchRideState { get }
    var isReachable: Bool { get }
    var onStateChange: ((WatchRideState) -> Void)? { get set }
    var onReachabilityChange: ((Bool) -> Void)? { get set }
    var onCommandResult: ((Bool, WatchRideState?) -> Void)? { get set }

    func activate()
    @discardableResult
    func send(command: WatchRideCommand) -> Bool
}

@MainActor
protocol WatchHealthProvider: AnyObject {
    var snapshot: WatchHealthSnapshot { get }
    var onSnapshotChange: ((WatchHealthSnapshot) -> Void)? { get set }

    func start()
    func pause()
    func resume()
    func stop()
}
