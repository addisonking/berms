import ActivityKit
import Foundation

public struct BermsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: String
        public var isPaused: Bool
        public var runCount: Int
        public var startedAt: Date
        public var elapsedSeconds: TimeInterval
        public var distanceMeters: Double
        public var descentMeters: Double
        public var speedMetersPerSecond: Double
        public var lastUpdated: Date

        public init(phase: String, isPaused: Bool, runCount: Int, startedAt: Date,
                    elapsedSeconds: TimeInterval, distanceMeters: Double, descentMeters: Double,
                    speedMetersPerSecond: Double, lastUpdated: Date = .now) {
            self.phase = phase
            self.isPaused = isPaused
            self.runCount = runCount
            self.startedAt = startedAt
            self.elapsedSeconds = elapsedSeconds
            self.distanceMeters = distanceMeters
            self.descentMeters = descentMeters
            self.speedMetersPerSecond = speedMetersPerSecond
            self.lastUpdated = lastUpdated
        }
    }

    public var rideID: String

    public init(rideID: UUID) {
        self.rideID = rideID.uuidString
    }
}
