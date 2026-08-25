// ChecksView.swift
//
// The Checks panel, in two halves:
//
//   CONFIGURATION  the three files this journal is made of — requirements,
//                  checks, structure — each openable, each editable, each
//                  flagged when this manuscript's copy has drifted from the
//                  user's library.
//   CHECKLIST      the live verdict: every check evaluated against the
//                  pane's content, green ✓ / red ✗, manual ones as boxes.
//
// Version-aware: a journal pane evaluates that version's content against its
// own journal's profile, so Checks renders one live pane per open tab in
// side-by-side (just like Abstract).  Everything recomputes on every edit
// because the stores are `@Observable`.

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

    @State private var editingRequirements = false
    @State private var editingRules = false
    @State private var editingStructure = false
    /// Set when saving would overwrite a same-named library profile with a
    /// different GUID — the one case that needs confirming.
    @State private var replacingLibraryID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if store.manuscript(for: versionRef) == nil {
                    ContentUnavailableView("No manuscript open", systemImage: "doc")
                } else if let journal = paneJournal {
                    header(journal)
                    configuration(journal)
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
                SourceRequirementsSheet(journal: journal, isPresented: $editingRequirements)
            }
        }
        .sheet(isPresented: $editingRules) {
            if let journal = paneJournal {
                CheckRulesEditor(journal: journal, isPresented: $editingRules)
            }
        }
        .sheet(isPresented: $editingStructure) {
            if let journal = paneJournal {
                StructureEditorSheet(journal: journal, isPresented: $editingStructure)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ journal: Journal) -> some View {
        let status = store.libraryStatus(for: journal)
        HStack(spacing: 10) {
            Text(journal.displayName).font(.headline)
            Spacer()
            if let link = store.profileLink(for: journal) {
                if link.url.isEmpty {
                    Label(link.label, systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let url = URL(string: link.url) {
                    Link(destination: url) {
                        Label(link.label, systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.caption2)
                    }
                    .help("Open this journal's configuration: \(link.url)")
                }
            }
            if status.canSave {
                Button {
                    if case .nameMatchDifferentID(let id) = status {
                        replacingLibraryID = id
                    } else {
                        store.saveProfileToLibrary(journalID: journal.id)
                    }
                } label: {
                    Label(status.saveVerb, systemImage: "books.vertical")
                }
                .help(saveHelp(status, journal: journal))
            } else {
                Label("Matches your library", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Replace \"\(journal.displayName)\" in your journal library?",
            isPresented: Binding(get: { replacingLibraryID != nil },
                                 set: { if !$0 { replacingLibraryID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let id = replacingLibraryID {
                    store.saveProfileToLibrary(journalID: journal.id, replacingID: id)
                }
                replacingLibraryID = nil
            }
            Button("Add as a Separate Profile") {
                store.saveProfileToLibrary(journalID: journal.id)
                replacingLibraryID = nil
            }
            Button("Cancel", role: .cancel) { replacingLibraryID = nil }
        } message: {
            Text("Your library already has a profile with this name, but a different identifier. Replacing overwrites it and links this manuscript to it.")
        }
    }

    private func saveHelp(_ status: ProfileLibraryStatus, journal: Journal) -> String {
        switch status {
        case .matches:
            return "This manuscript's configuration matches your library."
        case .differs(let parts):
            let names = parts.sorted { $0.rawValue < $1.rawValue }.map(\.label)
            return "Your library's copy differs in: \(names.joined(separator: ", ")). Saving replaces it."
        case .nameMatchDifferentID:
            return "Your library has a profile with this name but a different identifier."
        case .absent:
            return "Your library has no profile for \(journal.displayName) — saving adds it."
        }
    }

    // MARK: - Configuration (the three files)

    /// The journal's three configuration files, each with its own drift
    /// warning: knowing WHICH half moved is the point of splitting them.
    @ViewBuilder
    private func configuration(_ journal: Journal) -> some View {
        let flagged = store.libraryStatus(for: journal).flaggedParts
        let requirements = journal.sourceRequirements ?? SourceRequirements()
        let checks = journal.checkRules ?? []
        let structure = journal.structure ?? JournalStructure()

        VStack(alignment: .leading, spacing: 0) {
            configRow(
                .requirements,
                detail: requirements.bullets.isEmpty
                    ? "No requirements yet"
                    : "\(requirements.bullets.count) requirement\(requirements.bullets.count == 1 ? "" : "s")",
                flagged: flagged.contains(.requirements)
            ) { editingRequirements = true }

            Divider()

            configRow(
                .checks,
                detail: checks.isEmpty
                    ? "No checks yet"
                    : "\(checks.filter { !$0.isManual }.count) automatic · \(checks.filter(\.isManual).count) manual",
                flagged: flagged.contains(.checks)
            ) { editingRules = true }

            Divider()

            configRow(
                .structure,
                detail: structure.sections.isEmpty
                    ? "No structure yet"
                    : "\(structure.sections.count) section\(structure.sections.count == 1 ? "" : "s") · \(structure.requiredTitles.count) required",
                flagged: flagged.contains(.structure)
            ) { editingStructure = true }
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private func configRow(_ part: ProfilePart, detail: String, flagged: Bool,
                           open: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: part))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(part.label).fontWeight(.medium)
                    if flagged {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .help("This differs from your journal library — Save to Library to update it.")
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open…", action: open)
                .controlSize(.small)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private func icon(for part: ProfilePart) -> String {
        switch part {
        case .requirements: return "doc.text"
        case .checks:       return "checklist"
        case .structure:    return "list.bullet.indent"
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
                    ChecklistRow(result: result,
                                 fixAction: result.fixID == "typography" && !result.passed
                                     ? { store.applyRequiredTypography(journalID: journal.id) }
                                     : nil)
                }
            }
            if !manualRules.isEmpty {
                sectionHeader("Manual", note: "tick each box once you've verified it yourself")
                ForEach(manualRules) { result in
                    // Label the argument: an unlabeled trailing closure can
                    // bind to fixAction, turning checkboxes into Fix buttons.
                    ChecklistRow(result: result, onToggle: {
                        store.toggleManualCheck(journalID: journal.id, rule: result.rule)
                    })
                }
            }
            if results.isEmpty {
                Text("This journal has no checks configured yet — open Checks above to add them.")
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
    /// Set on repairable technical failures: renders a Fix button that
    /// applies the correction (e.g. align export typography).
    var fixAction: (() -> Void)? = nil

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
            if let fixAction {
                Spacer()
                Button("Fix", action: fixAction)
                    .controlSize(.small)
                    .help("Align the export with this requirement")
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

// MARK: - SourceRequirementsSheet

/// The journal's own instructions: a link to the page they came from and the
/// distilled bullets.  One requirement per line, because that is how journals
/// publish them — and free text, because no schema survives contact with a
/// real set of author instructions.
struct SourceRequirementsSheet: View {
    @Environment(ManuscriptStore.self) private var store

    let journal: Journal
    @Binding var isPresented: Bool

    @State private var editing = false
    @State private var urlDraft = ""
    @State private var bulletDraft = ""

    private var requirements: SourceRequirements {
        journal.sourceRequirements ?? SourceRequirements()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(journal.displayName) — Requirements").font(.headline)
                    Text("The journal's own instructions, distilled. Checks are what the app enforces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(editing ? "Save" : "Edit") {
                    if editing {
                        var edited = requirements
                        edited.url = urlDraft.trimmingCharacters(in: .whitespaces)
                        edited.text = bulletDraft
                        store.updateSourceRequirements(edited, journalID: journal.id)
                    } else {
                        urlDraft = requirements.url.isEmpty ? journal.submissionURL : requirements.url
                        bulletDraft = requirements.text
                    }
                    editing.toggle()
                }
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Link to the journal's author instructions", text: $urlDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    PlainTextEditor(text: $bulletDraft)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    Text("One requirement per line. Leading bullet characters are stripped, so pasting from the journal's page works.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let link = requirements.url.isEmpty ? journal.submissionURL : requirements.url
                        if !link.isEmpty, let url = URL(string: link) {
                            Link(destination: url) {
                                Label("Author instructions", systemImage: "arrow.up.right.square")
                                    .font(.callout)
                            }
                            .help(link)
                        }
                        if requirements.bullets.isEmpty {
                            Text("No requirements yet — Edit to paste this journal's instructions, one per line.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(Array(requirements.bullets.enumerated()), id: \.offset) { _, bullet in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(bullet)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - StructureEditorSheet

/// The sections a submission to this journal is expected to have.  Required
/// ones are what a `STRUCTURE` check verifies; optional ones are offered when
/// the journal is added but never fail.
struct StructureEditorSheet: View {
    @Environment(ManuscriptStore.self) private var store

    let journal: Journal
    @Binding var isPresented: Bool

    @State private var sections: [StructureSection] = []
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(journal.displayName) — Structure").font(.headline)
                    Text("The sections a submission starts with. Required ones are verified by checks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    store.updateStructure(JournalStructure(sections: sections),
                                          journalID: journal.id)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The sections this journal expects, in order. Title, authors, abstract, keywords, figures, tables, bibliography, and the cover letter come with every manuscript, so they aren't listed here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                    if sections.isEmpty {
                        Text("No sections yet — add the ones this journal expects below.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                    }
                    ForEach($sections) { $section in
                        sectionRow($section)
                    }
                }
                .padding(14)
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Add a section (e.g. \"Public Health Implications\")", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 480)
        .onAppear { sections = journal.structure?.sections ?? [] }
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !sections.contains(where: { $0.id == title.lowercased() }) else { return }
        sections.append(StructureSection(title: title))
        newTitle = ""
    }

    @ViewBuilder
    private func sectionRow(_ section: Binding<StructureSection>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .foregroundStyle(.tertiary)
                .font(.caption)
                .frame(width: 18)
            TextField("Section title", text: section.title)
                .textFieldStyle(.roundedBorder)
            Toggle("Required", isOn: section.required)
                .toggleStyle(.checkbox)
                .help("Required sections fail a STRUCTURE check when missing")
            Button {
                move(section.wrappedValue, by: -1)
            } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(sections.first?.id == section.wrappedValue.id)
            Button {
                move(section.wrappedValue, by: 1)
            } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(sections.last?.id == section.wrappedValue.id)
            Button(role: .destructive) {
                sections.removeAll { $0.id == section.wrappedValue.id }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Reorders within the prose sections only — moving past a core entry
    /// would be meaningless, since the export places those itself.
    private func move(_ section: StructureSection, by offset: Int) {
        guard let index = sections.firstIndex(where: { $0.id == section.id }) else { return }
        let target = index + offset
        guard sections.indices.contains(target) else { return }
        sections.swapAt(index, target)
    }
}

// MARK: - SaveToJournalLibrarySheet

/// Saves a manuscript journal's export outline into the journal registry —
/// the list of journals available when adding one to any manuscript.  The
/// journal's REQUIREMENTS, CHECKS, and STRUCTURE go to the profile library
/// instead, from the Checks pane's Save to Library.
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
            Text("Save Export Outline to Library").font(.headline)

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

            Text("Stores this journal's export outline in the journal registry — available in Settings → Journals and when adding a journal to any manuscript. Requirements, checks, and structure are saved separately, from the Checks pane.")
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
