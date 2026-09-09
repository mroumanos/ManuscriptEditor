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
    @State private var savingToLibrary = false
    @State private var adoptingLibrary = false

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
        .confirmationDialog("Replace this journal's configuration with your library's copy?",
                            isPresented: $adoptingLibrary, titleVisibility: .visible) {
            Button("Update From Library") {
                if let journal = paneJournal { store.adoptLibraryProfile(journalID: journal.id) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The summary, structure and tests are replaced. Nothing you have written is touched, and ⌘Z undoes it.")
        }
        .sheet(isPresented: $savingToLibrary) {
            if let journal = paneJournal {
                SaveProfileToLibrarySheet(journal: journal, isPresented: $savingToLibrary)
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
            if status.isModified {
                modifiedTag
            }
            if status.canSave {
                // Both directions, side by side: push this manuscript's
                // configuration into the library, or take the library's.
                // Only having the first one meant a profile corrected in the
                // library could never reach the manuscript that needed it.
                if status.isModified {
                    Button {
                        adoptingLibrary = true
                    } label: {
                        Label("Update From Library", systemImage: "arrow.down.circle")
                    }
                    .help("Replace this journal's summary, structure and tests with your library's copy. Your manuscript's content is untouched.")
                }
                Button {
                    savingToLibrary = true
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
    }

    /// The MODIFIED badge: this manuscript's rules are not the ones in your
    /// library.  Shown on import too — that is the point of carrying the
    /// profile with the manuscript.
    private var modifiedTag: some View {
        Text("MODIFIED")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange, in: Capsule())
            .help("This manuscript's configuration differs from your journal library")
    }

    private func saveHelp(_ status: ProfileLibraryStatus, journal: Journal) -> String {
        switch status {
        case .matches:
            return "This manuscript's configuration matches your library."
        case .differs(let parts):
            let names = parts.sorted { $0.rawValue < $1.rawValue }.map(\.label)
            return "Your library's copy differs in: \(names.joined(separator: ", "))."
        case .derived(_, let parts):
            let names = parts.sorted { $0.rawValue < $1.rawValue }.map(\.label)
            return "A modified version of a profile in your library, differing in: \(names.joined(separator: ", "))."
        case .nameMatchDifferentID:
            return "Your library has a profile with this name but a different identifier."
        case .absent:
            return "Your library has no profile for \(journal.displayName) — saving adds it."
        }
    }

    // MARK: - The journal's configuration

    /// What this journal expects, in three openable rows.
    ///
    /// Summary and Structure are the profile's own files; **Export** is here
    /// because a journal's formatting rules are part of its configuration even
    /// though they are edited in the Export pane — so the row states them and
    /// sends you there rather than growing a second editor for the same thing.
    /// The tests are no longer a row: they are the section below, because they
    /// are what the whole pane is for.
    @ViewBuilder
    private func configuration(_ journal: Journal) -> some View {
        let flagged = store.libraryStatus(for: journal).flaggedParts
        let requirements = journal.sourceRequirements ?? SourceRequirements()
        let structure = journal.structure ?? JournalStructure()

        VStack(alignment: .leading, spacing: 0) {
            configRow(
                .requirements,
                detail: requirements.bullets.isEmpty
                    ? "No summary yet"
                    : summaryDetail(requirements),
                flagged: flagged.contains(.requirements)
            ) { editingRequirements = true }

            Divider()

            configRow(
                .structure,
                detail: structure.sections.isEmpty
                    ? "No structure yet"
                    : "\(structure.sections.count) section\(structure.sections.count == 1 ? "" : "s") · \(structure.requiredTitles.count) required",
                flagged: flagged.contains(.structure)
            ) { editingStructure = true }

            Divider()

            exportRow(journal)
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    /// "38 requirements · 7 limits, 9 components" — the summary's own shape,
    /// since its bullets are written in standard categories.
    private func summaryDetail(_ requirements: SourceRequirements) -> String {
        let counts = SourceRequirements.categoryCounts(requirements.bullets)
        let parts = SourceRequirements.categoryOrder
            .compactMap { key in counts[key].map { "\($0) \(key)" } }
        let total = "\(requirements.bullets.count) requirement\(requirements.bullets.count == 1 ? "" : "s")"
        return parts.isEmpty ? total : "\(total) · \(parts.joined(separator: ", "))"
    }

    /// The export row: what this journal's outline produces, and a way in.
    @ViewBuilder
    private func exportRow(_ journal: Journal) -> some View {
        let config = journal.exportConfig
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Export").fontWeight(.medium)
                Text(exportDetail(config))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open…") {
                NotificationCenter.default.post(name: .showPane, object: nil,
                                                userInfo: ["pane": "export"])
            }
            .controlSize(.small)
            .help("Export formatting is part of this journal's configuration — edited in the Export pane")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private func exportDetail(_ config: ExportConfig?) -> String {
        guard let config, !config.documents.isEmpty else {
            return "Not configured — the standard outline is used"
        }
        let format = config.documents[0].format
        let documents = "\(config.documents.count) document\(config.documents.count == 1 ? "" : "s")"
        return "\(documents) · \(String(format: "%g", format.fontSize)) pt · "
            + "\(String(format: "%g", format.lineSpacing))× spacing · "
            + (format.lineNumbers ? "line numbers on" : "line numbers off")
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
                        Text("MODIFIED")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .help("This part differs from your journal library — Update Library… to reconcile it.")
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
            testsHeader(journal, results: results)
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
                Text("This journal has no tests yet — Edit Tests… turns its requirements into ones the app can check.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The heading the pane is really about.
    ///
    /// "Tests", not "Checks": each one is a test of a requirement stated in the
    /// Summary or the Structure above, and the whole list is how a cut proves
    /// it can be submitted.  The editor is the same popup as before.
    @ViewBuilder
    private func testsHeader(_ journal: Journal, results: [ChecklistResult]) -> some View {
        let flagged = store.libraryStatus(for: journal).flaggedParts.contains(.checks)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Tests").font(.headline)
            if flagged {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("MODIFIED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("This journal's tests differ from your library — Update Library… to reconcile them.")
            }
            Text("one per requirement above, evaluated against this cut")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Edit Tests…") { editingRules = true }
                .controlSize(.small)
        }
        .padding(.top, 12)
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

/// **Summary** — the journal's own instructions, distilled.
///
/// One requirement per line, because that is how journals publish them, and
/// free text, because no schema survives contact with a real set of author
/// instructions.  What it does have is a **standard vocabulary**: bullets are
/// written as `description:`, `limits:`, `components:`, `format:` or `extra:`,
/// which groups them here and makes the limits — the half that becomes tests —
/// findable without reading the prose.  Anything deeper belongs to the journal:
/// the link at the top is always the authority.
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
                    Text("\(journal.displayName) — Summary").font(.headline)
                    Text("The journal's instructions, distilled. The tests below the pane are what the app enforces.")
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
                    Text("One requirement per line. Start each with a category — description: / limits: / components: / format: / extra: — to keep the summary readable. Leading bullet characters are stripped, so pasting from the journal's page works.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
                            Text("No summary yet — Edit to paste this journal's instructions, one per line.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(Array(SourceRequirements.grouped(requirements.bullets).enumerated()),
                                    id: \.offset) { _, group in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text((group.category ?? "other").uppercased())
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text("•").foregroundStyle(.tertiary)
                                            Text(item)
                                                .textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                                .padding(.top, 4)
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
            Picker("", selection: section.kind) {
                ForEach(SectionKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("A question series arrives as the journal's submission questions when a cut is forked to it")
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

// MARK: - SaveProfileToLibrarySheet

/// Reconciling a manuscript's profile with the user's library.
///
/// Two outcomes, always: **overwrite** the library entry this one relates to,
/// or **branch** — save a new profile of your own that remembers where it came
/// from.  The branch is what makes the lineage work: share the manuscript and
/// the next person's library holds the ancestor, so they are told theirs is a
/// MODIFIED version of it and get the same two choices in turn, rather than an
/// unexplained stranger.
struct SaveProfileToLibrarySheet: View {
    @Environment(ManuscriptStore.self) private var store

    let journal: Journal
    @Binding var isPresented: Bool

    private enum Choice: Hashable { case overwrite, branch }
    @State private var choice: Choice = .overwrite
    @State private var newName: String = ""

    private var status: ProfileLibraryStatus { store.libraryStatus(for: journal) }
    private var ancestor: JournalProfile? { store.libraryAncestor(for: journal) }

    /// The library entry an overwrite would land on: the one this profile
    /// descends from or shares a name with, else its own GUID's entry.
    private var target: JournalProfile? {
        ancestor ?? JournalProfileLibrary.shared.profile(id: journal.profile.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Update Journal Library").font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if target != nil {
                Picker("", selection: $choice) {
                    Text("Overwrite the profile in my library").tag(Choice.overwrite)
                    Text("Save as a new profile of my own").tag(Choice.branch)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if choice == .branch || target == nil {
                TextField("Name for the new profile", text: $newName)
                    .textFieldStyle(.roundedBorder)
                if let target {
                    Text("Kept alongside \"\(target.displayName)\" and remembers it as its source, so anyone you share this manuscript with sees it as a modified version of that profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let target {
                Text("Replaces \"\(target.displayName)\" everywhere it is used — other manuscripts tracking it will follow the new rules the next time they open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if choice == .branch || target == nil {
                        store.branchProfileToLibrary(journalID: journal.id, named: newName)
                    } else {
                        store.saveProfileToLibrary(journalID: journal.id,
                                                   replacingID: target?.id)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled((choice == .branch || target == nil)
                          && newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 470)
        .onAppear {
            newName = journal.displayName
            if target == nil { choice = .branch }
        }
    }

    private var summary: String {
        switch status {
        case .matches:
            return "This manuscript already matches your library."
        case .differs(let parts), .derived(_, let parts):
            let names = parts.sorted { $0.rawValue < $1.rawValue }.map(\.label)
            return "This manuscript's \(names.joined(separator: ", ").lowercased()) "
                + (parts.count == 1 ? "differs" : "differ") + " from your library."
        case .nameMatchDifferentID:
            return "Your library has a profile with this name but a different identifier."
        case .absent:
            return "Your library has no profile for this journal yet."
        }
    }
}
