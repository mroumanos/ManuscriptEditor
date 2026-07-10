// ManuscriptVersion.swift
//
// A "version" (also called a "cut") is an adapted snapshot of the manuscript,
// targeted at a specific journal or rendered through a custom view.
//
// LINEAGE
// ─────────────────────────────────────────────────────────────────────────────
// Versions form a tree rooted at the Source manuscript:
//
//   Source
//   ├─ Nature cut          (parentID = nil)
//   │  └─ Science cut      (parentID = Nature cut)   ← branched from Nature,
//   └─ BMJ cut             (parentID = nil)             not from Source
//
// A version may be cut from Source (parentID == nil) or from any existing
// version (parentID == that version's id).  Cutting from a sibling that is
// already close to the target requirements avoids redoing the same adaptation
// work twice.
//
// Only leaf versions (those with no children) can be deleted, so the lineage
// never develops holes.
//
// VIEW BINDING
// ─────────────────────────────────────────────────────────────────────────────
// Every version has exactly one ViewConfig (referenced by `viewConfigID`):
//   • journal-based versions use the view auto-generated from the journal's
//     requirements (see ViewConfig.from(journal:)),
//   • custom versions use a user-created view picked at creation time.
//
// The manuscript-level `ManuscriptSettings.activeViewID` applies only to the
// Source version.

import Foundation

// MARK: - VersionRef

/// A reference to one comparable manuscript: the live Source, or a specific
/// cut version by id.  Used by the comparison tab bar and content panes so the
/// same content item (Authors, Introduction, …) can be rendered for each.
enum VersionRef: Hashable, Identifiable, Sendable {
    case source
    case version(UUID)

    var id: String {
        switch self {
        case .source:          return "source"
        case .version(let id): return id.uuidString
        }
    }
}

// MARK: - ManuscriptVersion

/// One adapted snapshot of the manuscript, positioned in the version lineage.
struct ManuscriptVersion: Codable, Identifiable, Sendable {

    /// Stable unique identifier.
    var id: UUID

    /// User-facing label, e.g. "Nature v1" or "resubmission-Mar-2026".
    var label: String

    /// The version this one was cut from.
    /// `nil` means it was cut directly from the Source manuscript.
    var parentID: UUID?

    /// The journal this version targets, if it is journal-based.
    /// `nil` for versions created from a custom view.
    var journalID: UUID?

    /// The view (layout/format template) tied 1-1 to this version.
    /// For journal-based versions this is the view auto-generated from the
    /// journal's requirements; for custom versions it is user-chosen.
    var viewConfigID: UUID?

    /// Sequential version number within the manuscript (shown as "v1", "v2", …).
    var number: Int

    /// Display name of whoever created this version.
    var author: String

    /// When this version was created.
    var createdAt: Date

    /// `updatedAt` of the content this version was cut from, so the user can
    /// see how far the parent has drifted since the cut was made.
    var sourceSnapshotDate: Date

    /// Free-text notes (e.g. what was changed for this cut).
    var notes: String

    /// The full adapted manuscript content. Self-contained so versions can be
    /// compared and exported independently. Its own `versions` array is always
    /// stripped to empty before storing — lineage lives only at the top level.
    var content: Manuscript

    /// Results of the requirements checklist last run against this version.
    var checklistResults: [ChecklistResult]

    // MARK: - Init

    init(id: UUID, label: String, parentID: UUID?, journalID: UUID?, viewConfigID: UUID?,
         number: Int, author: String, createdAt: Date, sourceSnapshotDate: Date,
         notes: String, content: Manuscript, checklistResults: [ChecklistResult]) {
        self.id = id; self.label = label; self.parentID = parentID
        self.journalID = journalID; self.viewConfigID = viewConfigID
        self.number = number; self.author = author
        self.createdAt = createdAt; self.sourceSnapshotDate = sourceSnapshotDate
        self.notes = notes; self.content = content; self.checklistResults = checklistResults
    }

    // MARK: - Backward-compatible Codable
    // `number` and `author` were added later; decode as defaults for older files.

    private enum CodingKeys: String, CodingKey {
        case id, label, parentID, journalID, viewConfigID, number, author,
             createdAt, sourceSnapshotDate, notes, content, checklistResults
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try c.decode(UUID.self, forKey: .id)
        label              = try c.decode(String.self, forKey: .label)
        parentID           = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        journalID          = try c.decodeIfPresent(UUID.self, forKey: .journalID)
        viewConfigID       = try c.decodeIfPresent(UUID.self, forKey: .viewConfigID)
        number             = try c.decodeIfPresent(Int.self, forKey: .number) ?? 1
        author             = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        createdAt          = try c.decode(Date.self, forKey: .createdAt)
        sourceSnapshotDate = try c.decode(Date.self, forKey: .sourceSnapshotDate)
        notes              = try c.decode(String.self, forKey: .notes)
        content            = try c.decode(Manuscript.self, forKey: .content)
        checklistResults   = try c.decode([ChecklistResult].self, forKey: .checklistResults)
    }

    // MARK: - Factory

    /// Creates a new version by snapshotting `content` (with nested versions
    /// stripped) under the given parent.
    static func cut(
        label: String,
        from content: Manuscript,
        parentID: UUID?,
        journalID: UUID?,
        viewConfigID: UUID?,
        number: Int,
        author: String
    ) -> ManuscriptVersion {
        var snapshot = content
        snapshot.versions = []   // lineage is stored only on the top-level manuscript
        snapshot.notes = []      // notes live only on the top-level manuscript
        return ManuscriptVersion(
            id: UUID(),
            label: label,
            parentID: parentID,
            journalID: journalID,
            viewConfigID: viewConfigID,
            number: number,
            author: author,
            createdAt: Date(),
            sourceSnapshotDate: content.updatedAt,
            notes: "",
            content: snapshot,
            checklistResults: []
        )
    }
}
