import SwiftData
import SwiftUI

struct DaySummaryMetric: Identifiable, Equatable, Hashable {
    let label: String
    let value: String

    var id: String { label }
}

enum DaySummaryPresentation {
    static func rows(of metrics: [DaySummaryMetric]) -> [[DaySummaryMetric]] {
        stride(from: 0, to: metrics.count, by: 2).map { index in
            Array(metrics[index..<min(index + 2, metrics.count)])
        }
    }

    static func detailMetrics(day: RideDay, runCount: Int, liftCount: Int) -> [DaySummaryMetric] {
        var metrics: [DaySummaryMetric] = []
        appendPositive(
            BermsFormat.elevation(day.descentMeters), label: "Descent", when: day.descentMeters, to: &metrics)
        appendPositive(
            BermsFormat.distance(day.distanceMeters), label: "Distance", when: day.distanceMeters, to: &metrics)
        if runCount > 0 || liftCount > 0 {
            metrics.append(DaySummaryMetric(label: "Runs", value: "\(runCount)"))
        }
        appendPositive(
            BermsFormat.speed(day.maximumSpeedMetersPerSecond),
            label: "Top speed",
            when: day.maximumSpeedMetersPerSecond,
            to: &metrics)
        appendPositive(
            BermsFormat.duration(day.activeSeconds),
            label: "Riding time",
            when: day.activeSeconds,
            to: &metrics)
        appendPositive(
            BermsFormat.jumpSize(day.maximumJumpLengthMeters),
            label: "Longest jump",
            when: day.maximumJumpLengthMeters,
            to: &metrics)
        return metrics
    }

    static func jumpDetailMetrics(day: RideDay, base: SessionDetailBase?) -> [DaySummaryMetric] {
        let jumpCount = base?.jumpCount ?? day.jumpCount
        guard jumpCount > 0 else { return [] }

        var metrics = [DaySummaryMetric(label: "Total jumps", value: "\(jumpCount)")]
        let longestLength =
            base?.longestJumpLengthMeters ?? (day.maximumJumpLengthMeters > 0 ? day.maximumJumpLengthMeters : nil)
        let highestAir =
            base?.highestJumpMeters ?? (day.maximumJumpHeightMeters > 0 ? day.maximumJumpHeightMeters : nil)
        let totalAirtime = base?.totalJumpAirtime ?? day.totalJumpAirtime
        let totalDistance = base?.totalJumpDistanceMeters ?? day.totalJumpDistanceMeters

        appendPositive(
            BermsFormat.jumpSize(longestLength),
            label: "Longest jump",
            when: longestLength ?? 0,
            to: &metrics)
        appendPositive(
            BermsFormat.jumpSize(highestAir),
            label: "Highest air",
            when: highestAir ?? 0,
            to: &metrics)
        appendPositive(
            BermsFormat.duration(totalAirtime),
            label: "Total airtime",
            when: totalAirtime,
            to: &metrics)
        appendPositive(
            BermsFormat.airtime(day.longestJumpAirtime),
            label: "Longest airtime",
            when: day.longestJumpAirtime,
            to: &metrics)
        appendPositive(
            BermsFormat.distance(totalDistance),
            label: "Total jump distance",
            when: totalDistance,
            to: &metrics)
        return metrics
    }

    static func showsTimeBreakdown(day: RideDay, breakdown: DayTimeBreakdown) -> Bool {
        breakdown.total > 0 && (!day.segments.isEmpty || breakdown.paused > 0)
    }

    private static func appendPositive(
        _ value: String,
        label: String,
        when quantity: Double,
        to metrics: inout [DaySummaryMetric]
    ) {
        guard quantity > 0 else { return }
        metrics.append(DaySummaryMetric(label: label, value: value))
    }
}
