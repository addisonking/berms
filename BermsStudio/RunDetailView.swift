import SwiftUI

@MainActor
struct RunDetailView: View {
    let library: StudioLibrary
    let run: RunRef

    private var session: StudioSession? { library.session(id: run.sessionID) }
    private var segment: StudioSegment? { library.run(for: run) }

    var body: some View {
        if let session, let segment {
            let clips = library.clips(forRun: segment, in: session)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(clipCount: clips.count)
                    stats(for: segment)
                    trails(for: segment)
                    clipSection(
                        title: "Clips (\(clips.count))", clips: clips,
                        emptyText: "No footage matched this run.")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(run.title)
        } else {
            ContentUnavailableView("Run not found", systemImage: "questionmark.circle")
        }
    }

    private func header(clipCount: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(run.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(run.subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                export()
            } label: {
                Label("Export video", systemImage: "film.stack")
            }
            .buttonStyle(.borderedProminent)
            .disabled(clipCount == 0 || library.busy != nil)
        }
    }

    private func stats(for segment: StudioSegment) -> some View {
        HStack(alignment: .top, spacing: 32) {
            stat("Time", StudioFormat.duration(segment.duration))
            stat("Distance", StudioFormat.distance(segment.distanceMeters))
            stat("Vert", StudioFormat.vertical(segment.verticalMeters))
            stat("Max speed", StudioFormat.speed(segment.maximumSpeedMetersPerSecond))
            stat("Jumps", "\(segment.jumps.count)")
        }
    }

    private func trails(for segment: StudioSegment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trails").font(.headline)
            if segment.trails.isEmpty {
                Text("No catalog match for this run").foregroundStyle(.secondary)
            } else {
                Text(segment.trails.joined(separator: " → "))
            }
        }
    }

    private func clipSection(title: String, clips: [Clip], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if clips.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(clips) { clip in
                        ClipRow(clip: clip)
                        if clip.id != clips.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .monospacedDigit()
        }
    }

    private func export() {
        guard let plan = library.exportPlan(for: run) else {
            library.message = "No footage matched this run"
            library.messageIsError = true
            return
        }

        let operationID = library.startExport(
            total: 1,
            activeItems: [StudioExportItemProgress(id: plan.id, title: plan.title, fraction: 0)]
        )
        let reportProgress: @Sendable (Double) -> Void = { [library] fraction in
            Task { @MainActor in
                library.updateExportItemProgress(fraction, itemID: plan.id, for: operationID)
            }
        }
        Task {
            do {
                try await Task.detached {
                    try FfmpegStitcher.concat(
                        clips: plan.clips, output: plan.output,
                        estimatedDuration: plan.estimatedDuration,
                        trimStart: plan.trimStart, trimEnd: plan.trimEnd,
                        progress: reportProgress)
                }.value
                library.completeExportItem(plan.id, succeeded: true, for: operationID)
                library.message =
                    "Exported \(plan.output.lastPathComponent) → \(plan.output.deletingLastPathComponent().path)"
                library.messageIsError = false
            } catch {
                library.completeExportItem(plan.id, succeeded: false, for: operationID)
                library.message = "Export failed: \(error.localizedDescription)"
                library.messageIsError = true
            }
            library.finishExport(operationID)
        }
    }
}
