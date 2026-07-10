// ChecklistService.swift
//
// Heuristic requirement checker for journal submissions.
//
// Given a source manuscript and a set of journal requirements, this service produces
// a list of ChecklistResult values — one per rule — each marked pass or fail.
// The checklist tab in JournalDetailView calls this every time the view renders,
// so the results update in real time as the user writes.
//
// Rules that cannot be checked automatically (e.g. "Cover letter required") are
// always marked failed with a "Requires manual verification" note.

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
    ///   - manuscript: The current source manuscript to evaluate.
    ///   - requirements: The target journal's rules.
    /// - Returns: An array of results in display order.
    static func run(manuscript: Manuscript, requirements: JournalRequirements) -> [ChecklistResult] {
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

        // --- Custom / manual rules ---

        // These cannot be checked programmatically.  We always mark them failed so
        // the user is reminded to verify them before submission.
        for rule in requirements.customRules where !rule.isEmpty {
            results.append(ChecklistResult(
                id: UUID(), rule: rule,
                passed: false,
                details: "Requires manual verification"
            ))
        }

        return results
    }
}
