import Foundation

final class ParkLapDetector {
    struct Configuration: Sendable {
        var minimumConfirmationSeconds: TimeInterval = 15
        var minimumSamples: Int = 3
        var liftVerticalRate: Double = 0.35
        var runVerticalRate: Double = -0.35
        var minimumMovementSpeed: Double = 1.4
        var maximumLiftSpeed: Double = 18
        var maximumHorizontalAccuracy: Double = 80
        var learnedLifts: [LearnedLiftProfile] = []
        var endpointConfirmationSeconds: TimeInterval = 8
        var endpointSpeedThreshold: Double = 1.5
    }

    private var configuration: Configuration
    private(set) var phase: DetectorPhase = .idle
    private(set) var currentPoints: [TrackSample] = []
    private(set) var lastSample: TrackSample?
    private var candidatePoints: [TrackSample] = []
    private var endpointCandidate: [TrackSample] = []
    private var isInRunBreak = false

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func process(_ sample: TrackSample) -> [DetectorEvent] {
        guard sample.horizontalAccuracy <= configuration.maximumHorizontalAccuracy else {
            lastSample = sample
            return []
        }

        defer { lastSample = sample }

        guard lastSample != nil else {
            candidatePoints = [sample]
            return []
        }

        switch phase {
        case .idle:
            return processIdle(sample)
        case .lift:
            return processActive(sample, expected: .lift)
        case .run:
            return processActive(sample, expected: .run)
        }
    }

    func finish() -> DetectorEvent? {
        defer { reset() }

        guard currentPoints.count >= configuration.minimumSamples,
              let first = currentPoints.first,
              let last = currentPoints.last else {
            return nil
        }

        return .finished(SegmentDraft(kind: phase == .lift ? .lift : .run,
                                      points: currentPoints,
                                      startedAt: first.timestamp,
                                      endedAt: last.timestamp))
    }

    func reset() {
        phase = .idle
        currentPoints.removeAll(keepingCapacity: true)
        candidatePoints.removeAll(keepingCapacity: true)
        endpointCandidate.removeAll(keepingCapacity: true)
        isInRunBreak = false
        lastSample = nil
    }


    func restore(kind: SegmentKind, points: [TrackSample]) {
        phase = kind == .lift ? .lift : .run
        currentPoints = points
        candidatePoints.removeAll(keepingCapacity: true)
        endpointCandidate.removeAll(keepingCapacity: true)
        isInRunBreak = false
        lastSample = points.last
    }

    func setLearnedLifts(_ profiles: [LearnedLiftProfile]) {
        configuration.learnedLifts = profiles.filter { $0.observationCount >= 3 && $0.confidence >= 1 }
    }

    var snapshot: DetectorSnapshot {
        DetectorSnapshot(phase: phase, currentPoints: currentPoints, lastSample: lastSample)
    }

    private func processIdle(_ sample: TrackSample) -> [DetectorEvent] {
        candidatePoints.append(sample)
        trimCandidate()

        guard let kind = confirmedKind(in: candidatePoints) else { return [] }
        phase = kind == .lift ? .lift : .run
        currentPoints = candidatePoints.filter { !$0.isStationary && !$0.isAutomotive }
        candidatePoints.removeAll(keepingCapacity: true)
        return [.started(kind: kind, points: currentPoints)]
    }

    private func processActive(_ sample: TrackSample, expected: SegmentKind) -> [DetectorEvent] {
        if let endpointEvents = processLearnedEndpoint(sample, expected: expected) {
            return endpointEvents
        }

        if expected == .run {
            if sample.isStationary {
                isInRunBreak = true
                return []
            }
            if isInRunBreak {
                let resumedRun = isPattern(.run, in: windowIncluding(sample))
                isInRunBreak = false
                if resumedRun {
                    currentPoints.append(sample)
                    candidatePoints.removeAll(keepingCapacity: true)
                    return [.updated(kind: .run, point: sample)]
                }
            }
        }

        let opposite: SegmentKind = expected == .lift ? .run : .lift
        let localWindow = Array(windowIncluding(sample).suffix(3))
        if !isPattern(opposite, in: localWindow),
           !sample.isStationary && !sample.isAutomotive,
           (isPattern(expected, in: windowIncluding(sample))
            || (expected == .run && isLevelMovement(in: localWindow))) {
            if !candidatePoints.isEmpty {
                currentPoints.append(contentsOf: candidatePoints.filter {
                    !$0.isStationary && !$0.isAutomotive
                        && $0.timestamp > (currentPoints.last?.timestamp ?? .distantPast)
                })
                candidatePoints.removeAll(keepingCapacity: true)
            }
            currentPoints.append(sample)
            return [.updated(kind: expected, point: sample)]
        }

        if candidatePoints.isEmpty {
            candidatePoints = currentPoints.last.map { [$0] } ?? []
        }
        candidatePoints.append(sample)
        trimCandidate()

        guard let confirmedOpposite = confirmedKind(in: candidatePoints), confirmedOpposite == opposite else {
            return []
        }

        let oldPoints = currentPoints
        let oldKind = expected
        currentPoints = candidatePoints.filter { !$0.isStationary && !$0.isAutomotive }
        candidatePoints.removeAll(keepingCapacity: true)
        phase = opposite == .lift ? .lift : .run

        guard let first = oldPoints.first, let last = oldPoints.last,
              oldPoints.count >= configuration.minimumSamples else {
            return [.started(kind: opposite, points: currentPoints)]
        }

        let finished = SegmentDraft(kind: oldKind, points: oldPoints,
                                    startedAt: first.timestamp, endedAt: last.timestamp)
        return [.finished(finished), .started(kind: opposite, points: currentPoints)]
    }


    private func processLearnedEndpoint(_ sample: TrackSample, expected: SegmentKind) -> [DetectorEvent]? {
        guard let endpoint = configuration.learnedLifts.first(where: {
            expected == .run ? $0.containsBottom(sample.coordinate) : $0.containsTop(sample.coordinate)
        }),
        sample.speed <= configuration.endpointSpeedThreshold,
        !sample.isAutomotive else {
            endpointCandidate.removeAll(keepingCapacity: true)
            return nil
        }

        endpointCandidate.append(sample)
        while endpointCandidate.count > configuration.minimumSamples,
              let first = endpointCandidate.first,
              sample.timestamp.timeIntervalSince(first.timestamp)
                > configuration.endpointConfirmationSeconds + 5 {
            endpointCandidate.removeFirst()
        }
        guard let first = endpointCandidate.first,
              sample.timestamp.timeIntervalSince(first.timestamp) >= configuration.endpointConfirmationSeconds,
              endpointCandidate.allSatisfy({
                  expected == .run ? endpoint.containsBottom($0.coordinate) : endpoint.containsTop($0.coordinate)
              }) else {
            return []
        }

        let finishedPoints = currentPoints
        endpointCandidate.removeAll(keepingCapacity: true)
        candidatePoints.removeAll(keepingCapacity: true)
        isInRunBreak = false
        phase = .idle
        currentPoints.removeAll(keepingCapacity: true)

        guard finishedPoints.count >= configuration.minimumSamples,
              let firstPoint = finishedPoints.first,
              let lastPoint = finishedPoints.last else {
            return []
        }
        return [.finished(SegmentDraft(kind: expected, points: finishedPoints,
                                       startedAt: firstPoint.timestamp, endedAt: lastPoint.timestamp))]
    }

    private func confirmedKind(in points: [TrackSample]) -> SegmentKind? {
        guard points.count >= configuration.minimumSamples,
              let first = points.first, let last = points.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= configuration.minimumConfirmationSeconds else {
            return nil
        }

        if isPattern(.lift, in: points) { return .lift }
        if isPattern(.run, in: points) { return .run }
        return nil
    }

    private func isPattern(_ kind: SegmentKind, in points: [TrackSample]) -> Bool {
        guard points.count >= 2,
              let firstAltitude = points.first?.altitude,
              let lastAltitude = points.last?.altitude else { return false }

        let duration = points.last!.timestamp.timeIntervalSince(points.first!.timestamp)
        guard duration > 0 else { return false }

        let verticalRate = (lastAltitude - firstAltitude) / duration
        let movingPoints = points.filter { !$0.isStationary && !$0.isAutomotive }
        guard movingPoints.count >= max(2, points.count / 2) else { return false }

        let averageSpeed = movingPoints.map(\.speed).reduce(0, +) / Double(movingPoints.count)
        switch kind {
        case .lift:
            let nonCyclingCount = movingPoints.filter { !$0.isCycling }.count
            return verticalRate >= configuration.liftVerticalRate
                && averageSpeed >= configuration.minimumMovementSpeed
                && averageSpeed <= configuration.maximumLiftSpeed
                && nonCyclingCount * 2 >= movingPoints.count
        case .run:
            return verticalRate <= configuration.runVerticalRate
                && averageSpeed >= configuration.minimumMovementSpeed
        }
    }

    private func isLevelMovement(in points: [TrackSample]) -> Bool {
        guard let first = points.first, let last = points.last,
              let firstAltitude = first.altitude, let lastAltitude = last.altitude,
              last.speed >= configuration.minimumMovementSpeed else { return false }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration > 0 else { return false }
        return (lastAltitude - firstAltitude) / duration <= 0
    }

    private func windowIncluding(_ sample: TrackSample) -> [TrackSample] {
        // Pending samples keep the trend local even when committed points predate a long stop.
        Array((currentPoints.suffix(5) + candidatePoints.suffix(5) + [sample]).suffix(6))
    }

    private func trimCandidate() {
        guard let last = candidatePoints.last else { return }
        let maximumDuration = max(configuration.minimumConfirmationSeconds + 5, 20)
        while candidatePoints.count > configuration.minimumSamples,
              let first = candidatePoints.first,
              last.timestamp.timeIntervalSince(first.timestamp) > maximumDuration {
            candidatePoints.removeFirst()
        }
    }
}
