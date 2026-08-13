// ManuscriptTable.swift
//
// Represents one data table in the manuscript.  Table content is stored as Markdown
// (pipe-delimited rows) so it can be rendered, edited in plain text, and exported to
// LaTeX or DOCX via simple post-processing.

import Foundation

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
    var footnotes: String

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
