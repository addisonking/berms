import MapKit
import SwiftData
import SwiftUI
import UIKit

enum BermsFormat {
    private static var isMetric: Bool { Locale.current.measurementSystem == .metric }

    static func duration(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func speed(_ metersPerSecond: Double) -> String {
        let value = isMetric ? metersPerSecond * 3.6 : metersPerSecond * 2.23694
        return String(format: "%.0f %@", value, isMetric ? "km/h" : "mph")
    }

    static func distance(_ meters: Double) -> String {
        if isMetric {
            return meters >= 1000 ? String(format: "%.1f km", meters / 1000) : String(format: "%.0f m", meters)
        }
        let miles = meters / 1609.344
        return miles >= 0.1 ? String(format: "%.1f mi", miles) : String(format: "%.0f ft", meters * 3.28084)
    }

    static func airtime(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", max(0, seconds))
    }

    static func gpsPoints(_ count: Int) -> String {
        "\(count) GPS point\(count == 1 ? "" : "s")"
    }

    static func elevation(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return elevation(meters)
    }

    static func elevation(_ meters: Double) -> String {
        isMetric ? String(format: "%.0f m", meters) : String(format: "%.0f ft", meters * 3.28084)
    }
}
