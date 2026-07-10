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
    func updateRunningTitle(_ title: String)        { touch { $0.runningTitle = title } }
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
        let note = Note.new(versionKey: versionKey, itemKey: itemKey, author: author, body: body)
        touch { $0.notes.append(note) }
        return note
    }

    func updateNote(_ note: Note) {
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

    /// One journal's version chain (nil = versions not tied to a journal),
    /// oldest first — the "linear lineage" of that journal.
    func versions(forJournal journalID: UUID?) -> [ManuscriptVersion] {
        versions
            .filter { $0.journalID == journalID }
            .sorted { $0.number < $1.number }
    }

    /// The working head of a journal: its most recent version.
    func latestVersion(forJournal journalID: UUID?) -> ManuscriptVersion? {
        versions(forJournal: journalID).last
    }

    /// A version's ordinal within its own journal's chain ("v1, v2, …" in the
    /// per-journal views; distinct from the manuscript-global `number`).
    func journalOrdinal(of version: ManuscriptVersion) -> Int {
        (versions(forJournal: version.journalID).firstIndex { $0.id == version.id } ?? 0) + 1
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
        // Chain roots at (or broke off toward) the live Source manuscript.
        return (nil, "Source", nil)
    }

    /// Fast-forwards one journal from its upstream: snapshots the upstream's
    /// latest content as a **new version** of this journal (never recursive).
    /// The journal's previous versions remain in its history.
    @discardableResult
    func syncJournal(_ journalID: UUID) -> ManuscriptVersion? {
        guard let m = manuscript,
              let head = latestVersion(forJournal: journalID),
              let source = syncSource(forJournal: journalID) else { return nil }

        let baseContent = source.targetVersion?.content ?? m
        let fromLabel = source.targetVersion.map {
            "\(source.upstreamName) v\(journalOrdinal(of: $0))"
        } ?? "Source"

        let number = (m.versions.map(\.number).max() ?? 0) + 1
        let author = UserDefaults.standard.string(forKey: "noteAuthorName") ?? "Me"
        let version = ManuscriptVersion.cut(
            label: "Synced from \(fromLabel)",
            from: baseContent,
            parentID: source.targetVersion?.id,
            journalID: journalID,
            viewConfigID: head.viewConfigID,
            number: number,
            author: author
        )
        touch { $0.versions.append(version) }
        // The synced version is the journal's new working head — open tabs
        // showing the old head must follow it or the sync looks like a no-op.
        NotificationCenter.default.post(
            name: .journalHeadChanged, object: nil,
            userInfo: ["old": head.id, "new": version.id])
        return version
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
        let author = UserDefaults.standard.string(forKey: "noteAuthorName") ?? "Me"
        let version = ManuscriptVersion.cut(
            label: label,
            from: baseContent,
            parentID: parentID,
            journalID: journalID,
            viewConfigID: viewConfigID,
            number: number,
            author: author
        )
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
