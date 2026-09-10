import SwiftUI
import WatchKit
import HealthKit

@MainActor
final class BermsWatchDelegate: NSObject, WKExtensionDelegate {
    let model = WatchDashboardModel()

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        model.reconcileHealth()
    }
}

@main
struct BermsWatchApp: App {
    @WKExtensionDelegateAdaptor(BermsWatchDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchDashboardView(model: delegate.model)
        }
    }
}
