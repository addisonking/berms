import MapKit
import SwiftData
import SwiftUI
import UIKit

struct RunMapDestination: Hashable {
    let dayID: UUID
    let runID: UUID
    let number: Int
}

struct FullScreenSummaryMap: View {
    let title: String
    let base: SessionDetailBase?
    let trailDetails: SessionDetailTrailDetails?
    let focusedSegmentID: UUID?
    let focusedRunNumber: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let base {
                    SessionRouteMap(
                        base: base, trailDetails: trailDetails,
                        focusedSegmentID: focusedSegmentID,
                        focusedRunNumber: focusedRunNumber,
                        extendsUnderBars: true)
                } else {
                    ProgressView("Loading map…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct RunMapView: View {
    private static let mapPreviewHeight: CGFloat = 320

    @Environment(\.modelContext) private var modelContext
    let number: Int
    let segment: RideSegment
    let preparedBase: SessionDetailBase?
    let preparedDetail: SessionDetailSegment?
    let preparedTrailDetails: SessionDetailTrailDetails?
    @Query private var trails: [Trail]
    @State private var showingFullScreenMap = false
    @State private var ownBase: SessionDetailBase?
    @State private var ownTrailDetails: SessionDetailTrailDetails?
    @State private var jumpComparisons: SessionJumpComparisons = .empty
    @State private var isPreparing = false
    @State private var prepareFailed = false
    @State private var showingSplitSheet = false
    @State private var correctionError: String?
    @Environment(\.dismiss) private var dismiss

    init(
        number: Int,
        segment: RideSegment,
        preparedBase: SessionDetailBase? = nil,
        preparedDetail: SessionDetailSegment? = nil,
        preparedTrailDetails: SessionDetailTrailDetails? = nil
    ) {
        self.number = number
        self.segment = segment
        self.preparedBase = preparedBase
        self.preparedDetail = preparedDetail
        self.preparedTrailDetails = preparedTrailDetails
    }

    private var activeBase: SessionDetailBase? {
        preparedBase ?? ownBase
    }

    private var activeDetail: SessionDetailSegment? {
        preparedDetail ?? ownBase?.segmentsByID[segment.id]
    }

    private var activeTrailDetails: SessionDetailTrailDetails? {
        preparedTrailDetails ?? ownTrailDetails
    }

    private var routePoints: [RoutePoint] {
        activeDetail?.routePoints ?? []
    }

    private var isLoaded: Bool {
        activeDetail != nil
    }

    var body: some View {
        ZStack {
            BermsBackground()
            if !isLoaded {
                if prepareFailed {
                    ContentUnavailableView {
                        Label("Map unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("This run's map could not be prepared.")
                    } actions: {
                        Button("Try Again") {
                            Task { await prepareIfNeeded(force: true) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: BermsSpacing.compact) {
                        ProgressView()
                        Text("Loading map…")
                            .font(.subheadline)
                            .foregroundStyle(Color.bermsMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if routePoints.isEmpty {
                ContentUnavailableView(
                    "No route", systemImage: "map",
                    description: Text("This run has no recorded GPS route."))
            } else {
                List {
                    Section {
                        if let activeBase {
                            SessionRouteMap(
                                base: activeBase, trailDetails: activeTrailDetails,
                                focusedSegmentID: segment.id, focusedRunNumber: number,
                                onExpand: { showingFullScreenMap = true }
                            )
                            .frame(height: Self.mapPreviewHeight)
                            .listRowInsets(EdgeInsets())
                        }
                    }
                    Section("Run stats") {
                        RunStatsCard(segment: segment, detail: activeDetail)
                    }
                    jumpsSection
                    Section("Trail") {
                        TrailSequenceCard(sequence: trailSequence, runNumber: number)
                    }
                }
                .fullScreenCover(isPresented: $showingFullScreenMap) {
                    FullScreenSummaryMap(
                        title: "Run \(number)", base: activeBase,
                        trailDetails: activeTrailDetails,
                        focusedSegmentID: segment.id,
                        focusedRunNumber: number)
                }
            }
        }
        .navigationTitle("Run \(number)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if segment.kind == .run {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSplitSheet = true
                    } label: {
                        Label("Split run", systemImage: "scissors")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSplitSheet) {
            SplitRunSheet(segment: segment) { index in
                splitRun(at: index)
            }
        }
        .alert(
            "Couldn't split run",
            isPresented: Binding(
                get: { correctionError != nil },
                set: { if !$0 { correctionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(correctionError ?? "")
        }
        .task(id: preparedDetail == nil) { await prepareIfNeeded() }
        .task(id: segment.id) { await prepareJumpComparisons() }
    }

    private func splitRun(at index: Int) {
        do {
            try SegmentEditor.split(segment, at: index, in: modelContext)
            showingSplitSheet = false
            dismiss()
        } catch {
            correctionError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var jumpsSection: some View {
        Section {
            if jumps.isEmpty {
                Text("No jumps detected in this run.")
                    .foregroundStyle(.secondary)
            } else {
                if notableJumps.isEmpty {
                    Text("No jumps over 0.4 s or 5 m in this run.")
                        .foregroundStyle(.secondary)
                }
                ForEach(notableJumps, id: \.index) { entry in
                    jumpLink(index: entry.index, jump: entry.jump)
                }
                if !smallerJumps.isEmpty {
                    DisclosureGroup("Smaller catches (\(smallerJumps.count))") {
                        ForEach(smallerJumps, id: \.index) { entry in
                            jumpLink(index: entry.index, jump: entry.jump)
                        }
                    }
                }
            }
        } header: {
            Text("Jumps")
        } footer: {
            Text("Notable: 0.4 s of air or 5 m long.")
        }
    }

    private func jumpLink(index: Int, jump: JumpEvent) -> some View {
        let attemptID = jumpAttemptID(index: index)
        let feature = jumpComparisons.feature(forAttemptID: attemptID)
        return NavigationLink {
            JumpComparisonView(
                attempt: attempt(at: index, jump: jump),
                feature: feature)
        } label: {
            RunJumpRow(
                number: index + 1,
                jump: jump,
                attemptID: attemptID,
                feature: feature)
        }
    }

    private var notableJumps: [(index: Int, jump: JumpEvent)] {
        jumps.enumerated()
            .filter { isNotable($0.element) }
            .map { (index: $0.offset, jump: $0.element) }
    }

    private var smallerJumps: [(index: Int, jump: JumpEvent)] {
        jumps.enumerated()
            .filter { !isNotable($0.element) }
            .map { (index: $0.offset, jump: $0.element) }
    }

    private func isNotable(_ jump: JumpEvent) -> Bool {
        jump.airtime >= 0.4 || (jump.lengthMeters ?? 0) >= 5
    }

    private var jumps: [JumpEvent] {
        activeDetail?.jumps ?? []
    }

    private func jumpAttemptID(index: Int) -> String {
        "\(segment.id.uuidString)-\(index)"
    }

    private func attempt(at index: Int, jump: JumpEvent) -> SessionJumpAttempt {
        let id = jumpAttemptID(index: index)
        if let existing = jumpComparisons.features
            .flatMap(\.attempts)
            .first(where: { $0.id == id })
        {
            return existing
        }
        return SessionJumpAttempt(
            id: id,
            segmentID: segment.id,
            runNumber: number,
            jumpNumber: index + 1,
            jump: jump)
    }

    @MainActor
    private func prepareJumpComparisons() async {
        guard let dayID = segment.day?.id else { return }
        let comparisons = await SessionDetailPresentationPreheater.prepareJumpComparisons(
            dayID: dayID,
            container: modelContext.container)
        guard !Task.isCancelled, let comparisons else { return }
        jumpComparisons = comparisons
    }

    private var trailSequence: String {
        guard let activeDetail, let activeTrailDetails else { return "Loading trails…" }
        return activeTrailDetails.sequenceBySegmentID[activeDetail.id] ?? "Trail not identified"
    }

    /// Prepares this run off the main actor when the caller has no presentation for
    /// it, so decoding and trail matching never run on the rendering path.
    @MainActor
    private func prepareIfNeeded(force: Bool = false) async {
        guard preparedDetail == nil, activeDetail == nil, !isPreparing || force else { return }
        if force { prepareFailed = false }
        let catalogID =
            segment.day.flatMap(TrailCatalogRegistry.resolvedCatalog(for:))?.id
        let selectionID = catalogID ?? TrailCatalogRegistry.automaticSelectionID
        var runKey: String?
        if let dayID = segment.day?.id {
            runKey = SessionDetailPresentationPreheater.runCacheKey(
                dayID: dayID,
                segmentID: segment.id,
                selectionID: selectionID,
                trails: trails)
            // A prepared day already covers every run in it, so reuse it before matching again.
            let dayKey = SessionDetailPresentationPreheater.cacheKey(
                dayID: dayID,
                selectionID: selectionID,
                trails: trails)
            if let dayEntry = SessionDetailPresentationCache.shared.entry(for: dayKey),
                dayEntry.base.segmentsByID[segment.id] != nil
            {
                ownBase = dayEntry.base
                ownTrailDetails = dayEntry.trailDetails
                return
            }
        }
        if let runKey, let cached = SessionDetailPresentationCache.shared.runEntry(for: runKey) {
            ownBase = cached.base
            ownTrailDetails = cached.trailDetails
            return
        }
        isPreparing = true
        defer { isPreparing = false }
        do {
            guard
                let entry = try await SessionDetailPresentationPreheater.prepareRun(
                    segmentID: segment.id,
                    manualCatalogID: catalogID,
                    container: modelContext.container,
                    onBase: { ownBase = $0 }
                )
            else { return }
            guard !Task.isCancelled else { return }
            ownTrailDetails = entry.trailDetails
            if let runKey {
                SessionDetailPresentationCache.shared.storeRun(entry, for: runKey)
            }
        } catch is CancellationError {
            return
        } catch {
            prepareFailed = true
        }
    }

}

struct RunStatsCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let segment: RideSegment
    let detail: SessionDetailSegment?

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.control) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                alignment: .leading, spacing: BermsSpacing.content
            ) {
                // Decoded values wait for the prepared detail; reading them from the
                // segment would decode its route and jumps on the rendering path.
                SummaryStat(label: "Duration", value: detail.map { BermsFormat.duration($0.duration) } ?? "…")
                SummaryStat(label: "Distance", value: BermsFormat.distance(segment.distanceMeters))
                SummaryStat(label: "Descent", value: BermsFormat.elevation(segment.verticalMeters))
                SummaryStat(label: "Top speed", value: BermsFormat.speed(segment.maximumSpeedMetersPerSecond))
                SummaryStat(label: "Jumps", value: detail.map { "\($0.jumps.count)" } ?? "…")
                SummaryStat(label: "Best airtime", value: bestAirtime)
                SummaryStat(label: "Longest jump", value: longestJump)
                SummaryStat(label: "Highest air", value: highestAir)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var bestAirtime: String {
        guard let detail else { return "…" }
        guard let airtime = detail.jumps.map(\.airtime).max() else { return "—" }
        return BermsFormat.airtime(airtime)
    }

    private var longestJump: String {
        guard let detail else { return "…" }
        return BermsFormat.jumpSize(detail.jumps.compactMap(\.lengthMeters).max())
    }

    private var highestAir: String {
        guard let detail else { return "…" }
        return BermsFormat.jumpSize(detail.jumps.compactMap(\.heightMeters).max())
    }
}

struct JumpStatsGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let jump: JumpEvent

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 3),
            alignment: .leading, spacing: BermsSpacing.content
        ) {
            SummaryStat(label: "Length", value: BermsFormat.jumpSize(jump.lengthMeters))
            SummaryStat(label: "Highest air", value: BermsFormat.jumpSize(jump.heightMeters))
            SummaryStat(label: "Airtime", value: BermsFormat.airtime(jump.airtime))
        }
        .accessibilityElement(children: .contain)
    }
}

struct RunJumpRow: View {
    let number: Int
    let jump: JumpEvent
    let attemptID: String
    let feature: SessionJumpFeature?

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.tight) {
            Text("Jump \(number)")
                .font(.headline)
            Text(jumpStatsLine(jump))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.bermsMuted)
            if let comparisonLine {
                Text(comparisonLine)
                    .font(.caption)
                    .foregroundStyle(Color.bermsMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Jump \(number)")
        .accessibilityValue(accessibilityValue)
    }

    private var comparisonLine: String? {
        guard let feature, feature.attempts.count > 1,
            let best = feature.attempts.max(by: {
                ($0.jump.lengthMeters ?? 0) < ($1.jump.lengthMeters ?? 0)
            })
        else { return nil }
        if best.id == attemptID {
            let runCount = Set(feature.attempts.map(\.runNumber)).count
            return runCount == 2
                ? "Best of 2 runs at this jump"
                : "Best of \(runCount) runs at this jump"
        }
        return "Best \(BermsFormat.jumpSize(best.jump.lengthMeters)) · Run \(best.runNumber)"
    }

    private var accessibilityValue: String {
        [jumpStatsLine(jump), comparisonLine].compactMap { $0 }.joined(separator: ", ")
    }
}

struct JumpComparisonView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let attempt: SessionJumpAttempt
    let feature: SessionJumpFeature?

    private var attempts: [SessionJumpAttempt] {
        (feature?.attempts ?? [attempt]).sorted {
            ($0.runNumber, $0.jumpNumber) < ($1.runNumber, $1.jumpNumber)
        }
    }

    private var bestLengthID: String? {
        attempts.max(by: { ($0.jump.lengthMeters ?? 0) < ($1.jump.lengthMeters ?? 0) })?.id
    }

    private func comparisonTitle(for other: SessionJumpAttempt) -> some View {
        Text("Run \(other.runNumber) · Jump \(other.jumpNumber)")
            .font(.headline)
    }

    private func comparisonValue(for other: SessionJumpAttempt) -> some View {
        Text(BermsFormat.jumpSize(other.jump.lengthMeters))
            .font(.headline.monospacedDigit())
    }

    var body: some View {
        List {
            Section("Run \(attempt.runNumber) · Jump \(attempt.jumpNumber)") {
                JumpStatsGrid(jump: attempt.jump)
            }
            if attempts.count > 1 {
                Section {
                    ForEach(attempts, id: \.id) { other in
                        VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: BermsSpacing.tight) {
                                    comparisonTitle(for: other)
                                    comparisonValue(for: other)
                                }
                            } else {
                                HStack {
                                    comparisonTitle(for: other)
                                    Spacer()
                                    comparisonValue(for: other)
                                }
                            }
                            Text(jumpStatsLine(other.jump))
                                .font(.caption)
                                .foregroundStyle(Color.bermsMuted)
                            if other.id == bestLengthID {
                                Text("Longest in session")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.bermsMuted)
                            }
                            if other.id == attempt.id {
                                Text("This run")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.bermsMuted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Across runs")
                } footer: {
                    Text(
                        "Matched by takeoff and landing location."
                    )
                }
            } else {
                Section {
                    Text("No other run in this session hit this jump.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Jump \(attempt.jumpNumber)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func jumpStatsLine(_ jump: JumpEvent) -> String {
    var parts: [String] = []
    if let length = jump.lengthMeters {
        parts.append(BermsFormat.jumpSize(length))
    }
    if let height = jump.heightMeters {
        parts.append("\(BermsFormat.jumpSize(height)) air")
    }
    parts.append(BermsFormat.airtime(jump.airtime))
    return parts.joined(separator: " · ")
}

struct TrailSequenceCard: View {
    let sequence: String
    let runNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: BermsSpacing.compact) {
            Text(sequence)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                sequence == "Trail not identified"
                    ? "Run \(runNumber) · GPS route only"
                    : "Run \(runNumber)"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.bermsMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sequence), Run \(runNumber)")
    }
}

/// Fast split: pick the stop that marks where one run ended and the next began.
private struct SplitRunSheet: View {
    let segment: RideSegment
    let onSplit: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private var candidates: [SegmentEditor.SplitCandidate] {
        SegmentEditor.splitCandidates(for: segment)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if candidates.isEmpty {
                        Text("No stops long enough to suggest a split point.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { candidate in
                            Button {
                                onSplit(candidate.index)
                            } label: {
                                row(for: candidate)
                            }
                        }
                    }
                } header: {
                    Text("Stops")
                } footer: {
                    Text(
                        "Split points come from stops of 15 s or more."
                    )
                }
                if let midpoint = SegmentEditor.midpointCandidate(for: segment) {
                    Section {
                        Button("Split in the middle") {
                            onSplit(midpoint.index)
                        }
                    } footer: {
                        Text("Use this when the run has no obvious stop.")
                    }
                }
            }
            .navigationTitle("Split run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(for candidate: SegmentEditor.SplitCandidate) -> some View {
        VStack(alignment: .leading, spacing: BermsSpacing.tight) {
            Text(candidate.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.headline)
            Text(
                "Stopped \(BermsFormat.duration(candidate.stoppedSeconds)) · "
                    + "\(BermsFormat.distance(candidate.distanceFromStart)) in"
            )
            .font(.caption)
            .foregroundStyle(Color.bermsMuted)
        }
        .accessibilityElement(children: .combine)
    }
}
