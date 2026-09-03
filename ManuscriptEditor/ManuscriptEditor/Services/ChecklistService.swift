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
import ImageIO

/// A stateless service that runs a manuscript against a set of journal requirements
/// and returns a list of pass/fail checklist items.
enum ChecklistService {

    /// The FAILING checks per scope, in checklist order.  The sidebar needs
    /// only "is anything failing here", but a pane also shows what is wrong
    /// and how many, so the failures themselves are what's returned.
    /// Keys match `CheckScope.key`.
    static func scopeFailures(manuscript: Manuscript, journal: Journal,
                              figureURL: ((Figure) -> URL?)? = nil) -> [String: [ChecklistResult]] {
        var failures: [String: [ChecklistResult]] = [:]
        for result in run(manuscript: manuscript, journal: journal, figureURL: figureURL)
        where !result.manual && !result.passed {
            for scope in Set(result.scopes) {
                failures[scope, default: []].append(result)
            }
        }
        return failures
    }

    /// Pass/fail per SCOPE for the sidebar: a pane is red when a check
    /// covering it failed.  Keys match `CheckScope.key`.
    static func scopeStatus(manuscript: Manuscript, journal: Journal,
                            figureURL: ((Figure) -> URL?)? = nil) -> [String: Bool] {
        var status: [String: Bool] = [:]
        for result in run(manuscript: manuscript, journal: journal, figureURL: figureURL)
        where !result.manual {
            for scope in result.scopes {
                status[scope] = (status[scope] ?? true) && result.passed
            }
        }
        return status
    }

    /// One condition's verdict plus the measurement behind it, so a failure
    /// reads "Abstract: 312 words" rather than just "failed".
    private static func evaluate(_ condition: CheckCondition, in m: Manuscript,
                                 journal: Journal? = nil) -> (passed: Bool, detail: String) {

        // Export formatting reads the journal's configuration, not the prose.
        if condition.metric.isFormat {
            let config = journal?.exportConfig
                ?? ExportConfig.standard(content: m, journal: journal)
            let format = config.documents.first?.format ?? ExportDocumentFormat()
            switch condition.metric {
            case .fontSize:
                return (condition.comparator.passes(format.fontSize, condition.number),
                        "export is \(String(format: "%g", format.fontSize)) pt")
            case .lineSpacing:
                return (condition.comparator.passes(format.lineSpacing, condition.number),
                        "export is \(String(format: "%g", format.lineSpacing))× spaced")
            case .lineNumbers:
                let on = format.lineNumbers
                let want = condition.number >= 1
                return (on == want, on ? "line numbers on" : "line numbers off")
            default: break
            }
        }


        // STRUCTURE compares the manuscript's shape against the journal's
        // structure file — the sections it says a submission has.  Optional
        // sections never fail; only the required ones do.
        if condition.metric.isStructure {
            let expected = journal?.structure?.sections.filter(\.required) ?? []
            guard !expected.isEmpty else { return (true, "no structure defined") }
            let present = m.sections.filter { $0.active && !$0.content.isEmpty }
                .map { $0.title.lowercased() }
            let missing = expected.filter { section in
                !present.contains { $0 == section.id || $0.contains(section.id) }
            }
            return (missing.isEmpty,
                    missing.isEmpty
                        ? "all \(expected.count) required sections present"
                        : "missing: \(missing.map(\.title).joined(separator: ", "))")
        }

        /// Narrow a scope's text to the condition's subsections, when set.
        func narrowed(_ whole: String) -> String {
            guard !condition.subsections.isEmpty else { return whole }
            return condition.subsections
                .map { SubsectionParser.body(of: $0, in: whole) }
                .joined(separator: "\n")
        }

        func text(of scope: CheckScope) -> String {
            switch scope.kind {
            case .title:       return m.articleTitle ?? m.title
            case .subtitle:    return m.subtitle ?? ""
            case .abstract:    return m.abstract.plain
            case .keywords:    return m.keywords.joined(separator: ", ")
            case .authors:     return m.authors.map(\.fullName).joined(separator: "; ")
            case .body:        return m.sections.filter(\.active).map(\.content.plain).joined(separator: "\n")
            case .section:
                let wanted = (scope.name ?? "").lowercased()
                return m.sections.first { $0.active && $0.title.lowercased() == wanted }?.content.plain
                    ?? m.sections.first { $0.active && $0.title.lowercased().contains(wanted) }?.content.plain
                    ?? ""
            case .figures:     return m.figures.map { "\($0.title) \($0.caption)" }.joined(separator: "\n")
            case .tables:      return m.tables.map { "\($0.title) \($0.caption)" }.joined(separator: "\n")
            case .references:  return m.bibliography.map(\.title).joined(separator: "\n")
            case .coverLetter: return m.letterToEditor.body.plain
            case .export:      return ""      // handled above, before scopes
            }
        }

        func collectionCount(of scope: CheckScope) -> Int {
            switch scope.kind {
            case .figures:    return m.figures.count
            case .tables:     return m.tables.count
            case .references: return m.bibliography.count
            case .keywords:   return m.keywords.count
            case .authors:    return m.authors.count
            case .body:       return m.sections.filter { $0.active && !$0.content.isEmpty }.count
            case .section:
                let wanted = (scope.name ?? "").lowercased()
                return m.sections.filter { $0.active && $0.title.lowercased().contains(wanted) }.count
            default:          return text(of: scope).isEmpty ? 0 : 1
            }
        }

        // Selected scopes measure TOGETHER: lengths and counts add up, and
        // EXISTS/CONTAINS require every one of them (the rule's ANY
        // combinator is how you express "either").
        let label = condition.scopeLabel
        let joined = narrowed(condition.scopes.map { text(of: $0) }.joined(separator: "\n"))

        switch condition.metric {
        case .words:
            let n = WordCountService.count(joined)
            return (condition.comparator.passes(Double(n), condition.number),
                    "\(label): \(n) words")
        case .characters:
            let n = joined.count
            return (condition.comparator.passes(Double(n), condition.number),
                    "\(label): \(n) characters")
        case .count:
            let n = condition.scopes.reduce(0) { $0 + collectionCount(of: $1) }
            return (condition.comparator.passes(Double(n), condition.number),
                    "\(label): \(n)")
        case .exists:
            let missing = condition.scopes.filter {
                narrowed(text(of: $0)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return (missing.isEmpty,
                    missing.isEmpty ? "\(label) present"
                                    : "missing: \(missing.map(\.label).joined(separator: ", "))")
        case .fontSize, .lineSpacing, .lineNumbers, .structure:
            return (true, "")                  // handled above
        case .contains:
            let needle = condition.text.trimmingCharacters(in: .whitespaces)
            let missing = condition.scopes.filter {
                needle.isEmpty || !narrowed(text(of: $0)).localizedCaseInsensitiveContains(needle)
            }
            return (missing.isEmpty && !needle.isEmpty,
                    missing.isEmpty ? "\(label) contains it"
                                    : "\(missing.map(\.label).joined(separator: ", ")) missing \"\(needle)\"")
        }
    }

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
    static func run(manuscript: Manuscript, journal: Journal,
                    figureURL: ((Figure) -> URL?)? = nil) -> [ChecklistResult] {
        let requirements = journal.requirements
        let manualDone = Set(journal.manualChecksDone ?? [])
        // Every printed export entry's effective typography (Phase 2:
        // per-section) — name + size + spacing + line numbers.
        let exportConfig = journal.exportConfig
            ?? ExportConfig.standard(content: manuscript, journal: journal)
        var typography: [(name: String, fontSize: Double, lineSpacing: Double, lineNumbers: Bool)] = []
        for document in exportConfig.documents {
            // Line numbering is section-level: each break re-sets it for
            // the entries after it (nil = inherit the document's).
            var sectionLines = document.format.lineNumbers
            for entry in document.items {
                if entry.kind == .pageBreak {
                    // nil inherits the previous section (running geometry).
                    sectionLines = entry.sectionLineNumbers ?? sectionLines
                    continue
                }
                typography.append((entry.title(in: manuscript),
                                   entry.format?.fontSize ?? document.format.fontSize,
                                   entry.format?.lineSpacing ?? document.format.lineSpacing,
                                   sectionLines))
            }
        }
        var results: [ChecklistResult] = []

        // EVERYTHING shown comes from the journal's profile — technical and
        // manual alike — so every line in the checklist is editable in the
        // checks editor.  (`JournalRequirements` survives as the export's
        // seed; the bundled profiles carry the same limits as checks.)
        // --- User-written rules (the configurable vocabulary) ---

        for rule in journal.checkRules ?? [] where rule.isEnabled {
            // Manual checks are just checks: same list, same editor, ticked
            // by hand and remembered per journal.
            if rule.isManual {
                let done = manualDone.contains(rule.displayName)
                results.append(ChecklistResult(
                    id: rule.id, rule: rule.displayName, passed: done,
                    details: rule.note ?? "Tick once verified by hand",
                    manual: true))
                continue
            }
            let outcomes = rule.conditions.map { evaluate($0, in: manuscript, journal: journal) }
            let passed = rule.combinator == .all
                ? outcomes.allSatisfy(\.passed)
                : outcomes.contains(where: \.passed)
            let detail = outcomes.map(\.detail)
                .joined(separator: rule.combinator == .all ? " · " : " or ")
            let repairable = rule.conditions.contains { $0.metric.isFormat }
            results.append(ChecklistResult(
                id: rule.id, rule: rule.displayName, passed: passed,
                details: passed ? detail : (rule.note.map { "\(detail) — \($0)" } ?? detail),
                scopes: rule.scopeKeys,
                fixID: (!passed && repairable) ? "typography" : nil
            ))
        }

        // --- Legacy manual rules (pre-profile journals only) ---
        guard (journal.checkRules ?? []).isEmpty else { return results }


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

    /// Effective print DPI of an image file: its DPI metadata when present,
    /// else a pixel-based estimate assuming a 6.5-inch print width.
    private static func imageDPI(at url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 { return dpi }
        if let width = props[kCGImagePropertyPixelWidth] as? Double, width > 0 { return width / 6.5 }
        return nil
    }
}
