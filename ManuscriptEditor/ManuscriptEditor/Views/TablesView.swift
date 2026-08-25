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
                        ManualTableGrid(cells: Binding(
                            get: { ManuscriptTable.styledGrid(result: previewResult, overlay: draft.cells) },
                            set: { draft.cells = $0 }
                        ), columnWidths: Binding(
                            get: { draft.columnWidths },
                            set: { draft.columnWidths = $0 }
                        ), structureEditable: false)
                    }
                } else {
                    // Grid editor — no Markdown required.  Cells edit in
                    // place; the toolbar styles the selected cell and adds/
                    // removes rows and columns.  `content` keeps a plain
                    // pipe-Markdown mirror for legacy readers.
                    ManualTableGrid(cells: Binding(
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
                    ))
                }
            }
            .frame(minHeight: 200)

            // MARK: Metadata form
            Form {
                dataSourceSection
                arrangementSection
                Section("Export Formatting") {
                    Toggle("Autofit column widths", isOn: Binding(
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


// MARK: - ManualTableGrid

/// Direct grid editing, spreadsheet-style:
///   click = select · double-click = edit · drag / ⇧-arrows = extend the
///   selection · toolbar (and ⌘B/⌘I/⌘U/⌘E) styles every selected cell.
/// Hovering a cell reveals its row's and column's grab handle (drag to
/// reorder) and "−" (remove) in the gutters; thin bars at the bottom and
/// right illuminate a "+" to add a row or column.  Row 0 is the header.
struct ManualTableGrid: View {
    @Binding var cells: [[TableCell]]
    /// Editor-adjusted column widths in points (drag the divider under a
    /// column boundary).  nil entries fall back to the default width; the
    /// export uses the RATIOS when autofit is off.
    @Binding var columnWidths: [Double]?
    /// false = CSV-backed styling mode: the shape and text come from the
    /// data (no gutters, add bars, reordering, or cell editing) — only the
    /// formatting toolbar and selection remain.
    var structureEditable: Bool = true

    struct CellID: Hashable { let r: Int; let c: Int }

    // Selection: a rectangle from anchor to extent.
    @State private var anchor: CellID?
    @State private var extent: CellID?
    @State private var editingCell: CellID?
    @FocusState private var fieldFocused: Bool
    /// Local keyDown monitor for arrow-key selection (installed while the
    /// grid is on screen).
    @State private var keyMonitor: Any?
    /// Column-divider drag in flight.
    @State private var resizingCol: Int?
    @State private var resizeBase: CGFloat?

    @State private var hover: CellID?
    @State private var hoverBottomBar = false
    @State private var showHighlightColors = false
    @State private var hoverRightBar = false

    /// Live row/column drag: (original index, current index).
    @State private var movingRow: (start: Int, current: Int)?
    @State private var movingCol: (start: Int, current: Int)?

    // Fixed row geometry; column widths are per-column (drag to adjust).
    private let cellW: CGFloat = 132
    private let cellH: CGFloat = 28
    private let gap: CGFloat = 1
    private let gutterW: CGFloat = 40   // left: [− ≡] side by side
    private let gutterH: CGFloat = 30   // top:  − above ≡

    private var rowCount: Int { cells.count }
    private var colCount: Int { cells.first?.count ?? 0 }

    private func colW(_ c: Int) -> CGFloat {
        guard let widths = columnWidths, widths.indices.contains(c), widths[c] > 0 else { return cellW }
        return CGFloat(widths[c])
    }

    /// x-offset of each column's leading edge (index colCount = grid width).
    private var colX: [CGFloat] {
        var out: [CGFloat] = [0]
        for c in 0..<colCount { out.append(out[c] + colW(c) + gap) }
        return out
    }

    private var gridW: CGFloat { max(colX.last.map { $0 - gap } ?? 0, 0) }
    private var gridH: CGFloat { CGFloat(rowCount) * (cellH + gap) - gap }

    private var selection: (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
        // Clamp to the CURRENT grid: editing the SQL can shrink a
        // data-linked table's result while anchor/extent still point at
        // the old shape, and the onChange clamp only runs AFTER the body
        // that would subscript with the stale range (crash on save).
        guard let a = anchor, rowCount > 0, colCount > 0 else { return nil }
        let e = extent ?? a
        let rLo = max(min(min(a.r, e.r), rowCount - 1), 0)
        let rHi = max(min(max(a.r, e.r), rowCount - 1), 0)
        let cLo = max(min(min(a.c, e.c), colCount - 1), 0)
        let cHi = max(min(max(a.c, e.c), colCount - 1), 0)
        return (rLo...rHi, cLo...cHi)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    if structureEditable {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: gutterW, height: gutterH)
                            columnGutter
                        }
                    }
                    HStack(alignment: .top, spacing: 0) {
                        if structureEditable { rowGutter }
                        gridBody
                        if structureEditable { addColumnBar }
                    }
                    if structureEditable {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: gutterW, height: 1)
                            addRowBar
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        // Sticky until the cursor leaves the whole view box — clearing at
        // any inner boundary made the buttons vanish mid-reach.
        .onHover { inside in
            if !inside, movingRow == nil, movingCol == nil { hover = nil }
        }
        .onChange(of: cells.count) { _, _ in clampSelection() }
        .onChange(of: colCount) { _, _ in clampSelection() }
    }

    private func clampSelection() {
        if let a = anchor, !cells.indices.contains(a.r) || !(cells.first?.indices.contains(a.c) ?? false) {
            anchor = nil; extent = nil; editingCell = nil
        }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            styleButton("bold", "Bold (⌘B)", key: "b") {
                $0.bold = ($0.bold ?? false) ? false : true
            }
            styleButton("italic", "Italic (⌘I)", key: "i") {
                $0.italic = ($0.italic ?? false) ? nil : true
            }
            styleButton("underline", "Underline (⌘U)", key: "u") {
                $0.underline = ($0.underline ?? false) ? nil : true
            }
            highlightMenu
            AlignmentPicker(align: Binding(
                get: { firstSelected?.align },
                set: { value in mutateSelection { $0.align = value } }
            ))
            .disabled(selection == nil)
            .help("Cell text alignment (⌘E toggles center)")
            // ⌘E: center on/off for the selection.
            Button("") {
                let on = firstSelected?.align == "center"
                mutateSelection { $0.align = on ? nil : "center" }
            }
            .keyboardShortcut("e", modifiers: .command)
            .frame(width: 0)
            .opacity(0)

            Divider().frame(height: 16).padding(.horizontal, 4)

            Button {
                fitColumnsToContent()
            } label: {
                Image(systemName: "arrow.left.and.right.text.vertical")
            }
            .help("Fit columns to their widest value (then adjust by dragging the dividers)")

            Spacer()
            Text(structureEditable
                 ? "click selects · double-click edits · drag, ⇧-click, or ⇧-arrows extend"
                 : "styling only — the data supplies the cells · ⇧-click / ⇧-arrows extend")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var firstSelected: TableCell? {
        guard let sel = selection,
              cells.indices.contains(sel.rows.lowerBound),
              cells[sel.rows.lowerBound].indices.contains(sel.cols.lowerBound) else { return nil }
        return cells[sel.rows.lowerBound][sel.cols.lowerBound]
    }

    private func styleButton(_ symbol: String, _ help: String, key: Character,
                             _ change: @escaping (inout TableCell) -> Void) -> some View {
        Button { mutateSelection(change) } label: {
            Image(systemName: symbol)
        }
        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        .disabled(selection == nil)
        .help(help)
    }

    /// The highlighter button: pops the color swatches under the icon.
    private var highlightMenu: some View {
        Button {
            showHighlightColors = true
        } label: {
            Image(systemName: "highlighter")
                .foregroundStyle(firstSelected?.highlight == true
                    ? Self.highlightColor(firstSelected?.highlightColor) : Color.primary)
        }
        .disabled(selection == nil)
        .help("Highlight the selected cells")
        .popover(isPresented: $showHighlightColors, arrowEdge: .bottom) {
            highlightSwatches.padding(10)
        }
    }

    /// Five colored, selectable boxes plus a "none".
    private var highlightSwatches: some View {
        HStack(spacing: 3) {
            ForEach(["yellow", "green", "blue", "pink", "orange"], id: \.self) { name in
                let active = firstSelected?.highlight == true
                    && (firstSelected?.highlightColor ?? "yellow") == name
                Button {
                    mutateSelection { $0.highlight = true; $0.highlightColor = name == "yellow" ? nil : name }
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.highlightColor(name).opacity(0.55))
                        .frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(active ? Color.accentColor : Color.secondary.opacity(0.4),
                                          lineWidth: active ? 1.5 : 0.5))
                }
                .buttonStyle(.plain)
                .help("Highlight \(name)")
            }
            Button {
                mutateSelection { $0.highlight = nil; $0.highlightColor = nil }
            } label: {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5)
                    .frame(width: 14, height: 14)
                    .overlay(Image(systemName: "line.diagonal")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help("No highlight")
        }
    }

    /// One snapshot, one write: mutating cell-by-cell through the binding
    /// re-read stale state each pass, so only the LAST cell's change
    /// survived a multi-cell selection.
    private func mutateSelection(_ change: (inout TableCell) -> Void) {
        guard let sel = selection else { return }
        var grid = cells
        for r in sel.rows where grid.indices.contains(r) {
            for c in sel.cols where grid[r].indices.contains(c) {
                change(&grid[r][c])
            }
        }
        cells = grid
    }

    // MARK: gutters (hover: drag handle + remove)

    /// Top gutter: the hovered COLUMN's "−" (outermost, so a miss doesn't
    /// delete) above its grab handle.  Sticky — it stays for the last
    /// hovered column even after the cursor leaves the table.
    private var columnGutter: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: gridW, height: gutterH)
            if let h = hoverColumn {
                VStack(spacing: 1) {
                    Button {
                        removeColumn(h)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(colCount <= 1)
                    .help("Remove this column")
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .help("Drag to reorder this column")
                        .gesture(columnDragGesture(from: h))
                }
                .frame(width: colW(h))
                .offset(x: colX[h], y: 0)
            }
        }
        .frame(height: gutterH)
    }

    /// Left gutter: the hovered ROW's "−" (outermost) left of its grab
    /// handle.  Sticky like the column gutter.
    private var rowGutter: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: gutterW, height: gridH)
            if let h = hoverRow {
                HStack(spacing: 4) {
                    Button {
                        removeRow(h)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(rowCount <= 1)
                    .help("Remove this row")
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .help("Drag to reorder this row")
                        .gesture(rowDragGesture(from: h))
                }
                .frame(height: cellH)
                .offset(x: 2, y: CGFloat(h) * (cellH + gap))
            }
        }
        .frame(width: gutterW)
    }

    /// While dragging, the gutter controls stay at the START index — the
    /// gesture's coordinate space must not move with the reordered row or
    /// the translation jumps and the row hunts between two positions.
    private var hoverRow: Int? { movingRow?.start ?? hover?.r }
    private var hoverColumn: Int? { movingCol?.start ?? hover?.c }

    // MARK: add bars

    private var addRowBar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(hoverBottomBar ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hoverBottomBar ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .frame(width: gridW, height: 16)
        .padding(.top, 3)
        .contentShape(Rectangle())
        .onHover { hoverBottomBar = $0 }
        .onTapGesture {
            cells.append(Array(repeating: TableCell(), count: max(colCount, 1)))
        }
        .help("Add a row")
    }

    private var addColumnBar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(hoverRightBar ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hoverRightBar ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .frame(width: 16, height: gridH)
        .padding(.leading, 3)
        .contentShape(Rectangle())
        .onHover { hoverRightBar = $0 }
        .onTapGesture {
            for r in cells.indices { cells[r].append(TableCell()) }
        }
        .help("Add a column")
    }

    private func removeRow(_ r: Int) {
        guard rowCount > 1, cells.indices.contains(r) else { return }
        cells.remove(at: r)
        anchor = nil; extent = nil; editingCell = nil
    }

    private func removeColumn(_ c: Int) {
        guard colCount > 1 else { return }
        for r in cells.indices where cells[r].indices.contains(c) {
            cells[r].remove(at: c)
        }
        if var widths = columnWidths, widths.indices.contains(c) {
            widths.remove(at: c)
            columnWidths = widths
        }
        anchor = nil; extent = nil; editingCell = nil
    }

    // MARK: row/column reordering

    private func rowDragGesture(from row: Int) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if movingRow == nil { movingRow = (row, row) }
                guard var m = movingRow else { return }
                // Header stays row 0.
                let target = min(max(m.start + Int((value.translation.height / (cellH + gap)).rounded()),
                                     m.start == 0 ? 0 : 1),
                                 rowCount - 1)
                if target != m.current, m.start != 0 || target == 0 {
                    cells.move(fromOffsets: IndexSet(integer: m.current),
                               toOffset: target > m.current ? target + 1 : target)
                    m.current = target
                    movingRow = m
                }
            }
            .onEnded { _ in
                if let m = movingRow { hover = CellID(r: m.current, c: hover?.c ?? 0) }
                movingRow = nil
            }
    }

    private func columnDragGesture(from col: Int) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if movingCol == nil { movingCol = (col, col) }
                guard var m = movingCol else { return }
                let xs = colX
                let x = xs[m.start] + colW(m.start) / 2 + value.translation.width
                let target = min(max((0..<colCount).first(where: { x < xs[$0 + 1] }) ?? colCount - 1, 0),
                                 colCount - 1)
                if target != m.current {
                    for r in cells.indices where cells[r].indices.contains(m.current) {
                        cells[r].move(fromOffsets: IndexSet(integer: m.current),
                                      toOffset: target > m.current ? target + 1 : target)
                    }
                    if var widths = columnWidths, widths.indices.contains(m.current) {
                        widths.move(fromOffsets: IndexSet(integer: m.current),
                                    toOffset: target > m.current ? target + 1 : target)
                        columnWidths = widths
                    }
                    m.current = target
                    movingCol = m
                }
            }
            .onEnded { _ in
                if let m = movingCol { hover = CellID(r: hover?.r ?? 0, c: m.current) }
                movingCol = nil
            }
    }

    // MARK: grid body
    //
    // PERFORMANCE: selection and hover are OVERLAYS, not per-cell state —
    // a drag-select over a 300-cell table re-rendered every cell per mouse
    // tick when each cell's background depended on the selection.  Rows are
    // Equatable child views (skipped when their data didn't change), and
    // all pointer handling lives on the container.

    /// The grid's top-left in SCREEN coordinates, tracked live.  Every
    /// pointer computation runs in global space minus this origin: a
    /// scroll-view-local space shifts when the content resizes (exactly
    /// what dragging a column divider does), so a wide, horizontally
    /// scrolled table mapped the same screen point to a different cell
    /// mid-drag — the selection "a few rows below" that survived every
    /// earlier fix.
    @State private var gridOrigin: CGPoint = .zero

    private func gridPoint(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - gridOrigin.x, y: global.y - gridOrigin.y)
    }

    private var gridBody: some View {
        ZStack(alignment: .topLeading) {
            // Pointer handling lives on the ROWS, not the container: the
            // dividers are siblings drawn on top, so a press on a divider
            // hits the divider alone and can never also drive selection.
            VStack(alignment: .leading, spacing: gap) {
                ForEach(cells.indices, id: \.self) { r in
                    GridRowView(row: cells[r], isHeader: r == 0,
                                editingCol: editingCell?.r == r ? editingCell?.c : nil,
                                widths: (0..<cells[r].count).map { colW($0) },
                                cellH: cellH, gap: gap,
                                fieldFocused: $fieldFocused,
                                onTextChange: { c, value in
                                    guard cells.indices.contains(r), cells[r].indices.contains(c) else { return }
                                    cells[r][c].text = value
                                },
                                onSubmit: { commitAndMove(dr: 1, dc: 0) },
                                onMoveEdit: { dr, dc in commitAndMove(dr: dr, dc: dc) })
                        .equatable()
                }
            }
            .contentShape(Rectangle())
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { gridOrigin = geo.frame(in: .global).origin }
                    .onChange(of: geo.frame(in: .global).origin) { _, new in gridOrigin = new }
            })
            // Hover feeds the GUTTER controls only — a per-cell hover
            // outline froze mid-drag and read as a stray active cell.
            .onContinuousHover(coordinateSpace: .global) { phase in
                guard movingRow == nil, movingCol == nil, resizingCol == nil else { return }
                if case .active(let p) = phase, let cell = cellAt(gridPoint(p)), cell != hover {
                    hover = cell
                }
            }
            .onTapGesture(count: 2, coordinateSpace: .global) { p in
                guard structureEditable, let cell = cellAt(gridPoint(p)), cell != editingCell else { return }
                anchor = cell; extent = nil
                editingCell = cell
                fieldFocused = true
            }
            .simultaneousGesture(pressAndDragGesture)

            selectionOverlay
            columnDividers
        }
        .onAppear { installKeyMonitor() }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Spreadsheet fill flow: commit the edit and move to (and edit) the
    /// adjacent cell — Return goes down, Tab right, ⇧Tab left, ↑/↓ vertical.
    private func commitAndMove(dr: Int, dc: Int) {
        guard let e = editingCell else { return }
        let target = CellID(r: e.r + dr, c: e.c + dc)
        guard cells.indices.contains(target.r), cells[target.r].indices.contains(target.c) else {
            editingCell = nil
            return
        }
        anchor = target
        extent = nil
        editingCell = structureEditable ? target : nil
        fieldFocused = structureEditable
    }

    /// One gesture for press-select (mouse-down, no double-click wait) and
    /// drag-select.  STATELESS per tick: the anchor always derives from the
    /// gesture's own start location — a tracked "is dragging" flag could
    /// stick when a simultaneous child gesture (a column divider) claimed
    /// the drag and our onEnded was skipped, after which every click only
    /// extended the old selection.  Skipped inside the cell being edited
    /// and over the divider strips.
    private var pressAndDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                // A divider resize owns the drag outright: resizingCol is
                // the divider gesture's own state, so it stays valid even
                // as the boundary MOVES (the geometric dead zone below
                // stopped matching once the column had grown ±5pt, and the
                // fallthrough re-selected against the shifted geometry —
                // the "locked onto the wrong cell" bug).
                if resizingCol != nil { return }
                // Dead zone for the FIRST tick, before the divider gesture
                // reaches its minimum distance and sets resizingCol.
                let start = gridPoint(value.startLocation)
                if isOnDivider(start) { return }
                let startCell = cellAt(start)
                if let editingCell, startCell == editingCell { return }
                guard let startCell else { return }
                if NSApp.keyWindow?.firstResponder is NSText {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                if NSEvent.modifierFlags.contains(.shift), let a = anchor, a != startCell {
                    let target = cellAt(gridPoint(value.location)) ?? startCell
                    if extent != target { extent = target }
                    if editingCell != nil { editingCell = nil }
                    return
                }
                if editingCell != nil { editingCell = nil }
                if anchor != startCell { anchor = startCell }
                let current = cellAt(gridPoint(value.location))
                let newExtent = current == startCell ? nil : current
                if extent != newExtent { extent = newExtent }
            }
    }

    /// True when the point sits on a column-resize divider strip (header
    /// row, near a column boundary).
    private func isOnDivider(_ p: CGPoint) -> Bool {
        guard p.y <= cellH else { return false }
        let xs = colX
        return (1...colCount).contains { abs(p.x - (xs[$0] - gap / 2)) <= 5 }
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if let sel = selection {
            let xs = colX
            Rectangle()
                .fill(Color.accentColor.opacity(0.08))
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.2))
                .frame(width: xs[sel.cols.upperBound + 1] - xs[sel.cols.lowerBound] - gap,
                       height: CGFloat(sel.rows.count) * (cellH + gap) - gap)
                .offset(x: xs[sel.cols.lowerBound],
                        y: CGFloat(sel.rows.lowerBound) * (cellH + gap))
                .allowsHitTesting(false)
        }
    }

    /// Draggable dividers on the column boundaries (over the header row):
    /// drag to set that column's width; the ratios drive the export when
    /// autofit is off.
    private var columnDividers: some View {
        let xs = colX
        return ZStack(alignment: .topLeading) {
            ForEach(0..<colCount, id: \.self) { c in
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 7, height: cellH)
                    .contentShape(Rectangle())
                    .overlay(Rectangle()
                        .fill(Color.secondary.opacity(resizingCol == c ? 0.7 : 0.25))
                        .frame(width: resizingCol == c ? 2 : 1))
                    .offset(x: xs[c + 1] - gap / 2 - 3.5, y: 0)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if resizingCol == nil {
                                    resizingCol = c
                                    resizeBase = colW(c)
                                }
                                guard resizingCol == c, let base = resizeBase else { return }
                                var widths = columnWidths ?? (0..<colCount).map { Double(colW($0)) }
                                while widths.count < colCount { widths.append(Double(cellW)) }
                                // Screen-space delta = actual mouse travel.
                                // A local (or scroll-view) space slides as
                                // the column grows and the content resizes,
                                // feeding the drag back on itself.
                                let delta = value.location.x - value.startLocation.x
                                widths[c] = Double(min(max(base + delta, 50), 480))
                                columnWidths = widths
                            }
                            .onEnded { _ in
                                // Clear a runloop tick late: the simultaneous
                                // selection gesture can still deliver a final
                                // onChanged after this, and it must still see
                                // a resize in progress.
                                let finished = resizingCol
                                DispatchQueue.main.async {
                                    if resizingCol == finished {
                                        resizingCol = nil
                                        resizeBase = nil
                                    }
                                }
                            }
                    )
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
            }
        }
        .frame(width: gridW, height: cellH, alignment: .topLeading)
    }

    private func cellAt(_ p: CGPoint) -> CellID? {
        let xs = colX
        guard let c = (0..<colCount).first(where: { p.x < xs[$0 + 1] }) else { return nil }
        let r = Int(p.y / (cellH + gap))
        guard cells.indices.contains(r), cells[r].indices.contains(c) else { return nil }
        return CellID(r: r, c: c)
    }

    /// SwiftUI's focusable/onKeyPress never reliably saw the arrows here
    /// (ScrollView + AppKit focus), so a LOCAL key monitor handles them:
    /// active only while a selection exists, no edit is in flight, and no
    /// text control holds first responder (captions, cells, SQL boxes keep
    /// their own keys).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard editingCell == nil, let a = anchor,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            let shift = event.modifierFlags.contains(.shift)
            let base = shift ? (extent ?? a) : a
            var next = base
            if event.modifierFlags.contains(.command) {
                // ⌘V: paste a spreadsheet block (tab-separated columns,
                // newline rows) starting at the anchor, growing the grid.
                if event.charactersIgnoringModifiers?.lowercased() == "v", structureEditable,
                   let text = NSPasteboard.general.string(forType: .string) {
                    pasteBlock(text, at: a)
                    return nil
                }
                return event
            }
            switch event.keyCode {
            case 126: next = CellID(r: max(base.r - 1, 0), c: base.c)                // ↑
            case 125: next = CellID(r: min(base.r + 1, rowCount - 1), c: base.c)     // ↓
            case 123: next = CellID(r: base.r, c: max(base.c - 1, 0))                // ←
            case 124: next = CellID(r: base.r, c: min(base.c + 1, colCount - 1))     // →
            case 36:                                                                  // ⏎
                guard structureEditable else { return event }
                editingCell = a
                fieldFocused = true
                return nil
            default:
                return event
            }
            if shift { extent = next } else { anchor = next; extent = nil }
            return nil
        }
    }

    /// Spreads pasted spreadsheet text (TSV: tabs between columns, newlines
    /// between rows) into the grid from `origin`, adding rows and columns
    /// as needed; existing cell styles survive, only texts change.
    private func pasteBlock(_ text: String, at origin: CellID) {
        let rows = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var matrix = rows.map { $0.components(separatedBy: "\t") }
        while matrix.last?.allSatisfy(\.isEmpty) == true { matrix.removeLast() }
        guard !matrix.isEmpty else { return }

        var grid = cells
        let blockCols = matrix.map(\.count).max() ?? 1
        let neededRows = origin.r + matrix.count
        let neededCols = max(origin.c + blockCols, grid.first?.count ?? 1)
        while grid.count < neededRows {
            grid.append(Array(repeating: TableCell(), count: grid.first?.count ?? 1))
        }
        for r in grid.indices {
            while grid[r].count < neededCols { grid[r].append(TableCell()) }
        }
        for (i, row) in matrix.enumerated() {
            for (j, value) in row.enumerated() {
                grid[origin.r + i][origin.c + j].text = value
            }
        }
        cells = grid
        extent = CellID(r: origin.r + matrix.count - 1, c: origin.c + blockCols - 1)
    }

    /// Sizes every column to its widest cell as displayed in the grid —
    /// most tables then need only a drag or two.
    private func fitColumnsToContent() {
        guard colCount > 0 else { return }
        var widths: [Double] = []
        for c in 0..<colCount {
            var w: CGFloat = 40
            for r in cells.indices where cells[r].indices.contains(c) {
                let cell = cells[r][c]
                let font = NSFont.systemFont(ofSize: 12,
                                             weight: (cell.bold ?? (r == 0)) ? .semibold : .regular)
                w = max(w, (cell.text as NSString).size(withAttributes: [.font: font]).width)
            }
            widths.append(Double(min(max(w + 18, 50), 480)))
        }
        columnWidths = widths
    }

    static func highlightColor(_ name: String?) -> Color {
        switch name {
        case "green":  return .green
        case "blue":   return .blue
        case "pink":   return .pink
        case "orange": return .orange
        default:       return .yellow
        }
    }

}


// MARK: - GridRowView

/// One grid row — Equatable so rows whose data didn't change are skipped
/// entirely while selections drag across the table.
private struct GridRowView: View, Equatable {
    let row: [TableCell]
    let isHeader: Bool
    let editingCol: Int?
    let widths: [CGFloat]
    let cellH: CGFloat
    let gap: CGFloat
    var fieldFocused: FocusState<Bool>.Binding
    let onTextChange: (Int, String) -> Void
    let onSubmit: () -> Void
    /// Commit the edit and move to the adjacent cell (Tab/⇧Tab, ↑/↓).
    let onMoveEdit: (Int, Int) -> Void

    static func == (a: GridRowView, b: GridRowView) -> Bool {
        a.row == b.row && a.isHeader == b.isHeader && a.editingCol == b.editingCol
            && a.widths == b.widths
    }

    var body: some View {
        HStack(spacing: gap) {
            ForEach(row.indices, id: \.self) { c in
                cell(c)
            }
        }
    }

    @ViewBuilder
    private func cell(_ c: Int) -> some View {
        let cell = row[c]
        Group {
            if editingCol == c {
                TextField("", text: Binding(
                    get: { row.indices.contains(c) ? row[c].text : "" },
                    set: { onTextChange(c, $0) }
                ))
                .textFieldStyle(.plain)
                .focused(fieldFocused)
                .onSubmit(onSubmit)
                // Spreadsheet fill flow: Tab/⇧Tab horizontal, ↑/↓ vertical
                // (←/→ stay with the caret).
                .onKeyPress(.tab) { onMoveEdit(0, NSEvent.modifierFlags.contains(.shift) ? -1 : 1); return .handled }
                .onKeyPress(.upArrow) { onMoveEdit(-1, 0); return .handled }
                .onKeyPress(.downArrow) { onMoveEdit(1, 0); return .handled }
                .font(font(cell))
                .underline(cell.underline == true)
                .multilineTextAlignment(cell.align == "center" ? .center
                                        : cell.align == "right" ? .trailing : .leading)
            } else {
                Text(cell.text)
                    .font(font(cell))
                    .underline(cell.underline == true)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity,
                           alignment: cell.align == "center" ? .center
                                    : cell.align == "right" ? .trailing : .leading)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: widths.indices.contains(c) ? widths[c] : 132, height: cellH, alignment: .leading)
        .background(background(cell))
        .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }

    private func font(_ cell: TableCell) -> Font {
        var f: Font = .system(size: 12, weight: (cell.bold ?? isHeader) ? .semibold : .regular)
        if cell.italic == true { f = f.italic() }
        return f
    }

    private func background(_ cell: TableCell) -> Color {
        if cell.highlight == true {
            return ManualTableGrid.highlightColor(cell.highlightColor).opacity(0.3)
        }
        return isHeader ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.04)
    }
}
