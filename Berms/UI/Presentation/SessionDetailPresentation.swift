import MapKit
import SwiftData
import SwiftUI
import UIKit

@MainActor
final class MapLayerPreferences: ObservableObject {
    private enum Key {
        static let ridePath = "berms.mapLayers.ridePath"
        static let actualTrails = "berms.mapLayers.actualTrails"
        static let jumps = "berms.mapLayers.jumps"
        static let liftPaths = "berms.mapLayers.liftPaths"
        static let previousRuns = "berms.mapLayers.previousRuns"
    }

    private let defaults: UserDefaults

    @Published var showsRidePath: Bool {
        didSet { defaults.set(showsRidePath, forKey: Key.ridePath) }
    }

    @Published var showsActualTrails: Bool {
        didSet { defaults.set(showsActualTrails, forKey: Key.actualTrails) }
    }

    @Published var showsJumps: Bool {
        didSet { defaults.set(showsJumps, forKey: Key.jumps) }
    }

    @Published var showsLiftPaths: Bool {
        didSet { defaults.set(showsLiftPaths, forKey: Key.liftPaths) }
    }

    @Published var showsPreviousRunsInLiveMap: Bool {
        didSet { defaults.set(showsPreviousRunsInLiveMap, forKey: Key.previousRuns) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsRidePath = defaults.object(forKey: Key.ridePath) as? Bool ?? true
        showsActualTrails = defaults.object(forKey: Key.actualTrails) as? Bool ?? true
        showsJumps = defaults.object(forKey: Key.jumps) as? Bool ?? true
        showsLiftPaths = defaults.object(forKey: Key.liftPaths) as? Bool ?? true
        showsPreviousRunsInLiveMap = defaults.object(forKey: Key.previousRuns) as? Bool ?? false
    }
}

@MainActor
final class SessionDetailPresentationCache: ObservableObject {
    static let shared = SessionDetailPresentationCache()

    struct Entry: Sendable {
        let base: SessionDetailBase
        let trailDetails: SessionDetailTrailDetails
    }

    struct RunEntry: Sendable {
        let base: SessionDetailBase
        let detail: SessionDetailSegment
        let trailDetails: SessionDetailTrailDetails
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var runEntries: [String: RunEntry] = [:]
    private var runOrder: [String] = []
    @Published private(set) var revision = 0

    func entry(for key: String) -> Entry? {
        entries[key]
    }

    func store(_ entry: Entry, for key: String) {
        entries[key] = entry
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 3 {
            entries[order.removeFirst()] = nil
        }
        revision &+= 1
    }

    func runEntry(for key: String) -> RunEntry? {
        runEntries[key]
    }

    func storeRun(_ entry: RunEntry, for key: String) {
        runEntries[key] = entry
        runOrder.removeAll { $0 == key }
        runOrder.append(key)
        while runOrder.count > 3 {
            runEntries[runOrder.removeFirst()] = nil
        }
        revision &+= 1
    }
}

@MainActor
enum SessionDetailPresentationPreheater {
    static func latestCompletedRun(in days: [RideDay]) -> (day: RideDay, run: RideSegment)? {
        days.filter { $0.isFinished }.compactMap { day in
            guard
                let run = day.segments
                    .filter({ $0.kind == .run })
                    .max(by: { $0.startedAt < $1.startedAt })
            else {
                return nil
            }
            return (day: day, run: run)
        }
        .max(by: { $0.run.startedAt < $1.run.startedAt })
    }

    static func cacheKey(dayID: UUID, selectionID: String, trails: [Trail]) -> String {
        "\(dayID.uuidString)|\(selectionID)|\(trailRevision(for: trails))"
    }

    static func runCacheKey(
        dayID: UUID,
        segmentID: UUID,
        selectionID: String,
        trails: [Trail]
    ) -> String {
        "\(dayID.uuidString)|\(segmentID.uuidString)|\(selectionID)|\(trailRevision(for: trails))"
    }

    /// Snapshots the day on its own model context so navigation is never blocked by
    /// SwiftData reads or route decoding. Returns nil when the day no longer exists.
    static func makeInput(
        dayID: UUID,
        manualCatalogID: String?,
        container: ModelContainer
    ) async -> SessionDetailPreparationInput? {
        await Task.detached(priority: .userInitiated) {
            SessionDetailPresentationBuilder.makeInput(
                dayID: dayID,
                manualCatalogID: manualCatalogID,
                container: container
            )
        }.value
    }

    /// Snapshots the run on its own model context so navigation is never blocked by
    /// SwiftData reads or route decoding. Returns nil when the run no longer exists.
    static func makeInput(
        segmentID: UUID,
        manualCatalogID: String?,
        container: ModelContainer
    ) async -> SessionDetailPreparationInput? {
        await Task.detached(priority: .userInitiated) {
            SessionDetailPresentationBuilder.makeInput(
                segmentID: segmentID,
                manualCatalogID: manualCatalogID,
                container: container
            )
        }.value
    }

    static func build(
        _ input: SessionDetailPreparationInput,
        onBase: @MainActor (SessionDetailBase) -> Void = { _ in }
    ) async throws -> SessionDetailPresentationCache.Entry {
        let baseTask = Task.detached(priority: .utility) {
            try SessionDetailPresentationBuilder.buildBase(input)
        }
        let base = try await withTaskCancellationHandler {
            try await baseTask.value
        } onCancel: {
            baseTask.cancel()
        }
        try Task.checkCancellation()
        onBase(base)

        let trailTask = Task.detached(priority: .utility) {
            try SessionDetailPresentationBuilder.buildTrailDetails(base: base, input: input)
        }
        let trailDetails = try await withTaskCancellationHandler {
            try await trailTask.value
        } onCancel: {
            trailTask.cancel()
        }
        // The matcher stops early when cancelled, so a partial result must not be
        // handed back as a successful presentation.
        try Task.checkCancellation()
        return .init(base: base, trailDetails: trailDetails)
    }

    /// Prepares one run's presentation off the caller's actor.
    static func prepareRun(
        segmentID: UUID,
        manualCatalogID: String?,
        container: ModelContainer,
        onBase: @MainActor (SessionDetailBase) -> Void = { _ in }
    ) async throws -> SessionDetailPresentationCache.RunEntry? {
        guard
            let input = await makeInput(
                segmentID: segmentID,
                manualCatalogID: manualCatalogID,
                container: container)
        else {
            return nil
        }
        let entry = try await build(input, onBase: onBase)
        guard let detail = entry.base.segmentsByID[segmentID] else { return nil }
        return .init(base: entry.base, detail: detail, trailDetails: entry.trailDetails)
    }

    /// Groups the day's jumps by landing spot off the caller's actor, so a run
    /// can compare its jumps with the session's other runs.
    static func prepareJumpComparisons(
        dayID: UUID,
        container: ModelContainer
    ) async -> SessionJumpComparisons? {
        await Task.detached(priority: .userInitiated) {
            SessionJumpComparisonBuilder.build(dayID: dayID, container: container)
        }.value
    }

    static func trailRevision(for trails: [Trail]) -> String {
        trails
            .map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }
            .sorted()
            .joined(separator: "|")
    }
}
