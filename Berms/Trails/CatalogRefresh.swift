import Combine
import Foundation
import SwiftData

@MainActor
final class CatalogRefresh: ObservableObject {
    static let shared = CatalogRefresh()
    static let discoveryURL =
        "https://github.com/addisonking/berms/releases/download/trail-catalog-latest/catalog-manifest.json"
    @Published private(set) var isRefreshing = false
    @Published var message: String?

    var captureIsBusy: Bool {
        RideRecorder.shared.isRecording || LocationCapture.shared.consumerCount > 0
    }

    func refresh(from url: URL, context: ModelContext) async {
        guard !isRefreshing, !captureIsBusy else {
            message = "Finish riding and surveying before updating catalogs."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
            let (manifest, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let snapshot = try JSONDecoder().decode(CatalogSnapshot.self, from: manifest)
            guard snapshot.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
            var packages: [String: Data] = [:]
            for catalog in snapshot.catalogs {
                guard let packageURL = URL(string: catalog.url, relativeTo: url)?.absoluteURL,
                    packageURL.scheme == "https"
                else { throw URLError(.unsupportedURL) }
                let (data, response) = try await URLSession.shared.data(from: packageURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                packages[catalog.id] = data
            }
            guard !captureIsBusy else { throw CocoaError(.userCancelled) }
            let store = CatalogSnapshotStore.shared
            _ = try store.validate(manifest: manifest, packages: packages)
            let descriptors = try ResortCatalogLoader.decode(manifest).catalogs
            // Persist user work before beginning a catalog-only transaction.
            try context.save()
            do {
                try store.withActivatedSnapshot(manifest: manifest, packages: packages) {
                    for catalog in descriptors {
                        guard let data = packages[catalog.id] else { throw CocoaError(.fileReadCorruptFile) }
                        _ = try TrailCatalogImporter.import(
                            data: data, into: context, catalog: catalog, approvedGeometry: true, saveChanges: false)
                    }
                    try context.save()
                }
            } catch {
                context.rollback()
                throw error
            }
            for catalog in descriptors { TrailCatalogImporter.markImported(catalog, defaults: .standard) }
            TrailGeometryStore.shared.invalidateAll()
            message = "Catalogs updated. Revision \(snapshot.revision.prefix(12))."
        } catch {
            message = "Catalog update failed: \(error.localizedDescription). The previous download remains available."
        }
    }
}
