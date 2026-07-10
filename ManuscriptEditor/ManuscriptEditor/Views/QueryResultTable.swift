// QueryResultTable.swift
//
// Shared tabular renderer for SQL query results — used by the Data pane and by
// data-linked manuscript tables, so "what the query returns" always looks the
// same everywhere.
//
// Uses SwiftUI's native `Table` (not a hand-rolled Grid): the system control
// gives clean column separation, resizable columns, alternating row
// backgrounds, and single-line truncation with a hover tooltip for the full
// value — no per-cell borders to drift out of alignment.

import SwiftUI

struct QueryResultTable: View {

    let result: QueryResult

    /// Rendering cap: SwiftUI Table stays fluid, huge results don't.  The
    /// footer states the truncation honestly (never silently cut coverage).
    private static let maxRows = 500

    /// One result row; identity is the row's position in the result set.
    private struct Row: Identifiable {
        let id: Int
        let values: [String]
    }

    private var rows: [Row] {
        result.rows.prefix(Self.maxRows).enumerated().map { Row(id: $0.offset, values: $0.element) }
    }

    var body: some View {
        if result.columns.isEmpty {
            ContentUnavailableView("No Results", systemImage: "tablecells")
        } else {
            VStack(spacing: 0) {
                // Columns share the width evenly by default (still resizable).
                GeometryReader { geo in
                    let equal = max(60, geo.size.width / CGFloat(max(1, result.columns.count)) - 12)
                    Table(rows) {
                        TableColumnForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
                            TableColumn(column) { (row: Row) in
                                let value = row.values.indices.contains(index) ? row.values[index] : ""
                                Text(value)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(value)   // full value on hover when truncated
                            }
                            .width(ideal: equal)
                        }
                    }
                    .alternatingRowBackgrounds(.enabled)
                }

                if result.rows.count > Self.maxRows {
                    HStack {
                        Text("Showing first \(Self.maxRows) of \(result.rows.count) rows — refine the query to narrow results.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
    }
}
