import Foundation

enum ShareStatKind: String, CaseIterable, Codable, Identifiable {
    case descent
    case distance
    case duration
    case runs
    case topSpeed
    case jumps
    case ridingTime
    case liftTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .descent: "Descent"
        case .distance: "Distance"
        case .duration: "Time"
        case .runs: "Runs"
        case .topSpeed: "Top speed"
        case .jumps: "Jumps"
        case .ridingTime: "Riding time"
        case .liftTime: "Lift time"
        }
    }

    var shortTitle: String {
        switch self {
        case .descent: "VERTICAL"
        case .distance: "DISTANCE"
        case .duration: "TIME"
        case .runs: "RUNS"
        case .topSpeed: "TOP SPEED"
        case .jumps: "JUMPS"
        case .ridingTime: "RIDING"
        case .liftTime: "LIFT"
        }
    }

    static let defaultSelection: [ShareStatKind] = [.descent, .runs, .jumps, .liftTime]
}

enum ShareCardMapStyle: String, CaseIterable, Codable, Identifiable {
    case monochrome
    case standard
    case satellite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monochrome: "Monochrome"
        case .standard: "Standard"
        case .satellite: "Satellite"
        }
    }
}

struct ShareCardConfiguration: Equatable, Codable {
    static let maximumStats = 4

    var preset: ShareCardPreset = .story
    var stats: [ShareStatKind] = ShareStatKind.defaultSelection
    var showsMap = true
    var mapStyle: ShareCardMapStyle = .monochrome
    var showsTrails = false
    var showsJumps = false
    var showsWatermark = true

    mutating func toggleStat(_ kind: ShareStatKind) {
        if let index = stats.firstIndex(of: kind) {
            guard stats.count > 1 else { return }
            stats.remove(at: index)
        } else if stats.count < Self.maximumStats {
            stats.append(kind)
        }
    }

    func canToggleStat(_ kind: ShareStatKind) -> Bool {
        stats.contains(kind) ? stats.count > 1 : stats.count < Self.maximumStats
    }

    var normalized: ShareCardConfiguration {
        var copy = self
        if copy.stats.isEmpty { copy.stats = ShareStatKind.defaultSelection }
        return copy
    }
}

enum ShareCardConfigurationStore {
    static let key = "berms.shareCard.configuration"
    private static let legacyDefaultSelection: [ShareStatKind] = [.descent, .distance, .topSpeed, .runs]

    static func load(from defaults: UserDefaults = .standard) -> ShareCardConfiguration {
        guard let data = defaults.data(forKey: key),
            var configuration = try? JSONDecoder().decode(ShareCardConfiguration.self, from: data)
        else {
            return ShareCardConfiguration()
        }
        if configuration.stats == legacyDefaultSelection {
            configuration.stats = ShareStatKind.defaultSelection
        }
        return configuration.normalized
    }

    static func save(_ configuration: ShareCardConfiguration, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(configuration.normalized) else { return }
        defaults.set(data, forKey: key)
    }
}
