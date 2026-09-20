import Foundation
import SwiftData

enum SeasonBucket: String, Codable, CaseIterable, Identifiable, Sendable {
    case summer
    case winter

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

enum ActivityMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case bikePark
    case ski

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bikePark: "Bike"
        case .ski: "Ski"
        }
    }

    var readyTitle: String {
        switch self {
        case .bikePark: "Ready to ride"
        case .ski: "Ready to ski"
        }
    }

    var readyDescription: String {
        switch self {
        case .bikePark: "Track runs, lifts, and routes."
        case .ski: "Track ski runs, lifts, and your day on the mountain."
        }
    }

    var startTitle: String {
        switch self {
        case .bikePark: "Start"
        case .ski: "Start ski day"
        }
    }

    var systemImage: String {
        switch self {
        case .bikePark: "figure.outdoor.cycle"
        case .ski: "snowflake"
        }
    }

    var season: SeasonBucket {
        switch self {
        case .bikePark: .summer
        case .ski: .winter
        }
    }

    var activeTimeTitle: String {
        switch self {
        case .bikePark: "Riding time"
        case .ski: "Ski time"
        }
    }
}

@Model
final class RideDay {
    @Attribute(.unique) var id: UUID
    var name: String?
    var notes: String?
    var activityModeRawValue: String?
    var catalogID: String?
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
        self.activityModeRawValue = nil
        self.catalogID = nil
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

    var activityMode: ActivityMode {
        ActivityMode(rawValue: activityModeRawValue ?? "") ?? .bikePark
    }

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

    /// First GPS point of the day, used to resolve which resort it belongs to.
    var firstRecordedCoordinate: Coordinate? {
        for segment in segments.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let point = segment.points.first else { continue }
            return Coordinate(latitude: point.latitude, longitude: point.longitude)
        }
        return nil
    }

    func duration(at date: Date) -> TimeInterval {
        let end = endedAt ?? date
        let paused =
            (accumulatedPausedSeconds ?? 0)
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

    var totalJumpAirtime: TimeInterval {
        segments.filter { $0.kind == .run }.flatMap(\.jumps).reduce(0) { $0 + $1.airtime }
    }

    var totalJumpDistanceMeters: Double {
        segments.filter { $0.kind == .run }.flatMap(\.jumps).compactMap(\.lengthMeters).reduce(0, +)
    }

    var maximumJumpLengthMeters: Double {
        segments.filter { $0.kind == .run }.flatMap(\.jumps).compactMap(\.lengthMeters).max() ?? 0
    }

    var maximumJumpHeightMeters: Double {
        segments.filter { $0.kind == .run }.flatMap(\.jumps).compactMap(\.heightMeters).max() ?? 0
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

struct BermsDataExport: Codable, Sendable {
    let format: String
    let version: Int
    let exportedAt: Date
    let days: [Day]
    let parsed: Parsed
    let rawDiagnostics: RawDiagnostics?

    struct Day: Codable, Sendable {
        let id: String
        let name: String?
        let notes: String?
        let activityMode: ActivityMode?
        let catalogID: String?
        let startedAt: Date
        let endedAt: Date?
        let segments: [Segment]
    }

    struct Segment: Codable, Sendable {
        let id: String
        let kind: SegmentKind
        let runNumber: Int?
        let startedAt: Date
        let endedAt: Date
        let distanceMeters: Double
        let verticalMeters: Double
        let maximumSpeedMetersPerSecond: Double
        let route: [RoutePoint]
        let trails: [String]
        let jumps: [Jump]
    }

    struct Parsed: Codable, Sendable {
        let dayID: String
        let runCount: Int
        let runs: [Run]
    }

    struct Run: Codable, Sendable {
        let segmentID: String
        let number: Int
        let startedAt: Date
        let endedAt: Date
        let distanceMeters: Double
        let verticalMeters: Double
        let maximumSpeedMetersPerSecond: Double
        let route: [RoutePoint]
        let trails: [String]
        let jumps: [Jump]
    }

    struct Jump: Codable, Sendable {
        let takeoffAt: Date
        let landingAt: Date
        let airtimeSeconds: Double
        let lengthMeters: Double?
        let heightMeters: Double?
        let dropMeters: Double?

        init(_ jump: JumpEvent) {
            takeoffAt = jump.takeoffTimestamp
            landingAt = jump.landingTimestamp
            airtimeSeconds = jump.airtime
            lengthMeters = jump.lengthMeters
            heightMeters = jump.heightMeters
            dropMeters = jump.dropMeters
        }
    }

    struct RawDiagnostics: Codable, Sendable {
        let filename: String
        let format: String
    }

    init(
        day: RideDay, trails: [Trail] = [], exportedAt: Date = .now,
        rawDiagnosticsFilename: String? = nil
    ) {
        var nextRunNumber = 0
        let catalogTrails: [Trail]
        if let catalogID = day.catalogID,
            let catalog = TrailCatalogRegistry.catalog(withID: catalogID)
        {
            catalogTrails = TrailCatalogRegistry.trails(trails, for: catalog)
        } else {
            catalogTrails = trails
        }
        let trailNamesByID = Dictionary(
            catalogTrails.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first })
        let trailCandidates = catalogTrails.map {
            TrailRouteCandidate(
                id: $0.id, name: $0.name, difficulty: $0.difficulty,
                routes: $0.matcherRoutes)
        }
        let matcher = TrailRouteMatcher()

        func trailSequence(for segment: RideSegment) -> [String] {
            guard segment.kind == .run, segment.points.count >= 2,
                !trailCandidates.isEmpty
            else { return [] }
            let route = RouteCleaner().clean(segment.points)
            let sections = matcher.matchResult(for: route, candidates: trailCandidates).sections
            var result: [String] = []
            for name in sections.compactMap({ trailNamesByID[$0.trailID] })
            where result.last != name {
                result.append(name)
            }
            return result
        }

        let segments = day.segments.sorted { $0.startedAt < $1.startedAt }.map { segment in
            let runNumber: Int?
            if segment.kind == .run {
                nextRunNumber += 1
                runNumber = nextRunNumber
            } else {
                runNumber = nil
            }
            return Segment(
                id: segment.id.uuidString,
                kind: segment.kind,
                runNumber: runNumber,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                distanceMeters: segment.distanceMeters,
                verticalMeters: segment.verticalMeters,
                maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond,
                route: segment.points,
                trails: trailSequence(for: segment),
                jumps: segment.jumps.map(Jump.init)
            )
        }

        let runs = segments.compactMap { segment -> Run? in
            guard let number = segment.runNumber else { return nil }
            return Run(
                segmentID: segment.id,
                number: number,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                distanceMeters: segment.distanceMeters,
                verticalMeters: segment.verticalMeters,
                maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond,
                route: segment.route,
                trails: segment.trails,
                jumps: segment.jumps
            )
        }

        format = "berms.day"
        version = 6
        self.exportedAt = exportedAt
        days = [
            Day(
                id: day.id.uuidString, name: day.name, notes: day.notes,
                activityMode: day.activityMode, catalogID: day.catalogID,
                startedAt: day.startedAt, endedAt: day.endedAt, segments: segments)
        ]
        parsed = Parsed(dayID: day.id.uuidString, runCount: runs.count, runs: runs)
        rawDiagnostics = rawDiagnosticsFilename.map {
            RawDiagnostics(filename: $0, format: "jsonl")
        }
    }
}

enum TrailDifficulty: String, Codable, CaseIterable, Identifiable, Sendable {
    case green
    case blue
    case black
    case doubleBlack
    /// Published without a rating, which is common for service roads and
    /// new cuts. Kept so a trail is never dropped or given a made-up color.
    case unrated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .green: "Green"
        case .blue: "Blue"
        case .black: "Black"
        case .doubleBlack: "Double Black"
        case .unrated: "Unrated"
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
        LearnedLiftProfile(
            id: id,
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
    var catalogID: String?
    var createdAt: Date
    var updatedAt: Date
    @Attribute(.externalStorage) var averagedRouteData: Data?

    @Transient private var cachedPoints: [RoutePoint]?

    @Relationship(deleteRule: .cascade, inverse: \TrailPass.trail)
    var passes: [TrailPass]

    init(
        name: String, difficulty: TrailDifficulty, style: TrailStyle = .freeRide,
        resort: String, catalogID: String? = nil, createdAt: Date = .now
    ) {
        self.id = UUID()
        self.name = name
        self.difficultyRawValue = difficulty.rawValue
        self.styleRawValue = style.rawValue
        self.resort = resort
        self.catalogID = catalogID
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
        if let cachedPoints { return cachedPoints }
        let resolved: [RoutePoint]
        if let averagedRouteData,
            let points = try? RouteCodec.decode(averagedRouteData),
            !points.isEmpty
        {
            resolved = points
        } else {
            resolved = passes.sorted { $0.recordedAt < $1.recordedAt }.first?.points ?? []
        }
        cachedPoints = resolved
        return resolved
    }

    var passCount: Int { passes.count }

    func recalculateAverage() {
        cachedPoints = nil
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
            cumulative.append(cumulative[cumulative.count - 1] + previous.distance(to: current))
        }
        guard let total = cumulative.last, total > 0 else {
            return (0..<count).map { index in
                let sourceIndex = Int(
                    (Double(index) * Double(points.count - 1)
                        / Double(count - 1)).rounded())
                return points[min(points.count - 1, sourceIndex)]
            }
        }

        var segmentIndex = 0
        return (0..<count).map { index in
            let target = total * Double(index) / Double(count - 1)
            while segmentIndex + 1 < cumulative.count - 1,
                cumulative[segmentIndex + 1] < target
            {
                segmentIndex += 1
            }
            let nextIndex = min(segmentIndex + 1, points.count - 1)
            let segmentDistance = cumulative[nextIndex] - cumulative[segmentIndex]
            let fraction =
                segmentDistance > 0
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

/// Stats the live tracking panel on the Track screen can show.
enum LiveStatMetric: String, CaseIterable, Identifiable, Sendable {
    case topSpeed
    case distance
    case longestJump
    case highestAir
    case jumps
    case bestAirtime

    static let defaultSelection: [LiveStatMetric] = [
        .topSpeed, .distance, .longestJump, .highestAir, .jumps,
    ]
    /// Fills the panel's 3-wide, 2-tall grid without crowding.
    static let selectionLimit = 6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topSpeed: "Top speed"
        case .distance: "Distance"
        case .longestJump: "Longest jump"
        case .highestAir: "Highest air"
        case .jumps: "Jumps"
        case .bestAirtime: "Best airtime"
        }
    }
}

struct RoutePoint: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let timestamp: Date
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

    init(
        coordinate: Coordinate, altitude: Double?, speed: Double, course: Double = -1,
        horizontalAccuracy: Double = 10, timestamp: Date, isStationary: Bool = false,
        isCycling: Bool = false, isAutomotive: Bool = false
    ) {
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
        RoutePoint(
            latitude: coordinate.latitude, longitude: coordinate.longitude,
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
            current.speed <= lowSpeedThreshold
        else { return false }
        let interval = current.timestamp.timeIntervalSince(previous.timestamp)
        guard interval > 0 else { return false }
        return previous.coordinate.distance(to: current.coordinate) > maximumLowSpeedDriftMeters
    }

    mutating func normalize(_ sample: TrackSample, smoothAltitude: Bool = true) -> TrackSample? {
        guard sample.coordinate.latitude.isFinite,
            sample.coordinate.longitude.isFinite,
            (-90...90).contains(sample.coordinate.latitude),
            (-180...180).contains(sample.coordinate.longitude),
            sample.horizontalAccuracy.isFinite,
            sample.horizontalAccuracy >= 0,
            sample.horizontalAccuracy <= maximumHorizontalAccuracy,
            sample.speed.isFinite,
            sample.speed >= 0,
            sample.speed <= maximumSpeed
        else { return nil }

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
        if !smoothAltitude {
            // Barometer-fused altitude is already stable, and low-passing it
            // averages away the fast drops jump measurements depend on.
            smoothedAltitude = sample.altitude ?? previous?.altitude
        } else {
            switch (previous?.altitude, sample.altitude, lowSpeed) {
            case (let old?, _, true):
                smoothedAltitude = old
            case (let old?, let new?, _):
                smoothedAltitude = old * 0.7 + new * 0.3
            case (nil, let altitude?, _), (let altitude?, nil, _):
                smoothedAltitude = altitude
            case (_, _, _):
                smoothedAltitude = nil
            }
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
    let runNumber: Int?
    let trailSequence: [String]?
    let points: [TrackSample]
    let startedAt: Date
    let endedAt: Date
    let jumps: [JumpEvent]

    init(
        kind: SegmentKind, points: [TrackSample], startedAt: Date, endedAt: Date,
        runNumber: Int? = nil,
        trailSequence: [String]? = nil,
        jumps: [JumpEvent] = []
    ) {
        self.kind = kind
        self.runNumber = runNumber
        self.trailSequence = trailSequence
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
        let a =
            sin(dLat / 2) * sin(dLat / 2)
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
