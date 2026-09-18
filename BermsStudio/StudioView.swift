import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct StudioView: View {
    @State private var library = StudioLibrary()
    @State private var selection: SidebarItem?
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle("Berms Studio")
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
            return true
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: true
        ) { result in
            Task { @MainActor in
                if case .success(let urls) = result {
                    importURLs(urls)
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if !library.inboxClipIndices.isEmpty {
                Section("Unsorted") {
                    Label {
                        HStack {
                            Text("Inbox")
                            Spacer()
                            Text("\(library.inboxClipIndices.count)")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tray.full")
                    }
                    .tag(SidebarItem.inbox)
                }
            }

            Section("Sessions") {
                ForEach(library.sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .lineLimit(1)
                        Text(session.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(SidebarItem.session(session.id))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        .overlay {
            if !library.hasContent {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "square.and.arrow.down",
                    description: Text("Drop clips and a Berms log anywhere in this window."))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        NavigationStack {
            switch selection {
            case .inbox:
                InboxDetailView(library: library)
            case .session(let id):
                if let session = library.session(id: id) {
                    SessionDetailView(library: library, session: session)
                } else {
                    ContentUnavailableView("Session not found", systemImage: "questionmark.circle")
                }
            case nil:
                emptyDetail
            }
        }
    }

    @ViewBuilder
    private var emptyDetail: some View {
        if library.hasContent {
            ContentUnavailableView(
                "Select a session",
                systemImage: "calendar.day.timeline.left",
                description: Text("Pick a session to see its runs and clips."))
        } else {
            ContentUnavailableView {
                Label("Drop your footage", systemImage: "square.and.arrow.down")
            } description: {
                Text(
                    "Drag the day's GoPro clips and the Berms log straight from Downloads — "
                        + "no folders needed. Clips attach to runs by time.")
            } actions: {
                Button("Add files…") { showImporter = true }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showImporter = true
            } label: {
                Label("Add files…", systemImage: "plus")
            }
            .help("Add GoPro clips, Berms logs, folders, or a shared day zip")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let exportProgress = library.exportProgress {
                StudioExportProgressView(progress: exportProgress)
            } else if let busy = library.busy {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
            } else {
                Text(library.message)
                    .foregroundStyle(library.messageIsError ? Color.red : Color.secondary)
            }
            Spacer()
            Text(
                "\(library.sessions.count) sessions · \(library.runCount) runs · "
                    + "\(library.clipCount) clips · \(library.unmatchedCount) unsorted"
            )
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var importContentTypes: [UTType] {
        var types: [UTType] = [.folder, .movie, .zip, .json]
        if let jsonl = UTType(filenameExtension: "jsonl") {
            types.append(jsonl)
        }
        types.append(.data)
        return types
    }

    private func handleDrop(_ urls: [URL]) {
        let (videoFiles, logFiles) = Self.collect(from: urls)
        importFrom(videoFiles: videoFiles, logFiles: logFiles)
    }

    private func importURLs(_ urls: [URL]) {
        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        let (videoFiles, logFiles) = Self.collect(from: urls)
        importFrom(videoFiles: videoFiles, logFiles: logFiles, securityScopedURLs: scopedURLs)
    }

    private func importFrom(
        videoFiles: [URL], logFiles: [URL],
        securityScopedURLs: [URL] = []
    ) {
        guard !videoFiles.isEmpty || !logFiles.isEmpty else {
            for url in securityScopedURLs {
                url.stopAccessingSecurityScopedResource()
            }
            library.message = "Nothing to import from that drop"
            library.messageIsError = true
            return
        }
        library.busy = "Importing…"
        Task {
            defer {
                for url in securityScopedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let newClips = try await Task.detached {
                    try FootageScanner.clips(fromFiles: videoFiles)
                }.value
                let newDays = try await Task.detached {
                    try logFiles.flatMap(Self.loadDay)
                }.value

                if !newClips.isEmpty { library.add(clips: newClips) }
                if !newDays.isEmpty { library.add(days: newDays) }

                if let sessionID = newDays.first?.id, library.session(id: sessionID) != nil {
                    selection = .session(sessionID)
                }
                library.message = summary(clips: newClips.count, days: newDays.count)
                library.messageIsError = false
            } catch {
                library.message = "Import failed: \(error.localizedDescription)"
                library.messageIsError = true
            }
            library.busy = nil
        }
    }

    private func summary(clips: Int, days: Int) -> String {
        var parts: [String] = []
        if clips > 0 { parts.append("\(clips) clips") }
        if days > 0 { parts.append("\(days) sessions") }
        return parts.isEmpty ? "Nothing new to add" : "Added " + parts.joined(separator: " · ")
    }

    nonisolated private static func isLog(_ url: URL) -> Bool {
        ["json", "jsonl"].contains(url.pathExtension.lowercased())
    }

    nonisolated private static func isArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    /// Sorts dropped items into footage and logs, looking inside folders and zips.
    nonisolated private static func collect(from urls: [URL]) -> (videos: [URL], logs: [URL]) {
        var videos: [URL] = []
        var logs: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue {
                videos.append(contentsOf: FootageScanner.videoFiles(in: url))
                logs.append(contentsOf: logFiles(in: url))
            } else if FootageScanner.isVideo(url) {
                videos.append(url)
            } else if isLog(url) {
                logs.append(url)
            } else if isArchive(url), let folder = extract(url) {
                let nested = collect(from: [folder])
                videos.append(contentsOf: nested.videos)
                logs.append(contentsOf: nested.logs)
            }
        }
        return (videos, logs)
    }

    nonisolated private static func logFiles(in root: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator where isLog(url) { result.append(url) }
        return result
    }

    nonisolated private static func extract(_ url: URL) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Berms-unzip-\(UUID().uuidString)", isDirectory: true)
        guard
            (try? FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true)) != nil
        else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, destination.path]
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? destination : nil
    }

    nonisolated private static func loadDay(_ url: URL) throws -> [StudioDay] {
        if url.pathExtension.lowercased() == "jsonl" {
            return [try DiagnosticsImporter.loadDay(url: url)]
        }
        return try StudioExport.load(url).studioDays()
    }
}

private struct StudioExportProgressView: View {
    let progress: StudioExportProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    ProgressView(value: progress.fraction)
                        .controlSize(.small)
                        .frame(width: 140)
                    Text("Exporting")
                        .fontWeight(.medium)
                    Text(videoCountDescription)
                        .foregroundStyle(.secondary)
                    Text("\(Int((progress.fraction * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(activeDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(
                        "Elapsed \(StudioFormat.duration(progress.elapsed(at: context.date))) · \(etaLabel(at: context.date))"
                    )
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Export progress")
            .accessibilityValue(accessibilityValue(at: context.date))
        }
    }

    private var activeDescription: String {
        let titles = progress.activeItems.map(\.title)
        if titles.isEmpty { return "Finishing…" }
        if titles.count == 1 { return "Stitching \(titles[0])" }
        return "Stitching " + titles.joined(separator: " · ")
    }

    private var videoCountDescription: String {
        var description = "\(progress.completed) of \(progress.total) videos"
        if progress.failed > 0 {
            description += " · \(progress.failed) failed"
        }
        return description
    }

    private func etaLabel(at date: Date) -> String {
        guard let eta = progress.estimatedTimeRemaining(at: date) else {
            return "ETA calculating…"
        }
        return "ETA \(StudioFormat.duration(eta))"
    }

    private func accessibilityValue(at date: Date) -> String {
        var value =
            "\(Int((progress.fraction * 100).rounded())) percent, "
            + "\(progress.completed) of \(progress.total) videos"
        if progress.failed > 0 {
            value += ", \(progress.failed) failed"
        }
        value += ", elapsed \(StudioFormat.duration(progress.elapsed(at: date)))"
        if let eta = progress.estimatedTimeRemaining(at: date) {
            value += ", eta \(StudioFormat.duration(eta))"
        } else {
            value += ", eta calculating"
        }
        return value
    }
}

// MARK: - Session

@MainActor
struct SessionDetailView: View {
    let library: StudioLibrary
    let session: StudioSession
    @AppStorage("studio.showOnlyRunsWithClips") private var showOnlyRunsWithClips = true
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                runsSection
                unmatchedSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(session.title)
        .navigationDestination(for: RunRef.self) { run in
            RunDetailView(library: library, run: run)
        }
        .sheet(isPresented: $showSettings) {
            SessionSettingsView(library: library, session: session)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(session.subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                library.exportAll(in: session)
            } label: {
                Label("Export all", systemImage: "film.stack")
            }
            .buttonStyle(.borderedProminent)
            .disabled(library.exportableRunCount(in: session) == 0 || library.busy != nil)
            .help("Export every run that has footage, three at a time")

            Button {
                library.renameClips(for: library.runRefs(in: session))
            } label: {
                Label("Rename clips", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .disabled(library.renameableRunCount(in: session) == 0 || library.busy != nil)
            .help("Copy every matched clip to the session folder named for its run and trails")

            Button {
                showSettings = true
            } label: {
                Label("Session settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .help("Output folder, trims, and clip clock offset")
        }
    }

    @ViewBuilder
    private var runsSection: some View {
        let runs = runsToShow
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Runs").font(.headline)
                Spacer()
                Toggle("Only runs with clips", isOn: $showOnlyRunsWithClips)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout)
                    .help("Hide runs that don't have any matching footage")
            }
            if runs.isEmpty {
                Text(
                    showOnlyRunsWithClips
                        ? "No runs have clips yet. Add the matching footage, or turn off the filter to see every run."
                        : "This session has no runs."
                )
                .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(runs) { run in
                        NavigationLink(value: run) {
                            runRow(run)
                        }
                        .buttonStyle(.plain)
                        if run.id != runs.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var runsToShow: [RunRef] {
        let refs = library.runRefs(in: session)
        guard showOnlyRunsWithClips else { return refs }
        return refs.filter { run in
            guard let segment = library.run(for: run) else { return false }
            return !library.clips(forRun: segment, in: session).isEmpty
        }
    }

    private func runRow(_ run: RunRef) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).lineLimit(1)
                Text(run.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let segment = library.run(for: run) {
                Text("\(library.clips(forRun: segment, in: session).count) clips")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var unmatchedSection: some View {
        let unmatched = library.unmatchedClips(in: session)
        VStack(alignment: .leading, spacing: 8) {
            Text("Clips not on a run (\(unmatched.count))").font(.headline)
            if unmatched.isEmpty {
                Text("Every clip landed on a run.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(unmatched) { clip in
                        ClipRow(clip: clip)
                        if clip.id != unmatched.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

// MARK: - Session settings

@MainActor
struct SessionSettingsView: View {
    let library: StudioLibrary
    let session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var showOutputPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Export") {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(library.outputDirectory(for: session.id).path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button("Choose…") { showOutputPicker = true }
                            if library.hasCustomOutputDirectory(for: session.id) {
                                Button("Default") { library.clearOutputDirectory(for: session.id) }
                            }
                        }
                    }
                    LabeledContent("Trim start") {
                        secondsField(trimStartBinding)
                    }
                    LabeledContent("Trim end") {
                        secondsField(trimEndBinding)
                    }
                    Text("Seconds cut from the start and end of each clip before stitching.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Clip clock offset") {
                    HStack(spacing: 12) {
                        Button {
                            library.shiftOffset(for: session.id, by: -60)
                        } label: {
                            Image(systemName: "minus")
                        }
                        .accessibilityLabel("Shift clip clock one minute earlier")

                        Text(StudioFormat.offset(library.offset(for: session.id)))
                            .monospacedDigit()
                            .frame(minWidth: 52)

                        Button {
                            library.shiftOffset(for: session.id, by: 60)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Shift clip clock one minute later")

                        if library.offset(for: session.id) != 0 {
                            Button("Reset") { library.resetOffset(for: session.id) }
                        }
                        Spacer()
                    }
                    Text(
                        "Shifts this session's clip timestamps when the camera clock is wrong, "
                            + "so clips land on the right runs."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 400)
        .fileImporter(
            isPresented: $showOutputPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                library.setOutputDirectory(url, for: session.id)
            }
        }
    }

    private func secondsField(_ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
            Text("seconds").foregroundStyle(.secondary)
        }
    }

    private var trimStartBinding: Binding<Double> {
        Binding(
            get: { library.trimStart(for: session.id) },
            set: { library.setTrimStart($0, for: session.id) })
    }

    private var trimEndBinding: Binding<Double> {
        Binding(
            get: { library.trimEnd(for: session.id) },
            set: { library.setTrimEnd($0, for: session.id) })
    }
}

// MARK: - Inbox

@MainActor
struct InboxDetailView: View {
    let library: StudioLibrary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unsorted footage")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(
                        "These clips don't line up with any session. Add the matching Berms log, "
                            + "or fix a session's footage clock."
                    )
                    .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    let clips = library.inboxClips()
                    ForEach(clips) { clip in
                        ClipRow(clip: clip)
                        if clip.id != clips.last?.id { Divider() }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Inbox")
    }
}

// MARK: - Shared row

@MainActor
struct ClipRow: View {
    let clip: Clip

    var body: some View {
        HStack(spacing: 12) {
            if let url = clip.firstPath {
                ClipThumbnail(url: url)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).lineLimit(1)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(StudioFormat.clock(clip.recordedAt))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var meta: String {
        let chapters = clip.chapterCount == 1 ? "1 chapter" : "\(clip.chapterCount) chapters"
        return "\(chapters) · \(StudioFormat.duration(clip.duration))"
    }
}
