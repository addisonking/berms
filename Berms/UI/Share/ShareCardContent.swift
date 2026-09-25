import Foundation

struct ShareCardStat: Identifiable, Equatable {
    let kind: ShareStatKind
    let value: String

    var id: String { kind.rawValue }
    var title: String { kind.title }
    var shortTitle: String { kind.shortTitle }
}

struct ShareCardMapRoute: Identifiable {
    let id: UUID
    let kind: SegmentKind
    let points: [RoutePoint]
    let opacity: Double
}

struct ShareCardContent {
    let resortName: String
    /// Custom day name when the rider set one, otherwise the resort name.
    let title: String
    /// Resort and date line shown under the title.
    let meta: String
    let stats: [ShareCardStat]
    let routes: [ShareCardMapRoute]
    let jumps: [SessionDetailJumpMarker]
    let trails: [TrailMapOverlay]

    var hasRoute: Bool {
        routes.contains { $0.points.count > 1 }
    }

    var accessibilitySummary: String {
        var parts = [title, meta]
        parts.append(contentsOf: stats.map { "\($0.title) \($0.value)" })
        return parts.joined(separator: ". ")
    }
}

enum ShareCardContentBuilder {
    static func build(
        day: RideDay,
        base: SessionDetailBase?,
        trailDetails: SessionDetailTrailDetails?,
        manualCatalogID: String?,
        configuration: ShareCardConfiguration
    ) -> ShareCardContent {
        let resortName = resolveResortName(day: day, base: base, manualCatalogID: manualCatalogID)
        let dateText = day.startedAt.formatted(date: .abbreviated, time: .omitted)
        let customName =
            day.hasCustomName
            ? day.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let title = customName.flatMap { $0.isEmpty ? nil : $0 } ?? resortName
        let meta = customName == nil ? dateText : "\(resortName) · \(dateText)"

        let values = statValues(day: day, base: base)
        let stats = selectedStats(day: day, base: base, configuration: configuration).compactMap {
            kind -> ShareCardStat? in
            guard let value = values[kind] else { return nil }
            return ShareCardStat(kind: kind, value: value)
        }

        let runs = base?.runs ?? []
        let lifts = (base?.mapSegments ?? []).filter { $0.kind == .lift }
        let routes =
            runs.enumerated().map { index, segment in
                ShareCardMapRoute(
                    id: segment.id,
                    kind: .run,
                    points: segment.routePoints,
                    opacity: RideMapPresentation.summaryRunOpacity(index: index, count: runs.count))
            }
            + lifts.map { segment in
                ShareCardMapRoute(id: segment.id, kind: .lift, points: segment.routePoints, opacity: 0.75)
            }

        return ShareCardContent(
            resortName: resortName,
            title: title,
            meta: meta,
            stats: stats,
            routes: routes,
            jumps: base?.summaryJumpMarkers ?? [],
            trails: (trailDetails?.overlays ?? []).map(TrailMapOverlay.init(detail:))
        )
    }

    static func availableStats(day: RideDay, base: SessionDetailBase?) -> [ShareStatKind] {
        let runCount = day.segments.filter { $0.kind == .run }.count
        var available: Set<ShareStatKind> = []
        if day.descentMeters > 0 { available.insert(.descent) }
        if day.distanceMeters > 0 { available.insert(.distance) }
        if day.duration > 0 { available.insert(.duration) }
        if runCount > 0 { available.insert(.runs) }
        if day.maximumSpeedMetersPerSecond > 0 { available.insert(.topSpeed) }
        if (base?.jumpCount ?? day.jumpCount) > 0 { available.insert(.jumps) }
        if day.activeSeconds > 0 { available.insert(.ridingTime) }
        if day.liftSeconds > 0 { available.insert(.liftTime) }
        return ShareStatKind.allCases.filter { available.contains($0) }
    }

    static func selectedStats(
        day: RideDay,
        base: SessionDetailBase?,
        configuration: ShareCardConfiguration
    ) -> [ShareStatKind] {
        let available = availableStats(day: day, base: base)
        let selected = configuration.stats.filter { available.contains($0) }
        if !selected.isEmpty { return selected }
        if available.contains(.duration) { return [.duration] }
        return Array(available.prefix(ShareCardConfiguration.maximumStats))
    }

    private static func resolveResortName(
        day: RideDay,
        base: SessionDetailBase?,
        manualCatalogID: String?
    ) -> String {
        if let catalog = day.catalogID.flatMap(TrailCatalogRegistry.catalog(withID:)) {
            return catalog.resortName
        }
        if let active = base?.runs.first?.activeResort, !active.isEmpty {
            return active
        }
        if let manualCatalogID,
            let catalog = TrailCatalogRegistry.catalog(withID: manualCatalogID)
        {
            return catalog.resortName
        }
        return day.activityMode == .ski ? "Unknown ski area" : "Unknown bike park"
    }

    private static func statValues(day: RideDay, base: SessionDetailBase?) -> [ShareStatKind: String] {
        let runCount = day.segments.filter { $0.kind == .run }.count
        return [
            .descent: BermsFormat.elevation(day.descentMeters),
            .distance: BermsFormat.distance(day.distanceMeters),
            .duration: BermsFormat.duration(day.duration),
            .runs: "\(runCount)",
            .topSpeed: BermsFormat.speed(day.maximumSpeedMetersPerSecond),
            .jumps: "\(base?.jumpCount ?? day.jumpCount)",
            .ridingTime: BermsFormat.duration(day.activeSeconds),
            .liftTime: BermsFormat.duration(day.liftSeconds),
        ]
    }
}
