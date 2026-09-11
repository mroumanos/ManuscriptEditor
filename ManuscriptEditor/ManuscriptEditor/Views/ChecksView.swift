// ChecksView.swift
//
// **Tests** — the live verdict: every check evaluated against the pane's
// content, green ✓ / red ✗, manual ones as boxes.
//
// It used to carry a card listing the journal's four parts, each behind an
// "Open…" button.  Those are sidebar sections now (Summary · Structure ·
// Tests · Export), so this pane is one thing again: what passes and what
// doesn't.
//
// Version-aware: a journal pane evaluates that version's content against its
// own journal's profile, so Checks renders one live pane per open tab in
// side-by-side (just like Abstract).  Everything recomputes on every edit
// because the stores are `@Observable`.

import SwiftUI

struct ChecksView: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(\.colorScheme) private var scheme

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

    @State private var editingRules = false
    /// Taking the template's tests back — confirmed, because it replaces
    /// every rule here, including ones written for this cut alone.
    @State private var loadingTests = false
    @State private var savingToLibrary = false
    @State private var adoptingLibrary = false
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
                    checklist(journal)
                } else {
                    noJournalState
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $editingRules) {
            if let journal = paneJournal {
                CheckRulesEditor(journal: journal, isPresented: $editingRules)
            }
        }
        .confirmationDialog("Replace this journal's tests with the template's?",
                            isPresented: $loadingTests, titleVisibility: .visible) {
            Button("Load", role: .destructive) {
                if let journal = paneJournal {
                    store.loadTemplatePart(.checks, journalID: journal.id)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Takes “\(linkedTemplate?.displayName ?? "the template")”'s tests, including losing any you wrote here. Nothing you have written in the manuscript changes, and ⌘Z undoes it.")
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
                    NotificationCenter.default.post(name: .manageTemplate, object: nil,
                                                    userInfo: ["template": template.id])
                } label: {
                    Label("Manage \(template.displayName)", systemImage: TemplateStyle.symbol)
                        .font(.caption)
                }
                .buttonStyle(.link)
                .foregroundStyle(TemplateStyle.accent(scheme))
                .help("Open this template in its own tab — where a template is edited")
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

    /// The template this journal is linked to, if the library still has it.
    private var linkedTemplate: JournalTemplate? {
        paneJournal?.profileID.flatMap { JournalProfileLibrary.shared.profile(id: $0) }
    }

    private func commitType(_ journal: Journal) {
        var edited = journal
        let trimmed = typeDraft.trimmingCharacters(in: .whitespaces)
        edited.articleType = trimmed.isEmpty ? nil : trimmed
        store.updateJournal(edited)
        editingType = false
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
            if store.partDiffersFromTemplate(.checks, journal: journal) {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange).font(.caption)
                    .help("Differs from the template it came from")
            }
            Text(testsDetail(journal))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Edit Tests…") { editingRules = true }
                .controlSize(.small)
            Button("Load") { loadingTests = true }
                .controlSize(.small)
                .disabled(linkedTemplate == nil)
                .help(linkedTemplate == nil
                      ? "This journal isn't linked to a template"
                      : "Replace this journal's tests with the template's")
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

// The Summary and Structure editors used to live here as sheets behind an
// "Open…" button.  They are panes now — `JournalSummaryView` and
// `JournalStructureView` — reached from the sidebar like everything else a
// journal has.

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
