// DocxWriter.swift
//
// A Word document, written by hand.
//
// WHY THE APP WRITES ITS OWN
// ─────────────────────────────────────────────────────────────────────────────
// DOCX used to come out of `NSAttributedString.data(from:documentAttributes:)`
// with `.officeOpenXML`.  Measured on macOS 26 (a probe that saved a table, an
// image and a double-spaced paragraph and read the XML back), that writer
// emits:
//
//   • NO TABLES.  Every `NSTextTable` cell becomes a paragraph of its own —
//     a table exported as one column of values.
//   • NO IMAGES.  Attachments are dropped: figures, and a letterhead's logo.
//   • NO PARAGRAPH PROPERTIES.  `<w:pPr>` is empty: line spacing is lost.
//   • and it has no notion of sections, columns, page numbers, or line
//     numbering, which an attributed string cannot express in the first place.
//
// Fonts and sizes were the only things that survived, so a Word export
// matched its preview in nothing but the typeface.  None of that is fixable
// by changing what the writer is handed.
//
// WHAT THIS WRITES
// ─────────────────────────────────────────────────────────────────────────────
// The same page sections the PDF paginator consumes (`ExportService
// .PageSection`), one Word SECTION each, so geometry means the same thing in
// both outputs:
//
//   section     margins · one or two columns · continuous line numbering when
//               its text carries the line-number attribute · a centred page
//               number in the footer when asked for
//   paragraph   line height (`lineHeightMultiple` → w:spacing/@w:line),
//               space before/after, indents, tab stops, alignment
//   run         family, size, bold, italic, underline, strikethrough, colour,
//               highlight, and a real super/subscript (the export's
//               materialized "smaller font + baseline offset" is turned back
//               into w:vertAlign, which is what Word means by it)
//   table       a `w:tbl` built from consecutive paragraphs that share an
//               `NSTextTable`: spans, percentage widths, per-edge borders,
//               shading, cell padding, vertical alignment
//   image       an inline PNG, sized by its attachment's bounds
//
// The package is a ZIP of stored (uncompressed) parts, written here too —
// no third-party code, and no shelling out for something this small.
//
// See MasterContext/05-features.md (Export) and 08-engineering-standards.md.

import AppKit
import Foundation

enum DocxWriter {

    /// One Word section: the text and the page geometry it is set in.
    struct Section {
        let text: NSAttributedString
        let marginInches: Double
        let twoColumn: Bool
        let pageNumbers: Bool

        init(text: NSAttributedString, marginInches: Double = 1, twoColumn: Bool = false,
             pageNumbers: Bool = false) {
            self.text = text
            self.marginInches = marginInches
            self.twoColumn = twoColumn
            self.pageNumbers = pageNumbers
        }
    }

    /// The finished `.docx`.
    ///
    /// - Parameters:
    ///   - lineNumberKey: the attribute that marks numbered lines (the PDF
    ///     paginator's own); a section with any marked text is numbered, and
    ///     its unmarked paragraphs opt out.
    ///   - tableAlignKey: the attribute a table's cells carry when the table
    ///     itself sits centred or right on the page ("center" | "right").
    ///   - baseFont / lineSpacing: the document's typography, written as the
    ///     defaults so text typed into the file later matches.
    static func data(sections: [Section], lineNumberKey: NSAttributedString.Key? = nil,
                     tableAlignKey: NSAttributedString.Key? = nil,
                     baseFont: NSFont = .systemFont(ofSize: 12), lineSpacing: Double = 1) -> Data {
        ZipWriter.archive(parts(sections: sections, lineNumberKey: lineNumberKey,
                                tableAlignKey: tableAlignKey,
                                baseFont: baseFont, lineSpacing: lineSpacing))
    }

    /// The package's parts, in the order they are written.  Exposed so the
    /// harness can read `word/document.xml` without unzipping.
    static func parts(sections: [Section], lineNumberKey: NSAttributedString.Key? = nil,
                      tableAlignKey: NSAttributedString.Key? = nil,
                      baseFont: NSFont = .systemFont(ofSize: 12),
                      lineSpacing: Double = 1) -> [(name: String, data: Data)] {
        let builder = Builder(lineNumberKey: lineNumberKey, tableAlignKey: tableAlignKey)
        let document = builder.document(sections.isEmpty ? [Section(text: NSAttributedString())] : sections)

        var contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        """
        for footer in builder.footers {
            contentTypes += "<Override PartName=\"/word/\(footer.name)\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>"
        }
        contentTypes += "</Types>"

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        </Relationships>
        """

        var documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        for rel in builder.relationships {
            documentRels += "<Relationship Id=\"\(rel.id)\" Type=\"\(rel.type)\" Target=\"\(rel.target)\"/>"
        }
        documentRels += "</Relationships>"

        var out: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/_rels/document.xml.rels", Data(documentRels.utf8)),
            ("word/styles.xml", Data(styles(baseFont: baseFont, lineSpacing: lineSpacing).utf8)),
        ]
        for footer in builder.footers { out.append(("word/\(footer.name)", Data(footer.xml.utf8))) }
        for media in builder.media { out.append(("word/media/\(media.name)", media.data)) }
        return out.map { (name: $0.0, data: $0.1) }
    }

    // MARK: - Units

    /// Points → twentieths of a point (Word's "twips").
    fileprivate static func twips(_ points: CGFloat) -> Int { Int((points * 20).rounded()) }
    /// Points → English Metric Units (drawing extents).
    fileprivate static func emu(_ points: CGFloat) -> Int { Int((points * 12_700).rounded()) }

    fileprivate static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // Control characters are not legal XML 1.0 and would make the
                // whole document unreadable; nothing in a manuscript needs one.
                if scalar.value < 0x20 && scalar != "\t" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    fileprivate static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }

    /// A face Word can name.  The system font has no family Word knows
    /// (".AppleSystemUIFont"), so it travels as Helvetica Neue, its nearest
    /// installed relative.
    fileprivate static func family(_ font: NSFont) -> String {
        let name = font.familyName ?? font.fontName
        return name.hasPrefix(".") ? "Helvetica Neue" : name
    }

    // MARK: - Styles

    private static func styles(baseFont: NSFont, lineSpacing: Double) -> String {
        let face = escape(family(baseFont))
        let size = Int((baseFont.pointSize * 2).rounded())
        let line = Int((240 * max(lineSpacing, 0.5)).rounded())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr>\
        <w:rFonts w:ascii="\(face)" w:hAnsi="\(face)" w:cs="\(face)" w:eastAsia="\(face)"/>\
        <w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/><w:lang w:val="en-US"/>\
        </w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="\(line)" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
        </w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:uiPriority w:val="99"/><w:semiHidden/>\
        <w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr>\
        </w:style>\
        </w:styles>
        """
    }

    // MARK: - Document

    private final class Builder {
        let lineNumberKey: NSAttributedString.Key?
        let tableAlignKey: NSAttributedString.Key?
        var media: [(name: String, data: Data)] = []
        var relationships: [(id: String, type: String, target: String)] = []
        var footers: [(name: String, xml: String)] = []
        private var footerIDs: (numbered: String, blank: String)?
        private var drawingID = 0

        init(lineNumberKey: NSAttributedString.Key?, tableAlignKey: NSAttributedString.Key?) {
            self.lineNumberKey = lineNumberKey
            self.tableAlignKey = tableAlignKey
        }

        // One element of a section's flow: a paragraph, or a table of them.
        private enum Element {
            case paragraph(NSRange)
            case table(NSTextTable, [(block: NSTextTableBlock, range: NSRange)])
        }

        func document(_ sections: [Section]) -> String {
            // A footer is inherited from the previous section unless a section
            // names its own, so once ANY section prints page numbers every
            // section has to say which footer it wears.
            if sections.contains(where: \.pageNumbers) { makeFooters() }

            var body = ""
            for (index, section) in sections.enumerated() {
                let isLast = index == sections.count - 1
                let properties = sectionProperties(section, isLast: isLast)
                let numbered = isNumbered(section.text)
                let elements = self.elements(of: section.text)
                let contentWidth = CGFloat(8.5 - 2 * section.marginInches) * 72

                for (i, element) in elements.enumerated() {
                    // A section ends in the pPr of its last paragraph (the
                    // final one closes the body instead).
                    let closes = !isLast && i == elements.count - 1
                    switch element {
                    case .paragraph(let range):
                        body += paragraph(section.text, range: range, numberedSection: numbered,
                                          sectionProperties: closes ? properties : nil)
                    case .table(let table, let cells):
                        body += self.table(table, cells: cells, in: section.text,
                                           contentWidth: contentWidth, numberedSection: numbered)
                        // A table cannot carry a section break, and Word wants
                        // a paragraph after one anyway.
                        if closes { body += "<w:p><w:pPr>\(properties)</w:pPr></w:p>" }
                    }
                }
                if elements.isEmpty, !isLast { body += "<w:p><w:pPr>\(properties)</w:pPr></w:p>" }
                if isLast {
                    if case .table = elements.last { body += "<w:p/>" }
                    body += properties
                }
            }

            return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">\
            <w:body>\(body)</w:body></w:document>
            """
        }

        // MARK: Sections

        private func isNumbered(_ text: NSAttributedString) -> Bool {
            guard let key = lineNumberKey, text.length > 0 else { return false }
            var found = false
            text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length)) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            return found
        }

        private func sectionProperties(_ section: Section, isLast: Bool) -> String {
            let margin = Int((section.marginInches * 1440).rounded())
            var out = "<w:sectPr>"
            if let ids = footerIDs {
                out += "<w:footerReference w:type=\"default\" r:id=\"\(section.pageNumbers ? ids.numbered : ids.blank)\"/>"
            }
            out += "<w:type w:val=\"nextPage\"/>"
            out += "<w:pgSz w:w=\"12240\" w:h=\"15840\"/>"
            out += "<w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/>"
            // Continuous, so the count carries across sections the way the
            // PDF's does; a section with nothing marked is simply not numbered.
            if isNumbered(section.text) {
                out += "<w:lnNumType w:countBy=\"1\" w:restart=\"continuous\"/>"
            }
            out += section.twoColumn ? "<w:cols w:num=\"2\" w:space=\"360\"/>" : "<w:cols w:space=\"720\"/>"
            return out + "</w:sectPr>"
        }

        private func makeFooters() {
            let namespaces = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
            let numbered = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:ftr \(namespaces)><w:p><w:pPr><w:jc w:val="center"/></w:pPr>\
            <w:r><w:rPr><w:sz w:val="19"/></w:rPr><w:fldChar w:fldCharType="begin"/></w:r>\
            <w:r><w:rPr><w:sz w:val="19"/></w:rPr><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>\
            <w:r><w:rPr><w:sz w:val="19"/></w:rPr><w:fldChar w:fldCharType="separate"/></w:r>\
            <w:r><w:rPr><w:sz w:val="19"/></w:rPr><w:t>1</w:t></w:r>\
            <w:r><w:rPr><w:sz w:val="19"/></w:rPr><w:fldChar w:fldCharType="end"/></w:r>\
            </w:p></w:ftr>
            """
            let blank = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:ftr \(namespaces)><w:p/></w:ftr>
            """
            footers = [("footer1.xml", numbered), ("footer2.xml", blank)]
            let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"
            relationships.append(("rIdFooter1", type, "footer1.xml"))
            relationships.append(("rIdFooter2", type, "footer2.xml"))
            footerIDs = ("rIdFooter1", "rIdFooter2")
        }

        // MARK: Flow

        /// Splits a section's text into paragraphs and groups the ones that
        /// belong to a text table.
        private func elements(of text: NSAttributedString) -> [Element] {
            let string = text.string as NSString
            var out: [Element] = []
            var location = 0
            while location < string.length {
                let range = string.paragraphRange(for: NSRange(location: location, length: 0))
                defer { location = NSMaxRange(range) }
                let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                guard let block = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first else {
                    out.append(.paragraph(range))
                    continue
                }
                if case .table(let table, var cells)? = out.last, table === block.table {
                    cells.append((block, range))
                    out[out.count - 1] = .table(table, cells)
                } else {
                    out.append(.table(block.table, [(block, range)]))
                }
            }
            return out
        }

        // MARK: Paragraphs

        private func paragraph(_ text: NSAttributedString, range: NSRange, numberedSection: Bool,
                               sectionProperties: String?) -> String {
            let string = text.string as NSString
            // The paragraph without its terminator.
            var content = range
            while content.length > 0 {
                let last = string.character(at: NSMaxRange(content) - 1)
                guard last == 0x0A || last == 0x0D || last == 0x2029 else { break }
                content.length -= 1
            }
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle

            var properties = ""
            if numberedSection, let key = lineNumberKey,
               text.attribute(key, at: range.location, effectiveRange: nil) == nil {
                properties += "<w:suppressLineNumbers/>"
            }
            properties += paragraphProperties(style)
            if let sectionProperties { properties += sectionProperties }

            return "<w:p><w:pPr>\(properties)</w:pPr>\(runs(text, range: content))</w:p>"
        }

        /// tabs · spacing · ind · jc — in the order the schema wants them.
        private func paragraphProperties(_ style: NSParagraphStyle?) -> String {
            var out = ""
            if let stops = style?.tabStops, !stops.isEmpty, stops.count <= 12 {
                out += "<w:tabs>"
                for stop in stops {
                    let kind: String
                    switch stop.alignment {
                    case .center: kind = "center"
                    case .right:  kind = "right"
                    default:      kind = "left"
                    }
                    out += "<w:tab w:val=\"\(kind)\" w:pos=\"\(DocxWriter.twips(stop.location))\"/>"
                }
                out += "</w:tabs>"
            }
            // A multiple of 0 means "unset", which is single spacing.
            let multiple = (style?.lineHeightMultiple ?? 0) > 0 ? style!.lineHeightMultiple : 1
            let before = DocxWriter.twips(style?.paragraphSpacingBefore ?? 0)
            let after = DocxWriter.twips(style?.paragraphSpacing ?? 0)
            out += "<w:spacing w:before=\"\(before)\" w:after=\"\(after)\" w:line=\"\(Int((240 * multiple).rounded()))\" w:lineRule=\"auto\"/>"

            let head = style?.headIndent ?? 0, first = style?.firstLineHeadIndent ?? 0
            if head != 0 || first != 0 {
                let delta = first - head
                out += "<w:ind w:left=\"\(DocxWriter.twips(head))\""
                out += delta >= 0 ? " w:firstLine=\"\(DocxWriter.twips(delta))\"/>"
                                  : " w:hanging=\"\(DocxWriter.twips(-delta))\"/>"
            }
            switch style?.alignment ?? .natural {
            case .center:    out += "<w:jc w:val=\"center\"/>"
            case .right:     out += "<w:jc w:val=\"right\"/>"
            case .justified: out += "<w:jc w:val=\"both\"/>"
            default:         break
            }
            return out
        }

        // MARK: Runs

        private func runs(_ text: NSAttributedString, range: NSRange) -> String {
            guard range.length > 0 else { return "" }
            var out = ""
            text.enumerateAttributes(in: range) { attrs, run, _ in
                let properties = self.runProperties(attrs)
                if let attachment = attrs[.attachment] as? NSTextAttachment {
                    if let drawing = self.drawing(attachment) {
                        out += "<w:r>\(properties)\(drawing)</w:r>"
                    }
                    return
                }
                out += "<w:r>\(properties)\(self.runContent(text.attributedSubstring(from: run).string))</w:r>"
            }
            return out
        }

        /// Text with its tabs, soft breaks and page breaks as the elements
        /// Word has for them.
        private func runContent(_ string: String) -> String {
            var out = ""
            var pending = ""
            func flush() {
                guard !pending.isEmpty else { return }
                out += "<w:t xml:space=\"preserve\">\(DocxWriter.escape(pending))</w:t>"
                pending = ""
            }
            for scalar in string.unicodeScalars {
                switch scalar.value {
                case 0x09:   flush(); out += "<w:tab/>"
                case 0x2028: flush(); out += "<w:br/>"
                case 0x0C:   flush(); out += "<w:br w:type=\"page\"/>"
                case 0xFFFC: continue                    // an attachment with nothing to draw
                default:     pending.unicodeScalars.append(scalar)
                }
            }
            flush()
            return out
        }

        /// rFonts · b · i · strike · color · sz · u · shd · vertAlign.
        private func runProperties(_ attrs: [NSAttributedString.Key: Any]) -> String {
            let font = attrs[.font] as? NSFont
            var out = "<w:rPr>"
            var size = font?.pointSize

            // The export materializes a script as a shrunk font plus a
            // baseline offset (what CoreText honours).  Word has the real
            // thing, and shrinks it itself — so the size goes back to the
            // body's, or it would be shrunk twice.
            var script = (attrs[.superscript] as? Int) ?? 0
            if let offset = (attrs[.baselineOffset] as? NSNumber)?.doubleValue, offset != 0 {
                script = offset > 0 ? 1 : -1
                size = size.map { ($0 / 0.65).rounded() }
            }

            if let font {
                let face = DocxWriter.escape(DocxWriter.family(font))
                out += "<w:rFonts w:ascii=\"\(face)\" w:hAnsi=\"\(face)\" w:cs=\"\(face)\" w:eastAsia=\"\(face)\"/>"
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold)   { out += "<w:b/>" }
                if traits.contains(.italic) { out += "<w:i/>" }
            }
            if ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0 { out += "<w:strike/>" }
            if let color = attrs[.foregroundColor] as? NSColor, let hex = DocxWriter.hex(color),
               hex != "000000" {
                out += "<w:color w:val=\"\(hex)\"/>"
            }
            if let size {
                let half = Int((size * 2).rounded())
                out += "<w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/>"
            }
            if ((attrs[.underlineStyle] as? Int) ?? 0) != 0 { out += "<w:u w:val=\"single\"/>" }
            if let fill = attrs[.backgroundColor] as? NSColor, let hex = DocxWriter.hex(fill) {
                out += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(hex)\"/>"
            }
            if script != 0 {
                out += "<w:vertAlign w:val=\"\(script > 0 ? "superscript" : "subscript")\"/>"
            }
            return out + "</w:rPr>"
        }

        // MARK: Images

        private func drawing(_ attachment: NSTextAttachment) -> String? {
            guard let image = attachment.image else { return nil }
            var size = attachment.bounds.size
            if size.width <= 0 || size.height <= 0 { size = image.size }
            guard size.width > 0, size.height > 0, let png = pngData(image) else { return nil }

            drawingID += 1
            let name = "image\(drawingID).png"
            let relation = "rIdImage\(drawingID)"
            media.append((name, png))
            relationships.append((relation, "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "media/\(name)"))

            let cx = DocxWriter.emu(size.width), cy = DocxWriter.emu(size.height)
            return """
            <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
            <wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(drawingID)" name="Picture \(drawingID)"/>\
            <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:nvPicPr><pic:cNvPr id="\(drawingID)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="\(relation)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
            """
        }

        /// The image as a PNG.  A drawn (handler-backed) image is rendered at
        /// 3× so type inside it stays crisp in print; a bitmap comes back at
        /// the resolution it already has.
        private func pngData(_ image: NSImage) -> Data? {
            let zoom = NSAffineTransform()
            zoom.scale(by: 3)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: zoom]) {
                return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }

        // MARK: Tables

        private func table(_ table: NSTextTable, cells: [(block: NSTextTableBlock, range: NSRange)],
                           in text: NSAttributedString, contentWidth: CGFloat,
                           numberedSection: Bool) -> String {
            // A cell is every consecutive paragraph that shares a block.
            var grouped: [(block: NSTextTableBlock, ranges: [NSRange])] = []
            for cell in cells {
                if let last = grouped.last, last.block === cell.block {
                    grouped[grouped.count - 1].ranges.append(cell.range)
                } else {
                    grouped.append((cell.block, [cell.range]))
                }
            }

            let columnCount = max(table.numberOfColumns,
                                  grouped.map { $0.block.startingColumn + $0.block.columnSpan }.max() ?? 1, 1)
            let rowCount = (grouped.map { $0.block.startingRow + $0.block.rowSpan }.max() ?? 1)

            // The table's width: a percentage of the text column, as set.
            var tablePercent: CGFloat = 100
            if table.contentWidthValueType == .percentageValueType, table.contentWidth > 0 {
                tablePercent = min(table.contentWidth, 100)
            }
            let tableWidth = contentWidth * tablePercent / 100

            // Column widths from the single-column cells that state one;
            // whatever is left is shared by the columns that don't.
            var fractions = [CGFloat?](repeating: nil, count: columnCount)
            for cell in grouped where cell.block.columnSpan == 1 && cell.block.startingColumn < columnCount {
                let value = cell.block.value(for: .width)
                guard value > 0, fractions[cell.block.startingColumn] == nil else { continue }
                fractions[cell.block.startingColumn] =
                    cell.block.valueType(for: .width) == .percentageValueType ? value / 100 : value / max(tableWidth, 1)
            }
            let stated = fractions.compactMap { $0 }.reduce(0, +)
            let unstated = fractions.filter { $0 == nil }.count
            let share = unstated > 0 ? max(1 - stated, 0) / CGFloat(unstated) : 0
            var widths = fractions.map { $0 ?? share }
            let total = widths.reduce(0, +)
            widths = total > 0 ? widths.map { $0 / total } : widths.map { _ in 1 / CGFloat(columnCount) }

            var out = "<w:tbl><w:tblPr>"
            // Absolute widths (twips), table and cells alike: the text
            // column's width is known here, and readers agree about twips
            // where they differ about percentages.
            out += "<w:tblW w:w=\"\(DocxWriter.twips(tableWidth))\" w:type=\"dxa\"/>"
            // The table's own place on the page — not its cells' text.
            if let key = tableAlignKey, let first = cells.first,
               let align = text.attribute(key, at: first.range.location, effectiveRange: nil) as? String,
               align == "center" || align == "right" {
                out += "<w:jc w:val=\"\(align)\"/>"
            }
            out += "<w:tblLayout w:type=\"fixed\"/>"
            out += "</w:tblPr><w:tblGrid>"
            for width in widths { out += "<w:gridCol w:w=\"\(DocxWriter.twips(tableWidth * width))\"/>" }
            out += "</w:tblGrid>"

            for row in 0..<rowCount {
                let inRow = grouped.filter { $0.block.startingRow == row }
                    .sorted { $0.block.startingColumn < $1.block.startingColumn }
                guard !inRow.isEmpty else { continue }
                out += "<w:tr>"
                var column = 0
                for cell in inRow {
                    // A gap before this cell (a column the row never names).
                    while column < cell.block.startingColumn {
                        out += "<w:tc><w:tcPr><w:tcW w:w=\"\(DocxWriter.twips(tableWidth * widths[column]))\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                        column += 1
                    }
                    let span = max(cell.block.columnSpan, 1)
                    let fraction = widths[column..<min(column + span, columnCount)].reduce(0, +)
                    out += "<w:tc>\(cellProperties(cell.block, width: tableWidth * fraction, span: span))"
                    for range in cell.ranges {
                        out += paragraph(text, range: range, numberedSection: numberedSection,
                                         sectionProperties: nil)
                    }
                    out += "</w:tc>"
                    column += span
                }
                while column < columnCount {
                    out += "<w:tc><w:tcPr><w:tcW w:w=\"\(DocxWriter.twips(tableWidth * widths[column]))\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                    column += 1
                }
                out += "</w:tr>"
            }
            return out + "</w:tbl>"
        }

        /// tcW · gridSpan · tcBorders · shd · tcMar · vAlign.
        private func cellProperties(_ block: NSTextTableBlock, width: CGFloat, span: Int) -> String {
            var out = "<w:tcPr><w:tcW w:w=\"\(DocxWriter.twips(width))\" w:type=\"dxa\"/>"
            if span > 1 { out += "<w:gridSpan w:val=\"\(span)\"/>" }

            out += "<w:tcBorders>"
            for (name, edge) in [("top", NSRectEdge.minY), ("left", .minX), ("bottom", .maxY), ("right", .maxX)] {
                let width = block.width(for: .border, edge: edge)
                if width > 0 {
                    let color = block.borderColor(for: edge).flatMap(DocxWriter.hex) ?? "000000"
                    // Eighths of a point; Word draws nothing thinner than 2.
                    out += "<w:\(name) w:val=\"single\" w:sz=\"\(max(Int((width * 8).rounded()), 2))\" w:space=\"0\" w:color=\"\(color)\"/>"
                } else {
                    out += "<w:\(name) w:val=\"nil\"/>"
                }
            }
            out += "</w:tcBorders>"

            if let fill = block.backgroundColor, let hex = DocxWriter.hex(fill) {
                out += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(hex)\"/>"
            }

            out += "<w:tcMar>"
            for (name, edge) in [("top", NSRectEdge.minY), ("left", .minX), ("bottom", .maxY), ("right", .maxX)] {
                out += "<w:\(name) w:w=\"\(DocxWriter.twips(block.width(for: .padding, edge: edge)))\" w:type=\"dxa\"/>"
            }
            out += "</w:tcMar>"

            switch block.verticalAlignment {
            case .middleAlignment: out += "<w:vAlign w:val=\"center\"/>"
            case .bottomAlignment: out += "<w:vAlign w:val=\"bottom\"/>"
            default:               out += "<w:vAlign w:val=\"top\"/>"
            }
            return out + "</w:tcPr>"
        }
    }
}

// MARK: - ZIP

/// The smallest ZIP that is still a ZIP: stored entries, one central
/// directory.  A `.docx` is a few kilobytes of XML and images that are
/// already compressed, so there is nothing for deflate to win.
private enum ZipWriter {

    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var directory = Data()
        // 1980-01-01 00:00 — a fixed stamp, so the same document is the same
        // bytes every time it is exported.
        let time: UInt16 = 0, date: UInt16 = (0 << 9) | (1 << 5) | 1

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            out.append(le32(0x0403_4B50))
            out.append(le16(20)); out.append(le16(0)); out.append(le16(0))
            out.append(le16(time)); out.append(le16(date))
            out.append(le32(crc)); out.append(le32(size)); out.append(le32(size))
            out.append(le16(UInt16(name.count))); out.append(le16(0))
            out.append(name)
            out.append(entry.data)

            directory.append(le32(0x0201_4B50))
            directory.append(le16(20)); directory.append(le16(20))
            directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(time)); directory.append(le16(date))
            directory.append(le32(crc)); directory.append(le32(size)); directory.append(le32(size))
            directory.append(le16(UInt16(name.count)))
            directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0))
            directory.append(le32(0))
            directory.append(le32(offset))
            directory.append(name)
        }

        let directoryOffset = UInt32(out.count)
        out.append(directory)
        out.append(le32(0x0605_4B50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(entries.count))); out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(directory.count)))
        out.append(le32(directoryOffset))
        out.append(le16(0))
        return out
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
