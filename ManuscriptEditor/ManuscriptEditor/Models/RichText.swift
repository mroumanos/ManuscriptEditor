// RichText.swift
//
// Rich-text storage for prose fields (abstract, body sections, cover-letter body).
//
// WHY A WRAPPER
// ─────────────────────────────────────────────────────────────────────────────
// Prose now supports bold/italic/underline/strikethrough, super/subscript,
// alignment, and bullet lists.  We persist that styling as RTF (`rtf`) — a
// stable, portable format that round-trips faithfully through NSAttributedString
// — while keeping a flattened `plain` mirror so word counts, Checks, and search
// stay cheap and never need to decode RTF.
//
// BACKWARD COMPATIBILITY
// ─────────────────────────────────────────────────────────────────────────────
// Older manuscripts stored these fields as a bare JSON string.  `init(from:)`
// detects that shape and loads it as unstyled text, so existing files open
// unchanged.

import Foundation

/// One reference token in a prose field — an in-text citation of a bibliography
/// entry, or a cross-reference to a figure or table.
///
/// Stored **in document order** on the owning `RichText` so numbering and
/// bibliography ordering never require decoding RTF: the editor extracts the
/// list whenever the styled text changes, and the store just concatenates the
/// arrays across the manuscript.
struct RefOccurrence: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case bib, figure, table
    }
    var kind: Kind
    var targetID: UUID
}

struct RichText: Codable, Sendable, Equatable {

    /// Flattened plain text.  Always kept in sync with `rtf`; used for word
    /// counts, Checks, search, and as the fallback when there is no styling.
    var plain: String

    /// RTF archive of the styled text.  `nil` means unstyled (use `plain`).
    var rtf: Data?

    /// Reference tokens embedded in the text, in document order.
    /// `nil` means "not yet extracted" (a pre-refs file); the store extracts
    /// from `rtf` once on load, after which the list is kept current by the
    /// editor.
    var refs: [RefOccurrence]?

    init(plain: String = "", rtf: Data? = nil, refs: [RefOccurrence]? = nil) {
        self.plain = plain
        self.rtf = rtf
        self.refs = refs
    }

    /// True when the text is empty or whitespace-only.
    var isEmpty: Bool {
        plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Codable (legacy-string tolerant)

    private enum CodingKeys: String, CodingKey { case plain, rtf, refs }

    init(from decoder: Decoder) throws {
        // Legacy: the whole field was a plain JSON string — unstyled, so it
        // cannot contain reference tokens ([] rather than "unknown").
        if let single = try? decoder.singleValueContainer(),
           let string = try? single.decode(String.self) {
            self.plain = string
            self.rtf = nil
            self.refs = []
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.plain = (try? c.decode(String.self, forKey: .plain)) ?? ""
        self.rtf = try? c.decodeIfPresent(Data.self, forKey: .rtf)
        self.refs = try? c.decodeIfPresent([RefOccurrence].self, forKey: .refs)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(plain, forKey: .plain)
        try c.encodeIfPresent(rtf, forKey: .rtf)
        try c.encodeIfPresent(refs, forKey: .refs)
    }
}
