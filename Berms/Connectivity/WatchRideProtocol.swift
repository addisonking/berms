import Foundation

enum WatchRideStatus: String, Codable, Equatable, Sendable {
    case idle
    case recording
    case paused
}

struct WatchRideState: Codable, Equatable, Sendable {
    struct RunMetrics: Codable, Equatable, Sendable {
        let number: Int
        let distanceMeters: Double
        let descentMeters: Double
        let topSpeedMetersPerSecond: Double
        let longestJumpAirtime: TimeInterval?
        let jumpCount: Int?
    }

    static let currentVersion = 1

    let version: Int
    let status: WatchRideStatus
    let rideID: String?
    let phase: String
    let startedAt: Date?
    let elapsedSeconds: TimeInterval
    let distanceMeters: Double
    let descentMeters: Double
    let speedMetersPerSecond: Double
    let run: RunMetrics?
    let updatedAt: Date
    let activityModeRawValue: String?

    init(
        version: Int = WatchRideState.currentVersion,
        status: WatchRideStatus,
        rideID: String?,
        phase: String,
        startedAt: Date?,
        elapsedSeconds: TimeInterval,
        distanceMeters: Double,
        descentMeters: Double,
        speedMetersPerSecond: Double,
        run: RunMetrics? = nil,
        updatedAt: Date,
        activityModeRawValue: String? = nil
    ) {
        self.version = version
        self.status = status
        self.rideID = rideID
        self.phase = phase
        self.startedAt = startedAt
        self.elapsedSeconds = elapsedSeconds
        self.distanceMeters = distanceMeters
        self.descentMeters = descentMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.run = run
        self.updatedAt = updatedAt
        self.activityModeRawValue = activityModeRawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        status = try container.decode(WatchRideStatus.self, forKey: .status)
        rideID = try container.decodeIfPresent(String.self, forKey: .rideID)
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? "idle"
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        elapsedSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .elapsedSeconds) ?? 0
        distanceMeters = try container.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 0
        descentMeters = try container.decodeIfPresent(Double.self, forKey: .descentMeters) ?? 0
        speedMetersPerSecond = try container.decodeIfPresent(Double.self, forKey: .speedMetersPerSecond) ?? 0
        run = try container.decodeIfPresent(RunMetrics.self, forKey: .run)
        activityModeRawValue = try container.decodeIfPresent(String.self, forKey: .activityModeRawValue)
        // A missing timestamp must never look newer than what the watch already shows.
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    static var idle: WatchRideState {
        WatchRideState(
            status: .idle,
            rideID: nil,
            phase: "idle",
            startedAt: nil,
            elapsedSeconds: 0,
            distanceMeters: 0,
            descentMeters: 0,
            speedMetersPerSecond: 0,
            updatedAt: .now
        )
    }

    var isActive: Bool { status != .idle }

    var isSkiDay: Bool { activityModeRawValue == "ski" }

    var activityTitle: String {
        isSkiDay ? "Ski day" : "Berms"
    }

    func isStale(at date: Date = .now, threshold: TimeInterval = 5) -> Bool {
        isActive && date.timeIntervalSince(updatedAt) > threshold
    }
}

enum WatchRideCommand: String, Codable, Equatable, Sendable {
    case pause
    case resume
    case finish
}

struct WatchRideCommandRequest: Codable, Sendable {
    let version: Int
    let command: WatchRideCommand
    let rideID: String

    init(
        version: Int = WatchRideState.currentVersion,
        command: WatchRideCommand,
        rideID: String
    ) {
        self.version = version
        self.command = command
        self.rideID = rideID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        command = try container.decode(WatchRideCommand.self, forKey: .command)
        rideID = try container.decode(String.self, forKey: .rideID)
    }
}

struct WatchRideCommandReply: Codable, Equatable, Sendable {
    let accepted: Bool
    let state: WatchRideState
}

enum WatchRideWire {
    static let requestState = "requestState"
    static let state = "state"
    static let command = "command"
    static let reply = "reply"
}

enum WatchRideCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
