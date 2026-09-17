import MapKit
import SwiftData
import SwiftUI
import UIKit

struct DayRow: View {
    let day: RideDay

    var body: some View {
        AdaptiveStatRow {
            HStack(alignment: .top, spacing: BermsSpacing.control) {
                Image(systemName: day.activityMode.systemImage)
                    .font(.headline)
                    .foregroundStyle(Color.bermsMuted)
                    .frame(width: BermsSpacing.target, height: BermsSpacing.target)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundStyle(Color.bermsMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(BermsFormat.duration(day.duration))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.bermsTrail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: BermsSpacing.target, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.activityMode.title) day, \(title)")
        .accessibilityValue("\(metadata), \(BermsFormat.duration(day.duration))")
    }

    /// The month header only names the month, so unnamed sessions lead with the
    /// date and keep the start time in the metadata.
    private var title: String {
        day.hasCustomName ? day.displayName : dayLabel
    }

    private var metadata: String {
        let runCount = day.segments.filter { $0.kind == .run }.count
        let runLabel = runCount == 1 ? "1 run" : "\(runCount) runs"
        let stats = "\(runLabel)  ·  \(BermsFormat.distance(day.distanceMeters))"
        guard day.hasCustomName else { return "\(time)  ·  \(stats)" }
        return "\(dayLabel)  ·  \(time)  ·  \(stats)"
    }

    private var dayLabel: String {
        day.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var time: String {
        day.startedAt.formatted(date: .omitted, time: .shortened)
    }
}
