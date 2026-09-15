import AppIntents
import Foundation

struct ToggleBermsPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Session"

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: Notification.Name("berms.liveActivity.togglePause"),
            object: nil
        )
        return .result()
    }
}
