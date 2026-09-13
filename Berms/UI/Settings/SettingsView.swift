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

    var body: some View {
        NavigationStack {
            Form {
                Section("Trail catalog") {
                    NavigationLink {
                        TrailLibraryView()
                    } label: {
                        Label("Trail Library", systemImage: "map")
                    }

                    Picker("Resort", selection: Binding(
                        get: { trailCatalogSelection.selectionID },
                        set: { trailCatalogSelection.setSelectionID($0) }
                    )) {
                        Text("Automatic").tag(TrailCatalogRegistry.automaticSelectionID)
                        ForEach(TrailCatalogRegistry.catalogs) { catalog in
                            Text(catalog.resortName).tag(catalog.id)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(trailCatalogSelection.isAutomatic
                         ? "Automatic chooses the nearest bundled resort from GPS."
                         : "Using this resort until you switch back to Automatic.")
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
                    Toggle("Raw motion logging", isOn: Binding(
                        get: { recorder.rawMotionLoggingEnabled },
                        set: { recorder.setRawMotionLoggingEnabled($0) }
                    ))
                    .tint(.green)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Keeps high-rate motion samples with each ride so sessions can be re-analyzed. Uses extra storage and is off by default.")
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
