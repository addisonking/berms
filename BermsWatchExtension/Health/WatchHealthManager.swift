import Foundation
@preconcurrency import HealthKit

@MainActor
final class WatchHealthManager: NSObject, WatchHealthProvider, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    private let healthStore = HKHealthStore()
    private let heartRateType = HKQuantityType(.heartRate)
    private let activeEnergyType = HKQuantityType(.activeEnergyBurned)

    private(set) var snapshot = WatchHealthSnapshot.unavailable
    var onSnapshotChange: ((WatchHealthSnapshot) -> Void)?

    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var authorizationInFlight = false
    private var pauseWhenStarted = false
    private var generation = UUID()

    func start() {
        guard workoutSession == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            updateSnapshot(.unavailable)
            return
        }
        guard !authorizationInFlight else { return }

        authorizationInFlight = true
        let requestGeneration = generation
        updateSnapshot(
            WatchHealthSnapshot(
                heartRateBeatsPerMinute: nil,
                activeCalories: nil,
                availability: .waiting
            ))
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == requestGeneration { authorizationInFlight = false } }
            do {
                try await healthStore.requestAuthorization(
                    toShare: [HKObjectType.workoutType()],
                    read: [heartRateType, activeEnergyType]
                )
                guard generation == requestGeneration else { return }
                try beginWorkout()
            } catch {
                guard generation == requestGeneration else { return }
                updateSnapshot(.unavailable)
            }
        }
    }

    func pause() {
        pauseWhenStarted = true
        workoutSession?.pause()
    }

    func resume() {
        pauseWhenStarted = false
        workoutSession?.resume()
    }

    func stop() {
        generation = UUID()
        authorizationInFlight = false
        pauseWhenStarted = false
        guard let session = workoutSession else {
            updateSnapshot(.unavailable)
            return
        }

        let builder = workoutBuilder
        workoutSession = nil
        workoutBuilder = nil
        if let builder {
            builder.endCollection(withEnd: .now) { @Sendable [session] _, _ in
                session.end()
                builder.discardWorkout()
            }
        } else {
            session.end()
        }
        updateSnapshot(.unavailable)
    }

    private func beginWorkout() throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .snowSports
        configuration.locationType = .outdoor

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self
        workoutSession = session
        workoutBuilder = builder

        let startDate = Date.now
        let collectionGeneration = generation
        session.startActivity(with: startDate)
        builder.beginCollection(withStart: startDate) { @Sendable [weak self] success, _ in
            guard success else {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == collectionGeneration else { return }
                    self.stop()
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == collectionGeneration else { return }
                if self.pauseWhenStarted {
                    self.workoutSession?.pause()
                }
                self.readLatestStatistics()
            }
        }
    }

    private func readLatestStatistics() {
        guard let builder = workoutBuilder else { return }
        var next = snapshot
        next.availability = .available
        if let statistics = builder.statistics(for: heartRateType),
            let quantity = statistics.mostRecentQuantity()
        {
            next.heartRateBeatsPerMinute = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        }
        if let statistics = builder.statistics(for: activeEnergyType),
            let quantity = statistics.sumQuantity()
        {
            next.activeCalories = quantity.doubleValue(for: .kilocalorie())
        }
        updateSnapshot(next)
    }

    private func updateSnapshot(_ snapshot: WatchHealthSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        onSnapshotChange?(snapshot)
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.workoutSession === workoutSession else { return }
            self.stop()
        }
    }

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf types: Set<HKSampleType>
    ) {
        Task { @MainActor [weak self] in
            self?.readLatestStatistics()
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didFinishWithError error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self, error != nil, self.workoutBuilder === workoutBuilder else { return }
            self.updateSnapshot(.unavailable)
        }
    }
}
