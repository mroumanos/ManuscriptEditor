// ChecklistService.swift
//
// Heuristic requirement checker for journal submissions.
//
// Given a source manuscript and a set of journal requirements, this service produces
// a list of ChecklistResult values — one per rule — each marked pass or fail.
// The checklist tab in JournalDetailView calls this every time the view renders,
// so the results update in real time as the user writes.
//
// Rules split into TECHNICAL (verified against the manuscript and the
// journal's export configuration automatically) and MANUAL (free-text
// `customRules` the app cannot verify — rendered as checkboxes the user
// ticks after verifying by hand; ticks persist in `Journal.manualChecksDone`).

import Foundation

/// A stateless service that runs a manuscript against a set of journal requirements
/// and returns a list of pass/fail checklist items.
enum ChecklistService {

    /// Evaluate `manuscript` against `requirements` and return one `ChecklistResult` per rule.
    ///
    /// Results are returned in a human-friendly order:
    ///   1. Word-count limits (body, abstract)
    ///   2. Asset limits (figures, tables, references)
    ///   3. Baseline checks (abstract present, title set)
    ///   4. Required sections
    ///   5. Custom / manual rules
    ///
    /// - Parameters:
    ///   - manuscript: The current version's content to evaluate.
    ///   - journal: The target journal — requirements, export config (for
    ///     the spacing/font/line-number checks), and manual-check ticks.
    /// - Returns: An array of results in display order (technical first).
    static func run(manuscript: Manuscript, journal: Journal) -> [ChecklistResult] {
        let requirements = journal.requirements
        let manualDone = Set(journal.manualChecksDone ?? [])
        // The export document the journal actually renders (first document
        // of its outline; the standard outline when not customized yet).
        let exportFormat = (journal.exportConfig
            ?? ExportConfig.standard(content: manuscript, journal: journal))
            .documents.first?.format ?? ExportDocumentFormat()
        var results: [ChecklistResult] = []

        // --- Word count limits ---

        if let limit = requirements.maxBodyWords {
            let wc = manuscript.bodyWordCount
            results.append(ChecklistResult(
                id: UUID(), rule: "Body ≤ \(limit) words",
                passed: wc <= limit,
                details: "\(wc) of \(limit) words used"
            ))
        }

        if let limit = requirements.maxAbstractWords {
            let wc = manuscript.abstractWordCount
            results.append(ChecklistResult(
                id: UUID(), rule: "Abstract ≤ \(limit) words",
                passed: wc <= limit,
                details: "\(wc) of \(limit) words"
            ))
        }

        // --- Asset limits ---

        if let limit = requirements.maxFigures {
            let n = manuscript.figures.count
            results.append(ChecklistResult(
                id: UUID(), rule: "Figures ≤ \(limit)",
                passed: n <= limit,
                details: "\(n) of \(limit) figures"
            ))
        }

        if let limit = requirements.maxTables {
            let n = manuscript.tables.count
            results.append(ChecklistResult(
                id: UUID(), rule: "Tables ≤ \(limit)",
                passed: n <= limit,
                details: "\(n) of \(limit) tables"
            ))
        }

        if let limit = requirements.maxFiguresPlusTables {
            let n = manuscript.figures.count + manuscript.tables.count
            results.append(ChecklistResult(
                id: UUID(), rule: "Tables + figures ≤ \(limit) combined",
                passed: n <= limit,
                details: "\(manuscript.tables.count) table\(manuscript.tables.count == 1 ? "" : "s") + \(manuscript.figures.count) figure\(manuscript.figures.count == 1 ? "" : "s") = \(n) of \(limit)"
            ))
        }

        if let limit = requirements.maxCoverLetterWords {
            let wc = manuscript.letterToEditor.body.plain
                .split(whereSeparator: \.isWhitespace).count
            results.append(ChecklistResult(
                id: UUID(), rule: "Cover letter ≤ \(limit) words",
                passed: wc <= limit,
                details: wc == 0 ? "No cover letter written yet" : "\(wc) of \(limit) words"
            ))
        }

        if let limit = requirements.maxReferences {
            let n = manuscript.bibliography.count
            results.append(ChecklistResult(
                id: UUID(), rule: "References ≤ \(limit)",
                passed: n <= limit,
                details: "\(n) of \(limit) references"
            ))
        }

        // --- Baseline manuscript checks ---

        // An abstract must exist and contain at least some text.
        let hasAbstract = !manuscript.abstract.isEmpty
        results.append(ChecklistResult(
            id: UUID(), rule: "Abstract present",
            passed: hasAbstract,
            details: hasAbstract ? "\(manuscript.abstractWordCount) words" : "No abstract written"
        ))

        // Title must be set to something other than the default placeholder.
        let hasTitle = !manuscript.title.isEmpty && manuscript.title != "Untitled Manuscript"
        results.append(ChecklistResult(
            id: UUID(), rule: "Title set",
            passed: hasTitle,
            details: hasTitle ? manuscript.title : "Title is still the default"
        ))

        // --- Required sections ---

        // For each section the journal mandates, check that it exists AND has content.
        // An empty section (heading with no body) does not count as present.
        for type in requirements.requiredSections {
            let exists = manuscript.sections.contains {
                $0.type == type && $0.active && !$0.content.isEmpty
            }
            results.append(ChecklistResult(
                id: UUID(), rule: "\(type.rawValue) section present",
                passed: exists,
                details: exists ? "Found with content" : "Missing or empty"
            ))
        }

        // Sections required by title (case-insensitive), e.g. AJPH's
        // "Public Health Implications" — active + non-empty, so it also
        // reaches the export.
        for title in requirements.requiredSectionTitles ?? [] {
            let exists = manuscript.sections.contains {
                $0.active && !$0.content.isEmpty
                    && $0.title.localizedCaseInsensitiveContains(title)
            }
            results.append(ChecklistResult(
                id: UUID(), rule: "\"\(title)\" section present",
                passed: exists,
                details: exists ? "Found with content" : "No active section titled \(title)"
            ))
        }

        // Structured-abstract headings must appear in the abstract text.
        if let headings = requirements.requiredAbstractHeadings, !headings.isEmpty {
            let text = manuscript.abstract.plain
            let missing = headings.filter { !text.localizedCaseInsensitiveContains($0) }
            results.append(ChecklistResult(
                id: UUID(), rule: "Structured abstract headings: \(headings.joined(separator: ", "))",
                passed: missing.isEmpty,
                details: missing.isEmpty ? "All headings present"
                                         : "Missing: \(missing.joined(separator: ", "))"
            ))
        }

        // --- Export configuration ---

        if let spacing = requirements.requiredLineSpacing {
            let passed = exportFormat.lineSpacing >= spacing - 0.01
            results.append(ChecklistResult(
                id: UUID(), rule: "Export spacing ≥ \(spacing == 1.5 ? "1.5×" : String(format: "%g×", spacing))",
                passed: passed,
                details: "Export document is \(String(format: "%g", exportFormat.lineSpacing))× spaced"
            ))
        }

        if let size = requirements.requiredFontSize {
            let passed = abs(exportFormat.fontSize - size) < 0.01
            results.append(ChecklistResult(
                id: UUID(), rule: "Export font size \(String(format: "%g", size)) pt",
                passed: passed,
                details: "Export document is \(String(format: "%g", exportFormat.fontSize)) pt"
            ))
        }

        if requirements.requiresLineNumbers == true {
            results.append(ChecklistResult(
                id: UUID(), rule: "Continuous line numbers in the export",
                passed: exportFormat.lineNumbers,
                details: exportFormat.lineNumbers ? "Line numbers on"
                                                  : "Turn on Lines in the Export pane"
            ))
        }

        // --- Manual rules ---

        // The app cannot verify these; each renders as a checkbox and its
        // tick persists on the journal (matched by rule text).
        for rule in requirements.customRules where !rule.isEmpty {
            let done = manualDone.contains(rule)
            results.append(ChecklistResult(
                id: UUID(), rule: rule,
                passed: done,
                details: done ? "Marked done" : "Tick once verified by hand",
                manual: true
            ))
        }

        return results
    }
}
