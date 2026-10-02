import Foundation
import SwiftData

extension RideRecorder {
    static func pruneOldDiagnosticLogs() {
        let fileManager = FileManager.default
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: diagnosticsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return }
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
        for url in urls where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let modified = values.contentModificationDate,
                modified < cutoff
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    func rebuildSummaryFromDiagnosticLog(for day: RideDay, from url: URL) -> Bool {
        guard day.isFinished,
            let summary = DiagnosticSummaryRebuilder.rebuild(dayID: day.id, logURL: url),
            reconcile(summary, to: day)
        else {
            return false
        }
        return saveContext(detail: "diagnostic_summary_rebuild")
    }

    private func reconcile(_ summary: RebuiltDaySummary, to day: RideDay) -> Bool {
        let existing = day.segments.sorted { $0.startedAt < $1.startedAt }
        let rebuilt = summary.segments.sorted { $0.startedAt < $1.startedAt }
        guard !rebuilt.isEmpty,
            existing.count == rebuilt.count,
            zip(existing, rebuilt).allSatisfy({ $0.kind == $1.kind })
        else {
            return false
        }

        for (segment, replacement) in zip(existing, rebuilt) {
            segment.startedAt = replacement.startedAt
            segment.endedAt = replacement.endedAt
            segment.routeData = replacement.routeData
            segment.jumpData = try? JSONEncoder().encode(replacement.jumps)
            segment.distanceMeters = replacement.distanceMeters
            segment.verticalMeters = replacement.verticalMeters
            segment.maximumSpeedMetersPerSecond = replacement.maximumSpeedMetersPerSecond
        }
        day.segments = existing
        day.recalculateTotals()
        return true
    }

    private struct SegmentRepairInput: Sendable {
        let id: UUID
        let kind: SegmentKind
        let routeData: Data
    }

    private struct RepairDayInput: Sendable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let segmentKinds: [SegmentKind]
    }

    func startDiagnosticMigrationIfNeeded() {
        guard migrationTask == nil else { return }
        let repairsStoredRoutes =
            UserDefaults.standard.string(forKey: Self.diagnosticSummaryVersionKey)
            != Self.diagnosticSummaryVersion

        let dayInputs: [RepairDayInput]
        let segmentInputs: [SegmentRepairInput]
        let passInputs: [CatalogPassRepairInput]
        do {
            let days = try context.fetch(FetchDescriptor<RideDay>()).filter(\.isFinished)
            dayInputs = days.filter { $0.diagnosticSummaryVersion != Self.diagnosticSummaryVersion }.map {
                RepairDayInput(
                    id: $0.id,
                    startedAt: $0.startedAt,
                    endedAt: $0.endedAt ?? $0.startedAt,
                    segmentKinds: $0.segments.sorted { $0.startedAt < $1.startedAt }.map(\.kind)
                )
            }
            guard repairsStoredRoutes || !dayInputs.isEmpty else { return }
            segmentInputs = try (repairsStoredRoutes ? context.fetch(FetchDescriptor<RideSegment>()) : []).map {
                SegmentRepairInput(id: $0.id, kind: $0.kind, routeData: $0.routeData)
            }
            passInputs = try (repairsStoredRoutes ? context.fetch(FetchDescriptor<TrailPass>()) : []).compactMap {
                pass in
                guard let trail = pass.trail else { return nil }
                return CatalogPassRepairInput(
                    id: pass.id, trailID: trail.id,
                    trailCreatedAt: trail.createdAt,
                    recordedAt: pass.recordedAt)
            }
        } catch {
            errorMessage = "Could not update saved session summaries. Please try again."
            return
        }

        let task = Task { [weak self] in
            let work = await Task.detached(priority: .utility) {
                () -> ([RebuiltDaySummary], [RepairedRoute], [RepairedRoute]) in
                let rebuiltDays = dayInputs.compactMap { input -> RebuiltDaySummary? in
                    let logURLs = DiagnosticSummaryRebuilder.logURLs(
                        dayID: input.id,
                        startedAt: input.startedAt,
                        endedAt: input.endedAt
                    )
                    guard
                        let summary = DiagnosticSummaryRebuilder.rebuild(
                            dayID: input.id,
                            logURLs: logURLs
                        ),
                        summary.segments.count == input.segmentKinds.count,
                        summary.segments.sorted(by: { $0.startedAt < $1.startedAt }).map(\.kind)
                            == input.segmentKinds
                    else {
                        return nil
                    }
                    return summary
                }
                let repairedSegments = segmentInputs.compactMap { input -> RepairedRoute? in
                    guard let points = try? RouteCodec.decode(input.routeData),
                        let cleaned = DiagnosticSummaryRebuilder.cleanedRoute(
                            points: points,
                            kind: input.kind)
                    else {
                        return nil
                    }
                    return RepairedRoute(
                        id: input.id,
                        routeData: cleaned.routeData,
                        distanceMeters: cleaned.distance,
                        verticalMeters: cleaned.vertical,
                        maximumSpeedMetersPerSecond: cleaned.maximumSpeed)
                }
                let catalogRoutePoints = TrailCatalogRegistry.catalogs.reduce(
                    into: [UUID: [RoutePoint]]()
                ) { routes, catalog in
                    routes.merge(TrailCatalogImporter.bundledRoutePoints(catalog: catalog)) {
                        current, _ in current
                    }
                }
                let repairedPasses = CatalogPassRepair.repairs(
                    inputs: passInputs,
                    catalogRoutes: catalogRoutePoints
                )
                return (rebuiltDays, repairedSegments, repairedPasses)
            }.value
            guard let self else { return }
            self.applyDiagnosticMigration(
                rebuiltDays: work.0,
                repairedSegments: work.1,
                repairedPasses: work.2,
                repairsStoredRoutes: repairsStoredRoutes)
        }
        setMigrationTask(task)
    }

    private func applyDiagnosticMigration(
        rebuiltDays: [RebuiltDaySummary],
        repairedSegments: [RepairedRoute],
        repairedPasses: [RepairedRoute],
        repairsStoredRoutes: Bool
    ) {
        defer { setMigrationTask(nil) }

        let segments: [RideSegment]
        let passes: [TrailPass]
        let trails: [Trail]
        let days: [RideDay]
        do {
            segments = try repairsStoredRoutes ? context.fetch(FetchDescriptor<RideSegment>()) : []
            passes = try repairsStoredRoutes ? context.fetch(FetchDescriptor<TrailPass>()) : []
            trails = try repairsStoredRoutes ? context.fetch(FetchDescriptor<Trail>()) : []
            days = try context.fetch(FetchDescriptor<RideDay>())
        } catch {
            errorMessage = "Could not update saved session summaries. Please try again."
            return
        }

        let segmentsByID = Dictionary(
            segments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        for repair in repairedSegments {
            guard let segment = segmentsByID[repair.id] else { continue }
            segment.routeData = repair.routeData
            segment.distanceMeters = repair.distanceMeters
            segment.verticalMeters = repair.verticalMeters
            segment.maximumSpeedMetersPerSecond = repair.maximumSpeedMetersPerSecond
        }

        var repairedTrailIDs = Set<UUID>()
        let passesByID = Dictionary(passes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for repair in repairedPasses {
            guard let pass = passesByID[repair.id], pass.trail?.catalogRouteData == nil else { continue }
            if let trailID = pass.trail?.id {
                repairedTrailIDs.insert(trailID)
            }
            pass.routeData = repair.routeData
            pass.distanceMeters = repair.distanceMeters
        }

        // Trail.points prefers the cached average over its passes. Rebuilding a
        // repaired pass without rebuilding that average leaves the old, thinned
        // centerline on every map that reads Trail.points.
        for trail in trails where repairedTrailIDs.contains(trail.id) && trail.catalogRouteData == nil {
            trail.recalculateAverage()
        }

        let daysByID = Dictionary(
            days.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var completedDays: [(day: RideDay, previousVersion: String?)] = []
        for summary in rebuiltDays {
            guard let day = daysByID[summary.dayID], day.isFinished,
                reconcile(summary, to: day)
            else { continue }
            completedDays.append((day, day.diagnosticSummaryVersion))
            day.diagnosticSummaryVersion = Self.diagnosticSummaryVersion
        }

        if repairsStoredRoutes {
            for day in days where day.isFinished {
                day.recalculateTotals()
                for segment in day.segments where segment.kind == .lift {
                    learnLiftProfile(from: segment)
                }
            }
        }

        guard saveContext(detail: "diagnostic_summary_migration") else {
            for completion in completedDays {
                completion.day.diagnosticSummaryVersion = completion.previousVersion
            }
            return
        }
        guard repairsStoredRoutes else { return }
        UserDefaults.standard.set(
            Self.diagnosticSummaryVersion,
            forKey: Self.diagnosticSummaryVersionKey)
    }
}
