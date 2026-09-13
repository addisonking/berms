import SwiftUI

struct WatchDashboardView: View {
    @ObservedObject var model: WatchDashboardModel
    @State private var page = 0

    var body: some View {
        Group {
            if model.state.status == .recording, !model.isStale {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    content
                }
            } else {
                content
            }
        }
    }

    private var content: some View {
        TabView(selection: $page) {
            ridePage
                .tag(0)
            healthPage
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .background(Color.black.ignoresSafeArea())
    }

    private var ridePage: some View {
        pageContent {
            if model.state.status == .idle {
                idleContent
            } else {
                metricRow(label: "Descent", value: elevationValue(model.state.descentMeters),
                          unit: elevationUnit, symbol: "arrow.down", color: .green)
                metricRow(label: "Distance", value: distanceValue(model.state.distanceMeters),
                          unit: distanceUnit, symbol: "arrow.right", color: .cyan)
                metricRow(label: "Speed", value: speedValue(model.state.speedMetersPerSecond),
                          unit: speedUnit, symbol: "figure.outdoor.cycle", color: .blue)
                pauseButton
            }
        }
    }

    private var healthPage: some View {
        pageContent {
            if model.state.status == .idle {
                Text("Live heart rate and active calories appear during a ride.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                metricRow(label: "Heart rate", value: heartRateText, unit: "bpm",
                          symbol: "heart.fill", color: .red)
                metricRow(label: "Active energy", value: caloriesText, unit: "kcal",
                          symbol: "flame.fill", color: .yellow)
                if model.health.availability != .available {
                    Text(model.health.availability == .waiting ? "Waiting for health data" : "Health data unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pageContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            content()
            if let message = model.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(headerStatusText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
            }
            Text(headerSubtitle)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(model.isStale ? .orange : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ride status")
        .accessibilityValue("\(headerStatusText), \(elapsedText)" + (model.isStale ? ", phone disconnected" : ""))
    }

    private func metricRow(label: String, value: String, unit: String,
                           symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(minWidth: 27, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)")
        .frame(minHeight: 32)
    }

    private var pauseButton: some View {
        Button(action: model.togglePause) {
            Label(model.actionTitle, systemImage: model.state.status == .paused ? "play.fill" : "pause.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.state.status == .paused ? .green : .orange)
        .disabled(!model.canTogglePause)
        .accessibilityHint(model.isStale ? "Waiting for the iPhone connection" : "Changes the ride on iPhone")
    }

    private var idleContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Start a ride on iPhone")
                .font(.headline)
            Text("Live stats appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private var headerStatusText: String {
        switch model.state.status {
        case .idle: "IDLE"
        case .recording: model.state.phase == "idle" ? "WAITING" : model.state.phase.uppercased()
        case .paused: "PAUSED"
        }
    }

    private var elapsedText: String {
        let total = max(0, Int(liveElapsedSeconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    private var liveElapsedSeconds: TimeInterval {
        let base = model.state.elapsedSeconds
        guard model.state.status == .recording, !model.isStale else { return base }
        return base + max(0, Date.now.timeIntervalSince(model.state.updatedAt))
    }

    private var headerSubtitle: String {
        guard model.state.isActive else { return "Start a ride on iPhone" }
        return model.isStale ? "Phone disconnected" : "Elapsed " + elapsedText
    }

    private var usesMetric: Bool {
        Locale.current.measurementSystem == .metric
    }

    private var speedUnit: String { usesMetric ? "km/h" : "mph" }

    private var distanceUnit: String { usesMetric ? "km" : "mi" }

    private var elevationUnit: String { usesMetric ? "m" : "ft" }

    private func speedValue(_ metersPerSecond: Double) -> String {
        let value = usesMetric ? metersPerSecond * 3.6 : metersPerSecond * 2.23694
        return String(format: "%.1f", value)
    }

    private func distanceValue(_ meters: Double) -> String {
        let value = usesMetric ? meters / 1_000 : meters * 0.000621371
        return String(format: "%.2f", value)
    }

    private func elevationValue(_ meters: Double) -> String {
        let value = usesMetric ? meters : meters * 3.28084
        return String(format: "%.0f", value)
    }

    private var heartRateText: String {
        guard let heartRate = model.health.heartRateBeatsPerMinute else { return "—" }
        return String(format: "%.0f", heartRate)
    }

    private var caloriesText: String {
        guard let calories = model.health.activeCalories else { return "—" }
        return String(format: "%.0f", calories)
    }
}
