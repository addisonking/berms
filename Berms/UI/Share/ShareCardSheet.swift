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
    @State private var previewMapImage: UIImage?
    @State private var exportURL: URL?
    @State private var mapUnavailable = false
    @State private var isRendering = false
    @State private var renderTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var showingSaved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var saveErrorMessage: String?
    @State private var savedFeedbackTask: Task<Void, Never>?

    private let snapshotter = MapKitShareSnapshotter()

    private var renderKey: String {
        "\(day.id.uuidString)|\(base?.mapSegments.count ?? -1)|\(trailDetails?.overlays.count ?? -1)"
    }

    private var availableStats: [ShareStatKind] {
        ShareCardContentBuilder.availableStats(day: day, base: base)
    }

    private var selectedStats: [ShareStatKind] {
        ShareCardContentBuilder.selectedStats(day: day, base: base, configuration: configuration)
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

                if availableStats.count > 1 {
                    Section {
                        ForEach(availableStats) { kind in
                            statToggle(kind)
                        }
                    } header: {
                        Text("Stats")
                    } footer: {
                        Text("Choose up to \(ShareCardConfiguration.maximumStats).")
                    }
                }

                if content?.hasRoute == true {
                    Section("Map") {
                        Toggle("Include map", isOn: $configuration.showsMap)
                            .tint(Color.bermsSwitch)
                        if configuration.showsMap {
                            Picker("Map style", selection: $configuration.mapStyle) {
                                ForEach(ShareCardMapStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            if !(trailDetails?.overlays ?? []).isEmpty {
                                Toggle("Trail names", isOn: $configuration.showsTrails)
                                    .tint(Color.bermsSwitch)
                            }
                            if !(base?.jumpMarkers ?? []).isEmpty {
                                Toggle("Jump markers", isOn: $configuration.showsJumps)
                                    .tint(Color.bermsSwitch)
                            }
                        }
                    }
                }

                Section("Branding") {
                    Toggle("Berms watermark", isOn: $configuration.showsWatermark)
                        .tint(Color.bermsSwitch)
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
        GeometryReader { proxy in
            let canvasSize = configuration.preset.canvasSize
            let scale = min(
                proxy.size.width / canvasSize.width,
                proxy.size.height / canvasSize.height)
            ZStack {
                if let content {
                    ShareCardCanvas(
                        content: content,
                        configuration: configuration,
                        mapImage: previewMapImage
                    )
                    .scaleEffect(scale)
                    .frame(width: canvasSize.width * scale, height: canvasSize.height * scale)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(content.accessibilitySummary)
                } else {
                    RoundedRectangle(cornerRadius: BermsSpacing.compact, style: .continuous)
                        .fill(Color.bermsInset)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .scaleEffect(scale)
                        .frame(width: canvasSize.width * scale, height: canvasSize.height * scale)
                        .overlay {
                            ProgressView()
                        }
                }
            }
        }
        .frame(height: min(420, configuration.preset.canvasSize.height))
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
        .animation(reduceMotion ? nil : BermsMotion.content, value: showingSaved)
    }

    private func statToggle(_ kind: ShareStatKind) -> some View {
        Button {
            var updated = configuration
            updated.stats = selectedStats
            updated.toggleStat(kind)
            configuration = updated
        } label: {
            HStack {
                Text(kind.title)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedStats.contains(kind) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .disabled(
            selectedStats.contains(kind)
                ? selectedStats.count <= 1
                : selectedStats.count >= ShareCardConfiguration.maximumStats
        )
        .accessibilityAddTraits(selectedStats.contains(kind) ? [.isSelected] : [])
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
        previewMapImage = nil

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
        previewMapImage = mapImage

        guard
            let image = ShareCardRenderer.render(
                content: content,
                configuration: configuration,
                mapImage: mapImage)
        else {
            isRendering = false
            return
        }

        mapUnavailable = unavailable
        exportURL = try? ShareCardRenderer.writePNG(
            image,
            fileName: ShareCardRenderer.fileName(
                content: content,
                preset: configuration.preset,
                date: day.startedAt))
        if let exportURL, let exportedImage = UIImage(contentsOfFile: exportURL.path) {
            previewImage = exportedImage
        } else {
            previewImage = image
        }
        isRendering = false
    }
}
