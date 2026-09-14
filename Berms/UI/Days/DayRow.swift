import MapKit
import SwiftData
import SwiftUI
import UIKit

struct DayRow: View {
    let day: RideDay

    var body: some View {
        AdaptiveStatRow {
            VStack(alignment: .leading, spacing: 5) {
                Text(day.displayName)
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

    private var metadata: String {
        let stats = "\(day.segments.filter { $0.kind == .run }.count) runs  ·  \(BermsFormat.distance(day.distanceMeters))"
        guard day.hasCustomName else { return stats }
        return "\(day.startedAt.formatted(date: .abbreviated, time: .shortened))  ·  \(stats)"
    }
}
