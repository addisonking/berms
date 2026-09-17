import MapKit
import SwiftUI

/// Camera framing and legal pan/zoom range for a route map. When a resort is
/// known the boundary owns the range, so toggling map layers never moves the
/// camera limits and the camera can never leave the resort.
struct RouteMapConfiguration {
    let initialPosition: MapCameraPosition
    /// The region `initialPosition` frames. Map views seed their own idea of the
    /// visible region from this, so overlays never depend on a camera callback
    /// arriving after a programmatic move.
    let framingRegion: MKCoordinateRegion
    let initialDistance: CLLocationDistance
    let minimumDistance: CLLocationDistance
    let maximumDistance: CLLocationDistance
    let panRegion: MKCoordinateRegion

    var bounds: MapCameraBounds {
        MapCameraBounds(
            centerCoordinateBounds: panRegion,
            minimumDistance: minimumDistance,
            maximumDistance: maximumDistance)
    }

    /// True when a camera region sits inside the legal pan area. The map reports
    /// the previous framing after a programmatic move, and trusting that region
    /// hides every overlay, so callers filter camera changes through this.
    func contains(cameraRegion: MKCoordinateRegion) -> Bool {
        let halfLatitude = panRegion.span.latitudeDelta / 2
        let halfLongitude = panRegion.span.longitudeDelta / 2
        return abs(cameraRegion.center.latitude - panRegion.center.latitude) <= halfLatitude
            && abs(cameraRegion.center.longitude - panRegion.center.longitude) <= halfLongitude
    }

    private init(
        framingRegion: MKCoordinateRegion,
        initialDistance: CLLocationDistance,
        minimumDistance: CLLocationDistance,
        maximumDistance: CLLocationDistance,
        panRegion: MKCoordinateRegion
    ) {
        self.initialPosition = .region(framingRegion)
        self.framingRegion = framingRegion
        self.initialDistance = initialDistance
        self.minimumDistance = minimumDistance
        self.maximumDistance = maximumDistance
        self.panRegion = panRegion
    }

    init?(points: [RoutePoint], boundary: ResortBoundary? = nil) {
        let extent = RouteExtent(points: points)
        if let boundary {
            self = Self.resortConfiguration(extent: extent, boundary: boundary)
        } else if let extent {
            self = Self.sessionConfiguration(extent: extent)
        } else {
            return nil
        }
    }

    /// Frames a set of trails from their combined bounds, so callers never
    /// flatten every point of a large catalog just to place the camera.
    init(bounds: GeoBounds, boundary: ResortBoundary? = nil) {
        let extent = RouteExtent(bounds: bounds)
        if let boundary {
            self = Self.resortConfiguration(extent: extent, boundary: boundary)
        } else {
            self = Self.sessionConfiguration(extent: extent)
        }
    }

    private static func resortConfiguration(
        extent: RouteExtent?,
        boundary: ResortBoundary
    ) -> RouteMapConfiguration {
        let resortCenter = CLLocationCoordinate2D(
            latitude: boundary.center.latitude,
            longitude: boundary.center.longitude)
        let diameter = boundary.radiusMeters * 2
        let panRegion = MKCoordinateRegion(
            center: resortCenter,
            latitudinalMeters: diameter * 1.4,
            longitudinalMeters: diameter * 1.4)

        let positionCenter = extent?.center ?? resortCenter
        let positionLatitude = min(max((extent?.latitudeMeters ?? 0) * 1.25, diameter * 0.5), diameter * 1.15)
        let positionLongitude = min(max((extent?.longitudeMeters ?? 0) * 1.25, diameter * 0.5), diameter * 1.15)

        return RouteMapConfiguration(
            framingRegion: MKCoordinateRegion(
                center: positionCenter,
                latitudinalMeters: positionLatitude,
                longitudinalMeters: positionLongitude),
            initialDistance: max(positionLatitude, positionLongitude),
            minimumDistance: 60,
            // Enough distance that the whole resort boundary fits on screen.
            maximumDistance: max(1_200, diameter * 2.0),
            panRegion: panRegion
        )
    }

    private static func sessionConfiguration(extent: RouteExtent) -> RouteMapConfiguration {
        let latitudeMeters = max(800, extent.latitudeMeters * 1.25)
        let longitudeMeters = max(800, extent.longitudeMeters * 1.25)
        let largestSpan = max(latitudeMeters, longitudeMeters)
        let center = extent.center
        let panRegion = MKCoordinateRegion(
            center: center,
            latitudinalMeters: max(2_500, latitudeMeters * 2.2),
            longitudinalMeters: max(2_500, longitudeMeters * 2.2))

        return RouteMapConfiguration(
            framingRegion: MKCoordinateRegion(
                center: center,
                latitudinalMeters: latitudeMeters,
                longitudinalMeters: longitudeMeters),
            initialDistance: largestSpan,
            minimumDistance: max(60, largestSpan * 0.05),
            maximumDistance: min(max(2_500, largestSpan * 3.5), 15_000),
            panRegion: panRegion
        )
    }
}

private struct RouteExtent {
    let center: CLLocationCoordinate2D
    let latitudeMeters: Double
    let longitudeMeters: Double

    init?(points: [RoutePoint]) {
        var minLatitude = 0.0
        var maxLatitude = 0.0
        var minLongitude = 0.0
        var maxLongitude = 0.0
        var hasValidPoint = false
        for point in points {
            guard point.latitude.isFinite, point.longitude.isFinite,
                (-90...90).contains(point.latitude),
                (-180...180).contains(point.longitude)
            else { continue }
            if !hasValidPoint {
                minLatitude = point.latitude
                maxLatitude = point.latitude
                minLongitude = point.longitude
                maxLongitude = point.longitude
                hasValidPoint = true
                continue
            }
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }
        guard hasValidPoint else { return nil }

        let centerLatitude = (minLatitude + maxLatitude) / 2
        let centerLongitude = (minLongitude + maxLongitude) / 2
        let longitudeScale = max(0.1, cos(centerLatitude * .pi / 180))
        center = CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
        latitudeMeters = max(100, (maxLatitude - minLatitude) * 111_000)
        longitudeMeters = max(100, (maxLongitude - minLongitude) * 111_000 * longitudeScale)
    }

    init(bounds: GeoBounds) {
        let centerLatitude = (bounds.minLatitude + bounds.maxLatitude) / 2
        let centerLongitude = (bounds.minLongitude + bounds.maxLongitude) / 2
        let longitudeScale = max(0.1, cos(centerLatitude * .pi / 180))
        center = CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
        latitudeMeters = max(100, (bounds.maxLatitude - bounds.minLatitude) * 111_000)
        longitudeMeters = max(100, (bounds.maxLongitude - bounds.minLongitude) * 111_000 * longitudeScale)
    }
}
