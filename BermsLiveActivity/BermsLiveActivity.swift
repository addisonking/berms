import ActivityKit
import SwiftUI
import WidgetKit

struct BermsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BermsActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color(uiColor: .systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Berms", systemImage: "mountain.2.fill")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Run \(context.state.runCount)")
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.isPaused ? "Paused" : context.state.phase.capitalized)
                        .font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        metric("Time", duration(context.state.elapsedSeconds))
                        Spacer()
                        detailMetric(context)
                        Spacer()
                        Button(intent: ToggleBermsPauseIntent()) {
                            Image(systemName: context.state.isPaused ? "play.fill" : "pause.fill")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(context.state.isPaused ? "Resume ride" : "Pause ride")
                    }
                }
            } compactLeading: {
                Image(systemName: "mountain.2.fill")
                    .accessibilityHidden(true)
            } compactTrailing: {
                Text("\(context.state.runCount)")
                    .monospacedDigit()
                    .accessibilityLabel("\(context.state.runCount) runs")
            } minimal: {
                Image(systemName: "mountain.2.fill")
                    .accessibilityLabel("Berms ride")
            }
            .widgetURL(URL(string: "berms://track"))
        }
    }

    private func lockScreenView(context: ActivityViewContext<BermsActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Berms", systemImage: "mountain.2.fill")
                    .font(.headline)
                Spacer()
                Text(statusText(context))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(context.isStale ? .secondary : .primary)
            }
            HStack(spacing: 8) {
                timeMetric(context)
                    .frame(maxWidth: .infinity, alignment: .leading)
                metric("Runs", "\(context.state.runCount)")
                    .frame(maxWidth: .infinity, alignment: .center)
                HStack(spacing: 8) {
                    metric(context.state.metric.title, detailValue(context))
                    pauseButton(context)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
        .opacity(context.isStale ? 0.7 : 1)
        .widgetURL(URL(string: "berms://track"))
    }

    private func statusText(_ context: ActivityViewContext<BermsActivityAttributes>) -> String {
        if context.isStale { return "Not updating" }
        return context.state.isPaused ? "Paused" : context.state.phase.capitalized
    }

    @ViewBuilder
    private func timeMetric(_ context: ActivityViewContext<BermsActivityAttributes>) -> some View {
        if context.state.isPaused || context.isStale {
            metric("Time", duration(context.state.elapsedSeconds))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.startedAt, style: .timer)
                    .font(.headline.monospacedDigit())
                Text("Time")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func pauseButton(_ context: ActivityViewContext<BermsActivityAttributes>) -> some View {
        Button(intent: ToggleBermsPauseIntent()) {
            Image(systemName: context.state.isPaused ? "play.fill" : "pause.fill")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(context.state.isPaused ? "Resume ride" : "Pause ride")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func detailMetric(_ context: ActivityViewContext<BermsActivityAttributes>) -> some View {
        metric(context.state.metric.title, detailValue(context))
    }

    private func detailValue(_ context: ActivityViewContext<BermsActivityAttributes>) -> String {
        let state = context.state
        switch state.metric {
        case .descent: return elevation(state.descentMeters)
        case .jumps: return "\(state.jumpCount)"
        case .distance: return distance(state.distanceMeters)
        case .topSpeed: return speed(state.topSpeedMetersPerSecond)
        case .lifts: return "\(state.liftCount)"
        case .longestAirtime: return airtime(state.longestAirtime)
        case .totalAirtime: return airtime(state.totalAirtime)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    private func elevation(_ meters: Double) -> String {
        isMetric
            ? String(format: "%.0f m", meters)
            : String(format: "%.0f ft", meters * 3.28084)
    }

    private func distance(_ meters: Double) -> String {
        if isMetric {
            return meters >= 1000
                ? String(format: "%.1f km", meters / 1000)
                : String(format: "%.0f m", meters)
        }
        let miles = meters / 1609.344
        return miles >= 0.1
            ? String(format: "%.1f mi", miles)
            : String(format: "%.0f ft", meters * 3.28084)
    }

    private func speed(_ metersPerSecond: Double) -> String {
        let value = isMetric ? metersPerSecond * 3.6 : metersPerSecond * 2.23694
        return String(format: "%.0f %@", value, isMetric ? "km/h" : "mph")
    }

    private func airtime(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", max(0, seconds))
    }

    private var isMetric: Bool { Locale.current.measurementSystem == .metric }
}

@main
struct BermsLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        BermsLiveActivity()
    }
}
