import MapKit
import SwiftData
import SwiftUI
import UIKit

struct DayRow: View {
    let day: RideDay

    var body: some View {
        AdaptiveStatRow {
            VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(Color.bermsMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(BermsFormat.duration(day.duration))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.bermsTrail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: BermsSpacing.target, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The month header only names the month, so unnamed sessions lead with the
    /// date and keep the start time in the metadata.
    private var title: String {
        day.hasCustomName ? day.displayName : dayLabel
    }

    private var metadata: String {
        let runCount = day.segments.filter { $0.kind == .run }.count
        var parts: [String] = []
        if day.hasCustomName {
            parts.append(dayLabel)
        }
        parts.append(time)
        if runCount > 0 {
            parts.append(runCount == 1 ? "1 run" : "\(runCount) runs")
        }
        if day.distanceMeters > 0 {
            parts.append(BermsFormat.distance(day.distanceMeters))
        }
        return parts.joined(separator: "  ·  ")
    }

    private var dayLabel: String {
        day.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var time: String {
        day.startedAt.formatted(date: .omitted, time: .shortened)
    }
}
