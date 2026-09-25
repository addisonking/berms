import SwiftData
import SwiftUI

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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AdaptiveStatRow {
                        SummaryStat(
                            label: "Descent",
                            value: BermsFormat.elevation(day.descentMeters), emphasis: true)
                        SummaryStat(
                            label: "Distance",
                            value: BermsFormat.distance(day.distanceMeters), emphasis: true)
                    }
                } header: {
                    Text(day.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                } footer: {
                    Text(timeRangeLine)
                }
                Section("Day") {
                    AdaptiveStatRow {
                        SummaryStat(label: "Runs", value: "\(runs.count)")
                        SummaryStat(
                            label: "Top speed", value: BermsFormat.speed(day.maximumSpeedMetersPerSecond))
                    }
                    AdaptiveStatRow {
                        SummaryStat(label: "Lifts", value: "\(lifts.count)")
                        SummaryStat(label: "Lift vertical", value: BermsFormat.elevation(day.liftMeters))
                    }
                }
                Section("Time") {
                    DayTimeBreakdownView(
                        breakdown: breakdown,
                        ridingTitle: day.activityMode.activeTimeTitle)
                }
                if day.jumpCount > 0 {
                    Section("Jumps") {
                        AdaptiveStatRow {
                            SummaryStat(label: "Jumps", value: "\(day.jumpCount)")
                            SummaryStat(
                                label: "Longest airtime",
                                value: BermsFormat.airtime(day.longestJumpAirtime))
                        }
                        AdaptiveStatRow {
                            SummaryStat(
                                label: "Longest jump",
                                value: BermsFormat.jumpSize(day.maximumJumpLengthMeters))
                            SummaryStat(
                                label: "Highest air",
                                value: BermsFormat.jumpSize(day.maximumJumpHeightMeters))
                        }
                    }
                }
                Section {
                    Button {
                        dismiss()
                        onShare()
                    } label: {
                        Label("Share image", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
