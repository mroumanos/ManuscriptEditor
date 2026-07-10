// JournalPresets.swift
//
// Hard-coded requirement data for commonly targeted journals.
// When a user adds a journal via "From Preset" in the Add Journal sheet, the app
// copies one of these presets into the manuscript's journals array so the user
// gets a realistic starting point without typing everything manually.
//
// Requirements are based on publicly available author guidelines.
// Users can edit any field in JournalDetailView after adding the preset.

import Foundation

/// Namespace for journal requirement presets.
///
/// `JournalPresets` is a caseless enum (no instances) — just a container for the static
/// data and the nested `JournalPreset` type.
enum JournalPresets {

    /// A template for one journal, used by the "Add Journal" sheet.
    ///
    /// When the user picks a preset and taps Add, the app creates a full `Journal` value
    /// from this template (with a fresh UUID so each added journal is independent).
    struct JournalPreset: Identifiable {
        /// Unique identifier used by SwiftUI's `List` to track rows.
        let id = UUID()
        /// Full journal name displayed in the preset picker.
        let name: String
        /// Publisher name shown as a subtitle in the picker.
        let publisher: String
        /// Pre-filled requirements based on the journal's published author guidelines.
        let requirements: JournalRequirements
    }

    // MARK: - All presets

    /// Every available preset, in the order shown in the picker.
    static var all: [JournalPreset] {
        [nature, nejm, plosOne, lancet, bmj, cell, science]
    }

    // MARK: - Individual presets

    /// Nature — flagship Springer Nature multidisciplinary journal.
    /// Letters/Articles: 3000-word body, 150-word abstract, up to 6 figures.
    static let nature = JournalPreset(
        name: "Nature",
        publisher: "Springer Nature",
        requirements: JournalRequirements(
            maxBodyWords: 3000,
            maxAbstractWords: 150,
            maxFigures: 6,
            maxTables: nil,
            maxReferences: 30,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx, .pdf],
            citationStyle: .vancouver,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Cover letter required",
                "No subheadings within the Abstract",
                "Online Methods appended after references (not counted in word limit)"
            ]
        )
    )

    /// New England Journal of Medicine — leading clinical medicine journal.
    /// Original Articles: 2700-word body, structured 150-word abstract.
    static let nejm = JournalPreset(
        name: "New England Journal of Medicine",
        publisher: "NEJM Group",
        requirements: JournalRequirements(
            maxBodyWords: 2700,
            maxAbstractWords: 150,
            maxFigures: 5,
            maxTables: 4,
            maxReferences: 70,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx],
            citationStyle: .vancouver,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Structured abstract: Background, Methods, Results, Conclusions",
                "Ethics statement required in Methods",
                "Statistical analysis plan described in Methods"
            ]
        )
    )

    /// PLOS ONE — open-access multidisciplinary journal with no length or figure limits.
    /// Emphasis on methodological rigour; any scientifically valid study is in scope.
    static let plosOne = JournalPreset(
        name: "PLOS ONE",
        publisher: "Public Library of Science",
        requirements: JournalRequirements(
            maxBodyWords: nil,    // No strict body word limit
            maxAbstractWords: 300,
            maxFigures: nil,      // No figure limit
            maxTables: nil,
            maxReferences: nil,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx, .pdf, .latex],
            citationStyle: .vancouver,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Data availability statement required",
                "Ethics approval statement required for human/animal studies",
                "ORCID iD recommended for all authors",
                "Figures must be high-resolution (≥300 DPI) separate files"
            ]
        )
    )

    /// The Lancet — high-impact clinical medicine and global health journal.
    /// Articles: 3000 words, structured 250-word abstract with Findings instead of Results.
    static let lancet = JournalPreset(
        name: "The Lancet",
        publisher: "Elsevier",
        requirements: JournalRequirements(
            maxBodyWords: 3000,
            maxAbstractWords: 250,
            maxFigures: 4,
            maxTables: 4,
            maxReferences: 60,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx],
            citationStyle: .vancouver,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Structured abstract: Background, Methods, Findings, Interpretation, Funding",
                "Research in context panel required (Evidence before this study / Added value / Implications)",
                "Declaration of interests required for all authors"
            ]
        )
    )

    /// BMJ — British Medical Journal; broad clinical research scope.
    /// Research Articles: 3000 words, structured abstract, patient involvement statement.
    static let bmj = JournalPreset(
        name: "BMJ",
        publisher: "BMJ Publishing Group",
        requirements: JournalRequirements(
            maxBodyWords: 3000,
            maxAbstractWords: 250,
            maxFigures: 5,
            maxTables: 4,
            maxReferences: 50,
            requiresSeparateFigures: false,
            allowedExportFormats: [.docx, .pdf],
            citationStyle: .vancouver,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Structured abstract: Objectives, Design, Setting, Participants, Main outcome measures, Results, Conclusions",
                "What is already known / What this study adds box required",
                "Patient and public involvement statement required"
            ]
        )
    )

    /// Cell — flagship Cell Press journal for life sciences.
    /// Articles: up to 8000 words; requires STAR Methods and graphical abstract.
    static let cell = JournalPreset(
        name: "Cell",
        publisher: "Cell Press / Elsevier",
        requirements: JournalRequirements(
            maxBodyWords: 8000,
            maxAbstractWords: 150,
            maxFigures: 7,
            maxTables: nil,
            maxReferences: nil,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx, .pdf],
            citationStyle: .apa,
            requiredSections: [.introduction, .results, .discussion, .methods],
            customRules: [
                "STAR Methods (Structured, Transparent, Accessible Reporting) required",
                "Graphical abstract required (1200×1200 px recommended)",
                "Highlights: 3–5 bullet points (85 characters each, max)",
                "Key Resources Table required in STAR Methods"
            ]
        )
    )

    /// Science — flagship AAAS multidisciplinary journal.
    /// Reports: 2500-word body, 125-word summary paragraph (replaces traditional abstract).
    static let science = JournalPreset(
        name: "Science",
        publisher: "American Association for the Advancement of Science",
        requirements: JournalRequirements(
            maxBodyWords: 2500,
            maxAbstractWords: 125,
            maxFigures: 5,
            maxTables: nil,
            maxReferences: 40,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx, .pdf],
            citationStyle: .ama,
            requiredSections: [.introduction, .results, .discussion, .methods],
            customRules: [
                "Summary paragraph replaces traditional abstract (125 words max)",
                "Materials and Methods placed after references (not counted in word limit)",
                "Supplementary materials uploaded as separate file"
            ]
        )
    )
}
