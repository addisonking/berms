import MapKit
import SwiftData
import SwiftUI
import UIKit

extension MapStyle {
    // Keep the system basemap subdued so route and trail overlays stay legible.
    static var bermsMonochrome: MapStyle {
        .standard(
            elevation: .flat,
            emphasis: .muted,
            pointsOfInterest: .excludingAll,
            showsTraffic: false)
    }
}

struct TrailMapOverlay: Identifiable {
    let id: String
    let trailID: UUID
    let name: String
    let difficulty: TrailDifficulty
    let points: [RoutePoint]
    let score: Double

    var color: Color {
        .bermsDifficulty(difficulty)
    }

    var coordinates: [CLLocationCoordinate2D] {
        points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }
}

extension TrailMapOverlay {
    init(detail: SessionDetailTrailOverlay) {
        self.init(
            id: detail.id,
            trailID: detail.trailID,
            name: detail.name,
            difficulty: detail.difficulty,
            points: detail.points,
            score: detail.score)
    }
}

func trailCoordinates(for trail: Trail) -> [CLLocationCoordinate2D] {
    trailCoordinates(for: trail.points)
}

func trailCoordinates(for points: [RoutePoint]) -> [CLLocationCoordinate2D] {
    points.map {
        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
    }
}

enum TrailMapRendering {
    static let lineWidth: CGFloat = 2.25
    static let accentLineWidth: CGFloat = 1.1
    static let doubleBlackDash: [CGFloat] = [7, 5]
    /// Dots, so an unrated trail never borrows the double black dash.
    static let unratedDash: [CGFloat] = [2, 4]
    static let accentDash: [CGFloat] = [3, 5]
}

func trailMapDash(for difficulty: TrailDifficulty) -> [CGFloat] {
    switch difficulty {
    case .doubleBlack: TrailMapRendering.doubleBlackDash
    case .unrated: TrailMapRendering.unratedDash
    default: []
    }
}

func trailMapStrokeStyle(
    for difficulty: TrailDifficulty,
    lineWidth: CGFloat = TrailMapRendering.lineWidth
) -> StrokeStyle {
    StrokeStyle(
        lineWidth: lineWidth,
        lineCap: .round,
        lineJoin: .round,
        dash: trailMapDash(for: difficulty))
}

func trailMapAccentStrokeStyle(lineWidth: CGFloat = TrailMapRendering.accentLineWidth) -> StrokeStyle {
    StrokeStyle(
        lineWidth: lineWidth,
        lineCap: .round,
        lineJoin: .round,
        dash: TrailMapRendering.accentDash)
}

func trailLabelCoordinate(for points: [RoutePoint]) -> CLLocationCoordinate2D? {
    guard !points.isEmpty else { return nil }
    let point = points[points.count / 2]
    return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
}

/// True when a trail box overlaps the visible region. Used to keep a
/// several-hundred-trail catalog from building off-screen overlays.
func trailBoundsIntersect(_ bounds: GeoBounds, region: MKCoordinateRegion) -> Bool {
    bounds.intersects(
        centerLatitude: region.center.latitude,
        centerLongitude: region.center.longitude,
        latitudeSpan: region.span.latitudeDelta,
        longitudeSpan: region.span.longitudeDelta)
}

func regionSpanMeters(_ region: MKCoordinateRegion) -> Double {
    max(
        region.span.latitudeDelta * 111_000,
        region.span.longitudeDelta * 111_000 * cos(region.center.latitude * .pi / 180)
    )
}

struct TrailMapLabelItem: Identifiable {
    let id: String
    let name: String
    let difficulty: TrailDifficulty
    let color: Color
    let coordinate: CLLocationCoordinate2D
}

/// One label per trail name so repeated runs of the same trail do not stack
/// pills. The longest matched slice represents the trail.
func trailMapLabelItems(
    for overlays: [TrailMapOverlay],
    limit: Int = 12
) -> [TrailMapLabelItem] {
    var order: [String] = []
    var representatives: [String: TrailMapOverlay] = [:]
    for overlay in overlays {
        let key = overlay.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { continue }
        if let current = representatives[key] {
            if overlay.points.count > current.points.count {
                representatives[key] = overlay
            }
        } else {
            representatives[key] = overlay
            order.append(key)
        }
    }
    return order.prefix(limit).compactMap { key in
        guard let overlay = representatives[key],
            let coordinate = trailLabelCoordinate(for: overlay.points)
        else { return nil }
        return TrailMapLabelItem(
            id: key,
            name: overlay.name,
            difficulty: overlay.difficulty,
            color: overlay.color,
            coordinate: coordinate)
    }
}

@MainActor
@MapContentBuilder
func trailMapContent(
    coordinates: [CLLocationCoordinate2D],
    difficulty: TrailDifficulty,
    color: Color? = nil,
    lineWidth: CGFloat = TrailMapRendering.lineWidth,
    tag: UUID? = nil
) -> some MapContent {
    if let tag {
        MapPolyline(coordinates: coordinates)
            .stroke(
                color ?? .bermsDifficulty(difficulty),
                style: trailMapStrokeStyle(for: difficulty, lineWidth: lineWidth)
            )
            .tag(tag)
    } else {
        MapPolyline(coordinates: coordinates)
            .stroke(
                color ?? .bermsDifficulty(difficulty),
                style: trailMapStrokeStyle(for: difficulty, lineWidth: lineWidth))
    }

    if difficulty == .doubleBlack {
        MapPolyline(coordinates: coordinates)
            .stroke(.red, style: trailMapAccentStrokeStyle())
    }
}

func trailDistance(from coordinate: Coordinate, to points: [RoutePoint]) -> Double {
    guard points.count >= 2 else {
        guard let point = points.first else { return .greatestFiniteMagnitude }
        return Coordinate(latitude: point.latitude, longitude: point.longitude).distance(to: coordinate)
    }

    let latitudeScale = max(0.1, cos(coordinate.latitude * .pi / 180))
    func project(_ value: Coordinate) -> (x: Double, y: Double) {
        (
            (value.longitude - coordinate.longitude) * 111_000 * latitudeScale,
            (value.latitude - coordinate.latitude) * 111_000
        )
    }

    let origin = project(coordinate)
    return zip(points, points.dropFirst()).map { start, end in
        let a = project(Coordinate(latitude: start.latitude, longitude: start.longitude))
        let b = project(Coordinate(latitude: end.latitude, longitude: end.longitude))
        let dx = b.x - a.x
        let dy = b.y - a.y
        let denominator = dx * dx + dy * dy
        let fraction =
            denominator > 0
            ? max(0, min(1, ((origin.x - a.x) * dx + (origin.y - a.y) * dy) / denominator))
            : 0
        return hypot(origin.x - (a.x + dx * fraction), origin.y - (a.y + dy * fraction))
    }.min() ?? .greatestFiniteMagnitude
}

struct TrailRatingBadge: View {
    let difficulty: TrailDifficulty
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 2) {
            ratingShape
            if difficulty == .doubleBlack {
                ratingShape
            }
        }
        .frame(width: difficulty == .doubleBlack ? (size * 2 + 2) : size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ratingShape: some View {
        let color = Color.bermsDifficulty(difficulty)
        switch difficulty {
        case .green:
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        case .blue:
            Rectangle()
                .fill(color)
                .frame(width: size, height: size)
        case .black, .doubleBlack:
            TrailDiamond()
                .fill(color)
                .frame(width: size, height: size)
                .overlay {
                    TrailDiamond()
                        .stroke(Color.bermsMuted.opacity(0.7), lineWidth: 0.75)
                }
        case .unrated:
            Circle()
                .strokeBorder(
                    color,
                    style: StrokeStyle(lineWidth: max(1, size * 0.18), dash: [size * 0.3, size * 0.22])
                )
                .frame(width: size, height: size)
        }
    }
}

struct TrailDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

struct TrailMapLabel: View {
    let name: String
    let difficulty: TrailDifficulty
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            TrailRatingBadge(difficulty: difficulty)
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .accessibilityLabel("\(name), \(difficulty.title) trail")
        .allowsHitTesting(false)
    }
}
