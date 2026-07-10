// DataView.swift
//
// The "Data" panel under the Manuscript section of the sidebar.
//
// LAYOUT (HSplitView)
// ─────────────────────────────────────────────────────────────────────────────
// LEFT  — list of all DataAssets (CSV tables and images) + import buttons
// RIGHT — detail panel for the selected asset:
//           CSV    → SQL query editor + tabular results grid + chart view
//           Image  → full-size preview
//
// SQL EXECUTION
// ─────────────────────────────────────────────────────────────────────────────
// The user types a SQL SELECT statement and taps "Run" (or ⌘Return).  Results
// are displayed in a scrollable grid.  If the query fails, an inline error
// message is shown.
//
// CHARTS
// ─────────────────────────────────────────────────────────────────────────────
// For CSV assets the user can switch to "Chart" mode, pick a chart type
// (line / bar / histogram) and specify which columns map to X and Y axes.
// Swift Charts renders the result.

import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

// MARK: - DataView

struct DataView: View {
    @Environment(ManuscriptStore.self) private var store

    @State private var selectedID: UUID?

    /// One fileImporter serves both kinds — two `.fileImporter` modifiers on
    /// the same view is unreliable on macOS (only one registers).
    enum ImportKind { case csv, image }
    @State private var importKind: ImportKind = .csv
    @State private var showImporter = false

    private var assets: [DataAsset] {
        (store.manuscript?.dataAssets ?? []).sorted { $0.importedAt < $1.importedAt }
    }

    var body: some View {
        Group {
            if assets.isEmpty {
                emptyState
            } else {
                HSplitView {
                    assetList
                        .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
                        .frame(maxHeight: .infinity)
                        .background(Color(NSColor.windowBackgroundColor))
                    assetDetail
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importKind == .image
                          ? [UTType.image]
                          : [UTType.commaSeparatedText, .plainText],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            switch importKind {
            case .csv:   store.importCSVAsset(from: url)
            case .image: store.importImageAsset(from: url)
            }
            selectedID = store.manuscript?.dataAssets.last?.id
        }
        // Imports must never fail silently (e.g. a non-UTF-8 CSV).
        .alert("Import Failed", isPresented: Binding(
            get: { store.dataError != nil },
            set: { if !$0 { store.dataError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.dataError ?? "")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No Data Imported")
                .font(.title3.weight(.semibold))
            Text("Import a CSV table or image to get started.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    importKind = .csv
                    showImporter = true
                } label: {
                    Label("Import CSV", systemImage: "tablecells.badge.ellipsis")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    importKind = .image
                    showImporter = true
                } label: {
                    Label("Import Image", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left pane: asset list

    private var assetList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                if !csvAssets.isEmpty {
                    Section("Tabular Data") {
                        ForEach(csvAssets) { asset in
                            assetRow(asset).tag(asset.id)
                        }
                    }
                }
                if !imageAssets.isEmpty {
                    Section("Images") {
                        ForEach(imageAssets) { asset in
                            assetRow(asset).tag(asset.id)
                        }
                    }
                }
                if assets.isEmpty {
                    Text("No data imported yet")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(NSColor.windowBackgroundColor))
            .onAppear { autoSelect() }
            .onChange(of: assets.map(\.id)) { _, _ in autoSelect() }

            Divider()

            HStack(spacing: 4) {
                Button {
                    importKind = .csv
                    showImporter = true
                } label: {
                    Label("Import CSV", systemImage: "tablecells.badge.ellipsis")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Divider().frame(height: 16)

                Button {
                    importKind = .image
                    showImporter = true
                } label: {
                    Label("Import Image", systemImage: "photo.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var csvAssets:   [DataAsset] { assets.filter { $0.type == .csv   } }
    private var imageAssets: [DataAsset] { assets.filter { $0.type == .image } }

    private func autoSelect() {
        if selectedID == nil || !assets.contains(where: { $0.id == selectedID }) {
            selectedID = assets.first?.id
        }
    }

    private func assetRow(_ asset: DataAsset) -> some View {
        HStack(spacing: 6) {
            Label(asset.name, systemImage: asset.type == .csv ? "tablecells" : "photo")
                .lineLimit(1)
            Spacer()
            Button {
                if let idx = assets.firstIndex(where: { $0.id == asset.id }) {
                    store.deleteDataAssets(at: IndexSet([idx]))
                    if selectedID == asset.id { selectedID = nil }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Remove \(asset.name)")
        }
    }

    // MARK: - Right pane: detail

    @ViewBuilder
    private var assetDetail: some View {
        if let id = selectedID,
           let asset = assets.first(where: { $0.id == id }) {
            switch asset.type {
            case .csv:   CSVAssetDetail(asset: asset)
            case .image: ImageAssetDetail(asset: asset)
            }
        } else {
            ContentUnavailableView(
                "Select a Data Asset",
                systemImage: "tablecells",
                description: Text("Import a CSV or image to get started.")
            )
        }
    }
}

// MARK: - CSVAssetDetail

struct CSVAssetDetail: View {
    @Environment(ManuscriptStore.self) private var store
    let asset: DataAsset

    enum ViewMode { case table, chart }

    @State private var mode: ViewMode = .table
    @State private var queryDraft: String
    @State private var queryResult: QueryResult = .empty
    @State private var queryError: String?

    @State private var chartType: ChartType = .bar
    @State private var xColumn: String = ""
    @State private var yColumn: String = ""

    init(asset: DataAsset) {
        self.asset = asset
        _queryDraft = State(initialValue: asset.lastQuery.isEmpty ? "SELECT * FROM data" : asset.lastQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header toolbar
            HStack(spacing: 12) {
                Text(asset.name)
                    .font(.headline)
                Text("SQLite · \(queryResult.rows.count) row\(queryResult.rows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $mode) {
                    Label("Table", systemImage: "tablecells").tag(ViewMode.table)
                    Label("Chart", systemImage: "chart.bar").tag(ViewMode.chart)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // SQL query bar
            HStack(spacing: 8) {
                TextField("SQL query…", text: $queryDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...4)
                    .onSubmit { runQuery() }

                Button("Run") { runQuery() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let err = queryError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Divider()

            // Results
            if mode == .table {
                tableResultsView
            } else {
                chartResultsView
            }
        }
        .onAppear { runQuery() }
        .onChange(of: asset.id) { _, _ in
            queryDraft = asset.lastQuery.isEmpty ? "SELECT * FROM data" : asset.lastQuery
            runQuery()
        }
    }

    // MARK: - Table results

    private var tableResultsView: some View {
        QueryResultTable(result: queryResult)
    }

    // MARK: - Chart results

    private var chartResultsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Picker("Chart", selection: $chartType) {
                    ForEach(ChartType.allCases, id: \.self) { ct in
                        Label(ct.label, systemImage: ct.systemImage).tag(ct)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                if !queryResult.columns.isEmpty {
                    Picker("X", selection: $xColumn) {
                        ForEach(queryResult.columns, id: \.self) { col in Text(col).tag(col) }
                    }
                    .frame(maxWidth: 140)

                    Picker("Y", selection: $yColumn) {
                        ForEach(queryResult.columns, id: \.self) { col in Text(col).tag(col) }
                    }
                    .frame(maxWidth: 140)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider()

            DataChartView(
                result: queryResult,
                chartType: chartType,
                xColumn: xColumn,
                yColumn: yColumn
            )
            .padding(16)
        }
        .onAppear { initialiseAxisColumns() }
        .onChange(of: queryResult.columns) { _, _ in initialiseAxisColumns() }
    }

    private func initialiseAxisColumns() {
        let cols = queryResult.columns
        if xColumn.isEmpty || !cols.contains(xColumn) { xColumn = cols.first ?? "" }
        if yColumn.isEmpty || !cols.contains(yColumn) { yColumn = cols.dropFirst().first ?? cols.first ?? "" }
    }

    // MARK: - Helpers

    private func runQuery() {
        let result = store.runQuery(queryDraft, for: asset)
        if let err = result.errorMessage {
            queryError = err
            queryResult = .empty
        } else {
            queryError = nil
            queryResult = result
        }
        // Persist the last query
        var updated = asset
        updated.lastQuery = queryDraft
        store.updateDataAsset(updated)
    }
}

// MARK: - DataChartView

/// Renders QueryResult as a Swift Charts chart (shared by the Data pane and
/// data-linked figures).
///
/// Column mapping: explicit X/Y when the caller provides them (the Data pane's
/// pickers); otherwise the SQL SELECT decides — the first column is X and the
/// second (or first, for single-column results) is Y.  So a figure's
/// `SELECT month, revenue FROM data` charts exactly what it reads as.
struct DataChartView: View {
    let result: QueryResult
    let chartType: ChartType
    var xColumn: String? = nil
    var yColumn: String? = nil

    private struct ChartPoint: Identifiable {
        let id: Int
        let x: String
        let y: Double
    }

    private var resolvedX: String { xColumn ?? result.columns.first ?? "" }
    private var resolvedY: String {
        yColumn ?? result.columns.dropFirst().first ?? result.columns.first ?? ""
    }

    private var points: [ChartPoint] {
        let xIdx = result.columns.firstIndex(of: resolvedX) ?? 0
        let yIdx = result.columns.firstIndex(of: resolvedY) ?? 0
        return result.rows.enumerated().compactMap { idx, row in
            let xVal = row.indices.contains(xIdx) ? row[xIdx] : ""
            let yRaw = row.indices.contains(yIdx) ? row[yIdx] : ""
            guard let y = Double(yRaw) else { return nil }
            return ChartPoint(id: idx, x: xVal, y: y)
        }
    }

    /// Histogram bins over the Y column's numeric values: ~12 equal-width
    /// buckets, each bar = how many values fall in the bucket.  (A histogram
    /// is a distribution, not a bar-per-row — the pre-binned look of the old
    /// implementation was just a recolored bar chart.)
    private var bins: [(label: String, count: Int)] {
        let values = points.map(\.y)
        guard let lo = values.min(), let hi = values.max(), values.count > 1 else {
            return values.map { (String($0), 1) }
        }
        let binCount = min(12, max(4, Int(Double(values.count).squareRoot())))
        let width = (hi - lo) / Double(binCount)
        guard width > 0 else { return [(String(lo), values.count)] }
        var counts = Array(repeating: 0, count: binCount)
        for v in values {
            let idx = min(binCount - 1, Int((v - lo) / width))
            counts[idx] += 1
        }
        return counts.enumerated().map { i, c in
            let start = lo + Double(i) * width
            return (String(format: "%.3g–%.3g", start, start + width), c)
        }
    }

    var body: some View {
        if points.isEmpty {
            ContentUnavailableView(
                "No numeric data",
                systemImage: "chart.bar",
                description: Text("The Y column (second column of the SELECT) must contain numeric values.")
            )
        } else {
            chart
                .chartXAxis { AxisMarks(values: .automatic) }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(minHeight: 220)
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch chartType {
        case .line:
            Chart(points) { pt in
                LineMark(x: .value(resolvedX, pt.x), y: .value(resolvedY, pt.y))
                    .interpolationMethod(.catmullRom)
            }
        case .bar:
            Chart(points) { pt in
                BarMark(x: .value(resolvedX, pt.x), y: .value(resolvedY, pt.y))
            }
        case .histogram:
            Chart(Array(bins.enumerated()), id: \.offset) { _, bin in
                BarMark(x: .value(resolvedY, bin.label), y: .value("Count", bin.count))
            }
        }
    }
}

// MARK: - ImageAssetDetail

struct ImageAssetDetail: View {
    @Environment(ManuscriptStore.self) private var store
    let asset: DataAsset

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(asset.name)
                    .font(.headline)
                Spacer()
                Text(asset.importedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if let url = store.dataImageURL(for: asset),
               let image = NSImage(contentsOf: url) {
                ScrollView {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                }
            } else {
                ContentUnavailableView("Image not found", systemImage: "photo")
            }
        }
    }
}
