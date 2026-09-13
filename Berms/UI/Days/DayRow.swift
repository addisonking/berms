import MapKit
import SwiftData
import SwiftUI
import UIKit

struct DayRow: View {
    let day: RideDay

    var body: some View {
        HStack(spacing: BermsSpacing.control) {
            VStack(alignment: .leading, spacing: 5) {
                Text(day.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(Color.bermsMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(BermsFormat.duration(day.duration))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.bermsTrail)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, minHeight: BermsSpacing.target, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var metadata: String {
        let stats = "\(day.segments.filter { $0.kind == .run }.count) runs  ·  \(BermsFormat.distance(day.distanceMeters))"
        guard day.hasCustomName else { return stats }
        return "\(day.startedAt.formatted(date: .abbreviated, time: .shortened))  ·  \(stats)"
    }
}
