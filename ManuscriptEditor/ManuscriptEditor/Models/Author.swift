// Author.swift
//
// Represents one author on a manuscript.  Authors are ordered (first author, last author,
// etc.) and the user can reorder them by dragging rows in AuthorsView.

import Foundation

/// One entry in the manuscript's institution registry (managed alongside
/// authors).  Authors affiliate by referencing these ids — a reference is
/// required for every author.
struct Institution: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    /// Institution name, e.g. "Harvard Medical School, Dept. of Genetics".
    var name: String
    /// Location parts — optional (older files decode without them); exports
    /// print "<institute> <city>, <state> <country>".
    var city: String? = nil
    var state: String? = nil
    var country: String? = nil

    /// The affiliation line as exports print it, skipping absent parts.
    var displayLine: String {
        var out = name
        if let city, !city.isEmpty { out += " \(city)" }
        if let state, !state.isEmpty { out += ", \(state)" }
        if let country, !country.isEmpty { out += " \(country)" }
        return out
    }

    static func empty() -> Institution { Institution(id: UUID(), name: "") }
}

/// All the information the app tracks for a single manuscript author.
///
/// Most journal submission systems require names, institutional affiliations, contact
/// email, and ORCID identifiers.  This struct captures all of those.
struct Author: Codable, Identifiable, Sendable, Equatable {

    /// Stable unique identifier.  Used by SwiftUI's `ForEach` to track rows efficiently.
    var id: UUID

    /// Author's given / first name.
    var firstName: String

    /// Author's family / last name.
    var lastName: String

    /// Middle name or initials ("M.", "van der").  Optional; decodes as nil
    /// from files written before Aug 2026 (issue #16).
    var middleName: String? = nil

    /// Honorific / title ("Dr.", "Prof.") — stored for correspondence; not
    /// printed in exported bylines.
    var namePrefix: String? = nil

    /// Academic degrees ("MD, PhD") — legacy free text, superseded by the
    /// ordered `titles` tags; still decoded so old files keep their byline.
    var degrees: String? = nil

    /// Free-form title tags ("MD", "PhD", "Professor"), kept in the order
    /// they were entered (Aug 2026).  Optional for backward-compatible
    /// decoding; nil = fall back to splitting `degrees`.
    var titles: [String]? = nil

    /// Postal address — required by some journals for the corresponding author.
    var address: String? = nil

    /// Contact email address — required for the corresponding author.
    var email: String

    /// List of institutional affiliations (department + institution).
    /// Legacy free text — new files reference the manuscript's institution
    /// registry via `institutionIDs` instead.
    var affiliations: [String]

    /// References into `Manuscript.institutions` — the required way to
    /// affiliate an author (every author must reference at least one).
    var institutionIDs: [UUID]? = nil

    /// Whether this author is the one journals should contact for revisions.
    /// Typically shown with a star or envelope symbol in author lists.
    var isCorresponding: Bool

    /// Free-text correspondence details (address, phone, preferred email
    /// line) shown when `isCorresponding` — referencable in prose as
    /// [[authors.corresponding_author.details]].  Optional for
    /// backward-compatible decoding.
    var correspondingDetails: String? = nil

    /// ORCID persistent researcher identifier, formatted as 0000-0000-0000-0000.
    /// Many journals now require or strongly recommend this.
    var orcid: String

    /// Zero-based position in the author list.  First author = 0.
    var order: Int

    // MARK: - Computed

    /// "First Middle Last" — used in export and overview display.
    var fullName: String {
        [firstName, middleName ?? "", lastName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Title tags in display order: the tag list when present, else the
    /// legacy `degrees` text split on commas.
    var effectiveTitles: [String] {
        if let titles { return titles.filter { !$0.isEmpty } }
        return (degrees ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Byline for exported documents: full name plus title tags ("Jane Q.
    /// Doe, MD, PhD").  The honorific prefix is deliberately excluded.
    var exportName: String {
        let t = effectiveTitles
        return t.isEmpty ? fullName : "\(fullName), \(t.joined(separator: ", "))"
    }

    /// "Last, First" — conventional format for reference lists and author lines.
    var displayName: String { lastName.isEmpty ? firstName : "\(lastName), \(firstName)" }

    /// Resolved affiliation names: registry references when present,
    /// otherwise the legacy free-text affiliations.
    func affiliationNames(in m: Manuscript) -> [String] {
        let resolved = (institutionIDs ?? []).compactMap { id in
            m.institutions.first(where: { $0.id == id })?.name
        }.filter { !$0.isEmpty }
        return resolved.isEmpty ? affiliations.filter { !$0.isEmpty } : resolved
    }

    /// Resolved affiliation display lines ("<institute> <city>, <state>
    /// <country>"): registry records when referenced, else legacy free text.
    func affiliationLines(in m: Manuscript) -> [String] {
        let resolved = (institutionIDs ?? []).compactMap { id in
            m.institutions.first(where: { $0.id == id })
        }.map(\.displayLine).filter { !$0.isEmpty }
        return resolved.isEmpty ? affiliations.filter { !$0.isEmpty } : resolved
    }

    /// True when the author lacks the required institution reference.
    func missingInstitution(in m: Manuscript) -> Bool {
        affiliationNames(in: m).isEmpty
    }

    // MARK: - Factory

    /// A blank author value ready for the user to fill in.
    /// `order` should be set to the author's intended position (0 = first author).
    static func empty(order: Int = 0) -> Author {
        Author(
            id: UUID(),
            firstName: "",
            lastName: "",
            email: "",
            affiliations: [""],   // start with one empty affiliation slot
            isCorresponding: false,
            orcid: "",
            order: order
        )
    }
}
