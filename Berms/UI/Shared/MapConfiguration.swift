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
        let panOverscan: CGFloat = 1.4
        let minimumPanDistance: CGFloat = 60
        let minimumMaximumDistance: CGFloat = 1_200
        let maximumDistanceOverscan: CGFloat = 2.0
        let panRegion = MKCoordinateRegion(
            center: resortCenter,
            latitudinalMeters: diameter * panOverscan,
            longitudinalMeters: diameter * panOverscan)

        let positionCenter = extent?.center ?? resortCenter
        // Without an extent, which is what a resort preview looks like, frame the
        // whole boundary. A small extent still opens out to half the resort so
        // the camera is not too tight on a short ride.
        let minimumSpanFactor: CGFloat = 0.5
        let extentGrowth: CGFloat = 1.25
        let maximumSpanFactor: CGFloat = 1.15
        let minimumSpan = extent == nil ? diameter : diameter * minimumSpanFactor
        let positionLatitude = min(
            max((extent?.latitudeMeters ?? 0) * extentGrowth, minimumSpan), diameter * maximumSpanFactor)
        let positionLongitude = min(
            max((extent?.longitudeMeters ?? 0) * extentGrowth, minimumSpan), diameter * maximumSpanFactor)

        return RouteMapConfiguration(
            framingRegion: MKCoordinateRegion(
                center: positionCenter,
                latitudinalMeters: positionLatitude,
                longitudinalMeters: positionLongitude),
            initialDistance: max(positionLatitude, positionLongitude),
            minimumDistance: minimumPanDistance,
            // Enough distance that the whole resort boundary fits on screen.
            maximumDistance: max(minimumMaximumDistance, diameter * maximumDistanceOverscan),
            panRegion: panRegion
        )
    }

    private static func sessionConfiguration(extent: RouteExtent) -> RouteMapConfiguration {
        let minimumExtentMeters: CGFloat = 800
        let extentGrowth: CGFloat = 1.25
        let minimumPanDistance: CGFloat = 60
        let latitudeMeters = max(minimumExtentMeters, extent.latitudeMeters * extentGrowth)
        let longitudeMeters = max(minimumExtentMeters, extent.longitudeMeters * extentGrowth)
        let largestSpan = max(latitudeMeters, longitudeMeters)
        let relativeMinimumDistance: CGFloat = 0.05
        let maximumDistanceGrowth: CGFloat = 3.5
        let maximumDistanceCap: CGFloat = 15_000
        let center = extent.center
        let panMinimumMeters: CGFloat = 2_500
        let panGrowth: CGFloat = 2.2
        let panRegion = MKCoordinateRegion(
            center: center,
            latitudinalMeters: max(panMinimumMeters, latitudeMeters * panGrowth),
            longitudinalMeters: max(panMinimumMeters, longitudeMeters * panGrowth))

        return RouteMapConfiguration(
            framingRegion: MKCoordinateRegion(
                center: center,
                latitudinalMeters: latitudeMeters,
                longitudinalMeters: longitudeMeters),
            initialDistance: largestSpan,
            minimumDistance: max(minimumPanDistance, largestSpan * relativeMinimumDistance),
            maximumDistance: min(
                max(panMinimumMeters, largestSpan * maximumDistanceGrowth), maximumDistanceCap),
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
