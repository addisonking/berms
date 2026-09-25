import MapKit
import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var recorder: RideRecorder
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        NavigationStack {
            Form {
                trackScreenSection
                liveActivitySection
                jumpDetectionSection
                correctionsSection
                dataSection
                #if DEBUG
                    developerSection
                #endif
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About Berms Beta", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    #if DEBUG
        private var developerSection: some View {
            Section {
                NavigationLink {
                    TrailLibraryView()
                } label: {
                    Label("Trail catalog", systemImage: "map")
                }
            } header: {
                Text("Developer")
            }
        }
    #endif

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
            Picker("Detail stat", selection: liveActivityMetricBinding) {
                ForEach(BermsLiveActivityMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Live Activity")
        } footer: {
            Text(
                "Shown in the expanded Dynamic Island and on the Lock Screen. The compact Dynamic Island always shows the run count on the right and a mountain icon while active or a pause icon while paused on the left."
            )
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
            Text("More sensitive catches smaller jumps. Less sensitive filters small bumps.")
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

    private var dataSection: some View {
        Section {
            Toggle("Detailed ride logs", isOn: rawMotionLoggingBinding)
                .tint(Color.bermsSwitch)
        } header: {
            Text("Data")
        } footer: {
            Text("Includes location and movement details in day exports for support. Uses more storage.")
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
