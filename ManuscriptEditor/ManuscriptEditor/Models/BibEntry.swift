// BibEntry.swift
//
// A single bibliographic reference (journal article, book, website, etc.).
// The app stores references in a BibTeX-inspired format — each entry has a
// citation key (like "Smith2023") that will eventually be used for in-text citations.

import Foundation

/// The publication type of a bibliographic entry.
/// Used to group references in the Bibliography view and to guide export formatting.
enum BibEntryType: String, Codable, CaseIterable, Sendable {
    case article      = "Journal Article"
    case book         = "Book"
    case bookChapter  = "Book Chapter"
    case conference   = "Conference Paper"
    case thesis       = "Thesis"
    case preprint     = "Preprint"
    case website      = "Website"
    case other        = "Other"
}

/// All the fields needed to represent and cite one publication.
///
/// Field names follow BibTeX conventions so the data can be exported to `.bib` files
/// in Phase 2.  Only `id`, `key`, `type`, `authors`, and `title` are always required;
/// all other fields are optional because not every publication type needs them.
struct BibEntry: Codable, Identifiable, Sendable, Equatable {

    /// Stable unique identifier used to track the entry across saves.
    var id: UUID

    /// The short citation key the user types in the text to reference this work
    /// (e.g. "Smith2023", "Jones_et_al_2021").  Must be unique within the manuscript.
    var key: String

    /// Publication category — drives how the entry is formatted on export.
    var type: BibEntryType

    /// Author names in "Last, First" format, one string per author.
    /// Example: `["Smith, John", "Doe, Jane"]`
    var authors: [String]

    /// Full title of the paper, book, or other work.
    var title: String

    /// Four-digit publication year (e.g. 2023).  `nil` if unknown or forthcoming.
    var year: Int?

    /// Journal name (for articles) or publisher name (for books).
    var journal: String?

    /// Volume number of the journal issue.
    var volume: String?

    /// Issue / number within the volume.
    var issue: String?

    /// Page range, e.g. "123–145" or "e0012345".
    var pages: String?

    /// Digital Object Identifier, e.g. "10.1000/xyz123".  Used to generate URLs.
    var doi: String?

    /// Direct URL if no DOI is available.
    var url: String?

    /// Publisher name (used for books and book chapters).
    var publisher: String?

    /// Book title when this entry is a chapter inside a larger edited volume.
    var booktitle: String?

    /// Free-form notes visible only in the app (not exported to the paper).
    var note: String?

    /// If imported from Zotero, the source item key — the first rung of the
    /// link-matching ladder (key > DOI > title+authors > URL).  `nil` for
    /// manual entries; matches found by the lower rungs are NEVER written
    /// back here — the link resolves dynamically each time.
    var zoteroKey: String? = nil

    /// Whether a Zotero-imported entry is locked to its library record
    /// (read-only in ME; refreshable).  nil = locked when `zoteroKey` is
    /// set — the historical behavior; unlocking makes it a normal entry.
    var zoteroLocked: Bool? = nil

    var isZoteroLocked: Bool { zoteroLocked ?? (zoteroKey != nil) }

    /// Legacy single-style formatted entry (superseded by `formatted`;
    /// still decoded and consulted for files from the first iteration).
    var formattedReference: String? = nil
    var formattedStyle: String? = nil

    /// CSL style id → the reference formatted by Zotero's citation
    /// processor (csl-entry inner HTML — only <i> markup matters), pulled
    /// per style by "Refresh from Zotero".  Exports pick their style here.
    var formatted: [String: String]? = nil

    /// Hand-written export text.  When `useFormattedOverride` is on, this
    /// exact text exports (any style) and refresh never touches it.
    var formattedOverride: String? = nil
    /// Off by default — the toggle lives in the reference editor.
    var useFormattedOverride: Bool? = nil

    var isOverrideActive: Bool {
        useFormattedOverride == true
            && !(formattedOverride ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The cached formatted entry for a style, folding in the legacy fields.
    func formattedEntry(for style: String) -> String? {
        if let hit = formatted?[style], !hit.isEmpty { return hit }
        if formattedStyle == style, let legacy = formattedReference, !legacy.isEmpty { return legacy }
        return nil
    }

    // MARK: - Computed display helpers

    /// Up to the first three authors joined by "; ", with "et al." appended when
    /// there are four or more — the standard abbreviated citation format.
    var authorsFormatted: String {
        let names = authors.prefix(3).joined(separator: "; ")
        return authors.count > 3 ? "\(names); et al." : names
    }

    /// Very short "Author (Year)" string for use inside sentences.
    var shortCitation: String {
        let firstLast = authors.first?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
        let y = year.map(String.init) ?? "n.d."
        return "\(firstLast) (\(y))"
    }

    // MARK: - Factory

    /// Returns a blank entry pre-populated with the current year and a single empty author slot.
    static func empty() -> BibEntry {
        BibEntry(
            id: UUID(),
            key: "",
            type: .article,
            authors: [""],
            title: "",
            year: Calendar.current.component(.year, from: Date()),
            journal: nil, volume: nil, issue: nil, pages: nil,
            doi: nil, url: nil, publisher: nil, booktitle: nil, note: nil
        )
    }
}
