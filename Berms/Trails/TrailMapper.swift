#if DEBUG
    import Combine
    import CoreLocation
    import Foundation
    import MapKit
    import SwiftData

    @MainActor
    final class TrailMapper: ObservableObject {
        static let shared = TrailMapper()

        let locationService = LocationService()

        @Published private(set) var isRecording = false
        @Published private(set) var activePoints: [TrackSample] = []
        @Published private(set) var lastSample: TrackSample?
        @Published private(set) var activeTrailName = ""
        @Published private(set) var activeDifficulty: TrailDifficulty = .blue
        @Published private(set) var activeStyle: TrailStyle = .unknown
        @Published private(set) var activeResort = ""
        @Published private(set) var isSaving = false
        @Published var errorMessage: String?

        private let context: ModelContext
        private var geocodingRequest: MKReverseGeocodingRequest?
        private var normalizer = TrackSampleNormalizer()
        private var activeTrail: Trail?
        private var startedAt: Date?

        private init(context: ModelContext? = nil) {
            self.context = context ?? PersistenceController.shared.container.mainContext
        }

        var locationAuthorization: CLAuthorizationStatus {
            locationService.authorizationStatus
        }

        var activeRoutePoints: [RoutePoint] {
            activePoints.map(\.routePoint)
        }

        var activeTrailPoints: [RoutePoint] {
            activeTrail?.points ?? []
        }

        @discardableResult
        func start(
            existingTrail: Trail?, name: String, difficulty: TrailDifficulty,
            style: TrailStyle = .unknown, resortOverride: String = ""
        ) -> Bool {
            guard !isRecording else { return false }
            guard !RideRecorder.shared.isRecording else {
                errorMessage = "Finish the ride recording before mapping a trail."
                return false
            }
            guard locationService.authorizationStatus != .denied,
                locationService.authorizationStatus != .restricted
            else {
                errorMessage = "Location access is disabled. Enable it in Settings."
                return false
            }

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard existingTrail != nil || !trimmedName.isEmpty else {
                errorMessage = "Enter a trail name first."
                return false
            }

            activeTrail = existingTrail
            activeTrailName = existingTrail?.name ?? trimmedName
            activeDifficulty = existingTrail?.difficulty ?? difficulty
            activeStyle = existingTrail?.style ?? style
            activeResort = existingTrail?.resort ?? resortOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            activePoints = []
            lastSample = nil
            normalizer.seed(with: nil)
            startedAt = .now
            isRecording = true

            locationService.authorizationChangeHandler = { [weak self] _ in
                self?.objectWillChange.send()
            }
            locationService.diagnosticHandler = { [weak self] detail in
                self?.errorMessage = detail
            }
            locationService.start { [weak self] location, stationary in
                self?.consume(location: location, isStationary: stationary)
            }
            return true
        }

        @discardableResult
        func save() -> Bool {
            guard isRecording, !isSaving else { return false }
            guard activePoints.count >= 2 else {
                errorMessage = "Wait for a few GPS points before saving."
                return false
            }

            isSaving = true
            locationService.stop()
            let routePoints = activeRoutePoints
            if let activeTrail {
                return finishSave(routePoints: routePoints, resort: activeTrail.resort)
            }
            if !activeResort.isEmpty {
                return finishSave(routePoints: routePoints, resort: activeResort)
            }

            guard let firstPoint = routePoints.first else {
                errorMessage = "Could not determine the trail location."
                isSaving = false
                return false
            }
            let location = CLLocation(latitude: firstPoint.latitude, longitude: firstPoint.longitude)
            guard let request = MKReverseGeocodingRequest(location: location) else {
                return finishSave(routePoints: routePoints, resort: "Unknown resort")
            }
            geocodingRequest = request
            Task { @MainActor [weak self] in
                defer { self?.geocodingRequest = nil }
                let mapItems = try? await request.mapItems
                guard let self, self.isRecording else { return }
                let resort = self.resortName(from: mapItems ?? [])
                _ = self.finishSave(routePoints: routePoints, resort: resort)
            }
            return true
        }

        func discard() {
            locationService.stop()
            reset()
        }

        func stopIfIdle() {
            guard !isRecording else { return }
            locationService.stop()
        }

        private func consume(location: CLLocation, isStationary: Bool) {
            guard isRecording else { return }
            let rawSample = TrackSample(
                coordinate: Coordinate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude),
                altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                speed: max(0, location.speed),
                course: location.course >= 0 ? location.course : -1,
                horizontalAccuracy: location.horizontalAccuracy,
                timestamp: location.timestamp,
                isStationary: isStationary,
                isCycling: false,
                isAutomotive: false
            )
            guard let sample = normalizer.normalize(rawSample) else { return }
            activePoints.append(sample)
            lastSample = sample
        }

        private func finishSave(routePoints: [RoutePoint], resort: String) -> Bool {
            guard isRecording else {
                isSaving = false
                return false
            }
            let trail: Trail
            if let activeTrail {
                trail = activeTrail
            } else {
                trail = Trail(
                    name: activeTrailName, difficulty: activeDifficulty,
                    style: activeStyle, resort: resort)
                context.insert(trail)
            }

            let pass = TrailPass(routePoints: routePoints, recordedAt: startedAt ?? .now)
            pass.trail = trail
            trail.passes.append(pass)
            context.insert(pass)
            trail.recalculateAverage()

            do {
                try context.save()
                reset()
                return true
            } catch {
                isSaving = false
                errorMessage = "Could not save this trail segment: \(error.localizedDescription)"
                return false
            }
        }

        private func resortName(from mapItems: [MKMapItem]) -> String {
            if let name = mapItems.lazy.compactMap({ $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty })
            {
                return name
            }
            if let city = mapItems.lazy.compactMap({ $0.addressRepresentations?.cityName })
                .first(where: { !$0.isEmpty })
            {
                return city
            }
            if let address = mapItems.lazy.compactMap({ $0.address?.shortAddress ?? $0.address?.fullAddress })
                .first(where: { !$0.isEmpty })
            {
                return address
            }
            return "Unknown resort"
        }

        private func reset() {
            geocodingRequest?.cancel()
            geocodingRequest = nil
            isSaving = false
            isRecording = false
            activePoints = []
            lastSample = nil
            activeTrailName = ""
            activeDifficulty = .blue
            activeStyle = .freeRide
            activeResort = ""
            activeTrail = nil
            startedAt = nil
            normalizer.seed(with: nil)
        }
    }
#endif
