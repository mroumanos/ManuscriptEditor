// JournalLibraryView.swift
//
// Preferences → Journals: the global journal library.  Search reusable
// journal profiles and inspect their details (name, country, publisher, how
// many requirements they carry, whether they bundle an export outline).
// Entries come from the built-in presets, "Save to Journal Library" in a
// manuscript's Export/Checks panes, and manual editing here.  Adding a
// journal to a manuscript (Sync → Add Journal) picks from this library.

import SwiftUI

struct JournalLibraryView: View {
    @Environment(AppStore.self) private var appStore

    @State private var query = ""
    @State private var selectedID: UUID?

    private var filtered: [Journal] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = appStore.journalLibrary.sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q)
                || $0.publisher.lowercased().contains(q)
                || ($0.country ?? "").lowercased().contains(q)
        }
    }

    /// Non-nil requirement limits + required sections + custom rules.
    private func requirementCount(_ journal: Journal) -> Int {
        let r = journal.requirements
        let limits = [r.maxBodyWords, r.maxAbstractWords, r.maxFigures,
                      r.maxTables, r.maxReferences].compactMap { $0 }.count
        return limits + r.requiredSections.count + r.customRules.count
            + (r.requiresSeparateFigures ? 1 : 0)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search journals…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)

                List(selection: $selectedID) {
                    ForEach(filtered) { journal in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(journal.name).fontWeight(.medium)
                                Text([journal.publisher, journal.country]
                                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                                    .joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(requirementCount(journal)) req")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .tag(journal.id)
                        .contextMenu {
                            Button("Delete Journal", role: .destructive) { delete(journal) }
                        }
                    }
                    .onDelete { offsets in
                        // Offsets are relative to the filtered list.
                        let ids = offsets.compactMap { filtered.indices.contains($0) ? filtered[$0].id : nil }
                        let indexes = IndexSet(appStore.journalLibrary.enumerated()
                            .filter { ids.contains($0.element.id) }
                            .map(\.offset))
                        appStore.deleteLibraryJournals(at: indexes)
                    }
                }
                .listStyle(.plain)

                Divider()
                HStack {
                    Button {
                        var entry = Journal.empty()
                        entry.name = "New Journal"
                        appStore.upsertLibraryJournal(entry)
                        selectedID = entry.id
                    } label: {
                        Label("Add Journal", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .padding(10)
                    Spacer()
                    Text("\(appStore.journalLibrary.count) in library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 10)
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID,
           let journal = appStore.journalLibrary.first(where: { $0.id == id }) {
            LibraryJournalForm(journal: journal)
        } else {
            ContentUnavailableView(
                "No Journal Selected",
                systemImage: "building.columns",
                description: Text("Search the library and select a journal to see its details.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    fileprivate func delete(_ journal: Journal) {
        if let idx = appStore.journalLibrary.firstIndex(where: { $0.id == journal.id }) {
            appStore.deleteLibraryJournals(at: IndexSet([idx]))
        }
        if selectedID == journal.id { selectedID = nil }
    }
}

// MARK: - LibraryJournalForm

private struct LibraryJournalForm: View {
    @Environment(AppStore.self) private var appStore
    let journal: Journal
    @State private var draft: Journal

    init(journal: Journal) {
        self.journal = journal
        _draft = State(initialValue: journal)
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Journal") {
                    TextField("Name", text: $draft.name)
                    TextField("Publisher", text: $draft.publisher)
                    TextField("Country", text: Binding(
                        get: { draft.country ?? "" },
                        set: { draft.country = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("Submission URL", text: $draft.submissionURL)
                }

                Section("Requirements") {
                    limitField("Max body words",     \.maxBodyWords)
                    limitField("Max abstract words", \.maxAbstractWords)
                    limitField("Max figures",        \.maxFigures)
                    limitField("Max tables",         \.maxTables)
                    limitField("Max references",     \.maxReferences)
                    LabeledContent("Required sections") {
                        Text(draft.requirements.requiredSections.isEmpty
                             ? "—"
                             : draft.requirements.requiredSections.map(\.rawValue).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Custom rules") {
                        Text("\(draft.requirements.customRules.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Export Outline") {
                    Text(draft.exportConfig == nil
                         ? "None bundled — manuscripts derive a standard outline."
                         : "Bundled: \(draft.exportConfig!.documents.count) document\(draft.exportConfig!.documents.count == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Full requirement/outline editing happens inside a manuscript (journal settings, Export pane) — use \"Save to Journal Library\" there to bring refinements back here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Delete Journal from Library", role: .destructive) {
                        if let idx = appStore.journalLibrary.firstIndex(where: { $0.id == journal.id }) {
                            appStore.deleteLibraryJournals(at: IndexSet([idx]))
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: draft.name)          { _, _ in appStore.upsertLibraryJournal(draft) }
        .onChange(of: draft.publisher)     { _, _ in appStore.upsertLibraryJournal(draft) }
        .onChange(of: draft.country)       { _, _ in appStore.upsertLibraryJournal(draft) }
        .onChange(of: draft.submissionURL) { _, _ in appStore.upsertLibraryJournal(draft) }
        .onChange(of: draft.requirements.maxBodyWords)     { _, _ in appStore.upsertLibraryJournal(draft) }
        .onChange(of: draft.requirements.maxAbstractWords) { _, _ in appStore.upsertLibraryJournal(draft) }
        .onChange(of: draft.requirements.maxFigures)       { _, _ in appStore.upsertLibraryJournal(draft) }
        .onChange(of: draft.requirements.maxTables)        { _, _ in appStore.upsertLibraryJournal(draft) }
        .onChange(of: draft.requirements.maxReferences)    { _, _ in appStore.upsertLibraryJournal(draft) }
        .onChange(of: journal.id)          { _, _ in draft = journal }
    }

    private func limitField(_ label: String,
                            _ keyPath: WritableKeyPath<JournalRequirements, Int?>) -> some View {
        LabeledContent(label) {
            TextField("none", value: Binding(
                get: { draft.requirements[keyPath: keyPath] },
                set: { draft.requirements[keyPath: keyPath] = $0 }
            ), format: .number)
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
        }
    }
}
