import SwiftUI

struct WatchDashboardView: View {
    @ObservedObject var model: WatchDashboardModel
    @State private var page = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            TabView(selection: $page) {
                ridePage
                    .tag(0)
                healthPage
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .background(Color.black.ignoresSafeArea())
        }
    }

    private var ridePage: some View {
        pageContent {
            if model.state.status == .idle {
                idleContent
            } else {
                metricRow(label: "Descent", value: feetText(model.state.descentMeters), unit: "ft",
                          symbol: "arrow.down", color: .green)
                metricRow(label: "Distance", value: distanceText(model.state.distanceMeters), unit: "mi",
                          symbol: "arrow.right", color: .cyan)
                metricRow(label: "Speed", value: speedText, unit: "mph",
                          symbol: "figure.outdoor.cycle", color: .blue)
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
            Text(model.isStale ? "Phone disconnected" : "Elapsed " + elapsedText)
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
        let total = max(0, Int(model.state.elapsedSeconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var speedText: String {
        String(format: "%.1f", model.state.speedMetersPerSecond * 2.23694)
    }

    private var heartRateText: String {
        guard let heartRate = model.health.heartRateBeatsPerMinute else { return "—" }
        return String(format: "%.0f", heartRate)
    }

    private var caloriesText: String {
        guard let calories = model.health.activeCalories else { return "—" }
        return String(format: "%.0f", calories)
    }

    private func distanceText(_ meters: Double) -> String {
        String(format: "%.2f", meters * 0.000621371)
    }

    private func feetText(_ meters: Double) -> String {
        String(format: "%.0f", meters * 3.28084)
    }
}
