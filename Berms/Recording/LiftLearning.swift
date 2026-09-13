import Foundation
import SwiftData

struct LearnedLiftProfile: Codable, Hashable, Sendable {
    let id: UUID
    let bottom: Coordinate
    let top: Coordinate
    let bottomRadius: Double
    let topRadius: Double
    let observationCount: Int
    let confidence: Double

    func containsBottom(_ coordinate: Coordinate) -> Bool {
        bottom.distance(to: coordinate) <= bottomRadius
    }

    func containsTop(_ coordinate: Coordinate) -> Bool {
        top.distance(to: coordinate) <= topRadius
    }
}

struct LiftLearningEngine: Sendable {
    var activationCount = 3
    var maximumEndpointDistance = 180.0

    func merge(observation: (bottom: Coordinate, top: Coordinate), into profiles: [LearnedLiftProfile], id: UUID = UUID()) -> [LearnedLiftProfile] {
        var updated = profiles
        guard let index = profiles.firstIndex(where: {
            $0.bottom.distance(to: observation.bottom) <= maximumEndpointDistance
                && $0.top.distance(to: observation.top) <= maximumEndpointDistance
        }) else {
            updated.append(LearnedLiftProfile(id: id, bottom: observation.bottom, top: observation.top,
                                              bottomRadius: 70, topRadius: 70,
                                              observationCount: 1, confidence: 1.0 / Double(activationCount)))
            return updated
        }

        let old = profiles[index]
        let count = old.observationCount
        let weight = 1.0 / Double(count + 1)
        let bottom = blend(old.bottom, observation.bottom, weight: weight)
        let top = blend(old.top, observation.top, weight: weight)
        let bottomRadius = adaptiveRadius(old.bottomRadius, distance: old.bottom.distance(to: observation.bottom), count: count)
        let topRadius = adaptiveRadius(old.topRadius, distance: old.top.distance(to: observation.top), count: count)
        let newCount = count + 1
        updated[index] = LearnedLiftProfile(id: old.id, bottom: bottom, top: top,
                                            bottomRadius: bottomRadius, topRadius: topRadius,
                                            observationCount: newCount,
                                            confidence: min(1, Double(newCount) / Double(activationCount)))
        return updated
    }

    func observations(from segments: [RideSegment]) -> [(bottom: Coordinate, top: Coordinate)] {
        segments.filter { $0.kind == .lift }.compactMap { segment in
            let points = RouteCleaner().clean(segment.points)
            guard let first = points.first, let last = points.last,
                  first.timestamp < last.timestamp else { return nil }
            return (bottom: Coordinate(latitude: first.latitude, longitude: first.longitude),
                    top: Coordinate(latitude: last.latitude, longitude: last.longitude))
        }
    }

    private func blend(_ old: Coordinate, _ new: Coordinate, weight: Double) -> Coordinate {
        Coordinate(latitude: old.latitude + (new.latitude - old.latitude) * weight,
                    longitude: old.longitude + (new.longitude - old.longitude) * weight)
    }

    private func adaptiveRadius(_ old: Double, distance: Double, count: Int) -> Double {
        let observed = min(120, max(45, distance * 1.5))
        return min(140, max(45, (old * Double(count) + observed) / Double(count + 1)))
    }
}
