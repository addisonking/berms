import SwiftUI
import UIKit

/// Shared layout rhythm for production screens.
///
/// Native List/Form margins remain system-owned. These values are used where
/// Berms owns the surrounding layout, so adjacent screens share one rhythm.
enum BermsSpacing {
    static let tight: CGFloat = 4
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
    static let bermsJump = Color.orange
    static let bermsOnJump = Color.black
    /// Keep switches monochrome in light mode. The dark appearance needs a
    /// saturated track because the root `.label` tint makes both parts white.
    static let bermsSwitch = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemGreen : .black
        })

    static func bermsDifficulty(_ difficulty: TrailDifficulty) -> Color {
        switch difficulty {
        case .green: .green
        case .blue: .blue
        case .black, .doubleBlack: .primary
        case .unrated: .secondary
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
    var emphasis = false

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.tight) {
            Text(value)
                .bermsValueMotion(value, numeric: numericValue, enabled: animatesValue)
                .font(emphasis ? .title.weight(.semibold) : .title3.weight(.semibold))
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

/// Consistently sized hit targets for map controls.
extension View {
    func bermsMapControl() -> some View {
        buttonStyle(.plain)
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
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: BermsSpacing.content))
            : AnyLayout(HStackLayout(alignment: .top, spacing: BermsSpacing.content))
        layout { content }
    }
}

/// Wall-clock split of a day: one proportional bar plus labeled rows.
struct DayTimeBreakdownView: View {
    let breakdown: DayTimeBreakdown
    let ridingTitle: String

    private enum Part: String, Identifiable {
        case riding
        case lifts
        case downtime

        var id: String { rawValue }

        var title: String {
            switch self {
            case .riding: "Riding"
            case .lifts: "Lifts"
            case .downtime: "Downtime"
            }
        }

        var style: AnyShapeStyle {
            switch self {
            case .riding: AnyShapeStyle(.primary)
            case .lifts: AnyShapeStyle(.secondary)
            case .downtime: AnyShapeStyle(.tertiary)
            }
        }
    }

    private var slices: [(part: Part, seconds: TimeInterval)] {
        let all: [(Part, TimeInterval)] = [
            (.riding, breakdown.riding),
            (.lifts, breakdown.lifts),
            (.downtime, breakdown.stopped + breakdown.paused),
        ]
        return all.filter { $0.1 > 0 }.map { (part: $0.0, seconds: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.control) {
            if breakdown.total > 0 {
                bar
            }
            ForEach(slices, id: \.part.id) { slice in
                LabeledContent(title(for: slice.part), value: value(for: slice.seconds))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var bar: some View {
        GeometryReader { proxy in
            let spacing = 2 * Double(max(0, slices.count - 1))
            let available = max(0, proxy.size.width - spacing)
            HStack(spacing: 2) {
                ForEach(slices, id: \.part.id) { slice in
                    Capsule()
                        .fill(slice.part.style)
                        .frame(width: max(2, available * slice.seconds / breakdown.total))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func title(for part: Part) -> String {
        part == .riding ? ridingTitle : part.title
    }

    private func value(for seconds: TimeInterval) -> String {
        let share = Int((seconds / breakdown.total * 100).rounded())
        return "\(BermsFormat.duration(seconds)) · \(share)%"
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
