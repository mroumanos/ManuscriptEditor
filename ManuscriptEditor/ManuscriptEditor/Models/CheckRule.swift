// CheckRule.swift
//
// Configurable submission checks.
//
// EVERY check the app runs is one of these — the ones shipped in a journal's
// profile and the ones the user writes are the same thing, so anything the
// checklist shows can be edited.  The vocabulary covers what journals
// actually ask for:
//
//   LENGTH(words|characters) of a scope   ≤ ≥ = ≠   a number
//   COUNT of a collection scope           ≤ ≥ = ≠   a number
//   EXISTS a scope                        (with content)
//   CONTAINS a scope                      some text
//   FONT_SIZE / LINE_SPACING / LINE_NUMBERS of the export
//
// The format metrics read the journal's export configuration rather than the
// prose, which is what lets a failing one offer the typography Fix.
//
// A rule is a list of conditions joined by ALL (and) or ANY (or), so
// "Discussion ≤ 1500 words AND Discussion exists" or "either a Limitations
// or a Strengths section" both express directly.  Every condition names a
// SCOPE, which is how a failing rule colors the section it applies to in
// the sidebar.

import Foundation

// MARK: - CheckMetric

enum CheckMetric: String, Codable, CaseIterable, Sendable {
    case words      = "LENGTH_WORDS"
    case characters = "LENGTH_CHARS"
    case count      = "COUNT"
    case exists     = "EXISTS"
    case contains   = "CONTAINS"
    /// The manuscript's sections against the journal's structure file.
    case structure   = "STRUCTURE"
    // Export formatting, read from the journal's export configuration.
    case fontSize    = "FONT_SIZE"
    case lineSpacing = "LINE_SPACING"
    case lineNumbers = "LINE_NUMBERS"

    var label: String {
        switch self {
        case .words:       return "LENGTH (words)"
        case .characters:  return "LENGTH (characters)"
        case .count:       return "COUNT"
        case .exists:      return "EXISTS"
        case .contains:    return "CONTAINS"
        case .structure:   return "STRUCTURE"
        case .fontSize:    return "FONT SIZE (pt)"
        case .lineSpacing: return "LINE SPACING (×)"
        case .lineNumbers: return "LINE NUMBERS (1 = on)"
        }
    }

    /// Whether the condition compares against a number (else text, or
    /// nothing at all for EXISTS).
    var takesNumber: Bool {
        switch self {
        case .exists, .contains, .structure: return false
        default:                            return true
        }
    }

    /// STRUCTURE measures the manuscript's shape against the journal's
    /// structure file, so it ignores the scope picker too.
    var isStructure: Bool { self == .structure }

    /// Format metrics measure the EXPORT, not the prose, so they ignore the
    /// scope picker and the app can repair them (the typography Fix).
    var isFormat: Bool {
        switch self {
        case .fontSize, .lineSpacing, .lineNumbers: return true
        default:                                    return false
        }
    }
}

// MARK: - CheckComparator

enum CheckComparator: String, Codable, CaseIterable, Sendable {
    case atMost    = "<="
    case atLeast   = ">="
    case equals    = "=="
    case notEquals = "!="

    var label: String { rawValue }

    func passes(_ lhs: Double, _ rhs: Double) -> Bool {
        switch self {
        case .atMost:    return lhs <= rhs
        case .atLeast:   return lhs >= rhs
        case .equals:    return abs(lhs - rhs) < 0.0001
        case .notEquals: return abs(lhs - rhs) >= 0.0001
        }
    }
}

// MARK: - CheckScope

/// What a condition measures.  `key` is the stable identifier the sidebar
/// uses to color the pane a failing rule belongs to.
struct CheckScope: Codable, Hashable, Sendable {

    enum Kind: String, Codable, CaseIterable, Sendable {
        case title, subtitle, abstract, keywords, authors
        case body            // every active body section, together
        case section         // one body section, named
        case figures, tables, references, coverLetter
        case export          // the journal's export configuration

        var label: String {
            switch self {
            case .title:       return "Title"
            case .subtitle:    return "Subtitle"
            case .abstract:    return "Abstract"
            case .keywords:    return "Keywords"
            case .authors:     return "Authors"
            case .body:        return "Body (all sections)"
            case .section:     return "Section…"
            case .figures:     return "Figures"
            case .tables:      return "Tables"
            case .references:  return "References"
            case .coverLetter: return "Cover letter"
            case .export:      return "Export format"
            }
        }
    }

    var kind: Kind
    /// Section title when `kind == .section` (matched case-insensitively).
    var name: String? = nil

    var key: String {
        kind == .section ? "section:\((name ?? "").lowercased())" : kind.rawValue
    }

    var label: String {
        kind == .section ? (name?.isEmpty == false ? name! : "Section") : kind.label
    }
}

// MARK: - CheckCondition

struct CheckCondition: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var metric: CheckMetric = .words
    /// One or MORE scopes, measured together: LENGTH over
    /// [Abstract, Introduction] is their combined word count, COUNT is the
    /// sum, EXISTS/CONTAINS require every selected scope.  Written as a
    /// list so a single-scope condition reads the same as a combined one.
    var scopes: [CheckScope] = [CheckScope(kind: .abstract)]
    /// Subsections (headings inside the selected scopes) to narrow to.
    /// Empty = the whole scope.
    var subsections: [String] = []
    var comparator: CheckComparator = .atMost
    /// Compared against for numeric metrics.
    var number: Double = 250
    /// Matched for CONTAINS.
    var text: String = ""

    /// Legacy single-scope decoding (pre-multi-select files).
    private enum CodingKeys: String, CodingKey {
        case id, metric, scopes, scope, subsections, comparator, number, text
    }

    init(id: UUID = UUID(), metric: CheckMetric = .words,
         scopes: [CheckScope] = [CheckScope(kind: .abstract)],
         subsections: [String] = [],
         comparator: CheckComparator = .atMost, number: Double = 250, text: String = "") {
        self.id = id; self.metric = metric; self.scopes = scopes
        self.subsections = subsections
        self.comparator = comparator; self.number = number; self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        metric = try c.decodeIfPresent(CheckMetric.self, forKey: .metric) ?? .words
        if let list = try c.decodeIfPresent([CheckScope].self, forKey: .scopes) {
            scopes = list
        } else if let single = try c.decodeIfPresent(CheckScope.self, forKey: .scope) {
            scopes = [single]
        } else {
            scopes = [CheckScope(kind: .abstract)]
        }
        subsections = try c.decodeIfPresent([String].self, forKey: .subsections) ?? []
        comparator = try c.decodeIfPresent(CheckComparator.self, forKey: .comparator) ?? .atMost
        number = try c.decodeIfPresent(Double.self, forKey: .number) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(metric, forKey: .metric)
        try c.encode(scopes, forKey: .scopes)
        if !subsections.isEmpty { try c.encode(subsections, forKey: .subsections) }
        try c.encode(comparator, forKey: .comparator)
        try c.encode(number, forKey: .number)
        if !text.isEmpty { try c.encode(text, forKey: .text) }
    }

    /// "Introduction (4)" — the first scope and how many there are.  Naming
    /// every one runs long enough to swamp the rule it belongs to; the
    /// failure detail spells out the full addition anyway.
    var scopeLabel: String {
        if metric.isFormat { return "Export" }
        if metric.isStructure { return "Structure" }
        let names = scopes.map(\.label)
        guard let first = names.first else { return "nothing selected" }
        let base = names.count == 1 ? first : "\(first) (\(names.count))"
        return subsections.isEmpty ? base : "\(base) › \(subsections.joined(separator: ", "))"
    }

    /// "Abstract + Introduction LENGTH (words) ≤ 250"
    var summary: String {
        switch metric {
        case .structure: return "Sections match the journal's structure"
        case .exists:   return "\(scopeLabel) EXISTS"
        case .contains: return "\(scopeLabel) CONTAINS \"\(text)\""
        case .lineNumbers:
            return "Export line numbers \(number >= 1 ? "on" : "off")"
        default:
            let n = number.rounded() == number ? String(Int(number)) : String(number)
            return "\(scopeLabel) \(metric.label) \(comparator.label) \(n)"
        }
    }
}

// MARK: - CheckRule

struct CheckRule: Codable, Identifiable, Sendable, Equatable {

    enum Combinator: String, Codable, CaseIterable, Sendable {
        case all = "ALL"
        case any = "ANY"
        var label: String { self == .all ? "all of" : "any of" }
    }

    var id: UUID = UUID()
    /// Shown in the checklist; blank falls back to the conditions.
    var name: String = ""
    /// Optional for backward-compatible decoding; nil = enabled.
    var enabled: Bool? = nil
    var combinator: Combinator = .all
    var conditions: [CheckCondition] = [CheckCondition()]
    /// Guidance shown under a failure.
    var note: String? = nil
    /// A rule the app can't evaluate — it renders as a checkbox the user
    /// ticks after verifying by hand.  Manual checks are just checks, in
    /// the same list and the same editor.  nil = automatic.
    var manual: Bool? = nil

    var isEnabled: Bool { enabled ?? true }
    var isManual: Bool { manual ?? false }

    var displayName: String {
        if !name.isEmpty { return name }
        if isManual { return "Manual check" }
        guard !conditions.isEmpty else { return "Empty rule" }
        let joiner = combinator == .all ? " AND " : " OR "
        return conditions.map(\.summary).joined(separator: joiner)
    }

    /// Every scope this rule touches — the panes it can color.  Deduplicated:
    /// a rule with four conditions over the abstract is ONE failure there, and
    /// a pane's failure count has to say one.
    var scopeKeys: [String] {
        var seen: Set<String> = []
        return conditions.flatMap { $0.scopes.map(\.key) }.filter { seen.insert($0).inserted }
    }

    /// Hand-written profile files shouldn't have to invent UUIDs, so every
    /// field but the conditions has a sensible default on decode.
    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, combinator, conditions, note, manual
    }

    init(id: UUID = UUID(), name: String = "", enabled: Bool? = nil,
         combinator: Combinator = .all, conditions: [CheckCondition] = [CheckCondition()],
         note: String? = nil, manual: Bool? = nil) {
        self.id = id; self.name = name; self.enabled = enabled
        self.combinator = combinator; self.conditions = conditions
        self.note = note; self.manual = manual
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        combinator = try c.decodeIfPresent(Combinator.self, forKey: .combinator) ?? .all
        conditions = try c.decodeIfPresent([CheckCondition].self, forKey: .conditions) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        manual = try c.decodeIfPresent(Bool.self, forKey: .manual)
    }

    static func newRule() -> CheckRule {
        CheckRule(name: "", conditions: [CheckCondition()])
    }

    static func newManual() -> CheckRule {
        CheckRule(name: "", conditions: [], manual: true)
    }
}
