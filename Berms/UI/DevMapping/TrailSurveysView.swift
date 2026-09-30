#if DEBUG
    import SwiftUI

    struct DeveloperView: View {
        var body: some View {
            Form {
                NavigationLink("Trail surveys") { TrailSurveysView() }
                NavigationLink("Trail catalog") { TrailLibraryView() }
            }
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    struct TrailSurveysView: View {
        @ObservedObject private var store = TrailSurveyStore.shared
        @State private var catalogID = TrailCatalogRegistry.defaultCatalog.id
        @State private var slug = ""
        @State private var name = ""
        @State private var difficulty = TrailDifficulty.blue
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @State private var choices: [SurveyChoice] = []

        var body: some View {
            Form {
                if let error = store.errorMessage {
                    Section { Text(error) }
                }
                if let active = store.active {
                    Section("Active survey") {
                        NavigationLink(active.name) { SurveyDetailView(id: active.id) }
                        LabeledContent("Points", value: "\(active.pointCount)")
                        Button("Pause") { perform { try store.pause() } }
                        Button("Save") { perform { try store.save(active.id) } }
                    }
                } else {
                    Section("New survey") {
                        Picker("Park", selection: $catalogID) {
                            ForEach(TrailCatalogRegistry.catalogs) { catalog in
                                Text(catalog.resortName).tag(catalog.id)
                            }
                        }
                        if dynamicTypeSize.isAccessibilitySize,
                            let catalog = TrailCatalogRegistry.catalog(withID: catalogID)
                        {
                            Text(catalog.resortName)
                        }
                        Picker("Trail", selection: $slug) {
                            Text("New trail").tag("")
                            ForEach(choices) { choice in Text(choice.name).tag(choice.id) }
                        }
                        if dynamicTypeSize.isAccessibilitySize, let choice = choices.first(where: { $0.id == slug }) {
                            Text(choice.name)
                        }
                        if slug.isEmpty {
                            TextField("Trail name", text: $name)
                                .accessibilityLabel("Trail name")
                            Picker("Difficulty", selection: $difficulty) {
                                ForEach(TrailDifficulty.allCases, id: \.self) { value in Text(value.title).tag(value) }
                            }
                        }
                        Button("Start survey") {
                            perform {
                                guard let catalog = TrailCatalogRegistry.catalog(withID: catalogID) else { return }
                                let id = try store.create(
                                    catalog: catalog, slug: slug.isEmpty ? nil : slug,
                                    name: name, difficulty: difficulty.rawValue)
                                try store.resume(id)
                            }
                        }
                        .disabled(slug.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section {
                    ForEach(store.drafts) { draft in
                        NavigationLink {
                            SurveyDetailView(id: draft.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(draft.name)
                                Text(
                                    "\(draft.state.capitalized) · \(draft.passes.count) passes · \(draft.pointCount) points"
                                )
                                .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Drafts")
                } footer: {
                    Text(
                        "Surveys stay separate from rides and approved trails. Capture continues when this screen closes. Pause between passes to avoid recording approaches."
                    )
                }
            }
            .navigationTitle("Trail surveys")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: catalogID) { loadChoices() }
            .onChange(of: catalogID) { _, _ in slug = "" }
        }

        private func loadChoices() {
            perform {
                guard let catalog = TrailCatalogRegistry.catalog(withID: catalogID) else { return }
                let data = try CatalogSnapshotStore.shared.catalogData(catalog)
                let collection = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                choices = (collection?["features"] as? [[String: Any]] ?? []).compactMap { feature in
                    guard let properties = feature["properties"] as? [String: Any],
                        let slug = properties["slug"] as? String,
                        catalog.aliases[slug] == nil,
                        let name = properties["name"] as? String
                    else { return nil }
                    return SurveyChoice(id: slug, name: name)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }

        private func perform(_ action: () throws -> Void) {
            do { try action() } catch { store.errorMessage = error.localizedDescription }
        }
    }

    private struct SurveyChoice: Identifiable {
        let id: String
        let name: String
    }

    private struct SurveyDetailView: View {
        let id: UUID
        @ObservedObject private var store = TrailSurveyStore.shared
        @Environment(\.dismiss) private var dismiss
        @State private var exportURL: URL?
        @State private var confirmsDiscard = false
        @State private var isExporting = false

        private var draft: SurveyDraft? { store.drafts.first { $0.id == id } }

        var body: some View {
            Form {
                if let draft {
                    Section {
                        LabeledContent("State", value: draft.state.capitalized)
                        LabeledContent("Points", value: "\(draft.pointCount)")
                        LabeledContent("Passes", value: "\(draft.passes.count)")
                        LabeledContent("Base revision", value: String(draft.baseRevision.prefix(12)))
                        LabeledContent("Content version", value: "\(draft.contentVersion)")
                        if let version = draft.exportedVersion {
                            Text(version == draft.contentVersion ? "Export is current" : "Changed since export")
                        }
                        if let error = store.errorMessage { Text(error) }
                    }
                    if store.activeID == id {
                        Section {
                            Button("Pause") { perform { try store.pause() } }
                            Button("Save") { perform { try store.save(id) } }
                        }
                    } else {
                        Section("Proposal") {
                            TextField("Trail name", text: binding(\.name), axis: .vertical)
                                .accessibilityLabel("Trail name")
                                .disabled(draft.kind == "corroborateTrail")
                            TextField("Note", text: binding(\.note), axis: .vertical)
                            if draft.baselineJSON != nil {
                                Picker("Operation", selection: binding(\.kind)) {
                                    Text("Append evidence").tag("corroborateTrail")
                                    Text("Propose edit").tag("editTrail")
                                }
                            }
                            if draft.kind != "corroborateTrail" {
                                Picker("Difficulty", selection: binding(\.difficulty)) {
                                    ForEach(TrailDifficulty.allCases, id: \.self) { value in
                                        Text(value.title).tag(value.rawValue)
                                    }
                                }
                            }
                            if draft.kind == "editTrail" {
                                Toggle("Replace approved line", isOn: replacementBinding)
                                    .tint(Color.bermsSwitch)
                            }
                            if draft.kind == "addTrail" || draft.replacesGeometry == true {
                                Picker("Reviewed geometry pass", selection: selectedPassBinding) {
                                    Text("Select a pass").tag(UUID?.none)
                                    ForEach(draft.passes) { pass in
                                        Text("\(pass.startedAt.formatted()) · \(pass.pointCount) points").tag(
                                            Optional(pass.id))
                                    }
                                }
                            }
                        }
                        Section("Passes") {
                            ForEach(draft.passes) { pass in
                                NavigationLink {
                                    SurveyPassView(draftID: id, passID: pass.id)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(pass.startedAt, style: .time)
                                        Text("\(pass.pointCount) points · \(pass.direction)")
                                            .font(.footnote).foregroundStyle(.secondary)
                                        if let interruption = pass.interruption { Text(interruption).font(.footnote) }
                                    }
                                }
                            }
                        }
                        Section {
                            Button("Resume with a new pass") { perform { try store.resume(id) } }.disabled(
                                store.isActive)
                            Button("Save") { perform { try store.save(id) } }
                            Button(isExporting ? "Preparing export…" : "Prepare export") {
                                isExporting = true
                                Task {
                                    defer { isExporting = false }
                                    do { exportURL = try await store.export(id) } catch {
                                        store.errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(
                                isExporting
                                    || ((draft.kind == "addTrail" || draft.replacesGeometry == true)
                                        && draft.selectedPassID == nil)
                            )
                            if let exportURL { ShareLink("Share survey ZIP", item: exportURL) }
                            Button("Discard", role: .destructive) { confirmsDiscard = true }
                        }
                    }
                }
            }
            .navigationTitle(draft?.name ?? "Survey")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Discard this survey?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    perform {
                        try store.discard(id)
                        dismiss()
                    }
                }
            }
        }

        private var replacementBinding: Binding<Bool> {
            Binding(
                get: { draft?.replacesGeometry == true },
                set: { value in
                    guard var updated = draft else { return }
                    updated.replacesGeometry = value
                    perform {
                        try store.update(updated)
                        exportURL = nil
                    }
                })
        }

        private var selectedPassBinding: Binding<UUID?> {
            Binding(
                get: { draft?.selectedPassID },
                set: { value in
                    guard var updated = draft else { return }
                    updated.selectedPassID = value
                    perform {
                        try store.update(updated)
                        exportURL = nil
                    }
                })
        }

        private func binding(_ keyPath: WritableKeyPath<SurveyDraft, String>) -> Binding<String> {
            Binding(
                get: { draft?[keyPath: keyPath] ?? "" },
                set: { value in
                    guard var updated = draft else { return }
                    updated[keyPath: keyPath] = value
                    perform {
                        try store.update(updated)
                        exportURL = nil
                    }
                })
        }

        private func perform(_ action: () throws -> Void) {
            do { try action() } catch { store.errorMessage = error.localizedDescription }
        }
    }

    private struct SurveyPassView: View {
        let draftID: UUID
        let passID: UUID
        @ObservedObject private var store = TrailSurveyStore.shared
        @State private var excludedIndices = ""
        private var draft: SurveyDraft? { store.drafts.first { $0.id == draftID } }
        private var pass: SurveyPass? { draft?.passes.first { $0.id == passID } }

        var body: some View {
            Form {
                Picker(
                    "Direction",
                    selection: Binding(
                        get: { pass?.direction ?? "unknown" },
                        set: { direction in
                            update { $0.direction = direction }
                        })
                ) {
                    Text("Unknown").tag("unknown")
                    Text("Forward").tag("forward")
                    Text("Reverse").tag("reverse")
                }
                TextField("Excluded sample indices (comma separated)", text: $excludedIndices)
                    .keyboardType(.numbersAndPunctuation)
                Button("Save exclusions") {
                    let values = excludedIndices.split(separator: ",").compactMap {
                        Int($0.trimmingCharacters(in: .whitespaces))
                    }
                    guard values.allSatisfy({ $0 >= 0 && $0 < (pass?.pointCount ?? 0) }) else {
                        store.errorMessage = "Exclusions must be valid zero-based sample indices."
                        return
                    }
                    update { $0.exclusions = Array(Set(values)).sorted() }
                }
                Text("Raw fixes remain preserved. Excluded indices are omitted only from the proposed line.")
            }
            .navigationTitle("Pass")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { excludedIndices = pass?.exclusions.map(String.init).joined(separator: ",") ?? "" }
        }

        private func update(_ action: (inout SurveyPass) -> Void) {
            guard var draft, let index = draft.passes.firstIndex(where: { $0.id == passID }) else { return }
            action(&draft.passes[index])
            do { try store.update(draft) } catch { store.errorMessage = error.localizedDescription }
        }
    }
#endif
