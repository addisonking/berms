#if DEBUG

    import Foundation
    import SwiftData
    import SwiftUI

    struct DayArchiveImportView: View {
        @Environment(\.modelContext) private var modelContext
        @State private var files: [DayArchiveFile] = []
        @State private var importingURL: URL?
        @State private var outcome: ImportOutcome?
        var onImported: (RideDay) -> Void = { _ in }

        var body: some View {
            List {
                if files.isEmpty {
                    ContentUnavailableView(
                        "No day archives",
                        systemImage: "tray",
                        description: Text(
                            "Copy a Berms-<dayID>-data.json file into the app's Documents folder, then pull to refresh."
                        )
                    )
                } else {
                    ForEach(files) { file in
                        Button {
                            importArchive(file)
                        } label: {
                            row(for: file)
                        }
                        .disabled(importingURL != nil)
                        .accessibilityHint("Imports this day into your library")
                    }
                }
            }
            .refreshable { reload() }
            .task { reload() }
            .navigationTitle("Import Day Archive")
            .alert(
                outcome?.title ?? "",
                isPresented: Binding(
                    get: { outcome != nil },
                    set: { if !$0 { outcome = nil } }
                )
            ) {
                Button("OK", role: .cancel) { outcome = nil }
            } message: {
                Text(outcome?.message ?? "")
            }
        }

        private func row(for file: DayArchiveFile) -> some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if importingURL == file.url {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }

        private func reload() {
            files = DayArchiveFile.loadFromDocuments()
        }

        private func importArchive(_ file: DayArchiveFile) {
            guard importingURL == nil else { return }
            importingURL = file.url
            defer { importingURL = nil }
            do {
                let day = try DayArchiveImporter.importDay(from: file.url, context: modelContext)
                let runCount = day.segments.filter { $0.kind == .run }.count
                outcome = .success(name: day.displayName, runCount: runCount)
                onImported(day)
                reload()
            } catch {
                outcome = .failure(message: error.localizedDescription)
            }
        }
    }

    private struct DayArchiveFile: Identifiable {
        let url: URL
        let modifiedAt: Date

        var id: URL { url }
        var name: String { url.lastPathComponent }

        static func loadFromDocuments() -> [DayArchiveFile] {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles])
            else { return [] }
            var files: [DayArchiveFile] = []
            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasSuffix("-data.json") else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                files.append(DayArchiveFile(url: url, modifiedAt: values?.contentModificationDate ?? .distantPast))
            }
            return files.sorted { $0.modifiedAt > $1.modifiedAt }
        }
    }

    private enum ImportOutcome: Identifiable {
        case success(name: String, runCount: Int)
        case failure(message: String)

        var id: String {
            switch self {
            case .success(let name, let runCount): "success-\(name)-\(runCount)"
            case .failure(let message): "failure-\(message)"
            }
        }

        var title: String {
            switch self {
            case .success: "Imported"
            case .failure: "Couldn't import"
            }
        }

        var message: String {
            switch self {
            case .success(let name, let runCount):
                "\(name) with \(runCount) run\(runCount == 1 ? "" : "s")."
            case .failure(let message):
                message
            }
        }
    }

#endif
