import Darwin
import Foundation
import Observation

struct RunRef: Identifiable, Hashable {
    let sessionID: String
    let segmentID: String
    let runNumber: Int
    let title: String
    let subtitle: String

    var id: String { "\(sessionID)/\(segmentID)" }
}

struct ExportPlan: Identifiable, Sendable {
    let runID: String
    let title: String
    let output: URL
    let clips: [[URL]]
    let estimatedDuration: TimeInterval
    let trimStart: TimeInterval
    let trimEnd: TimeInterval

    var id: String { runID }
}

struct ClipRenameFile: Identifiable, Sendable {
    let source: URL
    let destination: URL

    var id: String { "\(source.path)→\(destination.path)" }
}

/// A session is one ride day rebuilt from a Berms log, plus the footage that
/// overlaps its runs by timestamp.
struct StudioSession: Identifiable {
    let id: String
    var day: StudioDay
    var offsetSeconds: Int
    var clipIndices: [Int]

    var runs: [StudioSegment] { day.runs }
    var title: String { day.name ?? StudioFormat.dayLabel(day.startedAt) }

    var subtitle: String {
        let runs = day.runs.count == 1 ? "1 run" : "\(day.runs.count) runs"
        let clips = clipIndices.count == 1 ? "1 clip" : "\(clipIndices.count) clips"
        return "\(runs) · \(clips)"
    }
}

enum SidebarItem: Hashable {
    case inbox
    case session(String)
}

struct StudioExportItemProgress: Equatable, Sendable {
    let id: String
    let title: String
    var fraction: Double
}

struct StudioExportProgress: Equatable, Sendable {
    var completed: Int
    var failed: Int
    let total: Int
    var activeItems: [StudioExportItemProgress]
    let startedAt: Date

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(workCompleted / Double(total), 0), 1)
    }

    func elapsed(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(startedAt))
    }

    func estimatedTimeRemaining(at date: Date) -> TimeInterval? {
        let totalWork = Double(total)
        guard workCompleted > 0, workCompleted < totalWork else {
            return workCompleted >= totalWork ? 0 : nil
        }
        let elapsed = elapsed(at: date)
        guard elapsed > 0 else { return nil }
        return max(0, elapsed * (totalWork - workCompleted) / workCompleted)
    }

    private var workCompleted: Double {
        Double(completed)
            + activeItems.reduce(0.0) { total, item in
                total + min(max(item.fraction, 0), 1)
            }
    }
}

private struct StudioExportAttempt: Sendable {
    let id: String
    let succeeded: Bool
}

@MainActor
@Observable
final class StudioLibrary {
    private(set) var days: [StudioDay] = []
    private(set) var clips: [Clip] = []
    private(set) var sessions: [StudioSession] = []
    private(set) var inboxClipIndices: [Int] = []
    private(set) var catalog: [TrailRouteCandidate] = []

    var outputRoot: URL
    var message = "Ready"
    var messageIsError = false
    var busy: String?
    private(set) var exportProgress: StudioExportProgress?

    private var offsets: [String: Int] = [:]
    private var outputDirectories: [String: URL] = [:]
    private var accessedScopes: Set<URL> = []
    private var trimStarts: [String: TimeInterval] = [:]
    private var trimEnds: [String: TimeInterval] = [:]
    private var exportID: UUID?

    init() {
        catalog = TrailCatalogImporter.bundledRouteCandidates()
        outputRoot = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Berms")
    }

    // MARK: - counts

    var runCount: Int { days.reduce(0) { $0 + $1.runs.count } }
    var clipCount: Int { clips.count }
    var unmatchedCount: Int { inboxClipIndices.count }
    var hasContent: Bool { !days.isEmpty || !clips.isEmpty }

    // MARK: - import

    func add(clips newClips: [Clip]) {
        let existing = Set(clips.map(\.id))
        clips.append(contentsOf: newClips.filter { !existing.contains($0.id) })
        clips.sort(by: Clip.orderedBefore)
        refresh()
    }

    func add(days newDays: [StudioDay]) {
        days.append(contentsOf: newDays)
        days = mergeSameID(days)
        days = mergeAdjacent(days).map(normalizeRunNumbers)
            .sorted { $0.startedAt < $1.startedAt }
        refresh()
    }

    func clearAll() {
        for scope in accessedScopes {
            scope.stopAccessingSecurityScopedResource()
        }
        accessedScopes = []
        days = []
        clips = []
        offsets = [:]
        outputDirectories = [:]
        trimStarts = [:]
        trimEnds = [:]
        refresh()
    }

    // MARK: - session access

    func session(id: String) -> StudioSession? {
        sessions.first { $0.id == id }
    }

    func offset(for sessionID: String) -> Int { offsets[sessionID] ?? 0 }

    func shiftOffset(for sessionID: String, by seconds: Int) {
        offsets[sessionID] = offset(for: sessionID) + seconds
        refresh()
    }

    func resetOffset(for sessionID: String) {
        offsets[sessionID] = 0
        refresh()
    }

    var defaultOutputDirectory: URL { outputRoot.appendingPathComponent("Berms Exports") }

    func outputDirectory(for sessionID: String) -> URL {
        if let custom = outputDirectories[sessionID] { return custom }
        guard let session = session(id: sessionID) else { return defaultOutputDirectory }
        return defaultOutputDirectory.appendingPathComponent(slug(session.title))
    }

    func hasCustomOutputDirectory(for sessionID: String) -> Bool {
        outputDirectories[sessionID] != nil
    }

    func setOutputDirectory(_ url: URL, for sessionID: String) {
        if let previous = outputDirectories[sessionID], previous != url, accessedScopes.contains(previous) {
            previous.stopAccessingSecurityScopedResource()
            accessedScopes.remove(previous)
        }
        if url.startAccessingSecurityScopedResource() { accessedScopes.insert(url) }
        outputDirectories[sessionID] = url
    }

    func clearOutputDirectory(for sessionID: String) {
        if let previous = outputDirectories[sessionID], accessedScopes.contains(previous) {
            previous.stopAccessingSecurityScopedResource()
            accessedScopes.remove(previous)
        }
        outputDirectories[sessionID] = nil
    }

    func trimStart(for sessionID: String) -> TimeInterval { trimStarts[sessionID] ?? 0 }
    func trimEnd(for sessionID: String) -> TimeInterval { trimEnds[sessionID] ?? 0 }

    func setTrimStart(_ value: TimeInterval, for sessionID: String) {
        trimStarts[sessionID] = max(0, value)
    }

    func setTrimEnd(_ value: TimeInterval, for sessionID: String) {
        trimEnds[sessionID] = max(0, value)
    }

    func sessionClips(_ session: StudioSession) -> [Clip] {
        session.clipIndices.map { clips[$0] }
    }

    func runRefs(in session: StudioSession) -> [RunRef] {
        session.runs.enumerated().map { index, segment in
            let runNumber = segment.runNumber ?? index + 1
            return RunRef(
                sessionID: session.id, segmentID: segment.id,
                runNumber: runNumber,
                title: segment.title, subtitle: runSubtitle(segment, number: runNumber))
        }
    }

    func run(for ref: RunRef) -> StudioSegment? {
        session(id: ref.sessionID)?.runs.first { $0.id == ref.segmentID }
    }

    func clips(forRun segment: StudioSegment, in session: StudioSession) -> [Clip] {
        session.clipIndices.compactMap { index in
            guard clips.indices.contains(index) else { return nil }
            return overlaps(clips[index], segment: segment, offsetSeconds: session.offsetSeconds)
                ? clips[index]
                : nil
        }
    }

    func unmatchedClips(in session: StudioSession) -> [Clip] {
        return session.clipIndices.compactMap { index in
            guard clips.indices.contains(index) else { return nil }
            let matched = session.runs.contains {
                overlaps(clips[index], segment: $0, offsetSeconds: session.offsetSeconds)
            }
            return matched ? nil : clips[index]
        }
    }

    func inboxClips() -> [Clip] {
        inboxClipIndices.map { clips[$0] }
    }

    func exportURL(session: StudioSession, run: RunRef) -> URL {
        let filename =
            "\(slug(StudioFormat.dayLabel(session.day.startedAt)))"
            + "-run-\(String(format: "%02d", run.runNumber))"
            + "-\(slug(run.title)).mp4"
        return outputDirectory(for: session.id).appendingPathComponent(filename)
    }

    func orderedClips(forRun segment: StudioSegment, in session: StudioSession) -> [Clip] {
        clips(forRun: segment, in: session)
            .sorted { ($0.recordedAt ?? .distantFuture) < ($1.recordedAt ?? .distantFuture) }
    }

    func exportPlan(for ref: RunRef) -> ExportPlan? {
        guard let session = session(id: ref.sessionID),
            let segment = run(for: ref)
        else { return nil }
        let orderedClips = orderedClips(forRun: segment, in: session)
        let clips = orderedClips.map { $0.parts.map(\.path) }
        guard clips.contains(where: { !$0.isEmpty }) else { return nil }
        let trimStart = trimStart(for: ref.sessionID)
        let trimEnd = trimEnd(for: ref.sessionID)
        let estimatedDuration = orderedClips.reduce(0) { total, clip in
            total + max(0, clip.duration - trimStart - trimEnd)
        }
        return ExportPlan(
            runID: ref.id, title: ref.title,
            output: exportURL(session: session, run: ref), clips: clips,
            estimatedDuration: estimatedDuration,
            trimStart: trimStart, trimEnd: trimEnd)
    }

    func exportableRunCount(in session: StudioSession) -> Int {
        runRefs(in: session).reduce(0) { count, ref in
            exportPlan(for: ref) == nil ? count : count + 1
        }
    }

    /// Every part of every clip on the run, paired with a rich destination name
    /// beside the stitched exports.
    func renamePlan(for ref: RunRef) -> [ClipRenameFile]? {
        guard let session = session(id: ref.sessionID),
            let segment = run(for: ref)
        else { return nil }
        let orderedClips = orderedClips(forRun: segment, in: session)
        guard !orderedClips.isEmpty else { return nil }

        return orderedClips.enumerated().flatMap { clipIndex, clip in
            clipRenameFiles(
                for: clip, ref: ref, segment: segment,
                session: session, position: clipIndex + 1)
        }
    }

    /// One copy per clip, even when a clip overlaps several runs: each clip goes
    /// to the run it overlaps most.
    func renameFiles(for refs: [RunRef]) -> [ClipRenameFile] {
        var files: [ClipRenameFile] = []
        for sessionID in Set(refs.map(\.sessionID)) {
            guard let session = session(id: sessionID) else { continue }
            let runs = refs.filter { $0.sessionID == sessionID }.compactMap { ref in
                run(for: ref).map { (ref, $0) }
            }
            guard !runs.isEmpty else { continue }

            var assignments: [Int: (ref: RunRef, segment: StudioSegment)] = [:]
            for index in session.clipIndices {
                guard clips.indices.contains(index), let recordedAt = clips[index].recordedAt else {
                    continue
                }
                let clip = clips[index]
                let clipStart = recordedAt.addingTimeInterval(TimeInterval(session.offsetSeconds))
                let clipEnd = clipStart.addingTimeInterval(clip.duration)
                var best: (ref: RunRef, segment: StudioSegment, overlap: TimeInterval)?
                for (ref, segment) in runs {
                    let overlap = min(clipEnd, segment.endedAt)
                        .timeIntervalSince(max(clipStart, segment.startedAt))
                    guard overlap > 0, overlap > (best?.overlap ?? -.infinity) else { continue }
                    best = (ref, segment, overlap)
                }
                if let best { assignments[index] = (best.ref, best.segment) }
            }

            var positions: [String: Int] = [:]
            let ordered = assignments.keys.sorted {
                (clips[$0].recordedAt ?? .distantFuture) < (clips[$1].recordedAt ?? .distantFuture)
            }
            for index in ordered {
                guard let assignment = assignments[index] else { continue }
                let position = (positions[assignment.ref.id] ?? 0) + 1
                positions[assignment.ref.id] = position
                files.append(
                    contentsOf: clipRenameFiles(
                        for: clips[index], ref: assignment.ref,
                        segment: assignment.segment, session: session, position: position))
            }
        }
        return files
    }

    private func clipRenameFiles(
        for clip: Clip, ref: RunRef, segment: StudioSegment,
        session: StudioSession, position: Int
    ) -> [ClipRenameFile] {
        let directory = outputDirectory(for: session.id)
        let day = slug(StudioFormat.dayLabel(session.day.startedAt))
        let trail = segment.trails.isEmpty ? "" : "-\(slug(ref.title))"
        let run = String(format: "run-%02d", ref.runNumber)
        let positionPart = String(format: "clip-%02d", position)
        let time = StudioFormat.filenameClock(clip.recordedAt)
        return clip.parts.enumerated().map { partIndex, part in
            var name = "\(day)-\(run)\(trail)-\(positionPart)-\(time)"
            if clip.parts.count > 1 {
                name += String(format: "-ch-%02d", partIndex + 1)
            }
            let ext = part.path.pathExtension.isEmpty ? "mp4" : part.path.pathExtension.lowercased()
            return ClipRenameFile(
                source: part.path,
                destination: directory.appendingPathComponent("\(name).\(ext)"))
        }
    }

    func renameableRunCount(in session: StudioSession) -> Int {
        runRefs(in: session).reduce(0) { count, ref in
            renamePlan(for: ref) == nil ? count : count + 1
        }
    }

    /// Copies each clip once into the export folder with its run and trail in the
    /// name. Clips that never land on a run are skipped, and the source footage is
    /// left alone.
    func renameClips(for refs: [RunRef]) {
        let files = renameFiles(for: refs)
        guard !files.isEmpty else {
            message = "No clips to rename"
            messageIsError = true
            return
        }

        busy = "Renaming clips…"
        messageIsError = false
        Task {
            let outcome = await Task.detached { Self.copyRenames(files) }.value
            let noun = outcome.renamed == 1 ? "clip" : "clips"
            if outcome.failed > 0 {
                message = "Renamed \(outcome.renamed) of \(files.count) clips · \(outcome.failed) failed"
                messageIsError = true
            } else {
                let directory = files[0].destination.deletingLastPathComponent().path
                message = "Renamed \(outcome.renamed) \(noun) → \(directory)"
            }
            busy = nil
        }
    }

    private nonisolated static func copyRenames(
        _ files: [ClipRenameFile]
    ) -> (renamed: Int, failed: Int) {
        let manager = FileManager.default
        var claimed: Set<String> = []
        var renamed = 0
        var failed = 0
        for file in files {
            let source = file.source.standardizedFileURL
            guard source != file.destination.standardizedFileURL else { continue }
            let destination = uniqueDestination(file.destination, claimed: &claimed)
            do {
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                if clonefile(source.path, destination.path, 0) != 0 {
                    try manager.copyItem(at: source, to: destination)
                }
                renamed += 1
            } catch {
                failed += 1
            }
        }
        return (renamed, failed)
    }

    private nonisolated static func uniqueDestination(
        _ url: URL, claimed: inout Set<String>
    ) -> URL {
        guard claimed.contains(url.path) else {
            claimed.insert(url.path)
            return url
        }
        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var attempt = 2
        while true {
            let candidate = directory.appendingPathComponent("\(name)-\(attempt).\(ext)")
            if !claimed.contains(candidate.path) {
                claimed.insert(candidate.path)
                return candidate
            }
            attempt += 1
        }
    }

    /// Stitches every run in the session that has footage, a few at a time.
    func exportAll(in session: StudioSession, concurrency: Int = 3) {
        let plans = runRefs(in: session).compactMap { exportPlan(for: $0) }
        guard !plans.isEmpty else {
            message = "No runs in this session have footage"
            messageIsError = true
            return
        }

        let concurrency = max(1, concurrency)
        let operationID = startExport(
            total: plans.count,
            activeItems: plans.prefix(concurrency).map {
                StudioExportItemProgress(id: $0.id, title: $0.title, fraction: 0)
            })
        Task {
            var failures = 0
            var index = 0
            while index < plans.count {
                let chunk = Array(plans[index..<min(index + concurrency, plans.count)])
                setActiveExportItems(
                    chunk.map {
                        StudioExportItemProgress(id: $0.id, title: $0.title, fraction: 0)
                    }, for: operationID)
                await withTaskGroup(of: StudioExportAttempt.self) { group in
                    for plan in chunk {
                        let reportProgress: @Sendable (Double) -> Void = { [library = self] fraction in
                            Task { @MainActor in
                                library.updateExportItemProgress(
                                    fraction,
                                    itemID: plan.id,
                                    for: operationID)
                            }
                        }
                        group.addTask {
                            do {
                                try FfmpegStitcher.concat(
                                    clips: plan.clips, output: plan.output,
                                    estimatedDuration: plan.estimatedDuration,
                                    trimStart: plan.trimStart,
                                    trimEnd: plan.trimEnd,
                                    progress: reportProgress)
                                return StudioExportAttempt(id: plan.id, succeeded: true)
                            } catch {
                                return StudioExportAttempt(id: plan.id, succeeded: false)
                            }
                        }
                    }
                    for await attempt in group {
                        if !attempt.succeeded { failures += 1 }
                        completeExportItem(attempt.id, succeeded: attempt.succeeded, for: operationID)
                    }
                }
                index += chunk.count
            }

            let directory = outputDirectory(for: session.id)
            if failures == 0 {
                message = "Exported \(plans.count) videos → \(directory.path)"
            } else {
                message = "Exported \(plans.count - failures) of \(plans.count) videos · \(failures) failed"
                messageIsError = true
            }
            finishExport(operationID)
        }
    }

    @discardableResult
    func startExport(total: Int, activeItems: [StudioExportItemProgress]) -> UUID {
        let operationID = UUID()
        exportID = operationID
        exportProgress = StudioExportProgress(
            completed: 0, failed: 0, total: total,
            activeItems: activeItems, startedAt: .now)
        busy = "Exporting…"
        messageIsError = false
        return operationID
    }

    func setActiveExportItems(_ items: [StudioExportItemProgress], for operationID: UUID) {
        guard exportID == operationID, var progress = exportProgress else { return }
        progress.activeItems = items
        exportProgress = progress
    }

    func updateExportItemProgress(_ fraction: Double, itemID: String, for operationID: UUID) {
        guard exportID == operationID, var progress = exportProgress,
            let index = progress.activeItems.firstIndex(where: { $0.id == itemID })
        else {
            return
        }
        progress.activeItems[index].fraction = min(max(fraction, 0), 1)
        exportProgress = progress
    }

    func completeExportItem(_ itemID: String, succeeded: Bool, for operationID: UUID) {
        guard exportID == operationID, var progress = exportProgress else { return }
        progress.completed += 1
        if !succeeded { progress.failed += 1 }
        progress.activeItems.removeAll { $0.id == itemID }
        exportProgress = progress
    }

    func finishExport(_ operationID: UUID) {
        guard exportID == operationID else { return }
        exportID = nil
        exportProgress = nil
        busy = nil
    }

    // MARK: - derived state

    private func refresh() {
        days = days.map(applyTrails)
        offsets = offsets.filter { key, _ in days.contains { $0.id == key } }

        var assignments: [Int: [Int]] = [:]
        var inbox: [Int] = []
        for (index, clip) in clips.enumerated() {
            if let dayIndex = assignedDayIndex(for: clip) {
                assignments[dayIndex, default: []].append(index)
            } else {
                inbox.append(index)
            }
        }

        sessions = days.enumerated().map { index, day in
            StudioSession(
                id: day.id, day: day,
                offsetSeconds: offsets[day.id] ?? 0,
                clipIndices: assignments[index] ?? [])
        }
        inboxClipIndices = inbox
    }

    private func assignedDayIndex(for clip: Clip) -> Int? {
        guard let recordedAt = clip.recordedAt else { return nil }
        var best: (index: Int, overlap: TimeInterval)?
        for (index, day) in days.enumerated() {
            guard let (dayStart, dayEnd) = span(of: day) else { continue }
            let offset = TimeInterval(offsets[day.id] ?? 0)
            let clipStart = recordedAt.addingTimeInterval(offset)
            let clipEnd = clipStart.addingTimeInterval(clip.duration)
            let overlap = min(clipEnd, dayEnd).timeIntervalSince(max(clipStart, dayStart))
            guard overlap > 0 else { continue }
            if overlap > (best?.overlap ?? -.infinity) {
                best = (index, overlap)
            }
        }
        return best?.index
    }

    private func overlaps(_ clip: Clip, segment: StudioSegment, offsetSeconds: Int) -> Bool {
        guard let recordedAt = clip.recordedAt else { return false }
        let clipStart = recordedAt.addingTimeInterval(TimeInterval(offsetSeconds))
        let clipEnd = clipStart.addingTimeInterval(clip.duration)
        return clipStart < segment.endedAt && segment.startedAt < clipEnd
    }

    private func span(of day: StudioDay) -> (Date, Date)? {
        guard let start = day.segments.map(\.startedAt).min(),
            let end = day.segments.map(\.endedAt).max()
        else { return nil }
        return (start, end)
    }

    private func runSubtitle(_ segment: StudioSegment, number: Int) -> String {
        "Run \(number) · \(StudioFormat.clockRange(segment.startedAt, segment.endedAt))"
            + " · \(StudioFormat.distance(segment.distanceMeters))"
            + " · \(StudioFormat.vertical(segment.verticalMeters))"
    }

    private func applyTrails(to day: StudioDay) -> StudioDay {
        guard !catalog.isEmpty else { return day }
        let namesByID = Dictionary(catalog.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let matcher = TrailRouteMatcher()
        var day = day
        day.segments = day.segments.map { segment in
            guard segment.kind == .run, segment.trails.isEmpty, segment.route.count >= 2 else {
                return segment
            }
            let result = matcher.matchResult(for: segment.route, candidates: catalog)
            let names = result.sections.compactMap { namesByID[$0.trailID] }
            return StudioSegment(
                id: segment.id, kind: segment.kind, runNumber: segment.runNumber,
                startedAt: segment.startedAt, endedAt: segment.endedAt,
                distanceMeters: segment.distanceMeters, verticalMeters: segment.verticalMeters,
                maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond,
                route: segment.route, jumps: segment.jumps, trails: names
            )
        }
        return day
    }

    /// Stops/starts of the phone recording during one ride land in separate logs.
    /// Fold logs back together when the gap is small.
    private func mergeAdjacent(_ input: [StudioDay]) -> [StudioDay] {
        let sorted = input.sorted { $0.startedAt < $1.startedAt }
        var result: [StudioDay] = []
        for day in sorted {
            if var last = result.last, let lastEnd = span(of: last)?.1,
                day.startedAt.timeIntervalSince(lastEnd) < 2 * 3600
            {
                last.segments = mergeSegments(last.segments + day.segments)
                last.endedAt = max(last.endedAt ?? lastEnd, day.endedAt ?? day.startedAt)
                result[result.count - 1] = last
            } else {
                result.append(day)
            }
        }
        return result
    }

    private func mergeSameID(_ input: [StudioDay]) -> [StudioDay] {
        var result: [StudioDay] = []
        var indices: [String: Int] = [:]
        for day in input.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let index = indices[day.id] else {
                indices[day.id] = result.count
                result.append(day)
                continue
            }

            var merged = result[index]
            merged.name = merged.name ?? day.name
            merged.startedAt = min(merged.startedAt, day.startedAt)
            merged.endedAt = max(
                merged.endedAt ?? merged.startedAt,
                day.endedAt ?? day.startedAt)
            merged.segments = mergeSegments(merged.segments + day.segments)
            result[index] = merged
        }
        return result
    }

    private func mergeSegments(_ input: [StudioSegment]) -> [StudioSegment] {
        var result: [StudioSegment] = []
        for segment in input.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard
                let index = result.firstIndex(where: { existing in
                    existing.kind == segment.kind
                        && abs(existing.startedAt.timeIntervalSince(segment.startedAt)) < 3
                        && abs(existing.endedAt.timeIntervalSince(segment.endedAt)) < 3
                })
            else {
                result.append(segment)
                continue
            }

            let existing = result[index]
            let preferred = segment.route.count > existing.route.count ? segment : existing
            let runNumber = preferred.runNumber ?? existing.runNumber ?? segment.runNumber
            result[index] = StudioSegment(
                id: preferred.id,
                kind: preferred.kind,
                runNumber: runNumber,
                startedAt: preferred.startedAt,
                endedAt: preferred.endedAt,
                distanceMeters: preferred.distanceMeters,
                verticalMeters: preferred.verticalMeters,
                maximumSpeedMetersPerSecond: preferred.maximumSpeedMetersPerSecond,
                route: preferred.route,
                jumps: preferred.jumps,
                trails: preferred.trails
            )
        }
        return result
    }

    private func normalizeRunNumbers(_ input: StudioDay) -> StudioDay {
        var day = input
        var nextRunNumber = 1
        day.segments = day.segments.sorted { $0.startedAt < $1.startedAt }.map { segment in
            guard segment.kind == .run else { return segment }
            let runNumber = segment.runNumber ?? nextRunNumber
            nextRunNumber = max(nextRunNumber + 1, runNumber + 1)
            return StudioSegment(
                id: segment.id,
                kind: segment.kind,
                runNumber: runNumber,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                distanceMeters: segment.distanceMeters,
                verticalMeters: segment.verticalMeters,
                maximumSpeedMetersPerSecond: segment.maximumSpeedMetersPerSecond,
                route: segment.route,
                jumps: segment.jumps,
                trails: segment.trails
            )
        }
        return day
    }

    private func slug(_ value: String) -> String {
        var result = ""
        var pendingDash = false
        for character in value {
            if character.isLetter || character.isNumber {
                if pendingDash, !result.isEmpty { result.append("-") }
                result.append(contentsOf: character.lowercased())
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        if result.count > 48 {
            result = String(result.prefix(48))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result.isEmpty ? "untitled" : result
    }
}
