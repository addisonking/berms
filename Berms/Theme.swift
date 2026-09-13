import SwiftUI
import UIKit

/// Shared layout rhythm for production screens.
///
/// Native List/Form margins remain system-owned. These values are used where
/// Berms owns the surrounding layout, so adjacent screens share one rhythm.
enum BermsSpacing {
    static let compact: CGFloat = 8
    static let control: CGFloat = 12
    static let content: CGFloat = 16
    static let section: CGFloat = 24
    static let major: CGFloat = 32
    static let target: CGFloat = 44
}

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
        case .black, .doubleBlack: .primary
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
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// Material circle used for map controls so they stay legible in either appearance.
struct BermsMapControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
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

/// Preserve readable metrics at accessibility sizes without limiting Dynamic Type.
struct AdaptiveStatRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: BermsSpacing.content))
            : AnyLayout(HStackLayout(alignment: .top, spacing: BermsSpacing.content))
        layout { content }
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
