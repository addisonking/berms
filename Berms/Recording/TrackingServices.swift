import Combine
@preconcurrency import CoreLocation
@preconcurrency import CoreMotion
import Foundation
import UIKit

enum BackgroundLocationAccess {
    /// An active Live Activity keeps background location updates running.
    case liveActivity
    /// No Live Activity is running, so ask Core Location for a background activity session.
    case activitySession
}

@MainActor
final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var isRunning = false

    private let manager = CLLocationManager()
    private var updatesTask: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?
    private var serviceSession: CLServiceSession?
    private var backgroundAccess: BackgroundLocationAccess = .activitySession
    private var handler: ((CLLocation, Bool) -> Void)?
    private var didRequestAlwaysUpgrade = false
    private var updateGeneration = 0
    var authorizationChangeHandler: ((CLAuthorizationStatus) -> Void)?
    var diagnosticHandler: ((String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = false
        authorizationStatus = manager.authorizationStatus
    }

    func start(
        backgroundAccess: BackgroundLocationAccess = .activitySession,
        handler: @escaping (CLLocation, Bool) -> Void
    ) {
        guard !isRunning else { return }
        self.handler = handler
        self.backgroundAccess = backgroundAccess
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestAlwaysUpgradeIfNeeded()
            beginUpdates()
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        authorizationChangeHandler?(authorizationStatus)

        guard handler != nil else { return }
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requestAlwaysUpgradeIfNeeded()
            restartUpdatesIfNeeded()
        case .denied, .restricted:
            stopUpdates()
        case .notDetermined:
            break
        @unknown default:
            stopUpdates()
        }
    }

    func stop() {
        updateGeneration &+= 1
        manager.stopUpdatingLocation()
        stopUpdates()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        handler = nil
        authorizationChangeHandler = nil
        diagnosticHandler = nil
    }

    private func requestAlwaysUpgradeIfNeeded() {
        guard authorizationStatus == .authorizedWhenInUse, !didRequestAlwaysUpgrade else { return }
        didRequestAlwaysUpgrade = true
        manager.requestAlwaysAuthorization()
    }

    private func beginUpdates() {
        guard !isRunning, handler != nil else { return }
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }

        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        startSessionsIfNeeded()
        startStream()
    }

    /// Creates the Core Location sessions for this recording.
    ///
    /// Only ever creates them while the app is in the foreground. Creating a
    /// background activity session during a background launch leaves a stuck
    /// Dynamic Island location indicator on some iPhones after the sessions are
    /// invalidated, and only a device restart clears it. The recording Live
    /// Activity already keeps background updates running, so the background
    /// activity session is only a fallback for when no Live Activity exists.
    private func startSessionsIfNeeded() {
        guard serviceSession == nil, backgroundSession == nil else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        let authorization: CLServiceSession.AuthorizationRequirement =
            authorizationStatus == .authorizedAlways ? .always : .whenInUse
        serviceSession = CLServiceSession(authorization: authorization)
        if backgroundAccess == .activitySession {
            backgroundSession = CLBackgroundActivitySession()
        }
    }

    private func startStream() {
        isRunning = true
        let generation = updateGeneration

        updatesTask = Task { [weak self] in
            do {
                let updates = CLLocationUpdate.liveUpdates(.otherNavigation)
                for try await update in updates {
                    guard !Task.isCancelled else { break }
                    guard let location = update.location else { continue }
                    guard let self else { break }
                    self.lastLocation = location
                    self.authorizationStatus = self.manager.authorizationStatus
                    self.handler?(location, update.stationary)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.diagnosticHandler?("location_stream_error: \(error.localizedDescription)")
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                guard self.isRunning, self.handler != nil,
                    self.updateGeneration == generation
                else { return }
                self.restartStream()
            }
        }
    }

    private func restartStream() {
        updateGeneration &+= 1
        stopStream()
        startStream()
    }

    private func restartUpdatesIfNeeded() {
        guard isRunning else {
            beginUpdates()
            return
        }
        // Keep the existing sessions; recreating them is what strands the
        // background location indicator.
        restartStream()
    }

    private func stopStream() {
        updatesTask?.cancel()
        updatesTask = nil
        isRunning = false
    }

    private func stopUpdates() {
        stopStream()
        backgroundSession?.invalidate()
        serviceSession?.invalidate()
        backgroundSession = nil
        serviceSession = nil
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }
}

final class MotionService: ObservableObject, @unchecked Sendable {
    @Published private(set) var relativeAltitude: Double?
    private(set) var relativeAltitudeTimestamp: Date?
    @Published private(set) var altimeterAvailable = false
    @Published private(set) var deviceMotionAvailable = false
    var rawAltitudeHandler: (@Sendable (MotionAltitudeSample) -> Void)?
    var rawActivityHandler: (@Sendable (MotionActivitySample) -> Void)?
    var rawDeviceMotionHandler: (@Sendable (DeviceMotionSample) -> Void)?
    @Published private(set) var isCycling = false
    @Published private(set) var isAutomotive = false
    @Published private(set) var motionAvailable = true

    @MainActor private var generation = 0
    @MainActor private var isRunning = false
    private let altimeter = CMAltimeter()
    private let activityManager = CMMotionActivityManager()
    private let deviceMotionManager = CMMotionManager()
    private let callbackQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.addis.berms.motion"
        return queue
    }()

    @MainActor
    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        let generation = generation
        relativeAltitude = nil
        relativeAltitudeTimestamp = nil
        isCycling = false
        isAutomotive = false
        let authorization = CMAltimeter.authorizationStatus()
        altimeterAvailable =
            CMAltimeter.isRelativeAltitudeAvailable()
            && authorization != .denied && authorization != .restricted
        motionAvailable = altimeterAvailable
        deviceMotionManager.deviceMotionUpdateInterval = 0.04
        deviceMotionAvailable = deviceMotionManager.isDeviceMotionAvailable
        motionAvailable = motionAvailable || deviceMotionAvailable
        if deviceMotionAvailable {
            deviceMotionManager.startDeviceMotionUpdates(
                using: .xArbitraryCorrectedZVertical,
                to: callbackQueue,
                withHandler: Self.deviceMotionCallback(rawDeviceMotionHandler)
            )
        }
        if altimeterAvailable {
            altimeter.startRelativeAltitudeUpdates(
                to: callbackQueue,
                withHandler: Self.altitudeCallback(for: self, generation: generation)
            )
        }
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: callbackQueue) { @Sendable [weak self] activity in
                guard let activity else { return }
                let sample = MotionActivitySample(
                    recordedAt: .now,
                    activityStart: activity.startDate,
                    stationary: activity.stationary,
                    walking: activity.walking,
                    running: activity.running,
                    cycling: activity.cycling,
                    automotive: activity.automotive,
                    unknown: activity.unknown,
                    confidence: activity.confidence.rawValue
                )
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    self.isCycling = sample.cycling
                    self.isAutomotive = sample.automotive
                    self.rawActivityHandler?(sample)
                }
            }
        }
    }

    private static func deviceMotionCallback(
        _ handler: (@Sendable (DeviceMotionSample) -> Void)?
    ) -> @Sendable (CMDeviceMotion?, Error?) -> Void {
        { data, _ in
            guard let data else { return }
            let attitude = data.attitude.quaternion
            handler?(
                DeviceMotionSample(
                    recordedAt: .now,
                    monotonicSeconds: data.timestamp,
                    userAccelerationX: data.userAcceleration.x,
                    userAccelerationY: data.userAcceleration.y,
                    userAccelerationZ: data.userAcceleration.z,
                    rotationRateX: data.rotationRate.x,
                    rotationRateY: data.rotationRate.y,
                    rotationRateZ: data.rotationRate.z,
                    gravityX: data.gravity.x,
                    gravityY: data.gravity.y,
                    gravityZ: data.gravity.z,
                    quaternionW: attitude.w,
                    quaternionX: attitude.x,
                    quaternionY: attitude.y,
                    quaternionZ: attitude.z
                ))
        }
    }

    private static func altitudeCallback(
        for service: MotionService,
        generation: Int
    ) -> @Sendable (CMAltitudeData?, Error?) -> Void {
        { data, _ in
            guard let data else { return }
            let sample = MotionAltitudeSample(
                timestamp: .now,
                relativeAltitude: data.relativeAltitude.doubleValue,
                pressureKPa: data.pressure.doubleValue
            )
            Task { @MainActor [weak service] in
                guard let service, service.generation == generation else { return }
                service.relativeAltitude = sample.relativeAltitude
                service.relativeAltitudeTimestamp = sample.timestamp
                service.rawAltitudeHandler?(sample)
            }
        }
    }

    @MainActor
    func stop() {
        isRunning = false
        generation &+= 1
        altimeter.stopRelativeAltitudeUpdates()
        activityManager.stopActivityUpdates()
        deviceMotionManager.stopDeviceMotionUpdates()
        relativeAltitude = nil
        relativeAltitudeTimestamp = nil
        isCycling = false
        isAutomotive = false
        rawAltitudeHandler = nil
        rawActivityHandler = nil
        rawDeviceMotionHandler = nil
    }
}
