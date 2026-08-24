// Figure.swift
//
// Represents one figure panel in the manuscript.  The actual image file lives on disk
// (in the manuscript's figures/ sub-directory); this struct holds the metadata and a
// pointer (fileName) to that file.

import Foundation
import CoreGraphics

/// Styling for one part of a figure/table caption block — the index
/// ("Figure 1"), the title, or the caption paragraph.  Each part prints
/// independently, sits above/inline/below the asset, and carries its own
/// emphasis.  All fields optional so older files keep decoding (nil = the
/// part's default).
struct CaptionPartStyle: Codable, Sendable, Equatable {
    /// nil = on.
    var enabled: Bool? = nil
    /// Legacy placement ("above"/"inline"/"below") — superseded by the
    /// piece ORDER in `arrangement`; kept so Aug 2026 files decode.
    var placement: String? = nil
    var bold: Bool? = nil
    var italic: Bool? = nil
    var underline: Bool? = nil
    /// "left" | "center" | "right"; nil = left.
    var align: String? = nil

    var isEnabled: Bool { enabled ?? true }
    var effectiveAlign: String { align ?? "left" }
}

/// Metadata for a single manuscript figure, plus an optional link to its image file.
///
/// Image files are stored separately from the JSON to keep the manuscript file small.
/// `PersistenceService` manages copying images into the manuscript's folder on disk.
///
/// Equatable so the figure editor can watch its whole draft with one
/// `onChange` instead of a per-field modifier chain.
struct Figure: Codable, Identifiable, Sendable, Equatable {

    /// Stable unique identifier used as the image file name on disk (e.g. `{id}.png`).
    var id: UUID

    /// Human-readable figure number (Figure 1, Figure 2, …).
    /// The user can change this; it does not have to match the array index.
    var number: Int

    /// Short descriptive title shown in the sidebar and above the caption on export.
    var title: String

    /// Full figure caption — the paragraph that appears below the figure in the paper.
    var caption: String

    /// File name of the image within the manuscript's `figures/` directory (e.g. `{uuid}.png`).
    /// `nil` when no image has been imported yet.
    var fileName: String?

    /// Image sourced from the central Data library (an image `DataAsset` id).
    /// Takes precedence over `fileName` — raw images live once in Data and are
    /// referenced (never copied) by figures.
    var imageAssetID: UUID? = nil

    /// Crop rectangle, normalized 0–1 in image coordinates (origin top-left).
    /// nil = uncropped.  Applied in previews and rendered into the export.
    var crop: CGRect? = nil

    /// Output size as a percentage of the (cropped) original, 10–100.
    /// nil = 100%.  Applied when rendering the export package.
    var scalePercent: Double? = nil

    /// Render the figure in black & white (grayscale).  nil/false = original
    /// colors.  Like crop/scale this is a per-figure presentation choice —
    /// the original image in the Data library is never modified.
    var monochrome: Bool? = nil

    /// Text description for accessibility / screen readers.  No longer
    /// edited (these are print manuscripts) but kept so older files decode.
    var altText: String

    /// Per-part caption styling (index / title / caption): print toggle,
    /// above/inline/below placement, and emphasis.  nil = defaults
    /// (index+title inline below the figure, caption below).
    var numberStyle: CaptionPartStyle? = nil
    var titleStyle: CaptionPartStyle? = nil
    var captionStyle: CaptionPartStyle? = nil

    /// Rich caption (character-level bold/italic/underline/alignment).
    /// When set it is the caption's source of truth; `caption` keeps the
    /// plain mirror.  nil = legacy plain caption.
    var captionText: RichText? = nil

    /// The pieces of the exported figure in print order.  nil = the classic
    /// ["image", "title", "caption"].  The title piece renders
    /// "Figure N. Title" (the index folds in; legacy numberStyle.enabled ==
    /// false drops the prefix).
    var arrangement: [String]? = nil
    /// Image alignment on the page: "left" | "center" | "right"; nil = left.
    var imageAlign: String? = nil

    // MARK: - Data-derived chart fields (optional)

    /// When set, this figure is a chart generated from a `DataAsset` (CSV).
    var dataAssetID: UUID?

    /// Which chart style to render (nil → this is an imported image, not a chart).
    var chartType: ChartType?

    /// The SQL query used to fetch data for this chart.
    var chartQuery: String?

    /// Category color palette for the chart ("Default", "Vivid", "Pastel",
    /// "Monochrome").  nil = Default.  Colors series when the SELECT has a
    /// third (category) column.
    var chartPalette: String?

    // MARK: - Factory

    /// A blank figure ready for the user to fill in, with a placeholder title.
    static func empty(number: Int) -> Figure {
        Figure(id: UUID(), number: number, title: "Figure \(number)", caption: "",
               fileName: nil, altText: "", dataAssetID: nil, chartType: nil, chartQuery: nil)
    }
}
