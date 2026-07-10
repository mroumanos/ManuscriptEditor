// JournalsView.swift
//
// The journals panel: add target journals, edit their requirements, and view a
// live checklist of whether the source manuscript meets those requirements.
//
// OVERALL FLOW
// ─────────────────────────────────────────────────────────────────────────────
// 1. User clicks "Add Journal" → AddJournalSheet appears.
// 2. They pick a preset (Nature, NEJM, …) or type a custom name → a new Journal
//    value is appended to manuscript.journals.
// 3. Journal appears in the left list.  Clicking it opens JournalDetailView.
// 4. JournalDetailView has three tabs:
//      Requirements  — editable form of all journal rules
//      Checklist     — live pass/fail list run against the current source manuscript
//      Cuts          — stub for Phase-2 LLM adaptation
//
// PHASE 2 NOTE
// ─────────────────────────────────────────────────────────────────────────────
// The "Cuts" tab is intentionally a placeholder.  In Phase 2, clicking
// "Create Cut" will: (a) snapshot the source manuscript, (b) call an LLM to
// adapt it to the journal's requirements, (c) store the result in
// JournalVersion.content, and (d) create a git branch for the cut.

import SwiftUI

// MARK: - JournalsView

/// The journals panel: list of journals on the left, tabbed detail on the right.
struct JournalsView: View {
    @Environment(ManuscriptStore.self) private var store

    /// UUID of the selected journal.
    @State private var selectedID: UUID?
    /// Whether the "Add Journal" sheet is showing.
    @State private var showAddSheet = false

    /// All journals attached to the current manuscript.
    private var journals: [Journal] {
        store.manuscript?.journals ?? []
    }

    var body: some View {
        HSplitView {
            journalList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            if let id = selectedID,
               let journal = journals.first(where: { $0.id == id }) {
                JournalDetailView(journal: journal)
            } else {
                detailPlaceholder
            }
        }
        .navigationTitle("Journals")
        .sheet(isPresented: $showAddSheet) {
            AddJournalSheet(isPresented: $showAddSheet) { journal in
                store.addJournal(journal)
                selectedID = journal.id   // auto-select the new journal
            }
        }
    }

    // MARK: - Left panel

    private var journalList: some View {
        VStack(spacing: 0) {
            if journals.isEmpty {
                emptyListState
            } else {
                List(selection: $selectedID) {
                    ForEach(journals) { journal in
                        journalRow(journal).tag(journal.id)
                    }
                    // Swipe left on a row to delete.
                    .onDelete { store.deleteJournals(at: $0) }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Journal", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(10)
                .disabled(store.manuscript == nil)
                Spacer()
                Text("\(journals.count) journal\(journals.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
            }
        }
    }

    private var emptyListState: some View {
        VStack {
            Spacer()
            Image(systemName: "building.columns")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No journals added")
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func journalRow(_ journal: Journal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(journal.name.isEmpty ? "(unnamed journal)" : journal.name)
                .fontWeight(.medium)
                .lineLimit(1)
            if !journal.publisher.isEmpty {
                Text(journal.publisher)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Right panel placeholder (no journal selected)

    private var detailPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "building.columns")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text(journals.isEmpty
                 ? "Add a journal to see its requirements\nand check your manuscript against them."
                 : "Select a journal")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if journals.isEmpty {
                Button("Add Journal") { showAddSheet = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.manuscript == nil)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - JournalDetailView

/// Three-tab view for one journal: Requirements editor, live Checklist, and Cuts stub.
struct JournalDetailView: View {
    @Environment(ManuscriptStore.self) private var store
    /// The saved journal value from the store.
    let journal: Journal
    /// Mutable working copy; changes are pushed to the store via `onChange`.
    @State private var draft: Journal
    @State private var selectedTab = 0

    init(journal: Journal) {
        self.journal = journal
        _draft = State(initialValue: journal)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            requirementsTab
                .tabItem { Label("Requirements", systemImage: "list.bullet.clipboard") }
                .tag(0)
            checklistTab
                .tabItem { Label("Checklist", systemImage: "checklist") }
                .tag(1)
        }
        // When a different journal is selected, reload draft.
        .onChange(of: journal.id) { _, _ in draft = journal }
    }

    // MARK: - Tab 1: Requirements

    private var requirementsTab: some View {
        ScrollView {
            Form {
                Section("Journal Info") {
                    TextField("Name",            text: $draft.name)
                    TextField("Publisher",        text: $draft.publisher)
                    TextField("Submission URL",   text: $draft.submissionURL)
                }

                Section("Word Limits") {
                    optionalIntRow("Body word limit",     value: Binding(get: { draft.requirements.maxBodyWords },     set: { draft.requirements.maxBodyWords = $0 }))
                    optionalIntRow("Abstract word limit", value: Binding(get: { draft.requirements.maxAbstractWords }, set: { draft.requirements.maxAbstractWords = $0 }))
                }

                Section("Asset Limits") {
                    optionalIntRow("Max figures",    value: Binding(get: { draft.requirements.maxFigures },    set: { draft.requirements.maxFigures = $0 }))
                    optionalIntRow("Max tables",     value: Binding(get: { draft.requirements.maxTables },     set: { draft.requirements.maxTables = $0 }))
                    optionalIntRow("Max references", value: Binding(get: { draft.requirements.maxReferences }, set: { draft.requirements.maxReferences = $0 }))
                }

                Section("Format") {
                    Picker("Citation style", selection: $draft.requirements.citationStyle) {
                        ForEach(CitationStyle.allCases, id: \.self) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    Toggle("Figures submitted separately", isOn: $draft.requirements.requiresSeparateFigures)
                }

                Section("Required Sections") {
                    // One Toggle per section type (excluding .custom, which is user-defined).
                    ForEach(SectionType.allCases.filter { $0 != .custom }, id: \.self) { type in
                        Toggle(type.rawValue, isOn: Binding(
                            get: { draft.requirements.requiredSections.contains(type) },
                            set: { on in
                                if on {
                                    if !draft.requirements.requiredSections.contains(type) {
                                        draft.requirements.requiredSections.append(type)
                                    }
                                } else {
                                    draft.requirements.requiredSections.removeAll { $0 == type }
                                }
                            }
                        ))
                    }
                }

                // Custom rules are free-text strings the user adds for journal-specific checks.
                Section("Custom Rules") {
                    ForEach(draft.requirements.customRules.indices, id: \.self) { i in
                        HStack {
                            TextField("Rule description", text: $draft.requirements.customRules[i])
                            Button {
                                draft.requirements.customRules.remove(at: i)
                                store.updateJournal(draft)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        draft.requirements.customRules.append("")
                        store.updateJournal(draft)
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 16)
        }
        // Auto-save each field to the store.
        .onChange(of: draft.name)                                   { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.publisher)                              { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.submissionURL)                          { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.requirements.maxBodyWords)              { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.requirements.maxAbstractWords)          { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.requirements.maxFigures)                { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.requirements.maxTables)                 { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.requirements.maxReferences)             { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.requirements.citationStyle)             { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.requirements.requiresSeparateFigures)   { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.requirements.requiredSections)          { _, _ in store.updateJournal(draft) }
        .onChange(of: draft.requirements.customRules)               { _, _ in store.updateJournal(draft) }
    }

    /// A row showing an optional integer field with "No limit" placeholder.
    @ViewBuilder
    private func optionalIntRow(_ label: String, value: Binding<Int?>) -> some View {
        LabeledContent(label) {
            TextField("No limit", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
        }
    }

    // MARK: - Tab 2: Checklist

    /// Runs `ChecklistService` against the current source manuscript every time this
    /// view renders.  Because `store.manuscript` is `@Observable`, any change to the
    /// manuscript (new word typed, figure added, etc.) causes this view to re-render
    /// and the checklist to update automatically.
    private var checklistTab: some View {
        // Compute checklist results using the draft requirements so the checklist
        // reflects unsaved changes in real time.
        let results: [ChecklistResult]
        if let m = store.manuscript {
            results = ChecklistService.run(manuscript: m, requirements: draft.requirements)
        } else {
            results = []
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                checklistHeader(results: results)
                ForEach(results) { result in
                    ChecklistRow(result: result)
                }
                if results.isEmpty {
                    ContentUnavailableView("No checks configured", systemImage: "checklist")
                }
            }
            .padding(20)
        }
    }

    /// Summary banner at the top of the checklist: pass count, colour-coded status.
    private func checklistHeader(results: [ChecklistResult]) -> some View {
        let passed  = results.filter(\.passed).count
        let total   = results.count
        let allPass = total > 0 && passed == total
        let color: Color = allPass ? .green : (passed == 0 ? .red : .orange)

        return HStack(spacing: 12) {
            Image(systemName: allPass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(allPass
                     ? "Ready to submit"
                     : "\(total - passed) item\(total - passed == 1 ? "" : "s") need attention")
                    .fontWeight(.semibold)
                Text("\(passed) of \(total) checks passed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

}

// MARK: - ChecklistRow

/// One pass/fail row in the checklist tab.
struct ChecklistRow: View {
    let result: ChecklistResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Green checkmark = passed; red X = failed.
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.passed ? .green : .red)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.rule).fontWeight(.medium)
                Text(result.details).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - AddJournalSheet

/// Modal sheet for adding a new journal — either from a preset or as a blank entry.
struct AddJournalSheet: View {
    @Binding var isPresented: Bool
    /// Called when the user taps "Add"; receives the fully configured Journal value.
    let onAdd: (Journal) -> Void

    /// Whether the user is picking from a preset or creating a blank custom journal.
    enum AddMode { case preset, custom }

    @State private var mode: AddMode = .preset
    /// Name of the selected preset in the list (used as a unique identifier).
    @State private var selectedPresetName: String? = JournalPresets.all.first?.name
    /// Name typed when mode == .custom.
    @State private var customName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Journal").font(.headline)

            // Segmented control to switch between preset picker and custom name entry.
            Picker("", selection: $mode) {
                Text("From Preset").tag(AddMode.preset)
                Text("Custom").tag(AddMode.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .preset {
                // Scrollable list of preset journals; tapping one highlights it.
                List(selection: $selectedPresetName) {
                    ForEach(JournalPresets.all) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).fontWeight(.medium)
                            Text(preset.publisher).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(preset.name)   // tag = name string (unique among presets)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 220)
            } else {
                TextField("Journal name", text: $customName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(makeJournal())
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addDisabled)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    /// True when the "Add" button should be disabled (nothing selected / no name typed).
    private var addDisabled: Bool {
        mode == .custom ? customName.isEmpty : selectedPresetName == nil
    }

    /// Builds the `Journal` value to add, from either the selected preset or a blank entry.
    private func makeJournal() -> Journal {
        if mode == .preset,
           let name = selectedPresetName,
           let preset = JournalPresets.all.first(where: { $0.name == name }) {
            return Journal(
                id: UUID(), name: preset.name, publisher: preset.publisher,
                submissionURL: "",
                requirements: preset.requirements,
                viewConfigID: nil, createdAt: Date()
            )
        }
        return Journal(
            id: UUID(), name: customName, publisher: "",
            submissionURL: "",
            requirements: JournalRequirements(),
            viewConfigID: nil, createdAt: Date()
        )
    }
}
