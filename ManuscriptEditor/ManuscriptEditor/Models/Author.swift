// Author.swift
//
// Represents one author on a manuscript.  Authors are ordered (first author, last author,
// etc.) and the user can reorder them by dragging rows in AuthorsView.

import Foundation

/// All the information the app tracks for a single manuscript author.
///
/// Most journal submission systems require names, institutional affiliations, contact
/// email, and ORCID identifiers.  This struct captures all of those.
struct Author: Codable, Identifiable, Sendable {

    /// Stable unique identifier.  Used by SwiftUI's `ForEach` to track rows efficiently.
    var id: UUID

    /// Author's given / first name.
    var firstName: String

    /// Author's family / last name.
    var lastName: String

    /// Contact email address — required for the corresponding author.
    var email: String

    /// List of institutional affiliations (department + institution).
    /// An author can have more than one (e.g. dual appointments).
    var affiliations: [String]

    /// Whether this author is the one journals should contact for revisions.
    /// Typically shown with a star or envelope symbol in author lists.
    var isCorresponding: Bool

    /// ORCID persistent researcher identifier, formatted as 0000-0000-0000-0000.
    /// Many journals now require or strongly recommend this.
    var orcid: String

    /// Zero-based position in the author list.  First author = 0.
    var order: Int

    /// Public signing keys (base64 P-256) tied to this author — 0 to many.
    /// When an edit/comment's signature matches one of these keys, the UI
    /// shows this author's name (with a verified badge) instead of the raw
    /// signer name.  Private keys never enter manuscript files.
    /// Legacy field: entries here are treated as **local** identities; richer
    /// ties live in `signatureInfos`.
    var publicKeys: [String]? = nil

    /// Richer key ties: each carries the identity type (local / github /
    /// gitlab / openpgp) and handle, so badges can distinguish
    /// remote-anchored identities (✓) from unverifiable local ones (?).
    var signatureInfos: [AuthorSignature]? = nil

    // MARK: - Computed

    /// "First Last" — used in export and overview display.
    var fullName: String { "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces) }

    /// "Last, First" — conventional format for reference lists and author lines.
    var displayName: String { lastName.isEmpty ? firstName : "\(lastName), \(firstName)" }

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

/// One signing key tied to an author, with the identity that anchors it.
struct AuthorSignature: Codable, Sendable, Equatable {
    /// The app's P-256 public key (base64) that actually signs activity.
    var publicKey: String
    /// "local" | "github" | "gitlab" | "openpgp" (IdentityType raw values).
    var type: String
    /// Username (github/gitlab) or email (openpgp); nil for local.
    var handle: String?
    /// Whether the remote GPG key check passed when the tie was made.
    var verified: Bool?
}
