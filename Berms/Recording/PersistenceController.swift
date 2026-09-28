import Combine
import Foundation
import SwiftData

@MainActor
final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    struct StoreIssue: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    let container: ModelContainer
    private(set) var storeIssue: StoreIssue?
    @Published private(set) var catalogImportIssue: String?

    private init() {
        let schema = Schema([RideDay.self, RideSegment.self, Trail.self, TrailPass.self, LearnedLift.self])
        let configuration = ModelConfiguration("Berms", schema: schema, isStoredInMemoryOnly: false)

        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            self.container = container
            importCatalogs(in: container)
            return
        }

        let movedAside = Self.moveStoreAside()
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            self.container = container
            storeIssue = StoreIssue(
                message: movedAside
                    ? "Berms could not open its saved data, so it started fresh. The previous data was kept on this device."
                    : "Berms could not open its saved data, so it started fresh."
            )
            importCatalogs(in: container)
            return
        }

        let memoryConfiguration = ModelConfiguration("Berms", schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [memoryConfiguration]) else {
            fatalError("Could not create Berms storage schema")
        }
        self.container = container
        storeIssue = StoreIssue(
            message: "Berms could not open its saved data and is running without saving. Restart the app to try again."
        )
        importCatalogs(in: container)
    }

    /// Catalogs are imported on their own context off the main actor. A resort
    /// catalog is megabytes of geometry, so doing this during launch would
    /// stall the first frame.
    private func importCatalogs(in container: ModelContainer) {
        if let manifestError = TrailCatalogRegistry.manifestError {
            catalogImportIssue = manifestError
            print("Trail catalog import skipped: \(manifestError)")
            return
        }
        Task.detached(priority: .utility) { [weak self, container] in
            let context = ModelContext(container)
            do {
                for result in try TrailCatalogImporter.importCatalogsIfNeeded(into: context) {
                    print(
                        "Imported \(result.catalog.resortName) trails: "
                            + "\(result.summary.trailsCreated) trails, "
                            + "\(result.summary.passesCreated) passes")
                }
            } catch {
                print("Trail catalog import skipped: \(error.localizedDescription)")
                await MainActor.run {
                    self?.catalogImportIssue = "Trail catalog import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func moveStoreAside() -> Bool {
        let fileManager = FileManager.default
        guard
            let support = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        else {
            return false
        }
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        var movedAny = false
        for suffix in ["", "-shm", "-wal"] {
            let source = support.appendingPathComponent("Berms.store\(suffix)")
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = support.appendingPathComponent("Berms-recovered-\(stamp).store\(suffix)")
            do {
                try fileManager.moveItem(at: source, to: destination)
                movedAny = true
            } catch {
                print("Could not move store file \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return movedAny
    }
}
