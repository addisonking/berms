import ActivityKit
import Foundation

public enum BermsLiveActivityMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case descent
    case jumps
    case distance
    case topSpeed
    case lifts
    case longestAirtime
    case totalAirtime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .descent: "Descent"
        case .jumps: "Jumps"
        case .distance: "Distance"
        case .topSpeed: "Top speed"
        case .lifts: "Lifts"
        case .longestAirtime: "Longest airtime"
        case .totalAirtime: "Total airtime"
        }
    }
}

public struct BermsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: String
        public var isPaused: Bool
        public var runCount: Int
        public var startedAt: Date
        public var elapsedSeconds: TimeInterval
        public var distanceMeters: Double
        public var descentMeters: Double
        public var topSpeedMetersPerSecond: Double
        public var metric: BermsLiveActivityMetric
        public var jumpCount: Int
        public var liftCount: Int
        public var longestAirtime: TimeInterval
        public var totalAirtime: TimeInterval
        public var lastUpdated: Date
        public var activityModeRawValue: String?

        public var isSkiDay: Bool {
            activityModeRawValue == "ski"
        }

        public var activityTitle: String {
            isSkiDay ? "Ski day" : "Berms"
        }

        public init(
            phase: String, isPaused: Bool, runCount: Int, startedAt: Date,
            elapsedSeconds: TimeInterval, distanceMeters: Double, descentMeters: Double,
            topSpeedMetersPerSecond: Double, metric: BermsLiveActivityMetric = .descent,
            jumpCount: Int = 0, liftCount: Int = 0, longestAirtime: TimeInterval = 0,
            totalAirtime: TimeInterval = 0, lastUpdated: Date = .now,
            activityModeRawValue: String? = nil
        ) {
            self.phase = phase
            self.isPaused = isPaused
            self.runCount = runCount
            self.startedAt = startedAt
            self.elapsedSeconds = elapsedSeconds
            self.distanceMeters = distanceMeters
            self.descentMeters = descentMeters
            self.topSpeedMetersPerSecond = topSpeedMetersPerSecond
            self.metric = metric
            self.jumpCount = jumpCount
            self.liftCount = liftCount
            self.longestAirtime = longestAirtime
            self.totalAirtime = totalAirtime
            self.lastUpdated = lastUpdated
            self.activityModeRawValue = activityModeRawValue
        }
    }

    public var rideID: String

    public init(rideID: UUID) {
        self.rideID = rideID.uuidString
    }
}
