import SwiftUI

@main
struct BermsStudioApp: App {
    var body: some Scene {
        WindowGroup {
            StudioView()
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
