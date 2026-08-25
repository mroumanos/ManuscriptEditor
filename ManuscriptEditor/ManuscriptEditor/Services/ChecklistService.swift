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
    private static func evaluate(_ condition: CheckCondition,
                                 in m: Manuscript) -> (passed: Bool, detail: String) {

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

        func offenders(_ names: [String]) -> String {
            names.prefix(4).joined(separator: ", ") + (names.count > 4 ? ", …" : "")
        }

        if let spacing = requirements.requiredLineSpacing {
            let off = typography.filter { $0.lineSpacing < spacing - 0.01 }.map(\.name)
            results.append(ChecklistResult(
                id: UUID(), rule: "Export spacing ≥ \(spacing == 1.5 ? "1.5×" : String(format: "%g×", spacing)) (every section)",
                passed: off.isEmpty,
                details: off.isEmpty ? "All sections at the required spacing"
                                     : "Below required: \(offenders(off))",
                fixID: off.isEmpty ? nil : "typography"
            ))
        }

        if let size = requirements.requiredFontSize {
            let off = typography.filter { abs($0.fontSize - size) > 0.01 }.map(\.name)
            results.append(ChecklistResult(
                id: UUID(), rule: "Export font size \(String(format: "%g", size)) pt (every section)",
                passed: off.isEmpty,
                details: off.isEmpty ? "All sections at \(String(format: "%g", size)) pt"
                                     : "Off-size: \(offenders(off))",
                fixID: off.isEmpty ? nil : "typography"
            ))
        }

        if requirements.requiresLineNumbers == true {
            let off = typography.filter { !$0.lineNumbers }.map(\.name)
            results.append(ChecklistResult(
                id: UUID(), rule: "Continuous line numbers in the export (every section)",
                passed: off.isEmpty,
                details: off.isEmpty ? "Line numbers on throughout"
                                     : "Missing line numbers: \(offenders(off))",
                fixID: off.isEmpty ? nil : "typography"
            ))
        }

        // --- Content heuristics ---

        if requirements.requiresCompleteReferences == true, !manuscript.bibliography.isEmpty {
            let incomplete = manuscript.bibliography.filter { e in
                e.authors.allSatisfy(\.isEmpty) || e.title.isEmpty || e.year == nil
                    || (e.journal ?? e.publisher ?? e.booktitle ?? e.url ?? "").isEmpty
            }
            let names = incomplete.prefix(3)
                .map { $0.key.isEmpty ? ($0.title.isEmpty ? "(untitled)" : $0.title) : $0.key }
            results.append(ChecklistResult(
                id: UUID(), rule: "References complete (authors, title, year, venue)",
                passed: incomplete.isEmpty,
                details: incomplete.isEmpty
                    ? "All \(manuscript.bibliography.count) references carry the fields citation styles need"
                    : "\(incomplete.count) incomplete: \(names.joined(separator: ", "))\(incomplete.count > 3 ? ", …" : "")"
            ))
        }

        if let minDPI = requirements.minFigureImageDPI, let figureURL {
            let images = manuscript.figures.filter { $0.dataAssetID == nil }
            if !images.isEmpty {
                var low: [String] = []
                for figure in images {
                    guard let url = figureURL(figure), let dpi = imageDPI(at: url) else { continue }
                    if dpi < minDPI - 0.5 {
                        let label = figure.title.isEmpty ? "Figure \(figure.number)" : figure.title
                        low.append("\(label) (~\(Int(dpi)) dpi)")
                    }
                }
                results.append(ChecklistResult(
                    id: UUID(), rule: "Figure images ≥ \(Int(minDPI)) dpi",
                    passed: low.isEmpty,
                    details: low.isEmpty ? "\(images.count) image figure\(images.count == 1 ? "" : "s") at print resolution"
                                         : "Low resolution: \(low.joined(separator: ", "))"
                ))
            }
        }

        // Full prose the text heuristics scan: active sections + abstract.
        let bodyText = (manuscript.sections.filter(\.active).map { $0.content.plain }
                        + [manuscript.abstract.plain]).joined(separator: "\n")

        if requirements.checksAcronymsDefined == true {
            // ALL-CAPS tokens are acronyms; "defined" = the token appears in
            // parentheses at least once ("confidence interval (CI)").
            // Universally understood ones don't need defining.
            let allowed: Set<String> = ["USA", "US", "UK", "EU", "UN", "WHO", "CDC", "NIH",
                                        "HIV", "AIDS", "COVID", "DNA", "RNA", "CI", "OR",
                                        "RR", "IRR", "HR", "SD", "SE", "IQR", "ANOVA"]
            let tokens = Set(bodyText.matches(of: /\b[A-Z]{2,6}\b/).map { String($0.output) })
                .subtracting(allowed)
            let undefined = tokens.filter { !bodyText.contains("(\($0)") }.sorted()
            results.append(ChecklistResult(
                id: UUID(), rule: "Acronyms defined at first use (heuristic)",
                passed: undefined.isEmpty,
                details: undefined.isEmpty
                    ? "No undefined acronyms found"
                    : "Never defined in parentheses: \(undefined.prefix(6).joined(separator: ", "))\(undefined.count > 6 ? ", …" : "")"
            ))
        }

        if requirements.checksStatsNotation == true {
            var issues: [String] = []
            if bodyText.contains(/\bNS\b/) {
                issues.append("\"NS\" used — print the actual P value")
            }
            if !bodyText.matches(of: /[Pp]\s*[<=>≤≥]\s*0?\.\d{3,}/).isEmpty {
                issues.append("P value with more than 2 decimals")
            }
            results.append(ChecklistResult(
                id: UUID(), rule: "P-value notation: ≤ 2 decimals, never \"NS\"",
                passed: issues.isEmpty,
                details: issues.isEmpty ? "No notation issues found" : issues.joined(separator: "; ")
            ))
        }

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
            let outcomes = rule.conditions.map { evaluate($0, in: manuscript) }
            let passed = rule.combinator == .all
                ? outcomes.allSatisfy(\.passed)
                : outcomes.contains(where: \.passed)
            let detail = outcomes.map(\.detail)
                .joined(separator: rule.combinator == .all ? " · " : " or ")
            results.append(ChecklistResult(
                id: rule.id, rule: rule.displayName, passed: passed,
                details: passed ? detail : (rule.note.map { "\(detail) — \($0)" } ?? detail),
                scopes: rule.scopeKeys
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
