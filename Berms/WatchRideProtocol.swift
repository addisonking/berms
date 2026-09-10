import Foundation

enum WatchRideStatus: String, Codable, Equatable, Sendable {
    case idle
    case recording
    case paused
}

struct WatchRideState: Codable, Equatable, Sendable {
    let status: WatchRideStatus
    let rideID: String?
    let phase: String
    let startedAt: Date?
    let elapsedSeconds: TimeInterval
    let distanceMeters: Double
    let descentMeters: Double
    let speedMetersPerSecond: Double
    let updatedAt: Date

    static var idle: WatchRideState { WatchRideState(
        status: .idle,
        rideID: nil,
        phase: "idle",
        startedAt: nil,
        elapsedSeconds: 0,
        distanceMeters: 0,
        descentMeters: 0,
        speedMetersPerSecond: 0,
        updatedAt: .now
    ) }

    var isActive: Bool { status != .idle }

    func isStale(at date: Date = .now, threshold: TimeInterval = 5) -> Bool {
        isActive && date.timeIntervalSince(updatedAt) > threshold
    }
}

enum WatchRideCommand: String, Codable, Equatable, Sendable {
    case pause
    case resume
}

struct WatchRideCommandRequest: Codable, Sendable {
    let command: WatchRideCommand
    let rideID: String
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
