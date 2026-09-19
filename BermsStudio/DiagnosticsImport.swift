import Foundation

enum DiagnosticsImportError: LocalizedError {
    case unreadable(URL)
    case noSegments(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Couldn't read \(url.lastPathComponent)."
        case .noSegments(let url): "\(url.lastPathComponent) has no recordable ride segments."
        }
    }
}

/// Rebuilds a `StudioDay` from a Berms diagnostics `.jsonl` log using the same
/// detector replay and route cleaning the iOS app uses.
enum DiagnosticsImporter {
    static func loadDay(url: URL) throws -> StudioDay {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DiagnosticsImportError.unreadable(url)
        }

        let replay: DiagnosticReplayResult
        do {
            replay = try DiagnosticLogReplayer().replay(data: data)
        } catch {
            throw DiagnosticsImportError.unreadable(url)
        }
        guard !replay.segments.isEmpty else {
            throw DiagnosticsImportError.noSegments(url)
        }

        let dayID = dayID(for: url)
        let segments = replay.segments.enumerated().map { index, draft in
            makeSegment(draft, id: "\(dayID)-seg-\(index + 1)")
        }
        let startedAt = segments.map(\.startedAt).min() ?? .now
        let endedAt = segments.map(\.endedAt).max()

        return StudioDay(
            id: dayID, name: nil, startedAt: startedAt, endedAt: endedAt,
            segments: segments)
    }

    /// Day identifier encoded in a `Berms-<dayID>.jsonl` log filename.
    static func dayID(for url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
        return filename.hasPrefix("Berms-") ? String(filename.dropFirst(6)) : filename
    }

    /// Raw logs rebuild the original run boundaries, so days already covered by a
    /// parsed `*-data.json` export skip their logs and keep the parsed runs.
    static func rawLogs(_ urls: [URL], notCoveredBy parsedDayIDs: Set<String>) -> [URL] {
        let covered = Set(parsedDayIDs.map { $0.lowercased() })
        return urls.filter { !covered.contains(dayID(for: $0).lowercased()) }
    }

    private static func makeSegment(_ draft: SegmentDraft, id: String) -> StudioSegment {
        let cleaned = RouteCleaner().clean(draft.points).map(\.routePoint)
        let route = cleaned.count >= 2 ? cleaned : draft.routePoints
        return StudioSegment(
            id: id,
            kind: draft.kind,
            runNumber: draft.runNumber,
            startedAt: draft.startedAt,
            endedAt: draft.endedAt,
            distanceMeters: RouteMetrics.distance(of: route),
            verticalMeters: RouteMetrics.vertical(of: route, kind: draft.kind),
            maximumSpeedMetersPerSecond: RouteMetrics.maximumSpeed(of: route),
            route: route,
            jumps: draft.jumps,
            trails: draft.trailSequence ?? []
        )
    }
}
