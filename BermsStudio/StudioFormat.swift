import Foundation

enum StudioFormat {
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        return formatter
    }()

    static func clock(_ date: Date?) -> String {
        guard let date else { return "no timestamp" }
        return clockFormatter.string(from: date)
    }

    static func clockRange(_ start: Date, _ end: Date) -> String {
        "\(clock(start))–\(clock(end))"
    }

    static func dayLabel(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func distance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : String(format: "%.0f m", meters)
    }

    static func vertical(_ meters: Double) -> String {
        String(format: "%.0f m", meters)
    }

    static func speed(_ metersPerSecond: Double) -> String {
        String(format: "%.0f km/h", metersPerSecond * 3.6)
    }

    static func offset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds)
        return String(format: "%@%d:%02d", sign, total / 60, total % 60)
    }
}
