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

    /// Number of words in this section's content, computed on demand.
    var wordCount: Int { WordCountService.count(content.plain) }

    // MARK: - Init

    init(id: UUID, type: SectionType, title: String, content: RichText, order: Int, active: Bool = true) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.order = order
        self.active = active
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey { case id, type, title, content, order, active }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id      = try c.decode(UUID.self,        forKey: .id)
        type    = try c.decode(SectionType.self, forKey: .type)
        title   = try c.decode(String.self,      forKey: .title)
        content = try c.decode(RichText.self,    forKey: .content)
        order   = try c.decode(Int.self,         forKey: .order)
        active  = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
    }
}
