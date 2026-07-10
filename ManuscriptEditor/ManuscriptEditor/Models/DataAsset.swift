// DataAsset.swift
//
// Represents a raw data asset stored in the manuscript's Data library.
// Two flavours exist: tabular CSV data (persisted as a SQLite database) and
// imported images.  Both live in the manuscript's `data/` sub-directory.
//
// When a Figure in Content references a DataAsset, the figure is rendered as
// a chart (line / bar / histogram) by querying the associated SQLite database.
// When a Table in Content references a DataAsset, the table rows are populated
// by running the stored SQL query against the SQLite database.

import Foundation

// MARK: - Supporting enums

/// The storage / rendering type of a `DataAsset`.
enum DataAssetType: String, Codable, Sendable {
    case csv    // Tabular data; stored as SQLite at data/{id}.sqlite
    case image  // Imported image file; stored at data/{id}.{ext}
}

/// Chart styles available for figures that are derived from tabular data.
///
/// `histogram` is retired from the UI (a histogram is a bar chart over
/// SQL-binned buckets — `GROUP BY` expresses it directly) but stays decodable
/// so older files keep opening; it renders as a bar chart.
enum ChartType: String, Codable, CaseIterable, Sendable {
    case line
    case bar
    case histogram

    /// The chart styles offered in pickers (excludes retired cases).
    static var selectable: [ChartType] { [.line, .bar] }

    var label: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .line:      return "chart.line.uptrend.xyaxis"
        case .bar:       return "chart.bar"
        case .histogram: return "chart.bar.xaxis"
        }
    }
}

// MARK: - DataAsset

/// One entry in the manuscript's Data library.
///
/// - CSV assets:   `fileName` points to `{id}.sqlite` inside `data/`.
///                 `lastQuery` is the most recent SQL the user ran.
/// - Image assets: `fileName` points to the image file (e.g. `{id}.png`).
///                 `lastQuery` is ignored.
struct DataAsset: Codable, Identifiable, Sendable {

    /// Stable unique identifier; also used as part of the file name on disk.
    var id: UUID

    /// Human-readable name shown in the Data panel (default = original file name).
    var name: String

    /// Whether this asset is tabular data or an image.
    var type: DataAssetType

    /// File name relative to the manuscript's `data/` directory.
    var fileName: String

    /// When this asset was first imported.
    var importedAt: Date

    /// The last SQL query the user ran against this asset (CSV only).
    var lastQuery: String

    // MARK: - Factory

    static func emptyCSV(name: String) -> DataAsset {
        DataAsset(
            id: UUID(),
            name: name,
            type: .csv,
            fileName: "",               // set by DataService after SQLite creation
            importedAt: Date(),
            lastQuery: "SELECT * FROM data"
        )
    }

    static func emptyImage(name: String) -> DataAsset {
        DataAsset(
            id: UUID(),
            name: name,
            type: .image,
            fileName: "",               // set after import
            importedAt: Date(),
            lastQuery: ""
        )
    }
}
