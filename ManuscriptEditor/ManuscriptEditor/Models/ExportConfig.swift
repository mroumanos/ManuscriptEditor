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
            ExportItem(kind: .titlePage),
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
    /// Two-column body layout (IEEE-style; PDF and LaTeX output).
    var twoColumn: Bool = false
}

/// Font families offered for export documents (system-installed, no bundling).
enum ExportFontFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case times, helvetica, georgia, system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .times:     return "Times New Roman"
        case .helvetica: return "Helvetica"
        case .georgia:   return "Georgia"
        case .system:    return "System (San Francisco)"
        }
    }

    /// Compact name for the per-item column controls in the Export cards.
    var shortLabel: String {
        switch self {
        case .times:     return "Times"
        case .helvetica: return "Helvetica"
        case .georgia:   return "Georgia"
        case .system:    return "System"
        }
    }

    /// PostScript-resolvable family name; nil means the system font.
    var familyName: String? {
        switch self {
        case .times:     return "Times New Roman"
        case .helvetica: return "Helvetica"
        case .georgia:   return "Georgia"
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
        /// Print the heading in ALL CAPS.  Optional for backward-compatible
        /// decoding of already-saved styles.
        var allCaps: Bool? = nil
        /// Point-size delta over the document body font: 0 (S), 2 (M), 5 (L).
        /// Superseded by `pointSize` when that is set.
        var sizeDelta: Double = 2
        /// Absolute heading size in points (typed entry); nil = body + delta.
        var pointSize: Double? = nil
    }
    var headingStyle: HeadingStyle? = nil

    var effectiveHeadingStyle: HeadingStyle { headingStyle ?? HeadingStyle() }

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
        case .titlePage:   return "Title & Authors"
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
        case .pageBreak:   return "Page Break"
        }
    }

    var systemImage: String {
        switch kind {
        case .titlePage:   return "textformat"
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
