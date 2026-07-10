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
        try copyFigureImages(content, figureURL: figureURL, into: folder)

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
        figureURL: (Figure) -> URL?,
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
                let segments = pageSegments(for: document, content: content, refContext: refContext)
                let data = PDFPaginator(format: document.format).render(segments: segments)
                try data.write(to: url, options: .atomic)
            case .docx, .rtf:
                let segments = pageSegments(for: document, content: content, refContext: refContext)
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
                let tex = latexDocument(document, content: content)
                try Data(tex.utf8).write(to: url, options: .atomic)
            }
        }

        // Copy figure images whenever any document includes the figures block.
        if config.documents.contains(where: { doc in doc.items.contains { $0.kind == .figures } }) {
            try copyFigureImages(content, figureURL: figureURL, into: folder)
        }
        return folder
    }

    // MARK: Outline assembly (attributed)

    /// Renders a document's items into attributed segments; a new segment
    /// starts at every page break.
    private func pageSegments(for document: ExportDocument, content: Manuscript,
                              refContext: RefEngine.Context) -> [NSAttributedString] {
        let builder = OutlineBuilder(format: document.format, refContext: refContext)
        var segments: [NSAttributedString] = []
        var current = NSMutableAttributedString()
        for item in document.items {
            if item.kind == .pageBreak {
                if current.length > 0 { segments.append(current) }
                current = NSMutableAttributedString()
                continue
            }
            if let block = builder.block(for: item, content: content) {
                current.append(block)
            }
        }
        if current.length > 0 { segments.append(current) }
        return segments
    }

    // MARK: LaTeX writer

    /// Emits a self-contained .tex source for one document.  Section bodies are
    /// exported as escaped plain text (styling is not translated in v1);
    /// two-column and line numbering map to `twocolumn` and the `lineno` package.
    private func latexDocument(_ document: ExportDocument, content m: Manuscript) -> String {
        let f = document.format
        let pt = Int(f.fontSize.rounded()).clamped(to: 10...12)
        var options = ["\(pt)pt"]
        if f.twoColumn { options.append("twocolumn") }

        var out = "\\documentclass[\(options.joined(separator: ","))]{article}\n"
        out += "\\usepackage[margin=\(String(format: "%.2f", f.marginInches))in]{geometry}\n"
        out += "\\usepackage{setspace}\n"
        let anyLineNumbers = f.lineNumbers || document.items.contains { $0.format?.lineNumbers == true }
        if anyLineNumbers { out += "\\usepackage{lineno}\n" }
        out += "\\begin{document}\n"
        if f.lineSpacing >= 2.0 { out += "\\doublespacing\n" }
        else if f.lineSpacing >= 1.3 { out += "\\onehalfspacing\n" }

        // Line numbering follows each item's effective format.
        var numbering = false
        for item in document.items {
            if anyLineNumbers, item.kind != .pageBreak {
                let wanted = item.format?.lineNumbers ?? f.lineNumbers
                if wanted != numbering {
                    out += wanted ? "\\linenumbers\n" : "\\nolinenumbers\n"
                    numbering = wanted
                }
            }
            switch item.kind {
            case .titlePage:
                out += "\\title{\(tex(m.title))}\n"
                let authors = m.authors.sorted { $0.order < $1.order }.map { tex($0.fullName) }
                out += "\\author{\(authors.joined(separator: " \\and "))}\n\\date{}\n\\maketitle\n"
            case .abstract:
                if !m.abstract.isEmpty {
                    out += "\\begin{abstract}\n\(tex(m.abstract.plain))\n\\end{abstract}\n"
                }
            case .keywords:
                if !m.keywords.isEmpty {
                    out += "\\noindent\\textbf{Keywords:} \(tex(m.keywords.joined(separator: ", ")))\n\n"
                }
            case .section:
                if let id = item.sectionID,
                   let section = m.sections.first(where: { $0.id == id }),
                   section.active, !section.content.isEmpty {
                    out += "\\section{\(tex(latexHeading(item.customTitle ?? section.title)))}\n\(tex(section.content.plain))\n\n"
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
                    for entry in m.bibliography {
                        out += "\\bibitem{\(entry.key.isEmpty ? entry.id.uuidString : entry.key)} \(tex(RefEngine.fullReference(entry)))\n"
                    }
                    out += "\\end{thebibliography}\n"
                }
            case .coverLetter:
                if !m.letterToEditor.body.isEmpty {
                    out += "\\section*{Cover Letter}\n\(tex(m.letterToEditor.body.plain))\n\n"
                    if !m.letterToEditor.signature.isEmpty {
                        out += "\\noindent \(tex(m.letterToEditor.signature))\n"
                    }
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

        doc.append(line(m.title.isEmpty ? "Untitled Manuscript" : m.title, font: titleFont, spacingAfter: 8))
        if !m.runningTitle.isEmpty {
            doc.append(line("Running title: \(m.runningTitle)", font: metaFont, color: .secondaryLabelColor, spacingAfter: 8))
        }

        // Authors + affiliations.
        let authors = m.authors.sorted { $0.order < $1.order }
        if !authors.isEmpty {
            let names = authors.map { $0.fullName + ($0.isCorresponding ? "*" : "") }
                .joined(separator: ", ")
            doc.append(line(names, font: bodyFont, spacingAfter: 2))
            var seen = Set<String>()
            for aff in authors.flatMap({ $0.affiliations }) where !aff.isEmpty && seen.insert(aff).inserted {
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
            doc.append(heading("Cover Letter"))
            doc.append(rich(m.letterToEditor.body, refContext))
            if !m.letterToEditor.signature.isEmpty {
                doc.append(line(m.letterToEditor.signature, font: bodyFont, color: .secondaryLabelColor, spacingAfter: 2))
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

        let figures = m.figures.sorted { $0.number < $1.number }
        if !figures.isEmpty {
            doc.append(heading("Figures"))
            for f in figures {
                doc.append(line("Figure \(f.number). \(f.title)", font: bodyFont.bold(), spacingAfter: 2))
                if !f.caption.isEmpty {
                    doc.append(line(f.caption, font: metaFont, color: .secondaryLabelColor, spacingAfter: 8))
                }
            }
            doc.append(spacer())
        }

        let tables = m.tables.sorted { $0.number < $1.number }
        if !tables.isEmpty {
            doc.append(heading("Tables"))
            for t in tables {
                doc.append(line("Table \(t.number). \(t.title)", font: bodyFont.bold(), spacingAfter: 2))
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

    private func copyFigureImages(_ m: Manuscript, figureURL: (Figure) -> URL?, into folder: URL) throws {
        let fm = FileManager.default
        let figuresDir = folder.appendingPathComponent("figures", isDirectory: true)
        var created = false
        for figure in m.figures.sorted(by: { $0.number < $1.number }) {
            guard let src = figureURL(figure), fm.fileExists(atPath: src.path) else { continue }
            if !created {
                try fm.createDirectory(at: figuresDir, withIntermediateDirectories: true)
                created = true
            }
            // Cropped/resized figures are rendered to PNG so the package
            // contains exactly what the user framed; others copy verbatim.
            if FigureImaging.needsRendering(figure),
               let image = NSImage(contentsOf: src),
               let data = FigureImaging.pngData(
                   FigureImaging.processed(image, crop: figure.crop, scalePercent: figure.scalePercent)) {
                let dest = figuresDir.appendingPathComponent("Figure \(figure.number).png")
                try? fm.removeItem(at: dest)
                try? data.write(to: dest)
            } else {
                let dest = figuresDir.appendingPathComponent("Figure \(figure.number).\(src.pathExtension)")
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

    /// Renders `item`, honoring its format override and custom title, and
    /// stamps the line-number attribute when its effective format asks for it.
    func block(for item: ExportItem, content m: Manuscript) -> NSAttributedString? {
        let effective = effectiveFormat(for: item)
        let builder = OutlineBuilder(format: effective, refContext: refContext)
        guard let rendered = builder.renderBlock(item, content: m) else { return nil }
        guard effective.lineNumbers else { return rendered }
        let out = NSMutableAttributedString(attributedString: rendered)
        out.addAttribute(ExportAttr.lineNumbers, value: true,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Item override wins for typography; page geometry stays the document's.
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

    private func renderBlock(_ item: ExportItem, content m: Manuscript) -> NSAttributedString? {
        switch item.kind {
        case .titlePage:
            let doc = NSMutableAttributedString()
            doc.append(line(m.title.isEmpty ? "Untitled Manuscript" : m.title, font: title, after: 8))
            if !m.runningTitle.isEmpty {
                doc.append(line("Running title: \(m.runningTitle)", font: meta, color: .darkGray, after: 8))
            }
            let authors = m.authors.sorted { $0.order < $1.order }
            if !authors.isEmpty {
                let names = authors.map { $0.fullName + ($0.isCorresponding ? "*" : "") }.joined(separator: ", ")
                doc.append(line(names, font: base, after: 2))
                var seen = Set<String>()
                for aff in authors.flatMap({ $0.affiliations }) where !aff.isEmpty && seen.insert(aff).inserted {
                    doc.append(line(aff, font: meta, color: .darkGray, after: 1))
                }
            }
            doc.append(spacer())
            return doc
        case .abstract:
            guard !m.abstract.isEmpty else { return nil }
            let doc = NSMutableAttributedString(attributedString: headingBlock(item.customTitle ?? "Abstract"))
            doc.append(rich(m.abstract))
            return doc
        case .keywords:
            guard !m.keywords.isEmpty else { return nil }
            return line("\(headingText(item.customTitle ?? "Keywords")): " + m.keywords.joined(separator: ", "), font: meta, color: .darkGray, after: 10)
        case .section:
            guard let id = item.sectionID,
                  let section = m.sections.first(where: { $0.id == id }),
                  section.active, !section.content.isEmpty else { return nil }
            let doc = NSMutableAttributedString(attributedString: headingBlock(item.customTitle ?? section.title))
            doc.append(rich(section.content))
            return doc
        case .figures:
            let figures = m.figures.sorted { $0.number < $1.number }
            guard !figures.isEmpty else { return nil }
            let doc = NSMutableAttributedString(attributedString: headingBlock(item.customTitle ?? "Figures"))
            for f in figures {
                doc.append(line("Figure \(f.number). \(f.title)",
                                font: NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask), after: 2))
                if !f.caption.isEmpty { doc.append(line(f.caption, font: meta, color: .darkGray, after: 8)) }
            }
            return doc
        case .tables:
            let tables = m.tables.sorted { $0.number < $1.number }
            guard !tables.isEmpty else { return nil }
            let doc = NSMutableAttributedString(attributedString: headingBlock(item.customTitle ?? "Tables"))
            for t in tables {
                doc.append(line("Table \(t.number). \(t.title)",
                                font: NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask), after: 2))
                if !t.content.isEmpty {
                    doc.append(line(t.content, font: .monospacedSystemFont(ofSize: format.fontSize - 1, weight: .regular), after: 4))
                }
                if !t.caption.isEmpty { doc.append(line(t.caption, font: meta, color: .darkGray, after: 8)) }
            }
            return doc
        case .references:
            guard !m.bibliography.isEmpty else { return nil }
            let doc = NSMutableAttributedString(attributedString: headingBlock(item.customTitle ?? "References"))
            for (i, entry) in m.bibliography.enumerated() {
                doc.append(line("\(i + 1). \(RefEngine.fullReference(entry))", font: base, after: 4))
            }
            return doc
        case .coverLetter:
            guard !m.letterToEditor.body.isEmpty else { return nil }
            let doc = NSMutableAttributedString(attributedString: headingBlock(item.customTitle ?? "Cover Letter"))
            doc.append(rich(m.letterToEditor.body))
            if !m.letterToEditor.signature.isEmpty {
                doc.append(line(m.letterToEditor.signature, font: base, color: .darkGray, after: 2))
            }
            return doc
        case .pageBreak:
            return nil   // handled by the segmenter
        }
    }

    // MARK: helpers

    /// Section headings export with the first letter capitalized by default
    /// (custom titles and renamed sections included).
    private func headingText(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    /// A section title with a blank line before and after it.
    private func headingBlock(_ raw: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
        out.append(line(headingText(raw), font: heading, before: 0, after: 0))
        out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
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
        NSAttributedString(string: "\n", attributes: [.font: base])
    }

    /// Rich prose re-set in the document font: token refresh + chrome strip,
    /// then every run mapped onto the base font keeping bold/italic traits,
    /// and paragraph styles forced to the document's line spacing.
    private func rich(_ richText: RichText) -> NSAttributedString {
        let source: NSAttributedString
        if let rtf = richText.rtf, let s = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            source = RefEngine.exportReady(s, context: refContext)
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
        out.addAttribute(.foregroundColor, value: NSColor.black, range: full)
        out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
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

    func render(segments: [NSAttributedString]) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }

        let margin = CGFloat(format.marginInches * 72)
        let contentRect = CGRect(x: margin, y: margin,
                                 width: pageSize.width - 2 * margin,
                                 height: pageSize.height - 2 * margin)
        let columns = format.twoColumn ? 2 : 1
        let gap: CGFloat = 18
        let columnWidth = (contentRect.width - gap * CGFloat(columns - 1)) / CGFloat(columns)

        var lineNumber = 1
        for segment in segments where segment.length > 0 {
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
            // Number text lines only — blank spacer lines (around headings,
            // between blocks) get no number, like LaTeX's lineno.
            let content = text.substring(with: NSRange(location: range.location, length: range.length))
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
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
