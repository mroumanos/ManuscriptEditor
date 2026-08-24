// ExportService.swift
//
// Produces a journal **submission package** from a version's content — everything
// needed to submit online, in the right document types.
//
// DEPENDENCY-FREE
// ─────────────────────────────────────────────────────────────────────────────
// The document is assembled as an `NSAttributedString` and written with
// `NSAttributedString.data(from:documentAttributes:)`, which natively supports
// DOCX (officeOpenXML), RTF, HTML, and plain text — no third-party libraries.
//
// PACKAGE LAYOUT
// ─────────────────────────────────────────────────────────────────────────────
//   {chosen folder}/{Journal} Submission/
//     Manuscript.{ext}                 ← title → authors → abstract → keywords →
//                                         body sections → (figures/tables) →
//                                         bibliography → cover letter
//     Figures and Tables.{ext}         ← only when figures are submitted separately
//     figures/Figure N.{ext}           ← copied image files (self-contained package)
//
// SCOPE NOTE
// ─────────────────────────────────────────────────────────────────────────────
// v1 assembles a complete manuscript in a standard order and honors the
// "separate figures" flag. Full profile-outline-driven ordering across every
// component (see MasterContext 05-features M) is a documented refinement.

import AppKit
import CoreText

// MARK: - Letterhead

/// The cover letter's three-slot header as one attributed block: rows of
/// "left  center  right" cells on shared tab stops (0 / mid / right edge),
/// slot images as attachments capped at 40 pt tall, text lines beneath.
/// Returns nil when all three slots are empty.
private func letterheadBlock(_ letter: LetterToEditor, font: NSFont, width: CGFloat) -> NSAttributedString? {
    guard letter.hasHeader else { return nil }

    func cells(_ slot: LetterHeaderSlot) -> [NSAttributedString] {
        var out: [NSAttributedString] = []
        if let data = slot.imageData, let image = NSImage(data: data), image.size.height > 0 {
            let attachment = NSTextAttachment()
            attachment.image = image
            let h = min(40, image.size.height)
            attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * (h / image.size.height), height: h)
            out.append(NSAttributedString(attachment: attachment))
        }
        if !slot.text.isEmpty {
            for line in slot.text.components(separatedBy: "\n") {
                out.append(NSAttributedString(string: line,
                                              attributes: [.font: font, .foregroundColor: NSColor.black]))
            }
        }
        return out
    }

    let left = cells(letter.headerLeft), center = cells(letter.headerCenter), right = cells(letter.headerRight)
    let rows = max(left.count, center.count, right.count)
    guard rows > 0 else { return nil }

    let style = NSMutableParagraphStyle()
    style.tabStops = [NSTextTab(textAlignment: .center, location: width / 2),
                      NSTextTab(textAlignment: .right, location: width)]
    style.paragraphSpacing = 2

    let doc = NSMutableAttributedString()
    for i in 0..<rows {
        let row = NSMutableAttributedString()
        if i < left.count { row.append(left[i]) }
        row.append(NSAttributedString(string: "\t", attributes: [.font: font]))
        if i < center.count { row.append(center[i]) }
        row.append(NSAttributedString(string: "\t", attributes: [.font: font]))
        if i < right.count { row.append(right[i]) }
        row.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        row.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: row.length))
        doc.append(row)
    }
    doc.append(NSAttributedString(string: "\n", attributes: [.font: font]))
    return doc
}

/// The hand-drawn signature as an inline attachment (max 48 pt tall),
/// pinned hard left — never centered like figures are.  Transparent pad
/// margins are trimmed so the ink itself starts at the left edge.
private func signatureImageBlock(_ data: Data?, font: NSFont) -> NSAttributedString? {
    guard let data, let raw = NSImage(data: data), raw.size.height > 0 else { return nil }
    let image = raw.trimmedTransparentMargins()
    let attachment = NSTextAttachment()
    attachment.image = image
    let h = min(48, image.size.height)
    attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * (h / image.size.height), height: h)
    let out = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
    let style = NSMutableParagraphStyle()
    style.alignment = .left
    out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
    out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
    return out
}

/// Resolves the letter body's live tokens in place: ⟦Date⟧ → today's date,
/// ⟦Signature⟧ → the drawn signature (removed when none is drawn).  Runs on
/// the already-typeset body, so replacements inherit the marker's attributes.
private func resolveLetterTokens(in body: NSMutableAttributedString, letter: LetterToEditor) {
    func replace(_ marker: String, with replacement: ([NSAttributedString.Key: Any]) -> NSAttributedString) {
        while true {
            let range = (body.string as NSString).range(of: marker)
            guard range.location != NSNotFound else { break }
            let attrs = body.attributes(at: range.location, effectiveRange: nil)
                .filter { $0.key != .link && $0.key != .toolTip }
            body.replaceCharacters(in: range, with: replacement(attrs))
        }
    }
    replace(LetterToken.date.marker) { attrs in
        NSAttributedString(string: Date().formatted(date: .long, time: .omitted), attributes: attrs)
    }
    replace(LetterToken.signature.marker) { attrs in
        guard let data = letter.signatureImageData, let raw = NSImage(data: data),
              raw.size.height > 0 else { return NSAttributedString(string: "") }
        let image = raw.trimmedTransparentMargins()
        let attachment = NSTextAttachment()
        attachment.image = image
        let h = min(48, image.size.height)
        attachment.bounds = CGRect(x: 0, y: 0,
                                   width: image.size.width * (h / image.size.height), height: h)
        // Pinned hard left: keep the marker's indents/spacing but force the
        // alignment — inherited styles kept sneaking in centered.
        let out = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        let style = ((attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                     as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.alignment = .left
        out.addAttribute(.paragraphStyle, value: style,
                         range: NSRange(location: 0, length: out.length))
        return out
    }
}


/// The journal-facing title: the article title when set, else project name.
private func displayTitle(_ m: Manuscript) -> String {
    let article = (m.articleTitle ?? "").trimmingCharacters(in: .whitespaces)
    if !article.isEmpty { return article }
    return m.title.isEmpty ? "Untitled Manuscript" : m.title
}

struct ExportService {

    // MARK: - Format

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case docx, rtf, html, plainText

        var id: String { rawValue }

        var label: String {
            switch self {
            case .docx:      return "Word (.docx)"
            case .rtf:       return "Rich Text (.rtf)"
            case .html:      return "HTML (.html)"
            case .plainText: return "Plain Text (.txt)"
            }
        }

        var ext: String {
            switch self {
            case .docx:      return "docx"
            case .rtf:       return "rtf"
            case .html:      return "html"
            case .plainText: return "txt"
            }
        }

        var documentType: NSAttributedString.DocumentType {
            switch self {
            case .docx:      return .officeOpenXML
            case .rtf:       return .rtf
            case .html:      return .html
            case .plainText: return .plain
            }
        }
    }

    // MARK: - Fonts

    private let titleFont   = NSFont.systemFont(ofSize: 22, weight: .bold)
    private let headingFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private let bodyFont    = NSFont.systemFont(ofSize: 12)
    private let metaFont    = NSFont.systemFont(ofSize: 11)

    // MARK: - Public API

    /// Writes a submission package for `content` into a new subfolder of
    /// `destination`. Returns the package folder URL.
    @discardableResult
    func exportPackage(
        content: Manuscript,
        journalName: String,
        requiresSeparateFigures: Bool,
        format: Format,
        figureURL: (Figure) -> URL?,
        chartImage: ((Figure) -> NSImage?)? = nil,
        into destination: URL
    ) throws -> URL {
        let folder = destination.appendingPathComponent("\(sanitize(journalName)) Submission", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Main manuscript document.
        let main = buildMainDocument(content, includeAssets: !requiresSeparateFigures)
        try write(main, name: "Manuscript", format: format, into: folder)

        // Optional separate figures/tables document.
        if requiresSeparateFigures {
            let assets = buildAssetsDocument(content)
            try write(assets, name: "Figures and Tables", format: format, into: folder)
        }

        // Copy figure image files so the package is self-contained.
        try copyFigureImages(content, figureURL: figureURL, chartImage: chartImage, into: folder)

        return folder
    }

    // MARK: - Outline-driven export
    //
    // The per-journal `ExportConfig` path: every document in the outline is
    // assembled from its ordered items (with explicit page breaks) using its
    // own typography, then written as PDF (custom CoreText paginator — the
    // only type honoring columns/line numbers exactly), DOCX/RTF (attributed
    // writer + form-feed page breaks), or LaTeX source.

    /// Writes one submission package as specified by `config`.
    @discardableResult
    func exportPackage(
        config: ExportConfig,
        content: Manuscript,
        packageName: String,
        citationStyleDefault: String = "apa",
        figureURL: @escaping (Figure) -> URL?,
        chartImage: ((Figure) -> NSImage?)? = nil,
        tableData: ((ManuscriptTable) -> QueryResult?)? = nil,
        into destination: URL
    ) throws -> URL {
        let folder = destination.appendingPathComponent("\(sanitize(packageName)) Submission", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let refContext = RefEngine.context(for: content)

        for document in config.documents where !document.items.isEmpty {
            let name = sanitize(document.name.isEmpty ? "Document" : document.name)
            let url = folder.appendingPathComponent("\(name).\(document.fileType.ext)")
            switch document.fileType {
            case .pdf:
                let sections = pageSegments(for: document, content: content, refContext: refContext, figureURL: figureURL, chartImage: chartImage, tableData: tableData, citationStyleDefault: citationStyleDefault)
                let data = PDFPaginator(format: document.format).render(sections: sections)
                try data.write(to: url, options: .atomic)
            case .docx, .rtf:
                let segments = pageSegments(for: document, content: content, refContext: refContext, figureURL: figureURL, chartImage: chartImage, tableData: tableData, citationStyleDefault: citationStyleDefault).map(\.text)
                // Form feed is the closest page-break the attributed writers offer.
                let joined = NSMutableAttributedString()
                for (i, seg) in segments.enumerated() {
                    if i > 0 { joined.append(NSAttributedString(string: "\u{0C}")) }
                    joined.append(seg)
                }
                let margin = document.format.marginInches * 72
                let data = try joined.data(
                    from: NSRange(location: 0, length: joined.length),
                    documentAttributes: [
                        .documentType: document.fileType == .docx
                            ? NSAttributedString.DocumentType.officeOpenXML
                            : NSAttributedString.DocumentType.rtf,
                        .paperSize: NSSize(width: 612, height: 792),
                        .leftMargin: margin, .rightMargin: margin,
                        .topMargin: margin, .bottomMargin: margin,
                    ]
                )
                try data.write(to: url, options: .atomic)
            case .latex:
                let tex = latexDocument(document, content: content,
                                        citationStyleDefault: citationStyleDefault)
                try Data(tex.utf8).write(to: url, options: .atomic)
            }
        }

        // Copy figure images whenever any document includes the figures block.
        if config.documents.contains(where: { doc in doc.items.contains { $0.kind == .figures } }) {
            try copyFigureImages(content, figureURL: figureURL, chartImage: chartImage, into: folder)
        }
        return folder
    }

    /// Renders one document to PDF data for the on-screen preview — the
    /// same segments + paginator the real export uses, regardless of the
    /// document's file type (a DOCX document previews its layout as PDF).
    func previewPDF(document: ExportDocument, content: Manuscript,
                    citationStyleDefault: String = "apa",
                    figureURL: @escaping (Figure) -> URL?,
                    chartImage: ((Figure) -> NSImage?)? = nil,
                    tableData: ((ManuscriptTable) -> QueryResult?)? = nil,
                    separateAuthorsOverride: Bool? = nil) -> Data {
        let refContext = RefEngine.context(for: content)
        let sections = pageSegments(for: document, content: content, refContext: refContext,
                                    figureURL: figureURL, chartImage: chartImage,
                                    tableData: tableData,
                                    citationStyleDefault: citationStyleDefault,
                                    separateAuthorsOverride: separateAuthorsOverride)
        return PDFPaginator(format: document.format).render(sections: sections)
    }

    // MARK: Outline assembly (attributed)

    /// Renders a document's items into attributed segments; a new segment
    /// starts at every page break.
    /// One rendered section: its text plus the page geometry (margins,
    /// columns) that section's pages use.
    struct PageSection {
        let text: NSAttributedString
        let marginInches: Double
        let twoColumn: Bool
    }

    private func pageSegments(for document: ExportDocument, content: Manuscript,
                              refContext: RefEngine.Context,
                              figureURL: ((Figure) -> URL?)? = nil,
                              chartImage: ((Figure) -> NSImage?)? = nil,
                              tableData: ((ManuscriptTable) -> QueryResult?)? = nil,
                              citationStyleDefault: String = "apa",
                              separateAuthorsOverride: Bool? = nil) -> [PageSection] {
        let builder = OutlineBuilder(format: document.format, refContext: refContext,
                                     fileType: document.fileType,
                                     figureURL: figureURL, chartImage: chartImage, tableData: tableData,
                                     separateAuthors: separateAuthorsOverride
                                        ?? document.items.contains { $0.kind == .authors },
                                     citationStyleDefault: citationStyleDefault)
        var sections: [PageSection] = []
        var current = NSMutableAttributedString()
        // The document's own format is the first section's geometry; each
        // break re-sets it for what follows (nil fields inherit).
        var margin = document.format.marginInches
        var twoCol = document.format.twoColumn
        var sectionLines: Bool? = nil
        func flush() {
            if current.length > 0 {
                sections.append(PageSection(text: current, marginInches: margin, twoColumn: twoCol))
            }
            current = NSMutableAttributedString()
        }
        for item in document.items {
            if item.kind == .pageBreak {
                flush()
                margin = item.sectionMarginInches ?? document.format.marginInches
                twoCol = item.sectionTwoColumn ?? document.format.twoColumn
                sectionLines = item.sectionLineNumbers
                continue
            }
            if let block = builder.block(for: item, content: content,
                                         sectionLineNumbers: sectionLines) {
                current.append(block)
            }
        }
        flush()
        return sections
    }

    // MARK: LaTeX writer

    /// Emits a self-contained .tex source for one document.  Section bodies are
    /// exported as escaped plain text (styling is not translated in v1);
    /// two-column and line numbering map to `twocolumn` and the `lineno` package.
    private func latexDocument(_ document: ExportDocument, content m: Manuscript,
                               citationStyleDefault: String = "apa") -> String {
        let f = document.format
        let pt = Int(f.fontSize.rounded()).clamped(to: 10...12)
        var options = ["\(pt)pt"]
        if f.twoColumn { options.append("twocolumn") }

        var out = "\\documentclass[\(options.joined(separator: ","))]{article}\n"
        out += "\\usepackage[margin=\(String(format: "%.2f", f.marginInches))in]{geometry}\n"
        out += "\\usepackage{setspace}\n"
        let anyLineNumbers = f.lineNumbers
            || document.items.contains { $0.sectionLineNumbers == true }
        if anyLineNumbers { out += "\\usepackage{lineno}\n" }
        out += "\\begin{document}\n"
        if f.lineSpacing >= 2.0 { out += "\\doublespacing\n" }
        else if f.lineSpacing >= 1.3 { out += "\\onehalfspacing\n" }

        // Line numbering is section-level: each break re-sets it for the
        // items after it (nil = inherit the document's).
        var numbering = false
        var sectionLines: Bool? = nil
        for item in document.items {
            if item.kind == .pageBreak { sectionLines = item.sectionLineNumbers }
            if anyLineNumbers, item.kind != .pageBreak {
                let wanted = sectionLines ?? f.lineNumbers
                if wanted != numbering {
                    out += wanted ? "\\linenumbers\n" : "\\nolinenumbers\n"
                    numbering = wanted
                }
            }
            let separateAuthors = document.items.contains { $0.kind == .authors }
            switch item.kind {
            case .titlePage:
                let subtitleTex = (m.subtitle?.isEmpty == false)
                    ? " \\\\ \\large \(tex(m.subtitle ?? ""))" : ""
                out += "\\title{\(tex(displayTitle(m)))\(subtitleTex)}\n"
                if separateAuthors {
                    // The byline renders from its own item — a removed
                    // authors item makes a blind copy, so keep \author empty.
                    out += "\\author{}\n\\date{}\n\\maketitle\n"
                } else {
                    let authors = m.authors.sorted { $0.order < $1.order }
                        .map { tex(item.authorTitlesShown ? $0.exportName : $0.fullName) }
                    out += "\\author{\(authors.joined(separator: " \\and "))}\n\\date{}\n\\maketitle\n"
                }
            case .authors:
                let authors = m.authors.sorted { $0.order < $1.order }
                if !authors.isEmpty {
                    let delim: String
                    switch item.authorDelimiter {
                    case "comma":   delim = ", "
                    case "space":   delim = " "
                    case "slash":   delim = " / "
                    case "hyphen":  delim = " - "
                    case "newline": delim = " \\\\\n"
                    default:        delim = "; "
                    }
                    let markerStyle = item.affiliationMarker ?? "superscript"
                    var affLines: [String] = []
                    var indexByLine: [String: Int] = [:]
                    for a in authors {
                        for l in a.affiliationLines(in: m) where indexByLine[l] == nil {
                            indexByLine[l] = affLines.count
                            affLines.append(l)
                        }
                    }
                    func mk(_ i: Int) -> String {
                        switch markerStyle {
                        case "cross":
                            if i == 1 { return "‡" }
                            return String(repeating: "†", count: i + 1)
                        case "none": return ""
                        default:     return String(i + 1)
                        }
                    }
                    let names = authors.map { a -> String in
                        var s = tex(item.authorTitlesShown ? a.exportName : a.fullName)
                        if markerStyle != "none" {
                            let ms = a.affiliationLines(in: m).compactMap { indexByLine[$0] }
                                .sorted().map(mk).joined(separator: ",")
                            if !ms.isEmpty { s += "\\textsuperscript{\(ms)}" }
                        }
                        if a.isCorresponding, item.correspondingShown { s += "\\textsuperscript{*}" }
                        return s
                    }.joined(separator: delim)
                    out += "\\begin{center}\n\(names)\\\\\n"
                    for (i, l) in affLines.enumerated() {
                        let prefix = markerStyle == "none" ? "" : "\\textsuperscript{\(mk(i))} "
                        out += "\(prefix)\\textit{\(tex(l))}\\\\\n"
                    }
                    if item.correspondingShown, authors.contains(where: \.isCorresponding) {
                        out += "\\textsuperscript{*} Corresponding author\\\\\n"
                    }
                    out += "\\end{center}\n"
                }
            case .abstract:
                if !m.abstract.isEmpty {
                    out += "\\begin{abstract}\n\(tex(m.abstract.plain))\n\\end{abstract}\n"
                }
            case .keywords:
                if !m.keywords.isEmpty {
                    let label = item.titleShown ? "\\textbf{\(tex(latexHeading(item.customTitle ?? "Keywords"))):} " : ""
                    let delim = OutlineBuilder.delimiterText(item.authorDelimiter, fallback: ", ")
                    out += "\\noindent\(label)\(tex(m.keywords.joined(separator: delim)))\n\n"
                }
            case .section:
                if let id = item.sectionID,
                   let section = m.sections.first(where: { $0.id == id }),
                   section.active, !section.content.isEmpty {
                    if item.titleShown {
                        out += "\\section{\(tex(latexHeading(item.customTitle ?? section.title)))}\n"
                    }
                    out += "\(tex(PartEngine.expandPlainMarkers(section.content.plain, content: m)))\n\n"
                }
            case .figures:
                for fig in m.figures.sorted(by: { $0.number < $1.number }) {
                    out += "\\begin{figure}[htbp]\\centering\n"
                    out += "%% Figure \(fig.number) image: figures/Figure \(fig.number)\n"
                    out += "\\caption{\(tex(fig.caption.isEmpty ? fig.title : fig.caption))}\n\\end{figure}\n"
                }
            case .tables:
                for table in m.tables.sorted(by: { $0.number < $1.number }) {
                    out += "\\begin{table}[htbp]\\caption{\(tex(table.title))}\n"
                    out += "\\begin{verbatim}\n\(table.content)\n\\end{verbatim}\n\\end{table}\n"
                }
            case .references:
                if !m.bibliography.isEmpty {
                    out += "\\begin{thebibliography}{\(m.bibliography.count)}\n"
                    let style = item.citationStyle ?? citationStyleDefault
                    for entry in m.bibliography {
                        out += "\\bibitem{\(entry.key.isEmpty ? entry.id.uuidString : entry.key)} \(tex(RefEngine.referenceText(entry, style: style)))\n"
                    }
                    out += "\\end{thebibliography}\n"
                }
            case .coverLetter:
                if !m.letterToEditor.body.isEmpty {
                    // Letterhead text slots as three top-aligned minipages
                    // (slot images are attributed-writer only — LaTeX output
                    // is plain source with no bundled image files).
                    let letter = m.letterToEditor
                    if letter.hasHeader {
                        func slotTex(_ slot: LetterHeaderSlot, _ align: String) -> String {
                            "\\begin{minipage}[t]{0.32\\textwidth}\(align) \(tex(slot.text).replacingOccurrences(of: "\n", with: "\\\\ "))\\end{minipage}"
                        }
                        out += "\\noindent\n"
                        out += slotTex(letter.headerLeft, "\\raggedright") + "\\hfill\n"
                        out += slotTex(letter.headerCenter, "\\centering") + "\\hfill\n"
                        out += slotTex(letter.headerRight, "\\raggedleft") + "\n\\par\\vspace{1em}\n"
                    }
                    // Letter tokens: date resolves to text; the drawn
                    // signature is image-only, so it can't ride in bare
                    // LaTeX source — drop the marker.
                    let bodyText = m.letterToEditor.body.plain
                        .replacingOccurrences(of: LetterToken.date.marker,
                                              with: Date().formatted(date: .long, time: .omitted))
                        .replacingOccurrences(of: LetterToken.signature.marker, with: "")
                    if item.titleShown {
                        out += "\\section*{\(tex(latexHeading(item.customTitle ?? "Cover Letter")))}\n"
                    }
                    out += "\(tex(bodyText))\n\n"
                }
            case .pageBreak:
                out += "\\newpage\n"
            }
        }
        out += "\\end{document}\n"
        return out
    }

    /// First-letter capitalization for exported headings (matches OutlineBuilder).
    private func latexHeading(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    /// Escapes LaTeX special characters in plain text.
    private func tex(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\textbackslash{}"
            case "&", "%", "$", "#", "_", "{", "}": out += "\\\(ch)"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Document assembly

    private func buildMainDocument(_ m: Manuscript, includeAssets: Bool) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        // Reference-token rendering context: prose from closed editors can
        // carry stale numbers, so every rich block is re-rendered against the
        // final numbering (then stripped of in-app link/tooltip/bold chrome).
        let refContext = RefEngine.context(for: m)

        doc.append(line(displayTitle(m), font: titleFont, spacingAfter: 8))
        if !m.runningTitle.isEmpty {
            doc.append(line("Running title: \(m.runningTitle)", font: metaFont, color: .secondaryLabelColor, spacingAfter: 8))
        }

        // Authors + affiliations.
        let authors = m.authors.sorted { $0.order < $1.order }
        if !authors.isEmpty {
            let names = authors.map { $0.exportName + ($0.isCorresponding ? "*" : "") }
                .joined(separator: ", ")
            doc.append(line(names, font: bodyFont, spacingAfter: 2))
            var seen = Set<String>()
            for aff in authors.flatMap({ $0.affiliationNames(in: m) }) where seen.insert(aff).inserted {
                doc.append(line(aff, font: metaFont, color: .secondaryLabelColor, spacingAfter: 1))
            }
            doc.append(spacer())
        }

        if !m.abstract.isEmpty {
            doc.append(heading("Abstract"))
            doc.append(rich(m.abstract, refContext))
            doc.append(spacer())
        }

        if !m.keywords.isEmpty {
            doc.append(line("Keywords: " + m.keywords.joined(separator: ", "),
                            font: metaFont, color: .secondaryLabelColor, spacingAfter: 10))
        }

        // Deactivated sections are excluded from the submission package.
        for section in m.sections.sorted(by: { $0.order < $1.order })
        where section.active && !section.content.isEmpty {
            doc.append(heading(section.title))
            doc.append(rich(section.content, refContext))
            doc.append(spacer())
        }

        if includeAssets {
            doc.append(assetsBlock(m))
        }

        // The bibliography array is already in citation order (auto-ordered by
        // the store), so the printed numbers match the in-text tokens.
        if !m.bibliography.isEmpty {
            doc.append(heading("References"))
            for (i, entry) in m.bibliography.enumerated() {
                doc.append(line("\(i + 1). \(RefEngine.fullReference(entry))", font: bodyFont, spacingAfter: 4))
            }
            doc.append(spacer())
        }

        if !m.letterToEditor.body.isEmpty {
            // 468 pt = US Letter inside the writer's default 1" margins.
            if let head = letterheadBlock(m.letterToEditor, font: bodyFont, width: 468) {
                doc.append(head)
            }
            // No printed "Cover Letter" label — a real letter doesn't carry one.
            let body = NSMutableAttributedString(attributedString: rich(m.letterToEditor.body, refContext))
            resolveLetterTokens(in: body, letter: m.letterToEditor)
            doc.append(body)
            if !m.letterToEditor.body.plain.contains(LetterToken.signature.marker),
               let drawn = signatureImageBlock(m.letterToEditor.signatureImageData, font: bodyFont) {
                doc.append(drawn)
            }
        }

        return doc
    }

    private func buildAssetsDocument(_ m: Manuscript) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        doc.append(line("Figures and Tables", font: titleFont, spacingAfter: 10))
        doc.append(assetsBlock(m))
        return doc
    }

    /// The figures + tables block shared by the main and separate documents.
    private func assetsBlock(_ m: Manuscript) -> NSAttributedString {
        let doc = NSMutableAttributedString()

        let figureNumbers = RefEngine.effectiveFigureNumbers(in: m)
        let figures = m.figures.sorted { (figureNumbers[$0.id] ?? $0.number) < (figureNumbers[$1.id] ?? $1.number) }
        if !figures.isEmpty {
            doc.append(heading("Figures"))
            for f in figures {
                doc.append(line("Figure \(figureNumbers[f.id] ?? f.number). \(f.title)", font: bodyFont.bold(), spacingAfter: 2))
                if !f.caption.isEmpty {
                    doc.append(line(f.caption, font: metaFont, color: .secondaryLabelColor, spacingAfter: 8))
                }
            }
            doc.append(spacer())
        }

        let tableNumbers = RefEngine.effectiveTableNumbers(in: m)
        let tables = m.tables.sorted { (tableNumbers[$0.id] ?? $0.number) < (tableNumbers[$1.id] ?? $1.number) }
        if !tables.isEmpty {
            doc.append(heading("Tables"))
            for t in tables {
                doc.append(line("Table \(tableNumbers[t.id] ?? t.number). \(t.title)", font: bodyFont.bold(), spacingAfter: 2))
                if !t.content.isEmpty {
                    doc.append(line(t.content, font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                    spacingAfter: 4))
                }
                if !t.caption.isEmpty {
                    doc.append(line(t.caption, font: metaFont, color: .secondaryLabelColor, spacingAfter: 8))
                }
            }
            doc.append(spacer())
        }

        return doc
    }

    // MARK: - Writing

    private func write(_ attr: NSAttributedString, name: String, format: Format, into folder: URL) throws {
        let url = folder.appendingPathComponent("\(name).\(format.ext)")
        let data = try attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: [.documentType: format.documentType]
        )
        try data.write(to: url, options: .atomic)
    }

    private func copyFigureImages(_ m: Manuscript, figureURL: (Figure) -> URL?,
                                  chartImage: ((Figure) -> NSImage?)? = nil, into folder: URL) throws {
        let fm = FileManager.default
        let figuresDir = folder.appendingPathComponent("figures", isDirectory: true)
        var created = false
        // File names follow reference-order numbering, matching in-text tokens.
        let numbers = RefEngine.effectiveFigureNumbers(in: m)
        for figure in m.figures.sorted(by: { (numbers[$0.id] ?? $0.number) < (numbers[$1.id] ?? $1.number) }) {
            // Data-linked figures export their rendered chart.
            if figure.dataAssetID != nil {
                if let image = chartImage?(figure), let data = FigureImaging.pngData(image) {
                    if !created {
                        try fm.createDirectory(at: figuresDir, withIntermediateDirectories: true)
                        created = true
                    }
                    let dest = figuresDir.appendingPathComponent("Figure \(numbers[figure.id] ?? figure.number).png")
                    try? fm.removeItem(at: dest)
                    try? data.write(to: dest)
                }
                continue
            }
            guard let src = figureURL(figure), fm.fileExists(atPath: src.path) else { continue }
            if !created {
                try fm.createDirectory(at: figuresDir, withIntermediateDirectories: true)
                created = true
            }
            // Cropped/resized/B&W figures are rendered to PNG so the package
            // contains exactly what the user framed; others copy verbatim.
            if FigureImaging.needsRendering(figure),
               let image = NSImage(contentsOf: src),
               let data = FigureImaging.pngData(
                   FigureImaging.processed(image, crop: figure.crop, scalePercent: figure.scalePercent,
                                           monochrome: figure.monochrome)) {
                let dest = figuresDir.appendingPathComponent("Figure \(numbers[figure.id] ?? figure.number).png")
                try? fm.removeItem(at: dest)
                try? data.write(to: dest)
            } else {
                let dest = figuresDir.appendingPathComponent("Figure \(numbers[figure.id] ?? figure.number).\(src.pathExtension)")
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: src, to: dest)
            }
        }
    }

    // MARK: - Attributed-string helpers

    private func heading(_ text: String) -> NSAttributedString {
        line(text, font: headingFont, spacingBefore: 6, spacingAfter: 4)
    }

    private func line(_ text: String, font: NSFont, color: NSColor = .labelColor,
                      spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 2) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = spacingAfter
        para.paragraphSpacingBefore = spacingBefore
        return NSAttributedString(string: text + "\n", attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ])
    }

    private func spacer() -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: bodyFont])
    }

    /// Bridges a `RichText` (RTF archive or plain mirror) to `NSAttributedString`,
    /// re-rendering reference tokens against the final numbering and stripping
    /// their in-app chrome, then appending a trailing newline for separation.
    private func rich(_ richText: RichText, _ refContext: RefEngine.Context) -> NSAttributedString {
        let base: NSAttributedString
        if let rtf = richText.rtf, let s = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            base = RefEngine.exportReady(s, context: refContext)
        } else {
            base = NSAttributedString(string: richText.plain, attributes: [.font: bodyFont])
        }
        let out = NSMutableAttributedString(attributedString: base)
        // Same superscript materialization as the outline path, and the
        // same dark-mode line-color strip.
        let full = NSRange(location: 0, length: out.length)
        out.removeAttribute(.underlineColor, range: full)
        out.removeAttribute(.strikethroughColor, range: full)
        out.enumerateAttribute(.superscript, in: full) { value, range, _ in
            guard let level = value as? Int, level != 0 else { return }
            out.enumerateAttribute(.font, in: range) { f, sub, _ in
                let current = (f as? NSFont) ?? bodyFont
                let small = NSFont(descriptor: current.fontDescriptor,
                                   size: (bodyFont.pointSize * 0.65).rounded()) ?? current
                out.addAttribute(.font, value: small, range: sub)
            }
            out.addAttribute(.baselineOffset,
                             value: bodyFont.pointSize * 0.33 * CGFloat(level), range: range)
            out.removeAttribute(.superscript, range: range)
        }
        out.append(NSAttributedString(string: "\n"))
        return out
    }

    private func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
                             .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Manuscript" : cleaned
    }
}

// MARK: - Export attributes

/// Marks ranges that should carry margin line numbers in the PDF output —
/// set per item from its effective format, read per line by `PDFPaginator`.
private enum ExportAttr {
    static let lineNumbers = NSAttributedString.Key("MELineNumbers")
}

// MARK: - OutlineBuilder

/// Renders one `ExportItem` into an attributed block using the document's
/// typography — or the item's own override (font/size/spacing/line numbers;
/// margins/columns stay document-level).  Rich prose is re-set in the block's
/// font (preserving bold/italic), reference tokens re-rendered via RefEngine.
private struct OutlineBuilder {
    let format: ExportDocumentFormat
    let refContext: RefEngine.Context
    /// Output file type — tables build differently per target: drawn grids
    /// for the PDF path (CoreText has no table layout), NSTextTable for the
    /// attributed writers (real Word/RTF tables).
    var fileType: ExportFileType? = nil
    /// Resolves a figure's image file for inline placement rendering.
    var figureURL: ((Figure) -> URL?)? = nil
    /// Renders a data-linked figure's chart (SQL + chart type) to an image.
    var chartImage: ((Figure) -> NSImage?)? = nil
    /// Runs a data-linked table's SQL and returns the rows to lay out.
    var tableData: ((ManuscriptTable) -> QueryResult?)? = nil
    /// True when the document carries its own `.authors` item, so
    /// `.titlePage` must NOT render the byline too (pre-split configs have
    /// no authors item and keep the combined rendering).
    var separateAuthors: Bool = false
    /// True when the title item carries an explicit Size override — the
    /// title then renders at EXACTLY that size (bold) instead of the
    /// default document-font + 8 pt bump.
    var titleExactSize: Bool = false
    /// CSL style for the reference list when its item doesn't pick one
    /// (the journal's required style, resolved at the export call).
    var citationStyleDefault: String = "apa"

    /// Renders `item`, honoring its format override and custom title, and
    /// stamps the line-number attribute when its effective format asks for it.
    func block(for item: ExportItem, content m: Manuscript,
               sectionLineNumbers: Bool? = nil) -> NSAttributedString? {
        var effective = effectiveFormat(for: item)
        // Line numbering is SECTION-level only (Aug 2026): the enclosing
        // boundary's setting (or the document's) — never the item's own
        // format, which the typography seeds would otherwise freeze.
        effective.lineNumbers = sectionLineNumbers ?? format.lineNumbers
        let builder = OutlineBuilder(format: effective, refContext: refContext, fileType: fileType,
                                     figureURL: figureURL, chartImage: chartImage, tableData: tableData,
                                     separateAuthors: separateAuthors,
                                     titleExactSize: item.format?.fontSize != nil,
                                     citationStyleDefault: citationStyleDefault)
        guard let rendered = builder.renderBlock(item, content: m) else { return nil }
        guard effective.lineNumbers else { return rendered }
        let out = NSMutableAttributedString(attributedString: rendered)
        out.addAttribute(ExportAttr.lineNumbers, value: true,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Item override wins for typography — font, size, AND spacing (each
    /// component manages its own, Aug 2026); page geometry stays the
    /// document's.
    private func effectiveFormat(for item: ExportItem) -> ExportDocumentFormat {
        guard var override = item.format else { return format }
        override.marginInches = format.marginInches
        override.twoColumn = format.twoColumn
        return override
    }

    private var base: NSFont {
        if let name = format.fontFamily.familyName,
           let font = NSFont(name: name, size: format.fontSize) { return font }
        return .systemFont(ofSize: format.fontSize)
    }
    private var title: NSFont   { scaled(+8, bold: true) }
    private var heading: NSFont { scaled(+2, bold: true) }
    private var meta: NSFont    { scaled(-1, bold: false) }

    private func scaled(_ delta: CGFloat, bold: Bool) -> NSFont {
        var font = NSFont(descriptor: base.fontDescriptor, size: format.fontSize + delta) ?? base
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        return font
    }

    /// A list component's delimiter code rendered as text (authors byline,
    /// keywords line — stored in `ExportItem.authorDelimiter`; nil = the
    /// component's own default).
    static func delimiterText(_ code: String?, fallback: String) -> String {
        switch code {
        case "semicolon": return "; "
        case "comma":     return ", "
        case "space":     return " "
        case "slash":     return " / "
        case "hyphen":    return " - "
        case "newline":   return "\n"
        default:          return fallback
        }
    }

    /// The byline: names (credentials per the item toggle, * on the
    /// corresponding author) plus deduplicated affiliation lines.
    private func authorsBlock(_ item: ExportItem, content m: Manuscript) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        let authors = m.authors.sorted { $0.order < $1.order }
        guard !authors.isEmpty else { return doc }

        let delimiter = Self.delimiterText(item.authorDelimiter, fallback: "; ")
        let markerStyle = item.affiliationMarker ?? "superscript"

        // Ordered unique affiliation lines across the whole byline; each
        // gets the marker its index dictates.
        var affLines: [String] = []
        var indexByLine: [String: Int] = [:]
        for author in authors {
            for lineText in author.affiliationLines(in: m) where indexByLine[lineText] == nil {
                indexByLine[lineText] = affLines.count
                affLines.append(lineText)
            }
        }
        // Crosshatches escalate with the institution index: † (single),
        // ‡ (double), then ††† and up — one option, not several.
        func marker(_ index: Int) -> String {
            switch markerStyle {
            case "cross":
                if index == 1 { return "‡" }
                return String(repeating: "†", count: index + 1)
            case "none": return ""
            default:     return String(index + 1)
            }
        }

        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: base, .paragraphStyle: paragraph(after: 2, before: 0),
            .foregroundColor: NSColor.black]
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: meta, .paragraphStyle: paragraph(after: 1, before: 0),
            .foregroundColor: NSColor.darkGray]
        // Markers use the same materialized raise as citations (smaller
        // font + baselineOffset) so every writer renders them superscript.
        let markerFont = NSFont(descriptor: base.fontDescriptor,
                                size: (base.pointSize * 0.65).rounded()) ?? base
        func markerRun(_ text: String, para: NSParagraphStyle) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: markerFont,
                .baselineOffset: base.pointSize * 0.33,
                .paragraphStyle: para,
                .foregroundColor: NSColor.black])
        }

        for (i, author) in authors.enumerated() {
            doc.append(NSAttributedString(
                string: item.authorTitlesShown ? author.exportName : author.fullName,
                attributes: bodyAttrs))
            if markerStyle != "none" {
                let markers = author.affiliationLines(in: m)
                    .compactMap { indexByLine[$0] }.sorted().map(marker)
                    .joined(separator: ",")
                if !markers.isEmpty {
                    doc.append(markerRun(markers,
                                         para: bodyAttrs[.paragraphStyle] as! NSParagraphStyle))
                }
            }
            if author.isCorresponding, item.correspondingShown {
                // The * annotates like another institution marker (raised).
                doc.append(markerRun("*", para: bodyAttrs[.paragraphStyle] as! NSParagraphStyle))
            }
            doc.append(NSAttributedString(string: i < authors.count - 1 ? delimiter : "\n",
                                          attributes: bodyAttrs))
        }

        for (index, lineText) in affLines.enumerated() {
            if markerStyle != "none" {
                doc.append(markerRun(marker(index),
                                     para: metaAttrs[.paragraphStyle] as! NSParagraphStyle))
                doc.append(NSAttributedString(string: " ", attributes: metaAttrs))
            }
            doc.append(NSAttributedString(string: lineText + "\n", attributes: metaAttrs))
        }
        // "* Corresponding author" footnote — a line like the institutions'.
        if item.correspondingShown, authors.contains(where: \.isCorresponding) {
            doc.append(markerRun("*", para: metaAttrs[.paragraphStyle] as! NSParagraphStyle))
            doc.append(NSAttributedString(string: " Corresponding author\n",
                                          attributes: metaAttrs))
        }
        return doc
    }

    private func renderBlock(_ item: ExportItem, content m: Manuscript) -> NSAttributedString? {
        switch item.kind {
        case .titlePage:
            let doc = NSMutableAttributedString()
            // The title uses the standard heading system: its item's H
            // level (H1 = body+4 …) / typed size when set, else the item's
            // Size override, else the classic document-font + 8 pt.
            let hs = item.effectiveHeadingStyle
            var titleFont: NSFont
            if hs.level != nil {
                titleFont = scaled(ExportItem.HeadingStyle.sizeDelta(forLevel: hs.effectiveLevel),
                                   bold: hs.bold)
            } else if let pt = hs.pointSize {
                var sized = NSFont(descriptor: base.fontDescriptor, size: pt) ?? base
                if hs.bold { sized = NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask) }
                titleFont = sized
            } else if titleExactSize {
                titleFont = scaled(0, bold: hs.bold)
            } else {
                titleFont = title
            }
            if hs.italicOn { titleFont = NSFontManager.shared.convert(titleFont, toHaveTrait: .italicFontMask) }
            let titleLine = NSMutableAttributedString(attributedString:
                line(displayTitle(m), font: titleFont, after: 8))
            let titleRange = NSRange(location: 0, length: titleLine.length)
            if hs.underline {
                titleLine.addAttribute(.underlineStyle,
                                       value: NSUnderlineStyle.single.rawValue, range: titleRange)
            }
            applyHeadingAlignment(hs, to: titleLine)
            doc.append(titleLine)
            if let subtitle = m.subtitle, !subtitle.isEmpty {
                // Subtitle: one heading level below the title (H+1) when
                // the title uses levels; a +2 quiet size otherwise.
                let subFont: NSFont = hs.level != nil
                    ? scaled(ExportItem.HeadingStyle.sizeDelta(forLevel: min(hs.effectiveLevel + 1, 4)),
                             bold: false)
                    : scaled(2, bold: false)
                let subLine = NSMutableAttributedString(attributedString:
                    line(subtitle, font: subFont, after: 8))
                applyHeadingAlignment(hs, to: subLine)
                doc.append(subLine)
            }
            if !m.runningTitle.isEmpty {
                // Running title is page-header METADATA, not a subtitle —
                // it keeps its quiet labeled line.
                doc.append(line("Running title: \(m.runningTitle)", font: meta, color: .darkGray, after: 8))
            }
            if !separateAuthors { doc.append(authorsBlock(item, content: m)) }
            doc.append(spacer())
            return doc
        case .authors:
            let doc = NSMutableAttributedString(attributedString: authorsBlock(item, content: m))
            guard doc.length > 0 else { return nil }
            doc.append(spacer())
            return doc
        case .abstract:
            guard !m.abstract.isEmpty else { return nil }
            let doc = NSMutableAttributedString()
            if item.titleShown { doc.append(headingBlock(item.customTitle ?? "Abstract", style: item.effectiveHeadingStyle)) }
            doc.append(rich(m.abstract, in: m))
            return doc
        case .keywords:
            guard !m.keywords.isEmpty else { return nil }
            let list = m.keywords.joined(
                separator: Self.delimiterText(item.authorDelimiter, fallback: ", "))
            let text = item.titleShown ? "\(headingText(item.customTitle ?? "Keywords")): " + list : list
            return line(text, font: meta, color: .darkGray, after: 10)
        case .section:
            guard let id = item.sectionID,
                  let section = m.sections.first(where: { $0.id == id }),
                  section.active, !section.content.isEmpty else { return nil }
            let doc = NSMutableAttributedString()
            if item.titleShown { doc.append(headingBlock(item.customTitle ?? section.title, style: item.effectiveHeadingStyle)) }
            doc.append(rich(section.content, in: m))
            return doc
        case .figures:
            // Reference-order numbering, matching in-text tokens.
            let figures = m.figures.sorted {
                (refContext.figures[$0.id]?.number ?? $0.number) < (refContext.figures[$1.id]?.number ?? $1.number)
            }
            guard !figures.isEmpty else { return nil }
            let doc = NSMutableAttributedString()
            if item.titleShown { doc.append(headingBlock(item.customTitle ?? "Figures", style: item.effectiveHeadingStyle)) }
            for f in figures {
                let assembly = captionAssembly(
                    number: "Figure \(refContext.figures[f.id]?.number ?? f.number).",
                    title: f.title, caption: f.caption,
                    numberStyle: f.numberStyle, titleStyle: f.titleStyle, captionStyle: f.captionStyle,
                    defaults: ("below", "inline", "below"))
                doc.append(assembly.above)
                if let image = figureImage(f) {
                    doc.append(attachmentBlock(image))
                }
                doc.append(assembly.below)
            }
            return doc
        case .tables:
            let tables = m.tables.sorted {
                (refContext.tables[$0.id]?.number ?? $0.number) < (refContext.tables[$1.id]?.number ?? $1.number)
            }
            guard !tables.isEmpty else { return nil }
            let doc = NSMutableAttributedString()
            if item.titleShown { doc.append(headingBlock(item.customTitle ?? "Tables", style: item.effectiveHeadingStyle)) }
            for t in tables {
                let assembly = captionAssembly(
                    number: "Table \(refContext.tables[t.id]?.number ?? t.number).",
                    title: t.title, caption: t.caption,
                    numberStyle: t.numberStyle, titleStyle: t.titleStyle, captionStyle: t.captionStyle,
                    defaults: ("above", "inline", "below"))
                doc.append(assembly.above)
                doc.append(tableBody(t))
                doc.append(assembly.below)
                if !t.footnotes.isEmpty {
                    doc.append(line("Note. \(t.footnotes)", font: meta, color: .darkGray, after: 8))
                }
                doc.append(spacer())
            }
            return doc
        case .references:
            guard !m.bibliography.isEmpty else { return nil }
            let doc = NSMutableAttributedString()
            if item.titleShown { doc.append(headingBlock(item.customTitle ?? "References", style: item.effectiveHeadingStyle)) }
            let style = item.citationStyle ?? citationStyleDefault
            for (i, entry) in m.bibliography.enumerated() {
                doc.append(referenceLine(number: i + 1, entry: entry, style: style))
            }
            return doc
        case .coverLetter:
            guard !m.letterToEditor.body.isEmpty else { return nil }
            let doc = NSMutableAttributedString()
            // Letterhead sits above everything, like on paper.
            if let head = letterheadBlock(m.letterToEditor, font: base,
                                          width: 612 - format.marginInches * 144) {
                doc.append(head)
            }
            if item.titleShown { doc.append(headingBlock(item.customTitle ?? "Cover Letter", style: item.effectiveHeadingStyle)) }
            let body = NSMutableAttributedString(attributedString: rich(m.letterToEditor.body, in: m))
            resolveLetterTokens(in: body, letter: m.letterToEditor)
            doc.append(body)
            // No ⟦Signature⟧ placed: the drawing still closes the letter.
            if !m.letterToEditor.body.plain.contains(LetterToken.signature.marker),
               let drawn = signatureImageBlock(m.letterToEditor.signatureImageData, font: base) {
                doc.append(drawn)
            }
            return doc
        case .pageBreak:
            return nil   // handled by the segmenter
        }
    }

    // MARK: helpers

    /// Assembles a figure/table caption block from its three parts (index,
    /// title, caption): each part prints independently, resolves its
    /// placement — above the asset, below it, or INLINE joining the
    /// previous printed part's line — and carries its own emphasis.
    /// Defaults reproduce the classic output ("Figure 1. Title" below a
    /// figure / above a table, caption below).
    private func captionAssembly(number: String, title: String, caption: String,
                                 numberStyle: CaptionPartStyle?, titleStyle: CaptionPartStyle?,
                                 captionStyle: CaptionPartStyle?,
                                 defaults: (number: String, title: String, caption: String))
        -> (above: NSAttributedString, below: NSAttributedString) {
        struct Part {
            let text: String
            let style: CaptionPartStyle?
            let defaultPlacement: String
            let defaultBold: Bool
            let metaLook: Bool     // caption: smaller + dark gray
        }
        let parts = [
            Part(text: number, style: numberStyle, defaultPlacement: defaults.number,
                 defaultBold: true, metaLook: false),
            Part(text: title, style: titleStyle, defaultPlacement: defaults.title,
                 defaultBold: true, metaLook: false),
            Part(text: caption, style: captionStyle, defaultPlacement: defaults.caption,
                 defaultBold: false, metaLook: true),
        ]
        func styled(_ part: Part) -> NSAttributedString {
            let fm = NSFontManager.shared
            var font = part.metaLook ? meta : base
            if part.style?.bold ?? part.defaultBold {
                font = fm.convert(font, toHaveTrait: .boldFontMask)
            } else {
                font = fm.convert(font, toNotHaveTrait: .boldFontMask)
            }
            if part.style?.italic == true { font = fm.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: part.metaLook ? NSColor.darkGray : NSColor.black,
            ]
            if part.style?.underline == true {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return NSAttributedString(string: part.text, attributes: attrs)
        }
        var lines: [(place: String, text: NSMutableAttributedString)] = []
        var lastLine: Int? = nil
        for part in parts {
            guard part.style?.isEnabled ?? true, !part.text.isEmpty else { continue }
            let run = styled(part)
            var place = part.style?.placement ?? part.defaultPlacement
            if place == "inline" {
                if let li = lastLine {
                    lines[li].text.append(NSAttributedString(string: " "))
                    lines[li].text.append(run)
                    continue
                }
                place = part.defaultPlacement == "inline" ? "below" : part.defaultPlacement
            }
            lines.append((place, NSMutableAttributedString(attributedString: run)))
            lastLine = lines.count - 1
        }
        func merged(_ place: String, lastAfter: CGFloat) -> NSAttributedString {
            let out = NSMutableAttributedString()
            let mine = lines.filter { $0.place == place }
            for (i, l) in mine.enumerated() {
                let para = NSMutableAttributedString(attributedString: l.text)
                para.append(NSAttributedString(string: "\n"))
                para.addAttribute(.paragraphStyle,
                                  value: paragraph(after: i == mine.count - 1 ? lastAfter : 2),
                                  range: NSRange(location: 0, length: para.length))
                out.append(para)
            }
            return out
        }
        return (merged("above", lastAfter: 2), merged("below", lastAfter: 8))
    }

    /// Section headings export with the first letter capitalized by default
    /// (custom titles and renamed sections included).
    private func headingText(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    /// One numbered reference-list line.  A Zotero-formatted entry renders
    /// with its italics (csl-entry <i> runs — journal and volume names);
    /// entries without one fall back to the generic assembly.
    private func referenceLine(number: Int, entry: BibEntry, style: String) -> NSAttributedString {
        // Override wins verbatim; then the style's cached Zotero formatting
        // (italics preserved); then the generic assembly.
        if entry.isOverrideActive || entry.formattedEntry(for: style) == nil {
            return line("\(number). \(RefEngine.referenceText(entry, style: style))",
                        font: base, after: 4)
        }
        guard let html = entry.formattedEntry(for: style) else {
            return line("\(number). \(RefEngine.fullReference(entry))", font: base, after: 4)
        }
        // Reduce to text + italic ranges: <i>/<\i> become sentinels, all
        // other tags drop, entities decode, then the sentinels lift out.
        var marked = html
            .replacingOccurrences(of: #"(?i)<i>"#, with: "\u{1}", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</i>"#, with: "\u{2}", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, ch) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                             ("&#38;", "&"), ("&nbsp;", " ")] {
            marked = marked.replacingOccurrences(of: entity, with: ch)
        }
        var text = "\(number). "
        var italics: [NSRange] = []
        var start: Int?
        for ch in marked {
            if ch == "\u{1}" { start = (text as NSString).length }
            else if ch == "\u{2}" {
                if let s0 = start {
                    italics.append(NSRange(location: s0, length: (text as NSString).length - s0))
                    start = nil
                }
            } else { text.append(ch) }
        }
        let out = NSMutableAttributedString(attributedString:
            line(text.trimmingCharacters(in: .whitespaces), font: base, after: 4))
        let fm = NSFontManager.shared
        for range in italics where NSMaxRange(range) <= out.length {
            out.enumerateAttribute(.font, in: range) { value, sub, _ in
                let current = (value as? NSFont) ?? base
                out.addAttribute(.font, value: fm.convert(current, toHaveTrait: .italicFontMask),
                                 range: sub)
            }
        }
        return out
    }

    /// A section title with a blank line before and after it, styled per the
    /// item's heading format (bold/underline/centered/size).
    /// Applies the heading's left/center/right alignment to a rendered line.
    private func applyHeadingAlignment(_ style: ExportItem.HeadingStyle,
                                       to text: NSMutableAttributedString) {
        let align: NSTextAlignment
        switch style.effectiveAlignment {
        case "center": align = .center
        case "right":  align = .right
        default:       return
        }
        guard text.length > 0,
              let para = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
        para.alignment = align
        text.addAttribute(.paragraphStyle, value: para,
                          range: NSRange(location: 0, length: text.length))
    }

    private func headingBlock(_ raw: String,
                              style: ExportItem.HeadingStyle = .init()) -> NSAttributedString {
        var font: NSFont
        if style.level != nil {
            // Word-style level sizing (H1/H2/H3 off the document body font).
            font = scaled(ExportItem.HeadingStyle.sizeDelta(forLevel: style.effectiveLevel),
                          bold: style.bold)
        } else if let pt = style.pointSize {
            // Legacy typed point size — pre-level documents keep their look.
            var sized = NSFont(descriptor: base.fontDescriptor, size: pt) ?? base
            if style.bold { sized = NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask) }
            font = sized
        } else {
            font = scaled(style.sizeDelta, bold: style.bold)
        }
        if style.italicOn { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let out = NSMutableAttributedString()
        // The blank line after a heading must carry the document's
        // paragraph style — bare \n renders single-spaced and made the
        // gaps uneven (Aug 2026 feedback).  No blank BEFORE the heading:
        // sections start clean; the separating blank belongs to the END of
        // whatever came before (rich() appends it).
        let blank = NSAttributedString(string: "\n", attributes: [
            .font: base, .paragraphStyle: paragraph(after: 0, before: 0)])
        let heading = style.allCaps == true ? raw.uppercased() : headingText(raw)
        let text = NSMutableAttributedString(attributedString:
            line(heading, font: font, before: 0, after: 0))
        let full = NSRange(location: 0, length: text.length)
        if style.underline {
            text.addAttribute(.underlineStyle,
                              value: NSUnderlineStyle.single.rawValue, range: full)
        }
        applyHeadingAlignment(style, to: text)
        out.append(text)
        out.append(blank)
        return out
    }

    private func paragraph(after: CGFloat = 2, before: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = after
        p.paragraphSpacingBefore = before
        p.lineHeightMultiple = format.lineSpacing
        return p
    }

    private func line(_ text: String, font: NSFont, color: NSColor = .black,
                      before: CGFloat = 0, after: CGFloat = 2) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: [
            .font: font, .foregroundColor: color,
            .paragraphStyle: paragraph(after: after, before: before),
        ])
    }

    private func spacer() -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [
            .font: base, .paragraphStyle: paragraph(after: 0, before: 0)])
    }

    /// Rich prose re-set in the document font: token refresh + chrome strip,
    /// then every run mapped onto the base font keeping bold/italic traits,
    /// and paragraph styles forced to the document's line spacing.
    /// Replaces every [[part]] token with its live expansion (PartEngine),
    /// carrying the token's own attributes into the injected text.
    private func expandParts(_ s: NSMutableAttributedString, content m: Manuscript) {
        var tokens: [(NSRange, PartEngine.Part)] = []
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            guard let url = value as? URL, let part = PartEngine.parse(url) else { return }
            tokens.append((range, part))
        }
        for (range, part) in tokens.sorted(by: { $0.0.location > $1.0.location }) {
            let attrs = s.attributes(at: range.location, effectiveRange: nil)
            s.replaceCharacters(in: range,
                                with: PartEngine.attributed(for: part, content: m,
                                                            tokenAttributes: attrs))
        }
    }

    /// Citations (and any superscript/subscript prose) become transferable:
    /// the semantic NSSuperScript attribute translates into a smaller font
    /// plus an explicit baselineOffset — CoreText's paginator honors the
    /// offset (verified: the bare superscript key is a no-op there) and the
    /// RTF/DOCX writers serialize it as raised text, so Word gets a real
    /// raise instead of "body-type made smaller".
    private func materializeSuperscripts(_ out: NSMutableAttributedString, base: NSFont) {
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.superscript, in: full) { value, range, _ in
            guard let level = value as? Int, level != 0 else { return }
            out.enumerateAttribute(.font, in: range) { f, sub, _ in
                let current = (f as? NSFont) ?? base
                let small = NSFont(descriptor: current.fontDescriptor,
                                   size: (base.pointSize * 0.65).rounded()) ?? current
                out.addAttribute(.font, value: small, range: sub)
            }
            out.addAttribute(.baselineOffset,
                             value: base.pointSize * 0.33 * CGFloat(level), range: range)
            out.removeAttribute(.superscript, range: range)
        }
    }

    private func rich(_ richText: RichText, in m: Manuscript) -> NSAttributedString {
        let source: NSAttributedString
        if let rtf = richText.rtf, let s = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            // Placement tokens expand into the full figure/table FIRST —
            // exportReady strips token links, which would hide them.
            source = RefEngine.exportReady(expandPlacements(s, content: m), context: refContext)
        } else {
            source = NSAttributedString(string: richText.plain)
        }
        let out = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: out.length)
        let fm = NSFontManager.shared
        out.enumerateAttribute(.font, in: full) { value, range, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var font = base
            if traits.contains(.bold)   { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            if traits.contains(.italic) { font = fm.convert(font, toHaveTrait: .italicFontMask) }
            out.addAttribute(.font, value: font, range: range)
        }
        out.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.lineHeightMultiple = format.lineSpacing
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }
        materializeSuperscripts(out, base: base)
        out.addAttribute(.foregroundColor, value: NSColor.black, range: full)
        // Dark-mode storage carries near-white underline/strikethrough
        // colors: on paper the underline vanished and the strikethrough
        // printed as a translucent line.  Removed = lines use the (black)
        // text color.
        out.removeAttribute(.underlineColor, range: full)
        out.removeAttribute(.strikethroughColor, range: full)
        // [[part]] tokens expand LAST so the injected text inherits the
        // fully styled attributes of the token itself.
        expandParts(out, content: m)
        // Every section ENDS with the separating blank line (terminator +
        // one empty line, both carrying the document spacing); nothing is
        // prepended at section starts.
        out.append(NSAttributedString(string: "\n\n", attributes: [
            .font: base, .paragraphStyle: paragraph(after: 0, before: 0)]))
        return out
    }

    // MARK: Figure/table rendering helpers

    /// The figure's exportable image: the processed file image, or the chart
    /// rendered from its SQL data.
    private func figureImage(_ figure: Figure) -> NSImage? {
        if figure.dataAssetID != nil {
            return chartImage?(figure)
        }
        guard let url = figureURL?(figure), let image = NSImage(contentsOf: url) else { return nil }
        return FigureImaging.processed(image, crop: figure.crop,
                                       scalePercent: figure.scalePercent,
                                       monochrome: figure.monochrome)
    }

    /// An image attachment sized into the text column, centered.
    private func attachmentBlock(_ image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        let maxWidth: CGFloat = 612 - format.marginInches * 144 - 12
        let size = image.size
        let scale = size.width > maxWidth ? maxWidth / size.width : 1
        attachment.bounds = CGRect(x: 0, y: 0,
                                   width: size.width * scale, height: size.height * scale)
        let out = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = 6
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
        return out
    }

    // MARK: Table construction
    //
    // A table exports as a REAL table with boundaries that wrap the values:
    //   PDF       — a drawn grid (CoreText has no table layout): measured
    //               columns, wrapped cells, rules/shading per the table's
    //               formatting, page-height-aware chunks.
    //   DOCX/RTF  — NSTextTable cells, so Word/Pages get a native table.
    // Sources: the SQL result for data-linked tables, else parsed pipe rows.

    /// The rows of a table: SQL result (data-linked) or parsed pipe syntax.
    private func tableGrid(_ t: ManuscriptTable) -> (columns: [String], rows: [[String]])? {
        if let result = tableData?(t), !result.columns.isEmpty {
            return (result.columns, result.rows)
        }
        return Self.pipeRows(t.content)
    }

    /// The table body block for `t`, in the right construction for the
    /// output type; plain mono text only when nothing parses as a table.
    func tableBody(_ t: ManuscriptTable) -> NSAttributedString {
        guard let grid = tableGrid(t), !grid.columns.isEmpty else {
            return t.content.isEmpty ? NSAttributedString()
                : line(t.content, font: .monospacedSystemFont(ofSize: format.fontSize - 1, weight: .regular), after: 4)
        }
        // Normalize row widths; keep runaway result sets bounded.
        let capped = grid.rows.prefix(200).map { row in
            grid.columns.indices.map { $0 < row.count ? row[$0] : "" }
        }
        let out = NSMutableAttributedString()
        if fileType == .pdf {
            out.append(drawnTableBlock(columns: grid.columns, rows: Array(capped), table: t))
        } else {
            out.append(textTableBlock(columns: grid.columns, rows: Array(capped), table: t))
        }
        if grid.rows.count > 200 {
            out.append(line("… \(grid.rows.count - 200) more rows (see data)", font: meta, color: .darkGray, after: 4))
        }
        return out
    }

    /// Markdown pipe rows → (header, data rows); nil when it isn't a table.
    static func pipeRows(_ content: String) -> (columns: [String], rows: [[String]])? {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("|") }
        let rows: [[String]] = lines.compactMap { lineText in
            var l = lineText
            if l.hasPrefix("|") { l.removeFirst() }
            if l.hasSuffix("|") { l.removeLast() }
            let cells = l.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            // Skip the |---|---| separator row.
            let isRule = cells.allSatisfy { cell in cell.allSatisfy { "-:".contains($0) } }
                && cells.contains { $0.contains("-") }
            return isRule ? nil : cells
        }
        guard let header = rows.first, header.count >= 2 else { return nil }
        return (header, Array(rows.dropFirst()))
    }

    /// Width available to a table (one text column of the page).
    private var tableWidth: CGFloat {
        let content: CGFloat = 612 - format.marginInches * 144
        return format.twoColumn ? (content - 18) / 2 : content
    }

    private var tableCellFont: NSFont {
        NSFont(descriptor: base.fontDescriptor, size: max(9, format.fontSize - 1)) ?? base
    }

    /// Column widths as fractions of the table width: natural (widest cell)
    /// widths, capped so one long column can't starve the rest, normalized.
    private func columnFractions(columns: [String], rows: [[String]]) -> [CGFloat] {
        let cellFont = tableCellFont
        let headerFont = NSFontManager.shared.convert(cellFont, toHaveTrait: .boldFontMask)
        var naturals: [CGFloat] = columns.indices.map { i in
            var w = (columns[i] as NSString).size(withAttributes: [.font: headerFont]).width
            for row in rows {
                w = max(w, (row[i] as NSString).size(withAttributes: [.font: cellFont]).width)
            }
            return min(max(w + 12, 34), tableWidth * 0.55)
        }
        let total = naturals.reduce(0, +)
        if total <= 0 { naturals = naturals.map { _ in 1 } }
        let sum = naturals.reduce(0, +)
        return naturals.map { $0 / sum }
    }

    /// DOCX/RTF: a native NSTextTable — bordered cells that wrap values.
    private func textTableBlock(columns: [String], rows: [[String]], table t: ManuscriptTable) -> NSAttributedString {
        let cellFont = tableCellFont
        let headerFont = NSFontManager.shared.convert(cellFont, toHaveTrait: .boldFontMask)
        let open = t.openSides ?? false
        let shade = t.alternateShading ?? false
        let fractions = columnFractions(columns: columns, rows: rows)
        let lastRow = rows.count   // header is row 0

        let table = NSTextTable()
        table.numberOfColumns = columns.count
        table.setContentWidth(100, type: .percentageValueType)

        let out = NSMutableAttributedString()
        func appendCell(_ text: String, row: Int, col: Int) {
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                         startingColumn: col, columnSpan: 1)
            block.setValue(fractions[col] * 100, type: .percentageValueType, for: .width)
            block.setWidth(4, type: .absoluteValueType, for: .padding)
            block.setBorderColor(.black)
            if open {
                // Journal style: horizontal rules only.
                block.setWidth(0, type: .absoluteValueType, for: .border)
                if row == 0 {
                    block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
                    block.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .maxY)
                }
                if row == lastRow {
                    block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                }
            } else {
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
            }
            if row == 0 {
                if !open { block.backgroundColor = NSColor(white: 0.92, alpha: 1) }
            } else if shade, row % 2 == 1 {
                block.backgroundColor = NSColor(white: 0.955, alpha: 1)
            }
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: row == 0 ? headerFont : cellFont,
                .foregroundColor: NSColor.black,
                .paragraphStyle: style,
            ]))
        }

        for (col, name) in columns.enumerated() { appendCell(name, row: 0, col: col) }
        for (r, row) in rows.enumerated() {
            for (col, value) in row.enumerated() { appendCell(value, row: r + 1, col: col) }
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
        return out
    }

    /// PDF: the grid drawn into image chunks (vector text isn't available in
    /// the CoreText paginator) — measured columns, wrapped cells, rules and
    /// shading per the table's formatting, split so chunks fit a page.
    private func drawnTableBlock(columns: [String], rows: [[String]], table t: ManuscriptTable) -> NSAttributedString {
        let cellFont = tableCellFont
        let headerFont = NSFontManager.shared.convert(cellFont, toHaveTrait: .boldFontMask)
        let open = t.openSides ?? false
        let shade = t.alternateShading ?? false
        let width = tableWidth
        let pad: CGFloat = 5
        let widths = columnFractions(columns: columns, rows: rows).map { $0 * width }

        func cellHeight(_ text: String, columnWidth: CGFloat, font: NSFont) -> CGFloat {
            guard !text.isEmpty else { return ceil(font.ascender - font.descender) }
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: columnWidth - pad * 2, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font])
            return ceil(bounds.height)
        }
        let headerHeight = columns.indices
            .map { cellHeight(columns[$0], columnWidth: widths[$0], font: headerFont) }
            .max()! + pad * 2
        let rowHeights = rows.map { row in
            columns.indices.map { cellHeight(row[$0], columnWidth: widths[$0], font: cellFont) }
                .max()! + pad * 2
        }

        // Chunk rows so each image (header repeated) fits within a page.
        let maxChunkHeight: CGFloat = 620
        var chunks: [[Int]] = []
        var current: [Int] = []
        var height = headerHeight
        for (i, h) in rowHeights.enumerated() {
            if !current.isEmpty, height + h > maxChunkHeight {
                chunks.append(current)
                current = []
                height = headerHeight
            }
            current.append(i)
            height += h
        }
        if !current.isEmpty { chunks.append(current) }

        func drawChunk(_ indices: [Int]) -> NSImage {
            let heights = [headerHeight] + indices.map { rowHeights[$0] }
            let totalHeight = heights.reduce(0, +)
            let size = NSSize(width: width, height: totalHeight)
            return NSImage(size: size, flipped: true) { _ in
                NSColor.white.setFill()
                NSRect(origin: .zero, size: size).fill()

                // Backgrounds first.
                var y: CGFloat = 0
                for (rowIndex, rowHeight) in heights.enumerated() {
                    defer { y += rowHeight }
                    if rowIndex == 0 {
                        if !open {
                            NSColor(white: 0.92, alpha: 1).setFill()
                            NSRect(x: 0, y: y, width: width, height: rowHeight).fill()
                        }
                    } else if shade, indices[rowIndex - 1] % 2 == 1 {
                        NSColor(white: 0.955, alpha: 1).setFill()
                        NSRect(x: 0, y: y, width: width, height: rowHeight).fill()
                    }
                }

                // Cell text, wrapped inside its column.
                y = 0
                for (rowIndex, rowHeight) in heights.enumerated() {
                    let cells = rowIndex == 0 ? columns : rows[indices[rowIndex - 1]]
                    let font = rowIndex == 0 ? headerFont : cellFont
                    var x: CGFloat = 0
                    for (col, columnWidth) in widths.enumerated() where col < cells.count {
                        (cells[col] as NSString).draw(
                            in: NSRect(x: x + pad, y: y + pad,
                                       width: columnWidth - pad * 2, height: rowHeight - pad * 2),
                            withAttributes: [.font: font, .foregroundColor: NSColor.black])
                        x += columnWidth
                    }
                    y += rowHeight
                }

                // Rules.
                NSColor.black.setStroke()
                func hLine(_ atY: CGFloat, _ lineWidth: CGFloat) {
                    let path = NSBezierPath()
                    path.lineWidth = lineWidth
                    path.move(to: NSPoint(x: 0, y: atY))
                    path.line(to: NSPoint(x: width, y: atY))
                    path.stroke()
                }
                var boundaries: [CGFloat] = [0]
                var acc: CGFloat = 0
                for h in heights { acc += h; boundaries.append(acc) }
                if open {
                    hLine(0.5, 1.2)                                  // top rule
                    hLine(boundaries[1], 0.9)                        // header rule
                    hLine(totalHeight - 0.5, 1.2)                    // bottom rule
                    if !shade {
                        for b in boundaries.dropFirst(2).dropLast() { hLine(b, 0.4) }
                    }
                } else {
                    for b in boundaries { hLine(min(max(b, 0.4), totalHeight - 0.4), 0.6) }
                    var xs: [CGFloat] = [0]
                    var xAcc: CGFloat = 0
                    for w in widths { xAcc += w; xs.append(xAcc) }
                    for xb in xs {
                        let path = NSBezierPath()
                        path.lineWidth = 0.6
                        let x = min(max(xb, 0.4), width - 0.4)
                        path.move(to: NSPoint(x: x, y: 0))
                        path.line(to: NSPoint(x: x, y: totalHeight))
                        path.stroke()
                    }
                }
                return true
            }
        }

        let out = NSMutableAttributedString()
        for chunk in chunks {
            let image = drawChunk(chunk)
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: image.size)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 4
            let block = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            block.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: block.length))
            block.append(NSAttributedString(string: "\n", attributes: [.font: base]))
            out.append(block)
        }
        return out
    }

    // MARK: Placement tokens (⟦Figure 2 here⟧ → the rendered figure/table)

    /// Replaces figure/table placement tokens with their rendered blocks —
    /// the figure image (crop/scale/B&W applied) or the table content, each
    /// with its numbered caption — exactly where the author placed them.
    private func expandPlacements(_ attributed: NSAttributedString, content m: Manuscript) -> NSAttributedString {
        var targets: [(NSRange, RefEngine.Token)] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.link, in: full) { value, range, _ in
            guard let url = value as? URL, let token = RefEngine.Token.parse(url),
                  token.kind == .figurePlacement || token.kind == .tablePlacement
            else { return }
            targets.append((range, token))
        }
        guard !targets.isEmpty else { return attributed }
        let out = NSMutableAttributedString(attributedString: attributed)
        for (range, token) in targets.sorted(by: { $0.0.location > $1.0.location }) {
            out.replaceCharacters(in: range, with: placementBlock(for: token, content: m))
        }
        return out
    }

    private func placementBlock(for token: RefEngine.Token, content m: Manuscript) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "\n", attributes: [.font: base])
        switch token.kind {
        case .figurePlacement:
            guard let figure = m.figures.first(where: { $0.id == token.targetID }) else {
                return NSAttributedString(string: "")
            }
            let number = refContext.figures[figure.id]?.number ?? figure.number
            let assembly = captionAssembly(
                number: "Figure \(number).", title: figure.title, caption: figure.caption,
                numberStyle: figure.numberStyle, titleStyle: figure.titleStyle,
                captionStyle: figure.captionStyle,
                defaults: ("below", "inline", "below"))
            out.append(assembly.above)
            if let image = figureImage(figure) {
                out.append(attachmentBlock(image))
            }
            out.append(assembly.below)
        case .tablePlacement:
            guard let table = m.tables.first(where: { $0.id == token.targetID }) else {
                return NSAttributedString(string: "")
            }
            let number = refContext.tables[table.id]?.number ?? table.number
            let assembly = captionAssembly(
                number: "Table \(number).", title: table.title, caption: table.caption,
                numberStyle: table.numberStyle, titleStyle: table.titleStyle,
                captionStyle: table.captionStyle,
                defaults: ("above", "inline", "below"))
            out.append(assembly.above)
            out.append(tableBody(table))
            out.append(assembly.below)
            if !table.footnotes.isEmpty {
                out.append(line("Note. \(table.footnotes)", font: meta, color: .darkGray, after: 6))
            }
        default:
            break
        }
        return out
    }
}


// MARK: - PDFPaginator

/// Dependency-free PDF renderer: paginates attributed segments with CoreText.
/// Each segment starts on a new page (page breaks); the format's margins,
/// single/two-column layout, and continuous line numbering are honored exactly.
private struct PDFPaginator {
    let format: ExportDocumentFormat

    private let pageSize = CGSize(width: 612, height: 792)   // US Letter, points

    func render(sections: [ExportService.PageSection]) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }

        let gap: CGFloat = 18
        var lineNumber = 1
        for section in sections where section.text.length > 0 {
            // Each section carries its own page geometry (margins, columns).
            let raw = section.text
            let margin = CGFloat(section.marginInches * 72)
            let contentRect = CGRect(x: margin, y: margin,
                                     width: pageSize.width - 2 * margin,
                                     height: pageSize.height - 2 * margin)
            let columns = section.twoColumn ? 2 : 1
            let columnWidth = (contentRect.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            // CoreText ignores NSTextAttachment: without run delegates the
            // layout collapses images (charts, letterheads, signatures,
            // table grids) to nothing.  Reserve their space here and draw
            // them ourselves after each frame.
            let segment = withAttachmentDelegates(raw)
            let framesetter = CTFramesetterCreateWithAttributedString(segment)
            var location = 0
            while location < segment.length {
                ctx.beginPDFPage(nil)
                for column in 0..<columns where location < segment.length {
                    let rect = CGRect(x: contentRect.minX + CGFloat(column) * (columnWidth + gap),
                                      y: contentRect.minY, width: columnWidth, height: contentRect.height)
                    let frame = CTFramesetterCreateFrame(
                        framesetter, CFRange(location: location, length: 0),
                        CGPath(rect: rect, transform: nil), nil)
                    CTFrameDraw(frame, ctx)
                    drawAttachments(frame, frameRect: rect, context: ctx)
                    drawLineNumbers(frame, segment: segment, columnRect: rect,
                                    context: ctx, next: &lineNumber)
                    let visible = CTFrameGetVisibleStringRange(frame)
                    guard visible.length > 0 else { location = segment.length; break }
                    location += visible.length
                }
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return data as Data
    }

    /// Sizing box handed to each attachment's CTRunDelegate.
    private final class AttachmentBox {
        let size: CGSize
        init(size: CGSize) { self.size = size }
    }

    /// Wraps every NSTextAttachment run in a CTRunDelegate so CoreText
    /// reserves the image's bounds during layout.
    private func withAttachmentDelegates(_ input: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: input)
        input.enumerateAttribute(.attachment, in: NSRange(location: 0, length: input.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            var size = attachment.bounds.size
            if size == .zero { size = attachment.image?.size ?? .zero }
            guard size.width > 0, size.height > 0 else { return }
            var callbacks = CTRunDelegateCallbacks(
                version: kCTRunDelegateCurrentVersion,
                dealloc: { Unmanaged<AttachmentBox>.fromOpaque($0).release() },
                getAscent: { Unmanaged<AttachmentBox>.fromOpaque($0).takeUnretainedValue().size.height },
                getDescent: { _ in 0 },
                getWidth: { Unmanaged<AttachmentBox>.fromOpaque($0).takeUnretainedValue().size.width })
            let box = AttachmentBox(size: size)
            if let delegate = CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(box).toOpaque()) {
                out.addAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String),
                                 value: delegate, range: range)
            }
        }
        return out
    }

    /// Draws attachment images at their laid-out positions (run delegates
    /// only reserve space; the pixels are ours to paint).
    private func drawAttachments(_ frame: CTFrame, frameRect: CGRect, context: CGContext) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(lines, origins) {
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in runs {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard let attachment = attrs[NSAttributedString.Key.attachment] as? NSTextAttachment,
                      let image = attachment.image else { continue }
                var size = attachment.bounds.size
                if size == .zero { size = image.size }
                guard size.width > 0, size.height > 0 else { continue }
                let xOffset = CTLineGetOffsetForStringIndex(
                    line, CTRunGetStringRange(run).location, nil)
                let rect = CGRect(x: frameRect.minX + origin.x + xOffset,
                                  y: frameRect.minY + origin.y,
                                  width: size.width, height: size.height)
                // Rasterize at 3× so drawn tables/handler-backed images stay
                // crisp in print (bitmap-backed images just return their rep).
                let zoom = NSAffineTransform()
                zoom.scale(by: 3)
                if let cg = image.cgImage(forProposedRect: nil, context: nil,
                                          hints: [.ctm: zoom]) {
                    context.draw(cg, in: rect)
                }
            }
        }
    }

    /// Continuous line numbers in the margin left of each column — only for
    /// lines whose text carries the per-item line-number attribute (set from
    /// the item's effective format by `OutlineBuilder`).
    private func drawLineNumbers(_ frame: CTFrame, segment: NSAttributedString,
                                 columnRect: CGRect, context: CGContext, next: inout Int) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let text = segment.string as NSString
        for (line, origin) in zip(lines, origins) {
            let range = CTLineGetStringRange(line)
            guard range.location >= 0, range.location < segment.length,
                  segment.attribute(ExportAttr.lineNumbers, at: range.location,
                                    effectiveRange: nil) != nil else { continue }
            // Blank lines count too — the margin numbering matches the
            // editor's gutter, which numbers every visual line.
            _ = text   // (content no longer inspected)
            let label = NSAttributedString(string: "\(next)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .regular),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.gray.cgColor,
            ])
            let ctLine = CTLineCreateWithAttributedString(label)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            // Line origins are relative to the frame's path origin.
            context.textPosition = CGPoint(x: columnRect.minX - width - 8,
                                           y: columnRect.minY + origin.y)
            CTLineDraw(ctLine, context)
            next += 1
        }
    }
}

// MARK: - Small helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - NSFont bold helper

private extension NSFont {
    func bold() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}
