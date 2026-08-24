// ManuscriptTable.swift
//
// Represents one data table in the manuscript.  Table content is stored as Markdown
// (pipe-delimited rows) so it can be rendered, edited in plain text, and exported to
// LaTeX or DOCX via simple post-processing.

import Foundation

/// One cell of a manually edited table: its text plus optional emphasis.
/// All style fields optional so older files decode (nil = plain).
struct TableCell: Codable, Sendable, Equatable {
    var text: String = ""
    var bold: Bool? = nil
    var italic: Bool? = nil
    var underline: Bool? = nil
    /// Highlighted cell background.
    var highlight: Bool? = nil
    /// Highlight color name ("yellow" default, "green", "blue", "pink",
    /// "orange") — meaningful while `highlight == true`.
    var highlightColor: String? = nil
    /// "left" | "center" | "right"; nil = left.
    var align: String? = nil
}

/// Metadata and content for a single manuscript table.
struct ManuscriptTable: Codable, Identifiable, Sendable, Equatable {

    /// Stable unique identifier.
    var id: UUID

    /// Human-readable table number (Table 1, Table 2, …).
    var number: Int

    /// Short descriptive title shown above the table on export.
    var title: String

    /// Caption paragraph displayed below the table in the paper.
    var caption: String

    /// The table body stored as Markdown pipe syntax, for example:
    ///
    ///     | Gene  | Fold change | p-value |
    ///     |-------|-------------|---------|
    ///     | BRCA1 | 2.4         | 0.003   |
    ///
    /// `TableEditor` presents this in a monospaced editor so columns stay aligned.
    var content: String

    /// Notes that appear below the table (e.g. abbreviation key, statistical notes).
    /// No longer edited per table (a manuscript-wide footnote system will
    /// replace it) but kept so older files decode and still export.
    var footnotes: String

    /// Per-part caption styling (index / title / caption): print toggle,
    /// above/inline/below placement, and emphasis.  nil = defaults
    /// (index+title inline above the table, caption below).
    var numberStyle: CaptionPartStyle? = nil
    var titleStyle: CaptionPartStyle? = nil
    var captionStyle: CaptionPartStyle? = nil

    /// Grid-edited cells (first row = header).  When set, this is the
    /// table's source of truth; `content` keeps a plain pipe-Markdown
    /// mirror so older readers and word counts keep working.
    var cells: [[TableCell]]? = nil

    /// The pieces of the exported table in print order.  nil = the classic
    /// ["title", "table", "caption"].  The title piece renders
    /// "Table N. Title" (the index folds in; legacy numberStyle.enabled ==
    /// false drops the prefix).
    var arrangement: [String]? = nil

    /// Exported table width as a % of the page's text column (25–100).
    /// nil = 100.
    var tableWidthPercent: Double? = nil
    /// Table alignment when narrower than the column: "left" | "center" |
    /// "right"; nil = left.
    var tableAlign: String? = nil

    /// Rich caption (character-level bold/italic/underline/alignment).
    /// When set it is the caption's source of truth; `caption` keeps the
    /// plain mirror.  nil = legacy plain caption.
    var captionText: RichText? = nil

    /// Export autofit: the 1-based row DATA starts at (the header is row 1).
    /// nil = 2; higher values drop the rows between the header and N.
    var dataStartRow: Int? = nil

    // MARK: - Data-linked table fields (optional)

    /// When set, table rows are populated by running `dataQuery` against this DataAsset.
    var dataAssetID: UUID?

    /// SQL SELECT query run against the linked DataAsset to populate table rows.
    var dataQuery: String?

    // MARK: - Export formatting (optional — older files keep decoding)

    /// Journal style: horizontal rules only (open left/right sides) instead
    /// of a fully boxed grid.
    var openSides: Bool? = nil

    /// Light shading on alternating data rows.
    var alternateShading: Bool? = nil

    /// A query result merged with a style overlay: texts from the data,
    /// styles from `overlay` at the same coordinates (row 0 = header).
    /// Used by the styling-only grid for data-linked tables and by the
    /// export, so what you style is what prints.
    static func styledGrid(result: QueryResult, overlay: [[TableCell]]?) -> [[TableCell]] {
        func styled(_ text: String, _ r: Int, _ c: Int) -> TableCell {
            var cell = (overlay?.indices.contains(r) == true
                        && overlay![r].indices.contains(c)) ? overlay![r][c] : TableCell()
            cell.text = text
            return cell
        }
        var grid: [[TableCell]] = [result.columns.enumerated().map { styled($0.1, 0, $0.0) }]
        grid += result.rows.enumerated().map { ri, row in
            row.enumerated().map { styled($0.1, ri + 1, $0.0) }
        }
        return grid
    }

    // MARK: - Grid <-> Markdown

    /// Plain pipe-Markdown mirror of a cell grid.
    static func markdown(from cells: [[TableCell]]) -> String {
        guard let header = cells.first else { return "" }
        var out = "| " + header.map(\.text).joined(separator: " | ") + " |\n"
        out += "|" + header.map { _ in "---" }.joined(separator: "|") + "|\n"
        for row in cells.dropFirst() {
            out += "| " + row.map(\.text).joined(separator: " | ") + " |\n"
        }
        return out
    }

    /// Parses pipe Markdown into a plain cell grid (nil when it isn't one).
    static func cellGrid(fromPipe content: String) -> [[TableCell]]? {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("|") }
        let rows: [[String]] = lines.compactMap { lineText in
            var l = lineText
            if l.hasPrefix("|") { l.removeFirst() }
            if l.hasSuffix("|") { l.removeLast() }
            let cells = l.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let isRule = cells.allSatisfy { cell in cell.allSatisfy { "-:".contains($0) } }
                && cells.contains { $0.contains("-") }
            return isRule ? nil : cells
        }
        guard let header = rows.first, !header.isEmpty else { return nil }
        let width = rows.map(\.count).max() ?? header.count
        return rows.map { row in
            (0..<width).map { TableCell(text: $0 < row.count ? row[$0] : "") }
        }
    }

    // MARK: - Factory

    /// A blank table with a starter template already in `content`.
    static func empty(number: Int) -> ManuscriptTable {
        ManuscriptTable(
            id: UUID(),
            number: number,
            title: "Table \(number)",
            caption: "",
            content: "| Column 1 | Column 2 | Column 3 |\n|----------|----------|----------|\n|          |          |          |",
            footnotes: "",
            dataAssetID: nil,
            dataQuery: nil
        )
    }
}
