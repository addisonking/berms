import Combine
import CoreLocation
import Foundation

/// Each service owns one lease; idle cleanup can only release its own consumer.
@MainActor
final class LocationCapture: ObservableObject {
    static let shared = LocationCapture()
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    private let driver: LocationCaptureDriver?
    private var authorizationSubscription: AnyCancellable?
    private final class Consumer {
        weak var service: LocationService?
        init(_ service: LocationService) { self.service = service }
    }
    private var consumers: [UUID: Consumer] = [:]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var consumerCount: Int { consumers.count }

    init(usesHardware: Bool = true) {
        driver = usesHardware ? LocationCaptureDriver() : nil
        authorizationStatus = driver?.authorizationStatus ?? .authorizedAlways
        authorizationSubscription = driver?.$authorizationStatus.sink { [weak self] status in
            self?.authorizationChanged(status)
        }
    }

    func acquire(_ consumer: LocationService, access: BackgroundLocationAccess) {
        guard consumers[consumer.id] == nil else { return }
        consumers[consumer.id] = Consumer(consumer)
        if consumers.count == 1 {
            startCount += 1
            driver?.diagnosticHandler = { [weak self] detail in self?.report(detail) }
            driver?.start(backgroundAccess: access) { [weak self] location, stationary in
                self?.deliver(location, stationary: stationary)
            }
        } else if access == .activitySession {
            // Acquire while foregrounded, before a ride's Live Activity can end.
            driver?.requireBackgroundActivitySession()
        }
    }

    func release(_ id: UUID) {
        guard consumers.removeValue(forKey: id) != nil else { return }
        guard consumers.isEmpty else { return }
        stopCount += 1
        driver?.stop()
    }

    func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        for consumer in consumers.values.compactMap({ $0.service }) {
            consumer.authorizationChangeHandler?(status)
        }
    }

    func deliver(_ location: CLLocation, stationary: Bool = false) {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        for consumer in consumers.values.compactMap({ $0.service }) {
            consumer.receive(location, stationary: stationary)
        }
    }

    func report(_ detail: String) {
        for consumer in consumers.values.compactMap({ $0.service }) { consumer.diagnosticHandler?(detail) }
    }
}

@MainActor
final class LocationService: ObservableObject {
    fileprivate let id = UUID()
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var isRunning = false
    var authorizationChangeHandler: ((CLAuthorizationStatus) -> Void)?
    var diagnosticHandler: ((String) -> Void)?
    private let capture: LocationCapture
    private var subscription: AnyCancellable?
    private var handler: ((CLLocation, Bool) -> Void)?

    init(capture: LocationCapture? = nil) {
        self.capture = capture ?? .shared
        authorizationStatus = self.capture.authorizationStatus
        subscription = self.capture.$authorizationStatus.sink { [weak self] status in
            self?.authorizationStatus = status
        }
    }

    deinit {
        let capture = capture
        let id = id
        Task { @MainActor in capture.release(id) }
    }

    func start(
        backgroundAccess: BackgroundLocationAccess = .activitySession,
        handler: @escaping (CLLocation, Bool) -> Void
    ) {
        guard !isRunning else { return }
        self.handler = handler
        isRunning = true
        capture.acquire(self, access: backgroundAccess)
    }

    func stop() {
        capture.release(id)
        isRunning = false
        handler = nil
        authorizationChangeHandler = nil
        diagnosticHandler = nil
    }

    fileprivate func receive(_ location: CLLocation, stationary: Bool) {
        guard isRunning else { return }
        lastLocation = location
        handler?(location, stationary)
    }
}
