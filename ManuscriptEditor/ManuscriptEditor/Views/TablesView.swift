// TablesView.swift
//
// Two-pane view for managing manuscript data tables.
//
// Layout (HSplitView):
//   LEFT   — list of tables with "Add Table" button
//   RIGHT  — TableEditor split into a content editor and a metadata form
//
// Table content is stored as Markdown pipe-syntax.  A monospaced font in the
// editor helps the user keep column alignments readable while writing.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - TablesView

/// The tables panel: list on the left, editor on the right.
struct TablesView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    /// UUID of the selected table.
    @State private var selectedID: UUID?

    /// Display numbers follow reference order (first-referenced = Table 1).
    private var numbers: [UUID: Int] {
        store.manuscript(for: versionRef).map(RefEngine.effectiveTableNumbers) ?? [:]
    }

    /// Tables sorted by their effective (reference-order) number.
    private var tables: [ManuscriptTable] {
        (store.manuscript(for: versionRef)?.tables ?? [])
            .sorted { (numbers[$0.id] ?? $0.number) < (numbers[$1.id] ?? $1.number) }
    }

    var body: some View {
        if tables.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "tablecells")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("No Tables Yet")
                    .font(.title3.weight(.semibold))
                Text("Add a table to get started.")
                    .foregroundStyle(.secondary)
                Button {
                    store.addTable(ref: versionRef)
                } label: {
                    Label("Add Table", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        HSplitView {
            // MARK: Left — table list
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(tables) { table in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Table \(numbers[table.id] ?? table.number)").font(.callout.weight(.medium))
                                Text(table.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                // Index must come from the RAW array — offsets are applied
                                // to it, and the sidebar list is number-sorted.
                                guard let idx = store.manuscript(for: versionRef)?.tables
                                    .firstIndex(where: { $0.id == table.id }) else { return }
                                store.deleteTables(at: IndexSet([idx]), ref: versionRef)
                                if selectedID == table.id {
                                    selectedID = tables.first(where: { $0.id != table.id })?.id
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete table")
                        }
                        .padding(.vertical, 3)
                        .tag(table.id)
                    }
                    // Drag to reorder; referenced tables keep their
                    // citation-order numbers (a dragged one snaps back).
                    .onMove { source, destination in
                        store.moveTables(from: source, to: destination, ref: versionRef)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.windowBackgroundColor))
                .onAppear { autoSelect() }
                .onChange(of: tables.map(\.id)) { _, _ in autoSelect() }

                Divider()

                HStack {
                    Button {
                        store.addTable(ref: versionRef)
                        selectedID = store.manuscript(for: versionRef)?.tables.last?.id
                    } label: {
                        Label("Add Table", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .padding(10)
                    Spacer()
                }
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 250)
            .frame(maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))

            // MARK: Right — table editor
            if let id = selectedID,
               let table = tables.first(where: { $0.id == id }) {
                TableEditor(table: table, versionRef: versionRef)
            } else {
                Color.clear
            }
        }
        } // end else
    }

    private func autoSelect() {
        if selectedID == nil || !tables.contains(where: { $0.id == selectedID }) {
            selectedID = tables.first?.id
        }
    }
}

// MARK: - TableEditor

/// Vertical split: Markdown content editor on top, metadata form (title, caption,
/// footnotes) below.
struct TableEditor: View {
    @Environment(ManuscriptStore.self) private var store
    let table: ManuscriptTable
    /// Which version this table belongs to.
    var versionRef: VersionRef = .source

    /// Mutable working copy.
    @State private var draft: ManuscriptTable

    /// Live result of the linked data query (when a data source is set).
    @State private var previewResult: QueryResult = .empty
    /// Confirm for the one-way disconnect-from-data action.
    @State private var showDisconnectConfirm = false
    /// Arrangement piece being dragged to a new position.
    @State private var draggingPiece: String?
    /// The grid's selection, shared with the formatting toolbar.
    @State private var gridSelection = GridSelection()
    /// Debounces query re-runs while the user types SQL.
    @State private var previewTask: Task<Void, Never>?

    init(table: ManuscriptTable, versionRef: VersionRef = .source) {
        self.table = table
        self.versionRef = versionRef
        _draft = State(initialValue: table)
    }

    var body: some View {
        VSplitView {
            // MARK: Content: live data preview (linked) or Markdown editor
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(draft.dataAssetID == nil ? "Table Content" : "Data Preview")
                        .font(.headline)
                    Spacer()
                    if draft.dataAssetID == nil {
                        Text("Click a cell to type; select it to style it")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("\(previewResult.rows.count) row\(previewResult.rows.count == 1 ? "" : "s") · updates as the SQL below changes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)
                Divider()
                if draft.dataAssetID != nil {
                    // The linked query's rows ARE the table.  The same grid
                    // as manual tables, in styling-only mode: the data owns
                    // the shape and text; `draft.cells` persists a style
                    // OVERLAY aligned to the result (row 0 = header).
                    if let error = previewResult.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(12)
                        Spacer(minLength: 0)
                    } else {
                        gridToolbar
                        Divider()
                        SpreadsheetGrid(cells: Binding(
                            get: { ManuscriptTable.styledGrid(result: previewResult, overlay: draft.cells) },
                            set: { draft.cells = $0 }
                        ), columnWidths: Binding(
                            get: { draft.columnWidths },
                            set: { draft.columnWidths = $0 }
                        ), selection: gridSelection, structureEditable: false,
                           onManualWidths: { draft.autofit = false })
                    }
                } else {
                    // Grid editor — no Markdown required.  Cells edit in
                    // place; the toolbar styles the selection and the grid
                    // adds/removes rows and columns.  `content` keeps a
                    // plain pipe-Markdown mirror for legacy readers.
                    gridToolbar
                    Divider()
                    SpreadsheetGrid(cells: Binding(
                        get: {
                            draft.cells
                                ?? ManuscriptTable.cellGrid(fromPipe: draft.content)
                                ?? [[TableCell(text: "Column 1"), TableCell(text: "Column 2")],
                                    [TableCell(), TableCell()]]
                        },
                        set: { grid in
                            draft.cells = grid
                            draft.content = ManuscriptTable.markdown(from: grid)
                        }
                    ), columnWidths: Binding(
                        get: { draft.columnWidths },
                        set: { draft.columnWidths = $0 }
                    ), selection: gridSelection,
                       onManualWidths: { draft.autofit = false })
                }
            }
            .frame(minHeight: 200)

            // MARK: Metadata form
            Form {
                dataSourceSection
                arrangementSection
                Section("Export Formatting") {
                    Toggle("Autofit column widths (dragging a column turns this off)", isOn: Binding(
                        get: { draft.autofitOn },
                        set: { draft.autofit = $0 ? nil : false }
                    ))
                    if draft.autofitOn {
                        HStack(spacing: 4) {
                            Text("Measure from row")
                            TextField("", value: Binding(
                                get: { draft.dataStartRow ?? 2 },
                                set: { draft.dataStartRow = $0 <= 2 ? nil : min($0, 200) }
                            ), format: .number)
                            .frame(width: 40)
                            .multilineTextAlignment(.trailing)
                            Stepper("", value: Binding(
                                get: { draft.dataStartRow ?? 2 },
                                set: { draft.dataStartRow = $0 <= 2 ? nil : $0 }
                            ), in: 2...200)
                            .labelsHidden()
                            .controlSize(.small)
                        }
                        Text("Column widths follow each column's widest cell, measured from row N down (row 1 is the header); narrow columns never wrap.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Autofit off — the export fills the table width using the ratios of the column widths you drag in the grid above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Open sides (horizontal rules only — journal style)", isOn: Binding(
                        get: { draft.openSides ?? false },
                        set: { draft.openSides = $0 ? true : nil }
                    ))
                    Toggle("Alternate row shading", isOn: Binding(
                        get: { draft.alternateShading ?? false },
                        set: { draft.alternateShading = $0 ? true : nil }
                    ))
                    Text("Off = a fully boxed grid. Values wrap inside their cells either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 200)
        }
        // One draft observer (ManuscriptTable is Equatable) — the per-field
        // chain didn't scale to the caption-part fields.
        .onChange(of: draft) { old, new in
            store.updateTable(new, ref: versionRef)
            if old.dataAssetID != new.dataAssetID {
                refreshPreview()
            } else if old.dataQuery != new.dataQuery {
                refreshPreview(debounced: true)
            }
        }
        .onChange(of: table) { _, new in
            // External change (selection switch or document undo) — the form's
            // own commits arrive back equal to the draft and are skipped.
            guard new != draft else { return }
            draft = new
            refreshPreview()
        }
        .onAppear                         { refreshPreview() }
        .alert("Disconnect from Data Source?", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) { disconnectFromData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current query result is copied into a manual table and the data link is removed. The table will no longer update with the data, and this cannot be reversed.")
        }
    }

    // MARK: - Live data preview

    /// Re-runs the linked query.  Typing in the SQL field debounces ~0.4 s so
    /// half-written statements don't spam errors; picking an asset runs now.
    private func refreshPreview(debounced: Bool = false) {
        previewTask?.cancel()
        guard let assetID = draft.dataAssetID,
              let asset = store.manuscript?.dataAssets.first(where: { $0.id == assetID })
        else {
            previewResult = .empty
            return
        }
        let sql = draft.dataQuery ?? "SELECT * FROM data"
        previewTask = Task {
            if debounced {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            previewResult = store.runQuery(sql, for: asset)
        }
    }

    /// Arrangement: the three exported pieces — title, the table grid, and
    /// the caption — sorted with the arrows.  Title/caption carry emphasis
    /// + alignment; the grid carries its page-width % and alignment.
    @ViewBuilder
    private var arrangementSection: some View {
        Section("Arrangement") {
            let order = draft.arrangement ?? ["title", "table", "caption"]
            ForEach(order, id: \.self) { piece in
                HStack(spacing: 8) {
                    ArrangementDragHandle(piece: piece, dragging: $draggingPiece)
                    switch piece {
                    case "title":
                        CaptionPartToggle(style: $draft.titleStyle)
                        TextField("Title…", text: $draft.title)
                        Spacer()
                        CaptionPartControls(style: $draft.titleStyle, defaultBold: true)
                    case "caption":
                        CaptionPartToggle(style: $draft.captionStyle)
                        Text("Caption")
                        Spacer()
                        Text("styled in the box below")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    default:
                        Image(systemName: "tablecells").foregroundStyle(.secondary)
                        Text("Table grid")
                        Spacer()
                        Slider(value: Binding(
                            get: { draft.tableWidthPercent ?? 100 },
                            set: { draft.tableWidthPercent = $0 >= 99.5 ? nil : $0 }
                        ), in: 25...100, step: 5)
                        .frame(width: 120)
                        .help("Exported table width as a % of the page's text column")
                        Text("\(Int(draft.tableWidthPercent ?? 100))%")
                            .monospacedDigit()
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                        AlignmentPicker(align: Binding(
                            get: { draft.tableAlign },
                            set: { draft.tableAlign = $0 }
                        ))
                        .help("Table alignment when narrower than the column")
                    }
                }
                .onDrop(of: [.text], delegate: PieceDropDelegate(
                    target: piece, dragging: $draggingPiece, order: order,
                    apply: { draft.arrangement = $0 }))
            }
            CaptionRichBox(value: Binding(
                get: { draft.captionText ?? RichText(plain: draft.caption) },
                set: { rich in
                    draft.captionText = rich
                    draft.caption = rich.plain
                }
            ))
            Text("Drag the handles to sort the pieces; toggle the title or caption off as needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Data source section

    private var csvAssets: [DataAsset] {
        // Data is global: every journal reads the shared Data repository —
        // only the view on it (SQL, formatting) is journal-specific.
        (store.manuscript?.dataAssets ?? []).filter { $0.type == .csv }
    }

    @ViewBuilder
    var dataSourceSection: some View {
        Section("Data Source") {
            Picker("CSV Data", selection: Binding(
                get: { draft.dataAssetID },
                set: { draft.dataAssetID = $0 }
            )) {
                Text("None (manual Markdown)").tag(Optional<UUID>.none)
                ForEach(csvAssets) { asset in
                    Text(asset.name).tag(Optional(asset.id))
                }
            }
            if draft.dataAssetID != nil {
                SQLEditor(text: Binding(
                    get: { draft.dataQuery ?? "SELECT * FROM data" },
                    set: { draft.dataQuery = $0 }
                ))
                Text("The query result populates the table; manual content is ignored while linked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Disconnect from Data…", role: .destructive) {
                    showDisconnectConfirm = true
                }
                .help("Copy the current result into a manual table and unlink the data source")
            }
        }
    }

    /// Copies the live query result into the manual grid and unlinks the
    /// data source — the one-way door the confirm warns about.
    private func disconnectFromData() {
        var result = previewResult
        if result.columns.isEmpty || result.errorMessage != nil,
           let assetID = draft.dataAssetID,
           let asset = store.manuscript?.dataAssets.first(where: { $0.id == assetID }) {
            result = store.runQuery(draft.dataQuery ?? "SELECT * FROM data", for: asset)
        }
        if result.errorMessage == nil, !result.columns.isEmpty {
            let grid = ManuscriptTable.styledGrid(result: result, overlay: draft.cells)
            draft.cells = grid
            draft.content = ManuscriptTable.markdown(from: grid)
        }
        draft.dataAssetID = nil
        draft.dataQuery = nil
    }
}

// MARK: - Grid formatting toolbar

extension TableEditor {

    /// The cells the toolbar acts on (the grid's live selection).
    private var selectedRange: (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
        let grid = currentGrid
        return gridSelection.range(rows: grid.count, cols: grid.first?.count ?? 0)
    }

    /// Whichever grid is on screen: the query result plus its style overlay
    /// for a data-linked table, else the manual cells.
    private var currentGrid: [[TableCell]] {
        if draft.dataAssetID != nil {
            return ManuscriptTable.styledGrid(result: previewResult, overlay: draft.cells)
        }
        return draft.cells
            ?? ManuscriptTable.cellGrid(fromPipe: draft.content)
            ?? []
    }

    private var firstSelectedCell: TableCell? {
        guard let range = selectedRange else { return nil }
        let grid = currentGrid
        guard grid.indices.contains(range.rows.lowerBound),
              grid[range.rows.lowerBound].indices.contains(range.cols.lowerBound) else { return nil }
        return grid[range.rows.lowerBound][range.cols.lowerBound]
    }

    /// One snapshot, one write — per-cell writes through a binding re-read
    /// stale state and only the last cell survived.
    private func styleSelection(_ change: (inout TableCell) -> Void) {
        guard let range = selectedRange else { return }
        var grid = currentGrid
        for r in range.rows where grid.indices.contains(r) {
            for c in range.cols where grid[r].indices.contains(c) {
                change(&grid[r][c])
            }
        }
        draft.cells = grid
        if draft.dataAssetID == nil {
            draft.content = ManuscriptTable.markdown(from: grid)
        }
    }

    var gridToolbar: some View {
        HStack(spacing: 4) {
            styleButton("bold", "Bold") { $0.bold = ($0.bold ?? false) ? false : true }
            styleButton("italic", "Italic") { $0.italic = ($0.italic ?? false) ? nil : true }
            styleButton("underline", "Underline") { $0.underline = ($0.underline ?? false) ? nil : true }
            highlightButton
            AlignmentPicker(align: Binding(
                get: { firstSelectedCell?.align },
                set: { value in styleSelection { $0.align = value } }
            ))
            .disabled(selectedRange == nil)
            .help("Cell text alignment")

            Spacer()
            Text(draft.dataAssetID == nil
                 ? "click selects · double-click edits · drag or ⇧-click extends · edges add rows/columns"
                 : "styling only — the data supplies the cells · drag or ⇧-click extends")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func styleButton(_ symbol: String, _ help: String,
                             _ change: @escaping (inout TableCell) -> Void) -> some View {
        Button { styleSelection(change) } label: { Image(systemName: symbol) }
            .disabled(selectedRange == nil)
            .help(help)
    }

    private var highlightButton: some View {
        Menu {
            ForEach(["yellow", "green", "blue", "pink", "orange"], id: \.self) { name in
                Button(name.capitalized) {
                    styleSelection { $0.highlight = true; $0.highlightColor = name == "yellow" ? nil : name }
                }
            }
            Divider()
            Button("No highlight") {
                styleSelection { $0.highlight = nil; $0.highlightColor = nil }
            }
        } label: {
            Image(systemName: "highlighter")
                .foregroundStyle(firstSelectedCell?.highlight == true ? Color.accentColor : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(selectedRange == nil)
        .help("Highlight the selected cells")
    }
}
