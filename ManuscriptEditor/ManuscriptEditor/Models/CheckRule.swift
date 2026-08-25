// CheckRule.swift
//
// Configurable submission checks.
//
// The built-in checks derive from `JournalRequirements` and are fixed: they
// know how to repair themselves (the typography Fix), and they seed the
// export.  This file adds the OTHER kind — rules the user writes, in a small
// vocabulary that covers what journals actually ask for:
//
//   LENGTH(words|characters) of a scope   ≤ ≥ = ≠   a number
//   COUNT of a collection scope           ≤ ≥ = ≠   a number
//   EXISTS a scope                        (with content)
//   CONTAINS a scope                      some text
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

    var label: String {
        switch self {
        case .words:      return "LENGTH (words)"
        case .characters: return "LENGTH (characters)"
        case .count:      return "COUNT"
        case .exists:     return "EXISTS"
        case .contains:   return "CONTAINS"
        }
    }

    /// Whether the condition compares against a number (else text, or
    /// nothing at all for EXISTS).
    var takesNumber: Bool {
        switch self {
        case .words, .characters, .count: return true
        case .exists, .contains:          return false
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
    var scope: CheckScope = CheckScope(kind: .abstract)
    var comparator: CheckComparator = .atMost
    /// Compared against for numeric metrics.
    var number: Double = 250
    /// Matched for CONTAINS.
    var text: String = ""

    /// "Abstract LENGTH (words) ≤ 250"
    var summary: String {
        switch metric {
        case .exists:   return "\(scope.label) EXISTS"
        case .contains: return "\(scope.label) CONTAINS \"\(text)\""
        default:
            let n = number.rounded() == number ? String(Int(number)) : String(number)
            return "\(scope.label) \(metric.label) \(comparator.label) \(n)"
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

    var isEnabled: Bool { enabled ?? true }

    var displayName: String {
        if !name.isEmpty { return name }
        guard !conditions.isEmpty else { return "Empty rule" }
        let joiner = combinator == .all ? " AND " : " OR "
        return conditions.map(\.summary).joined(separator: joiner)
    }

    /// Every scope this rule touches — the panes it can color.
    var scopeKeys: [String] { conditions.map(\.scope.key) }

    static func newRule() -> CheckRule {
        CheckRule(name: "", conditions: [CheckCondition()])
    }
}
