import Foundation

struct ClipPart: Sendable {
    let path: URL
    let chapter: Int
    let recordedAt: Date?
    let duration: TimeInterval
}

struct Clip: Identifiable, Sendable {
    let key: String
    let name: String
    let sequenceNumber: Int?
    let parts: [ClipPart]

    var id: String { key }

    var recordedAt: Date? { parts.compactMap(\.recordedAt).min() }
    var duration: TimeInterval { parts.reduce(0) { $0 + $1.duration } }
    var endedAt: Date? { recordedAt.map { $0.addingTimeInterval(duration) } }
    var chapterCount: Int { parts.count }
    var firstPath: URL? { parts.first?.path }
}

extension Clip {
    static func orderedBefore(_ lhs: Clip, _ rhs: Clip) -> Bool {
        switch (lhs.sequenceNumber, rhs.sequenceNumber) {
        case (let left?, let right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            switch (lhs.recordedAt, rhs.recordedAt) {
            case (let leftDate?, let rightDate?) where leftDate != rightDate:
                return leftDate < rightDate
            default:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }
}

struct MediaInfo: Sendable {
    let duration: TimeInterval
    let recordedAt: Date?
}

enum FootageError: LocalizedError {
    case read(URL, Error)
    case probeUnavailable(Error)
    case probeFailed(URL, String)
    case invalidProbeOutput(URL, Error)
    case noUsableVideos(URL)
    case unavailable(Error)
    case concatFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .read(let url, let error): "Couldn't read \(url.path): \(error.localizedDescription)"
        case .probeUnavailable(let error): "Couldn't run ffprobe: \(error.localizedDescription)"
        case .probeFailed(let url, let stderr): "ffprobe failed for \(url.lastPathComponent): \(stderr)"
        case .invalidProbeOutput(let url, let error):
            "Invalid ffprobe output for \(url.lastPathComponent): \(error.localizedDescription)"
        case .noUsableVideos(let url):
            "Couldn't read any supported video in \(url.lastPathComponent)."
        case .unavailable(let error): "Couldn't run ffmpeg: \(error.localizedDescription)"
        case .concatFailed(let url, let stderr): "ffmpeg failed for \(url.lastPathComponent): \(stderr)"
        }
    }
}

enum FFmpeg {
    static var probePath: String {
        resolve(override: ProcessInfo.processInfo.environment["BERMS_FFPROBE"], name: "ffprobe")
    }

    static var path: String {
        resolve(override: ProcessInfo.processInfo.environment["BERMS_FFMPEG"], name: "ffmpeg")
    }

    /// Apps launched from Finder/Spotlight get a bare PATH that misses Homebrew,
    /// so fall back to the usual install locations.
    private static func resolve(override: String?, name: String) -> String {
        if let override { return override }
        if isOnPath(name) { return name }
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? name
    }

    private static func isOnPath(_ name: String) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
        return path.split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/\(name)")
        }
    }
}

enum FootageScanner {
    /// Scans a folder (recursively) and probes every video file it finds.
    static func scanAndProbe(root: URL) throws -> [Clip] {
        try groupAndProbe(fileURLs: videoFiles(in: root))
    }

    /// Groups and probes a loose pile of dropped files.
    static func clips(fromFiles files: [URL]) throws -> [Clip] {
        try groupAndProbe(fileURLs: files.filter(isVideo))
    }

    static func isVideo(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": true
        default: false
        }
    }

    static func videoFiles(in root: URL) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return isVideo(root) ? [root] : []
        }
        guard
            let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where isVideo(url) {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func probe(_ url: URL) throws -> MediaInfo {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            FFmpeg.probePath, "-v", "error", "-print_format", "json",
            "-show_entries", "format=duration:format_tags=creation_time", url.path,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw FootageError.probeUnavailable(error)
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message =
                String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FootageError.probeFailed(url, message)
        }

        let parsed: ProbeOutput
        do {
            parsed = try JSONDecoder().decode(ProbeOutput.self, from: output)
        } catch {
            throw FootageError.invalidProbeOutput(url, error)
        }

        let duration = parsed.format?.duration.flatMap(Double.init) ?? 0
        let mediaDate = parsed.format?.tags?.creationTime.flatMap(StudioDateParser.parse)
        let fileURL = url.resolvingSymlinksInPath()
        let resources = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let recordedAt = resolvedRecordedAt(
            mediaDate: mediaDate,
            fileCreationDate: resources?.creationDate,
            modificationDate: resources?.contentModificationDate
        )
        return MediaInfo(duration: max(0, duration), recordedAt: recordedAt)
    }

    static func resolvedRecordedAt(
        mediaDate: Date?, fileCreationDate: Date?,
        modificationDate: Date?
    ) -> Date? {
        guard let mediaDate else { return fileCreationDate }
        guard let fileCreationDate, let modificationDate,
            fileCreationDate < modificationDate.addingTimeInterval(-10),
            abs(mediaDate.timeIntervalSince(modificationDate)) <= 10
        else {
            return mediaDate
        }
        return fileCreationDate
    }

    private static func groupAndProbe(fileURLs: [URL]) throws -> [Clip] {
        var groups: [String: [Candidate]] = [:]
        for url in fileURLs {
            let candidate = Candidate(url: url)
            groups[candidate.groupKey, default: []].append(candidate)
        }

        var clips: [Clip] = []
        for (_, candidates) in groups {
            let ordered = candidates.sorted {
                ($0.chapter, $0.url.path) < ($1.chapter, $1.url.path)
            }
            var parts: [ClipPart] = []
            for candidate in ordered {
                guard let info = try? probe(candidate.url) else { continue }
                parts.append(
                    ClipPart(
                        path: candidate.url, chapter: candidate.chapter,
                        recordedAt: info.recordedAt, duration: info.duration))
            }
            guard let first = parts.first?.path else { continue }
            let name = first.lastPathComponent
            clips.append(
                Clip(
                    key: first.standardizedFileURL.path, name: name,
                    sequenceNumber: candidates.compactMap(\.sequenceNumber).first,
                    parts: parts))
        }

        guard !clips.isEmpty || fileURLs.isEmpty else {
            throw FootageError.noUsableVideos(fileURLs[0].deletingLastPathComponent())
        }
        clips.sort(by: Clip.orderedBefore)
        return clips
    }

    /// GoPro chapters share a file number across chapter prefixes (GH01/GH02),
    /// so they group into one clip. Everything else stands alone.
    private struct Candidate {
        let groupKey: String
        let chapter: Int
        let sequenceNumber: Int?
        let url: URL

        init(url: URL) {
            self.url = url
            let stem = url.deletingPathExtension().lastPathComponent
            (groupKey, chapter, sequenceNumber) = Self.parseName(stem)
        }

        static func parseName(_ stem: String) -> (String, Int, Int?) {
            let upper = stem.uppercased()

            if upper.hasPrefix("GOPR") {
                let rest = upper.dropFirst(4)
                if rest.count >= 4, rest.allSatisfy(\.isNumber) {
                    return ("gopro:\(rest)", 0, Int(rest))
                }
            }

            let letters = upper.prefix(2)
            let remainder = upper.dropFirst(2)
            let goproPrefixes = ["GP", "GH", "GX", "GL", "GS", "GC"]
            if goproPrefixes.contains(String(letters)), remainder.count >= 6 {
                let chapter = remainder.prefix(2)
                let file = remainder.dropFirst(2)
                if chapter.allSatisfy(\.isNumber), file.count >= 4, file.allSatisfy(\.isNumber) {
                    return ("gopro:\(file)", Int(chapter) ?? 0, Int(file))
                }
            }

            return ("file:\(stem.lowercased())", 0, nil)
        }
    }

    private struct ProbeOutput: Decodable {
        let format: ProbeFormat?
    }

    private struct ProbeFormat: Decodable {
        let duration: String?
        let tags: ProbeTags?
    }

    private struct ProbeTags: Decodable {
        let creationTime: String?

        enum CodingKeys: String, CodingKey {
            case creationTime = "creation_time"
        }
    }
}

enum FfmpegStitcher {
    static func concat(
        clips: [[URL]], output: URL,
        estimatedDuration: TimeInterval = 0,
        trimStart: TimeInterval = 0, trimEnd: TimeInterval = 0
    ) throws {
        try concat(
            clips: clips, output: output, estimatedDuration: estimatedDuration,
            trimStart: trimStart, trimEnd: trimEnd, progress: { _ in })
    }

    static func concat(
        clips: [[URL]], output: URL,
        estimatedDuration: TimeInterval = 0,
        trimStart: TimeInterval = 0, trimEnd: TimeInterval = 0,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let parts = clips.flatMap { $0 }
        guard !parts.isEmpty else { throw FfmpegStitcherError.nothingToBuild }
        let trimStart = max(0, trimStart)
        let trimEnd = max(0, trimEnd)

        progress(0)
        guard trimStart > 0 || trimEnd > 0 else {
            try concat(
                parts, output: output, expectedDuration: estimatedDuration,
                progress: progress)
            progress(1)
            return
        }

        let clipsToTrim = clips.filter { !$0.isEmpty }
        var staged: [URL] = []
        defer {
            for url in staged {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for (index, clip) in clipsToTrim.enumerated() {
            let start = Double(index) / Double(clipsToTrim.count) * 0.5
            let span = 0.5 / Double(clipsToTrim.count)
            staged.append(
                try trimClip(clip, trimStart: trimStart, trimEnd: trimEnd) { fraction in
                    progress(start + span * fraction)
                })
            progress(start + span)
        }
        try concat(staged, output: output, expectedDuration: estimatedDuration) { fraction in
            progress(0.5 + fraction * 0.5)
        }
        progress(1)
    }

    /// Trims one clip. Its chapters are a single continuous recording, so only the
    /// clip's own start and end are cut, never the boundaries between chapters.
    private static func trimClip(
        _ parts: [URL], trimStart: TimeInterval,
        trimEnd: TimeInterval,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> URL {
        var source = parts[0]
        var joined: URL?
        if parts.count > 1 {
            let full = temporaryFile()
            try concat(parts, output: full, expectedDuration: nil, progress: { _ in })
            source = full
            joined = full
        }
        defer { if let joined { try? FileManager.default.removeItem(at: joined) } }

        let total = (try? FootageScanner.probe(source).duration) ?? 0
        let length = total - trimStart - trimEnd
        guard length > 0 else { throw FfmpegStitcherError.trimEatsWholeVideo }

        let output = temporaryFile()
        try run(
            [
                "-ss", seconds(trimStart), "-i", source.path, "-t", seconds(length),
                "-c", "copy", "-movflags", "+faststart", output.path,
            ],
            for: output, expectedDuration: length, progress: progress)
        return output
    }

    private static func concat(
        _ parts: [URL], output: URL,
        expectedDuration: TimeInterval?,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        guard !parts.isEmpty else { throw FfmpegStitcherError.nothingToBuild }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let listURL = output.deletingPathExtension().appendingPathExtension("concat.txt")
        let list = parts.map { "file '\(escape($0.path))'\n" }.joined()
        try list.write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: listURL) }

        try run(
            [
                "-f", "concat", "-safe", "0", "-i", listURL.path,
                "-c", "copy", "-movflags", "+faststart", output.path,
            ],
            for: output, expectedDuration: expectedDuration, progress: progress)
    }

    private static func run(
        _ arguments: [String], for output: URL,
        expectedDuration: TimeInterval?,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments =
            [
                FFmpeg.path, "-hide_banner", "-loglevel", "error",
                "-nostats", "-progress", "pipe:1", "-y",
            ] + arguments
        let progressPipe = Pipe()
        let stderr = Pipe()
        process.standardOutput = progressPipe
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw FootageError.unavailable(error)
        }

        let reader = FfmpegProgressReader(
            expectedDuration: expectedDuration,
            progress: progress)
        let source = DispatchSource.makeReadSource(
            fileDescriptor: progressPipe.fileHandleForReading.fileDescriptor,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [reader, handle = progressPipe.fileHandleForReading] in
            let data = handle.availableData
            if data.isEmpty {
                source.cancel()
            } else {
                reader.append(data)
            }
        }
        source.resume()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        source.cancel()

        guard process.terminationStatus == 0 else {
            let message =
                String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FootageError.concatFailed(output, message)
        }
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }

    private static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }
}

private final class FfmpegProgressReader: @unchecked Sendable {
    private let expectedDuration: TimeInterval?
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var buffer = ""
    private var lastFraction = -1.0

    init(expectedDuration: TimeInterval?, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedDuration = expectedDuration
        self.progress = progress
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(String(decoding: data, as: UTF8.self))
        var fractions: [Double] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            if let fraction = fraction(for: line), fraction > lastFraction {
                lastFraction = fraction
                fractions.append(fraction)
            }
        }
        lock.unlock()

        fractions.forEach(progress)
    }

    private func fraction(for line: String) -> Double? {
        guard line.hasPrefix("out_time_ms="),
            let expectedDuration, expectedDuration > 0,
            let raw = line.split(separator: "=", maxSplits: 1).last,
            let microseconds = Double(raw)
        else {
            return nil
        }
        return min(max(microseconds / 1_000_000 / expectedDuration, 0), 1)
    }
}

enum FfmpegStitcherError: LocalizedError {
    case nothingToBuild
    case trimEatsWholeVideo

    var errorDescription: String? {
        switch self {
        case .nothingToBuild: "Nothing to export for this run."
        case .trimEatsWholeVideo: "The trim is longer than the clip."
        }
    }
}
