import MapKit
import SwiftData
import SwiftUI
import UIKit

struct RootView: View {
    private enum Tab: Hashable {
        case track
        case days
    }

    @ObservedObject var recorder: RideRecorder
    @StateObject private var mapLayerPreferences = MapLayerPreferences()
    @StateObject private var trailCatalogSelection = TrailCatalogSelection()
    @State private var selectedTab: Tab = .track
    @State private var pendingDayID: UUID?
    @State private var startupIssue: StartupIssue? = RootView.initialStartupIssue()

    private struct StartupIssue: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private static func initialStartupIssue() -> StartupIssue? {
        if let issue = PersistenceController.shared.storeIssue {
            return StartupIssue(title: "Storage problem", message: issue.message)
        }
        if let issue = PersistenceController.shared.catalogImportIssue {
            return StartupIssue(title: "Trail import problem", message: issue)
        }
        return nil
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TrackView(recorder: recorder) { day in
                pendingDayID = day.id
                selectedTab = .days
            }
            .tabItem { Label("Track", systemImage: "location.fill") }
            .tag(Tab.track)
            DaysView(pendingDayID: $pendingDayID) {
                selectedTab = .track
            }
                .tabItem { Label("Days", systemImage: "calendar") }
                .tag(Tab.days)
        }
        .tint(.bermsTrail)
        .environmentObject(mapLayerPreferences)
        .environmentObject(trailCatalogSelection)
        .onAppear { recorder.resumeIfNeeded() }
        .onOpenURL { url in
            guard url.scheme == "berms", url.host == "track" else { return }
            selectedTab = .track
            recorder.handleLiveActivityOpen()
        }
        .alert(item: $startupIssue) { issue in
            Alert(title: Text(issue.title),
                  message: Text(issue.message),
                  dismissButton: .cancel(Text("OK")))
        }
    }
}
