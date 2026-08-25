// ViewConfig.swift
//
// A "View" is a user-defined template that describes how manuscript content
// should be arranged and formatted for a particular purpose (e.g., a journal
// submission, a preprint, a grant report).
//
// CONCEPT
// ─────────────────────────────────────────────────────────────────────────────
// One ViewConfig can contain multiple ViewDocuments.  This lets you split
// content across files — e.g.:
//   Document 1: Abstract + Introduction + Methods + Results + Discussion + Refs
//   Document 2: Figures + Tables (submitted separately)
//
// Each ViewDocument lists the manuscript sections it includes, in order.
// Each section entry (ViewSectionConfig) can override how that section is
// displayed: title rename, font, word limit, line spacing.
//
// The ViewConfig data feeds two things:
//   1. The "Checks" panel — compares live content against per-section word limits
//   2. Export (Phase 2) — renders the manuscript through this template to DOCX/PDF
//
// STORED IN APPSTORE
// ─────────────────────────────────────────────────────────────────────────────
// ViewConfigs live in AppStore (global) so they can be reused across manuscripts.
// A manuscript's active view is recorded in ManuscriptSettings.activeViewID.

import Foundation

// MARK: - ViewConfig

/// A named template describing how to lay out and export manuscript content.
struct ViewConfig: Codable, Identifiable, Sendable {

    /// Stable unique identifier.
    var id: UUID

    /// User-assigned name (e.g. "Nature Submission", "Double-blind preprint").
    var name: String

    /// One or more documents that make up this view.
    /// Most views have one; some journals require separate figure files.
    var documents: [ViewDocument]

    /// Name of the journal whose requirements this view was auto-generated
    /// from.  `nil` for views the user created by hand.  Used only to group
    /// views in the UI ("Journal views" vs "My views").
    var originJournalName: String?

    /// When this view config was created.
    var createdAt: Date

    // MARK: - Factory

    static func empty(name: String = "New View") -> ViewConfig {
        ViewConfig(
            id: UUID(),
            name: name,
            documents: [ViewDocument.default()],
            originJournalName: nil,
            createdAt: Date()
        )
    }

    /// Builds a view from a journal's submission requirements.
    ///
    /// Mapping rules:
    ///   • Sections — the journal's `requiredSections` in their canonical order,
    ///     or the default IMRAD set when the journal doesn't specify any.
    ///   • Export format — the first format the journal accepts, falling back
    ///     to DOCX.
    ///   • Separate figures — when required, a second "Figures & Tables"
    ///     document is added so figures export as their own file.
    ///
    /// Word limits stay at the journal level (enforced by ChecklistService);
    /// per-section limits remain editable on the generated view afterwards.
    static func from(journal: Journal) -> ViewConfig {
        let req = journal.requirements

        let sectionTypes: [SectionType] = req.requiredSections.isEmpty
            ? [.introduction, .methods, .results, .discussion, .conclusion]
            : req.requiredSections

        let exportFormat = req.allowedExportFormats.first ?? .docx

        // The journal's STRUCTURE file, when it has one, is what a cut starts
        // from: it names sections the typed `requiredSections` cannot express
        // ("Public Health Implications") and carries the journal's order.
        let structured = journal.structure?.textSections ?? []
        let mainSections: [ViewSectionConfig] = structured.isEmpty
            ? sectionTypes.enumerated().map { i, type in
                ViewSectionConfig(
                    id: UUID(),
                    sectionRef: .byType(type),
                    customTitle: nil,
                    fontStyle: "Serif",
                    wordLimit: nil,
                    lineSpacing: 1.5,
                    order: i
                )
              }
            : structured.enumerated().map { i, section in
                let type = SectionType.allCases.first {
                    $0.rawValue.lowercased() == section.title.lowercased()
                } ?? .custom
                return ViewSectionConfig(
                    id: UUID(),
                    sectionRef: .byType(type),
                    customTitle: type == .custom ? section.title : nil,
                    fontStyle: "Serif",
                    wordLimit: nil,
                    lineSpacing: 1.5,
                    order: i
                )
              }

        var documents = [
            ViewDocument(
                id: UUID(),
                name: "Main Manuscript",
                sections: mainSections,
                lineNumbering: false,
                exportFormat: exportFormat,
                order: 0
            )
        ]

        if req.requiresSeparateFigures {
            documents.append(
                ViewDocument(
                    id: UUID(),
                    name: "Figures & Tables",
                    sections: [],
                    lineNumbering: false,
                    exportFormat: exportFormat,
                    order: 1
                )
            )
        }

        return ViewConfig(
            id: UUID(),
            name: "\(journal.name.isEmpty ? "Journal" : journal.name) View",
            documents: documents,
            originJournalName: journal.name,
            createdAt: Date()
        )
    }
}

// MARK: - ViewDocument

/// One file within a view — e.g., "Main manuscript" or "Supplementary material".
struct ViewDocument: Codable, Identifiable, Sendable {

    /// Stable unique identifier.
    var id: UUID

    /// Label shown in the UI (e.g. "Main Paper", "Supplementary Figures").
    var name: String

    /// The manuscript sections included in this document, in display order.
    var sections: [ViewSectionConfig]

    /// Whether line numbers should appear in the exported document.
    var lineNumbering: Bool

    /// The file format this document exports to.
    var exportFormat: ExportFormat

    /// Position of this document within the parent ViewConfig.
    var order: Int

    // MARK: - Factory

    /// A default single document covering all standard IMRAD sections.
    static func `default`() -> ViewDocument {
        let sectionTypes: [SectionType] = [
            .introduction, .methods, .results, .discussion, .conclusion
        ]
        let sections = sectionTypes.enumerated().map { i, type in
            ViewSectionConfig(
                id: UUID(),
                sectionRef: .byType(type),
                customTitle: nil,
                fontStyle: "Serif",
                wordLimit: nil,
                lineSpacing: 1.5,
                order: i
            )
        }
        return ViewDocument(
            id: UUID(),
            name: "Main Manuscript",
            sections: sections,
            lineNumbering: false,
            exportFormat: .docx,
            order: 0
        )
    }
}

// MARK: - ViewSectionConfig

/// How one manuscript section appears in a given ViewDocument.
///
/// A section is referenced by either its canonical `SectionType` (for standard
/// IMRAD sections) or by a specific UUID (for user-created custom sections).
struct ViewSectionConfig: Codable, Identifiable, Sendable {

    /// Stable unique identifier for this config entry.
    var id: UUID

    /// Which manuscript section this entry refers to.
    var sectionRef: SectionRef

    /// Override for the section heading shown in the exported document.
    /// `nil` means use the manuscript section's own title.
    var customTitle: String?

    /// Font family for this section: "Serif", "Sans", or "Mono".
    var fontStyle: String

    /// Maximum words allowed in this section.
    /// `nil` = no limit.  Used by the Checks panel.
    var wordLimit: Int?

    /// Line spacing multiplier (e.g. 1.0 = single, 2.0 = double).
    var lineSpacing: Double

    /// Position of this section within the parent ViewDocument.
    var order: Int
}

// MARK: - SectionRef

/// Identifies a manuscript section in a view-independent way.
///
/// - `byType`: references the section by its canonical `SectionType`.
///    Works across all manuscripts that have that section type.
/// - `byID`: references a specific section by its UUID.
///    Used for user-created custom sections (type `.custom`) that need
///    to be identified precisely.
enum SectionRef: Codable, Hashable, Sendable {
    case byType(SectionType)
    case byID(UUID)

    // Manual Codable because Swift cannot auto-synthesize Codable for
    // enums with associated values that themselves have custom Codable conformances.
    private enum CodingKeys: String, CodingKey {
        case type, id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let type = try? c.decode(SectionType.self, forKey: .type) {
            self = .byType(type)
        } else {
            let id = try c.decode(UUID.self, forKey: .id)
            self = .byID(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .byType(let type): try c.encode(type, forKey: .type)
        case .byID(let id):     try c.encode(id,   forKey: .id)
        }
    }
}
