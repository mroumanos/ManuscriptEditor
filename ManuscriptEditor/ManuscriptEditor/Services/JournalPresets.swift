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
        /// Country of the journal/publisher (journal-library detail).
        var country: String? = nil
        /// Submission format within the journal ("Research Article",
        /// "Research Brief") — a journal ships once per format, each with
        /// its own requirements.  nil = the journal's default format.
        var articleType: String? = nil
        /// Pre-filled requirements based on the journal's published author guidelines.
        let requirements: JournalRequirements
    }

    // MARK: - All presets

    /// Every available preset, in the order shown in the picker.
    static var all: [JournalPreset] {
        [nature, nejm, plosOne, lancet, bmj, cell, science,
         jama, healthAffairs, healthAndPlace, hsr,
         ajphResearchArticle, ajphResearchBrief, plosMedicine,
         diabetesCare, bmjOpenDiabetes, jneb]
    }

    // MARK: - Individual presets

    /// Nature — flagship Springer Nature multidisciplinary journal.
    /// Letters/Articles: 3000-word body, 150-word abstract, up to 6 figures.
    static let nature = JournalPreset(
        name: "Nature",
        publisher: "Springer Nature",
        country: "United Kingdom",
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
        country: "United States",
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
        country: "United States",
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
        country: "United Kingdom",
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
        country: "United Kingdom",
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
        country: "United States",
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
        country: "United States",
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

    /// JAMA — Journal of the American Medical Association.
    /// Original Investigation: ~3,000-word body, 350-word structured abstract.
    static let jama = JournalPreset(
        name: "JAMA",
        publisher: "American Medical Association",
        country: "United States",
        requirements: JournalRequirements(
            maxBodyWords: 3000,
            maxAbstractWords: 350,
            maxFigures: 5,
            maxTables: 4,
            maxReferences: 75,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx, .pdf],
            citationStyle: .ama,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Structured abstract required",
                "Key Points box (Question/Findings/Meaning) required",
            ]
        )
    )

    /// Health Affairs — health policy research and commentary.
    static let healthAffairs = JournalPreset(
        name: "Health Affairs",
        publisher: "Project HOPE",
        country: "United States",
        requirements: JournalRequirements(
            maxBodyWords: 3500,
            maxAbstractWords: 100,
            maxFigures: 4,
            maxTables: 4,
            maxReferences: 40,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx],
            citationStyle: .vancouver,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Exhibits (figures + tables combined) limited to four",
                "Policy implications must be explicit",
            ]
        )
    )

    /// Health & Place — geography of health (Elsevier).
    static let healthAndPlace = JournalPreset(
        name: "Health & Place",
        publisher: "Elsevier",
        country: "Netherlands",
        requirements: JournalRequirements(
            maxBodyWords: 8000,
            maxAbstractWords: 250,
            maxFigures: nil,
            maxTables: nil,
            maxReferences: nil,
            requiresSeparateFigures: false,
            allowedExportFormats: [.docx, .pdf],
            citationStyle: .harvard,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Highlights (3–5 bullet points) required",
            ]
        )
    )

    /// HSR — Health Services Research (Wiley).
    static let hsr = JournalPreset(
        name: "Health Services Research",
        publisher: "Wiley",
        country: "United States",
        requirements: JournalRequirements(
            maxBodyWords: 6000,
            maxAbstractWords: 250,
            maxFigures: 4,
            maxTables: 4,
            maxReferences: nil,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx],
            citationStyle: .ama,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Structured abstract (Objective/Data Sources/Study Design/Findings/Conclusions)",
                "What This Study Adds box required",
            ]
        )
    )

    /// AJPH — American Journal of Public Health.
    // AJPH ships once per submission format, each with its own limits and
    // checklist — verified against the published Instructions for Authors
    // (ajph.aphapublications.org/authorinstructions: formats, components,
    // and editorial-policies pages; also issued as a PDF), Aug 2026.

    /// AJPH Research Articles: original public health research, the
    /// journal's highest-priority format.
    static let ajphResearchArticle = JournalPreset(
        name: "American Journal of Public Health",
        publisher: "American Public Health Association",
        country: "United States",
        articleType: "Research Article",
        requirements: JournalRequirements(
            maxBodyWords: 3500,
            maxAbstractWords: 180,
            maxFigures: 4,
            maxTables: 4,
            maxReferences: 35,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx],
            citationStyle: .ama,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: ajphSharedRules + [
                "No more than 4 tables + figures COMBINED (the 4/4 caps above are not additive)",
            ]
        )
    )

    /// AJPH Research Briefs: original data-driven research, narrower in
    /// scope — a limited set of key findings shown with 1 table or figure.
    static let ajphResearchBrief = JournalPreset(
        name: "American Journal of Public Health",
        publisher: "American Public Health Association",
        country: "United States",
        articleType: "Research Brief",
        requirements: JournalRequirements(
            maxBodyWords: 1200,
            maxAbstractWords: 180,
            maxFigures: 1,
            maxTables: 1,
            maxReferences: 12,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx],
            citationStyle: .ama,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: ajphSharedRules + [
                "1 table OR 1 figure total (not one of each)",
                "Same rigor as a Research Article — narrower scope, key findings only",
            ]
        )
    )

    /// Checklist items common to every AJPH research format, from the
    /// components and editorial-policies author-instruction pages.
    private static let ajphSharedRules: [String] = [
        "Blinded title page: manuscript title only, no author names",
        "Cover letter ≤150 words: what the paper adds, its public health importance, and a one-sentence main message",
        "Structured abstract ≤180 words INCLUDING headings: Objectives, Methods, Results, Conclusions (+ optional Policy Implications)",
        "Public Health Implications section after Discussion",
        "Text 1.5 or double spaced, 12-point font",
        "Pages AND lines numbered continuously (Word: Page Setup → Line Numbers → Continuous)",
        "References in AMA Manual of Style format",
        "Figures: a single readable panel (2 panels only for direct comparison; more count as extra figures)",
        "Tables self-contained (content, place, time); no combined tables to dodge count limits",
        "Images ≥300 dpi print resolution",
        "Avoid abbreviations/acronyms; define any unavoidable ones at first use",
        "Statistics: exponentiated estimates (OR/IRR) with 95% CIs; P values to 2 decimals, never \"NS\"; two-sided tests",
        "CONSORT (trials) / TREND (non-randomized) / PRISMA (reviews) reporting compliance where applicable",
        "Supplemental files blinded and submitted with the paper",
    ]

    /// PLOS Medicine — open-access general medical journal.
    static let plosMedicine = JournalPreset(
        name: "PLOS Medicine",
        publisher: "Public Library of Science",
        country: "United States",
        requirements: JournalRequirements(
            maxBodyWords: nil,
            maxAbstractWords: 300,
            maxFigures: nil,
            maxTables: nil,
            maxReferences: nil,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx, .pdf],
            citationStyle: .vancouver,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Structured abstract (Background/Methods and Findings/Conclusions)",
                "Author Summary (non-technical) required",
                "Data availability statement required",
            ]
        )
    )

    /// Diabetes Care — American Diabetes Association clinical journal.
    static let diabetesCare = JournalPreset(
        name: "Diabetes Care",
        publisher: "American Diabetes Association",
        country: "United States",
        requirements: JournalRequirements(
            maxBodyWords: 4000,
            maxAbstractWords: 250,
            maxFigures: 4,
            maxTables: 4,
            maxReferences: 50,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx],
            citationStyle: .ama,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Structured abstract (Objective/Research Design and Methods/Results/Conclusions)",
            ]
        )
    )

    /// BMJ Open Diabetes Research & Care.
    static let bmjOpenDiabetes = JournalPreset(
        name: "BMJ Open Diabetes Research & Care",
        publisher: "BMJ Group",
        country: "United Kingdom",
        requirements: JournalRequirements(
            maxBodyWords: 4000,
            maxAbstractWords: 300,
            maxFigures: 5,
            maxTables: 5,
            maxReferences: nil,
            requiresSeparateFigures: true,
            allowedExportFormats: [.docx],
            citationStyle: .vancouver,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Significance of this study box required",
                "Open-access article processing charge applies",
            ]
        )
    )

    /// JNEB — Journal of Nutrition Education and Behavior (Elsevier).
    static let jneb = JournalPreset(
        name: "Journal of Nutrition Education and Behavior",
        publisher: "Elsevier",
        country: "United States",
        requirements: JournalRequirements(
            maxBodyWords: 4500,
            maxAbstractWords: 250,
            maxFigures: nil,
            maxTables: nil,
            maxReferences: nil,
            requiresSeparateFigures: false,
            allowedExportFormats: [.docx],
            citationStyle: .ama,
            requiredSections: [.introduction, .methods, .results, .discussion],
            customRules: [
                "Structured abstract (Objective/Design/Participants/Main Outcome Measures/Analysis/Results/Conclusions and Implications)",
            ]
        )
    )
}
