import SwiftUI
import UIKit

struct ShareCardSheet: View {
    let day: RideDay
    let base: SessionDetailBase?
    let trailDetails: SessionDetailTrailDetails?
    let manualCatalogID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var configuration = ShareCardConfigurationStore.load()
    @State private var content: ShareCardContent?
    @State private var previewImage: UIImage?
    @State private var exportURL: URL?
    @State private var mapUnavailable = false
    @State private var isRendering = false
    @State private var renderTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var showingSaved = false
    @State private var saveErrorMessage: String?
    @State private var savedFeedbackTask: Task<Void, Never>?

    private let snapshotter = MapKitShareSnapshotter()

    private var renderKey: String {
        "\(day.id.uuidString)|\(base?.mapSegments.count ?? -1)|\(trailDetails?.overlays.count ?? -1)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                } header: {
                    Text("Preview")
                } footer: {
                    if mapUnavailable {
                        Text("The map could not be captured right now. The card exports without it.")
                    } else {
                        Text("\(configuration.preset.detail) · \(configuration.preset.pixelDescription)")
                    }
                }

                Section("Format") {
                    Picker("Format", selection: $configuration.preset) {
                        ForEach(ShareCardPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(ShareStatKind.allCases) { kind in
                        statToggle(kind)
                    }
                } header: {
                    Text("Stats")
                } footer: {
                    Text("Choose up to \(ShareCardConfiguration.maximumStats).")
                }

                Section("Map") {
                    Toggle("Include map", isOn: $configuration.showsMap)
                        .tint(.green)
                    if configuration.showsMap {
                        Picker("Map style", selection: $configuration.mapStyle) {
                            ForEach(ShareCardMapStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        Toggle("Trail names", isOn: $configuration.showsTrails)
                            .tint(.green)
                            .disabled((trailDetails?.overlays ?? []).isEmpty)
                        Toggle("Jump markers", isOn: $configuration.showsJumps)
                            .tint(.green)
                            .disabled((base?.jumpMarkers ?? []).isEmpty)
                    }
                }

                Section("Branding") {
                    Toggle("Berms watermark", isOn: $configuration.showsWatermark)
                        .tint(.green)
                }
            }
            .navigationTitle("Share image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button {
                            saveToPhotos()
                        } label: {
                            Label("Save to Photos", systemImage: "photo.badge.arrow.down")
                        }
                        .disabled(isSaving)

                        Button {
                            share()
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        if isRendering {
                            ProgressView()
                        } else {
                            Text("Share")
                        }
                    }
                    .disabled(exportURL == nil || isRendering)
                }
            }
        }
        .task(id: renderKey) {
            await render(debounced: false)
        }
        .onChange(of: configuration) { _, newValue in
            ShareCardConfigurationStore.save(newValue)
            scheduleRender()
        }
        .onDisappear {
            renderTask?.cancel()
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .accessibilityLabel(content?.accessibilitySummary ?? "Share image preview")
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.bermsInset)
                    .frame(height: 320)
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .overlay(alignment: .bottom) {
            if showingSaved {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(BermsMotion.content, value: showingSaved)
    }

    private func statToggle(_ kind: ShareStatKind) -> some View {
        Button {
            configuration.toggleStat(kind)
        } label: {
            HStack {
                Text(kind.title)
                    .foregroundStyle(.primary)
                Spacer()
                if configuration.stats.contains(kind) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                }
            }
        }
        .disabled(!configuration.canToggleStat(kind))
        .accessibilityAddTraits(configuration.stats.contains(kind) ? [.isSelected] : [])
    }

    private func share() {
        guard let url = shareableExportURL() else { return }
        SharePresenter.present(fileURL: url)
    }

    /// A share item the system can no longer read makes every activity fail
    /// silently, so rewrite the export if the file went missing.
    private func shareableExportURL() -> URL? {
        guard let exportURL else { return nil }
        if FileManager.default.fileExists(atPath: exportURL.path) {
            return exportURL
        }
        guard let previewImage else { return nil }
        return try? ShareCardRenderer.writePNG(
            previewImage,
            fileName: exportURL.lastPathComponent)
    }

    private func saveToPhotos() {
        guard let exportURL, !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            do {
                try await ShareCardPhotos.savePNG(at: exportURL)
                isSaving = false
                announceSaved()
            } catch {
                isSaving = false
                saveErrorMessage = error.localizedDescription
            }
        }
    }

    private func announceSaved() {
        showingSaved = true
        savedFeedbackTask?.cancel()
        savedFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            showingSaved = false
        }
        UIAccessibility.post(notification: .announcement, argument: "Saved to Photos")
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            await render(debounced: true)
        }
    }

    @MainActor
    private func render(debounced: Bool) async {
        if debounced {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
        }

        isRendering = true
        let configuration = self.configuration
        let content = ShareCardContentBuilder.build(
            day: day,
            base: base,
            trailDetails: trailDetails,
            manualCatalogID: manualCatalogID,
            configuration: configuration)
        self.content = content

        var mapImage: UIImage?
        var unavailable = false
        if configuration.showsMap && content.hasRoute {
            let request = ShareMapSnapshotRequest(
                size: configuration.preset.mapFrameSize,
                scale: ShareCardPreset.renderScale,
                mapStyle: configuration.mapStyle,
                routes: content.routes,
                trails: configuration.showsTrails ? content.trails : [],
                jumps: configuration.showsJumps ? content.jumps : [])
            do {
                mapImage = try await snapshotter.snapshot(request)
            } catch is CancellationError {
                return
            } catch {
                unavailable = true
            }
        }
        guard !Task.isCancelled else { return }

        guard
            let image = ShareCardRenderer.render(
                content: content,
                configuration: configuration,
                mapImage: mapImage)
        else {
            isRendering = false
            return
        }

        previewImage = image
        mapUnavailable = unavailable
        exportURL = try? ShareCardRenderer.writePNG(
            image,
            fileName: ShareCardRenderer.fileName(
                content: content,
                preset: configuration.preset,
                date: day.startedAt))
        isRendering = false
    }
}
