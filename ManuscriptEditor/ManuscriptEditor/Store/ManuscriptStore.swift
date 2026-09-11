// ManuscriptStore.swift
//
// The single source of truth for all application state.
// See the original file header for the general architecture notes.
//
// ADDITIONS IN THIS REVISION
// ─────────────────────────────────────────────────────────────────────────────
// • createNew(in:)    — creates a manuscript in a user-chosen folder.
// • DataAsset CRUD   — addDataAsset, updateDataAsset, deleteDataAssets.
// • dataDirectory    — exposes the data/ sub-folder URL for the current manuscript.
// • dataService      — shared DataService instance for CSV/SQLite operations.

import Foundation
import Observation
import SwiftUI
import AppKit   // NSOpenPanel for folder picker
import CryptoKit   // content checksums for sync prechecks

@MainActor
@Observable
final class ManuscriptStore {

    // MARK: - State

    var manuscript: Manuscript? {
        didSet { if oldValue?.id != manuscript?.id { loadLog(); loadPromptLog() } }
    }
    var lastSaved: Date?
    var saveError: String?

    // MARK: - Dependencies

    let persistence = PersistenceService()
    let dataService = DataService()

    // MARK: - Undo (document level)
    //
    // Every model mutation funnels through `touch`, which snapshots the
    // pre-mutation `Manuscript` and registers a restore with the key window's
    // undo manager.  `Manuscript` is a value type with copy-on-write arrays,
    // so a snapshot shares storage with the live value and costs only the
    // delta.  Entries target the store (app lifetime), never a view, so they
    // cannot dangle — text-view *typing* deliberately stays out of this
    // manager, in each editor's scoped one (see PlainTextEditor and the
    // engineering-standards gotcha from issue #8).

    /// The key window's undo manager.  Registrations follow the active window
    /// so ⌘Z lands here whenever a text view doesn't claim it first.
    /// Not observable state — mutated from view-update paths.
    @ObservationIgnored weak var activeUndoManager: UndoManager? {
        didSet { activeUndoManager?.levelsOfUndo = 50 }
    }

    /// Context of the last registration — coalesces the per-keystroke commits
    /// of draft-based forms (they call `touch` on every character) into one
    /// snapshot per burst.
    @ObservationIgnored private var lastUndoContext: (name: String, at: Date)?

    /// Registers `before` as the undo state for the mutation just applied.
    private func registerUndo(_ before: Manuscript, name: String?) {
        guard let um = activeUndoManager, !um.isUndoing, !um.isRedoing else { return }
        // One snapshot per typing burst: the burst's first snapshot already
        // restores the pre-burst state, so followers within the window add
        // nothing but stack noise.
        let key = name ?? "Change"
        let now = Date()
        if let last = lastUndoContext, last.name == key, um.canUndo,
           now.timeIntervalSince(last.at) < UndoTuning.snapshotCoalescePause {
            lastUndoContext = (key, now)
            return
        }
        lastUndoContext = (key, now)
        um.registerUndo(withTarget: self) { $0.restoreSnapshot(before) }
        if let name { um.setActionName(name) }
    }

    /// Applies an undo/redo snapshot.  Registering the current state first
    /// lets NSUndoManager flip the entry onto the redo stack automatically.
    private func restoreSnapshot(_ snapshot: Manuscript) {
        // Entries can outlive a manuscript switch (another window's manager);
        // restoring across ids would clobber the open manuscript with the
        // previous one's data.
        guard let current = manuscript, current.id == snapshot.id else { return }
        lastUndoContext = nil
        activeUndoManager?.registerUndo(withTarget: self) { $0.restoreSnapshot(current) }
        manuscript = snapshot
        trySave()
    }

    /// Drops document undo history — called whenever `manuscript` is replaced
    /// wholesale (open/new/close/delete) rather than mutated.
    private func resetUndoHistory() {
        lastUndoContext = nil
        activeUndoManager?.removeAllActions(withTarget: self)
    }

    // MARK: - Lifecycle

    func loadMostRecent() {
        guard let idString = UserDefaults.standard.string(forKey: "lastOpenedManuscriptID"),
              let id = UUID(uuidString: idString)
        else { return }
        resetUndoHistory()
        manuscript = persistence.load(id: id).map(normalized)
        if let m = manuscript {
            resolveBookmarkIfNeeded(for: m)
        }
    }

    /// Saves and closes the current manuscript so the Welcome screen (the
    /// project manager) shows — File → Manage Manuscripts… lands here, which
    /// also guarantees you never trash the project you're working in.
    func closeToWelcome() {
        trySave()
        resetUndoHistory()
        manuscript = nil
        UserDefaults.standard.removeObject(forKey: "lastOpenedManuscriptID")
    }

    /// Creates a new manuscript in the default App Support location.
    func createNew() {
        resetUndoHistory()
        manuscript = Manuscript.new()
        if let m = manuscript { persistence.markOpened(id: m.id) }
        trySave()
    }

    /// Creates a new manuscript inside `folderURL` chosen by the user.
    func createNew(in folderURL: URL) {
        var m = Manuscript.new()
        // Store a security-scoped bookmark so the app retains access after relaunch.
        if let bookmark = try? folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            m.folderBookmark = bookmark
        }
        resetUndoHistory()
        manuscript = m
        persistence.setCustomFolder(folderURL, for: m.id)
        trySave()
    }

    func open(id: UUID) {
        resetUndoHistory()
        manuscript = persistence.load(id: id).map(normalized)
        if let m = manuscript {
            resolveBookmarkIfNeeded(for: m)
            persistence.markOpened(id: m.id)
            seedProfiles()
        }
    }

    /// Opens an existing project folder **in place** (File → Open (Local)…):
    /// the folder must hold a manuscript.json; edits keep writing there —
    /// nothing is copied into app data.  Returns an error message, or nil.
    func openLocal(folder: URL) -> String? {
        let json = folder.appendingPathComponent("manuscript.json")
        guard FileManager.default.fileExists(atPath: json.path) else {
            return "That folder doesn't contain a manuscript.json — pick the project folder exported or created by Manuscript Editor."
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var decoded = try decoder.decode(Manuscript.self, from: Data(contentsOf: json))
            // Keep editing THIS folder: register the mapping + a bookmark so
            // access survives relaunch.
            if let bookmark = try? folder.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                decoded.folderBookmark = bookmark
            }
            _ = folder.startAccessingSecurityScopedResource()
            persistence.setCustomFolder(folder, for: decoded.id)
            resetUndoHistory()
            manuscript = normalized(decoded)
            persistence.markOpened(id: decoded.id)
            trySave()
            return nil
        } catch {
            return "Couldn't read manuscript.json: \(error.localizedDescription)"
        }
    }

    /// Exports the whole project as a zip (File → Export Project…) that
    /// "Open Manuscript (Local)…" can reopen after unzipping.  Returns an
    /// error message, or nil.
    func exportProject(to zipURL: URL) -> String? {
        trySave()   // the zip carries what's on screen
        guard let m = manuscript else { return "No manuscript is open." }
        let dir = persistence.manuscriptDirectory(for: m.id)
        try? FileManager.default.removeItem(at: zipURL)
        // ditto preserves structure/attributes and ships with macOS.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", dir.path, zipURL.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                return "Couldn't create the zip: \(message.isEmpty ? "ditto failed" : message)"
            }
            return nil
        } catch {
            return "Couldn't create the zip: \(error.localizedDescription)"
        }
    }

    // MARK: - Normalization

    /// Sorts sections into canonical display order and renumbers `order`
    /// contiguously.  Heals legacy files where schema churn left duplicate or
    /// out-of-order values — without this, drag-to-reorder offsets (computed
    /// against the *sorted* list) can hit the wrong elements in the raw array.
    private func normalizedSections(_ sections: [ManuscriptSection]) -> [ManuscriptSection] {
        var sorted = sections.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            return a.id.uuidString < b.id.uuidString   // deterministic tiebreak for duplicates
        }
        for i in sorted.indices { sorted[i].order = i }
        return sorted
    }

    /// Applies section normalization to the source content and every version,
    /// back-fills reference-token lists for pre-refs files, and settles the
    /// bibliography into citation order.
    private func normalized(_ m: Manuscript) -> Manuscript {
        var m = m
        migrateLetter(&m)
        for i in m.versions.indices { migrateLetter(&m.versions[i].content) }
        m.sections = normalizedSections(m.sections)
        for i in m.versions.indices {
            m.versions[i].content.sections = normalizedSections(m.versions[i].content.sections)
        }
        withExtractedRefs(&m)
        RefEngine.autoOrderBibliography(&m)
        for i in m.versions.indices {
            withExtractedRefs(&m.versions[i].content)
            RefEngine.autoOrderBibliography(&m.versions[i].content)
        }
        return m
    }

    /// Turns a manuscript's fixed cover letter into a letter SECTION.
    ///
    /// Files written before the letter was a section kind carry it in
    /// `letterToEditor`.  A non-empty one becomes the last section, titled
    /// "Letter to the Editor", with its letterhead and signature beside its
    /// text; the legacy field is emptied so this runs once.  A file that
    /// already has a letter section is left alone.
    private func migrateLetter(_ m: inout Manuscript) {
        let legacy = m.letterToEditor
        guard !legacy.isEmpty else { return }
        m.letterToEditor = .empty()
        guard !m.sections.contains(where: { $0.sectionKind == .letter }) else { return }
        m.sections.append(ManuscriptSection(
            id: UUID(), type: .custom, title: "Letter to the Editor",
            content: legacy.body, order: m.sections.count, active: true,
            kind: .letter, letter: legacy.details))
    }

    /// Fills `RichText.refs` where it is still nil (files written before token
    /// tracking) by decoding the RTF once.  Editors keep the lists current
    /// from then on, so this never runs on an editing hot path.
    private func withExtractedRefs(_ m: inout Manuscript) {
        func fill(_ rt: inout RichText) {
            if rt.refs == nil { rt.refs = RefEngine.extractRefs(from: rt) }
        }
        fill(&m.abstract)
        for i in m.sections.indices { fill(&m.sections[i].content) }
    }

    func listSaved() -> [ManuscriptSummary] {
        persistence.listManuscripts()
    }

    /// Deletes a manuscript: its folder goes to the **Trash** (recoverable)
    /// and it is forgotten from the recents list.  Returns an error, or nil.
    func deleteManuscript(id: UUID) -> String? {
        let dir = persistence.manuscriptDirectory(for: id)
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } catch {
            return "Couldn't move the manuscript folder to the Trash: \(error.localizedDescription)"
        }
        persistence.forget(id: id)
        if UserDefaults.standard.string(forKey: "lastOpenedManuscriptID") == id.uuidString {
            UserDefaults.standard.removeObject(forKey: "lastOpenedManuscriptID")
        }
        if manuscript?.id == id { resetUndoHistory(); manuscript = nil }
        return nil
    }

    /// Drops a manuscript from the known list without touching its files
    /// (Manage Manuscripts → Remove from List).
    func forgetManuscript(id: UUID) {
        persistence.forget(id: id)
        if UserDefaults.standard.string(forKey: "lastOpenedManuscriptID") == id.uuidString {
            UserDefaults.standard.removeObject(forKey: "lastOpenedManuscriptID")
        }
    }

    /// Renames a manuscript's project title in place, open or not.
    /// Returns an error message, or nil.
    func renameManuscript(id: UUID, to title: String) -> String? {
        guard !title.isEmpty else { return nil }
        if manuscript?.id == id {
            updateTitle(title)
            trySave()
            return nil
        }
        let json = persistence.manuscriptDirectory(for: id).appendingPathComponent("manuscript.json")
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var m = try decoder.decode(Manuscript.self, from: Data(contentsOf: json))
            m.title = title
            m.updatedAt = Date()
            try persistence.save(m)
            return nil
        } catch {
            return "Couldn't rename: \(error.localizedDescription)"
        }
    }

    // MARK: - Persistence

    func trySave() {
        guard let m = manuscript else { return }
        do {
            try persistence.save(m)
            // The journals' own rules are part of the manuscript when they
            // differ from the app's defaults — written alongside it, not left
            // to whoever opens it next.
            writeTravelingProfiles()
            lastSaved = Date()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Manuscript metadata

    func updateTitle(_ title: String)               { touch { $0.title = title } }
    func updateAbout(_ text: String)                { touch { $0.about = text.isEmpty ? nil : text } }
    func updateRunningTitle(_ title: String, ref: VersionRef = .source) { touch(ref) { $0.runningTitle = title } }
    func updateSubtitle(_ subtitle: String, ref: VersionRef = .source) {
        touch(ref) { $0.subtitle = subtitle.isEmpty ? nil : subtitle }
    }
    /// The journal-facing article title — versioned content (Title pane).
    func updateArticleTitle(_ title: String, ref: VersionRef = .source) {
        touch(ref, undoAction: "Edit Title") { $0.articleTitle = title.isEmpty ? nil : title }
    }

    // MARK: - Fixed content panes (rename/hide)

    /// The display name of a fixed pane ("figures", "tables", …).
    func paneTitle(_ key: String, default def: String) -> String {
        manuscript?.paneTitles?[key] ?? def
    }

    func renamePane(_ key: String, to title: String) {
        touch {
            var titles = $0.paneTitles ?? [:]
            titles[key] = title.isEmpty ? nil : title
            $0.paneTitles = titles.isEmpty ? nil : titles
        }
    }

    func isPaneHidden(_ key: String) -> Bool {
        manuscript?.hiddenPanes?.contains(key) ?? false
    }

    func setPaneHidden(_ key: String, hidden: Bool) {
        touch {
            var keys = Set($0.hiddenPanes ?? [])
            if hidden { keys.insert(key) } else { keys.remove(key) }
            $0.hiddenPanes = keys.isEmpty ? nil : keys.sorted()
        }
    }
    func updateAbstract(_ abstract: RichText, ref: VersionRef = .source) { touch(ref, undoable: false) { $0.abstract = abstract } }
    func updateKeywords(_ keywords: [String], ref: VersionRef = .source) { touch(ref, undoAction: "Edit Keywords") { $0.keywords = keywords } }

    // MARK: - Authors

    func addAuthor(ref: VersionRef = .source) {
        touch(ref, undoAction: "Add Author") { $0.authors.append(Author.empty(order: $0.authors.count)) }
    }

    /// Adds an author autofilled from an ORCID search hit.  The candidate's
    /// primary (first-listed) institution is matched case-insensitively
    /// against the registry and created there only when missing.
    @discardableResult
    func addAuthor(from candidate: OrcidService.Candidate, ref: VersionRef = .source) -> UUID {
        var author = Author.empty()
        author.firstName = candidate.givenNames
        author.lastName  = candidate.familyNames
        author.email     = candidate.email ?? ""
        author.orcid     = candidate.orcid
        let newID = author.id
        touch(ref, undoAction: "Add Author") { m in
            author.order = m.authors.count
            if let name = candidate.institutionNames.first?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                if let existing = m.institutions.first(where: {
                    $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                        == .orderedSame
                }) {
                    author.institutionIDs = [existing.id]
                } else {
                    let institution = Institution(id: UUID(), name: name)
                    m.institutions.append(institution)
                    author.institutionIDs = [institution.id]
                }
            }
            m.authors.append(author)
        }
        return newID
    }

    func updateAuthor(_ author: Author, ref: VersionRef = .source) {
        touch(ref, undoAction: "Edit Author") { m in
            if let idx = m.authors.firstIndex(where: { $0.id == author.id }) { m.authors[idx] = author }
        }
    }

    func deleteAuthors(at offsets: IndexSet, ref: VersionRef = .source) {
        touch(ref, undoAction: "Delete Author") {
            $0.authors.remove(atOffsets: offsets)
            for i in $0.authors.indices { $0.authors[i].order = i }
        }
    }

    func moveAuthors(from source: IndexSet, to destination: Int, ref: VersionRef = .source) {
        touch(ref) {
            // The offsets come from the SORTED list the view shows; applying
            // them to the raw array scrambles rows whenever the two differ.
            var sorted = $0.authors.sorted { $0.order < $1.order }
            sorted.move(fromOffsets: source, toOffset: destination)
            for i in sorted.indices { sorted[i].order = i }
            $0.authors = sorted
        }
    }

    // MARK: - Institutions (registry referenced by authors)

    /// Appends a blank institution and returns its id (for focusing).
    @discardableResult
    func addInstitution(ref: VersionRef = .source) -> UUID {
        let institution = Institution.empty()
        touch(ref, undoAction: "Add Institution") { $0.institutions.append(institution) }
        return institution.id
    }

    func updateInstitution(_ institution: Institution, ref: VersionRef = .source) {
        touch(ref, undoAction: "Edit Institution") { m in
            if let idx = m.institutions.firstIndex(where: { $0.id == institution.id }) {
                m.institutions[idx] = institution
            }
        }
    }

    /// Removes an institution and strips its reference from every author.
    func deleteInstitution(id: UUID, ref: VersionRef = .source) {
        touch(ref, undoAction: "Delete Institution") { m in
            m.institutions.removeAll { $0.id == id }
            for i in m.authors.indices {
                m.authors[i].institutionIDs?.removeAll { $0 == id }
            }
        }
    }

    // MARK: - Sections
    //
    // Sections are **shared structure**: adding/deleting/reordering/renaming a
    // section applies to Source and every version so they line up in comparison.
    // What differs per version is a section's **content** and its **active** flag
    // (a version can deactivate a section it doesn't use).

    /// A unique section title (case-insensitive), suffixing "2", "3", … on collision.
    private func uniqueSectionTitle(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? "New Section" : trimmed
        let existing = Set((manuscript?.sections ?? []).map { $0.title.lowercased() })
        if !existing.contains(candidate.lowercased()) { return candidate }
        var n = 2
        while existing.contains("\(candidate) \(n)".lowercased()) { n += 1 }
        return "\(candidate) \(n)"
    }

    /// Adds a section to Source **and every version** (so it exists for every
    /// journal), with a unique title.  Returns the new section id.
    @discardableResult
    func addSection(type: SectionType = .custom, title: String? = nil,
                    kind: SectionKind = .text, undoable: Bool = true) -> UUID? {
        guard manuscript != nil else { return nil }
        let fallback: String
        switch kind {
        case .questions: fallback = "Submission Questions"
        case .letter:    fallback = "Letter to the Editor"
        case .text:      fallback = type == .custom ? "New Section" : type.rawValue
        }
        let uniqueTitle = uniqueSectionTitle(title ?? fallback)
        let id = UUID()
        // A question series starts with ONE empty question, so the pane opens
        // on something to fill in rather than on an empty state.
        func fresh(_ order: Int) -> ManuscriptSection {
            ManuscriptSection(id: id, type: type, title: uniqueTitle, content: RichText(),
                              order: order, active: true,
                              kind: kind == .text ? nil : kind,
                              questions: kind == .questions ? [QuestionEntry(order: 0)] : nil,
                              letter: kind == .letter ? LetterDetails() : nil)
        }
        touch(undoAction: "Add Section", undoable: undoable) { m in
            m.sections.append(fresh(m.sections.count))
            for v in m.versions.indices {
                var content = m.versions[v].content
                content.sections.append(fresh(content.sections.count))
                m.versions[v].content = content
            }
        }
        return id
    }

    /// The manuscript's letter section, if its pane has ever been opened.
    var letterSectionID: UUID? {
        manuscript?.sections.first { $0.sectionKind == .letter }?.id
    }

    /// The letter, made on first use.  Not undoable: opening a pane is not
    /// an edit, and ⌘Z taking the pane away would be a surprise.
    @discardableResult
    func ensureLetterSection() -> UUID? {
        letterSectionID ?? addSection(kind: .letter, undoable: false)
    }

    // MARK: - Question series

    /// Edits one section's questions in a single version (they are per-cut
    /// content, like prose — a journal asks its own questions).
    private func mutateQuestions(sectionID: UUID, ref: VersionRef, undo: String?,
                                 _ change: @escaping (inout [QuestionEntry]) -> Void) {
        touch(ref, undoAction: undo) { m in
            guard let idx = m.sections.firstIndex(where: { $0.id == sectionID }) else { return }
            var list = m.sections[idx].orderedQuestions
            change(&list)
            for i in list.indices { list[i].order = i }
            m.sections[idx].questions = list
            if m.sections[idx].kind == nil { m.sections[idx].kind = .questions }
        }
    }

    @discardableResult
    func addQuestion(sectionID: UUID, ref: VersionRef = .source) -> UUID? {
        let id = UUID()
        mutateQuestions(sectionID: sectionID, ref: ref, undo: "Add Question") { list in
            list.append(QuestionEntry(id: id, order: list.count))
        }
        return id
    }

    func updateQuestion(_ question: QuestionEntry, sectionID: UUID, ref: VersionRef = .source) {
        // Typing is not undoable per keystroke — the editors coalesce their
        // own snapshots, as everywhere else.
        mutateQuestions(sectionID: sectionID, ref: ref, undo: nil) { list in
            guard let i = list.firstIndex(where: { $0.id == question.id }) else { return }
            list[i] = question
        }
    }

    func deleteQuestion(id: UUID, sectionID: UUID, ref: VersionRef = .source) {
        mutateQuestions(sectionID: sectionID, ref: ref, undo: "Delete Question") { list in
            list.removeAll { $0.id == id }
        }
    }

    func moveQuestions(sectionID: UUID, from offsets: IndexSet, to destination: Int,
                       ref: VersionRef = .source) {
        mutateQuestions(sectionID: sectionID, ref: ref, undo: "Reorder Questions") { list in
            list.move(fromOffsets: offsets, toOffset: destination)
        }
    }

    /// Renames a section everywhere (shared structure), keeping the title unique.
    func renameSection(id: UUID, title: String) {
        touch(undoAction: "Rename Section") { m in
            // Uniqueness excluding this section itself.
            let others = Set(m.sections.filter { $0.id != id }.map { $0.title.lowercased() })
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            var finalTitle = trimmed.isEmpty ? "Section" : trimmed
            if others.contains(finalTitle.lowercased()) {
                var n = 2
                while others.contains("\(finalTitle) \(n)".lowercased()) { n += 1 }
                finalTitle = "\(finalTitle) \(n)"
            }
            if let i = m.sections.firstIndex(where: { $0.id == id }) { m.sections[i].title = finalTitle }
            for v in m.versions.indices {
                if let i = m.versions[v].content.sections.firstIndex(where: { $0.id == id }) {
                    m.versions[v].content.sections[i].title = finalTitle
                }
            }
        }
    }

    /// Activates / deactivates a section for one version.  A deactivated section
    /// is uneditable and excluded from Checks and Export, but its content is
    /// **preserved** so reactivating restores the text — Checks/Export filter on
    /// the `active` flag, never on emptiness, so nothing leaks while it's off.
    func setSectionActive(_ active: Bool, id: UUID, ref: VersionRef) {
        touch(ref, undoAction: active ? "Activate Section" : "Deactivate Section") { m in
            if let i = m.sections.firstIndex(where: { $0.id == id }) {
                m.sections[i].active = active
            }
        }
    }

    /// Edits one version's copy of a section (content etc.).
    func updateSection(_ section: ManuscriptSection, ref: VersionRef = .source) {
        touch(ref, undoable: false) { m in
            if let idx = m.sections.firstIndex(where: { $0.id == section.id }) { m.sections[idx] = section }
        }
    }

    /// Deletes a section everywhere (Source + all versions).
    func deleteSection(id: UUID) {
        touch(undoAction: "Delete Section") { m in
            m.sections.removeAll { $0.id == id }
            for i in m.sections.indices { m.sections[i].order = i }
            for v in m.versions.indices {
                m.versions[v].content.sections.removeAll { $0.id == id }
            }
        }
    }

    /// Swipe-to-delete from the (source-ordered) sidebar list — removes everywhere.
    func deleteSections(at offsets: IndexSet) {
        let sorted = (manuscript?.sections ?? []).sorted { $0.order < $1.order }
        let ids = offsets.compactMap { sorted.indices.contains($0) ? sorted[$0].id : nil }
        touch(undoAction: "Delete Section") { m in
            for id in ids {
                m.sections.removeAll { $0.id == id }
                for v in m.versions.indices { m.versions[v].content.sections.removeAll { $0.id == id } }
            }
            for i in m.sections.indices { m.sections[i].order = i }
        }
    }

    /// Reorders sections (shared structure); propagates the new order to every version.
    ///
    /// The drag offsets arrive relative to the *sorted* sidebar list, so the move
    /// is applied to the canonically sorted array (never the raw array, whose
    /// physical order can diverge in legacy files).
    func moveSections(from source: IndexSet, to destination: Int) {
        touch { m in
            var sorted = self.normalizedSections(m.sections)
            sorted.move(fromOffsets: source, toOffset: destination)
            for i in sorted.indices { sorted[i].order = i }
            m.sections = sorted
            let orderByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.order) })
            for v in m.versions.indices {
                var content = self.normalizedSections(m.versions[v].content.sections)
                for i in content.indices {
                    if let o = orderByID[content[i].id] { content[i].order = o }
                }
                m.versions[v].content.sections = content.sorted { $0.order < $1.order }
            }
        }
    }

    /// Resolves a section within `ref` by id (used by the section editor/pane).
    func section(_ id: UUID, ref: VersionRef) -> ManuscriptSection? {
        manuscript(for: ref)?.sections.first { $0.id == id }
    }

    // MARK: - Figures

    func addFigure(ref: VersionRef = .source) {
        touch(ref, undoAction: "Add Figure") { $0.figures.append(Figure.empty(number: ($0.figures.map(\.number).max() ?? 0) + 1)) }
    }

    func updateFigure(_ figure: Figure, ref: VersionRef = .source) {
        touch(ref, undoAction: "Edit Figure") { m in
            if let idx = m.figures.firstIndex(where: { $0.id == figure.id }) { m.figures[idx] = figure }
        }
    }

    func importFigureFile(from url: URL, for figureID: UUID, ref: VersionRef = .source) {
        guard let manuscriptID = manuscript?.id else { return }
        guard let fileName = try? persistence.importFigure(from: url, figureID: figureID, manuscriptID: manuscriptID) else { return }
        touch(ref) { m in
            if let idx = m.figures.firstIndex(where: { $0.id == figureID }) { m.figures[idx].fileName = fileName }
        }
    }

    func deleteFigures(at offsets: IndexSet, ref: VersionRef = .source) {
        touch(ref, undoAction: "Delete Figure") { $0.figures.remove(atOffsets: offsets) }
    }

    func figureURL(for figure: Figure) -> URL? {
        // Data-library images take precedence: raw data lives once in Data
        // and is referenced by figures, never copied.
        if let assetID = figure.imageAssetID,
           let asset = manuscript?.dataAssets.first(where: { $0.id == assetID }) {
            return dataImageURL(for: asset)
        }
        guard let manuscriptID = manuscript?.id, let fileName = figure.fileName else { return nil }
        return persistence.figureURL(fileName: fileName, manuscriptID: manuscriptID)
    }

    // MARK: - Tables

    func addTable(ref: VersionRef = .source) {
        touch(ref, undoAction: "Add Table") { $0.tables.append(ManuscriptTable.empty(number: ($0.tables.map(\.number).max() ?? 0) + 1)) }
    }

    func updateTable(_ table: ManuscriptTable, ref: VersionRef = .source) {
        touch(ref, undoAction: "Edit Table") { m in
            if let idx = m.tables.firstIndex(where: { $0.id == table.id }) { m.tables[idx] = table }
        }
    }

    func deleteTables(at offsets: IndexSet, ref: VersionRef = .source) {
        touch(ref, undoAction: "Delete Table") { $0.tables.remove(atOffsets: offsets) }
    }

    // MARK: - Data Assets

    /// Imports a CSV file into the manuscript's data library as a new `DataAsset`.
    /// Last data-import failure, surfaced as an alert by DataView (imports
    /// must never fail silently — the asset just wouldn't appear).
    var dataError: String?

    func importCSVAsset(from url: URL) {
        guard let dataDir = dataDirectoryURL else { return }
        do {
            let asset = try dataService.importCSV(from: url, into: dataDir)
            touch { $0.dataAssets.append(asset) }
        } catch {
            dataError = error.localizedDescription
        }
    }

    /// Imports an image file into the manuscript's data library.
    func importImageAsset(from url: URL) {
        guard let dataDir = dataDirectoryURL else { return }
        do {
            let asset = try dataService.importImage(from: url, into: dataDir)
            touch { $0.dataAssets.append(asset) }
        } catch {
            dataError = error.localizedDescription
        }
    }

    func updateDataAsset(_ asset: DataAsset) {
        guard let idx = manuscript?.dataAssets.firstIndex(where: { $0.id == asset.id }) else { return }
        touch { $0.dataAssets[idx] = asset }
    }

    func deleteDataAssets(at offsets: IndexSet) {
        touch(undoAction: "Delete Data Asset") { $0.dataAssets.remove(atOffsets: offsets) }
    }

    /// Returns the data directory URL for the current manuscript.
    var dataDirectoryURL: URL? {
        guard let id = manuscript?.id else { return nil }
        return persistence.dataDirectory(for: id)
    }

    /// Runs a SQL query against a data asset's SQLite database.
    func runQuery(_ sql: String, for asset: DataAsset) -> QueryResult {
        guard let dataDir = dataDirectoryURL else { return .empty }
        return dataService.runQuery(sql, asset: asset, dataDirectory: dataDir)
    }

    /// Whether the asset's original CSV was kept (enables re-fitting).
    func hasSourceCSV(for asset: DataAsset) -> Bool {
        guard let dataDir = dataDirectoryURL else { return false }
        return dataService.hasSourceCSV(for: asset, dataDirectory: dataDir)
    }

    /// Rebuilds a CSV asset's table with the data starting at `row`
    /// (1-based; the header is the row above it).
    func setDataStartRow(_ row: Int, for asset: DataAsset) {
        guard let dataDir = dataDirectoryURL else { return }
        do {
            try dataService.refitCSV(asset: asset, dataStartRow: row, dataDirectory: dataDir)
            var updated = asset
            updated.dataStartRow = row == 2 ? nil : row
            updateDataAsset(updated)
        } catch {
            dataError = error.localizedDescription
        }
    }

    /// Returns the image URL for a DataAsset of type `.image`.
    func dataImageURL(for asset: DataAsset) -> URL? {
        guard let manuscriptID = manuscript?.id, !asset.fileName.isEmpty else { return nil }
        return persistence.dataFileURL(fileName: asset.fileName, manuscriptID: manuscriptID)
    }

    // MARK: - Bibliography

    func addBibEntry(ref: VersionRef = .source) {
        touch(ref, undoAction: "Add Reference") { $0.bibliography.append(BibEntry.empty()) }
    }

    /// Appends a fully-populated entry (e.g. imported from Zotero), skipping
    /// duplicates that share the same `zoteroKey`.
    func addBibEntry(_ entry: BibEntry, ref: VersionRef = .source) {
        touch(ref, undoAction: "Add Reference") { m in
            if let zk = entry.zoteroKey, m.bibliography.contains(where: { $0.zoteroKey == zk }) { return }
            m.bibliography.append(entry)
        }
    }

    func updateBibEntry(_ entry: BibEntry, ref: VersionRef = .source) {
        touch(ref, undoAction: "Edit Reference") { m in
            if let idx = m.bibliography.firstIndex(where: { $0.id == entry.id }) { m.bibliography[idx] = entry }
        }
    }

    func deleteBibEntries(at offsets: IndexSet, ref: VersionRef = .source) {
        touch(ref, undoAction: "Delete Reference") { $0.bibliography.remove(atOffsets: offsets) }
    }

    /// Manual drag-reorder of the (flat) bibliography list.
    func moveBibEntries(from source: IndexSet, to destination: Int, ref: VersionRef = .source) {
        touch(ref) { $0.bibliography.move(fromOffsets: source, toOffset: destination) }
    }

    /// Reorders figures in DISPLAY order (drag): every figure's `number`
    /// is rewritten to its new position.  Display numbering still pins
    /// REFERENCED figures to citation order — like cited bibliography
    /// entries, a dragged referenced figure snaps back.
    func moveFigures(from source: IndexSet, to destination: Int, ref: VersionRef = .source) {
        touch(ref, undoAction: "Reorder Figures") { m in
            let numbers = RefEngine.effectiveFigureNumbers(in: m)
            var ordered = m.figures.sorted {
                (numbers[$0.id] ?? $0.number) < (numbers[$1.id] ?? $1.number)
            }
            ordered.move(fromOffsets: source, toOffset: destination)
            for (i, figure) in ordered.enumerated() {
                if let idx = m.figures.firstIndex(where: { $0.id == figure.id }) {
                    let old = m.figures[idx].number
                    m.figures[idx].number = i + 1
                    // A never-customized title ("Figure 3") follows its
                    // number; anything the user typed stays put.
                    if m.figures[idx].title == "Figure \(old)" {
                        m.figures[idx].title = "Figure \(i + 1)"
                    }
                }
            }
        }
    }

    /// Reorders tables in DISPLAY order — same rule as figures.
    func moveTables(from source: IndexSet, to destination: Int, ref: VersionRef = .source) {
        touch(ref, undoAction: "Reorder Tables") { m in
            let numbers = RefEngine.effectiveTableNumbers(in: m)
            var ordered = m.tables.sorted {
                (numbers[$0.id] ?? $0.number) < (numbers[$1.id] ?? $1.number)
            }
            ordered.move(fromOffsets: source, toOffset: destination)
            for (i, table) in ordered.enumerated() {
                if let idx = m.tables.firstIndex(where: { $0.id == table.id }) {
                    let old = m.tables[idx].number
                    m.tables[idx].number = i + 1
                    // A never-customized title ("Table 3") follows its
                    // number; anything the user typed stays put.
                    if m.tables[idx].title == "Table \(old)" {
                        m.tables[idx].title = "Table \(i + 1)"
                    }
                }
            }
        }
    }

    // MARK: Citations in text
    //
    // In-text references are link-attributed tokens inserted by the editor's
    // "/" autocomplete (see RefEngine).  Their document order comes from the
    // `RichText.refs` lists, so these queries never scan text.

    /// The rendering context (numbers, entry details, figure/table numbers)
    /// for every token in one version's prose.  Recomputed cheaply per render;
    /// editors compare its `signature` to skip redundant rewrite passes.
    /// App-wide citation format code, mirrored from UserDefaults so open
    /// editors re-render the moment it changes (observable dependency).
    var citationStyleCode: String =
        UserDefaults.standard.string(forKey: EditorPrefs.citationStyleKey) ?? "n"

    func setCitationStyle(_ code: String) {
        citationStyleCode = code
        UserDefaults.standard.set(code, forKey: EditorPrefs.citationStyleKey)
    }

    func refContext(for ref: VersionRef) -> RefEngine.Context? {
        let style = RefEngine.CitationStyle(rawValue: citationStyleCode)
        return manuscript(for: ref).map { RefEngine.context(for: $0, defaultStyle: style) }
    }

    /// Per-entry citation number, total count, and per-field usage for the
    /// Bibliography list badges and entry details.
    func citationIndex(ref: VersionRef) -> RefEngine.CitationIndex {
        manuscript(for: ref).map(RefEngine.citationIndex) ?? RefEngine.CitationIndex()
    }

    // MARK: - Letter to editor


    // MARK: - Notes
    //
    // Notes live at the top level of the manuscript (not inside version
    // snapshots), anchored to a content item within a version by string keys.

    /// Notes attached to a specific content item within a specific version,
    /// oldest first.
    func notes(versionKey: String, itemKey: String) -> [Note] {
        (manuscript?.notes ?? [])
            .filter { $0.versionKey == versionKey && $0.itemKey == itemKey }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Unresolved notes on an item — the sidebar badge hides once every
    /// comment is checked off (resolved = done, no attention needed).
    func openNoteCount(versionKey: String, itemKey: String) -> Int {
        (manuscript?.notes ?? []).reduce(0) {
            $0 + (($1.versionKey == versionKey && $1.itemKey == itemKey && !$1.resolved) ? 1 : 0)
        }
    }

    /// Total notes on a content item (used for the badge count).
    func noteCount(versionKey: String, itemKey: String) -> Int {
        (manuscript?.notes ?? []).reduce(0) {
            $0 + (($1.versionKey == versionKey && $1.itemKey == itemKey) ? 1 : 0)
        }
    }

    @discardableResult
    func addNote(versionKey: String, itemKey: String, author: String, body: String) -> Note {
        var note = Note.new(versionKey: versionKey, itemKey: itemKey, author: author, body: body)
        // Sign with the user's identity so collaborators can verify who
        // commented (see SignatureBadge).
        if let key = SigningService.publicKeyBase64 {
            note.authorKey = key
            note.signature = SigningService.sign(
                SigningService.noteMessage(id: note.id, createdAt: note.createdAt, body: note.body))
            note.authorType = SigningService.effectiveIdentityType
        }
        touch { $0.notes.append(note) }
        return note
    }

    func updateNote(_ note: Note) {
        var note = note
        // Body edits by the original signer re-sign; anyone else's edit
        // leaves the old signature, which then fails verification — exactly
        // the "red x" the badge is for.
        if let key = SigningService.publicKeyBase64, note.authorKey == key {
            note.signature = SigningService.sign(
                SigningService.noteMessage(id: note.id, createdAt: note.createdAt, body: note.body))
        }
        touch { m in
            if let idx = m.notes.firstIndex(where: { $0.id == note.id }) { m.notes[idx] = note }
        }
    }

    func deleteNote(id: UUID) {
        touch { $0.notes.removeAll { $0.id == id } }
    }

    // MARK: - Manuscript settings

    func updateManuscriptSettings(_ settings: ManuscriptSettings) {
        touch { $0.settings = settings }
    }

    // MARK: - Journals

    func addJournal(_ journal: Journal) {
        touch(undoAction: "Add Journal") { $0.journals.append(journal) }
    }

    func updateJournal(_ journal: Journal) {
        guard let idx = manuscript?.journals.firstIndex(where: { $0.id == journal.id }) else { return }
        touch { $0.journals[idx] = journal }
    }

    /// Checks' one-click repair: aligns every export document and item of
    /// the journal with its required typography (size, spacing, line
    /// numbers), correcting conflicting overrides.
    func applyRequiredTypography(journalID: UUID) {
        guard let journal = manuscript?.journals.first(where: { $0.id == journalID }) else { return }
        var config = exportConfig(forJournal: journalID)
        let r = journal.requirements
        for d in config.documents.indices {
            if let size = r.requiredFontSize { config.documents[d].format.fontSize = size }
            if let spacing = r.requiredLineSpacing { config.documents[d].format.lineSpacing = spacing }
            if let lines = r.requiresLineNumbers { config.documents[d].format.lineNumbers = lines }
            for i in config.documents[d].items.indices {
                if var override = config.documents[d].items[i].format {
                    if let size = r.requiredFontSize { override.fontSize = size }
                    if let spacing = r.requiredLineSpacing { override.lineSpacing = spacing }
                    config.documents[d].items[i].format = override
                }
                // Line numbering is section-level: clear the breaks so
                // every section inherits the document's (required) setting.
                if r.requiresLineNumbers != nil,
                   config.documents[d].items[i].sectionLineNumbers != nil {
                    config.documents[d].items[i].sectionLineNumbers = nil
                }
            }
        }
        updateExportConfig(config, forJournal: journalID)
        showBanner(.success, "Export typography aligned with \(journal.displayName)'s requirements.")
    }

    /// Fills a journal's profile — requirements, checks, and structure —
    /// from the user's library, falling back to what the app ships.  Called
    /// on add and on open, so an existing manuscript picks up profiles with
    /// no migration step.  A journal the user has edited HERE is left alone:
    /// the manuscript's own copy is authoritative for the manuscript.
    func seedProfileIfNeeded(journalID: UUID) {
        guard let m = manuscript,
              let journal = m.journals.first(where: { $0.id == journalID })
        else { return }
        let library = JournalProfileLibrary.shared
        guard let source = journal.profileID.flatMap({ library.profile(id: $0) })
                ?? library.profile(name: journal.name, articleType: journal.articleType)
                ?? JournalProfile.bundled(name: journal.name, articleType: journal.articleType)
        else { return }

        // A journal the user has edited HERE owns its configuration, so its
        // checks and requirements are left alone.  Structure is different:
        // journals edited before structure existed have none at all, and an
        // empty structure isn't a choice the user made — fill it in, and
        // adopt the GUID so the two stay linked.
        if journal.configOrigin == .manuscript {
            guard journal.structure == nil || journal.profileID == nil else { return }
            touch(undoable: false) { m in
                guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
                if m.journals[idx].structure == nil { m.journals[idx].structure = source.structure }
                if m.journals[idx].profileID == nil { m.journals[idx].profileID = source.id }
            }
            writeProfile(journalID: journalID)
            return
        }

        // Otherwise the journal TRACKS the library, so it follows it: seed
        // when it has no checks, when it predates profiles carrying a GUID
        // (the identity the library is matched on), or whenever the library's
        // copy has moved on.  Nothing is lost — a local edit sets
        // `configOrigin = .manuscript` and takes the branch above.
        let stale = ProfilePart.allCases.contains {
            journal.profile.fingerprint($0) != source.fingerprint($0)
        }
        guard (journal.checkRules ?? []).isEmpty || journal.profileID == nil || stale
        else { return }
        touch(undoable: false) { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            m.journals[idx].profileID = source.id
            m.journals[idx].profileLineage = source.lineage.isEmpty ? nil : source.lineage
            m.journals[idx].checkRules = source.checks
            m.journals[idx].sourceRequirements = source.requirements
            m.journals[idx].structure = source.structure
            m.journals[idx].configOrigin = source.origin
            m.journals[idx].configURL = source.originURL
        }
        writeProfile(journalID: journalID)
    }

    /// Adds any section this journal's structure names that the manuscript
    /// doesn't have yet.
    ///
    /// This is how a journal's **submission questions** travel with it: record
    /// the question series in the journal's structure once, and forking to
    /// that journal brings the section along, already in question form.
    /// Sections are shared, so an existing one is left exactly as it is.
    func addMissingStructureSections(journalID: UUID) {
        guard let m = manuscript,
              let journal = m.journals.first(where: { $0.id == journalID }),
              let wanted = journal.structure?.sections, !wanted.isEmpty
        else { return }
        let existing = Set(m.sections.map { $0.title.lowercased() })
        var created: [(id: UUID, entry: StructureSection)] = []
        // An "Abstract" entry describes the abstract FIELD — its format,
        // notes and boilerplate — not a section to create beside it.  A
        // letter entry (templates could carry one for a while) is ignored:
        // the letter is the author's, with a pane of its own.
        for section in wanted
        where !existing.contains(section.key) && section.key != "abstract" && section.kind != .letter {
            guard let id = addSection(type: .custom, title: section.title, kind: section.kind)
            else { continue }
            created.append((id, section))
        }
        // A section created here arrives in THIS journal's cut with what the
        // venue carries for it — its boilerplate, its questions.  Source's
        // copy and every other cut's stay empty: the section is theirs in
        // shape only.  (It used to land in Source's copy, which is the one
        // place it wasn't wanted.)  Only sections created just now: one
        // already there is never written over by adding a journal.
        if !created.isEmpty, let head = latestVersion(forJournal: journalID) {
            touch(.version(head.id), undoable: false) { content in
                for (id, entry) in created {
                    guard let idx = content.sections.firstIndex(where: { $0.id == id }) else { continue }
                    content.sections[idx] = Self.templated(content.sections[idx], entry: entry)
                }
            }
        }
        // The outline is where a template's formatting lives; the per-section
        // formats are the older path, for templates that never had one.
        if !adoptTemplateExport(journalID: journalID) {
            applyTemplateFormatting(journalID: journalID)
        }
    }

    /// Gives a journal its template's export outline, pointed at this
    /// manuscript's sections.
    ///
    /// A template's outline names the template's own sections; a manuscript's
    /// sections have their own ids.  Copying the outline raw — which is what
    /// happened before — left every section row reading "(missing section)".
    /// So each section item is matched **by title** through the template
    /// (uid → title → this manuscript's section), the cover letter and fixed
    /// parts pass straight through, and anything that matches nothing is
    /// dropped.  Templates with no outline fall back to
    /// `applyTemplateFormatting`, which reads the older per-section formats.
    @discardableResult
    func adoptTemplateExport(journalID: UUID) -> Bool {
        guard let journal = manuscript?.journals.first(where: { $0.id == journalID }),
              let template = journal.profileID
                .flatMap({ JournalProfileLibrary.shared.profile(id: $0) }),
              let export = template.export, !export.documents.isEmpty,
              let content = latestVersion(forJournal: journalID)?.content ?? manuscript
        else { return false }
        updateExportConfig(remappedExport(export, template: template, content: content),
                           forJournal: journalID)
        return true
    }

    private func remappedExport(_ config: ExportConfig, template: JournalTemplate,
                                content: Manuscript) -> ExportConfig {
        let repaired = TemplateWorkspace.repaired(config, for: template)
        let keyByUID = Dictionary(template.structure.sections.map { ($0.uid, $0.key) },
                                  uniquingKeysWith: { first, _ in first })
        let idByKey = Dictionary(content.sections.map { ($0.title.lowercased(), $0.id) },
                                 uniquingKeysWith: { first, _ in first })
        var out = repaired
        for d in out.documents.indices {
            out.documents[d].items = out.documents[d].items.compactMap { item in
                if item.kind == .coverLetter { return nil }      // legacy kind
                guard item.kind == .section else { return item }
                guard let uid = item.sectionID, let key = keyByUID[uid], let id = idByKey[key]
                else { return nil }
                var mapped = item
                mapped.sectionID = id
                return mapped
            }
        }
        return out
    }

    /// Applies a template's export formatting to a journal's outline.
    ///
    /// The formats travel with the structure, so a forked journal ADOPTS the
    /// target's typography — the title block, byline and abstract set the way
    /// that venue sets them — while their content copies over one for one.
    /// Section formats are matched by title, since section ids belong to a
    /// manuscript and a template is shared across many.
    func applyTemplateFormatting(journalID: UUID) {
        guard let journal = manuscript?.journals.first(where: { $0.id == journalID }),
              let structure = journal.structure,
              structure.documentFormat != nil || structure.coreFormats != nil
                  || structure.sections.contains(where: { $0.format != nil })
        else { return }
        guard let content = latestVersion(forJournal: journalID)?.content ?? manuscript
        else { return }

        var config = journal.exportConfig ?? ExportConfig.standard(content: content, journal: journal)
        guard !config.documents.isEmpty else { return }
        let formatByTitle = Dictionary(
            structure.sections.compactMap { entry in entry.format.map { (entry.title.lowercased(), $0) } },
            uniquingKeysWith: { first, _ in first })

        for d in config.documents.indices {
            if let documentFormat = structure.documentFormat {
                config.documents[d].format = documentFormat
            }
            for i in config.documents[d].items.indices {
                let item = config.documents[d].items[i]
                switch item.kind {
                case .pageBreak:
                    continue
                case .section:
                    guard let id = item.sectionID,
                          let title = content.sections.first(where: { $0.id == id })?.title,
                          let format = formatByTitle[title.lowercased()] else { continue }
                    config.documents[d].items[i].format = format
                default:
                    guard let format = structure.coreFormats?[item.kind.rawValue] else { continue }
                    config.documents[d].items[i].format = format
                }
            }
        }
        updateExportConfig(config, forJournal: journalID)
    }

    /// A section as a journal receives it: the shape it has upstream and
    /// none of the upstream's text — the venue's boilerplate and questions in
    /// its place.
    ///
    /// Text belongs to a fast-forward, the moment the user asks for it; what
    /// a cut is born with is the venue's.  Boilerplate goes in as rich text
    /// so its `[[title]]` tokens are live (`PartEngine.richText`).
    static func templated(_ section: ManuscriptSection, entry: StructureSection?) -> ManuscriptSection {
        // The letter is the author's — letterhead, signature, format and
        // text — and comes along whole, like the title and the authors.
        if section.sectionKind == .letter { return section }
        var out = section
        // First, none of the upstream's text.
        switch section.sectionKind {
        case .text, .letter:
            out.content = RichText()
        case .questions:
            out.questions = section.orderedQuestions.map { var q = $0; q.response = RichText(); return q }
        }
        // Then what the venue carries for it.
        guard let entry else { return out }
        switch entry.kind {
        case .text, .letter:
            if entry.kind == .letter {
                out.kind = .letter
                if out.letter == nil { out.letter = LetterDetails() }
            }
            if let sample = entry.sample, !sample.isEmpty {
                out.content = PartEngine.richText(sample)
            }
        case .questions:
            guard let questions = entry.questions, !questions.isEmpty else { break }
            out.kind = .questions
            out.questions = questions.enumerated().map { index, q in
                var made = QuestionEntry()
                made.prompt = q.prompt
                made.wordLimit = q.wordLimit
                made.limitUnit = q.limitUnit
                made.order = index
                if let sample = q.sample, !sample.isEmpty {
                    made.response = PartEngine.richText(sample)
                }
                return made
            }
        }
        return out
    }

    /// The upstream's content as a new journal receives it: everything but
    /// its prose.  Title, authors, figures, tables and bibliography come
    /// along — the tokens in a title page need them, and they are the
    /// manuscript's.  The **abstract** does not: it is a cut's prose like
    /// any section (structured at one venue, a paragraph at another), so it
    /// starts from what the venue's structure says for "Abstract", if
    /// anything, and arrives on the first fast-forward like the rest.
    func templatedContent(_ content: Manuscript, journal: Journal) -> Manuscript {
        let byKey = Dictionary((journal.structure?.sections ?? []).map { ($0.key, $0) },
                               uniquingKeysWith: { first, _ in first })
        var out = content
        out.sections = content.sections.map { Self.templated($0, entry: byKey[$0.title.lowercased()]) }
        out.abstract = Self.templated(FastForwardIntent.abstractSection(content),
                                      entry: byKey["abstract"]).content
        return out
    }

    /// Writes **every** journal's template into the manuscript.
    ///
    /// Every one, not only the modified ones.  Carrying just the edited ones
    /// left the rest depending on the app that opens the manuscript being the
    /// app that made it — and an app update that corrects a bundled template
    /// would then silently re-grade a finished paper, or lose the template
    /// altogether if it were withdrawn.  A manuscript states the rules it was
    /// written to; the library is only where new ones come from.
    func writeTravelingProfiles() {
        guard let m = manuscript else { return }
        for journal in m.journals {
            _ = writeProfile(journalID: journal.id)
        }
    }

    /// Whether this journal's rules differ from the app's default for it —
    /// what the pane shows as "edited", not whether the rules travel.  They
    /// always travel.
    func differsFromDefault(_ journal: Journal) -> Bool {
        let mine = journal.profile
        return JournalProfile.bundled()[mine.id].map { $0.checksum != mine.checksum } ?? true
    }

    /// Seeds every journal that still needs it (called after a manuscript
    /// opens).
    func seedProfiles() {
        for journal in manuscript?.journals ?? [] {
            seedProfileIfNeeded(journalID: journal.id)
        }
    }

    /// Edits a journal's source requirements.  The first edit makes this
    /// manuscript the OWNER of the configuration: the profile is written into
    /// the manuscript folder (and therefore into its remote, if it has one)
    /// instead of tracking the library's copy.
    func updateSourceRequirements(_ requirements: SourceRequirements, journalID: UUID) {
        touch(undoAction: "Edit Source Requirements") { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            var edited = requirements
            edited.editedAt = Date()
            m.journals[idx].sourceRequirements = edited
            m.journals[idx].configOrigin = .manuscript
            m.journals[idx].configURL = nil
        }
        writeProfile(journalID: journalID)
    }

    /// Edits a journal's expected structure — same ownership rule as the
    /// requirements and the checks.
    func updateStructure(_ structure: JournalStructure, journalID: UUID) {
        touch(undoAction: "Edit Structure") { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            m.journals[idx].structure = structure
            m.journals[idx].configOrigin = .manuscript
            m.journals[idx].configURL = nil
        }
        writeProfile(journalID: journalID)
    }

    /// Writes a journal's three configuration files into the manuscript
    /// folder at `journals/<slug>/`, so the profile travels with the
    /// manuscript locally and in its remote repository.
    @discardableResult
    func writeProfile(journalID: UUID) -> URL? {
        guard let m = manuscript,
              let journal = m.journals.first(where: { $0.id == journalID }),
              let dir = persistence.manuscriptDirectory(for: m.id) as URL? else { return nil }
        let folder = dir
            .appendingPathComponent("journals", isDirectory: true)
            .appendingPathComponent(journal.profileSlug, isDirectory: true)
        var profile = journal.profile
        profile.updatedAt = Date()
        profile.partChecksums = Dictionary(uniqueKeysWithValues:
            ProfilePart.allCases.map { ($0.rawValue, profile.fingerprint($0)) })
        guard profile.write(to: folder) else { return nil }
        // A previous version wrote `journals/<slug>.json`; leaving it beside
        // the folder would look authoritative in the manuscript and in its
        // remote.
        let legacy = dir.appendingPathComponent("journals", isDirectory: true)
            .appendingPathComponent("\(journal.profileSlug).json")
        try? FileManager.default.removeItem(at: legacy)
        return folder
    }

    /// The link for a journal's configuration folder: the manuscript's own
    /// copy when it owns one (and has a remote), else the app's default.
    func profileLink(for journal: Journal) -> (label: String, url: String)? {
        if journal.configOrigin == .manuscript {
            guard let repo = manuscript?.settings.remoteRepository, !repo.isEmpty else {
                return ("This manuscript (local)", "")
            }
            let base = repo.hasPrefix("http") ? repo : "https://github.com/\(repo)"
            return ("This manuscript", "\(base)/tree/main/journals/\(journal.profileSlug)")
        }
        if journal.configOrigin == .library {
            return ("Your library", "")
        }
        return ("App defaults", JournalProfile.bundledURL(slug: journal.profileSlug))
    }

    /// The plain prose a comparable pane shows, for the sentence-similarity
    /// highlighting in compare mode.  nil where a pane has no prose to compare
    /// (authors, figures, the asset lists).
    func comparableText(for item: SidebarItem, ref: VersionRef) -> String? {
        guard let m = manuscript(for: ref) else { return nil }
        switch item {
        case .abstract:       return m.abstract.plain
        case .section(let id):
            // Versions keep the source ids at cut time; fall back to the same
            // section TYPE so a replaced section still compares.
            if let byID = m.sections.first(where: { $0.id == id }) {
                return byID.active ? byID.plainText : nil
            }
            guard let type = manuscript?.sections.first(where: { $0.id == id })?.type,
                  type != .custom,
                  let byType = m.sections.first(where: { $0.type == type })
            else { return nil }
            return byType.active ? byType.plainText : nil
        default: return nil
        }
    }

    // MARK: - AI context

    /// The context rows for this manuscript, seeding the two built-in rows the
    /// first time they're asked for.  Seeded lazily rather than at creation so
    /// manuscripts written before this feature gain them on open.
    var aiContextEntries: [AIContextEntry] {
        guard let stored = manuscript?.aiContext, !stored.isEmpty else {
            return [AIContextEntry(kind: .appPrimer, title: AIContextPrimer.title),
                    AIContextEntry(kind: .manuscriptData, title: "This manuscript")]
        }
        // A stored list that predates a built-in row still gets it, off the
        // end of the list so the user's own ordering survives.
        var entries = stored
        for kind in [AIContextKind.appPrimer, .manuscriptData]
        where !entries.contains(where: { $0.kind == kind }) {
            entries.insert(AIContextEntry(kind: kind, title: kind.label),
                           at: kind == .appPrimer ? 0 : min(1, entries.count))
        }
        return entries
    }

    private func writeContext(_ entries: [AIContextEntry], undo: String?) {
        touch(undoAction: undo) { $0.aiContext = entries }
    }

    func setContextEnabled(_ enabled: Bool, id: UUID) {
        var entries = aiContextEntries
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        // The primer carries no user content and the model is useless without
        // it, so it isn't switchable.
        guard !entries[idx].isLocked else { return }
        entries[idx].isEnabled = enabled
        writeContext(entries, undo: enabled ? "Include Context" : "Exclude Context")
    }

    func updateContextEntry(_ entry: AIContextEntry) {
        var entries = aiContextEntries
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var edited = entry
        edited.updatedAt = Date()
        entries[idx] = edited
        writeContext(entries, undo: nil)
    }

    @discardableResult
    func addContextNote() -> UUID? {
        var entries = aiContextEntries
        let entry = AIContextEntry(kind: .freeText, title: "New note")
        entries.append(entry)
        writeContext(entries, undo: "Add Context")
        return entry.id
    }

    /// Copies a file into the manuscript's `context/` folder and adds a row for
    /// it, so the attachment travels with the manuscript rather than pointing
    /// at a path that may not exist on another machine.
    @discardableResult
    func addContextFile(from source: URL) -> UUID? {
        guard let id = manuscript?.id else { return nil }
        let stored = "\(UUID().uuidString.lowercased())-\(source.lastPathComponent)"
        let destination = persistence.contextDirectory(for: id).appendingPathComponent(stored)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            showBanner(.error, "Couldn't add \(source.lastPathComponent) to the context.")
            return nil
        }
        var entries = aiContextEntries
        let entry = AIContextEntry(kind: .file, title: source.lastPathComponent,
                                   fileName: stored)
        entries.append(entry)
        writeContext(entries, undo: "Add Context File")
        return entry.id
    }

    func removeContextEntry(id: UUID) {
        var entries = aiContextEntries
        guard let idx = entries.firstIndex(where: { $0.id == id }),
              !entries[idx].kind.isBuiltIn else { return }
        if let name = entries[idx].fileName, let mid = manuscript?.id {
            try? FileManager.default.removeItem(
                at: persistence.contextDirectory(for: mid).appendingPathComponent(name))
        }
        entries.remove(at: idx)
        writeContext(entries, undo: "Remove Context")
    }

    /// Reads an attached context file as text.  Anything that isn't decodable
    /// text is skipped rather than sent as noise.
    func contextFileText(_ fileName: String) -> String? {
        guard let id = manuscript?.id else { return nil }
        let url = persistence.contextDirectory(for: id).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// The payload actually sent with a request — enabled rows only.
    func aiContextBundle(includeSectionText: Bool = true) -> AIContextBundle {
        AIContextBundle.build(entries: aiContextEntries,
                              manuscript: manuscript,
                              fileText: { [weak self] in self?.contextFileText($0) },
                              includeSectionText: includeSectionText)
    }

    // MARK: - Export attachments

    /// The stored copy of an uploaded export document.
    func attachmentURL(for document: ExportDocument) -> URL? {
        guard let name = document.attachmentFileName, let id = manuscript?.id else { return nil }
        let url = persistence.attachmentsDirectory(for: id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies a file into the manuscript and adds it to a journal's export
    /// outline as a passthrough document.  The copy is what travels with the
    /// manuscript, so the package still builds on another machine.
    @discardableResult
    func addAttachmentDocument(from source: URL, forJournal journalID: UUID?) -> Bool {
        guard let id = manuscript?.id else { return false }
        let ext = source.pathExtension
        let stored = "\(UUID().uuidString.lowercased())\(ext.isEmpty ? "" : ".\(ext)")"
        let destination = persistence.attachmentsDirectory(for: id).appendingPathComponent(stored)
        // Reading through a security scope: the panel hands back a URL the
        // app may only touch while it is open.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            showBanner(.error, "Couldn't add \(source.lastPathComponent) to the export.")
            return false
        }
        var config = exportConfig(forJournal: journalID)
        config.documents.append(ExportDocument(
            name: source.deletingPathExtension().lastPathComponent,
            items: [],
            attachmentFileName: stored,
            attachmentOriginalName: source.lastPathComponent))
        updateExportConfig(config, forJournal: journalID)
        showBanner(.success, "\(source.lastPathComponent) added to the export package.")
        return true
    }

    /// Removes an uploaded document's stored file (called when its document
    /// leaves the outline, so the manuscript doesn't accumulate orphans).
    func removeAttachmentFile(for document: ExportDocument) {
        guard let url = attachmentURL(for: document) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Journal library

    /// How this journal's profile compares with the user's library — what
    /// lights the warning icons and what Save to Library will do.
    func libraryStatus(for journal: Journal) -> ProfileLibraryStatus {
        JournalProfileLibrary.shared.status(of: journal.profile)
    }

    /// The journal behind a pane's tab.  A pane IS its tab's journal; Source
    /// has none, which is why every one of these returns an optional.
    func paneJournal(for ref: VersionRef) -> Journal? {
        guard case .version(let id) = ref,
              let jid = versions.first(where: { $0.id == id })?.journalID
        else { return nil }
        return manuscript?.journals.first { $0.id == jid }
    }

    /// Whether this part differs from the template it came from.
    ///
    /// One question, asked the same way everywhere it is asked — the profile
    /// panes and the sidebar all want the orange pencil to mean exactly this:
    /// **have I changed this since it came from the template?**
    ///
    /// Prefers the checksums the template recorded when it was saved, since
    /// the manuscript carries its own copy of the template and the comparison
    /// should work without the library holding it at all.  The structure is
    /// compared against what a save WOULD produce, because it is computed from
    /// this cut's sections and their export formatting — none of which is in
    /// the stored structure until a capture happens.
    func partDiffersFromTemplate(_ part: ProfilePart, journal: Journal) -> Bool {
        var mine = journal.profile
        if part == .structure, let prospective = structureCapture(journalID: journal.id) {
            mine.structure = prospective
        }
        let template = journal.profileID.flatMap { JournalProfileLibrary.shared.profile(id: $0) }
        if let saved = (template?.partChecksums ?? journal.profile.partChecksums)?[part.rawValue] {
            return mine.fingerprint(part) != saved
        }
        if let template {
            return mine.fingerprint(part) != template.fingerprint(part)
        }
        switch libraryStatus(for: journal) {
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

    /// Writes ONE part of this journal's configuration into its template.
    ///
    /// Per part, because the parts move independently: you tighten a test
    /// without meaning to publish the summary you were halfway through
    /// rewriting, and a single Save that took all four made every save a
    /// bigger decision than it needed to be.  Each part carries its own
    /// checksum, so each knows on its own whether it differs.
    ///
    /// Saving the STRUCTURE also captures this cut's section content as the
    /// template's sample text — the callers warn about that, because it is
    /// how someone's own manuscript text could end up as everyone's starting
    /// point.
    @discardableResult
    func saveTemplatePart(_ part: ProfilePart, journalID: UUID) -> Bool {
        if part == .structure { captureStructureFromSections(journalID: journalID) }

        guard let journal = manuscript?.journals.first(where: { $0.id == journalID })
        else { return false }
        let mine = journal.profile
        let library = JournalProfileLibrary.shared

        // Start from the template as it stands, so the other parts are left
        // exactly as they are.
        guard var target = journal.profileID.flatMap({ library.profile(id: $0) })
                ?? library.profile(name: mine.name, articleType: mine.articleType) else {
            showBanner(.error, "\(journal.name) has no template to save into — use Link Template… or Add to Template Library.")
            return false
        }
        switch part {
        case .requirements: target.requirements = mine.requirements
        case .checks:       target.checks = mine.checks
        case .structure:
            // What the pane compared against is what gets written.
            target.structure = structureCapture(journalID: journalID) ?? mine.structure
        case .export:       target.export = mine.export
        }
        guard library.save(target) else {
            showBanner(.error, "Couldn't write \(target.displayName) to your templates.")
            return false
        }
        touch(undoable: false) { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            m.journals[idx].profileID = target.id
            m.journals[idx].templateName = target.name
            m.journals[idx].templateChecksum = target.checksum
        }
        writeProfile(journalID: journalID)
        showBanner(.success, "\(part.label) saved to the “\(target.displayName)” template.")
        return true
    }

    /// Loads ONE part from this journal's template, leaving the rest alone.
    ///
    /// The mirror of `saveTemplatePart`: each part is its own decision in both
    /// directions, so taking the venue's content back doesn't also throw away
    /// a test you were in the middle of writing.
    @discardableResult
    func loadTemplatePart(_ part: ProfilePart, journalID: UUID) -> Bool {
        guard let journal = manuscript?.journals.first(where: { $0.id == journalID }),
              let template = journal.profileID
                .flatMap({ JournalProfileLibrary.shared.profile(id: $0) })
        else {
            showBanner(.error, "\(manuscript?.journals.first { $0.id == journalID }?.name ?? "This journal") has no template to load from.")
            return false
        }
        touch(undoAction: "Load \(part.label)") { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            switch part {
            case .requirements: m.journals[idx].sourceRequirements = template.requirements
            case .checks:       m.journals[idx].checkRules = template.checks
            case .structure:    m.journals[idx].structure = template.structure
            case .export:       break   // remapped below, once the touch is done
            }
        }
        if part == .structure { applyTemplateFormatting(journalID: journalID) }
        if part == .export { adoptTemplateExport(journalID: journalID) }
        writeProfile(journalID: journalID)
        showBanner(.success, "\(part.label) loaded from the “\(template.displayName)” template.")
        return true
    }

    /// Points a journal at a template explicitly, and takes its rules.
    ///
    /// A journal can be orphaned — its template deleted, renamed past
    /// recognition, or never present on this machine because the manuscript
    /// came from someone else.  Name matching cannot rescue that (a journal
    /// called "BMJ test 1" matches nothing), so the link has to be something
    /// you can state.  Without this, an orphaned journal has no way back to a
    /// template at all.
    @discardableResult
    func linkToTemplate(_ templateID: UUID, journalID: UUID) -> Bool {
        guard let template = JournalProfileLibrary.shared.profile(id: templateID),
              manuscript?.journals.contains(where: { $0.id == journalID }) == true
        else { return false }
        touch(undoAction: "Link Template") { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            m.journals[idx].profileID = template.id
            m.journals[idx].templateName = template.name
            m.journals[idx].templateChecksum = template.checksum
            m.journals[idx].profileLineage = template.lineage.isEmpty ? nil : template.lineage
        }
        adoptLibraryProfile(journalID: journalID)
        return true
    }

    /// The other direction: replaces this journal's configuration with the
    /// library's copy.
    ///
    /// Saving pushed the manuscript's configuration into the library and there
    /// was no way back, so a profile corrected in the library — a fixed link,
    /// a limit read properly off the journal's page — could never reach the
    /// manuscript that needed it.  The manuscript is still the authority on
    /// its own content; this replaces only the three profile files.
    @discardableResult
    func adoptLibraryProfile(journalID: UUID) -> Bool {
        guard let journal = manuscript?.journals.first(where: { $0.id == journalID })
        else { return false }
        let library = JournalProfileLibrary.shared
        guard let profile = journal.profileID.flatMap({ library.profile(id: $0) })
                ?? library.profile(name: journal.name, articleType: journal.articleType)
        else {
            showBanner(.error, "Your library has no profile for \(journal.displayName).")
            return false
        }
        touch(undoAction: "Update From Library") { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            m.journals[idx].sourceRequirements = profile.requirements
            m.journals[idx].checkRules = profile.checks
            m.journals[idx].structure = profile.structure
            m.journals[idx].profileID = profile.id
            // The template's own name and checksum, so "edited since" is a
            // comparison rather than a guess — and so renaming either side
            // doesn't break the link.
            m.journals[idx].templateName = profile.name
            m.journals[idx].templateChecksum = profile.checksum
            m.journals[idx].profileLineage = profile.lineage.isEmpty ? nil : profile.lineage
            m.journals[idx].configOrigin = profile.origin
            m.journals[idx].configURL = profile.originURL
            if m.journals[idx].submissionURL.isEmpty {
                m.journals[idx].submissionURL = profile.requirements.url
            }
        }
        adoptTemplateExport(journalID: journalID)
        writeProfile(journalID: journalID)
        showBanner(.success, "\(journal.displayName) updated from your journal library — \(profile.requirements.bullets.count) requirements, \(profile.checks.count) tests\(profile.export == nil ? "" : ", and its export outline").")
        return true
    }

    /// Overwrites a library profile with this journal's configuration.
    ///
    /// `replacingID` is the library entry to take over — its GUID wins, and
    /// the manuscript adopts it, so the two stay linked from then on.  With
    /// no `replacingID` this simply writes the profile under its own GUID.
    func saveProfileToLibrary(journalID: UUID, replacingID: UUID? = nil) {
        captureStructureFromSections(journalID: journalID)
        guard let journal = manuscript?.journals.first(where: { $0.id == journalID }) else { return }
        var profile = journal.profile
        if let replacingID {
            profile.id = replacingID
            // Taking over an ancestor makes the branch pointless.
            profile.lineage = []
        }
        guard JournalProfileLibrary.shared.save(profile) else {
            showBanner(.error, "Couldn't write \(journal.displayName) to your journal library.")
            return
        }
        touch(undoable: false) { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            m.journals[idx].profileID = profile.id
            m.journals[idx].templateName = profile.name
            m.journals[idx].templateChecksum = profile.checksum
            m.journals[idx].profileLineage = profile.lineage.isEmpty ? nil : profile.lineage
        }
        writeProfile(journalID: journalID)
        showBanner(.success, "Saved to the “\(profile.displayName)” template.")
    }

    /// Folds this cut's own sections into the journal's structure.
    ///
    /// The structure file is meant to say what a submission for this journal
    /// contains — and the truth about that is the cut you actually built, not
    /// a list typed in beforehand.  So saving to the library captures every
    /// **active** section (hidden ones are deliberately excluded: switching a
    /// section off is how you say it isn't part of this submission), keeping
    /// the note and kind of any entry that was already there.
    ///
    /// Sections the structure names but the cut doesn't have are kept: they
    /// are requirements this cut has yet to meet, which is exactly what a
    /// structure test is for.
    func captureStructureFromSections(journalID: UUID) {
        guard let structure = structureCapture(journalID: journalID) else { return }
        touch(undoable: false) { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            m.journals[idx].structure = structure
        }
    }

    /// The structure this cut WOULD save — computed, never written.
    ///
    /// Pure so the profile pane can compare it against the template on every
    /// render: a journal's structure is only as current as the last capture,
    /// and without this, editing a section's text or its export formatting
    /// left Save greyed out because the stored structure hadn't moved yet.
    /// The question "does this differ from the template" has to be asked of
    /// what a save would produce, not of what a previous save produced.
    func structureCapture(journalID: UUID) -> JournalStructure? {
        guard let content = latestVersion(forJournal: journalID)?.content ?? manuscript,
              let journal = manuscript?.journals.first(where: { $0.id == journalID })
        else { return nil }
        let existing = journal.structure?.sections ?? []
        let byTitle = Dictionary(existing.map { ($0.title.lowercased(), $0) },
                                 uniquingKeysWith: { first, _ in first })

        // No formats.  They were captured here once — the outline's typography
        // copied into each section and into `coreFormats` — which made a font
        // change read as a STRUCTURE change.  How a submission is set is the
        // Export part's question, compared on its own checksum.
        var captured: [StructureSection] = []
        // The letter is never captured: it is the author's, not the venue's.
        for section in content.sections.filter({ $0.active && $0.sectionKind != .letter })
            .sorted(by: { $0.order < $1.order }) {
            var entry = byTitle[section.title.lowercased()]
                ?? StructureSection(title: section.title)
            entry.title = section.title
            entry.kind = section.sectionKind
            // **Boilerplate is not captured.**  It is the venue's default
            // content, authored while editing the template — taking whatever a
            // cut happens to contain is how one author's draft became
            // everyone's starting point, and it made the text on screen
            // ambiguous: boilerplate to be replaced, or writing to be kept?
            // The existing entry's boilerplate is carried through untouched.
            switch section.sectionKind {
            case .text, .letter:
                entry.questions = nil
            case .questions:
                // The QUESTIONS are the venue's and do belong to the template;
                // the answers to them do not.
                let asked = section.orderedQuestions.filter { !$0.prompt.isEmpty }
                if !asked.isEmpty {
                    let previous = Dictionary(
                        (byTitle[section.title.lowercased()]?.questions ?? [])
                            .map { ($0.prompt.lowercased(), $0) },
                        uniquingKeysWith: { first, _ in first })
                    entry.questions = asked.map { q in
                        TemplateQuestion(prompt: q.prompt, wordLimit: q.wordLimit,
                                         limitUnit: q.limitUnit,
                                         sample: previous[q.prompt.lowercased()]?.sample)
                    }
                }
            }
            captured.append(entry)
        }
        // Anything the structure required that this cut doesn't have yet —
        // except a letter entry, which no template should carry.
        let capturedTitles = Set(captured.map { $0.title.lowercased() })
        captured += existing.filter { !capturedTitles.contains($0.title.lowercased()) && $0.kind != .letter }

        return JournalStructure(sections: captured,
                                coreFormats: journal.structure?.coreFormats,
                                documentFormat: journal.structure?.documentFormat)
    }

    /// Branches this journal's configuration into a NEW library profile
    /// instead of overwriting what's there.
    ///
    /// The new profile keeps a pointer to the one it came from, so the
    /// lineage survives being shared: a collaborator whose library holds the
    /// ancestor is told this is a MODIFIED version of what they have, and is
    /// offered the same two choices in turn.
    func branchProfileToLibrary(journalID: UUID, named name: String) {
        captureStructureFromSections(journalID: journalID)
        guard let journal = manuscript?.journals.first(where: { $0.id == journalID }) else { return }
        var profile = journal.profile
        // The new profile descends from the one it was branched off, plus
        // everything THAT one descended from — so a branch of a branch still
        // resolves for someone whose library only holds the root.
        let chain = [profile.id] + profile.lineage
        profile.id = UUID()
        profile.lineage = chain
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { profile.name = trimmed }
        guard JournalProfileLibrary.shared.save(profile) else {
            showBanner(.error, "Couldn't write \(profile.displayName) to your journal library.")
            return
        }
        touch(undoable: false) { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            m.journals[idx].profileID = profile.id
            m.journals[idx].profileLineage = profile.lineage
            // The new template takes the name given for it; the journal keeps
            // its own — they are different things.
            m.journals[idx].templateName = profile.name
            m.journals[idx].templateChecksum = profile.checksum
        }
        writeProfile(journalID: journalID)
        showBanner(.success, "“\(profile.displayName)” added to your templates.")
    }

    /// The library profile a journal descends from, for labelling.
    func libraryAncestor(for journal: Journal) -> JournalProfile? {
        guard let id = libraryStatus(for: journal).counterpartID else { return nil }
        return JournalProfileLibrary.shared.profile(id: id)
    }

    /// Replaces a journal's user-written check rules.
    func updateCheckRules(_ rules: [CheckRule], journalID: UUID) {
        touch(undoAction: "Edit Checks") { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            m.journals[idx].checkRules = rules.isEmpty ? nil : rules
            // Editing checks makes this manuscript the configuration's
            // owner, exactly like editing the source requirements.
            m.journals[idx].configOrigin = .manuscript
        }
        writeProfile(journalID: journalID)
    }

    /// Ticks/unticks one manual checklist rule for a journal (Checks pane).
    func toggleManualCheck(journalID: UUID, rule: String) {
        touch(undoAction: "Check Item") { m in
            guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
            var done = m.journals[idx].manualChecksDone ?? []
            if let i = done.firstIndex(of: rule) { done.remove(at: i) } else { done.append(rule) }
            m.journals[idx].manualChecksDone = done
        }
    }

    func deleteJournals(at offsets: IndexSet) {
        touch(undoAction: "Delete Journal") { $0.journals.remove(atOffsets: offsets) }
    }

    // MARK: - Export outlines

    /// The export outline for a journal (nil = Source): the stored, customized
    /// one, or the standard pre-configured outline derived from the content.
    func exportConfig(forJournal journalID: UUID?) -> ExportConfig {
        guard let m = manuscript else { return ExportConfig(documents: []) }
        var config: ExportConfig
        if let journalID {
            let journal = m.journals.first { $0.id == journalID }
            if let stored = journal?.exportConfig {
                config = stored
            } else {
                let content = latestVersion(forJournal: journalID)?.content ?? m
                config = .standard(content: content, journal: journal)
            }
        } else {
            config = m.sourceExportConfig ?? .standard(content: m, journal: nil)
        }
        // Every document leads with a pinned Section — the format anchor;
        // configs saved before sections existed gain one here.
        for i in config.documents.indices
            where !config.documents[i].items.isEmpty
                && config.documents[i].items.first?.kind != .pageBreak {
            config.documents[i].items.insert(ExportItem(kind: .pageBreak), at: 0)
        }
        // An outline from when the cover letter was its own kind of item:
        // that item now means "the manuscript's letter section" — the first
        // one — or nothing at all if there isn't one.
        let content = journalID.flatMap { latestVersion(forJournal: $0)?.content } ?? m
        let letterID = content.sections.sorted { $0.order < $1.order }
            .first { $0.sectionKind == .letter }?.id
        for d in config.documents.indices {
            config.documents[d].items = config.documents[d].items.compactMap { item in
                guard item.kind == .coverLetter else { return item }
                guard let letterID else { return nil }
                var section = item
                section.kind = .section
                section.sectionID = letterID
                section.showTitle = item.showTitle ?? false
                return section
            }
        }
        config.documents.removeAll { !$0.isAttachment && !$0.items.isEmpty
            && $0.items.allSatisfy { $0.kind == .pageBreak } }
        return config
    }

    /// Persists a (customized) export outline for a journal or the Source.
    /// The export-item identity a content pane maps to (nil = the pane has
    /// no exported counterpart).
    static func exportItemKey(for item: SidebarItem) -> (kind: ExportItem.Kind, sectionID: UUID?)? {
        switch item {
        case .title:           return (.titlePage, nil)
        case .authors:         return (.authors, nil)
        case .abstract:        return (.abstract, nil)
        case .keywords:        return (.keywords, nil)
        case .section(let id): return (.section, id)
        case .figures:         return (.figures, nil)
        case .tables:          return (.tables, nil)
        case .bibliography:    return (.references, nil)
        default:               return nil
        }
    }

    /// The journal behind a version ref (nil = Source).
    func journalID(for ref: VersionRef) -> UUID? {
        guard case .version(let id) = ref else { return nil }
        return versions.first { $0.id == id }?.journalID
    }

    /// The typography a content pane's export actually uses: its item's
    /// override over its document's format (spacing stays document-uniform).
    /// Phase 2: this is what the pane EDITS and the editor RENDERS.
    func effectiveExportFormat(for item: SidebarItem, ref: VersionRef) -> ExportDocumentFormat {
        let config = exportConfig(forJournal: journalID(for: ref))
        guard var key = Self.exportItemKey(for: item) else {
            return config.documents.first?.format ?? ExportDocumentFormat()
        }
        // Pre-split configs: the byline is part of the Title item.
        if key.kind == .authors,
           !config.documents.contains(where: { $0.items.contains { $0.kind == .authors } }) {
            key = (.titlePage, nil)
        }
        for document in config.documents {
            guard let found = document.items.first(where: {
                $0.kind == key.kind && $0.sectionID == key.sectionID
            }) else { continue }
            var format = document.format
            if let override = found.format {
                format.fontFamily = override.fontFamily
                format.fontSize = override.fontSize
                format.lineSpacing = override.lineSpacing
            }
            return format
        }
        return config.documents.first?.format ?? ExportDocumentFormat()
    }

    /// Mutates a content pane's export entry — its item, and/or the
    /// document carrying it — persisting the journal's config.  Used by
    /// the pane-header typography popover (Phase 2: page-level settings
    /// edit from the editors; Export mirrors read-only).
    func updateExportEntry(for item: SidebarItem, ref: VersionRef,
                           mutateItem: ((inout ExportItem) -> Void)? = nil,
                           mutateDocument: ((inout ExportDocument) -> Void)? = nil) {
        guard var key = Self.exportItemKey(for: item) else { return }
        let jid = journalID(for: ref)
        var config = exportConfig(forJournal: jid)
        // Pre-split configs carry the byline on the Title item (no .authors
        // item anywhere) — the Authors pane's settings write there.
        if key.kind == .authors,
           !config.documents.contains(where: { $0.items.contains { $0.kind == .authors } }) {
            key = (.titlePage, nil)
        }
        // EVERY copy of the component, not just the first.  An outline can
        // carry the same section more than once (across documents, or twice
        // in one), and stopping at the first match left the others behind —
        // the pane's gear then said "heading off" while the export still
        // printed one, because it was rendering the copy that never got the
        // change.
        var touched = false
        for d in config.documents.indices {
            let matches = config.documents[d].items.indices.filter {
                config.documents[d].items[$0].kind == key.kind
                    && config.documents[d].items[$0].sectionID == key.sectionID
            }
            guard !matches.isEmpty else { continue }
            if let mutateItem {
                for i in matches { mutateItem(&config.documents[d].items[i]) }
            }
            if let mutateDocument { mutateDocument(&config.documents[d]) }
            touched = true
        }
        guard touched else { return }
        updateExportConfig(config, forJournal: jid)
    }

    ///
    /// An outline that equals the standard one — what the pane shows when
    /// nothing is stored — is stored as **nothing**, so adding a document and
    /// deleting it again leaves the journal exactly as it was rather than
    /// holding a materialized copy of the same outline that reads as an edit.
    func updateExportConfig(_ config: ExportConfig, forJournal journalID: UUID?) {
        touch { m in
            if let journalID {
                guard let idx = m.journals.firstIndex(where: { $0.id == journalID }) else { return }
                let content = m.versions.filter { $0.journalID == journalID }
                    .max { $0.number < $1.number }?.content ?? m
                let baseline = ExportConfig.standard(content: content, journal: m.journals[idx])
                m.journals[idx].exportConfig =
                    ProfileFingerprint.of(config) == ProfileFingerprint.of(baseline) ? nil : config
            } else {
                let baseline = ExportConfig.standard(content: m, journal: nil)
                m.sourceExportConfig =
                    ProfileFingerprint.of(config) == ProfileFingerprint.of(baseline) ? nil : config
            }
        }
    }

    // MARK: - Versions (cuts)

    /// All versions, in creation order.
    var versions: [ManuscriptVersion] { manuscript?.versions ?? [] }

    /// One journal's version chain (nil = legacy custom cuts), oldest first —
    /// the "linear lineage" of that journal.  Source stamps are their own
    /// chain (see `sourceStamps`), never mixed in here.
    func versions(forJournal journalID: UUID?) -> [ManuscriptVersion] {
        versions
            .filter { $0.journalID == journalID && $0.sourceStamp != true }
            .sorted { $0.number < $1.number }
    }

    /// Source's own version chain, oldest first — Source maintains versions
    /// just like the journals; the live manuscript is its working "latest".
    var sourceStamps: [ManuscriptVersion] {
        versions.filter { $0.sourceStamp == true }.sorted { $0.number < $1.number }
    }

    var latestSourceStamp: ManuscriptVersion? { sourceStamps.last }

    /// The working head of a journal: its most recent version.
    func latestVersion(forJournal journalID: UUID?) -> ManuscriptVersion? {
        versions(forJournal: journalID).last
    }

    /// A version's ordinal within its own journal's chain ("v1, v2, …" in the
    /// per-journal views; distinct from the manuscript-global `number`).
    func journalOrdinal(of version: ManuscriptVersion) -> Int {
        (versions(forJournal: version.journalID).firstIndex { $0.id == version.id } ?? 0) + 1
    }

    /// When content last crossed this journal's upstream edge — the creation
    /// date of its newest head whose parent lives in another chain (the
    /// original cut counts).  nil = never synced.
    func lastSynced(journalID: UUID) -> Date? {
        for v in versions(forJournal: journalID).reversed() {
            guard let pid = v.parentID else { return v.createdAt }   // cut from live Source
            if let parent = versions.first(where: { $0.id == pid }),
               parent.journalID != journalID {
                return v.createdAt
            }
        }
        return nil
    }

    // MARK: - Stamping (freeze the working head as a version)

    /// Signs a freshly-cut version with the user's identity key.
    private func signed(_ version: ManuscriptVersion) -> ManuscriptVersion {
        var v = version
        if let key = SigningService.publicKeyBase64,
           let sig = SigningService.sign(SigningService.stampMessage(
               id: v.id, createdAt: v.createdAt, author: v.author)) {
            v.stampedByKey = key
            v.stampSignature = sig
            v.stampedByType = SigningService.effectiveIdentityType
            v.stampedBySource = SigningService.identitySource
        }
        return v
    }

    /// Canonical content checksum — volatile metadata (timestamps, sync
    /// marker, the version list itself) is zeroed first, so two states hash
    /// equal exactly when their real content is identical.
    func contentChecksum(_ m: Manuscript) -> String {
        var normalized = m
        normalized.updatedAt = .distantPast
        normalized.lastSyncedAt = nil
        normalized.versions = []
        // Data is global (shared by every journal) — the asset list isn't
        // per-version content, so it can't count as content drift.
        normalized.dataAssets = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(normalized) else { return m.id.uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when the journal's working head has edits since it was created —
    /// i.e. stamping now would actually freeze something new.  A timestamp
    /// touch alone doesn't count: the checksum must actually differ from the
    /// frozen predecessor's.
    func headHasUnstampedChanges(journalID: UUID) -> Bool {
        guard let head = latestVersion(forJournal: journalID) else { return false }
        guard head.content.updatedAt > head.createdAt.addingTimeInterval(1) else { return false }
        guard let pid = head.parentID,
              let parent = versions.first(where: { $0.id == pid }),
              parent.journalID == journalID else { return true }
        return contentChecksum(head.content) != contentChecksum(parent.content)
    }

    /// True when the live Source has edits since its latest stamp (or has
    /// never been stamped).  Checksum-confirmed like the journal check.
    var sourceHasUnstampedChanges: Bool {
        guard let m = manuscript else { return false }
        guard let stamp = latestSourceStamp else { return true }
        guard m.updatedAt > stamp.createdAt.addingTimeInterval(1) else { return false }
        return contentChecksum(m) != contentChecksum(stamp.content)
    }

    // MARK: - Sync prechecks (A → B)

    /// What comparing an edge's two ends found, checked before any sync runs.
    enum SyncPrecheck {
        /// A's latest content and B's latest content hash identically —
        /// there is nothing to pull.
        case alreadyInSync(upstreamName: String)
        /// A's latest content differs from A's last stamp — the sync must
        /// wait until A is stamped, so lineage always hangs from a frozen
        /// version.
        case upstreamNeedsStamp(upstreamName: String)
        case ready
    }

    /// Verifies an A→B sync edge by content checksums:
    /// checksum(A latest) == checksum(B latest) → `.alreadyInSync`;
    /// checksum(A latest) != checksum(A's last stamp) → `.upstreamNeedsStamp`;
    /// otherwise `.ready`.
    func syncPrecheck(forJournal journalID: UUID) -> SyncPrecheck {
        guard let m = manuscript,
              let head = latestVersion(forJournal: journalID),
              let source = syncSource(forJournal: journalID) else { return .ready }

        let upstreamLatest: Manuscript
        var upstreamStamp: Manuscript?
        if let upID = source.upstreamJournalID {
            guard let upHead = latestVersion(forJournal: upID) else { return .ready }
            upstreamLatest = upHead.content
            if let pid = upHead.parentID,
               let parent = versions.first(where: { $0.id == pid }),
               parent.journalID == upID {
                upstreamStamp = parent.content
            }
        } else {
            upstreamLatest = m
            upstreamStamp = latestSourceStamp?.content
        }

        let latestSum = contentChecksum(upstreamLatest)
        if latestSum == contentChecksum(head.content) {
            return .alreadyInSync(upstreamName: source.upstreamName)
        }
        guard let stamp = upstreamStamp, contentChecksum(stamp) == latestSum else {
            return .upstreamNeedsStamp(upstreamName: source.upstreamName)
        }
        return .ready
    }

    /// Stamps a journal: freezes the current head as-is and opens a new
    /// working head with identical content.  Returns the **frozen** version
    /// (the lineage-stable thing children can hang from).
    @discardableResult
    func stampVersion(journalID: UUID) -> ManuscriptVersion? {
        guard let m = manuscript,
              let head = latestVersion(forJournal: journalID) else { return nil }
        let next = signed(ManuscriptVersion.cut(
            label: "",
            from: head.content,
            parentID: head.id,
            journalID: journalID,
            viewConfigID: head.viewConfigID,
            number: (m.versions.map(\.number).max() ?? 0) + 1,
            author: SigningService.userName
        ))
        touch { $0.versions.append(next) }
        let name = m.journals.first { $0.id == journalID }?.name ?? "journal"
        log(.info, "Stamped \(name) v\(journalOrdinal(of: head))")
        NotificationCenter.default.post(
            name: .journalHeadChanged, object: nil,
            userInfo: ["old": head.id, "new": next.id])
        return head
    }

    /// Stamps the live Source as a new Source version.  Returns the stamp.
    @discardableResult
    func stampSource() -> ManuscriptVersion? {
        guard let m = manuscript else { return nil }
        var stamp = signed(ManuscriptVersion.cut(
            label: "",
            from: m,
            parentID: latestSourceStamp?.id,
            journalID: nil,
            viewConfigID: nil,
            number: (m.versions.map(\.number).max() ?? 0) + 1,
            author: SigningService.userName
        ))
        stamp.sourceStamp = true
        touch { $0.versions.append(stamp) }
        log(.info, "Stamped Source v\(sourceStamps.count)")
        return stamp
    }

    /// The frozen version a sync/cut should base on for an upstream —
    /// stamping the upstream first when it has unstamped changes.  Syncs are
    /// pre-gated by `syncPrecheck` (they refuse instead of auto-stamping), so
    /// the auto-stamp here effectively serves cut-creation.  nil = Source.
    func syncBase(forUpstream journalID: UUID?) -> ManuscriptVersion? {
        if let journalID {
            if headHasUnstampedChanges(journalID: journalID) {
                return stampVersion(journalID: journalID)          // freezes old head
            }
            guard let head = latestVersion(forJournal: journalID) else { return nil }
            // The head is an unedited copy of its predecessor stamp; prefer
            // the frozen predecessor, falling back to the head for a
            // never-stamped journal.
            if let pid = head.parentID,
               let parent = versions.first(where: { $0.id == pid }),
               parent.journalID == journalID {
                return parent
            }
            return head
        } else {
            if sourceHasUnstampedChanges { return stampSource() }
            return latestSourceStamp
        }
    }

    // MARK: - Rollback

    /// Rolls a journal back to `version`: later versions in the same journal
    /// are deleted (changes in between are dropped).  Refused with a message
    /// when a dropped version has cuts hanging from it in another journal.
    /// For a Source stamp, restores the live content from the stamp and
    /// drops later stamps.
    @discardableResult
    func rollback(to version: ManuscriptVersion) -> String? {
        if version.sourceStamp == true {
            let dropped = sourceStamps.filter { $0.number > version.number }
            if let blocked = crossJournalChild(of: dropped.map(\.id)) { return blocked }
            touch { m in
                let content = version.content
                m.title = content.title
                m.runningTitle = content.runningTitle
                m.keywords = content.keywords
                m.authors = content.authors
                m.abstract = content.abstract
                m.sections = content.sections
                m.figures = content.figures
                m.tables = content.tables
                m.bibliography = content.bibliography
                m.versions.removeAll { v in dropped.contains { $0.id == v.id } }
            }
            log(.info, "Rolled Source back to v\(sourceOrdinal(of: version))")
            return nil
        }
        guard let journalID = version.journalID else { return "Only journal versions can be rolled back." }
        let chain = versions(forJournal: journalID)
        let dropped = chain.filter { $0.number > version.number }
        guard !dropped.isEmpty else { return nil }
        if let blocked = crossJournalChild(of: dropped.map(\.id)) { return blocked }
        let oldHead = chain.last
        touch { m in
            m.versions.removeAll { v in dropped.contains { $0.id == v.id } }
        }
        if let oldHead {
            NotificationCenter.default.post(
                name: .journalHeadChanged, object: nil,
                userInfo: ["old": oldHead.id, "new": version.id])
        }
        let name = manuscript?.journals.first { $0.id == journalID }?.name ?? "journal"
        log(.info, "Rolled \(name) back to v\(journalOrdinal(of: version))")
        return nil
    }

    /// A human-readable blocker when any of `ids` has a child in another
    /// journal (rolling those away would orphan that journal's lineage).
    private func crossJournalChild(of ids: [UUID]) -> String? {
        let idSet = Set(ids)
        for v in versions where v.parentID.map(idSet.contains) == true {
            let name = v.journalID.flatMap { jid in
                manuscript?.journals.first { $0.id == jid }?.name
            } ?? "another journal"
            return "Can't roll back past a version that \(name) was cut from — roll back or remove that journal's versions first."
        }
        return nil
    }

    // MARK: - Sync (fast-forward one lineage edge)

    /// Where a sync of `journalID` would pull from: the latest version of the
    /// upstream journal its head derives from (or the live Source).  Walks up
    /// past same-journal ancestors — a head cut from its own earlier version
    /// must still sync from the journal it was originally derived from, never
    /// from itself.  Returns nil when the journal has no versions to sync.
    func syncSource(forJournal journalID: UUID)
        -> (upstreamJournalID: UUID?, upstreamName: String, targetVersion: ManuscriptVersion?)? {
        guard let head = latestVersion(forJournal: journalID) else { return nil }

        var cursor: ManuscriptVersion? = head
        while let current = cursor, let pid = current.parentID {
            guard let parent = versions.first(where: { $0.id == pid }) else { break }
            if parent.sourceStamp == true {
                // Hangs from a stamped Source version.
                return (nil, "Source", latestSourceStamp)
            }
            if parent.journalID != journalID {
                // First cross-journal edge: this is the upstream.
                let upstreamName: String
                if let jid = parent.journalID,
                   let journal = manuscript?.journals.first(where: { $0.id == jid }) {
                    upstreamName = journal.name
                } else {
                    upstreamName = parent.journalID == nil
                        ? (parent.label.isEmpty ? "Custom" : parent.label)
                        : "Upstream"
                }
                // Fast-forward to the newest version of the upstream journal.
                let target = latestVersion(forJournal: parent.journalID) ?? parent
                return (parent.journalID, upstreamName, target)
            }
            cursor = parent
        }
        // Chain roots at the Source (legacy edges have no stamp to point at).
        return (nil, "Source", latestSourceStamp)
    }

    /// A Source stamp's ordinal within the Source chain ("Source v2").
    func sourceOrdinal(of stamp: ManuscriptVersion) -> Int {
        (sourceStamps.firstIndex { $0.id == stamp.id } ?? 0) + 1
    }

    /// How incoming content meets what is already there.
    enum SyncMode: String, Sendable {
        /// The incoming version replaces the target's content (the original
        /// behaviour, and still the default).
        case overwrite
        /// The target keeps what it has and the incoming content is added
        /// after it — for a cut you have already worked on and don't want
        /// replaced wholesale.
        case append
    }

    /// Fast-forwards one journal from its upstream: **stamps the upstream
    /// first when it has unstamped changes** (keeping lineage anchored to
    /// frozen versions), then snapshots that stamp as a new version of this
    /// journal.  Never recursive.
    @discardableResult
    func syncJournal(_ journalID: UUID,
                     adaptation: FastForwardIntent.Adaptation? = nil,
                     assistedBy model: String? = nil,
                     mode: SyncMode = .overwrite) -> ManuscriptVersion? {
        guard let head = latestVersion(forJournal: journalID),
              let source = syncSource(forJournal: journalID) else { return nil }

        // May stamp the upstream (mutating the manuscript) — resolve before
        // snapshotting content.
        let base = syncBase(forUpstream: source.upstreamJournalID)
        guard let m = manuscript else { return nil }

        // The upstream's text where it has some, this journal's own where it
        // hasn't — then the adaptation, which is the last word.  (The
        // template's content was re-applied AFTER the adaptation here once,
        // and quietly replaced every rewritten section with its boilerplate
        // while the banner reported the rewrite.)
        var baseContent = migrated(base?.content ?? m, into: head.content)
        if let adaptation { applyAdaptation(adaptation, to: &baseContent) }
        if mode == .append, let head = latestVersion(forJournal: journalID)?.content {
            appendIncoming(into: &baseContent, keeping: head)
        }
        let fromLabel: String
        if let base {
            fromLabel = base.sourceStamp == true
                ? "Source v\(sourceOrdinal(of: base))"
                : "\(source.upstreamName) v\(journalOrdinal(of: base))"
        } else {
            fromLabel = "Source"
        }

        let number = (m.versions.map(\.number).max() ?? 0) + 1
        // The label names the model when one was involved: a rollback target
        // is only useful if you can tell at a glance which versions were
        // written by hand and which were adapted.
        let version = signed(ManuscriptVersion.cut(
            label: model.map { "Adapted from \(fromLabel) by \($0)" } ?? "Synced from \(fromLabel)",
            from: baseContent,
            parentID: base?.id,
            journalID: journalID,
            viewConfigID: head.viewConfigID,
            number: number,
            author: SigningService.userName
        ))
        touch { $0.versions.append(version) }
        // The synced version is the journal's new working head — open tabs
        // showing the old head must follow it or the sync looks like a no-op.
        NotificationCenter.default.post(
            name: .journalHeadChanged, object: nil,
            userInfo: ["old": head.id, "new": version.id])
        log(.info, model.map { "Adapted \(journalName(journalID) ?? "journal") from \(fromLabel) with \($0)" }
                   ?? "Fast-forwarded \(journalName(journalID) ?? "journal") from \(fromLabel)")
        return version
    }

    /// Fast-backward: overrides the upstream with this journal's latest
    /// content — a full override by design (Aug 2026 sync redesign).  A
    /// journal upstream gets a new head version; the live Source is stamped
    /// first (so the overridden state stays in its history), then the
    /// content is transplanted into the live manuscript (undoable).
    @discardableResult
    func pushToUpstream(_ journalID: UUID,
                        adaptation: FastForwardIntent.Adaptation? = nil,
                        assistedBy model: String? = nil,
                        mode: SyncMode = .overwrite) -> Bool {
        guard let source = syncSource(forJournal: journalID) else { return false }
        // Freeze this journal so lineage hangs from a stamp.
        let base = syncBase(forUpstream: journalID)
        guard var content = base?.content ?? latestVersion(forJournal: journalID)?.content
        else { return false }
        if let adaptation { applyAdaptation(adaptation, to: &content) }
        if mode == .append,
           let upstreamID = source.upstreamJournalID,
           let head = latestVersion(forJournal: upstreamID)?.content {
            appendIncoming(into: &content, keeping: head)
        } else if mode == .append, source.upstreamJournalID == nil, let live = manuscript {
            appendIncoming(into: &content, keeping: live)
        }

        if let upstreamID = source.upstreamJournalID {
            guard let upstreamHead = latestVersion(forJournal: upstreamID) else { return false }
            let pushLabel = "Pushed back from \(journalName(journalID) ?? "journal")"
            let next = signed(ManuscriptVersion.cut(
                label: model.map { "\(pushLabel), adapted by \($0)" } ?? pushLabel,
                from: content,
                parentID: base?.id,
                journalID: upstreamID,
                viewConfigID: upstreamHead.viewConfigID,
                number: (manuscript?.versions.map(\.number).max() ?? 0) + 1,
                author: SigningService.userName))
            touch { $0.versions.append(next) }
            NotificationCenter.default.post(
                name: .journalHeadChanged, object: nil,
                userInfo: ["old": upstreamHead.id, "new": next.id])
        } else {
            // Upstream is the live Source: stamp it, then transplant (the
            // same field set rollback restores).
            _ = stampSource()
            touch(undoAction: "Fast-Backward to Source") { m in
                m.title = content.title
                m.runningTitle = content.runningTitle
                m.keywords = content.keywords
                m.authors = content.authors
                m.abstract = content.abstract
                m.sections = content.sections
                m.figures = content.figures
                m.tables = content.tables
                m.bibliography = content.bibliography
            }
        }
        log(.info, "Fast-backward: \(source.upstreamName) overridden with \(journalName(journalID) ?? "journal")'s latest")
        return true
    }

    /// Keeps what the target already had and puts the incoming content after
    /// it, section by section.
    ///
    /// The third option in every sync: a cut you have worked on shouldn't have
    /// to be replaced wholesale to take an upstream revision.  Identical text
    /// is not appended to itself.
    private func appendIncoming(into incoming: inout Manuscript, keeping existing: Manuscript) {
        let byTitle = Dictionary(existing.sections.map { ($0.title.lowercased(), $0) },
                                 uniquingKeysWith: { first, _ in first })
        for i in incoming.sections.indices {
            guard let mine = byTitle[incoming.sections[i].title.lowercased()] else { continue }
            switch incoming.sections[i].sectionKind {
            case .text, .letter:
                let kept = mine.content.plain
                let arriving = incoming.sections[i].content.plain
                guard !kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !kept.contains(arriving), !arriving.contains(kept) else { continue }
                // Joined as rich text: a plain join dropped every citation.
                incoming.sections[i].content = RefEngine.joined(mine.content, incoming.sections[i].content)
            case .questions:
                // Answers are per question: keep the one already written when
                // the arriving copy has nothing to say.
                guard let mineQ = mine.questions else { continue }
                let byPrompt = Dictionary(mineQ.map { ($0.prompt.lowercased(), $0) },
                                          uniquingKeysWith: { first, _ in first })
                for q in (incoming.sections[i].questions ?? []).indices {
                    let prompt = incoming.sections[i].questions![q].prompt.lowercased()
                    guard let kept = byPrompt[prompt], !kept.response.isEmpty else { continue }
                    let arriving = incoming.sections[i].questions![q].response.plain
                    if arriving.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        incoming.sections[i].questions![q].response = kept.response
                    } else if !kept.response.plain.contains(arriving) {
                        incoming.sections[i].questions![q].response =
                            RefEngine.joined(kept.response, incoming.sections[i].questions![q].response)
                    }
                }
            }
        }
    }

    /// The upstream's content as a fast-forward brings it down: its text
    /// where it has some, and this journal's own where it has none.
    ///
    /// A section the upstream leaves empty — the venue's title page, its
    /// submission questions, a letter — has nothing to migrate, so the cut
    /// keeps what it has there: the boilerplate it was created with, or what
    /// was written here.  Emptiness is not content.  Everything else is the
    /// full override it always was.
    private func migrated(_ upstream: Manuscript, into head: Manuscript) -> Manuscript {
        var out = upstream
        if upstream.abstract.isEmpty { out.abstract = head.abstract }
        let byID = Dictionary(head.sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byTitle = Dictionary(head.sections.map { ($0.title.lowercased(), $0) },
                                 uniquingKeysWith: { first, _ in first })
        for i in out.sections.indices where out.sections[i].isEmptyContent {
            let theirs = out.sections[i]
            guard let mine = byID[theirs.id] ?? byTitle[theirs.title.lowercased()] else { continue }
            var kept = mine
            kept.id = theirs.id
            kept.title = theirs.title
            kept.order = theirs.order
            out.sections[i] = kept
        }
        return out
    }

    /// Writes an adaptation into a manuscript snapshot.
    ///
    /// Rich text, not plain: a citation lives in the RTF's link attribute, so
    /// writing `RichText(plain:)` over a section silently destroyed every
    /// reference in it.  `AIRefMarkers` has already rebuilt those links.
    private func applyAdaptation(_ adaptation: FastForwardIntent.Adaptation,
                                 to content: inout Manuscript) {
        if let rich = adaptation.sections[FastForwardIntent.abstractID] {
            content.abstract = rich
        }
        for i in content.sections.indices {
            let id = content.sections[i].id
            if let rich = adaptation.sections[id] {
                content.sections[i].content = rich
            }
            if let answers = adaptation.answers[id] {
                for q in (content.sections[i].questions ?? []).indices {
                    let questionID = content.sections[i].questions![q].id
                    if let rich = answers[questionID] {
                        content.sections[i].questions![q].response = rich
                    }
                }
            }
        }
    }

    private func journalName(_ id: UUID) -> String? {
        manuscript?.journals.first { $0.id == id }?.name
    }

    // MARK: - AI assist
    //
    // Every request the app makes goes through here: it resolves where the
    // prompt is going, honours the context checkboxes, and writes the prompt
    // log whether the run succeeded or failed.  An intent that skips this
    // would be a request nobody can audit afterwards.

    /// Requests in flight, keyed by the journal whose button started them,
    /// with the moment each began.
    ///
    /// Per-journal rather than one global flag: a fast-forward can take
    /// minutes, and a spinner on every row says the whole card is working when
    /// only one journal is.  The start time is here because the row needs to
    /// show how long it has been going — a request with no elapsed counter is
    /// indistinguishable from a hung one.
    private(set) var assistRuns: [UUID: AssistRun] = [:]

    /// A request in flight on one journal.
    struct AssistRun: Equatable {
        let startedAt: Date
        /// What the tool is doing right now — thinking, or writing.  Absent
        /// for destinations that don't report it (the keyed HTTP APIs).
        var progress: AIRunProgress?
    }

    /// True while any request is in flight — the ✦ toggle pulses on this.
    var isAssistBusy: Bool { !assistRuns.isEmpty }

    func isAssisting(_ journalID: UUID) -> Bool { assistRuns[journalID] != nil }

    /// This journal's request, for the elapsed counter and the phase line.
    func assistRun(_ journalID: UUID) -> AssistRun? { assistRuns[journalID] }

    /// This manuscript's prompt log, newest first.  Reloaded when a
    /// manuscript opens; appended to in memory as requests complete, so the
    /// popup never has to re-read the folder.
    var promptLog: [AIPromptLogEntry] = []

    /// "✦ Assist" — whether AI affordances are live for this manuscript.
    var isAssistEnabled: Bool { manuscript?.settings.aiAssistEnabled == true }

    func setAssistEnabled(_ enabled: Bool) {
        touch(undoAction: nil, undoable: false) { $0.settings.aiAssistEnabled = enabled }
    }

    func loadPromptLog() {
        promptLog = []
        guard let id = manuscript?.id else { return }
        promptLog = AIPromptLogService(persistence: persistence).entries(for: id)
    }

    /// Where this manuscript's requests go, or nil if it has no model chosen.
    ///
    /// A connector is only offered once it has tested successfully — an
    /// untested tool means a request that hangs on a sign-in prompt nobody
    /// can see.
    func aiDestination(appStore: AppStore) -> AIDestination? {
        guard let settings = manuscript?.settings else { return nil }
        if let id = settings.activeConnectorID,
           var connector = appStore.connectors.first(where: { $0.id == id }) {
            if let model = settings.aiModel, !model.isEmpty { connector.selectedModel = model }
            return .connector(connector)
        }
        if let id = settings.activeAIServiceID,
           let account = appStore.aiServices.first(where: { $0.id == id }) {
            let key = KeychainService.secret(for: account.id)
            if account.provider.requiresAPIKey, (key ?? "").isEmpty { return nil }
            return .service(account, apiKey: key)
        }
        return nil
    }

    /// Whether the assist toggle can do anything: a model is selected and
    /// reachable.
    ///
    /// **Deliberately does not touch the Keychain.**  This is read on every
    /// render of the ✦ toggle, and `aiDestination` reads the stored API key —
    /// so asking it here meant a Keychain read on every SwiftUI update pass,
    /// which is exactly the kind of thing that turns into a permission prompt
    /// storm.  `hasKey` already records whether a key was stored, which is all
    /// the toggle needs to know; the key itself is read once, when a request
    /// is actually sent.
    func canAssist(appStore: AppStore) -> Bool {
        guard let settings = manuscript?.settings else { return false }
        if let id = settings.activeConnectorID,
           appStore.connectors.contains(where: { $0.id == id }) {
            return true
        }
        if let id = settings.activeAIServiceID,
           let account = appStore.aiServices.first(where: { $0.id == id }) {
            return !account.provider.requiresAPIKey || account.hasKey
        }
        return false
    }

    // AI INTENT  journal.fastForward — see Services/AI/Intents/FastForwardIntent.swift
    //
    /// A fast-forward that adapts on the way down.
    ///
    /// The mechanical override is unchanged and still does the writing: the
    /// model only supplies replacement section text, which `syncJournal` /
    /// `pushToUpstream` apply through the same path a plain copy uses — so
    /// the overridden side is stamped into version history first, exactly as
    /// it would have been.  A failed or unreadable reply changes nothing.
    func assistFastForward(journalID: UUID, forward: Bool, appStore: AppStore,
                           mode: SyncMode = .overwrite) async {
        guard let m = manuscript, let source = syncSource(forJournal: journalID) else { return }
        guard let destination = aiDestination(appStore: appStore) else {
            showBanner(.error, "Assist needs a model — pick one in Overview → Settings → AI.")
            return
        }

        let journal = m.journals.first { $0.id == journalID }
        // Forward pulls the upstream's content down into this journal, so the
        // TARGET is this journal; backward pushes up, so the target is the
        // upstream.  The target's profile is what the adaptation aims at.
        //
        // The whole snapshot travels, not just its sections: the checks are
        // evaluated against it (abstract, figures, tables and references all
        // count toward limits), and that evaluation is what makes the limits
        // actionable in the prompt.
        let baseContent: Manuscript
        let target: Journal?
        if forward {
            // The same merge the plain copy makes, so the model adapts a
            // title page that reads as the venue's boilerplate — tokens and
            // all — rather than an empty section it has to invent.
            let upstream = syncBase(forUpstream: source.upstreamJournalID)?.content ?? m
            baseContent = latestVersion(forJournal: journalID)
                .map { migrated(upstream, into: $0.content) } ?? upstream
            target = journal
        } else {
            baseContent = latestVersion(forJournal: journalID)?.content ?? m
            target = source.upstreamJournalID.flatMap { id in m.journals.first { $0.id == id } }
        }
        guard let target else {
            showBanner(.error, "Assist can only adapt toward a journal — Source has no requirements to aim at.")
            return
        }

        let started = Date()
        // The section text goes in the intent's own payload below, so the
        // context sends the manuscript's shape without repeating its body.
        let bundle = aiContextBundle(includeSectionText: false)
        let summary = "\(forward ? "Fast-forward" : "Fast-backward") \(target.name) from \(forward ? source.upstreamName : (journal?.name ?? "journal"))"

        // The log entry's id is handed to the CLI as its session id, so the
        // tool's own transcript for this run lands at a path the app can find
        // later — including when the run fails.
        let entryID = UUID()
        assistRuns[journalID] = AssistRun(startedAt: started)
        defer { assistRuns[journalID] = nil }

        var prompt = ""
        do {
            let sent = FastForwardIntent.payloads(for: baseContent, target: target)
            prompt = AIRequestService.prompt(
                context: bundle,
                task: try FastForwardIntent.task(content: baseContent, target: target))

            let result = try await AIRequestService.send(
                prompt: prompt, to: destination, sessionID: entryID,
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.assistRuns[journalID]?.progress = progress }
                })
            let adaptation = try FastForwardIntent.adaptation(
                from: result.text, sent: sent,
                context: RefEngine.context(for: baseContent))

            // Measured before the write, while the old text is still in hand.
            let changes = sent.compactMap { payload -> AIPromptLogChange? in
                let after: String
                if let rich = adaptation.sections[payload.section.id] {
                    after = rich.plain
                } else if let answers = adaptation.answers[payload.section.id] {
                    after = payload.questions
                        .compactMap { answers[$0.question.id]?.plain }
                        .joined(separator: "\n\n")
                } else {
                    return nil
                }
                return AIPromptLogChange.measure(title: payload.section.title,
                                                 before: payload.section.plainText, after: after)
            }

            // Assisted or not, the write is the same mechanical override —
            // which is what guarantees the previous content is stamped into
            // version history first and the change can be rolled back.
            let applied = forward
                ? syncJournal(journalID, adaptation: adaptation,
                              assistedBy: result.model, mode: mode) != nil
                : pushToUpstream(journalID, adaptation: adaptation,
                                 assistedBy: result.model, mode: mode)

            record(AIPromptLogEntry(
                id: entryID,
                intentID: FastForwardIntent.descriptor.id,
                summary: summary,
                connectorLabel: destination.label,
                model: result.model,
                startedAt: started,
                duration: result.duration,
                outcome: applied ? .applied : .noChange,
                detail: assistDetail(applied: applied, result: result,
                                     adaptation: adaptation, target: target, journalID: journalID),
                contextTitles: bundle.pieces.map(\.title),
                excludedContextTitles: bundle.excludedTitles,
                promptCharacters: prompt.count,
                responseCharacters: result.text.count,
                changes: changes,
                sessionID: result.sessionID),
                prompt: prompt, response: result.text)

            if applied {
                let failures = failingChecks(forJournal: journalID, target: target)
                var message = "\(summary) — \(changes.count) section\(changes.count == 1 ? "" : "s") adapted by \(result.model). Stamped as a new version; the previous content is in Versions."
                if !adaptation.refused.isEmpty {
                    message += " \(adaptation.refused.count) section\(adaptation.refused.count == 1 ? "" : "s") kept unchanged because the reply dropped a citation or field: \(adaptation.refused.joined(separator: ", "))."
                }
                if !failures.isEmpty {
                    message += " \(failures.count) check\(failures.count == 1 ? "" : "s") still failing."
                }
                showBanner(failures.isEmpty && adaptation.refused.isEmpty ? .success : .error, message)
            } else {
                showBanner(.error, "\(summary) failed: the override didn't run.")
            }
        } catch {
            record(AIPromptLogEntry(
                id: entryID,
                intentID: FastForwardIntent.descriptor.id,
                summary: summary,
                connectorLabel: destination.label,
                model: destination.requestedModel,
                startedAt: started,
                duration: Date().timeIntervalSince(started),
                outcome: .failed,
                detail: error.localizedDescription,
                contextTitles: bundle.pieces.map(\.title),
                excludedContextTitles: bundle.excludedTitles,
                promptCharacters: prompt.count,
                sessionID: entryID.uuidString.lowercased()),
                prompt: prompt, response: "")
            showBanner(.error, "Assist failed: \(error.localizedDescription)")
        }
    }

    /// The checks the target still fails after an assisted write.
    ///
    /// The point of sending the checks with their numbers is that the result
    /// can be graded the same way — so the log says whether the adaptation
    /// actually met the journal's rules rather than only that it ran.
    private func failingChecks(forJournal journalID: UUID, target: Journal) -> [ChecklistResult] {
        guard let content = latestVersion(forJournal: journalID)?.content ?? manuscript
        else { return [] }
        return ChecklistService.run(manuscript: content, journal: target)
            .filter { !$0.manual && !$0.passed }
    }

    /// What the log entry says beyond "applied": a substituted model, tokens
    /// the reply dropped, and any check the result still fails.
    private func assistDetail(applied: Bool,
                              result: AISendResult,
                              adaptation: FastForwardIntent.Adaptation,
                              target: Journal,
                              journalID: UUID) -> String? {
        var parts: [String] = []
        if result.modelWasSubstituted {
            parts.append("\(result.model) answered, not the model selected.")
        }
        if !applied {
            parts.append("The override didn't run — nothing was written.")
            return parts.joined(separator: " ")
        }
        for (section, tokens) in adaptation.missingTokens.sorted(by: { $0.key < $1.key }) {
            parts.append("\(section): kept unchanged — the reply dropped \(tokens.joined(separator: ", ")).")
        }
        let failures = failingChecks(forJournal: journalID, target: target)
        if failures.isEmpty {
            parts.append("Every automatic check passes.")
        } else {
            parts.append("Still failing: "
                + failures.map { "\($0.rule) (\($0.details))" }.joined(separator: "; ") + ".")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Writes one entry to disk and to the in-memory log.
    ///
    /// A log that couldn't be written is reported: the alternative is a
    /// request that ran with no record, which is the one outcome this whole
    /// mechanism exists to prevent.
    private func record(_ entry: AIPromptLogEntry, prompt: String, response: String) {
        promptLog.insert(entry, at: 0)
        guard let id = manuscript?.id else { return }
        if !AIPromptLogService(persistence: persistence)
            .append(entry, prompt: prompt, response: response, to: id) {
            showBanner(.error, "Couldn't write the prompt log — this request isn't recorded on disk.")
        }
    }

    /// Adds a journal to the manuscript from a library/template entry, cut
    /// from `fromJournalID` (nil = Source) — stamping the upstream first when
    /// needed so the new lineage edge hangs from a frozen version.  Creates
    /// the journal's v1 ("Created") and returns the new journal.
    @discardableResult
    func addJournalCut(template: Journal, fromJournalID: UUID?, viewConfigID: UUID?) -> Journal? {
        guard manuscript != nil else { return nil }
        var journal = template
        journal.id = UUID()
        journal.createdAt = Date()
        journal.viewConfigID = viewConfigID
        journal.submissionURL = template.submissionURL
        touch { $0.journals.append(journal) }
        // The profile first, so the cut below is shaped by it: the sections
        // its structure names exist (empty, everywhere) before anything is
        // snapshotted, and its Checks pane is populated the moment its tab
        // opens.
        seedProfileIfNeeded(journalID: journal.id)
        addMissingStructureSections(journalID: journal.id)

        let base = syncBase(forUpstream: fromJournalID)
        guard let m = manuscript,
              let shaped = m.journals.first(where: { $0.id == journal.id }) else { return journal }
        // The shape and the venue's boilerplate — none of the upstream's
        // text.  That arrives on the first fast-forward, section by matching
        // section, which is the moment the user asks for it.
        let content = templatedContent(base?.content ?? m, journal: shaped)
        let v = signed(ManuscriptVersion.cut(
            label: "Created",
            from: content,
            parentID: base?.id,
            journalID: journal.id,
            viewConfigID: viewConfigID,
            number: (m.versions.map(\.number).max() ?? 0) + 1,
            author: SigningService.userName
        ))
        touch { $0.versions.append(v) }
        return manuscript?.journals.first { $0.id == journal.id } ?? journal
    }

    /// The manuscript content backing a comparison reference: the live Source,
    /// or a version's snapshot content.
    func manuscript(for ref: VersionRef) -> Manuscript? {
        switch ref {
        case .source:          return manuscript
        case .version(let id): return versions.first { $0.id == id }?.content
        }
    }

    /// User-facing label for a comparison reference.
    func label(for ref: VersionRef) -> String {
        switch ref {
        case .source:          return "Source"
        case .version(let id): return versions.first { $0.id == id }?.label ?? "Version"
        }
    }

    /// Creates a new version cut from `parentID` (nil = cut from Source).
    ///
    /// The new version's content is a snapshot of the parent's content — the
    /// Source manuscript itself when `parentID` is nil.  Phase 2 will run an
    /// LLM over this snapshot to adapt it to the target requirements.
    @discardableResult
    func addVersion(
        label: String,
        parentID: UUID?,
        journalID: UUID?,
        viewConfigID: UUID?
    ) -> ManuscriptVersion? {
        guard let m = manuscript else { return nil }

        // Content to snapshot: the parent version's content, or Source.
        let baseContent: Manuscript
        if let parentID, let parent = m.versions.first(where: { $0.id == parentID }) {
            baseContent = parent.content
        } else {
            baseContent = m
        }

        let number = (m.versions.map(\.number).max() ?? 0) + 1
        let version = signed(ManuscriptVersion.cut(
            label: label,
            from: baseContent,
            parentID: parentID,
            journalID: journalID,
            viewConfigID: viewConfigID,
            number: number,
            author: SigningService.userName
        ))
        touch { $0.versions.append(version) }
        return version
    }

    func updateVersion(_ version: ManuscriptVersion) {
        guard let idx = manuscript?.versions.firstIndex(where: { $0.id == version.id }) else { return }
        touch { $0.versions[idx] = version }
    }

    /// Deletes a version. Refused unless the version is a leaf (no children),
    /// so the lineage tree never develops holes.
    /// Returns `true` when the deletion happened.
    @discardableResult
    func deleteVersion(id: UUID) -> Bool {
        guard isLeafVersion(id) else { return false }
        touch(undoAction: "Delete Version") { $0.versions.removeAll { $0.id == id } }
        return true
    }

    /// Direct children of a version (or of Source when `id` is nil).
    func childVersions(of id: UUID?) -> [ManuscriptVersion] {
        versions.filter { $0.parentID == id }
    }

    /// True when no other version was cut from this one.
    func isLeafVersion(_ id: UUID) -> Bool {
        !versions.contains { $0.parentID == id }
    }

    /// The chain of ancestors from Source down to (and including) the version.
    /// e.g. [Nature cut, Science cut] for a Science cut branched off Nature.
    func lineagePath(to id: UUID) -> [ManuscriptVersion] {
        var path: [ManuscriptVersion] = []
        var currentID: UUID? = id
        // Walk parent pointers upward; versions.count bounds the loop against cycles.
        while let cid = currentID,
              let version = versions.first(where: { $0.id == cid }),
              path.count <= versions.count {
            path.append(version)
            currentID = version.parentID
        }
        return path.reversed()
    }

    /// Depth in the lineage tree: 0 for versions cut directly from Source.
    func versionDepth(_ id: UUID) -> Int {
        max(0, lineagePath(to: id).count - 1)
    }

    // MARK: - Remote (backend save-and-share — Phase II)
    //
    // "Save to remote" pushes the manuscript folder (manuscript.json, figures/,
    // data/) to the manuscript's active backend as one commit; "Load from
    // remote" pulls those files back and replaces the local content.  GitHub is
    // the first supported provider; the token lives in the Keychain.

    /// Transient success line ("Pushed to owner/repo@main (ab12cd3)").
    var remoteStatus: String?
    /// Last remote failure (also bannered).
    var remoteError: String?
    /// True while a push/pull is in flight (disables re-entry).
    var isRemoteBusy = false

    // MARK: - Toolbar banner (global transient notifications)
    //
    // One reusable notification slot rendered centered in the window
    // toolbar — sync results, save confirmations, and whatever comes next.

    enum BannerKind { case success, error }

    /// The banner currently showing, or nil.  Auto-dismisses.
    var banner: (kind: BannerKind, message: String)?
    private var bannerTask: Task<Void, Never>?

    // MARK: - Activity log (Log pane)

    /// Newest-first user-visible events; persisted to log.json beside
    /// manuscript.json.  Autosaves are deliberately never logged.
    var activityLog: [LogEntry] = []

    func log(_ kind: LogEntry.Kind, _ message: String, detail: String? = nil,
             context: String? = nil) {
        activityLog.insert(LogEntry(kind: kind, message: message, detail: detail,
                                    author: SigningService.userName, context: context), at: 0)
        if activityLog.count > 500 { activityLog.removeLast(activityLog.count - 500) }
        persistLog()
    }

    func clearLog() {
        activityLog = []
        persistLog()
    }

    private func logURL(for id: UUID) -> URL {
        persistence.manuscriptDirectory(for: id).appendingPathComponent("log.json")
    }

    private func persistLog() {
        guard let id = manuscript?.id else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(activityLog).write(to: logURL(for: id), options: .atomic)
    }

    /// "Source" or the journal owning `ref`'s version.
    private func refName(_ ref: VersionRef) -> String {
        if case .version(let id) = ref,
           let jid = manuscript?.versions.first(where: { $0.id == id })?.journalID,
           let name = manuscript?.journals.first(where: { $0.id == jid })?.name {
            return name
        }
        return "Source"
    }

    /// Content-change entries coalesce per (action, ref) so a typing burst
    /// reads as one "Edited Introduction" line, not hundreds.
    @ObservationIgnored private var lastActivity: (key: String, at: Date)?

    func logActivity(_ action: String, ref: VersionRef) {
        let key = action + refName(ref)
        if let last = lastActivity, last.key == key,
           Date().timeIntervalSince(last.at) < 300 {
            lastActivity = (key, Date())
            return
        }
        lastActivity = (key, Date())
        log(.info, action, context: refName(ref))
    }

    // MARK: - Changelog commit anchor

    /// Commits on the remote branch; the changelog compares against one of
    /// these (latest by default) — the repo, not local state, is the anchor.
    var remoteCommits: [GitHubBackendService.Commit] = []
    var changelogBaseSHA: String?
    var changelogBaseManuscript: Manuscript?
    @ObservationIgnored private var changelogBaseCache: [String: Manuscript] = [:]
    /// An explicit dropdown pick — kept across refreshes while that commit
    /// exists.  Unset (the default) means "always follow the latest commit";
    /// without this distinction a refresh kept whatever sha happened to be
    /// selected, so after a push the anchor stayed on the pre-push commit.
    @ObservationIgnored private var changelogPinnedSHA: String?

    func refreshChangelogCommits(appStore: AppStore) {
        guard let m = manuscript, m.settings.remoteRepository != nil,
              let (_, raw) = try? remoteConfig(appStore) else { return }
        let config = raw.with(branch: m.settings.remoteBranch ?? "source")
        Task {
            guard let commits = try? await gitHubService.commits(config: config) else { return }
            remoteCommits = commits
            // Default follows the newest commit; only an explicit dropdown
            // pick (still present in the list) pins an older anchor.
            let pinned = changelogPinnedSHA.flatMap { p in commits.first(where: { $0.sha == p })?.sha }
            if let target = pinned ?? commits.first?.sha,
               target != changelogBaseSHA || changelogBaseManuscript == nil {
                await loadChangelogBase(target, config: config)
            }
        }
    }

    func selectChangelogCommit(_ sha: String, appStore: AppStore) {
        guard let m = manuscript, let (_, raw) = try? remoteConfig(appStore) else { return }
        changelogPinnedSHA = sha
        let config = raw.with(branch: m.settings.remoteBranch ?? "source")
        Task { await loadChangelogBase(sha, config: config) }
    }

    private func loadChangelogBase(_ sha: String, config: GitHubBackendService.Config) async {
        changelogBaseSHA = sha
        if let cached = changelogBaseCache[sha] { changelogBaseManuscript = cached; return }
        guard let data = try? await gitHubService.manuscriptJSON(atCommit: sha, config: config) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let base = try? decoder.decode(Manuscript.self, from: data) {
            changelogBaseCache[sha] = base
            changelogBaseManuscript = base
        }
    }

    // MARK: - Changelog (diff vs a remote commit)

    struct ChangeItem: Identifiable {
        let context: String   // "Source" or journal name
        let item: String      // "Introduction", "Authors", …
        let change: String    // Added / Removed / Renamed / Modified (+n −m)
        var detail: String? = nil   // exact line-level diff, expandable
        var id: String { context + item + change }
    }

    /// What differs between each journal's current content and its last
    /// stamped version (the state a remote push carries) — a readable diff,
    /// not an event trail.
    func changelog() -> [ChangeItem] {
        guard let m = manuscript else { return [] }
        // The repo is the anchor: the selected commit's manuscript.json
        // (latest by default).  The local baseline file is only an offline
        // fallback.
        guard let baseline = changelogBaseManuscript ?? remoteBaseline() else {
            return [ChangeItem(context: "All", item: "No remote commits yet",
                               change: "Save Remote to start tracking")]
        }
        var out: [ChangeItem] = []
        out += diff(baseline, m, context: "Source")
        for journal in m.journals {
            guard let head = versions(forJournal: journal.id).last else { continue }
            let baseHead = baseline.versions
                .filter { $0.journalID == journal.id && $0.sourceStamp != true }
                .max { $0.number < $1.number }
            if let baseHead {
                out += diff(baseHead.content, head.content, context: journal.name)
            } else {
                out.append(ChangeItem(context: journal.name, item: "Journal", change: "Added"))
            }
        }
        for old in baseline.journals where !m.journals.contains(where: { $0.id == old.id }) {
            out.append(ChangeItem(context: old.name, item: "Journal", change: "Removed"))
        }
        return out
    }

    private func diff(_ base: Manuscript, _ current: Manuscript, context: String) -> [ChangeItem] {
        var out: [ChangeItem] = []
        func add(_ item: String, _ change: String) {
            out.append(ChangeItem(context: context, item: item, change: change))
        }
        func addText(_ item: String, _ old: String, _ new: String) {
            guard old != new else { return }
            if let d = textDiff(old, new) {
                out.append(ChangeItem(context: context, item: item,
                                      change: "Modified (\(d.summary))", detail: d.detail))
            } else {
                out.append(ChangeItem(context: context, item: item, change: "Modified",
                                      detail: "Differs only in whitespace or formatting."))
            }
        }
        if base.title != current.title { add("Project Title", "Modified") }
        addText("Abstract", base.abstract.plain, current.abstract.plain)
        if base.keywords != current.keywords { add("Keywords", "Modified") }
        let baseSecs = Dictionary(uniqueKeysWithValues: base.sections.map { ($0.id, $0) })
        for s in current.sections {
            guard let b = baseSecs[s.id] else { add(s.title, "Added"); continue }
            if b.title != s.title { add("\(b.title) → \(s.title)", "Renamed") }
            addText(s.title, b.content.plain, s.content.plain)
        }
        for b in base.sections where !current.sections.contains(where: { $0.id == b.id }) {
            add(b.title, "Removed")
        }
        func diffList<T: Identifiable>(_ label: String, _ old: [T], _ new: [T],
                                       changed: (T, T) -> Bool, name: (T) -> String) {
            let olds = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            for n in new {
                guard let o = olds[n.id] else { add("\(label): \(name(n))", "Added"); continue }
                if changed(o, n) { add("\(label): \(name(n))", "Modified") }
            }
            for o in old where !new.contains(where: { $0.id == o.id }) {
                add("\(label): \(name(o))", "Removed")
            }
        }
        diffList("Author", base.authors, current.authors, changed: { $0 != $1 }, name: { $0.fullName.isEmpty ? "(unnamed)" : $0.fullName })
        diffList("Figure", base.figures, current.figures, changed: { $0 != $1 }, name: { $0.title.isEmpty ? "untitled" : $0.title })
        diffList("Table", base.tables, current.tables, changed: { $0 != $1 }, name: { $0.title.isEmpty ? "untitled" : $0.title })
        diffList("Reference", base.bibliography, current.bibliography, changed: { $0 != $1 }, name: { $0.key.isEmpty ? $0.title : $0.key })
        return out
    }

    /// Line-level diff: "+n −m" summary plus the exact added/removed lines.
    private func textDiff(_ old: String, _ new: String) -> (summary: String, detail: String)? {
        let oldLines = old.components(separatedBy: "\n").filter { !$0.isEmpty }
        let newLines = new.components(separatedBy: "\n").filter { !$0.isEmpty }
        let changes = newLines.difference(from: oldLines)
        guard !changes.isEmpty else { return nil }
        var removed: [String] = [], added: [String] = []
        for change in changes {
            switch change {
            case .remove(_, let line, _): removed.append("− \(line)")
            case .insert(_, let line, _): added.append("+ \(line)")
            }
        }
        let detail = (removed + added).joined(separator: "\n")
        return ("+\(added.count) −\(removed.count)", detail)
    }

    private func loadLog() {
        activityLog = []
        guard let id = manuscript?.id else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: logURL(for: id)),
           let entries = try? decoder.decode([LogEntry].self, from: data) {
            activityLog = entries
        }
    }

    func showBanner(_ kind: BannerKind, _ message: String) {
        log(kind == .success ? .success : .error, message)
        banner = (kind, message)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .error ? 8 : 6))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    private let gitHubService = GitHubBackendService()

    /// The manuscript's active backend account, or a user-actionable error.
    private func activeBackend(_ appStore: AppStore) throws -> BackendAccount {
        guard let m = manuscript else {
            throw GitHubBackendError.notConfigured("No manuscript is open.")
        }
        guard let backendID = m.settings.activeBackendID,
              let account = appStore.backends.first(where: { $0.id == backendID })
        else {
            throw GitHubBackendError.notConfigured("This manuscript has no active backend. Pick one in Overview (add accounts in Settings → Backend).")
        }
        return account
    }

    /// Every file that belongs to the manuscript on the remote, with paths
    /// relative to the manuscript folder.
    private func gatherRemoteFiles() throws -> [GitHubBackendService.File] {
        guard let m = manuscript else { return [] }
        let dir = persistence.manuscriptDirectory(for: m.id)
        var files: [GitHubBackendService.File] = []
        let manuscriptJSON = dir.appendingPathComponent("manuscript.json")
        files.append(.init(path: "manuscript.json", data: try Data(contentsOf: manuscriptJSON)))
        // `ai/` is listed with its two children: the walk is deliberately
        // one level deep, and the prompt log ships with the manuscript.
        // A journal template that was modified here, or invented here, has to
        // travel: whoever opens this manuscript must get the rules it was
        // written against, not whatever their own library happens to hold.
        var journalFolders: [String] = []
        let journalsDir = dir.appendingPathComponent("journals", isDirectory: true)
        if let slugs = try? FileManager.default.contentsOfDirectory(atPath: journalsDir.path) {
            journalFolders = slugs.filter { !$0.hasPrefix(".") }.sorted().map { "journals/\($0)" }
        }
        for sub in ["figures", "data", "attachments", "context",
                    "ai", "ai/prompts", "ai/responses"] + journalFolders {
            let subdir = dir.appendingPathComponent(sub, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: subdir.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = subdir.appendingPathComponent(name)
                if let data = try? Data(contentsOf: url) {
                    files.append(.init(path: "\(sub)/\(name)", data: data))
                }
            }
        }
        return files
    }

    /// The GitHub config for this manuscript: active account credentials +
    /// the manuscript's own repository/branch.
    // MARK: - Remote repository validation (Overview's adaptive controls)

    enum RemoteRepoStatus: Equatable {
        case unknown      // nothing configured, not yet checked, or offline
        case checking
        case valid        // repo exists and its content branch loads
        case missing      // repo (or the content branch) not reachable
    }
    var remoteRepoStatus: RemoteRepoStatus = .unknown

    /// Verifies the configured repository exists and its content branch is
    /// loadable — one commits fetch covers both.  Runs when a manuscript
    /// loads and after the repo name is edited; Overview swaps Save|Load
    /// for Create while the status is `.missing`.  Note GitHub 404s both
    /// "missing" and "no access" — either way Save couldn't work.
    func validateRemoteRepository(appStore: AppStore) {
        guard manuscript?.settings.remoteRepository?.isEmpty == false else {
            remoteRepoStatus = .missing   // nothing entered — offer Create
            return
        }
        guard let (_, raw) = try? remoteConfig(appStore) else {
            remoteRepoStatus = .unknown   // no usable account — leave Save|Load
            return
        }
        let config = raw.with(branch: manuscript?.settings.remoteBranch ?? "source")
        remoteRepoStatus = .checking
        Task {
            do {
                _ = try await gitHubService.commits(config: config, limit: 1)
                remoteRepoStatus = .valid
            } catch is URLError {
                remoteRepoStatus = .unknown   // offline — don't flip the UI
            } catch {
                remoteRepoStatus = .missing
            }
        }
    }

    /// Default repository name for Create when none is entered:
    /// manuscript-editor-<title slug>-<first 8 of the manuscript id> (the
    /// same UUID that names the local storage folder).
    var suggestedRepoName: String {
        let title = (manuscript?.title ?? "manuscript").lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let slug = title.split(separator: "-").joined(separator: "-")
        let id8 = (manuscript?.id.uuidString.prefix(8) ?? "00000000").lowercased()
        return "manuscript-editor-\(slug.isEmpty ? "untitled" : slug)-\(id8)"
    }

    private func remoteConfig(_ appStore: AppStore) throws -> (BackendAccount, GitHubBackendService.Config) {
        let account = try activeBackend(appStore)
        let config = try GitHubBackendService.Config.from(
            account: account,
            repository: manuscript?.settings.remoteRepository,
            branch: manuscript?.settings.remoteBranch)
        return (account, config)
    }

    /// Marks a successful remote round-trip on the manuscript (shown in
    /// Overview and the sidebar), without bumping `updatedAt` — syncing isn't
    /// an edit.
    // MARK: - Remote baseline (changelog anchor)

    /// The manuscript exactly as of the last remote push/pull — what a
    /// collaborator pulling the repo sees.  The changelog diffs against it.
    private func baselineURL(for id: UUID) -> URL {
        persistence.manuscriptDirectory(for: id).appendingPathComponent("remote-baseline.json")
    }

    func remoteBaseline() -> Manuscript? {
        guard let id = manuscript?.id,
              let data = try? Data(contentsOf: baselineURL(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manuscript.self, from: data)
    }

    private func saveRemoteBaseline() {
        guard let m = manuscript else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(m).write(to: baselineURL(for: m.id), options: .atomic)
    }

    /// Reloads the manuscript from its local manuscript.json, discarding
    /// unsaved in-memory state.
    func reloadFromDisk() {
        guard let id = manuscript?.id else { return }
        resetUndoHistory()
        manuscript = persistence.load(id: id).map(normalized)
        showBanner(.success, "Reloaded from the local manuscript.json.")
    }

    private func markSynced(appStore: AppStore? = nil) {
        saveRemoteBaseline()
        remoteRepoStatus = .valid   // a successful round-trip proves it
        manuscript?.lastSyncedAt = Date()
        // The remote head just moved: drop the stale changelog anchor so the
        // comparison retargets to the fresh commit (immediately when we have
        // the appStore for the API config, else on the next pane refresh).
        changelogPinnedSHA = nil
        changelogBaseSHA = nil
        changelogBaseManuscript = nil
        if let appStore { refreshChangelogCommits(appStore: appStore) }
        trySave()
    }

    // MARK: Git branch layout
    //
    // The repository is app-managed with a fixed shape:
    //   main      — README.md only (name, description, how-to, and the
    //               "don't edit by hand" warning)
    //   source    — the authoritative content (full manuscript.json +
    //               figures/ + data/)
    //   journal-* — one branch per journal, holding that journal's head
    //               content snapshot, so `git diff source..journal-x` works.
    //
    // DESIGN NOTE (flagged): in-app Sync is content-taking, not a git
    // fast-forward — once a journal branch has its own commits, git can only
    // fast-forward when histories are strict ancestors.  Sync here lands as a
    // plain commit on the child branch carrying the upstream's content;
    // recording true merge parents is a documented refinement.

    /// Branch name for a journal ("journal-nejm").
    /// Deletes a journal: its tab, its whole version chain, and — when a
    /// remote is configured — its journal-* snapshot branch (best effort;
    /// the local delete never waits on the network).  Refused when another
    /// journal's versions hang from this chain, mirroring rollback's rule:
    /// lineage edges must never dangle.  Returns an error message, or nil.
    func deleteJournal(id: UUID, appStore: AppStore) -> String? {
        guard let m = manuscript,
              let journal = m.journals.first(where: { $0.id == id }) else { return nil }

        let chainIDs = Set(versions(forJournal: id).map(\.id))
        if let dependent = m.versions.first(where: { v in
               v.journalID != id && v.parentID.map(chainIDs.contains) == true
           }),
           let child = m.journals.first(where: { $0.id == dependent.journalID }) {
            return "\(journal.name) has journals derived from it (\(child.name)) — delete those first, or re-sync them from another upstream."
        }

        let branch = branchName(for: journal)
        touch {
            $0.journals.removeAll { $0.id == id }
            $0.versions.removeAll { $0.journalID == id }
        }

        // Remote snapshot branch: removed asynchronously, result bannered.
        if let (_, config) = try? remoteConfig(appStore) {
            Task {
                do {
                    try await gitHubService.deleteBranch(config: config.with(branch: branch))
                    showBanner(.success, "Deleted \(journal.name) — including its \(branch) branch on the remote.")
                } catch {
                    showBanner(.error, "\(journal.name) was deleted locally, but removing the \(branch) branch failed: \(error.localizedDescription)")
                }
            }
        } else {
            showBanner(.success, "Deleted \(journal.name).")
        }
        return nil
    }

    private func branchName(for journal: Journal) -> String {
        let slug = journal.name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, ch in
                if ch == "-" && out.hasSuffix("-") { return }
                out.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "journal-" + (slug.isEmpty ? journal.id.uuidString.lowercased() : slug)
    }

    /// The main branch's README: identity + the do-not-touch warning.
    private func readmeFile() -> GitHubBackendService.File {
        let m = manuscript
        let text = """
        # \(m?.title ?? "Manuscript")

        \(m?.about ?? "A manuscript managed by Manuscript Editor.")

        ## ⚠️ Managed repository — do not edit by hand

        This repository is created and maintained by the **Manuscript Editor**
        macOS app. It is not meant to be manipulated outside the app; manual
        commits can be overwritten on the next save.

        ## Layout

        - `main` — this README only
        - `source` — the authoritative manuscript content
        - `journal-*` — one branch per journal cut (diff against `source` to
          see how a cut departs from the source)

        ## Opening this manuscript

        In Manuscript Editor: **File → New Manuscript (Remote)…**, pick your
        account, and enter this repository.
        """
        return .init(path: "README.md", data: Data(text.utf8))
    }

    /// A journal branch's snapshot: its head content as readable JSON.
    private func journalSnapshot(_ journal: Journal) throws -> GitHubBackendService.File? {
        guard let head = latestVersion(forJournal: journal.id) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]   // diff-friendly
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(head.content)
        return .init(path: "manuscript.json", data: data)
    }

    /// Pushes the manuscript to the active backend in the branch layout above.
    func saveToRemote(appStore: AppStore) {
        guard !isRemoteBusy else { return }
        trySave()   // flush current edits so the push carries what's on screen
        remoteStatus = nil
        remoteError = nil
        do {
            var (account, config) = try remoteConfig(appStore)
            let files = try gatherRemoteFiles()
            let readme = readmeFile()
            let snapshots: [(String, GitHubBackendService.File)] =
                try (manuscript?.journals ?? []).compactMap { journal in
                    try journalSnapshot(journal).map { (branchName(for: journal), $0) }
                }
            let title = manuscript?.title ?? "manuscript"
            isRemoteBusy = true
            account.syncStatus = .syncing
            appStore.updateBackend(account)

            Task {
                do {
                    // main: README only (bootstraps an empty repository too).
                    _ = try await gitHubService.push(
                        files: [readme],
                        message: "Update manuscript README",
                        config: config.with(branch: "main"))
                    // source: the authoritative content.
                    let sha = try await gitHubService.push(
                        files: files,
                        message: "Save \(title) from Manuscript Editor",
                        config: config.with(branch: "source"))
                    // journal-*: per-journal head snapshots for git diffs.
                    for (branch, snapshot) in snapshots {
                        _ = try await gitHubService.push(
                            files: [snapshot],
                            message: "Update \(branch) snapshot",
                            config: config.with(branch: branch))
                    }
                    remoteStatus = "Pushed to \(config.owner)/\(config.repo) — source@\(sha), \(snapshots.count) journal branch\(snapshots.count == 1 ? "" : "es")"
                    showBanner(.success, "Successfully saved to remote — \(remoteStatus ?? "")")
                    markSynced(appStore: appStore)
                    account.isConnected = true
                    account.syncStatus = .available
                    account.lastErrorMessage = nil
                } catch {
                    remoteError = error.localizedDescription
                    showBanner(.error, "Remote sync failed: \(error.localizedDescription)")
                    account.syncStatus = .error
                    account.lastErrorMessage = error.localizedDescription
                }
                appStore.updateBackend(account)
                isRemoteBusy = false
            }
        } catch {
            remoteError = error.localizedDescription
            showBanner(.error, "Remote sync failed: \(error.localizedDescription)")
        }
    }

    /// Creates a private GitHub repository for this manuscript (Manuscript →
    /// Backend), binds it to the manuscript, pushes the current content, and
    /// reports the repository's web URL via `onDone`.
    func createRemoteRepository(named name: String, appStore: AppStore,
                                onDone: @escaping (URL?) -> Void) {
        guard !isRemoteBusy else { return }
        trySave()
        remoteStatus = nil
        remoteError = nil
        do {
            var account = try activeBackend(appStore)
            guard account.provider == .github else {
                throw GitHubBackendError.notConfigured("The active account is \(account.provider.rawValue) — repository creation currently supports GitHub.")
            }
            guard let token = KeychainService.secret(for: account.id), !token.isEmpty else {
                throw GitHubBackendError.notConfigured("No personal access token stored for \"\(account.displayName)\". Add one in Settings → Accounts.")
            }
            let files = try gatherRemoteFiles()
            let readme = readmeFile()
            let snapshots: [(String, GitHubBackendService.File)] =
                try (manuscript?.journals ?? []).compactMap { journal in
                    try journalSnapshot(journal).map { (branchName(for: journal), $0) }
                }
            let title = manuscript?.title ?? "manuscript"
            isRemoteBusy = true
            account.syncStatus = .syncing
            appStore.updateBackend(account)

            Task {
                do {
                    var htmlURL: URL?
                    do {
                        let repo = try await gitHubService.createRepository(named: name, token: token)
                        manuscript?.settings.remoteRepository = repo.fullName
                        htmlURL = repo.htmlURL
                        trySave()
                    } catch {
                        // The repo may exist from a previous attempt whose
                        // push failed (it once pushed content straight to
                        // `source`, which an empty repo rejects) — resume
                        // into the bound repository instead of dead-ending
                        // on "name already exists".
                        guard manuscript?.settings.remoteRepository?.isEmpty == false else { throw error }
                    }
                    let config = try GitHubBackendService.Config.from(
                        account: account, repository: manuscript?.settings.remoteRepository,
                        branch: manuscript?.settings.remoteBranch)
                    // The same layout Save (Remote) writes — README on main
                    // FIRST (this is what bootstraps an empty repository),
                    // content on source, then per-journal snapshots.
                    _ = try await gitHubService.push(
                        files: [readme],
                        message: "Update manuscript README",
                        config: config.with(branch: "main"))
                    _ = try await gitHubService.push(
                        files: files,
                        message: "Save \(title) from Manuscript Editor",
                        config: config.with(branch: "source"))
                    for (branch, snapshot) in snapshots {
                        _ = try await gitHubService.push(
                            files: [snapshot],
                            message: "Update \(branch) snapshot",
                            config: config.with(branch: branch))
                    }
                    let fullName = manuscript?.settings.remoteRepository ?? name
                    remoteStatus = "Created \(fullName) and pushed"
                    showBanner(.success, "Created \(fullName) and pushed.")
                    markSynced(appStore: appStore)
                    account.isConnected = true
                    account.syncStatus = .available
                    account.lastErrorMessage = nil
                    appStore.updateBackend(account)
                    isRemoteBusy = false
                    onDone(htmlURL ?? URL(string: "https://github.com/\(fullName)"))
                } catch {
                    remoteError = error.localizedDescription
                    showBanner(.error, "Remote sync failed: \(error.localizedDescription)")
                    account.syncStatus = .error
                    account.lastErrorMessage = error.localizedDescription
                    appStore.updateBackend(account)
                    isRemoteBusy = false
                    onDone(nil)
                }
            }
        } catch {
            remoteError = error.localizedDescription
            showBanner(.error, "Remote sync failed: \(error.localizedDescription)")
            onDone(nil)
        }
    }

    /// Creates a manuscript bound to a remote repository (File → New
    /// Manuscript (Remote)…).  A local copy always exists (default App
    /// Support location, shown in Overview → Saving & Backend): if the repository
    /// already holds a manuscript it is pulled; an empty repository gets this
    /// fresh manuscript pushed as its first commit.
    func createNewRemote(repository: String, branch: String?, accountID: UUID, appStore: AppStore) {
        var m = Manuscript.new()
        m.settings.activeBackendID = accountID
        m.settings.remoteRepository = repository
        m.settings.remoteBranch = branch?.isEmpty == false ? branch : nil
        resetUndoHistory()
        manuscript = m
        persistence.markOpened(id: m.id)
        trySave()
        remoteStatus = nil
        remoteError = nil
        do {
            var (account, config) = try remoteConfig(appStore)
            isRemoteBusy = true
            account.syncStatus = .syncing
            appStore.updateBackend(account)
            Task {
                do {
                    // Content lives on the SOURCE branch (main is just the
                    // README) — pull from there unless the user named one.
                    let pullConfig = config.with(branch: m.settings.remoteBranch ?? "source")
                    let files = try await gitHubService.pull(config: pullConfig)
                    let dir = persistence.manuscriptDirectory(for: m.id)
                    for file in files where file.path != "manuscript.json" {
                        let dest = dir.appendingPathComponent(file.path)
                        try FileManager.default.createDirectory(
                            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try file.data.write(to: dest, options: .atomic)
                    }
                    if let json = files.first(where: { $0.path == "manuscript.json" }) {
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        var decoded = try decoder.decode(Manuscript.self, from: json.data)
                        decoded.id = m.id
                        decoded.folderBookmark = nil   // the uploader's Mac, not ours
                        decoded.settings.activeBackendID = accountID
                        decoded.settings.remoteRepository = repository
                        decoded.settings.remoteBranch = m.settings.remoteBranch
                        manuscript = normalized(decoded)
                        trySave()
                        markSynced(appStore: appStore)
                    }
                    remoteStatus = "Loaded from \(config.owner)/\(config.repo)@\(config.branch)"
                    showBanner(.success, "Loaded from \(config.owner)/\(config.repo)@\(config.branch).")
                    account.isConnected = true
                    account.syncStatus = .available
                    account.lastErrorMessage = nil
                    appStore.updateBackend(account)
                    isRemoteBusy = false
                } catch {
                    // Empty/uninitialized repository: push the fresh manuscript.
                    isRemoteBusy = false
                    appStore.updateBackend(account)
                    self.saveToRemote(appStore: appStore)
                }
            }
        } catch {
            remoteError = error.localizedDescription
            showBanner(.error, "Remote sync failed: \(error.localizedDescription)")
        }
    }

    /// Moves the manuscript's folder: copies manuscript.json, figures/, and
    /// data/ into `newFolder`, repoints the folder mapping + security bookmark,
    /// then deletes the previous folder.  Returns an error message, or nil.
    func moveManuscriptFolder(to newFolder: URL) -> String? {
        guard var m = manuscript else { return "No manuscript is open." }
        let old = persistence.manuscriptDirectory(for: m.id)
        guard newFolder.standardizedFileURL != old.standardizedFileURL else { return nil }
        let fm = FileManager.default
        do {
            for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where !name.hasPrefix(".") {
                let src = old.appendingPathComponent(name)
                let dst = newFolder.appendingPathComponent(name)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
            if let bookmark = try? newFolder.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                m.folderBookmark = bookmark
            }
            _ = newFolder.startAccessingSecurityScopedResource()
            persistence.setCustomFolder(newFolder, for: m.id)
            manuscript = m
            trySave()
            try? fm.removeItem(at: old)   // the move is a move, not a copy
            return nil
        } catch {
            return "Couldn't move the folder: \(error.localizedDescription)"
        }
    }

    /// Pulls the manuscript files from the active backend, **replacing** the
    /// local content (the caller confirms with the user first).  The local
    /// manuscript id is kept so the folder mapping and lineage of trust stay
    /// local — load-from-remote restores content, it doesn't adopt identity.
    func loadFromRemote(appStore: AppStore) {
        guard !isRemoteBusy else { return }
        guard let current = manuscript else { return }
        remoteStatus = nil
        remoteError = nil
        do {
            var (account, config) = try remoteConfig(appStore)
            isRemoteBusy = true
            account.syncStatus = .syncing
            appStore.updateBackend(account)

            Task {
                do {
                    // Content lives on the SOURCE branch (main is just the
                    // README) — pull from there unless the user named one.
                    let pullConfig = config.with(
                        branch: current.settings.remoteBranch ?? "source")
                    let files = try await gitHubService.pull(config: pullConfig)
                    let dir = persistence.manuscriptDirectory(for: current.id)
                    for file in files where file.path != "manuscript.json" {
                        let dest = dir.appendingPathComponent(file.path)
                        try FileManager.default.createDirectory(
                            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try file.data.write(to: dest, options: .atomic)
                    }
                    if let json = files.first(where: { $0.path == "manuscript.json" }) {
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        var decoded = try decoder.decode(Manuscript.self, from: json.data)
                        decoded.id = current.id                     // keep the local folder mapping
                        decoded.folderBookmark = current.folderBookmark
                        // The remote copy shouldn't retarget where THIS copy syncs.
                        decoded.settings.remoteRepository = current.settings.remoteRepository
                            ?? decoded.settings.remoteRepository
                        manuscript = normalized(decoded)
                        markSynced(appStore: appStore)
                    }
                    remoteStatus = "Loaded from \(config.owner)/\(config.repo)@\(config.branch)"
                    account.isConnected = true
                    account.syncStatus = .available
                    account.lastErrorMessage = nil
                } catch {
                    remoteError = error.localizedDescription
                    showBanner(.error, "Remote sync failed: \(error.localizedDescription)")
                    account.syncStatus = .error
                    account.lastErrorMessage = error.localizedDescription
                }
                appStore.updateBackend(account)
                isRemoteBusy = false
            }
        } catch {
            remoteError = error.localizedDescription
            showBanner(.error, "Remote sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private helpers

    /// Applies `mutation` to the manuscript backing `ref` — the live Source, or
    /// a version's snapshot content — then bumps the timestamp and saves.
    ///
    /// Routing all edits through here lets the content editors stay agnostic:
    /// they pass their `VersionRef` and the same array logic edits whichever
    /// manuscript that tab represents.
    ///
    /// `undoAction` names the entry in the Edit menu; `undoable: false` is for
    /// the rich-text editors' per-keystroke content commits, whose undo lives
    /// in the editor's own scoped manager instead.
    private func touch(_ ref: VersionRef = .source,
                       undoAction: String? = nil,
                       undoable: Bool = true,
                       _ mutation: (inout Manuscript) -> Void) {
        guard var m = manuscript else { return }
        let before = m
        switch ref {
        case .source:
            mutation(&m)
            // Bibliography order tracks citation order as a standing invariant
            // (cited first, by first citation; uncited keep their manual order).
            RefEngine.autoOrderBibliography(&m)
        case .version(let id):
            guard let idx = m.versions.firstIndex(where: { $0.id == id }) else { return }
            var content = m.versions[idx].content
            mutation(&content)
            RefEngine.autoOrderBibliography(&content)
            m.versions[idx].content = content
        }
        m.updatedAt = Date()
        manuscript = m
        trySave()
        if undoable { registerUndo(before, name: undoAction) }
    }

    /// Attempts to resolve a security-scoped bookmark stored on the manuscript
    /// so the app can write to a user-chosen folder after relaunch.
    private func resolveBookmarkIfNeeded(for m: Manuscript) {
        guard let bookmarkData = m.folderBookmark else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale)
        else { return }
        _ = url.startAccessingSecurityScopedResource()
        persistence.setCustomFolder(url, for: m.id)
    }
}
