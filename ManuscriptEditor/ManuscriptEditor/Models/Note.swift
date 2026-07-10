// Note.swift
//
// First-class feedback anchored to content — for oneself or collaborators.
//
// ANCHORING
// ─────────────────────────────────────────────────────────────────────────────
// A note is anchored to a specific content item within a specific version by two
// stable string keys:
//   • `versionKey` — the `VersionRef.id` ("source" or a version UUID string).
//   • `itemKey`    — the `SidebarItem.notesKey` ("abstract", "figures",
//                    "section:<uuid>", …).
//
// This element-level anchoring is intentionally simple and stable across edits.
// A future revision can add prose text-range anchoring (highlight-to-comment);
// the model is kept minimal so that extension is additive.
//
// Notes live at the top level of `Manuscript` (not inside a version's content
// snapshot), so they persist independently of versioning.

import Foundation

struct Note: Codable, Identifiable, Sendable, Equatable {

    /// Stable unique identifier.
    var id: UUID

    /// The version this note belongs to (`VersionRef.id`).
    var versionKey: String

    /// The content item this note is attached to (`SidebarItem.notesKey`).
    var itemKey: String

    /// The note text.
    var body: String

    /// Display name of whoever wrote the note.
    var author: String

    /// When the note was created.
    var createdAt: Date

    /// Whether the note has been marked resolved.
    var resolved: Bool

    // MARK: - Factory

    static func new(versionKey: String, itemKey: String, author: String, body: String = "") -> Note {
        Note(
            id: UUID(),
            versionKey: versionKey,
            itemKey: itemKey,
            body: body,
            author: author,
            createdAt: Date(),
            resolved: false
        )
    }
}
