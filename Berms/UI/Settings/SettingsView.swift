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
            return "Automatic matches trails for the resort you are riding in, from GPS."
        }
        guard selectedCatalog.season == recorder.activeActivityMode.season else {
            return
                "This resort has no \(recorder.activeActivityMode.title.lowercased()) trails, so Automatic is used instead."
        }
        return "Using this resort until you switch back to Automatic."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trail catalog") {
                    NavigationLink {
                        TrailLibraryView()
                    } label: {
                        Label("Trail Library", systemImage: "map")
                    }

                    Picker(
                        "Resort",
                        selection: Binding(
                            get: { trailCatalogSelection.selectionID },
                            set: { trailCatalogSelection.setSelectionID($0) }
                        )
                    ) {
                        Text("Automatic").tag(TrailCatalogRegistry.automaticSelectionID)
                        ForEach(selectableCatalogs) { catalog in
                            Text(catalog.resortName).tag(catalog.id)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(catalogCaption)
                        .font(.caption)
                        .foregroundStyle(Color.bermsMuted)
                }
                Section("Jump detection") {
                    Picker("Sensitivity", selection: sensitivityBinding) {
                        ForEach(JumpSensitivity.allCases) { sensitivity in
                            VStack(alignment: .leading) {
                                Text(sensitivity.title)
                                Text(sensitivity.detail)
                                    .font(.caption)
                            }
                            .tag(sensitivity)
                        }
                    }
                    .pickerStyle(.inline)
                }
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
                    Text("Shown at the right of the Live Activity and Dynamic Island while recording.")
                }
                Section {
                    ForEach(LiveStatMetric.allCases) { metric in
                        Toggle(
                            metric.title,
                            isOn: Binding(
                                get: { recorder.liveStatMetrics.contains(metric) },
                                set: { recorder.setLiveStatMetric(metric, enabled: $0) }
                            )
                        )
                        .tint(.green)
                        .disabled(
                            !recorder.liveStatMetrics.contains(metric)
                                && recorder.liveStatMetrics.count >= LiveStatMetric.selectionLimit
                        )
                    }
                } header: {
                    Text("Live tracking panel")
                } footer: {
                    Text(
                        "Choose up to \(LiveStatMetric.selectionLimit) stats for the Track screen while recording. Run status, GPS status, Pause, and Finish always appear."
                    )
                }
                Section {
                    Toggle(
                        "Raw motion logging",
                        isOn: Binding(
                            get: { recorder.rawMotionLoggingEnabled },
                            set: { recorder.setRawMotionLoggingEnabled($0) }
                        )
                    )
                    .tint(.green)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text(
                        "Keeps high-rate motion samples with each ride so sessions can be re-analyzed. Uses extra storage and is off by default."
                    )
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
}
