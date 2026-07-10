// LetterToEditor.swift
//
// The cover letter submitted alongside the manuscript.
//
// STRUCTURE
// ─────────────────────────────────────────────────────────────────────────────
// Most journals require a cover letter with three logical parts:
//
//   HEADER  — Identifies the sender: institution logo/icon, lab name, address.
//             In this model, `headerTitle` is the institution/lab name and
//             `headerIconName` is an SF Symbol for the icon at the top.
//
//   BODY    — The actual letter: why this journal, novelty summary, author
//             contributions, conflict of interest statement, etc.
//
//   SIGNATURE — Corresponding author's name, title, contact, institution.
//
// Stored on the `Manuscript` struct so it persists with the manuscript JSON.
// Each journal cut (Phase 2) will have its own letter adapted from this source.

import Foundation

/// The cover letter for a manuscript submission.
struct LetterToEditor: Codable, Sendable {

    // MARK: - Header

    /// SF Symbol name used as the institution/lab icon at the top of the letter.
    /// Defaults to a generic document icon; users can pick any SF Symbol.
    var headerIconName: String

    /// The institution or lab name shown in the header (e.g. "Harvard Medical School").
    var headerTitle: String

    /// Optional second line in the header — e.g. department name or address line.
    var headerSubtitle: String

    // MARK: - Body

    /// The main text of the cover letter (rich text).  Typically 3-5 paragraphs
    /// covering: why this journal was chosen, a brief novelty summary, conflict
    /// of interest / ethics statement, and suggested reviewers (if applicable).
    var body: RichText

    // MARK: - Signature

    /// The closing signature block.
    /// Convention:  "Sincerely,\n\nDr. Jane Smith\nProfessor of …\njane@example.edu"
    var signature: String

    // MARK: - Factory

    /// A blank letter with sensible placeholder defaults.
    static func empty() -> LetterToEditor {
        LetterToEditor(
            headerIconName: "building.columns",
            headerTitle: "",
            headerSubtitle: "",
            body: RichText(),
            signature: ""
        )
    }
}
