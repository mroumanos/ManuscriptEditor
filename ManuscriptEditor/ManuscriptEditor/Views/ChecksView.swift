// ChecksView.swift
//
// The Checks panel: the live submission **checklist** for a journal — every
// requirement (word limits, asset limits, required sections, custom rules)
// evaluated against the pane's content with a green ✓ / red ✗ per rule.
//
// Version-aware: a journal pane evaluates that version's content against its
// own journal's requirements, so Checks renders one live pane per open tab in
// side-by-side (just like Abstract).  The Source pane picks a journal to check
// against.  Everything recomputes on every edit because the stores are
// `@Observable`.
//
// Requirements *editing* lives in the Journals settings (JournalDetailView);
// this pane is intentionally just the checklist.

import SwiftUI

struct ChecksView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this checklist evaluates (Source by default).
    var versionRef: VersionRef = .source

    private var journals: [Journal] { store.manuscript?.journals ?? [] }

    /// The journal behind this pane's tab.  The pane IS its tab's journal —
    /// there is no picker; the Source pane has no requirements of its own
    /// (Source uses empty defaults per the domain model).
    private var paneJournal: Journal? {
        guard case .version(let id) = versionRef,
              let jid = store.versions.first(where: { $0.id == id })?.journalID
        else { return nil }
        return journals.first { $0.id == jid }
    }

    /// Drives the requirements editor sheet / save-to-library sheet.
    @State private var editingRequirements = false
    @State private var savingToLibrary = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if store.manuscript(for: versionRef) == nil {
                    ContentUnavailableView("No manuscript open", systemImage: "doc")
                } else if let journal = paneJournal {
                    header(journal)
                    checklist(journal)
                } else {
                    noJournalState
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $editingRequirements) {
            if let journal = paneJournal {
                RequirementsEditorSheet(journal: journal, isPresented: $editingRequirements)
            }
        }
        .sheet(isPresented: $savingToLibrary) {
            if let journal = paneJournal {
                SaveToJournalLibrarySheet(journal: journal, isPresented: $savingToLibrary)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ journal: Journal) -> some View {
        HStack {
            Text(journal.displayName).font(.headline)
            // Straight to the journal's author instructions — the checks'
            // source of truth.
            if !journal.submissionURL.isEmpty, let url = URL(string: journal.submissionURL) {
                Link(destination: url) {
                    Label("Author instructions", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .help(journal.submissionURL)
            }
            Spacer()
            Button("Edit Requirements…") { editingRequirements = true }
            Button {
                savingToLibrary = true
            } label: {
                Label("Save to Journal Library…", systemImage: "books.vertical")
            }
            .help("Store this journal's checks (and export outline) as a reusable library profile")
        }
    }

    // MARK: - Checklist

    @ViewBuilder
    private func checklist(_ journal: Journal) -> some View {
        if let manuscript = store.manuscript(for: versionRef) {
            let results = ChecklistService.run(manuscript: manuscript, journal: journal,
                                               figureURL: { store.figureURL(for: $0) })
            let technical = results.filter { !$0.manual }
            let manualRules = results.filter(\.manual)
            summaryBanner(results)
            if !technical.isEmpty {
                sectionHeader("Technical", note: "checked automatically against the manuscript and export")
                ForEach(technical) { result in
                    ChecklistRow(result: result)
                }
            }
            if !manualRules.isEmpty {
                sectionHeader("Manual", note: "tick each box once you've verified it yourself")
                ForEach(manualRules) { result in
                    ChecklistRow(result: result) {
                        store.toggleManualCheck(journalID: journal.id, rule: result.rule)
                    }
                }
            }
            if results.isEmpty {
                Text("This journal has no requirements configured yet — use Edit Requirements… above to add limits and rules.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionHeader(_ title: String, note: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(note)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }

    private func summaryBanner(_ results: [ChecklistResult]) -> some View {
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

    // MARK: - Empty state

    private var noJournalState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("Source Has No Requirements")
                    .font(.title3.weight(.semibold))
                Text("Checks evaluate a journal cut against that journal's requirements.\nSwitch to a journal tab above to see its checklist.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ChecklistRow

/// One requirement check with a green ✓ / red ✗ verdict.
struct ChecklistRow: View {
    let result: ChecklistResult
    /// Set for manual rules: the row renders as a checkbox (neutral until
    /// ticked — an unverified item is a to-do, not a failure) and clicking
    /// anywhere on it toggles.
    var onToggle: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if onToggle != nil {
                Image(systemName: result.passed ? "checkmark.square.fill" : "square")
                    .foregroundStyle(result.passed ? Color.green : Color.secondary)
                    .padding(.top, 1)
            } else {
                Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.passed ? .green : .red)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.rule).fontWeight(.medium)
                Text(result.details).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
    }
}

// MARK: - RequirementsEditorSheet

/// Edits one manuscript journal's requirements (limits + custom rules).
struct RequirementsEditorSheet: View {
    @Environment(ManuscriptStore.self) private var store
    let journal: Journal
    @Binding var isPresented: Bool

    @State private var draft: JournalRequirements
    @State private var newRule = ""

    init(journal: Journal, isPresented: Binding<Bool>) {
        self.journal = journal
        self._isPresented = isPresented
        _draft = State(initialValue: journal.requirements)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(journal.name) Requirements").font(.headline)

            Form {
                Section("Limits") {
                    limitField("Max body words",     \.maxBodyWords)
                    limitField("Max abstract words", \.maxAbstractWords)
                    limitField("Max figures",        \.maxFigures)
                    limitField("Max tables",         \.maxTables)
                    limitField("Max references",     \.maxReferences)
                    Toggle("Requires separate figures document", isOn: $draft.requiresSeparateFigures)
                }
                Section("Custom Rules (checked manually)") {
                    ForEach(draft.customRules.indices, id: \.self) { index in
                        HStack {
                            Text(draft.customRules[index])
                            Spacer()
                            Button {
                                draft.customRules.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("New rule (e.g. \"Cover letter required\")", text: $newRule)
                        Button("Add") {
                            let trimmed = newRule.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            draft.customRules.append(trimmed)
                            newRule = ""
                        }
                        .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 340)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = journal
                    updated.requirements = draft
                    store.updateJournal(updated)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func limitField(_ label: String,
                            _ keyPath: WritableKeyPath<JournalRequirements, Int?>) -> some View {
        LabeledContent(label) {
            TextField("none", value: Binding(
                get: { draft[keyPath: keyPath] },
                set: { draft[keyPath: keyPath] = $0 }
            ), format: .number)
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
        }
    }
}

// MARK: - SaveToJournalLibrarySheet

/// Saves a manuscript journal's profile (requirements + export outline) into
/// the global library — as a new entry or overwriting an existing one.
struct SaveToJournalLibrarySheet: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    let journal: Journal
    @Binding var isPresented: Bool

    private enum Destination: Hashable { case new, existing(UUID) }
    @State private var destination: Destination = .new
    @State private var name: String = ""
    @State private var country: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save to Journal Library").font(.headline)

            Picker("Save as", selection: $destination) {
                Text("New library journal").tag(Destination.new)
                ForEach(appStore.journalLibrary) { entry in
                    Text("Overwrite \"\(entry.name)\"").tag(Destination.existing(entry.id))
                }
            }

            if destination == .new {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("Country (optional)", text: $country)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Stores this journal's requirements and export outline as a reusable profile — available in Settings → Journals and when adding a journal to any manuscript.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination == .new
                          && name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { name = journal.name }
    }

    private func save() {
        // Effective export outline: the stored customization or the standard
        // derivation for this journal's current content.
        let outline = store.exportConfig(forJournal: journal.id)
        switch destination {
        case .new:
            var entry = journal
            entry.id = UUID()
            entry.name = name.trimmingCharacters(in: .whitespaces)
            entry.country = country.isEmpty ? nil : country
            entry.exportConfig = outline
            entry.viewConfigID = nil
            appStore.upsertLibraryJournal(entry)
        case .existing(let id):
            guard var entry = appStore.journalLibrary.first(where: { $0.id == id }) else { return }
            entry.requirements = journal.requirements
            entry.exportConfig = outline
            appStore.upsertLibraryJournal(entry)
        }
    }
}
