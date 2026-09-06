// ManuscriptSection.swift
//
// A single named section of the manuscript body — Introduction, Methods, Results, etc.
// The user can reorder, rename, and add custom sections beyond the defaults.

import Foundation

/// The well-known section types that appear in most scientific manuscripts.
///
/// Using an enum (rather than free-form strings) lets the app enforce required-section
/// checks in `ChecklistService`, show appropriate icons, and seed new manuscripts with
/// the canonical IMRAD structure.
enum SectionType: String, Codable, CaseIterable, Hashable, Sendable {
    case introduction    = "Introduction"
    case methods         = "Methods"
    case results         = "Results"
    case discussion      = "Discussion"
    case conclusion      = "Conclusion"
    case acknowledgments = "Acknowledgments"
    case supplementary   = "Supplementary Materials"
    /// Free-form section with a user-supplied title.
    case custom          = "Custom"

    /// The order in which these sections appear in a freshly created manuscript.
    static var defaultOrder: [SectionType] {
        [.introduction, .methods, .results, .discussion, .conclusion, .acknowledgments]
    }

    /// SF Symbol name used to represent each section type in the sidebar and toolbars.
    var systemImage: String {
        switch self {
        case .introduction:    return "doc.text"
        case .methods:         return "wrench.and.screwdriver"
        case .results:         return "chart.bar"
        case .discussion:      return "bubble.left.and.bubble.right"
        case .conclusion:      return "checkmark.circle"
        case .acknowledgments: return "hands.sparkles"
        case .supplementary:   return "paperclip"
        case .custom:          return "doc"
        }
    }
}

/// One named body section inside a manuscript (e.g. the Introduction).
///
/// Content is stored as plain text (Markdown is supported but not required).
/// The `order` field controls display position in the sidebar and export output.
struct ManuscriptSection: Codable, Identifiable, Sendable {

    /// Unique identifier — stable across renames and reordering.
    var id: UUID

    /// Which kind of section this is.  Drives the icon and required-section checklist.
    var type: SectionType

    /// Display name shown in the sidebar and as the section heading on export.
    /// For built-in types this defaults to the enum's raw value; for `custom` sections
    /// the user supplies their own title.
    var title: String

    /// The full prose content of this section (rich text).
    var content: RichText

    /// Zero-based position in the manuscript.  The sidebar and export use ascending order.
    var order: Int

    /// Whether this section is active in this version (journal).  A section exists
    /// in every version, but each version can **deactivate** it: a deactivated
    /// section is empty, uneditable, and excluded from Checks and Export.
    /// Defaults to `true`; decodes as `true` for older files that predate it.
    var active: Bool

    /// What this section holds.  A **text box** is prose, the original and
    /// still the default; a **question series** is a list of prompts a journal
    /// asks at submission ("Why is this an important submission?") each with
    /// its own answer and word limit.  Optional so files that predate the
    /// distinction decode as prose.
    var kind: SectionKind? = nil
    var sectionKind: SectionKind { kind ?? .text }

    /// The prompts, when this is a question series.  Prose sections leave it
    /// nil rather than empty, so the two are told apart on disk too.
    var questions: [QuestionEntry]? = nil

    /// The prompts in asked order.
    var orderedQuestions: [QuestionEntry] {
        (questions ?? []).sorted { $0.order < $1.order }
    }

    /// Everything this section contributes as plain text — the prose, or the
    /// questions and their answers.  Word limits, checks, and the comparison
    /// highlighting all read this rather than `content` directly.
    var plainText: String {
        switch sectionKind {
        case .text: return content.plain
        case .questions:
            return orderedQuestions
                .map { [$0.prompt, $0.response.plain].filter { !$0.isEmpty }.joined(separator: "\n") }
                .joined(separator: "\n\n")
        }
    }

    /// True when there is nothing in this section at all.
    var isEmptyContent: Bool {
        switch sectionKind {
        case .text:      return content.isEmpty
        case .questions: return orderedQuestions.allSatisfy { $0.isEmpty }
        }
    }

    /// Number of words in this section's content, computed on demand.
    var wordCount: Int { WordCountService.count(plainText) }

    // MARK: - Init

    init(id: UUID, type: SectionType, title: String, content: RichText, order: Int,
         active: Bool = true, kind: SectionKind? = nil, questions: [QuestionEntry]? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.order = order
        self.active = active
        self.kind = kind
        self.questions = questions
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case id, type, title, content, order, active, kind, questions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id      = try c.decode(UUID.self,        forKey: .id)
        type    = try c.decode(SectionType.self, forKey: .type)
        title   = try c.decode(String.self,      forKey: .title)
        content = try c.decode(RichText.self,    forKey: .content)
        order   = try c.decode(Int.self,         forKey: .order)
        active  = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        kind    = try c.decodeIfPresent(SectionKind.self, forKey: .kind)
        questions = try c.decodeIfPresent([QuestionEntry].self, forKey: .questions)
    }
}

// MARK: - SectionKind

/// Whether a section is prose or a list of submission questions.
enum SectionKind: String, Codable, CaseIterable, Sendable {
    case text, questions

    var label: String {
        switch self {
        case .text:      return "Text Box"
        case .questions: return "Question Series"
        }
    }

    var systemImage: String {
        switch self {
        case .text:      return "text.alignleft"
        case .questions: return "list.bullet.rectangle"
        }
    }
}

// MARK: - QuestionEntry

/// One question a journal asks at submission, with the answer and the limit
/// it imposes.
struct QuestionEntry: Codable, Identifiable, Sendable, Equatable {

    var id: UUID = UUID()

    /// The journal's question, verbatim.  Editable, because journals word
    /// these differently and revise them between cycles.
    var prompt: String = ""

    /// The answer.  Rich text like any other prose, so it carries the same
    /// formatting into the export.
    var response: RichText = RichText()

    /// The journal's cap on the answer, in words.  **Nullable**: plenty of
    /// questions have no limit, and inventing one would be a lie.
    var wordLimit: Int? = nil

    var order: Int = 0

    var responseWordCount: Int { WordCountService.count(response.plain) }

    /// True when the limit exists and the answer is past it.
    var isOverLimit: Bool {
        guard let wordLimit else { return false }
        return responseWordCount > wordLimit
    }

    /// "84 / 250", or just the count when the question has no limit.
    var countLabel: String {
        guard let wordLimit else { return "\(responseWordCount) words" }
        return "\(responseWordCount) / \(wordLimit)"
    }

    var isEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && response.isEmpty
    }
}
