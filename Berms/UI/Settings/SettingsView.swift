import MapKit
import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var recorder: RideRecorder
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var trailCatalogSelection: TrailCatalogSelection

    private var sensitivityBinding: Binding<JumpSensitivity> {
        Binding(
            get: { recorder.jumpSensitivity },
            set: { recorder.setJumpSensitivity($0) }
        )
    }

    private var liveActivityMetricBinding: Binding<BermsLiveActivityMetric> {
        Binding(
            get: { recorder.liveActivityMetric },
            set: { recorder.setLiveActivityMetric($0) }
        )
    }

    private var correctionsSharingBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: CorrectionsSharing.key) },
            set: { UserDefaults.standard.set($0, forKey: CorrectionsSharing.key) })
    }

    private var resortSelectionBinding: Binding<String> {
        Binding(
            get: { trailCatalogSelection.selectionID },
            set: { trailCatalogSelection.setSelectionID($0) }
        )
    }

    private var liveStatBinding: (LiveStatMetric) -> Binding<Bool> {
        { metric in
            Binding(
                get: { recorder.liveStatMetrics.contains(metric) },
                set: { recorder.setLiveStatMetric(metric, enabled: $0) }
            )
        }
    }

    private var rawMotionLoggingBinding: Binding<Bool> {
        Binding(
            get: { recorder.rawMotionLoggingEnabled },
            set: { recorder.setRawMotionLoggingEnabled($0) }
        )
    }

    private var jumpDetectionFooter: String {
        let configuration = recorder.jumpSensitivity.configuration
        let airtime = String(format: "%.2f", configuration.minimumAirtime)
        let speed = String(format: "%.1f", configuration.minimumRidingSpeed)
        return "Detects \(airtime) s of air at \(speed) m/s or faster."
    }

    private var selectedCatalog: TrailCatalogDescriptor? {
        trailCatalogSelection.manualCatalogID.flatMap(TrailCatalogRegistry.catalog(withID:))
    }

    /// Resorts that ship trails for the season the rider is in, plus a resort
    /// they picked earlier so the menu can still show that selection.
    private var selectableCatalogs: [TrailCatalogDescriptor] {
        let mode = recorder.activeActivityMode
        var catalogs = TrailCatalogRegistry.catalogs.filter { $0.season == mode.season }
        if let selectedCatalog, !catalogs.contains(where: { $0.id == selectedCatalog.id }) {
            catalogs.append(selectedCatalog)
        }
        return catalogs
    }

    private var catalogCaption: String {
        guard let selectedCatalog else {
            return "Matches trails from GPS."
        }
        guard selectedCatalog.season == recorder.activeActivityMode.season else {
            return "No \(recorder.activeActivityMode.title.lowercased()) trails here; Automatic is used."
        }
        return "Using this resort until you switch back."
    }

    var body: some View {
        NavigationStack {
            Form {
                trailsSection
                trackScreenSection
                liveActivitySection
                jumpDetectionSection
                correctionsSection
                diagnosticsSection
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About Berms Beta", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationSubtitle("Beta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var trailsSection: some View {
        Section {
            NavigationLink {
                TrailLibraryView()
            } label: {
                Label("Trail Library", systemImage: "map")
            }
            Picker("Resort", selection: resortSelectionBinding) {
                Text("Automatic").tag(TrailCatalogRegistry.automaticSelectionID)
                ForEach(selectableCatalogs) { catalog in
                    Text(catalog.resortName).tag(catalog.id)
                }
            }
            .pickerStyle(.menu)
            Text(catalogCaption)
                .font(.caption)
                .foregroundStyle(Color.bermsMuted)
        } header: {
            Text("Trails")
        }
    }

    private var trackScreenSection: some View {
        Section {
            ForEach(LiveStatMetric.allCases) { metric in
                Toggle(metric.title, isOn: liveStatBinding(metric))
                    .tint(Color.bermsSwitch)
                    .disabled(
                        !recorder.liveStatMetrics.contains(metric)
                            && recorder.liveStatMetrics.count >= LiveStatMetric.selectionLimit
                    )
            }
        } header: {
            Text("Track screen")
        } footer: {
            Text("Up to \(LiveStatMetric.selectionLimit) stats. Status, Pause, and Finish always show.")
        }
    }

    private var liveActivitySection: some View {
        Section {
            Picker("Right field", selection: liveActivityMetricBinding) {
                ForEach(BermsLiveActivityMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Live Activity")
        } footer: {
            Text("Right side of the Dynamic Island while recording.")
        }
    }

    private var jumpDetectionSection: some View {
        Section {
            Picker("Sensitivity", selection: sensitivityBinding) {
                ForEach(JumpSensitivity.allCases) { sensitivity in
                    Text(sensitivity.title).tag(sensitivity)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Jump detection")
        } footer: {
            Text(jumpDetectionFooter)
        }
    }

    private var correctionsSection: some View {
        Section {
            Toggle("Include corrections in exports", isOn: correctionsSharingBinding)
                .tint(Color.bermsSwitch)
        } header: {
            Text("Corrections")
        } footer: {
            Text("Corrections stay on this phone unless exported.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Toggle("Raw motion logging", isOn: rawMotionLoggingBinding)
                .tint(Color.bermsSwitch)
            #if DEBUG
                NavigationLink {
                    DayArchiveImportView()
                } label: {
                    Label("Import day export", systemImage: "square.and.arrow.down")
                }
            #endif
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Saves motion samples for re-analysis. Uses more storage.")
        }
    }
}

private struct AboutView: View {
    var body: some View {
        Form {
            if let identity = BuildIdentity.current {
                Section {
                    VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                        Text("Build")
                        Text(verbatim: identity.shortCommit)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if identity.hasLocalChanges {
                            Text("Local changes")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                        Text("Built")
                        Text(identity.builtAt, format: .dateTime.year().month().day().hour().minute().second())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)

                    ShareLink("Share Build Details", item: identity.shareText)
                }
            } else {
                Section {
                    Text("Build details unavailable")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("About Berms Beta")
        .navigationBarTitleDisplayMode(.inline)
    }
}
