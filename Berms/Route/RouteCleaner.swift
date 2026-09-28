import Foundation

struct RouteCleaner: Sendable {
    struct Configuration: Sendable {
        var lowSpeedThreshold: Double = 1.5
        var minimumDwellDuration: TimeInterval = 4
        var maximumDwellExtent: Double = 80
        var maximumHorizontalAccuracy: Double = 80
        var maximumSpikeDistance: Double = 45
        var smoothingDistance: Double = 80
    }

    let configuration: Configuration

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func clean(_ samples: [TrackSample]) -> [TrackSample] {
        let valid = samples.filter {
            $0.horizontalAccuracy.isFinite
                && $0.horizontalAccuracy >= 0
                && $0.horizontalAccuracy <= configuration.maximumHorizontalAccuracy
        }
        let cleanedPoints = clean(valid.map(\.routePoint))
        var result: [TrackSample] = []
        result.reserveCapacity(cleanedPoints.count)
        var searchIndex = 0
        for point in cleanedPoints {
            // Both arrays are time-ordered, so walk a single cursor instead of
            // scanning every source sample for each cleaned point.
            while searchIndex + 1 < valid.count,
                abs(valid[searchIndex + 1].timestamp.timeIntervalSince(point.timestamp))
                    <= abs(valid[searchIndex].timestamp.timeIntervalSince(point.timestamp))
            {
                searchIndex += 1
            }
            let source = valid.indices.contains(searchIndex) ? valid[searchIndex] : nil
            result.append(
                TrackSample(
                    coordinate: Coordinate(latitude: point.latitude, longitude: point.longitude),
                    altitude: point.altitude,
                    speed: point.speed,
                    course: source?.course ?? -1,
                    horizontalAccuracy: source?.horizontalAccuracy ?? configuration.maximumHorizontalAccuracy,
                    timestamp: point.timestamp,
                    isStationary: source?.isStationary ?? false,
                    isCycling: source?.isCycling ?? false,
                    isAutomotive: source?.isAutomotive ?? false
                ))
        }
        return result
    }

    func clean(_ points: [RoutePoint]) -> [RoutePoint] {
        let valid = points.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
                && (-90...90).contains($0.latitude)
                && (-180...180).contains($0.longitude)
        }
        guard valid.count >= 3 else { return valid }

        let withoutSpikes = removeSpikes(from: valid)
        let withoutStars = collapseDwellClusters(in: withoutSpikes)
        return smoothSmallCorrections(in: withoutStars)
    }

    private func removeSpikes(from points: [RoutePoint]) -> [RoutePoint] {
        guard points.count >= 3 else { return points }
        var result = [points[0]]
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]
            let shortcut = coordinate(for: previous).distance(to: coordinate(for: next))
            let detour =
                coordinate(for: previous).distance(to: coordinate(for: current))
                + coordinate(for: current).distance(to: coordinate(for: next))
            if detour > max(configuration.maximumSpikeDistance * 2, shortcut * 2.8 + 15),
                current.speed <= configuration.lowSpeedThreshold * 2
            {
                continue
            }
            result.append(current)
        }
        result.append(points[points.count - 1])
        return result
    }

    private func collapseDwellClusters(in points: [RoutePoint]) -> [RoutePoint] {
        var result: [RoutePoint] = []
        var index = 0

        while index < points.count {
            guard points[index].speed <= configuration.lowSpeedThreshold else {
                result.append(points[index])
                index += 1
                continue
            }

            var end = index
            while end + 1 < points.count,
                points[end + 1].speed <= configuration.lowSpeedThreshold,
                coordinate(for: points[index]).distance(to: coordinate(for: points[end + 1]))
                    <= configuration.maximumDwellExtent
            {
                end += 1
            }

            let cluster = Array(points[index...end])
            let duration = (cluster.last?.timestamp ?? .distantPast)
                .timeIntervalSince(cluster.first?.timestamp ?? .distantPast)
            if cluster.count >= 2 && duration >= configuration.minimumDwellDuration {
                if let before = result.last, end + 1 < points.count {
                    // Bridge a break with one stable point between the last point
                    // before the stop and the first point after it. Averaging the
                    // GPS wander itself can move the route off the trail.
                    result.append(
                        interpolatedPoint(
                            from: before, to: points[end + 1],
                            timestamp: cluster[cluster.count / 2].timestamp))
                } else {
                    result.append(representative(of: cluster))
                }
            } else {
                result.append(contentsOf: cluster)
            }
            index = end + 1
        }
        return result
    }

    private func smoothSmallCorrections(in points: [RoutePoint]) -> [RoutePoint] {
        guard points.count >= 3 else { return points }
        return points.indices.map { index in
            guard index > 0, index + 1 < points.count else { return points[index] }
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]
            let previousDistance = coordinate(for: previous).distance(to: coordinate(for: current))
            let nextDistance = coordinate(for: current).distance(to: coordinate(for: next))
            guard previousDistance <= configuration.smoothingDistance,
                nextDistance <= configuration.smoothingDistance
            else { return current }
            return RoutePoint(
                latitude: previous.latitude * 0.2 + current.latitude * 0.6 + next.latitude * 0.2,
                longitude: previous.longitude * 0.2 + current.longitude * 0.6 + next.longitude * 0.2,
                altitude: previous.altitude * 0.2 + current.altitude * 0.6 + next.altitude * 0.2,
                speed: current.speed,
                timestamp: current.timestamp
            )
        }
    }

    private func representative(of points: [RoutePoint]) -> RoutePoint {
        let divisor = Double(points.count)
        return RoutePoint(
            latitude: points.reduce(0) { $0 + $1.latitude } / divisor,
            longitude: points.reduce(0) { $0 + $1.longitude } / divisor,
            altitude: points.reduce(0) { $0 + $1.altitude } / divisor,
            speed: 0,
            timestamp: points[points.count / 2].timestamp
        )
    }

    private func interpolatedPoint(
        from start: RoutePoint, to end: RoutePoint,
        timestamp: Date
    ) -> RoutePoint {
        RoutePoint(
            latitude: (start.latitude + end.latitude) / 2,
            longitude: (start.longitude + end.longitude) / 2,
            altitude: (start.altitude + end.altitude) / 2,
            speed: 0,
            timestamp: timestamp
        )
    }

    private func coordinate(for point: RoutePoint) -> Coordinate {
        Coordinate(latitude: point.latitude, longitude: point.longitude)
    }
}

struct RouteMetrics: Sendable {
    static func distance(of points: [RoutePoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total
                + Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(to: Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    static func vertical(of points: [RoutePoint], kind: SegmentKind) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let change = pair.1.altitude - pair.0.altitude
            return total + (kind == .run ? max(0, -change) : max(0, change))
        }
    }

    static func maximumSpeed(of points: [RoutePoint]) -> Double {
        points.map(\.speed).max() ?? 0
    }
}
