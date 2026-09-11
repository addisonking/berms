import Foundation
import SwiftData

@Model
final class RideDay {
    @Attribute(.unique) var id: UUID
    var name: String?
    var notes: String?
    var startedAt: Date
    var endedAt: Date?
    var distanceMeters: Double
    var descentMeters: Double
    var liftMeters: Double
    var activeSeconds: Double
    var liftSeconds: Double
    var maximumSpeedMetersPerSecond: Double
    var checkpointKind: String?
    var checkpointStartedAt: Date?
    @Attribute(.externalStorage) var checkpointData: Data?
    var pausedAt: Date?
    var accumulatedPausedSeconds: Double?

    @Relationship(deleteRule: .cascade, inverse: \RideSegment.day)
    var segments: [RideSegment]

    init(startedAt: Date = .now) {
        self.id = UUID()
        self.name = nil
        self.notes = nil
        self.startedAt = startedAt
        self.endedAt = nil
        self.distanceMeters = 0
        self.descentMeters = 0
        self.liftMeters = 0
        self.activeSeconds = 0
        self.liftSeconds = 0
        self.maximumSpeedMetersPerSecond = 0
        self.pausedAt = nil
        self.accumulatedPausedSeconds = nil
        self.segments = []
    }

    var isFinished: Bool { endedAt != nil }

    var isPaused: Bool { endedAt == nil && pausedAt != nil }

    var displayName: String {
        normalizedName ?? startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var hasCustomName: Bool {
        normalizedName != nil
    }

    func setName(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? nil : trimmed
    }

    var hasNotes: Bool {
        normalizedNotes != nil
    }

    func setNotes(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        notes = trimmed.isEmpty ? nil : trimmed
    }

    var duration: TimeInterval {
        duration(at: .now)
    }

    func duration(at date: Date) -> TimeInterval {
        let end = endedAt ?? date
        let paused = (accumulatedPausedSeconds ?? 0)
            + (pausedAt.map { max(0, end.timeIntervalSince($0)) } ?? 0)
        return max(0, end.timeIntervalSince(startedAt) - paused)
    }

    func beginPause(at date: Date) {
        guard !isFinished, pausedAt == nil else { return }
        pausedAt = max(startedAt, date)
    }

    @discardableResult
    func endPause(at date: Date) -> TimeInterval {
        guard let pausedAt else { return 0 }
        let duration = max(0, date.timeIntervalSince(pausedAt))
        accumulatedPausedSeconds = (accumulatedPausedSeconds ?? 0) + duration
        self.pausedAt = nil
        return duration
    }

    var jumpCount: Int {
        segments.filter { $0.kind == .run }.reduce(0) { $0 + $1.jumps.count }
    }

    var longestJumpAirtime: TimeInterval {
        segments.filter { $0.kind == .run }.flatMap(\.jumps).map(\.airtime).max() ?? 0
    }

    func recalculateTotals() {
        let runs = segments.filter { $0.kind == .run }
        let lifts = segments.filter { $0.kind == .lift }
        distanceMeters = runs.reduce(0) { $0 + $1.distanceMeters }
        descentMeters = runs.reduce(0) { $0 + $1.verticalMeters }
        liftMeters = lifts.reduce(0) { $0 + $1.verticalMeters }
        activeSeconds = runs.reduce(0) { $0 + $1.duration }
        liftSeconds = lifts.reduce(0) { $0 + $1.duration }
        maximumSpeedMetersPerSecond = runs.map(\.maximumSpeedMetersPerSecond).max() ?? 0
    }

    private var normalizedName: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var normalizedNotes: String? {
        guard let notes else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@Model
final class RideSegment {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var startedAt: Date
    var endedAt: Date
    var distanceMeters: Double
    var verticalMeters: Double
    var maximumSpeedMetersPerSecond: Double
    var routeData: Data
    @Attribute(.externalStorage) var jumpData: Data?
    var day: RideDay?

    init(kind: SegmentKind, startedAt: Date, endedAt: Date, routeData: Data, jumps: [JumpEvent] = []) {
        self.id = UUID()
        self.kindRawValue = kind.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = 0
        self.verticalMeters = 0
        self.maximumSpeedMetersPerSecond = 0
        self.routeData = routeData
        self.jumpData = try? JSONEncoder().encode(jumps)
    }

    var kind: SegmentKind {
        SegmentKind(rawValue: kindRawValue) ?? .run
    }

    var duration: TimeInterval {
        let routePoints = points
        guard routePoints.count >= 2 else {
            return max(0, endedAt.timeIntervalSince(startedAt))
        }
        return zip(routePoints, routePoints.dropFirst()).reduce(0) { total, pair in
            let interval = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            return total + min(max(0, interval), 10)
        }
    }

    var points: [RoutePoint] {
        (try? RouteCodec.decode(routeData)) ?? []
    }

    var jumps: [JumpEvent] {
        guard let jumpData else { return [] }
        return (try? JSONDecoder().decode([JumpEvent].self, from: jumpData)) ?? []
    }
}

enum TrailDifficulty: String, Codable, CaseIterable, Identifiable, Sendable {
    case green
    case blue
    case black
    case doubleBlack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .green: "Green"
        case .blue: "Blue"
        case .black: "Black"
        case .doubleBlack: "Double Black"
        }
    }
}

enum TrailStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case freeRide
    case tech

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeRide: "Free Ride"
        case .tech: "Tech"
        }
    }
}

@Model
final class LearnedLift {
    @Attribute(.unique) var id: UUID
    var bottomLatitude: Double
    var bottomLongitude: Double
    var topLatitude: Double
    var topLongitude: Double
    var bottomRadius: Double
    var topRadius: Double
    var observationCount: Int
    var confidence: Double
    var lastObservedAt: Date

    init(profile: LearnedLiftProfile, lastObservedAt: Date = .now) {
        self.id = profile.id
        self.bottomLatitude = profile.bottom.latitude
        self.bottomLongitude = profile.bottom.longitude
        self.topLatitude = profile.top.latitude
        self.topLongitude = profile.top.longitude
        self.bottomRadius = profile.bottomRadius
        self.topRadius = profile.topRadius
        self.observationCount = profile.observationCount
        self.confidence = profile.confidence
        self.lastObservedAt = lastObservedAt
    }

    var profile: LearnedLiftProfile {
        LearnedLiftProfile(id: id,
                           bottom: Coordinate(latitude: bottomLatitude, longitude: bottomLongitude),
                           top: Coordinate(latitude: topLatitude, longitude: topLongitude),
                           bottomRadius: bottomRadius, topRadius: topRadius,
                           observationCount: observationCount, confidence: confidence)
    }
}

@Model
final class Trail {
    @Attribute(.unique) var id: UUID
    var name: String
    var difficultyRawValue: String
    var styleRawValue: String?
    var resort: String
    var createdAt: Date
    var updatedAt: Date
    @Attribute(.externalStorage) var averagedRouteData: Data?

    @Relationship(deleteRule: .cascade, inverse: \TrailPass.trail)
    var passes: [TrailPass]

    init(name: String, difficulty: TrailDifficulty, style: TrailStyle = .freeRide,
         resort: String, createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.difficultyRawValue = difficulty.rawValue
        self.styleRawValue = style.rawValue
        self.resort = resort
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.averagedRouteData = nil
        self.passes = []
    }

    var difficulty: TrailDifficulty {
        TrailDifficulty(rawValue: difficultyRawValue) ?? .blue
    }

    var style: TrailStyle {
        TrailStyle(rawValue: styleRawValue ?? "") ?? .freeRide
    }

    var points: [RoutePoint] {
        if let averagedRouteData,
           let points = try? RouteCodec.decode(averagedRouteData),
           !points.isEmpty {
            return points
        }
        return passes.sorted { $0.recordedAt < $1.recordedAt }.first?.points ?? []
    }

    var passCount: Int { passes.count }

    func recalculateAverage() {
        let paths = passes.map(\.points).filter { $0.count >= 2 }
        guard let firstPath = paths.first else {
            averagedRouteData = nil
            updatedAt = .now
            return
        }

        let sampleCount = min(500, max(40, paths.map(\.count).max() ?? firstPath.count))
        let resampledPaths = paths.map { Self.resample($0, count: sampleCount) }
        let averaged = (0..<sampleCount).map { index in
            let samples = resampledPaths.map { $0[index] }
            let divisor = Double(samples.count)
            let timestamp = samples[0].timestamp
            return RoutePoint(
                latitude: samples.reduce(0) { $0 + $1.latitude } / divisor,
                longitude: samples.reduce(0) { $0 + $1.longitude } / divisor,
                altitude: samples.reduce(0) { $0 + $1.altitude } / divisor,
                speed: samples.reduce(0) { $0 + $1.speed } / divisor,
                timestamp: timestamp
            )
        }
        averagedRouteData = try? RouteCodec.encode(averaged)
        updatedAt = .now
    }

    private static func resample(_ points: [RoutePoint], count: Int) -> [RoutePoint] {
        guard points.count >= 2, count >= 2 else { return points }
        var cumulative = [0.0]
        for pair in zip(points, points.dropFirst()) {
            let previous = Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let current = Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude)
            cumulative.append(cumulative.last! + previous.distance(to: current))
        }
        guard let total = cumulative.last, total > 0 else {
            return (0..<count).map { index in
                let sourceIndex = Int((Double(index) * Double(points.count - 1)
                    / Double(count - 1)).rounded())
                return points[min(points.count - 1, sourceIndex)]
            }
        }

        var segmentIndex = 0
        return (0..<count).map { index in
            let target = total * Double(index) / Double(count - 1)
            while segmentIndex + 1 < cumulative.count - 1,
                  cumulative[segmentIndex + 1] < target {
                segmentIndex += 1
            }
            let nextIndex = min(segmentIndex + 1, points.count - 1)
            let segmentDistance = cumulative[nextIndex] - cumulative[segmentIndex]
            let fraction = segmentDistance > 0
                ? (target - cumulative[segmentIndex]) / segmentDistance
                : 0
            let start = points[segmentIndex]
            let end = points[nextIndex]
            return RoutePoint(
                latitude: interpolate(start.latitude, end.latitude, fraction),
                longitude: interpolate(start.longitude, end.longitude, fraction),
                altitude: interpolate(start.altitude, end.altitude, fraction),
                speed: interpolate(start.speed, end.speed, fraction),
                timestamp: start.timestamp.addingTimeInterval(
                    end.timestamp.timeIntervalSince(start.timestamp) * fraction
                )
            )
        }
    }

    private static func interpolate(_ start: Double, _ end: Double, _ fraction: Double) -> Double {
        start + (end - start) * fraction
    }
}

@Model
final class TrailPass {
    @Attribute(.unique) var id: UUID
    var recordedAt: Date
    @Attribute(.externalStorage) var routeData: Data
    var distanceMeters: Double
    var trail: Trail?

    init(routePoints: [RoutePoint], recordedAt: Date = .now) {
        self.id = UUID()
        self.recordedAt = recordedAt
        self.routeData = (try? RouteCodec.encode(routePoints)) ?? Data()
        self.distanceMeters = zip(routePoints, routePoints.dropFirst()).reduce(0) { total, pair in
            let start = Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return total + start.distance(to: end)
        }
    }

    var points: [RoutePoint] {
        (try? RouteCodec.decode(routeData)) ?? []
    }
}

enum SegmentKind: String, Codable, Sendable {
    case run
    case lift

    var title: String {
        switch self {
        case .run: "Run"
        case .lift: "Lift"
        }
    }
}

struct RoutePoint: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let timestamp: Date

    init(latitude: Double, longitude: Double, altitude: Double, speed: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.timestamp = timestamp
    }
}

struct TrackSample: Codable, Sendable, Equatable {
    let coordinate: Coordinate
    let altitude: Double?
    let speed: Double
    let course: Double
    let horizontalAccuracy: Double
    let timestamp: Date
    let isStationary: Bool
    let isCycling: Bool
    let isAutomotive: Bool

    init(coordinate: Coordinate, altitude: Double?, speed: Double, course: Double = -1,
         horizontalAccuracy: Double = 10, timestamp: Date, isStationary: Bool = false,
         isCycling: Bool = false, isAutomotive: Bool = false) {
        self.coordinate = coordinate
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.isStationary = isStationary
        self.isCycling = isCycling
        self.isAutomotive = isAutomotive
    }

    var routePoint: RoutePoint {
        RoutePoint(latitude: coordinate.latitude, longitude: coordinate.longitude,
                   altitude: altitude ?? 0, speed: speed, timestamp: timestamp)
    }
}

struct Coordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct MotionAltitudeSample: Codable, Sendable {
    let timestamp: Date
    let relativeAltitude: Double
    let pressureKPa: Double
}

struct MotionActivitySample: Codable, Sendable {
    let recordedAt: Date
    let activityStart: Date
    let stationary: Bool
    let walking: Bool
    let running: Bool
    let cycling: Bool
    let automotive: Bool
    let unknown: Bool
    let confidence: Int
}

struct DeviceMotionSample: Codable, Sendable {
    let recordedAt: Date
    let monotonicSeconds: Double
    let userAccelerationX: Double
    let userAccelerationY: Double
    let userAccelerationZ: Double
    let rotationRateX: Double
    let rotationRateY: Double
    let rotationRateZ: Double
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double
    let quaternionW: Double
    let quaternionX: Double
    let quaternionY: Double
    let quaternionZ: Double
}

struct AltitudeFusion: Sendable {
    private(set) var barometerAvailable = false
    private var gpsBaseline: Double?
    private var relativeBaseline: Double?
    private var latestGPSAltitude: Double?
    private var gpsOffset: Double = 0
    private var usingBarometer = false

    mutating func reset(barometerAvailable: Bool) {
        self.barometerAvailable = barometerAvailable
        gpsBaseline = nil
        relativeBaseline = nil
        latestGPSAltitude = nil
        gpsOffset = 0
        usingBarometer = false
    }

    mutating func update(gpsAltitude: Double?, relativeAltitude: Double?) -> Double? {
        if let gpsAltitude, gpsAltitude.isFinite {
            latestGPSAltitude = gpsAltitude
        }

        guard barometerAvailable else { return latestGPSAltitude }
        guard let relativeAltitude, relativeAltitude.isFinite else {
            usingBarometer = false
            return latestGPSAltitude.map { $0 + gpsOffset }
        }

        if !usingBarometer {
            gpsBaseline = latestGPSAltitude.map { $0 + gpsOffset }
            relativeBaseline = relativeAltitude
        }

        guard let gpsBaseline, let relativeBaseline else { return nil }
        usingBarometer = true
        let altitude = gpsBaseline + relativeAltitude - relativeBaseline
        if let latestGPSAltitude {
            gpsOffset = altitude - latestGPSAltitude
        }
        return altitude
    }
}

struct TrackSampleNormalizer: Sendable {
    private(set) var previous: TrackSample?
    private let maximumSpeed: Double = 45
    private let maximumHorizontalAccuracy: Double = 80
    private static let lowSpeedThreshold: Double = 1
    private static let maximumLowSpeedDriftMeters: Double = 30

    static func isLowSpeedDrift(previous: TrackSample?, current: TrackSample) -> Bool {
        guard let previous,
              previous.speed <= lowSpeedThreshold,
              current.speed <= lowSpeedThreshold else { return false }
        let interval = current.timestamp.timeIntervalSince(previous.timestamp)
        guard interval > 0 else { return false }
        return previous.coordinate.distance(to: current.coordinate) > maximumLowSpeedDriftMeters
    }

    mutating func normalize(_ sample: TrackSample) -> TrackSample? {
        guard sample.coordinate.latitude.isFinite,
              sample.coordinate.longitude.isFinite,
              (-90...90).contains(sample.coordinate.latitude),
              (-180...180).contains(sample.coordinate.longitude),
              sample.horizontalAccuracy.isFinite,
              sample.horizontalAccuracy >= 0,
              sample.horizontalAccuracy <= maximumHorizontalAccuracy,
              sample.speed.isFinite,
              sample.speed >= 0,
              sample.speed <= maximumSpeed else { return nil }

        let lowSpeed = sample.speed <= Self.lowSpeedThreshold

        if let previous {
            let interval = sample.timestamp.timeIntervalSince(previous.timestamp)
            guard interval > 0 else { return nil }
            // A stopped phone can report large coordinate jumps. Reject those once
            // the previous normalized sample is also stopped, rather than allowing
            // the jump to become part of the route.
            if lowSpeed && !sample.isStationary {
                guard !Self.isLowSpeedDrift(previous: previous, current: sample) else { return nil }
            }
            let displacement = previous.coordinate.distance(to: sample.coordinate)
            let allowedDisplacement = max(250, maximumSpeed * interval + 120)
            guard displacement <= allowedDisplacement else { return nil }
        }

        let smoothedSpeed: Double
        if sample.isStationary || lowSpeed {
            // Do not carry moving speed into a break. This keeps dwell cleanup
            // effective even when Core Location does not flag every sample as
            // stationary.
            smoothedSpeed = 0
        } else if let previous, previous.isStationary || previous.speed <= Self.lowSpeedThreshold {
            // Resume at the reported speed instead of lagging behind by several
            // samples after a break.
            smoothedSpeed = sample.speed
        } else if let previous {
            smoothedSpeed = previous.speed * 0.65 + sample.speed * 0.35
        } else {
            smoothedSpeed = sample.speed
        }

        let coordinate: Coordinate
        if lowSpeed, let previous, previous.speed <= Self.lowSpeedThreshold {
            // Hold the last stable point through the stopped portion of a route.
            // A large jump was rejected above; smaller GPS wander is discarded.
            coordinate = previous.coordinate
        } else {
            coordinate = sample.coordinate
        }

        let smoothedAltitude: Double?
        switch (previous?.altitude, sample.altitude, lowSpeed) {
        case let (old?, _, true):
            smoothedAltitude = old
        case let (old?, new?, _):
            smoothedAltitude = old * 0.7 + new * 0.3
        case let (nil, altitude?, _), let (altitude?, nil, _):
            smoothedAltitude = altitude
        case (_, _, _):
            smoothedAltitude = nil
        }

        let normalized = TrackSample(
            coordinate: coordinate,
            altitude: smoothedAltitude,
            speed: smoothedSpeed,
            course: sample.course,
            horizontalAccuracy: sample.horizontalAccuracy,
            timestamp: sample.timestamp,
            isStationary: sample.isStationary,
            isCycling: sample.isCycling,
            isAutomotive: sample.isAutomotive
        )
        previous = normalized
        return normalized
    }

    mutating func seed(with sample: TrackSample?) {
        previous = sample
    }
}

struct SegmentDraft: Sendable {
    let kind: SegmentKind
    let points: [TrackSample]
    let startedAt: Date
    let endedAt: Date
    let jumps: [JumpEvent]

    init(kind: SegmentKind, points: [TrackSample], startedAt: Date, endedAt: Date,
         jumps: [JumpEvent] = []) {
        self.kind = kind
        self.points = points
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.jumps = jumps
    }

    var routePoints: [RoutePoint] { points.map(\.routePoint) }

    var distanceMeters: Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + pair.0.coordinate.distance(to: pair.1.coordinate)
        }
    }

    var netVerticalMeters: Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let change = (pair.1.altitude ?? 0) - (pair.0.altitude ?? 0)
            return total + (kind == .run ? max(0, -change) : max(0, change))
        }
    }

    var maximumSpeed: Double {
        points.map(\.speed).max() ?? 0
    }
}

extension Coordinate {
    func distance(to other: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

struct DetectorSnapshot: Sendable {
    let phase: DetectorPhase
    let currentPoints: [TrackSample]
    let lastSample: TrackSample?
}

enum DetectorPhase: String, Sendable {
    case idle
    case lift
    case run

    var title: String {
        rawValue.capitalized
    }
}

enum DetectorEvent: Sendable {
    case started(kind: SegmentKind, points: [TrackSample])
    case updated(kind: SegmentKind, point: TrackSample)
    case finished(SegmentDraft)
}
