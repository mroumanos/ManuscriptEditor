// LetterToEditor.swift
//
// The cover letter submitted alongside the manuscript.
//
// STRUCTURE
// ─────────────────────────────────────────────────────────────────────────────
// Most journals require a cover letter with three logical parts:
//
//   HEADER  — Letterhead identifying the sender.  Three slots — left, center,
//             right — each holding an optional image (institution logo,
//             letterhead art) and freeform text (lab name, address, date).
//             Mirrors how real letterheads are laid out.
//
//   BODY    — The actual letter: why this journal, novelty summary, author
//             contributions, conflict of interest statement, etc.
//
//   SIGNATURE — Corresponding author's name, title, contact, institution.
//
// Stored on the `Manuscript` struct so it persists with the manuscript JSON.
// Each journal cut (Phase 2) will have its own letter adapted from this source.

import Foundation

/// One letterhead slot (left / center / right): an optional image above
/// optional freeform text.  Image data is embedded in the manuscript JSON —
/// logos are small and this keeps the letter self-contained.
/// One letterhead slot — an image OR text, never both.
///
/// A slot occupies one corner of the letterhead, and stacking a logo above a
/// line of type in the same corner is not what anyone means by "left" or
/// "right": setting one replaces the other, so a slot always renders exactly
/// one thing.
struct LetterHeaderSlot: Codable, Sendable, Equatable {

    private(set) var text: String = ""
    private(set) var imageData: Data? = nil

    var isEmpty: Bool { text.isEmpty && imageData == nil }

    /// True when this slot is showing an image rather than type.
    var isImage: Bool { imageData != nil }

    init(text: String = "", imageData: Data? = nil) {
        // A slot decoded from a file written when both could coexist keeps
        // the image: it is the deliberate choice of the two.
        self.imageData = imageData
        self.text = imageData == nil ? text : ""
    }

    mutating func setText(_ value: String) {
        text = value
        if !value.isEmpty { imageData = nil }
    }

    mutating func setImage(_ data: Data?) {
        imageData = data
        if data != nil { text = "" }
    }

    /// Editing binding for the text side — writing non-empty text clears any
    /// image, which is how one replaces the other.
    var editableText: String {
        get { text }
        set { setText(newValue) }
    }
}

/// The cover letter for a manuscript submission.
struct LetterToEditor: Codable, Sendable, Equatable {

    // MARK: - Header (three letterhead slots)

    var headerLeft: LetterHeaderSlot
    var headerCenter: LetterHeaderSlot
    var headerRight: LetterHeaderSlot

    var hasHeader: Bool {
        !(headerLeft.isEmpty && headerCenter.isEmpty && headerRight.isEmpty)
    }

    // MARK: - Body

    /// The main text of the cover letter (rich text).  Typically 3-5 paragraphs
    /// covering: why this journal was chosen, a brief novelty summary, conflict
    /// of interest / ethics statement, and suggested reviewers (if applicable).
    var body: RichText

    // MARK: - Signature

    /// The closing signature block.
    /// Convention:  "Sincerely,\n\nDr. Jane Smith\nProfessor of …\njane@example.edu"
    var signature: String

    /// A hand-drawn signature (PNG), rendered above the signature text.
    var signatureImageData: Data?

    // MARK: - Codable (backward compatible)

    // Pre-slot files stored `headerIconName` / `headerTitle` / `headerSubtitle`;
    // the title + subtitle migrate into the center slot on decode (the icon was
    // an SF Symbol, not user content — it is dropped).
    private enum CodingKeys: String, CodingKey {
        case headerLeft, headerCenter, headerRight
        case headerTitle, headerSubtitle           // legacy, read-only
        case body, signature, signatureImageData
    }

    init(headerLeft: LetterHeaderSlot = .init(),
         headerCenter: LetterHeaderSlot = .init(),
         headerRight: LetterHeaderSlot = .init(),
         body: RichText,
         signature: String,
         signatureImageData: Data? = nil) {
        self.headerLeft = headerLeft
        self.headerCenter = headerCenter
        self.headerRight = headerRight
        self.body = body
        self.signature = signature
        self.signatureImageData = signatureImageData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headerLeft   = try c.decodeIfPresent(LetterHeaderSlot.self, forKey: .headerLeft) ?? .init()
        headerCenter = try c.decodeIfPresent(LetterHeaderSlot.self, forKey: .headerCenter) ?? .init()
        headerRight  = try c.decodeIfPresent(LetterHeaderSlot.self, forKey: .headerRight) ?? .init()
        body         = try c.decodeIfPresent(RichText.self, forKey: .body) ?? RichText()
        signature    = try c.decodeIfPresent(String.self, forKey: .signature) ?? ""
        signatureImageData = try c.decodeIfPresent(Data.self, forKey: .signatureImageData)

        if headerCenter.isEmpty {
            let title    = try c.decodeIfPresent(String.self, forKey: .headerTitle) ?? ""
            let subtitle = try c.decodeIfPresent(String.self, forKey: .headerSubtitle) ?? ""
            headerCenter.setText([title, subtitle].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(headerLeft, forKey: .headerLeft)
        try c.encode(headerCenter, forKey: .headerCenter)
        try c.encode(headerRight, forKey: .headerRight)
        try c.encode(body, forKey: .body)
        try c.encode(signature, forKey: .signature)
        try c.encodeIfPresent(signatureImageData, forKey: .signatureImageData)
    }

    // MARK: - Factory

    /// A blank letter with sensible placeholder defaults.
    static func empty() -> LetterToEditor {
        LetterToEditor(body: RichText(), signature: "")
    }
}
