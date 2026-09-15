import Foundation

struct StudioDay: Identifiable, Sendable {
    let id: String
    var name: String?
    var startedAt: Date
    var endedAt: Date?
    var segments: [StudioSegment]

    var runs: [StudioSegment] { segments.filter { $0.kind == .run } }
    var displayName: String { name ?? StudioFormat.dayLabel(startedAt) }
}

struct StudioSegment: Identifiable, Sendable {
    let id: String
    let kind: SegmentKind
    let runNumber: Int?
    let startedAt: Date
    let endedAt: Date
    let distanceMeters: Double
    let verticalMeters: Double
    let maximumSpeedMetersPerSecond: Double
    let route: [RoutePoint]
    let jumps: [JumpEvent]
    let trails: [String]

    var duration: TimeInterval {
        guard route.count >= 2 else { return max(0, endedAt.timeIntervalSince(startedAt)) }
        return zip(route, route.dropFirst()).reduce(0) { total, pair in
            total + min(max(0, pair.1.timestamp.timeIntervalSince(pair.0.timestamp)), 10)
        }
    }

    var title: String {
        trails.isEmpty ? "Untitled run" : trails.joined(separator: " → ")
    }

    var maximumSpeed: Double { maximumSpeedMetersPerSecond }
}

enum StudioExportError: LocalizedError {
    case unreadable(URL)
    case invalid(URL, Error)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Couldn't read \(url.lastPathComponent)."
        case .invalid(let url, let error):
            "Invalid Berms export \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

/// Mirrors the Rust `berms_rides::Export` interchange schema.
struct StudioExport: Decodable {
    let version: Int
    let exportedAt: Date
    let days: [Day]
    let parsed: Parsed?

    struct Day: Decodable {
        let id: String
        let name: String?
        let startedAt: Date
        let endedAt: Date?
        let segments: [Segment]
    }

    struct Segment: Decodable {
        let id: String
        let kind: String?
        let runNumber: Int?
        let startedAt: Date
        let endedAt: Date
        let distanceMeters: Double?
        let verticalMeters: Double?
        let maximumSpeedMetersPerSecond: Double?
        let trails: [String]?
        let route: [Point]?
        let jumps: [Jump]?
    }

    struct Parsed: Decodable {
        let dayID: String?
        let runCount: Int?
        let runs: [ParsedRun]?
    }

    struct ParsedRun: Decodable {
        let segmentID: String
        let number: Int
        let trails: [String]?
    }

    struct Point: Decodable {
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        let speed: Double?
        let timestamp: Date
    }

    struct Jump: Decodable {
        let takeoffAt: Date
        let landingAt: Date
        let airtimeSeconds: Double?
    }

    static func load(_ url: URL) throws -> StudioExport {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StudioExportError.unreadable(url)
        }
        do {
            return try decoder().decode(StudioExport.self, from: data)
        } catch {
            throw StudioExportError.invalid(url, error)
        }
    }

    func studioDays() -> [StudioDay] {
        let parsedRuns = Dictionary(
            (parsed?.runs ?? []).map { ($0.segmentID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return days.map { day in
            StudioDay(
                id: day.id,
                name: day.name,
                startedAt: day.startedAt,
                endedAt: day.endedAt,
                segments: day.segments.map { segment in
                    let kind = SegmentKind(rawValue: segment.kind ?? "run") ?? .run
                    let route = (segment.route ?? []).map {
                        RoutePoint(
                            latitude: $0.latitude, longitude: $0.longitude,
                            altitude: $0.altitude ?? 0, speed: $0.speed ?? 0,
                            timestamp: $0.timestamp)
                    }
                    let jumps = (segment.jumps ?? []).map { jump -> JumpEvent in
                        let takeoff = jump.takeoffAt.timeIntervalSinceReferenceDate
                        let airtime =
                            jump.airtimeSeconds
                            ?? max(0, jump.landingAt.timeIntervalSince(jump.takeoffAt))
                        return JumpEvent(
                            takeoffTimestamp: jump.takeoffAt,
                            landingTimestamp: jump.landingAt,
                            takeoffMonotonicSeconds: takeoff,
                            landingMonotonicSeconds: takeoff + airtime
                        )
                    }
                    return StudioSegment(
                        id: segment.id, kind: kind,
                        runNumber: segment.runNumber
                            ?? parsedRuns[segment.id]?.number
                            ?? Self.runNumber(from: segment.id),
                        startedAt: segment.startedAt, endedAt: segment.endedAt,
                        distanceMeters: segment.distanceMeters ?? RouteMetrics.distance(of: route),
                        verticalMeters: segment.verticalMeters
                            ?? RouteMetrics.vertical(of: route, kind: kind),
                        maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond
                            ?? RouteMetrics.maximumSpeed(of: route),
                        route: route, jumps: jumps,
                        trails: segment.trails ?? parsedRuns[segment.id]?.trails ?? []
                    )
                }
            )
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = StudioDateParser.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized date \(value)")
            }
            return date
        }
        return decoder
    }

    private static func runNumber(from id: String) -> Int? {
        guard
            let match = id.range(
                of: #"(?:^|[-_])run[-_]?([0-9]+)$"#,
                options: .regularExpression)
        else {
            return nil
        }
        let suffix = id[match].split { $0 == "-" || $0 == "_" }.last
        return suffix.flatMap { Int($0) }
    }
}

enum StudioDateParser {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
