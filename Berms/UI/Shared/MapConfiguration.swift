import MapKit
import SwiftData
import SwiftUI
import UIKit

struct SummaryMapJump: Identifiable {
    let id: String
    let number: Int
    let label: String
    let coordinate: CLLocationCoordinate2D
    let airtime: TimeInterval
}

struct JumpMarker: Identifiable {
    let number: Int
    let coordinate: CLLocationCoordinate2D
    let airtime: TimeInterval

    var id: Int { number }
}

struct RouteMapConfiguration {
    let initialPosition: MapCameraPosition
    let initialDistance: CLLocationDistance
    let bounds: MapCameraBounds

    init?(points: [RoutePoint]) {
        var minLatitude = 0.0
        var maxLatitude = 0.0
        var minLongitude = 0.0
        var maxLongitude = 0.0
        var hasValidPoint = false
        for point in points {
            guard point.latitude.isFinite, point.longitude.isFinite,
                  (-90...90).contains(point.latitude),
                  (-180...180).contains(point.longitude) else { continue }
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
        let latitudeMeters = max(100, (maxLatitude - minLatitude) * 111_000)
        let longitudeScale = max(0.1, cos(centerLatitude * .pi / 180))
        let longitudeMeters = max(100, (maxLongitude - minLongitude) * 111_000 * longitudeScale)
        let cameraLatitudeMeters = max(800, latitudeMeters * 1.25)
        let cameraLongitudeMeters = max(800, longitudeMeters * 1.25)
        let largestSpan = max(cameraLatitudeMeters, cameraLongitudeMeters)
        let cameraRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
            latitudinalMeters: cameraLatitudeMeters,
            longitudinalMeters: cameraLongitudeMeters
        )
        let boundsRegion = MKCoordinateRegion(
            center: cameraRegion.center,
            latitudinalMeters: max(2_500, cameraLatitudeMeters * 3.0),
            longitudinalMeters: max(2_500, cameraLongitudeMeters * 3.0)
        )

        initialPosition = .region(cameraRegion)
        initialDistance = largestSpan
        bounds = MapCameraBounds(
            centerCoordinateBounds: boundsRegion,
            minimumDistance: max(60, largestSpan * 0.08),
            maximumDistance: max(20_000, largestSpan * 8)
        )
    }
}
