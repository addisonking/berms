import SwiftUI
import WatchKit

struct WatchDashboardView: View {
    @ObservedObject var model: WatchDashboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 1
    @State private var showsFinishConfirmation = false
    @State private var showsCommandError = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: model.state.isActive ? 1 : 60)) { _ in
            content
        }
        .onChange(of: model.message) { _, message in
            if message != nil { showsCommandError = true }
        }
        .alert("Finish ride?", isPresented: $showsFinishConfirmation) {
            Button("Finish ride", role: .destructive, action: model.finishRide)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your ride will be saved on iPhone.")
        }
    }

    private var content: some View {
        GeometryReader { geometry in
            TabView(selection: $page) {
                controlsPage
                    .frame(height: geometry.size.height)
                    .tag(0)
                statsPage
                    .frame(height: geometry.size.height)
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .background(Color.black.ignoresSafeArea())
            .onChange(of: model.state.isActive) { _, _ in
                page = 1
            }
        }
    }

    private var statsPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.state.isActive {
                Label(runTitle, systemImage: "figure.outdoor.cycle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    metricRow(
                        "Top speed", symbol: "speedometer",
                        value: speedText, unit: speedUnit)
                    metricRow(
                        "Best jump airtime", symbol: "arrow.up.forward",
                        value: airtimeText, unit: "s air")
                    metricRow(
                        "Heart rate", symbol: "heart.fill",
                        value: heartRateText, unit: "bpm")
                }
                if model.isStale || model.state.status == .paused {
                    Text(model.isStale ? "Phone disconnected" : "Paused")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                idleContent
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var controlsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.state.isActive {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.isStale ? "Disconnected" : model.state.status == .paused ? "Paused" : "Berms")
                        .font(.footnote)
                        .contentTransition(.interpolate)
                    Spacer(minLength: 8)
                    Image(systemName: "iphone")
                        .font(.caption2)
                        .accessibilityLabel(connectionText)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            showsFinishConfirmation = true
                        } label: {
                            Label("Finish", systemImage: "flag.checkered")
                                .fixedSize()
                                .frame(maxWidth: .infinity)
                        }
                        .buttonBorderShape(.capsule)
                        .disabled(!model.canTogglePause)

                        Button {
                            WKInterfaceDevice.current().enableWaterLock()
                        } label: {
                            Image(systemName: "lock.fill")
                        }
                        .buttonBorderShape(.circle)
                        .frame(width: 44)
                        .disabled(!canLock)
                        .accessibilityLabel("Water Lock")
                        .accessibilityHint("Locks the screen against accidental touches")
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.white)
                    .fixedSize(horizontal: false, vertical: true)

                    pauseButton
                }
                .fixedSize(horizontal: false, vertical: true)

            } else {
                idleContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(controlAnimation, value: model.state.status)
        .animation(controlAnimation, value: model.isStale)
        .alert("Couldn’t update ride", isPresented: $showsCommandError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "Try again when iPhone is connected.")
        }
    }

    private func metricRow(_ label: String, symbol: String, value: String, unit: String) -> some View {
        GridRow {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: value)
                .fixedSize()
                .frame(minHeight: 28)
                .gridColumnAlignment(.trailing)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)")
    }

    private var pauseButton: some View {
        Button(action: model.togglePause) {
            Label {
                Text(model.actionTitle)
                    .contentTransition(.interpolate)
            } icon: {
                Image(systemName: model.state.status == .paused ? "play.fill" : "pause.fill")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.magic(fallback: .replace)))
                    .frame(width: 20)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .tint(.white)
        .disabled(!model.canTogglePause)
        .accessibilityHint(model.isStale ? "Waiting for the iPhone connection" : "Changes the ride on iPhone")
    }

    private var idleContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.outdoor.cycle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Start on iPhone")
                .font(.headline)
            Text("Run stats appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controlAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.3)
    }

    private var canLock: Bool {
        model.state.status == .recording && !model.isStale
            && model.health.availability == .available && !model.isDemo
    }

    private var connectionText: String {
        model.isStale ? "Phone disconnected" : "iPhone connected"
    }

    private var runTitle: String {
        guard let run = model.state.run else { return "Waiting for a run" }
        return model.state.phase == "run" ? "Run \(run.number)" : "Last run \(run.number)"
    }

    private let speedUnit = "mph"

    private var speedText: String {
        guard let run = model.state.run else { return "—" }
        let value = run.topSpeedMetersPerSecond * 2.23694
        return String(format: "%.1f", value)
    }

    private var airtimeText: String {
        guard let seconds = model.state.run?.longestJumpAirtime, seconds > 0 else { return "—" }
        return String(format: "%.2f", seconds)
    }

    private var heartRateText: String {
        guard let heartRate = model.health.heartRateBeatsPerMinute else { return "—" }
        return String(format: "%.0f", heartRate)
    }
}
