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
        didSet { if oldValue?.id != manuscript?.id { loadLog() } }
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

    /// Fills `RichText.refs` where it is still nil (files written before token
    /// tracking) by decoding the RTF once.  Editors keep the lists current
    /// from then on, so this never runs on an editing hot path.
    private func withExtractedRefs(_ m: inout Manuscript) {
        func fill(_ rt: inout RichText) {
            if rt.refs == nil { rt.refs = RefEngine.extractRefs(from: rt) }
        }
        fill(&m.abstract)
        for i in m.sections.indices { fill(&m.sections[i].content) }
        fill(&m.letterToEditor.body)
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
    func addSection(type: SectionType = .custom, title: String? = nil) -> UUID? {
        guard manuscript != nil else { return nil }
        let uniqueTitle = uniqueSectionTitle(title ?? (type == .custom ? "New Section" : type.rawValue))
        let id = UUID()
        touch(undoAction: "Add Section") { m in
            m.sections.append(ManuscriptSection(id: id, type: type, title: uniqueTitle,
                                                content: RichText(), order: m.sections.count, active: true))
            for v in m.versions.indices {
                var content = m.versions[v].content
                content.sections.append(ManuscriptSection(id: id, type: type, title: uniqueTitle,
                                                          content: RichText(), order: content.sections.count, active: true))
                m.versions[v].content = content
            }
        }
        return id
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

    func updateLetterToEditor(_ letter: LetterToEditor, ref: VersionRef = .source) {
        touch(ref, undoable: false) { $0.letterToEditor = letter }
    }

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
        case .letterToEditor:  return (.coverLetter, nil)
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
        for d in config.documents.indices {
            guard let i = config.documents[d].items.firstIndex(where: {
                $0.kind == key.kind && $0.sectionID == key.sectionID
            }) else { continue }
            if let mutateItem { mutateItem(&config.documents[d].items[i]) }
            if let mutateDocument { mutateDocument(&config.documents[d]) }
            updateExportConfig(config, forJournal: jid)
            return
        }
    }

    func updateExportConfig(_ config: ExportConfig, forJournal journalID: UUID?) {
        touch { m in
            if let journalID {
                if let idx = m.journals.firstIndex(where: { $0.id == journalID }) {
                    m.journals[idx].exportConfig = config
                }
            } else {
                m.sourceExportConfig = config
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
                m.letterToEditor = content.letterToEditor
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

    /// Fast-forwards one journal from its upstream: **stamps the upstream
    /// first when it has unstamped changes** (keeping lineage anchored to
    /// frozen versions), then snapshots that stamp as a new version of this
    /// journal.  Never recursive.
    @discardableResult
    func syncJournal(_ journalID: UUID,
                     adaptedSections: [UUID: String]? = nil) -> ManuscriptVersion? {
        guard let head = latestVersion(forJournal: journalID),
              let source = syncSource(forJournal: journalID) else { return nil }

        // May stamp the upstream (mutating the manuscript) — resolve before
        // snapshotting content.
        let base = syncBase(forUpstream: source.upstreamJournalID)
        guard let m = manuscript else { return nil }

        var baseContent = base?.content ?? m
        if let adaptedSections { applyAdaptedSections(adaptedSections, to: &baseContent) }
        let fromLabel: String
        if let base {
            fromLabel = base.sourceStamp == true
                ? "Source v\(sourceOrdinal(of: base))"
                : "\(source.upstreamName) v\(journalOrdinal(of: base))"
        } else {
            fromLabel = "Source"
        }

        let number = (m.versions.map(\.number).max() ?? 0) + 1
        let version = signed(ManuscriptVersion.cut(
            label: "Synced from \(fromLabel)",
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
        log(.info, "Fast-forwarded \(journalName(journalID) ?? "journal") from \(fromLabel)")
        return version
    }

    /// Fast-backward: overrides the upstream with this journal's latest
    /// content — a full override by design (Aug 2026 sync redesign).  A
    /// journal upstream gets a new head version; the live Source is stamped
    /// first (so the overridden state stays in its history), then the
    /// content is transplanted into the live manuscript (undoable).
    @discardableResult
    func pushToUpstream(_ journalID: UUID,
                        adaptedSections: [UUID: String]? = nil) -> Bool {
        guard let source = syncSource(forJournal: journalID) else { return false }
        // Freeze this journal so lineage hangs from a stamp.
        let base = syncBase(forUpstream: journalID)
        guard var content = base?.content ?? latestVersion(forJournal: journalID)?.content
        else { return false }
        if let adaptedSections { applyAdaptedSections(adaptedSections, to: &content) }

        if let upstreamID = source.upstreamJournalID {
            guard let upstreamHead = latestVersion(forJournal: upstreamID) else { return false }
            let next = signed(ManuscriptVersion.cut(
                label: "Pushed back from \(journalName(journalID) ?? "journal")",
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
                m.letterToEditor = content.letterToEditor
            }
        }
        log(.info, "Fast-backward: \(source.upstreamName) overridden with \(journalName(journalID) ?? "journal")'s latest")
        return true
    }

    /// Overwrites matching sections with AI-adapted plain text (smart sync).
    private func applyAdaptedSections(_ adapted: [UUID: String], to content: inout Manuscript) {
        for i in content.sections.indices {
            if let text = adapted[content.sections[i].id] {
                content.sections[i].content = RichText(plain: text)
            }
        }
    }

    private func journalName(_ id: UUID) -> String? {
        manuscript?.journals.first { $0.id == id }?.name
    }

    /// True while a smart sync's AI call is in flight (spinner in the card).
    var isSmartSyncBusy = false

    /// Smart sync: adapts sections via the connected Claude account, then
    /// performs the override.  Forward adapts the upstream's content toward
    /// this journal's requirements; backward adapts this journal's content
    /// toward the upstream's.
    func smartSync(journalID: UUID, forward: Bool, appStore: AppStore) async {
        guard let m = manuscript,
              let source = syncSource(forJournal: journalID) else { return }
        guard let accountID = m.settings.activeAIServiceID,
              let account = appStore.aiServices.first(where: { $0.id == accountID }) else {
            showBanner(.error, "Smart sync needs an AI service — pick one in Overview → Saving & Backend.")
            return
        }
        let key = KeychainService.secret(for: account.id)
        if account.provider.requiresAPIKey, (key ?? "").isEmpty {
            showBanner(.error, "No API key stored for \(account.displayName) — add one in Settings → Accounts.")
            return
        }

        let journal = m.journals.first { $0.id == journalID }
        let sections: [ManuscriptSection]
        let targetName: String
        let targetRequirements: JournalRequirements?
        if forward {
            // Upstream's latest content, adapted toward THIS journal.
            let base = syncBase(forUpstream: source.upstreamJournalID)
            sections = (base?.content ?? m).sections
            targetName = journal?.name ?? "the journal"
            targetRequirements = journal?.requirements
        } else {
            // This journal's latest content, adapted toward the upstream.
            let upstream = source.upstreamJournalID
                .flatMap { id in m.journals.first { $0.id == id } }
            sections = latestVersion(forJournal: journalID)?.content.sections ?? []
            targetName = upstream?.name ?? "the source manuscript"
            targetRequirements = upstream?.requirements
        }

        isSmartSyncBusy = true
        defer { isSmartSyncBusy = false }
        do {
            let adapted = try await SmartSyncService().adaptSections(
                sections, targetName: targetName,
                requirements: targetRequirements, account: account, apiKey: key)
            if forward {
                if syncJournal(journalID, adaptedSections: adapted) != nil {
                    showBanner(.success, "Smart-forwarded \(journalName(journalID) ?? "journal") from \(source.upstreamName).")
                }
            } else {
                if pushToUpstream(journalID, adaptedSections: adapted) {
                    showBanner(.success, "Smart-backward: \(source.upstreamName) updated from \(journalName(journalID) ?? "journal").")
                }
            }
        } catch {
            showBanner(.error, "Smart sync failed: \(error.localizedDescription)")
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

        let base = syncBase(forUpstream: fromJournalID)
        guard let m = manuscript else { return journal }
        let content = base?.content ?? m
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
        return journal
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
        addText("Letter to Editor", base.letterToEditor.body.plain, current.letterToEditor.body.plain)
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
        for sub in ["figures", "data"] {
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
