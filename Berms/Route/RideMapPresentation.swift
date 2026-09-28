import Foundation

enum LiveMapPathRole: Equatable, Sendable {
    case previousRun
    case latestCompletedRun
    case activeSegment
}

struct LiveMapPath: Equatable, Sendable {
    let role: LiveMapPathRole
    let points: [RoutePoint]
}

enum RideMapPresentation {
    static func livePaths(
        activeKind: SegmentKind?,
        currentPath: [RoutePoint],
        completedRunPaths: [[RoutePoint]],
        showsPreviousRuns: Bool
    ) -> [LiveMapPath] {
        var paths: [LiveMapPath] = []
        if showsPreviousRuns {
            paths.append(
                contentsOf: completedRunPaths.filter { $0.count > 1 }.map {
                    LiveMapPath(role: .previousRun, points: $0)
                })
        }

        switch activeKind {
        case .run:
            if currentPath.count > 1 {
                paths.append(LiveMapPath(role: .activeSegment, points: currentPath))
            }
        case .lift:
            if let latest = completedRunPaths.last, latest.count > 1 {
                paths.append(LiveMapPath(role: .latestCompletedRun, points: latest))
            } else if currentPath.count > 1 {
                paths.append(LiveMapPath(role: .activeSegment, points: currentPath))
            }
        case .none:
            if currentPath.count > 1 {
                paths.append(LiveMapPath(role: .activeSegment, points: currentPath))
            }
        }
        return paths
    }

    static func summaryRunOpacity(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0.82 }
        let clampedIndex = min(max(index, 0), count - 1)
        return 0.28 + 0.54 * Double(clampedIndex) / Double(count - 1)
    }
}
