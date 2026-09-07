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
                        metric("Descent", elevation(context.state.descentMeters))
                        Spacer()
                        Button(intent: ToggleBermsPauseIntent()) {
                            Image(systemName: context.state.isPaused ? "play.fill" : "pause.fill")
                        }
                        .accessibilityLabel(context.state.isPaused ? "Resume ride" : "Pause ride")
                    }
                }
            } compactLeading: {
                Image(systemName: "mountain.2.fill")
            } compactTrailing: {
                Text("\(context.state.runCount)")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "mountain.2.fill")
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
                Text(context.state.isPaused ? "Paused" : context.state.phase.capitalized)
                    .font(.subheadline.weight(.semibold))
            }
            HStack {
                metric("Time", duration(context.state.elapsedSeconds))
                Spacer()
                metric("Runs", "\(context.state.runCount)")
                Spacer()
                metric("Descent", elevation(context.state.descentMeters))
                Button(intent: ToggleBermsPauseIntent()) {
                    Image(systemName: context.state.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(context.state.isPaused ? "Resume ride" : "Pause ride")
            }
        }
        .padding(16)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func elevation(_ meters: Double) -> String {
        Locale.current.measurementSystem == .metric
            ? String(format: "%.0f m", meters)
            : String(format: "%.0f ft", meters * 3.28084)
    }
}

@main
struct BermsLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        BermsLiveActivity()
    }
}
