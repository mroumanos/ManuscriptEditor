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
    @State private var palette: ChartPalette = .standard

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

            // SQL query bar (terminal-style, multi-line; ⌘⏎ runs)
            HStack(alignment: .bottom, spacing: 8) {
                SQLEditor(text: $queryDraft)

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
                    ForEach(ChartType.selectable, id: \.self) { ct in
                        Label(ct.label, systemImage: ct.systemImage).tag(ct)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

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

                Picker("Colors", selection: $palette) {
                    ForEach(ChartPalette.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .frame(maxWidth: 160)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider()

            DataChartView(
                result: queryResult,
                chartType: chartType,
                xColumn: xColumn,
                yColumn: yColumn,
                palette: palette
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

// MARK: - Chart palettes

/// Category color palettes for multi-series charts.  Chosen per figure
/// (persisted on `Figure.chartPalette`) or per Data-pane session.
enum ChartPalette: String, CaseIterable, Identifiable {
    case standard   = "Default"
    case vivid      = "Vivid"
    case pastel     = "Pastel"
    case monochrome = "Monochrome"

    var id: String { rawValue }

    var colors: [Color] {
        switch self {
        case .standard:
            return [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .red]
        case .vivid:
            return [Color(red: 0.0, green: 0.45, blue: 1.0), Color(red: 1.0, green: 0.3, blue: 0.2),
                    Color(red: 0.1, green: 0.75, blue: 0.35), Color(red: 0.7, green: 0.2, blue: 0.9),
                    Color(red: 1.0, green: 0.7, blue: 0.0), Color(red: 0.0, green: 0.7, blue: 0.8)]
        case .pastel:
            return [Color(red: 0.55, green: 0.7, blue: 0.95), Color(red: 0.98, green: 0.7, blue: 0.6),
                    Color(red: 0.65, green: 0.85, blue: 0.65), Color(red: 0.8, green: 0.7, blue: 0.9),
                    Color(red: 0.95, green: 0.85, blue: 0.55), Color(red: 0.6, green: 0.85, blue: 0.85)]
        case .monochrome:
            return [Color(white: 0.15), Color(white: 0.35), Color(white: 0.5),
                    Color(white: 0.65), Color(white: 0.78)]
        }
    }
}

// MARK: - DataChartView

/// Renders QueryResult as a Swift Charts chart (shared by the Data pane and
/// data-linked figures).
///
/// Column mapping comes from the SQL SELECT — **aliases name the axes**
/// (`SELECT month AS Month, revenue AS "Revenue ($)" …`):
///   1st column → X, 2nd column → Y, optional 3rd column → series/category
///   (colored by the palette; one line/bar group per category).
/// Explicit x/y override the defaults (the Data pane's pickers).
struct DataChartView: View {
    let result: QueryResult
    let chartType: ChartType
    var xColumn: String? = nil
    var yColumn: String? = nil
    var palette: ChartPalette = .standard

    private struct ChartPoint: Identifiable {
        let id: Int
        let x: String
        let y: Double
        let series: String?
    }

    private var resolvedX: String { xColumn ?? result.columns.first ?? "" }
    private var resolvedY: String {
        yColumn ?? result.columns.dropFirst().first ?? result.columns.first ?? ""
    }

    /// A third SELECT column (when x/y are the defaults) becomes the series.
    private var seriesColumn: String? {
        guard xColumn == nil, yColumn == nil, result.columns.count >= 3 else { return nil }
        return result.columns[2]
    }

    private var points: [ChartPoint] {
        let xIdx = result.columns.firstIndex(of: resolvedX) ?? 0
        let yIdx = result.columns.firstIndex(of: resolvedY) ?? 0
        let sIdx = seriesColumn.flatMap { result.columns.firstIndex(of: $0) }
        return result.rows.enumerated().compactMap { idx, row in
            let xVal = row.indices.contains(xIdx) ? row[xIdx] : ""
            let yRaw = row.indices.contains(yIdx) ? row[yIdx] : ""
            guard let y = Double(yRaw) else { return nil }
            let series = sIdx.flatMap { row.indices.contains($0) ? row[$0] : nil }
            return ChartPoint(id: idx, x: xVal, y: y, series: series)
        }
    }

    var body: some View {
        if points.isEmpty {
            // Full-bleed empty state — never a shrunken strip in the module.
            ContentUnavailableView(
                "No numeric data",
                systemImage: "chart.bar",
                description: Text("The Y column (second column of the SELECT) must contain numeric values. Alias columns to name the axes: SELECT month AS Month, total AS \"Total\" …")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            chart
                .chartXAxis { AxisMarks(values: .automatic) }
                .chartYAxis { AxisMarks(position: .leading) }
                // Axis titles: X centered below; Y rotated to read upwards,
                // centered along the axis.
                .chartXAxisLabel(position: .bottom, alignment: .center) {
                    Text(resolvedX)
                }
                .chartYAxisLabel(position: .leading, alignment: .center) {
                    Text(resolvedY)
                        .rotationEffect(.degrees(-90))
                        .fixedSize()
                        .frame(width: 16)
                }
                .chartForegroundStyleScale(range: palette.colors)
                .frame(minHeight: 220)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch chartType {
        case .line:
            Chart(points) { pt in
                LineMark(x: .value(resolvedX, pt.x), y: .value(resolvedY, pt.y),
                         series: .value(seriesColumn ?? "Series", pt.series ?? resolvedY))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value(seriesColumn ?? "Series", pt.series ?? resolvedY))
            }
        case .bar, .histogram:
            // .histogram is retired (GROUP BY in SQL bins directly); legacy
            // figures that still carry it render as a bar chart.
            Chart(points) { pt in
                BarMark(x: .value(resolvedX, pt.x), y: .value(resolvedY, pt.y))
                    .foregroundStyle(by: .value(seriesColumn ?? "Series", pt.series ?? resolvedY))
                    .position(by: .value(seriesColumn ?? "Series", pt.series ?? resolvedY))
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
