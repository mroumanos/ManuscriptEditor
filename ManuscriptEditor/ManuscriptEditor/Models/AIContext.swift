// AIContext.swift
//
// The context a manuscript gives an AI: what the app is, what this manuscript
// contains, and whatever else the user chooses to add.
//
// EVERY ROW HAS A CHECKBOX, AND THAT IS THE POINT
// ─────────────────────────────────────────────────────────────────────────────
// A researcher's unpublished manuscript is not something to hand to a model by
// default and explain later.  The table is the place they decide, row by row,
// what leaves the machine — and unticking a row means it is not in the payload
// at all, enforced where the payload is built rather than in the view.
//
// One row is locked: the primer describing how Manuscript Editor is put
// together.  It carries no user content, and a model that doesn't know what a
// "cut" or a "check" is will produce confident nonsense — so it is always on
// and not editable.  Everything else is the user's to add, edit, and remove.
//
// See MasterContext/11-ai-integration.md §4.

import Foundation

// MARK: - Kind

enum AIContextKind: String, Codable, Sendable {
    /// How the app works.  Generated from the app, locked, always sent.
    case appPrimer
    /// This manuscript's own content.  Deselectable — the privacy decision.
    case manuscriptData
    /// Free text the user wrote.
    case freeText
    /// A file the user attached, copied into `context/`.
    case file

    var label: String {
        switch self {
        case .appPrimer:      return "How Manuscript Editor works"
        case .manuscriptData: return "This manuscript"
        case .freeText:       return "Note"
        case .file:           return "File"
        }
    }

    var systemImage: String {
        switch self {
        case .appPrimer:      return "info.circle"
        case .manuscriptData: return "doc.text"
        case .freeText:       return "text.alignleft"
        case .file:           return "paperclip"
        }
    }

    /// The built-in rows can't be deleted or renamed; they're regenerated.
    var isBuiltIn: Bool { self == .appPrimer || self == .manuscriptData }

    /// A fixed identity for the built-in rows.
    ///
    /// They are regenerated on every read until the list is first written, so a
    /// fresh `UUID()` each time would change the id under the checkbox the user
    /// just clicked — unticking "This manuscript" on a manuscript whose context
    /// had never been edited silently did nothing, which is the one failure this
    /// table cannot have.  It also stops `ForEach` rebuilding the table on every
    /// update pass.
    var builtInID: UUID? {
        switch self {
        case .appPrimer:      return UUID(uuidString: "8A17B1C0-0000-4000-A000-000000000001")
        case .manuscriptData: return UUID(uuidString: "8A17B1C0-0000-4000-A000-000000000002")
        case .freeText, .file: return nil
        }
    }
}

// MARK: - Entry

struct AIContextEntry: Identifiable, Codable, Sendable, Equatable {

    var id: UUID = UUID()
    var kind: AIContextKind
    var title: String = ""

    /// Unticked = never sent.  The whole table exists for this flag.
    var isEnabled: Bool = true

    /// Free-text body.
    var body: String = ""

    /// File name inside the manuscript's `context/` folder.
    var fileName: String? = nil

    var updatedAt: Date? = nil

    init(kind: AIContextKind, title: String = "", body: String = "",
         fileName: String? = nil, isEnabled: Bool = true) {
        self.id = kind.builtInID ?? UUID()
        self.kind = kind
        self.title = title.isEmpty ? kind.label : title
        self.body = body
        self.fileName = fileName
        self.isEnabled = isEnabled
    }

    /// The primer is generated, so it is never editable and never deletable.
    var isLocked: Bool { kind == .appPrimer }
    /// The manuscript row is generated too, but switching it off is the whole
    /// privacy control, so it stays selectable.
    var isEditable: Bool { !kind.isBuiltIn }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, isEnabled, body, fileName, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(AIContextKind.self, forKey: .kind) ?? .freeText
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? kind.builtInID ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? kind.label
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

// MARK: - The primer

/// What the app is, in the app's own words.
///
/// Held as a constant rather than a stored row so it tracks the app across
/// releases instead of going stale inside somebody's manuscript. It describes
/// STRUCTURE only — never the user's content.
enum AIContextPrimer {

    static let title = "How Manuscript Editor works"

    static let text = """
    Manuscript Editor is a macOS app for writing one scientific manuscript and \
    adapting it into journal-specific copies.

    - SOURCE is the root version of the manuscript. Each target journal gets a \
    CUT: its own copy of the same content, adapted to that journal's rules. \
    Cuts never change the underlying data, only how it is presented.
    - A manuscript is made of COMPONENTS: title, authors (with institution \
    affiliations, numbered by superscript), abstract, keywords, body SECTIONS, \
    figures, tables, a bibliography, and a cover letter. A section is either \
    prose or a QUESTION SERIES — the questions a journal asks at submission, \
    each with its own answer and word limit.
    - Every journal carries a PROFILE in three parts: REQUIREMENTS (its \
    published instructions, as bullets), STRUCTURE (the sections a submission \
    should have), and CHECKS (machine-evaluated rules — word and count limits, \
    required sections, export formatting). Checks are what decide whether a cut \
    is ready to submit.
    - VERSIONS are save points inside one journal; LINEAGE records that one \
    journal's version was derived from another's, and a FAST-FORWARD re-derives \
    a downstream cut from a newer upstream version.
    - DATA lives once, centrally, and figures and tables reference it by SQL \
    rather than copying it.

    When adapting content for a journal, respect that journal's checks and \
    limits exactly, and change presentation rather than meaning.
    """
}

// MARK: - Bundle

/// The context actually sent with a request.
///
/// Built from the enabled rows only. Disabled rows are dropped **here**, at the
/// single point where a payload is assembled, so no caller can forget to honour
/// a checkbox.
struct AIContextBundle {

    struct Piece {
        let title: String
        let text: String
    }

    let pieces: [Piece]

    /// Rows the user switched off, named so the UI can say what was withheld.
    let excludedTitles: [String]

    /// Assembles the bundle for a manuscript.
    ///
    /// `fileText` resolves an attached file to text; it returns nil for
    /// anything unreadable, which is dropped rather than sent as noise.
    /// `includeSectionText` is false when the *intent* is already sending the
    /// sections — a fast-forward puts every section in its own payload, and
    /// repeating them in the context doubles a manuscript-sized prompt for
    /// nothing, which costs minutes on a long run.  The manuscript row still
    /// goes (title, authors, abstract, journals, and each section's title and
    /// length), so the model still knows the shape of the paper.
    static func build(entries: [AIContextEntry],
                      manuscript: Manuscript?,
                      fileText: (String) -> String?,
                      includeSectionText: Bool = true) -> AIContextBundle {
        var pieces: [Piece] = []
        var excluded: [String] = []

        for entry in entries {
            guard entry.isEnabled else { excluded.append(entry.title); continue }
            switch entry.kind {
            case .appPrimer:
                pieces.append(Piece(title: AIContextPrimer.title, text: AIContextPrimer.text))
            case .manuscriptData:
                if let manuscript,
                   let text = manuscriptSummary(manuscript, includeSectionText: includeSectionText) {
                    pieces.append(Piece(title: "This manuscript", text: text))
                }
            case .freeText:
                let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { pieces.append(Piece(title: entry.title, text: body)) }
            case .file:
                if let name = entry.fileName, let text = fileText(name),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pieces.append(Piece(title: entry.title, text: text))
                }
            }
        }
        return AIContextBundle(pieces: pieces, excludedTitles: excluded)
    }

    /// Renders as prompt text: a labelled block per piece, in table order.
    var promptText: String {
        pieces.map { "## \($0.title)\n\n\($0.text)" }.joined(separator: "\n\n")
    }

    var isEmpty: Bool { pieces.isEmpty }

    /// A rough size, so the UI can warn before a payload gets silly.
    var characterCount: Int { pieces.reduce(0) { $0 + $1.text.count } }

    /// The manuscript as structured text: what it contains and how it is
    /// shaped, including each journal's limits, since that is what an
    /// adaptation has to satisfy.
    private static func manuscriptSummary(_ m: Manuscript,
                                          includeSectionText: Bool = true) -> String? {
        var lines: [String] = []
        let title = (m.articleTitle?.isEmpty == false ? m.articleTitle! : m.title)
        if !title.isEmpty { lines.append("Title: \(title)") }
        if let subtitle = m.subtitle, !subtitle.isEmpty { lines.append("Subtitle: \(subtitle)") }
        if !m.authors.isEmpty {
            lines.append("Authors: " + m.authors.sorted { $0.order < $1.order }
                            .map(\.fullName).joined(separator: "; "))
        }
        if !m.keywords.isEmpty { lines.append("Keywords: " + m.keywords.joined(separator: ", ")) }
        let abstract = m.abstract.plain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !abstract.isEmpty { lines.append("\nAbstract:\n\(abstract)") }

        let sections = m.sections.filter { $0.active && !$0.isEmptyContent }
            .sorted { $0.order < $1.order }
        if !sections.isEmpty {
            lines.append("\nSections:")
            for section in sections {
                lines.append("\n### \(section.title) (\(section.wordCount) words)")
                if includeSectionText { lines.append(section.plainText) }
            }
        }
        if !m.figures.isEmpty || !m.tables.isEmpty || !m.bibliography.isEmpty {
            lines.append("\nAssets: \(m.figures.count) figures, \(m.tables.count) tables, "
                         + "\(m.bibliography.count) references")
        }
        if !m.journals.isEmpty {
            lines.append("\nTarget journals:")
            for journal in m.journals {
                var detail = "- \(journal.displayName)"
                if let checks = journal.checkRules, !checks.isEmpty {
                    detail += " — checks: " + checks.prefix(8).map(\.displayName).joined(separator: "; ")
                }
                lines.append(detail)
            }
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
