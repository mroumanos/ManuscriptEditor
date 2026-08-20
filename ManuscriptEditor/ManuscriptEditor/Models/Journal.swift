// Journal.swift
//
// Everything the app needs to know about a target journal:
//   - identity (name, publisher)
//   - submission requirements (word limits, format rules, etc.)
//   - the view auto-generated from those requirements (1-1, by UUID)
//
// Manuscript versions ("cuts") targeting a journal live at the manuscript
// level — see ManuscriptVersion — and reference the journal by `journalID`.
// Phase 2 will add LLM-driven adaptation of version content.

import Foundation

// MARK: - Journal

/// A target journal the user wants to submit to, along with its requirements.
struct Journal: Codable, Identifiable, Sendable {

    /// Stable unique identifier.
    var id: UUID

    /// Full journal name, e.g. "Nature" or "PLOS ONE".
    var name: String

    /// Publisher or society that owns the journal, e.g. "Springer Nature".
    var publisher: String

    /// URL of the journal's online submission system.  Left blank until the user fills it in.
    var submissionURL: String

    /// All the formatting and content rules for this journal.
    var requirements: JournalRequirements

    /// The `ViewConfig.id` of the view auto-generated from this journal's
    /// requirements (stored globally in AppStore).  Created lazily the first
    /// time a version targets this journal.  Each journal has exactly one view.
    var viewConfigID: UUID?

    /// When this journal profile was added to the manuscript.
    var createdAt: Date

    /// Country of the journal/publisher — registry detail shown in the app
    /// settings Journals library.  Optional for backward compatibility.
    var country: String? = nil

    /// SF Symbol shown for this journal in the sync lineage (configured in
    /// the app-settings Journals library).  nil renders as a question mark.
    var icon: String? = nil

    /// Submission format within the journal ("Research Article", "Research
    /// Brief") — one journal can appear in the library once per type, each
    /// with its own requirements.  Optional for backward-compatible
    /// decoding; nil = the journal's default/unspecified format.
    var articleType: String? = nil

    /// "American Journal of Public Health — Research Brief"; just the name
    /// when no type is set.
    var displayName: String {
        articleType.map { "\(name) — \($0)" } ?? name
    }

    /// Manual checklist rules the user has ticked off for this journal
    /// (matched by rule text).  Optional for backward-compatible decoding.
    var manualChecksDone: [String]? = nil

    /// This journal's export outline (documents, ordering, page breaks,
    /// format, file types).  `nil` means "not customized yet" — the Export
    /// pane shows `ExportConfig.standard` until the user edits it.
    var exportConfig: ExportConfig? = nil

    // MARK: - Factory

    /// A blank journal entry with default (permissive) requirements.
    static func empty() -> Journal {
        Journal(
            id: UUID(),
            name: "",
            publisher: "",
            submissionURL: "",
            requirements: JournalRequirements(),
            viewConfigID: nil,
            createdAt: Date()
        )
    }
}

// MARK: - JournalRequirements

/// The set of rules a manuscript must satisfy to be submitted to a given journal.
///
/// All limits are optional (`Int?`) because not every journal publishes explicit caps.
/// When a limit is `nil`, the corresponding checklist item is skipped.
struct JournalRequirements: Codable, Sendable {

    /// Maximum number of words allowed in the body (excluding abstract and methods notes).
    var maxBodyWords: Int?

    /// Maximum number of words allowed in the abstract.
    var maxAbstractWords: Int?

    /// Maximum number of figures (including supplementary figures, depending on journal).
    var maxFigures: Int?

    /// Maximum number of tables.
    var maxTables: Int?

    /// Maximum number of references in the bibliography.
    var maxReferences: Int?

    /// Whether the journal requires figures to be uploaded as separate files (common in
    /// high-impact journals) rather than embedded in the Word/PDF document.
    var requiresSeparateFigures: Bool = false

    /// File formats the journal's submission system accepts.
    var allowedExportFormats: [ExportFormat] = []

    /// The citation / reference style the journal mandates (APA, Vancouver, etc.).
    var citationStyle: CitationStyle = .apa

    /// Body sections that must be present and non-empty for submission.
    var requiredSections: [SectionType] = []

    /// Free-text rules that cannot be checked automatically and require manual review
    /// (e.g. "Cover letter required", "Ethics statement in Methods").
    var customRules: [String] = []

    // MARK: Technical checks (Aug 2026 — all optional so old files decode)

    /// Cover-letter word cap, checked against the letter body's text.
    var maxCoverLetterWords: Int? = nil

    /// Combined tables + figures cap — some journals cap the SUM (AJPH: 4
    /// combined), not each kind separately.
    var maxFiguresPlusTables: Int? = nil

    /// Sections required by TITLE, beyond the typed `requiredSections` —
    /// e.g. AJPH's "Public Health Implications".  Checked case-insensitively
    /// against active, non-empty sections.
    var requiredSectionTitles: [String]? = nil

    /// Headings the abstract text must contain ("Objectives", "Methods"…)
    /// for journals mandating structured abstracts.
    var requiredAbstractHeadings: [String]? = nil

    /// Minimum export line spacing (1.5 accepts 1.5× or double).
    var requiredLineSpacing: Double? = nil

    /// Exact export font size in points (12 = "font size of 12").
    var requiredFontSize: Double? = nil

    /// The export must have continuous line numbers enabled.
    var requiresLineNumbers: Bool? = nil
}

// MARK: - Supporting enumerations

/// Document formats accepted by journal submission systems.
enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case docx   = "DOCX"
    case pdf    = "PDF"
    case latex  = "LaTeX"
    case rtf    = "RTF"
    case txt    = "Plain Text"
}

/// Reference formatting styles used by different journals and disciplines.
enum CitationStyle: String, Codable, CaseIterable, Sendable {
    case apa        = "APA"        // social/behavioural sciences
    case mla        = "MLA"        // humanities
    case chicago    = "Chicago"    // history, arts
    case vancouver  = "Vancouver"  // biomedical (numbered superscripts)
    case harvard    = "Harvard"    // natural sciences
    case ama        = "AMA"        // medicine
    case custom     = "Custom"     // journal-specific variant
}

// MARK: - ChecklistResult

/// The result of a single heuristic requirement check run by `ChecklistService`.
struct ChecklistResult: Codable, Identifiable, Sendable {

    /// Stable unique identifier.
    var id: UUID

    /// Human-readable description of what was checked (e.g. "Body ≤ 3000 words").
    var rule: String

    /// Whether the manuscript currently satisfies this requirement.
    var passed: Bool

    /// A short explanation of the result (e.g. "2847 of 3000 words used").
    var details: String

    /// True for rules the app cannot verify — rendered as a checkbox the
    /// user ticks after verifying by hand (`passed` = ticked, persisted in
    /// `Journal.manualChecksDone`).  False = checked automatically.
    var manual: Bool = false
}
