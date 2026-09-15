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
    let trimStart: TimeInterval
    let trimEnd: TimeInterval

    var id: String { runID }
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

    private var offsets: [String: Int] = [:]
    private var outputDirectories: [String: URL] = [:]
    private var accessedScopes: Set<URL> = []
    private var trimStarts: [String: TimeInterval] = [:]
    private var trimEnds: [String: TimeInterval] = [:]

    init() {
        catalog = TrailCatalog.loadBundled()
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
        accessedScopes.forEach { $0.stopAccessingSecurityScopedResource() }
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
        outputDirectories[sessionID] ?? defaultOutputDirectory
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
            return RunRef(sessionID: session.id, segmentID: segment.id,
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
        let filename = "\(slug(StudioFormat.dayLabel(session.day.startedAt)))"
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
              let segment = run(for: ref) else { return nil }
        let clips = orderedClips(forRun: segment, in: session).map { $0.parts.map(\.path) }
        guard clips.contains(where: { !$0.isEmpty }) else { return nil }
        return ExportPlan(runID: ref.id, title: ref.title,
                          output: exportURL(session: session, run: ref), clips: clips,
                          trimStart: trimStart(for: ref.sessionID),
                          trimEnd: trimEnd(for: ref.sessionID))
    }

    func exportableRunCount(in session: StudioSession) -> Int {
        runRefs(in: session).reduce(0) { count, ref in
            exportPlan(for: ref) == nil ? count : count + 1
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

        busy = "Exporting 0 of \(plans.count)…"
        messageIsError = false
        Task {
            var completed = 0
            var failures = 0
            var index = 0
            while index < plans.count {
                let chunk = Array(plans[index..<min(index + concurrency, plans.count)])
                await withTaskGroup(of: Result<Void, Error>.self) { group in
                    for plan in chunk {
                        group.addTask {
                            do {
                                try FfmpegStitcher.concat(clips: plan.clips, output: plan.output,
                                                          trimStart: plan.trimStart,
                                                          trimEnd: plan.trimEnd)
                                return .success(())
                            } catch {
                                return .failure(error)
                            }
                        }
                    }
                    for await result in group {
                        completed += 1
                        busy = "Exporting \(completed) of \(plans.count)…"
                        if case .failure = result { failures += 1 }
                    }
                }
                index += chunk.count
            }

            busy = nil
            let directory = outputDirectory(for: session.id)
            if failures == 0 {
                message = "Exported \(plans.count) videos → \(directory.path)"
            } else {
                message = "Exported \(plans.count - failures) of \(plans.count) videos · \(failures) failed"
                messageIsError = true
            }
        }
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
            StudioSession(id: day.id, day: day,
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
            if best == nil || overlap > best!.overlap {
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
              let end = day.segments.map(\.endedAt).max() else { return nil }
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
               day.startedAt.timeIntervalSince(lastEnd) < 2 * 3600 {
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
            merged.endedAt = max(merged.endedAt ?? merged.startedAt,
                                  day.endedAt ?? day.startedAt)
            merged.segments = mergeSegments(merged.segments + day.segments)
            result[index] = merged
        }
        return result
    }

    private func mergeSegments(_ input: [StudioSegment]) -> [StudioSegment] {
        var result: [StudioSegment] = []
        for segment in input.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let index = result.firstIndex(where: { existing in
                existing.kind == segment.kind
                    && abs(existing.startedAt.timeIntervalSince(segment.startedAt)) < 3
                    && abs(existing.endedAt.timeIntervalSince(segment.endedAt)) < 3
            }) else {
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
