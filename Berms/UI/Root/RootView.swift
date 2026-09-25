import MapKit
import SwiftData
import SwiftUI
import UIKit

struct RootView: View {
    private enum AppTab: Hashable {
        case track
        case days
    }

    @ObservedObject var recorder: RideRecorder
    @ObservedObject private var persistence = PersistenceController.shared
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var mapLayerPreferences = MapLayerPreferences()
    @State private var selectedTab: AppTab = .track
    @State private var pendingDayID: UUID?
    @State private var pendingRecapDayID: UUID?
    @State private var startupIssue: StartupIssue? = RootView.initialStartupIssue()

    private struct StartupIssue: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private static let storageProblemTitle = "Storage problem"
    private static let trailImportProblemTitle = "Trail import problem"

    private static func initialStartupIssue() -> StartupIssue? {
        if let issue = PersistenceController.shared.storeIssue {
            return StartupIssue(title: storageProblemTitle, message: issue.message)
        }
        if let issue = PersistenceController.shared.catalogImportIssue {
            return StartupIssue(title: trailImportProblemTitle, message: issue)
        }
        return nil
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Track", systemImage: "location.fill", value: AppTab.track) {
                TrackView(recorder: recorder) { day in
                    pendingDayID = day.id
                    pendingRecapDayID = day.id
                    selectedTab = .days
                }
            }
            Tab("Days", systemImage: "calendar", value: AppTab.days) {
                DaysView(pendingDayID: $pendingDayID, pendingRecapDayID: $pendingRecapDayID) {
                    selectedTab = .track
                }
            }
        }
        .tint(.bermsTrail)
        .environmentObject(mapLayerPreferences)
        .onAppear { recorder.resumeIfNeeded() }
        // SwiftUI's scene lifecycle does not call the app delegate's
        // applicationDidEnterBackground, so route it through the scene phase.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                recorder.appDidEnterBackground()
            }
        }
        .onOpenURL { url in
            guard url.scheme == "berms", url.host == "track" else { return }
            selectedTab = .track
            recorder.handleLiveActivityOpen()
        }
        .onChange(of: persistence.catalogImportIssue) { _, issue in
            // The catalog import runs after launch, so its failure arrives late.
            // Never replace an alert the rider has not dismissed yet.
            guard let issue, startupIssue == nil else { return }
            startupIssue = StartupIssue(title: Self.trailImportProblemTitle, message: issue)
        }
        .alert(item: $startupIssue) { issue in
            Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                dismissButton: .cancel(Text("OK")))
        }
    }
}
