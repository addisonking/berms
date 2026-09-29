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

    static func recapHighlights(day: RideDay) -> [DaySummaryMetric] {
        var metrics: [DaySummaryMetric] = []
        appendPositive(
            BermsFormat.elevation(day.descentMeters), label: "Descent", when: day.descentMeters, to: &metrics)
        appendPositive(
            BermsFormat.distance(day.distanceMeters), label: "Distance", when: day.distanceMeters, to: &metrics)
        if metrics.isEmpty, day.duration > 0 {
            metrics.append(DaySummaryMetric(label: "Time", value: BermsFormat.duration(day.duration)))
        }
        return metrics
    }

    static func recapDayMetrics(day: RideDay, runCount: Int, liftCount: Int) -> [DaySummaryMetric] {
        guard runCount > 0 || liftCount > 0 else { return [] }
        var metrics = [DaySummaryMetric(label: "Runs", value: "\(runCount)")]
        appendPositive(
            BermsFormat.speed(day.maximumSpeedMetersPerSecond),
            label: "Top speed",
            when: day.maximumSpeedMetersPerSecond,
            to: &metrics)
        if liftCount > 0 {
            metrics.append(DaySummaryMetric(label: "Lifts", value: "\(liftCount)"))
            appendPositive(
                BermsFormat.elevation(day.liftMeters),
                label: "Lift vertical",
                when: day.liftMeters,
                to: &metrics)
        }
        return metrics
    }

    static func recapJumpMetrics(day: RideDay) -> [DaySummaryMetric] {
        guard day.jumpCount > 0 else { return [] }
        var metrics = [DaySummaryMetric(label: "Jumps", value: "\(day.jumpCount)")]
        appendPositive(
            BermsFormat.airtime(day.longestJumpAirtime),
            label: "Longest airtime",
            when: day.longestJumpAirtime,
            to: &metrics)
        appendPositive(
            BermsFormat.jumpSize(day.maximumJumpLengthMeters),
            label: "Longest jump",
            when: day.maximumJumpLengthMeters,
            to: &metrics)
        appendPositive(
            BermsFormat.jumpSize(day.maximumJumpHeightMeters),
            label: "Highest air",
            when: day.maximumJumpHeightMeters,
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

/// The first thing a rider sees after finishing: the shape of the day at a
/// glance, with the share card one tap away.
struct DayRecapSheet: View {
    let day: RideDay
    let runs: [RideSegment]
    let lifts: [RideSegment]
    var onShare: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private var breakdown: DayTimeBreakdown {
        DayTimeBreakdown(day: day)
    }

    private var headlineMetrics: [DaySummaryMetric] {
        DaySummaryPresentation.recapHighlights(day: day)
    }

    private var dayMetrics: [DaySummaryMetric] {
        DaySummaryPresentation.recapDayMetrics(day: day, runCount: runs.count, liftCount: lifts.count)
    }

    private var jumpMetrics: [DaySummaryMetric] {
        DaySummaryPresentation.recapJumpMetrics(day: day)
    }

    var body: some View {
        NavigationStack {
            List {
                if !headlineMetrics.isEmpty {
                    Section {
                        ForEach(DaySummaryPresentation.rows(of: headlineMetrics), id: \.self) { row in
                            AdaptiveStatRow {
                                ForEach(row) { metric in
                                    SummaryStat(label: metric.label, value: metric.value, emphasis: true)
                                }
                            }
                        }
                    } header: {
                        Text(day.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    } footer: {
                        Text(timeRangeLine)
                    }
                }
                if !dayMetrics.isEmpty {
                    Section("Day") {
                        ForEach(DaySummaryPresentation.rows(of: dayMetrics), id: \.self) { row in
                            AdaptiveStatRow {
                                ForEach(row) { metric in
                                    SummaryStat(label: metric.label, value: metric.value)
                                }
                            }
                        }
                    }
                }
                if DaySummaryPresentation.showsTimeBreakdown(day: day, breakdown: breakdown) {
                    Section("Time") {
                        DayTimeBreakdownView(
                            breakdown: breakdown,
                            ridingTitle: "Riding time")
                    }
                }
                if !jumpMetrics.isEmpty {
                    Section("Jumps") {
                        ForEach(DaySummaryPresentation.rows(of: jumpMetrics), id: \.self) { row in
                            AdaptiveStatRow {
                                ForEach(row) { metric in
                                    SummaryStat(label: metric.label, value: metric.value)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        dismiss()
                        onShare()
                    } label: {
                        Label("Share image", systemImage: "square.and.arrow.up")
                            .foregroundStyle(Color.bermsOnAccent)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.bermsTrail)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Day recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var timeRangeLine: String {
        let start = day.startedAt.formatted(date: .omitted, time: .shortened)
        guard let endedAt = day.endedAt else { return "Started \(start)" }
        let end = endedAt.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}
