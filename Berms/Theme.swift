import SwiftUI
import UIKit

extension Color {
    // Resolve against the current appearance, including sheets and system controls.
    static let bermsInk = Color(uiColor: .systemGroupedBackground)
    static let bermsCard = Color(uiColor: .secondarySystemGroupedBackground)
    static let bermsTrail = Color(uiColor: .label)
    static let bermsLift = Color(uiColor: .secondaryLabel)
    static let bermsMuted = Color(uiColor: .secondaryLabel)
    static let bermsOnAccent = Color(uiColor: .systemBackground)
    static let bermsInset = Color(uiColor: .tertiarySystemFill)

    static func bermsDifficulty(_ difficulty: TrailDifficulty) -> Color {
        switch difficulty {
        case .green: .green
        case .blue: .blue
        case .black, .doubleBlack: .black
        }
    }

    static func bermsDifficultyAccent(_ difficulty: TrailDifficulty) -> Color? {
        difficulty == .doubleBlack ? .red : nil
    }
}

struct BermsBackground: View {
    var body: some View {
        Color.bermsInk
        .ignoresSafeArea()
    }
}

struct SummaryStat: View {
    var animatesValue = false
    var numericValue = false
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .bermsValueMotion(value, numeric: numericValue, enabled: animatesValue)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetricTile: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.bermsMuted)
                .tracking(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.bermsCard, in: RoundedRectangle(cornerRadius: 16))
    }
}

// Keep motion local to the control or state that changed.
enum BermsMotion {
    static let press = Animation.easeOut(duration: 0.12)
    static let content = Animation.easeOut(duration: 0.18)
    static let recenter = Animation.easeInOut(duration: 0.25)

    @MainActor
    static func recordingFeedback() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

struct BermsPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : BermsMotion.press, value: configuration.isPressed)
    }
}

private struct BermsValueMotion: ViewModifier {
    let value: String
    let numeric: Bool
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if enabled {
            content
            .contentTransition(reduceMotion ? .identity : (numeric ? .numericText() : .opacity))
            .animation(reduceMotion ? nil : BermsMotion.content, value: value)
        } else {
            content
        }
    }
}

extension View {
    func bermsValueMotion(_ value: String, numeric: Bool = false, enabled: Bool = true) -> some View {
        modifier(BermsValueMotion(value: value, numeric: numeric, enabled: enabled))
    }
}
