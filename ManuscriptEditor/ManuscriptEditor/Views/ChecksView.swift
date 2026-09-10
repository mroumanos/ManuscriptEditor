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
    /// The part whose Save is awaiting confirmation.  Every save overwrites
    /// something in the library, so none of them happen on one click.
    @State private var savingPart: ProfilePart?
    /// The part whose Load is awaiting confirmation — it replaces what is here.
    @State private var loadingPart: ProfilePart?
    @State private var showingTemplate = false
    @State private var linkingTemplate = false
    @State private var editingType = false
    @State private var typeDraft = ""

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
        .confirmationDialog("Replace this journal's configuration with its template's?",
                            isPresented: $adoptingLibrary, titleVisibility: .visible) {
            Button("Update From Template") {
                if let journal = paneJournal { store.adoptLibraryProfile(journalID: journal.id) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The summary, structure, tests and export outline are replaced. Nothing you have written is touched, and ⌘Z undoes it.")
        }
        .confirmationDialog("Replace this journal's \(loadingPart?.label.lowercased() ?? "part") with the template's?",
                            isPresented: Binding(get: { loadingPart != nil },
                                                 set: { if !$0 { loadingPart = nil } }),
                            titleVisibility: .visible) {
            Button("Load", role: .destructive) {
                if let part = loadingPart, let journal = paneJournal {
                    store.loadTemplatePart(part, journalID: journal.id)
                }
                loadingPart = nil
            }
            Button("Cancel", role: .cancel) { loadingPart = nil }
        } message: {
            Text("Takes “\(linkedTemplate?.displayName ?? "the template")”'s copy of this part. Nothing you have written in the manuscript changes, and ⌘Z undoes it.")
        }
        .sheet(isPresented: $showingTemplate) {
            if let template = linkedTemplate {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.displayName).font(.headline)
                        Text("The template this journal is linked to — read-only here; edit it by saving parts from this journal.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    JournalProfileReview(profile: template).frame(height: 380)
                    HStack {
                        Spacer()
                        Button("Done") { showingTemplate = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(18)
                .frame(width: 560)
            }
        }
        .confirmationDialog(savePrompt.title,
                            isPresented: Binding(get: { savingPart != nil },
                                                 set: { if !$0 { savingPart = nil } }),
                            titleVisibility: .visible) {
            Button(savePrompt.verb, role: .destructive) {
                if let part = savingPart, let journal = paneJournal {
                    store.saveTemplatePart(part, journalID: journal.id)
                }
                savingPart = nil
            }
            Button("Cancel", role: .cancel) { savingPart = nil }
        } message: {
            Text(savePrompt.message)
        }
        .sheet(isPresented: $linkingTemplate) {
            if let journal = paneJournal {
                LinkTemplateSheet(journal: journal, isPresented: $linkingTemplate)
            }
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
            Text(journal.name).font(.headline)
            // Free-form on purpose: journals invent their own format names
            // ("Research Brief", "Rapid Communication", "Registered Report")
            // and a fixed list would be wrong within a year.  The type names
            // the profile and groups a journal's formats together.
            Button {
                typeDraft = journal.articleType ?? ""
                editingType = true
            } label: {
                Text(journal.articleType?.isEmpty == false ? journal.articleType! : "Add type…")
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(journal.articleType == nil ? 0.06 : 0.12),
                                in: Capsule())
                    .foregroundStyle(journal.articleType == nil ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("The article format this cut targets — Research Article, Research Brief, …")
            .popover(isPresented: $editingType, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Article type").font(.callout.weight(.medium))
                    TextField("Research Article, Research Brief, …", text: $typeDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit { commitType(journal) }
                    Text("Names this journal's profile and groups its formats together. Leave empty for a journal with only one.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 260, alignment: .leading)
                    HStack {
                        Spacer()
                        Button("Set") { commitType(journal) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(14)
            }
            Spacer()
            // What this journal is linked to, and a way into it — the same
            // shape Settings uses, so "which template is this?" is answered
            // in the one place you are already looking.
            if let template = linkedTemplate {
                Button {
                    showingTemplate = true
                } label: {
                    Label("Linked to \(template.displayName)", systemImage: "link")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .help("Open this template's details")
            } else {
                Button {
                    linkingTemplate = true
                } label: {
                    Label("Not linked to a template", systemImage: "link.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .help("This journal's configuration exists only here. Link it to a template to compare and update.")
            }
            // Permanent, not conditional: adding this journal to the library
            // as a template of its own is a thing you may want at any moment —
            // not only when something happens to differ.
            Button {
                savingToLibrary = true
            } label: {
                Label("Add to Template Library", systemImage: "books.vertical")
            }
            .help("Save this journal's whole configuration as a template — overwriting the one it came from, or as a new one.")
        }
    }

    /// What a save is about to do, said before it does it.
    ///
    /// Every one of these overwrites the template in your library, and other
    /// manuscripts follow that template — so the wording names the template and
    /// says what changes.  The structure's warning is the strongest on purpose:
    /// saving it captures the text currently in this cut's sections as the
    /// template's sample content, which is how someone's own manuscript could
    /// quietly become everyone's starting point.
    /// The template this journal is linked to, if the library still has it.
    private var linkedTemplate: JournalTemplate? {
        paneJournal?.profileID.flatMap { JournalProfileLibrary.shared.profile(id: $0) }
    }

    private var hasTemplate: Bool { linkedTemplate != nil }

    private var savePrompt: (title: String, verb: String, message: String) {
        let name = store.libraryAncestor(for: paneJournal ?? Journal.empty())?.displayName
            ?? paneJournal?.templateName
            ?? paneJournal?.displayName
            ?? "this template"
        switch savingPart {
        case .requirements:
            return ("Overwrite the summary in “\(name)”?", "Overwrite Summary",
                    "This journal's summary replaces the template's. Manuscripts tracking that template will see the new one.")
        case .checks:
            return ("Overwrite the tests in “\(name)”?", "Overwrite Tests",
                    "This journal's tests replace the template's — including any you removed.")
        case .structure:
            return ("Overwrite the content in “\(name)”?", "Overwrite Content",
                    "The template takes this cut's ACTIVE sections and, as its sample content, THE TEXT CURRENTLY IN THEM — the title page layout, the submission questions and their answers. Anything written here becomes the starting point for every journal cut from this template. Hidden sections are left out.")
        case .export:
            return ("Overwrite the export outline in “\(name)”?", "Overwrite Export",
                    "This journal's outline, formats and page breaks replace the template's.")
        case nil:
            return ("Overwrite the template?", "Overwrite", "")
        }
    }

    private func commitType(_ journal: Journal) {
        var edited = journal
        let trimmed = typeDraft.trimmingCharacters(in: .whitespaces)
        edited.articleType = trimmed.isEmpty ? nil : trimmed
        store.updateJournal(edited)
        editingType = false
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

    // MARK: - Part status

    /// Whether this part differs from the template as your library holds it.
    ///
    /// One state, not three.  A green tick on every unedited row was noise —
    /// the same noise a signature badge already carries — and the "new" case
    /// was hinging on whether the library had ever seen this GUID, which is not
    /// the question anyone is asking.  The question is: **have I changed this
    /// since it came from the template?**  So the comparison is against the
    /// template's checksum, and the answer is an orange pencil or nothing.
    private func isEdited(_ part: ProfilePart, journal: Journal) -> Bool {
        // The structure is computed from this cut's sections, their text and
        // their export formatting — none of which is in the stored structure
        // until a save happens.  So it is compared against what a save WOULD
        // produce, which is why editing a section's text lights up Save.
        if part == .structure,
           let prospective = store.structureCapture(journalID: journal.id) {
            guard let template = journal.profileID
                    .flatMap({ JournalProfileLibrary.shared.profile(id: $0) })
            else { return true }
            var mine = journal.profile
            mine.structure = prospective
            return mine.fingerprint(.structure) != template.fingerprint(.structure)
        }
        switch store.libraryStatus(for: journal) {
        case .matches:
            return false
        case .differs(let parts), .derived(_, let parts):
            return parts.contains(part)
        case .nameMatchDifferentID, .absent:
            // No template to compare against — this configuration exists only
            // here, so every part of it is unsaved work.
            return true
        }
    }

    @ViewBuilder
    private func editedBadge(_ edited: Bool) -> some View {
        if edited {
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .help("Edited here — differs from this journal's template in your library")
        }
    }

    // MARK: - The journal's configuration

    /// What this journal expects, in three openable rows.
    ///
    /// Summary and Content are the profile's own files; **Export** is here
    /// because a journal's formatting rules are part of its configuration even
    /// though they are edited in the Export pane — so the row states them and
    /// sends you there rather than growing a second editor for the same thing.
    /// The tests are no longer a row: they are the section below, because they
    /// are what the whole pane is for.
    @ViewBuilder
    private func configuration(_ journal: Journal) -> some View {
        let requirements = journal.sourceRequirements ?? SourceRequirements()
        let structure = journal.structure ?? JournalStructure()

        VStack(alignment: .leading, spacing: 0) {
            configRow(
                .requirements,
                detail: requirements.bullets.isEmpty
                    ? "No summary yet"
                    : summaryDetail(requirements),
                edited: isEdited(.requirements, journal: journal),
                open: { editingRequirements = true })

            Divider()

            configRow(
                .structure,
                detail: contentDetail(structure),
                edited: isEdited(.structure, journal: journal),
                open: { editingStructure = true })

            Divider()

            configRow(.checks,
                      detail: testsDetail(journal),
                      edited: isEdited(.checks, journal: journal),
                      open: { editingRules = true })

            Divider()

            exportRow(journal)
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    /// "7 sections · 5 required · 4 with content · 2 questions · export set" —
    /// what this venue's content actually holds, not just how many headings.
    private func contentDetail(_ structure: JournalStructure) -> String {
        guard !structure.sections.isEmpty else { return "No content yet" }
        var parts = ["\(structure.sections.count) section\(structure.sections.count == 1 ? "" : "s")",
                     "\(structure.requiredTitles.count) required"]
        let withSample = structure.sections.filter { $0.sample?.isEmpty == false }.count
        if withSample > 0 { parts.append("\(withSample) with content") }
        let questions = structure.sections.reduce(0) { $0 + ($1.questions?.count ?? 0) }
        if questions > 0 { parts.append("\(questions) question\(questions == 1 ? "" : "s")") }
        let formats = structure.sections.filter { $0.format != nil }.count
            + (structure.coreFormats?.count ?? 0)
        if formats > 0 { parts.append("\(formats) export format\(formats == 1 ? "" : "s")") }
        let guidance = structure.sections.filter {
            $0.formatNote?.isEmpty == false || $0.note?.isEmpty == false
        }.count
        if guidance > 0 { parts.append("\(guidance) with guidance") }
        return parts.joined(separator: " · ")
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
        configRow(.export,
                  detail: exportDetail(journal.exportConfig),
                  edited: isEdited(.export, journal: journal),
                  open: {
                      NotificationCenter.default.post(name: .showPane, object: nil,
                                                      userInfo: ["pane": "export"])
                  },
                  openNote: "Export formatting is part of this journal's configuration — edited in the Export pane")
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

    private func configRow(_ part: ProfilePart, detail: String, edited: Bool,
                           open: (() -> Void)?, openNote: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: part))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(part.label).fontWeight(.medium)
                    editedBadge(edited)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Open, Load, Save — the same three on every row, in the same
            // order.  Managing one component used to mean loading the whole
            // template, which made every small decision a large one.
            Button("Open…") { open?() }
                .controlSize(.small)
                .disabled(open == nil)
                .help(openNote ?? "")
            Button("Load") { loadingPart = part }
                .controlSize(.small)
                .disabled(!hasTemplate)
                .help(hasTemplate
                      ? "Replace this part with the template's copy"
                      : "This journal isn't linked to a template")
            Button("Save") { savingPart = part }
                .controlSize(.small)
                .disabled(!edited)
                .help(edited
                      ? "Overwrite this part of the template in your library"
                      : "Matches the template")
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
        case .export:       return "square.and.arrow.up"
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
    /// Summary or the Content above, and the whole list is how a cut proves
    /// it can be submitted.  The editor is the same popup as before.
    @ViewBuilder
    private func testsHeader(_ journal: Journal, results: [ChecklistResult]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Tests").font(.headline)
            Text("one per requirement above, evaluated against this cut — open or save them in the card")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 12)
    }

    /// "18 tests · 16 automatic, 2 manual"
    private func testsDetail(_ journal: Journal) -> String {
        let checks = journal.checkRules ?? []
        guard !checks.isEmpty else { return "No tests yet" }
        let manual = checks.filter(\.isManual).count
        return "\(checks.count) test\(checks.count == 1 ? "" : "s") · "
            + "\(checks.count - manual) automatic, \(manual) manual"
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
                    Text("\(journal.displayName) — Content").font(.headline)
                    Text("What a submission at this venue contains: its sections, how each is written and set, and the questions it asks.")
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
        VStack(alignment: .leading, spacing: 6) {
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

        // Format first, then Notes: how it has to be written, then why.
        // Both are sent when adapting a cut to this journal, which is the
        // point of writing them down here rather than in someone's head.
        HStack(alignment: .top, spacing: 8) {
            Text("Format").font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary).frame(width: 46, alignment: .leading)
            TextField("How this section must be written here — layout, headings, order",
                      text: Binding(get: { section.wrappedValue.formatNote ?? "" },
                                    set: { section.wrappedValue.formatNote = $0.isEmpty ? nil : $0 }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
        }
        HStack(alignment: .top, spacing: 8) {
            Text("Notes").font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary).frame(width: 46, alignment: .leading)
            TextField("Why the journal asks for it, and anything else worth knowing",
                      text: Binding(get: { section.wrappedValue.note ?? "" },
                                    set: { section.wrappedValue.note = $0.isEmpty ? nil : $0 }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
        }
        if let sample = section.wrappedValue.sample, !sample.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text("Content").font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary).frame(width: 46, alignment: .leading)
                Text(sample.replacingOccurrences(of: "\n", with: " ↵ "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(sample)
            }
        }
        if let questions = section.wrappedValue.questions, !questions.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text("Asks").font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary).frame(width: 46, alignment: .leading)
                Text(questions.map { q in
                    q.wordLimit.map { "\(q.prompt) (\($0) \((q.limitUnit ?? .words).shortLabel))" }
                        ?? q.prompt
                }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
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
    /// Seeded from the journal so the branch has a sensible name to start from.
    @State private var seeded = false

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
                Text("Save Template").font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if target != nil {
                // Name the profile being overwritten.  "Overwrite the profile
                // in my library" left you to work out WHICH one — and the
                // answer isn't always this journal's name, since a branch
                // overwrites its ancestor.
                Picker("", selection: $choice) {
                    Text("Overwrite the “\(target?.displayName ?? journal.displayName)” template")
                        .tag(Choice.overwrite)
                    Text("Save as a new template of my own").tag(Choice.branch)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if choice == .branch || target == nil {
                TextField("Name for the new template", text: $newName)
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


// MARK: - LinkTemplateSheet

/// Points an orphaned journal at a template.
///
/// A journal loses its template when the template is deleted, or when the
/// manuscript arrives from someone whose library you don't have.  Its rules
/// still work — the manuscript carries them — but nothing can be compared or
/// updated until it is linked again, and a journal named "BMJ test 1" cannot
/// be matched back by name.  So it is stated, not guessed.
struct LinkTemplateSheet: View {
    @Environment(ManuscriptStore.self) private var store

    let journal: Journal
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var choice: UUID?

    private var templates: [JournalTemplate] {
        let all = JournalProfileLibrary.shared.profiles.values
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return all }
        return all.filter { $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Link a Template").font(.headline)
                Text("“\(journal.name)” has no template in your library. Linking one lets this journal be compared against it and updated from it. Nothing you have written changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Search templates…", text: $query)
                .textFieldStyle(.roundedBorder)

            List(templates, selection: $choice) { template in
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.displayName).fontWeight(.medium)
                    Text("\(template.requirements.bullets.count) requirements · \(template.checks.count) tests")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(template.id)
            }
            .frame(height: 240)

            Text("Linking replaces this journal's summary, structure, tests and export outline with the template's. To keep what you have instead, close this and use Save Template.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Link") {
                    if let choice { store.linkToTemplate(choice, journalID: journal.id) }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
