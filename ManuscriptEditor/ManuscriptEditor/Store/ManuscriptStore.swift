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

    var manuscript: Manuscript?
    var lastSaved: Date?
    var saveError: String?

    // MARK: - Dependencies

    let persistence = PersistenceService()
    let dataService = DataService()

    // MARK: - Lifecycle

    func loadMostRecent() {
        guard let idString = UserDefaults.standard.string(forKey: "lastOpenedManuscriptID"),
              let id = UUID(uuidString: idString)
        else { return }
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
        manuscript = nil
        UserDefaults.standard.removeObject(forKey: "lastOpenedManuscriptID")
    }

    /// Creates a new manuscript in the default App Support location.
    func createNew() {
        manuscript = Manuscript.new()
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
        manuscript = m
        persistence.setCustomFolder(folderURL, for: m.id)
        trySave()
    }

    func open(id: UUID) {
        manuscript = persistence.load(id: id).map(normalized)
        if let m = manuscript {
            resolveBookmarkIfNeeded(for: m)
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
            manuscript = normalized(decoded)
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
        if manuscript?.id == id { manuscript = nil }
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
    /// The journal-facing article title — versioned content (Title pane).
    func updateArticleTitle(_ title: String, ref: VersionRef = .source) {
        touch(ref) { $0.articleTitle = title.isEmpty ? nil : title }
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
    func updateAbstract(_ abstract: RichText, ref: VersionRef = .source) { touch(ref) { $0.abstract = abstract } }
    func updateKeywords(_ keywords: [String], ref: VersionRef = .source) { touch(ref) { $0.keywords = keywords } }

    // MARK: - Authors

    func addAuthor(ref: VersionRef = .source) {
        touch(ref) { $0.authors.append(Author.empty(order: $0.authors.count)) }
    }

    func updateAuthor(_ author: Author, ref: VersionRef = .source) {
        touch(ref) { m in
            if let idx = m.authors.firstIndex(where: { $0.id == author.id }) { m.authors[idx] = author }
        }
    }

    func deleteAuthors(at offsets: IndexSet, ref: VersionRef = .source) {
        touch(ref) {
            $0.authors.remove(atOffsets: offsets)
            for i in $0.authors.indices { $0.authors[i].order = i }
        }
    }

    func moveAuthors(from source: IndexSet, to destination: Int, ref: VersionRef = .source) {
        touch(ref) {
            $0.authors.move(fromOffsets: source, toOffset: destination)
            for i in $0.authors.indices { $0.authors[i].order = i }
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
        touch { m in
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
        touch { m in
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

    /// Activates / deactivates a section for one version.  Deactivating empties
    /// its content (it becomes uneditable and excluded from Checks and Export).
    func setSectionActive(_ active: Bool, id: UUID, ref: VersionRef) {
        touch(ref) { m in
            if let i = m.sections.firstIndex(where: { $0.id == id }) {
                m.sections[i].active = active
                if !active { m.sections[i].content = RichText() }
            }
        }
    }

    /// Edits one version's copy of a section (content etc.).
    func updateSection(_ section: ManuscriptSection, ref: VersionRef = .source) {
        touch(ref) { m in
            if let idx = m.sections.firstIndex(where: { $0.id == section.id }) { m.sections[idx] = section }
        }
    }

    /// Deletes a section everywhere (Source + all versions).
    func deleteSection(id: UUID) {
        touch { m in
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
        touch { m in
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
        touch(ref) { $0.figures.append(Figure.empty(number: ($0.figures.map(\.number).max() ?? 0) + 1)) }
    }

    func updateFigure(_ figure: Figure, ref: VersionRef = .source) {
        touch(ref) { m in
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
        touch(ref) { $0.figures.remove(atOffsets: offsets) }
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
        touch(ref) { $0.tables.append(ManuscriptTable.empty(number: ($0.tables.map(\.number).max() ?? 0) + 1)) }
    }

    func updateTable(_ table: ManuscriptTable, ref: VersionRef = .source) {
        touch(ref) { m in
            if let idx = m.tables.firstIndex(where: { $0.id == table.id }) { m.tables[idx] = table }
        }
    }

    func deleteTables(at offsets: IndexSet, ref: VersionRef = .source) {
        touch(ref) { $0.tables.remove(atOffsets: offsets) }
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
        touch { $0.dataAssets.remove(atOffsets: offsets) }
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
        touch(ref) { $0.bibliography.append(BibEntry.empty()) }
    }

    /// Appends a fully-populated entry (e.g. imported from Zotero), skipping
    /// duplicates that share the same `zoteroKey`.
    func addBibEntry(_ entry: BibEntry, ref: VersionRef = .source) {
        touch(ref) { m in
            if let zk = entry.zoteroKey, m.bibliography.contains(where: { $0.zoteroKey == zk }) { return }
            m.bibliography.append(entry)
        }
    }

    func updateBibEntry(_ entry: BibEntry, ref: VersionRef = .source) {
        touch(ref) { m in
            if let idx = m.bibliography.firstIndex(where: { $0.id == entry.id }) { m.bibliography[idx] = entry }
        }
    }

    func deleteBibEntries(at offsets: IndexSet, ref: VersionRef = .source) {
        touch(ref) { $0.bibliography.remove(atOffsets: offsets) }
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
    func refContext(for ref: VersionRef) -> RefEngine.Context? {
        manuscript(for: ref).map(RefEngine.context)
    }

    /// Per-entry citation number, total count, and per-field usage for the
    /// Bibliography list badges and entry details.
    func citationIndex(ref: VersionRef) -> RefEngine.CitationIndex {
        manuscript(for: ref).map(RefEngine.citationIndex) ?? RefEngine.CitationIndex()
    }

    // MARK: - Letter to editor

    func updateLetterToEditor(_ letter: LetterToEditor, ref: VersionRef = .source) {
        touch(ref) { $0.letterToEditor = letter }
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
        touch { $0.journals.append(journal) }
    }

    func updateJournal(_ journal: Journal) {
        guard let idx = manuscript?.journals.firstIndex(where: { $0.id == journal.id }) else { return }
        touch { $0.journals[idx] = journal }
    }

    func deleteJournals(at offsets: IndexSet) {
        touch { $0.journals.remove(atOffsets: offsets) }
    }

    // MARK: - Export outlines

    /// The export outline for a journal (nil = Source): the stored, customized
    /// one, or the standard pre-configured outline derived from the content.
    func exportConfig(forJournal journalID: UUID?) -> ExportConfig {
        guard let m = manuscript else { return ExportConfig(documents: []) }
        if let journalID {
            let journal = m.journals.first { $0.id == journalID }
            if let stored = journal?.exportConfig { return stored }
            let content = latestVersion(forJournal: journalID)?.content ?? m
            return .standard(content: content, journal: journal)
        }
        return m.sourceExportConfig ?? .standard(content: m, journal: nil)
    }

    /// Persists a (customized) export outline for a journal or the Source.
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
    func syncJournal(_ journalID: UUID) -> ManuscriptVersion? {
        guard let head = latestVersion(forJournal: journalID),
              let source = syncSource(forJournal: journalID) else { return nil }

        // May stamp the upstream (mutating the manuscript) — resolve before
        // snapshotting content.
        let base = syncBase(forUpstream: source.upstreamJournalID)
        guard let m = manuscript else { return nil }

        let baseContent = base?.content ?? m
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
        return version
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
        touch { $0.versions.removeAll { $0.id == id } }
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
    /// Last remote failure, surfaced as an alert by ContentView.
    var remoteError: String?
    /// True while a push/pull is in flight (disables re-entry).
    var isRemoteBusy = false

    private let gitHubService = GitHubBackendService()

    /// The manuscript's active backend account, or a user-actionable error.
    private func activeBackend(_ appStore: AppStore) throws -> BackendAccount {
        guard let m = manuscript else {
            throw GitHubBackendError.notConfigured("No manuscript is open.")
        }
        guard let backendID = m.settings.activeBackendID,
              let account = appStore.backends.first(where: { $0.id == backendID })
        else {
            throw GitHubBackendError.notConfigured("This manuscript has no active backend. Pick one in Manuscript → Settings (add accounts in Preferences → Backend).")
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
    private func markSynced() {
        manuscript?.lastSyncedAt = Date()
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
                    markSynced()
                    account.isConnected = true
                    account.syncStatus = .available
                    account.lastErrorMessage = nil
                } catch {
                    remoteError = error.localizedDescription
                    account.syncStatus = .error
                    account.lastErrorMessage = error.localizedDescription
                }
                appStore.updateBackend(account)
                isRemoteBusy = false
            }
        } catch {
            remoteError = error.localizedDescription
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
                throw GitHubBackendError.notConfigured("No personal access token stored for \"\(account.displayName)\". Add one in Preferences → Accounts.")
            }
            let files = try gatherRemoteFiles()
            let title = manuscript?.title ?? "manuscript"
            isRemoteBusy = true
            account.syncStatus = .syncing
            appStore.updateBackend(account)

            Task {
                do {
                    let repo = try await gitHubService.createRepository(named: name, token: token)
                    manuscript?.settings.remoteRepository = repo.fullName
                    trySave()
                    let config = try GitHubBackendService.Config.from(
                        account: account, repository: repo.fullName,
                        branch: manuscript?.settings.remoteBranch)
                    _ = try await gitHubService.push(
                        files: files,
                        message: "Save \(title) from Manuscript Editor",
                        config: config)
                    remoteStatus = "Created \(repo.fullName) and pushed"
                    markSynced()
                    account.isConnected = true
                    account.syncStatus = .available
                    account.lastErrorMessage = nil
                    appStore.updateBackend(account)
                    isRemoteBusy = false
                    onDone(repo.htmlURL)
                } catch {
                    remoteError = error.localizedDescription
                    account.syncStatus = .error
                    account.lastErrorMessage = error.localizedDescription
                    appStore.updateBackend(account)
                    isRemoteBusy = false
                    onDone(nil)
                }
            }
        } catch {
            remoteError = error.localizedDescription
            onDone(nil)
        }
    }

    /// Creates a manuscript bound to a remote repository (File → New
    /// Manuscript (Remote)…).  A local copy always exists (default App
    /// Support location, shown in Manuscript → Backend): if the repository
    /// already holds a manuscript it is pulled; an empty repository gets this
    /// fresh manuscript pushed as its first commit.
    func createNewRemote(repository: String, branch: String?, accountID: UUID, appStore: AppStore) {
        var m = Manuscript.new()
        m.settings.activeBackendID = accountID
        m.settings.remoteRepository = repository
        m.settings.remoteBranch = branch?.isEmpty == false ? branch : nil
        manuscript = m
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
                    let files = try await gitHubService.pull(config: config)
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
                        decoded.settings.activeBackendID = accountID
                        decoded.settings.remoteRepository = repository
                        decoded.settings.remoteBranch = m.settings.remoteBranch
                        manuscript = normalized(decoded)
                        markSynced()
                    }
                    remoteStatus = "Loaded from \(config.owner)/\(config.repo)@\(config.branch)"
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
                    let files = try await gitHubService.pull(config: config)
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
                        markSynced()
                    }
                    remoteStatus = "Loaded from \(config.owner)/\(config.repo)@\(config.branch)"
                    account.isConnected = true
                    account.syncStatus = .available
                    account.lastErrorMessage = nil
                } catch {
                    remoteError = error.localizedDescription
                    account.syncStatus = .error
                    account.lastErrorMessage = error.localizedDescription
                }
                appStore.updateBackend(account)
                isRemoteBusy = false
            }
        } catch {
            remoteError = error.localizedDescription
        }
    }

    // MARK: - Private helpers

    /// Applies `mutation` to the manuscript backing `ref` — the live Source, or
    /// a version's snapshot content — then bumps the timestamp and saves.
    ///
    /// Routing all edits through here lets the content editors stay agnostic:
    /// they pass their `VersionRef` and the same array logic edits whichever
    /// manuscript that tab represents.
    private func touch(_ ref: VersionRef = .source, _ mutation: (inout Manuscript) -> Void) {
        guard var m = manuscript else { return }
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
