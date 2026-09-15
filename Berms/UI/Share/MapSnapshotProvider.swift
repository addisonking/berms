import MapKit
import UIKit

struct ShareMapSnapshotRequest {
    let size: CGSize
    let scale: CGFloat
    let mapStyle: ShareCardMapStyle
    let routes: [ShareCardMapRoute]
    let trails: [TrailMapOverlay]
    let jumps: [SessionDetailJumpMarker]
}

enum ShareMapSnapshotError: Error {
    case noRoute
}

@MainActor
protocol ShareMapSnapshotting {
    func snapshot(_ request: ShareMapSnapshotRequest) async throws -> UIImage
}

struct MapKitShareSnapshotter: ShareMapSnapshotting {
    func snapshot(_ request: ShareMapSnapshotRequest) async throws -> UIImage {
        let points = request.routes.flatMap(\.points)
        guard let framing = ShareMapFraming.make(points: points, size: request.size) else {
            throw ShareMapSnapshotError.noRoute
        }

        let options = MKMapSnapshotter.Options()
        options.region = framing.region
        options.size = request.size
        options.showsBuildings = false
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = .light
            traits.displayScale = request.scale
        }
        options.preferredConfiguration = Self.mapConfiguration(for: request.mapStyle)

        let snapshot = try await MKMapSnapshotter(options: options).start()
        return Self.draw(snapshot: snapshot, request: request, framing: framing)
    }

    private static func mapConfiguration(for style: ShareCardMapStyle) -> MKMapConfiguration {
        switch style {
        case .satellite:
            return MKImageryMapConfiguration(elevationStyle: .flat)
        case .standard:
            return MKStandardMapConfiguration(elevationStyle: .flat)
        case .monochrome:
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            configuration.pointOfInterestFilter = .excludingAll
            return configuration
        }
    }

    private static func draw(
        snapshot: MKMapSnapshotter.Snapshot,
        request: ShareMapSnapshotRequest,
        framing: ShareMapFraming
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = request.scale
        format.opaque = true
        let tolerance = max(3, framing.largestSpan / 320)

        return UIGraphicsImageRenderer(size: request.size, format: format).image { context in
            snapshot.image.draw(at: .zero)
            let cg = context.cgContext

            for trail in request.trails {
                stroke(
                    cg,
                    coordinates: decimatedCoordinates(trail.points, tolerance: tolerance),
                    snapshot: snapshot,
                    color: Self.trailColor(trail.difficulty, style: request.mapStyle),
                    width: 1.8,
                    dash: trail.difficulty == .doubleBlack ? [5, 3] : [])
            }

            for route in request.routes where route.kind == .lift {
                stroke(
                    cg,
                    coordinates: decimatedCoordinates(route.points, tolerance: tolerance),
                    snapshot: snapshot,
                    color: Self.liftColor(request.mapStyle),
                    width: 1.6,
                    dash: [4, 3])
            }

            for route in request.routes where route.kind == .run {
                stroke(
                    cg,
                    coordinates: decimatedCoordinates(route.points, tolerance: tolerance),
                    snapshot: snapshot,
                    color: Self.runColor(request.mapStyle).withAlphaComponent(route.opacity),
                    width: 2.4,
                    dash: [])
            }

            for jump in request.jumps {
                let point = snapshot.point(
                    for: CLLocationCoordinate2D(
                        latitude: jump.coordinate.latitude,
                        longitude: jump.coordinate.longitude))
                let rect = CGRect(x: point.x - 3.2, y: point.y - 3.2, width: 6.4, height: 6.4)
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillEllipse(in: rect)
                cg.setStrokeColor(UIColor(white: 0, alpha: 0.6).cgColor)
                cg.setLineWidth(1)
                cg.strokeEllipse(in: rect)
            }
        }
    }

    private static func stroke(
        _ cg: CGContext,
        coordinates: [CLLocationCoordinate2D],
        snapshot: MKMapSnapshotter.Snapshot,
        color: UIColor,
        width: CGFloat,
        dash: [CGFloat]
    ) {
        guard coordinates.count > 1 else { return }
        let path = CGMutablePath()
        path.move(to: snapshot.point(for: coordinates[0]))
        for coordinate in coordinates.dropFirst() {
            path.addLine(to: snapshot.point(for: coordinate))
        }
        cg.saveGState()
        cg.addPath(path)
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        if !dash.isEmpty {
            cg.setLineDash(phase: 0, lengths: dash)
        }
        cg.strokePath()
        cg.restoreGState()
    }

    private static func decimatedCoordinates(_ points: [RoutePoint], tolerance: Double) -> [CLLocationCoordinate2D] {
        decimate(points, tolerance: tolerance).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private static func decimate(_ points: [RoutePoint], tolerance: Double) -> [RoutePoint] {
        guard points.count > 2 else { return points }
        var result: [RoutePoint] = [points[0]]
        var anchor = points[0]
        for point in points.dropFirst().dropLast() where metersBetween(anchor, point) >= tolerance {
            result.append(point)
            anchor = point
        }
        if let last = points.last {
            result.append(last)
        }
        return result
    }

    private static func metersBetween(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let latitudeScale = 111_000.0
        let longitudeScale = 111_000.0 * max(0.1, cos(a.latitude * .pi / 180))
        let dx = (b.longitude - a.longitude) * longitudeScale
        let dy = (b.latitude - a.latitude) * latitudeScale
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func runColor(_ style: ShareCardMapStyle) -> UIColor {
        style == .satellite ? .white : UIColor(white: 0.06, alpha: 1)
    }

    private static func liftColor(_ style: ShareCardMapStyle) -> UIColor {
        style == .satellite ? UIColor(white: 1, alpha: 0.85) : UIColor(white: 0.3, alpha: 0.85)
    }

    private static func trailColor(_ difficulty: TrailDifficulty, style: ShareCardMapStyle) -> UIColor {
        switch difficulty {
        case .green: .systemGreen
        case .blue: .systemBlue
        case .black, .doubleBlack: style == .satellite ? .white : .black
        }
    }
}

struct ShareMapFraming {
    let region: MKCoordinateRegion
    let largestSpan: CLLocationDistance

    static func make(points: [RoutePoint], size: CGSize) -> ShareMapFraming? {
        guard size.width > 0, size.height > 0 else { return nil }
        var minLatitude = 0.0
        var maxLatitude = 0.0
        var minLongitude = 0.0
        var maxLongitude = 0.0
        var hasPoint = false
        for point in points {
            guard point.latitude.isFinite, point.longitude.isFinite,
                (-90...90).contains(point.latitude),
                (-180...180).contains(point.longitude)
            else { continue }
            if !hasPoint {
                minLatitude = point.latitude
                maxLatitude = point.latitude
                minLongitude = point.longitude
                maxLongitude = point.longitude
                hasPoint = true
                continue
            }
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }
        guard hasPoint else { return nil }

        let centerLatitude = (minLatitude + maxLatitude) / 2
        let centerLongitude = (minLongitude + maxLongitude) / 2
        let longitudeScale = max(0.1, cos(centerLatitude * .pi / 180))
        let latitudeMeters = max(250, (maxLatitude - minLatitude) * 111_000 * 1.18)
        let longitudeMeters = max(250, (maxLongitude - minLongitude) * 111_000 * longitudeScale * 1.18)

        let aspect = size.width / size.height
        let adjustedLatitude =
            longitudeMeters / latitudeMeters < aspect
            ? latitudeMeters
            : longitudeMeters / aspect
        let adjustedLongitude =
            longitudeMeters / latitudeMeters < aspect
            ? latitudeMeters * aspect
            : longitudeMeters

        return ShareMapFraming(
            region: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
                latitudinalMeters: adjustedLatitude,
                longitudinalMeters: adjustedLongitude
            ),
            largestSpan: max(adjustedLatitude, adjustedLongitude)
        )
    }
}
