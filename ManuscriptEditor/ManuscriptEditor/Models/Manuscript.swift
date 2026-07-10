// Manuscript.swift
//
// The top-level data model for an entire manuscript project.
// One Manuscript value holds everything: the paper's content (abstract, body sections,
// figures, tables, bibliography) and its metadata (title, authors, keywords), plus
// the journal profiles the user is targeting.
//
// Persistence: each Manuscript is saved as a single JSON file at
//   ~/Library/Application Support/ManuscriptEditor/manuscripts/{id}/manuscript.json
// See PersistenceService for the read/write logic.

import Foundation

/// The complete data for one manuscript project.
///
/// `Manuscript` is a Swift *value type* (a `struct`).  Every time the store mutates it,
/// it replaces the whole value rather than editing fields in place — which makes
/// change-tracking straightforward and safe across threads.
///
/// Conforms to:
/// - `Codable`      — can be encoded to / decoded from JSON automatically.
/// - `Identifiable` — has a stable `id` so SwiftUI lists can track rows across updates.
/// - `Sendable`     — safe to pass between Swift concurrency contexts (async/await, actors).
struct Manuscript: Codable, Identifiable, Sendable {

    // MARK: - Identity & metadata

    /// Unique identifier.  Assigned once at creation and never changes.
    var id: UUID

    /// The full title of the paper (e.g. "Mechanism of CRISPR-Cas9 off-target cleavage").
    var title: String

    /// A shortened title used in journal headers / running titles (often ≤ 50 characters).
    var runningTitle: String

    /// Subject-matter keywords that journals use for reviewer matching and indexing.
    var keywords: [String]

    // MARK: - Content

    /// The ordered list of authors.  See `Author` for per-author fields.
    var authors: [Author]

    /// The manuscript abstract (rich text; no section structure).
    var abstract: RichText

    /// The body of the paper broken into named sections (Introduction, Methods, etc.).
    /// Stored in display order via `ManuscriptSection.order`.
    var sections: [ManuscriptSection]

    // MARK: - Assets

    /// Figures attached to the manuscript. Each `Figure` can link to an image file on disk.
    var figures: [Figure]

    /// Data tables for the manuscript. Table content is stored as Markdown.
    var tables: [ManuscriptTable]

    /// Raw data assets (CSV → SQLite, imported images) in the manuscript's Data library.
    var dataAssets: [DataAsset]

    // MARK: - References

    /// The full reference list (bibliography).  Each entry is a `BibEntry` value.
    var bibliography: [BibEntry]

    // MARK: - Journal profiles

    /// Path bookmark for the user-chosen save folder (security-scoped, stored as Data).
    /// `nil` means the manuscript is in the default App Support location.
    var folderBookmark: Data?

    /// Target journals the user wants to submit to, each with its own requirements.
    /// Stored on the manuscript so they persist together in the same JSON file.
    var journals: [Journal]

    // MARK: - Versions (cuts)

    /// Adapted snapshots of this manuscript, forming a lineage tree rooted at
    /// the Source (this manuscript itself).  See `ManuscriptVersion` for the
    /// parent/child semantics.  Always empty inside a version's own `content`
    /// snapshot — lineage lives only at the top level.
    var versions: [ManuscriptVersion]

    // MARK: - Notes

    /// First-class feedback anchored to content, for oneself or collaborators.
    /// Stored at the top level (not inside version snapshots) so notes persist
    /// independently of versioning.  See `Note`.
    var notes: [Note]

    // MARK: - Cover letter

    /// The cover letter to be submitted alongside the manuscript.
    /// Each journal cut (Phase 2) will have its own adapted version.
    var letterToEditor: LetterToEditor

    // MARK: - Per-manuscript settings

    /// Active backend, view template, and AI service selections for this manuscript.
    /// References global accounts/configs stored in `AppStore` by UUID.
    var settings: ManuscriptSettings

    /// The Source journal's export outline (target journals store theirs on
    /// their `Journal`).  `nil` = not customized; Export shows the standard one.
    var sourceExportConfig: ExportConfig?

    // MARK: - Timestamps

    /// When this manuscript was first created.
    var createdAt: Date

    /// When this manuscript was last modified.  Updated automatically by `ManuscriptStore.touch`.
    var updatedAt: Date

    /// When this manuscript was last synced (pushed to or pulled from) its
    /// backend.  nil = never synced.  Optional so older files keep decoding.
    var lastSyncedAt: Date? = nil

    /// Free-text project description, editable on the Overview dashboard.
    var about: String? = nil

    // MARK: - Factory

    /// Creates a brand-new, empty manuscript with the standard set of body sections
    /// pre-populated (Introduction through Acknowledgments).
    static func new() -> Manuscript {
        Manuscript(
            id: UUID(),
            title: "Untitled Manuscript",
            runningTitle: "",
            keywords: [],
            authors: [],
            abstract: RichText(),
            sections: SectionType.defaultOrder.enumerated().map { i, type in
                ManuscriptSection(id: UUID(), type: type, title: type.rawValue, content: RichText(), order: i)
            },
            figures: [],
            tables: [],
            dataAssets: [],
            folderBookmark: nil,
            bibliography: [],
            journals: [],
            versions: [],
            notes: [],
            letterToEditor: .empty(),
            settings: .empty(),
            sourceExportConfig: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - Memberwise init
    // Needed explicitly because we also define `init(from:)` below.
    // Swift only synthesises a memberwise init when there is no custom init defined in the
    // struct body — once we add the Codable override, we have to write this out ourselves.

    init(id: UUID, title: String, runningTitle: String, keywords: [String], authors: [Author],
         abstract: RichText, sections: [ManuscriptSection], figures: [Figure],
         tables: [ManuscriptTable], dataAssets: [DataAsset], folderBookmark: Data?,
         bibliography: [BibEntry], journals: [Journal], versions: [ManuscriptVersion],
         notes: [Note], letterToEditor: LetterToEditor, settings: ManuscriptSettings,
         sourceExportConfig: ExportConfig? = nil,
         createdAt: Date, updatedAt: Date) {
        self.id = id; self.title = title; self.runningTitle = runningTitle
        self.keywords = keywords; self.authors = authors; self.abstract = abstract
        self.sections = sections; self.figures = figures; self.tables = tables
        self.dataAssets = dataAssets; self.folderBookmark = folderBookmark
        self.bibliography = bibliography; self.journals = journals; self.versions = versions
        self.notes = notes
        self.letterToEditor = letterToEditor; self.settings = settings
        self.sourceExportConfig = sourceExportConfig
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    // MARK: - Backward-compatible Codable decoding
    // When we added the `journals` field, older saved files didn't include it.
    // Swift's synthesised Decodable would crash on those files; this custom version
    // uses `decodeIfPresent` so missing keys are treated as empty arrays.

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self,                  forKey: .id)
        title         = try c.decode(String.self,                forKey: .title)
        runningTitle  = try c.decode(String.self,                forKey: .runningTitle)
        keywords      = try c.decode([String].self,              forKey: .keywords)
        authors       = try c.decode([Author].self,              forKey: .authors)
        abstract      = try c.decodeIfPresent(RichText.self,     forKey: .abstract) ?? RichText()
        sections      = try c.decode([ManuscriptSection].self,   forKey: .sections)
        figures        = try c.decode([Figure].self,              forKey: .figures)
        tables         = try c.decode([ManuscriptTable].self,    forKey: .tables)
        dataAssets     = try c.decodeIfPresent([DataAsset].self, forKey: .dataAssets)     ?? []
        folderBookmark = try c.decodeIfPresent(Data.self,        forKey: .folderBookmark)
        bibliography   = try c.decode([BibEntry].self,           forKey: .bibliography)
        journals       = try c.decodeIfPresent([Journal].self,            forKey: .journals)       ?? []
        versions       = try c.decodeIfPresent([ManuscriptVersion].self,  forKey: .versions)       ?? []
        notes          = try c.decodeIfPresent([Note].self,               forKey: .notes)          ?? []
        letterToEditor = try c.decodeIfPresent(LetterToEditor.self,     forKey: .letterToEditor) ?? .empty()
        settings       = try c.decodeIfPresent(ManuscriptSettings.self, forKey: .settings)       ?? .empty()
        sourceExportConfig = try c.decodeIfPresent(ExportConfig.self,   forKey: .sourceExportConfig)
        createdAt     = try c.decode(Date.self,                  forKey: .createdAt)
        updatedAt     = try c.decode(Date.self,                  forKey: .updatedAt)
    }

    // MARK: - Computed word counts

    /// Total word count across all body sections (excludes the abstract).
    var bodyWordCount: Int {
        sections.reduce(0) { $0 + $1.wordCount }
    }

    /// Word count of just the abstract.
    var abstractWordCount: Int {
        WordCountService.count(abstract.plain)
    }

    /// Combined word count: abstract + all body sections.
    var totalWordCount: Int {
        abstractWordCount + bodyWordCount
    }
}
