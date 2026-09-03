// ExportConfig.swift
//
// The per-journal **export outline**: which components go into which documents,
// in what order, with what page breaks, format, and file type.
//
// Every journal (and the Source) gets a sensible pre-configured outline that
// the user can modify in the Export pane: add/remove documents, add sections
// or page breaks within them, and set each document's typography (font, size,
// spacing, margins), layout (line numbers, single/two column) and file type
// (PDF, Word, RTF, LaTeX).
//
// See MasterContext 05-features M and the glossary term "Export outline".

import Foundation

// MARK: - ExportConfig

/// One journal's complete export specification: an ordered set of documents.
struct ExportConfig: Codable, Sendable, Equatable {
    var documents: [ExportDocument]

    /// The pre-configured outline for a journal (or the Source when nil):
    /// a main manuscript document, a separate figures document when the
    /// journal requires it, and a cover-letter document.
    static func standard(content: Manuscript, journal: Journal?) -> ExportConfig {
        let separateFigures = journal?.requirements.requiresSeparateFigures ?? false
        let fileType = ExportFileType.preferred(for: journal)

        var items: [ExportItem] = [
            // The outline leads with an explicit first Section (geometry
            // inherits the document defaults until touched).
            ExportItem(kind: .pageBreak),
            ExportItem(kind: .titlePage),
            ExportItem(kind: .authors),
            ExportItem(kind: .abstract),
            ExportItem(kind: .keywords),
            ExportItem(kind: .pageBreak),
        ]
        for section in content.sections.sorted(by: { $0.order < $1.order }) where section.active {
            items.append(ExportItem(kind: .section, sectionID: section.id))
        }
        items.append(ExportItem(kind: .pageBreak))
        items.append(ExportItem(kind: .references))
        if !separateFigures {
            items.append(ExportItem(kind: .pageBreak))
            items.append(ExportItem(kind: .figures))
            items.append(ExportItem(kind: .tables))
        }

        var documents = [ExportDocument(name: "Manuscript", fileType: fileType, items: items)]
        // Journal-add defaulting (Phase 2): the requirements seed the
        // document typography, and checks guard it from there.
        if let requirements = journal?.requirements {
            if let size = requirements.requiredFontSize { documents[0].format.fontSize = size }
            if let spacing = requirements.requiredLineSpacing { documents[0].format.lineSpacing = spacing }
            if let lines = requirements.requiresLineNumbers { documents[0].format.lineNumbers = lines }
        }
        if separateFigures {
            documents.append(ExportDocument(
                name: "Figures and Tables", fileType: fileType,
                items: [ExportItem(kind: .figures), ExportItem(kind: .pageBreak), ExportItem(kind: .tables)]
            ))
        }
        documents.append(ExportDocument(
            name: "Cover Letter", fileType: fileType,
            items: [ExportItem(kind: .coverLetter)]
        ))
        return ExportConfig(documents: documents)
    }
}

// MARK: - ExportDocument

/// One output file in the package: a name, a file type, a format, and the
/// ordered components (with explicit page breaks) it contains.
struct ExportDocument: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var name: String
    var fileType: ExportFileType = .pdf
    var format: ExportDocumentFormat = ExportDocumentFormat()
    var items: [ExportItem] = []
}

// MARK: - ExportDocumentFormat

/// Typography and layout for one export document.
struct ExportDocumentFormat: Codable, Sendable, Equatable {
    var fontFamily: ExportFontFamily = .times
    var fontSize: Double = 12
    /// Line-height multiple (1.0 single … 2.0 double).
    var lineSpacing: Double = 1.5
    /// Uniform page margins, in inches.
    var marginInches: Double = 1.0
    /// Continuous line numbers in the left margin (PDF and LaTeX output).
    var lineNumbers: Bool = false
    /// Page numbers centered in the bottom margin (PDF output).
    var pageNumbers: Bool = false
    /// Two-column body layout (IEEE-style; PDF and LaTeX output).
    var twoColumn: Bool = false

    init(fontFamily: ExportFontFamily = .times, fontSize: Double = 12,
         lineSpacing: Double = 1.5, marginInches: Double = 1.0,
         lineNumbers: Bool = false, pageNumbers: Bool = false, twoColumn: Bool = false) {
        self.fontFamily = fontFamily; self.fontSize = fontSize
        self.lineSpacing = lineSpacing; self.marginInches = marginInches
        self.lineNumbers = lineNumbers; self.pageNumbers = pageNumbers
        self.twoColumn = twoColumn
    }

    /// Every field decodes if present: a format saved before a setting
    /// existed must still open, and this is where new page furniture keeps
    /// landing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try c.decodeIfPresent(ExportFontFamily.self, forKey: .fontFamily) ?? .times
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 12
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1.5
        marginInches = try c.decodeIfPresent(Double.self, forKey: .marginInches) ?? 1.0
        lineNumbers = try c.decodeIfPresent(Bool.self, forKey: .lineNumbers) ?? false
        pageNumbers = try c.decodeIfPresent(Bool.self, forKey: .pageNumbers) ?? false
        twoColumn = try c.decodeIfPresent(Bool.self, forKey: .twoColumn) ?? false
    }
}

/// Font families offered for export documents (system-installed, no bundling).
enum ExportFontFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    // Declaration order = picker order.  Calibri/Cambria ship with
    // Microsoft Office, not macOS — call sites already fall back to the
    // system font when a family can't resolve, so listing them is safe
    // (journals ask for them constantly).
    case times, arial, helvetica, calibri, cambria, georgia, verdana,
         palatino, courier, system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .times:     return "Times New Roman"
        case .arial:     return "Arial"
        case .helvetica: return "Helvetica"
        case .calibri:   return "Calibri"
        case .cambria:   return "Cambria"
        case .georgia:   return "Georgia"
        case .verdana:   return "Verdana"
        case .palatino:  return "Palatino"
        case .courier:   return "Courier New"
        case .system:    return "System (San Francisco)"
        }
    }

    /// Compact name for the read-only summaries in the Export cards.
    var shortLabel: String {
        switch self {
        case .times:     return "Times"
        case .arial:     return "Arial"
        case .helvetica: return "Helvetica"
        case .calibri:   return "Calibri"
        case .cambria:   return "Cambria"
        case .georgia:   return "Georgia"
        case .verdana:   return "Verdana"
        case .palatino:  return "Palatino"
        case .courier:   return "Courier"
        case .system:    return "System"
        }
    }

    /// PostScript-resolvable family name; nil means the system font.
    var familyName: String? {
        switch self {
        case .times:     return "Times New Roman"
        case .arial:     return "Arial"
        case .helvetica: return "Helvetica"
        case .calibri:   return "Calibri"
        case .cambria:   return "Cambria"
        case .georgia:   return "Georgia"
        case .verdana:   return "Verdana"
        case .palatino:  return "Palatino"
        case .courier:   return "Courier New"
        case .system:    return nil
        }
    }
}

// MARK: - ExportFileType

/// Output file formats a document can be written as.
enum ExportFileType: String, Codable, CaseIterable, Identifiable, Sendable {
    case pdf, docx, rtf, latex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf:   return "PDF (.pdf)"
        case .docx:  return "Word (.docx)"
        case .rtf:   return "Rich Text (.rtf)"
        case .latex: return "LaTeX (.tex)"
        }
    }

    var ext: String {
        switch self {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .rtf: return "rtf"
        case .latex: return "tex"
        }
    }

    /// Maps a journal's first accepted submission format to a file type.
    static func preferred(for journal: Journal?) -> ExportFileType {
        switch journal?.requirements.allowedExportFormats.first {
        case .docx:  return .docx
        case .pdf:   return .pdf
        case .latex: return .latex
        case .rtf, .txt: return .rtf
        case nil:    return .pdf
        }
    }
}

// MARK: - ExportItem

/// One entry in a document's outline: a manuscript component or a page break.
struct ExportItem: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case titlePage, abstract, keywords, section, figures, tables,
             references, coverLetter, pageBreak
        /// The byline block (authors + affiliations), separate from the
        /// title since Aug 2026 so removing it makes a blind-review copy.
        /// Configs saved before then have no `.authors` item — `.titlePage`
        /// still renders the byline for those (see the renderers).
        case authors
    }

    var id: UUID = UUID()
    var kind: Kind
    /// The body section this item renders (only for `kind == .section`).
    var sectionID: UUID?

    /// User-renamed heading for this item in the exported document (click the
    /// name in the Export card to edit).  Export-level only — it does not
    /// rename the underlying manuscript section.  nil = the default title.
    var customTitle: String? = nil

    /// Whether this item's heading is printed in the exported document
    /// (toggle in the Export card).  Stored optional for backward-compatible
    /// decoding; nil = the kind's default — every kind prints its heading
    /// except the cover letter: a real letter to an editor doesn't carry a
    /// "Cover Letter" label (Jul 2026 beta feedback).
    var showTitle: Bool? = nil

    /// Resolved show/hide for the printed heading.
    var titleShown: Bool {
        get { showTitle ?? (kind != .coverLetter) }
        set { showTitle = newValue }
    }

    /// Formatting for the printed heading (bold/underline/centered/size),
    /// edited inline in the Export card when the heading is shown.  Stored
    /// optional for backward-compatible decoding; nil = the default look.
    struct HeadingStyle: Codable, Sendable, Equatable {
        var bold: Bool = true
        var underline: Bool = false
        var centered: Bool = false
        /// Italic heading.  Optional for backward-compatible decoding.
        var italic: Bool? = nil
        /// "left" | "center" | "right"; nil = the legacy `centered` flag
        /// decides.  Writers keep `centered` in sync when this is set.
        var alignment: String? = nil

        var italicOn: Bool { italic ?? false }
        var effectiveAlignment: String { alignment ?? (centered ? "center" : "left") }
        /// Print the heading in ALL CAPS.  Optional for backward-compatible
        /// decoding of already-saved styles.
        var allCaps: Bool? = nil
        /// Point-size delta over the document body font: 0 (S), 2 (M), 5 (L).
        /// Superseded by `pointSize` when that is set.
        var sizeDelta: Double = 2
        /// Absolute heading size in points (legacy typed entry); honored only
        /// when `level` is nil so pre-level documents keep their look.
        var pointSize: Double? = nil
        /// Word-style heading level (1–3) — the familiar replacement for the
        /// typed point size (Aug 2026).  Sizing comes from the document body
        /// font via `Self.sizeDelta(forLevel:)`.  Optional for
        /// backward-compatible decoding; nil = pointSize/sizeDelta rules.
        var level: Int? = nil

        var effectiveLevel: Int { min(max(level ?? 1, 1), 4) }

        /// Short label for the level button/summaries ("H1"…"H3", "B").
        var levelLabel: String { effectiveLevel == 4 ? "B" : "H\(effectiveLevel)" }

        /// H1 = body + 4, H2 = body + 2, H3 = body + 1, B(ody) = body size —
        /// mirrors the ratios word processors use, with a Body step for
        /// headings that shouldn't stand out by size (Aug 2026).
        static func sizeDelta(forLevel level: Int) -> Double {
            switch level {
            case 1: return 4
            case 2: return 2
            case 3: return 1
            default: return 0
            }
        }
    }
    var headingStyle: HeadingStyle? = nil

    var effectiveHeadingStyle: HeadingStyle { headingStyle ?? HeadingStyle() }

    /// Title-page byline mode ("Author | Author+Title" toggle): true prints
    /// each author's title tags after the name ("Jane Doe, MD, PhD"), false
    /// prints names alone.  Optional for backward-compatible decoding;
    /// nil = titles shown (the historical output).
    /// Section-break items only (kind == .pageBreak): page geometry for
    /// the pages that FOLLOW this boundary, until the next break.  nil =
    /// inherit the document's (first section's) setting.  Phase 1 of the
    /// document/section/page model (Aug 2026): a break both starts a new
    /// page and can re-set margins, columns, and line numbering.
    var sectionMarginInches: Double? = nil
    var sectionTwoColumn: Bool? = nil
    var sectionLineNumbers: Bool? = nil

    /// Page numbers for the pages after this break — same inheritance as the
    /// line-number switch (nil = carry on with whatever preceded it).
    var sectionPageNumbers: Bool? = nil

    /// References item only: the CSL style the reference list renders in.
    /// nil = the journal's required style (baked in at export).
    var citationStyle: String? = nil

    /// Authors item: what separates the authors (and affiliation lines):
    /// "comma" (default), "semicolon", or "newline".
    var authorDelimiter: String? = nil
    /// Authors item: how authors link to their institutions — "superscript"
    /// (numbers, the default), "cross" (†, ††, …), "doublecross" (‡, ‡‡, …),
    /// or "none" (deduplicated affiliation list, no markers).
    var affiliationMarker: String? = nil

    /// Authors item: annotate the corresponding author with a raised *
    /// (like an institution marker) plus a "* Corresponding author"
    /// footnote line.  nil = shown (the historical output).
    var showCorresponding: Bool? = nil
    var correspondingShown: Bool {
        get { showCorresponding ?? true }
        set { showCorresponding = newValue }
    }

    var showAuthorTitles: Bool? = nil
    var authorTitlesShown: Bool {
        get { showAuthorTitles ?? true }
        set { showAuthorTitles = newValue }
    }

    /// Per-item typography override (font/size/spacing/line numbers).
    /// nil = inherit the document's format.  Margins and columns are page
    /// geometry and always come from the document.
    var format: ExportDocumentFormat? = nil

    /// The heading actually printed for this item.
    func effectiveTitle(in content: Manuscript?) -> String {
        customTitle ?? title(in: content)
    }

    /// Default display name; body sections resolve their live title from `content`.
    func title(in content: Manuscript?) -> String {
        switch kind {
        case .titlePage:   return "Title"
        case .authors:     return "Authors"
        case .abstract:    return "Abstract"
        case .keywords:    return "Keywords"
        case .section:
            guard let sectionID,
                  let section = content?.sections.first(where: { $0.id == sectionID })
            else { return "(missing section)" }
            return section.title
        case .figures:     return "Figures"
        case .tables:      return "Tables"
        case .references:  return "References"
        case .coverLetter: return "Cover Letter"
        case .pageBreak:   return "Section"
        }
    }

    var systemImage: String {
        switch kind {
        case .titlePage:   return "textformat"
        case .authors:     return "person.2"
        case .abstract:    return "text.quote"
        case .keywords:    return "tag"
        case .section:     return "doc.text"
        case .figures:     return "photo.on.rectangle.angled"
        case .tables:      return "tablecells"
        case .references:  return "books.vertical"
        case .coverLetter: return "envelope"
        case .pageBreak:   return "arrow.down.to.line.compact"
        }
    }
}
