import SwiftUI
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let locationLaunchOptionKey = UIApplication.LaunchOptionsKey(
        rawValue: "UIApplicationLaunchOptionsLocationKey"
    )

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let autoResume = launchOptions?[Self.locationLaunchOptionKey] != nil
        // A location relaunch belongs to the same ride. Keep its existing
        // Live Activity so restoration cannot race a blanket cleanup.
        if !autoResume {
            BermsLiveActivityCoordinator.shared.endAll()
        }
        RideRecorder.shared.resumeIfNeeded(autoResume: autoResume)
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        RideRecorder.shared.appDidEnterBackground()
        #if DEBUG
            TrailMapper.shared.stopIfIdle()
            TrailSurveyStore.shared.checkpoint()
        #endif
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Best-effort cleanup for a normal process termination. The background
        // callback above handles the usual app-switcher force-close path.
        RideRecorder.shared.locationService.stop()
        BermsLiveActivityCoordinator.shared.endAll()
        #if DEBUG
            TrailMapper.shared.locationService.stop()
            TrailSurveyStore.shared.locationService.stop()
        #endif
    }
}

@main
struct BermsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = RideRecorder.shared

    var body: some Scene {
        WindowGroup {
            RootView(recorder: recorder)
        }
        .modelContainer(PersistenceController.shared.container)
    }
}
