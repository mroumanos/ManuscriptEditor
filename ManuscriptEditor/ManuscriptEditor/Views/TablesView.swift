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
                    // The linked query's rows ARE the table — rendered with the
                    // same component as the Data pane.
                    if let error = previewResult.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(12)
                        Spacer(minLength: 0)
                    } else {
                        QueryResultTable(result: previewResult)
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
                    ))
                }
            }
            .frame(minHeight: 200)

            // MARK: Metadata form
            Form {
                dataSourceSection
                arrangementSection
                Section("Export Formatting") {
                    HStack(spacing: 4) {
                        Text("Autofit — data starts at row")
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
                    Text("Row 1 is the header; rows between it and row N are dropped from the export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Text("Title")
                        TextField("Title text", text: $draft.title)
                        Spacer()
                        CaptionPartControls(style: $draft.titleStyle, defaultBold: true)
                    case "caption":
                        CaptionPartToggle(style: $draft.captionStyle)
                        Text("Caption")
                        Spacer()
                        Text("⌘B / ⌘I / ⌘U style the text below")
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
            // Rich caption: character-level styling via the standard keys
            // (⌘B/⌘I/⌘U; ⌘{ ⌘| ⌘} align).
            MiniRichEditor(value: Binding(
                get: { draft.captionText ?? RichText(plain: draft.caption) },
                set: { rich in
                    draft.captionText = rich
                    draft.caption = rich.plain
                }
            ))
            .frame(minHeight: 56)
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
            var grid: [[TableCell]] = [result.columns.map { TableCell(text: $0) }]
            grid += result.rows.map { row in row.map { TableCell(text: $0) } }
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

    struct CellID: Hashable { let r: Int; let c: Int }

    // Selection: a rectangle from anchor to extent.
    @State private var anchor: CellID?
    @State private var extent: CellID?
    @State private var editingCell: CellID?
    @FocusState private var fieldFocused: Bool
    @FocusState private var gridFocused: Bool

    @State private var hover: CellID?
    @State private var hoverBottomBar = false
    @State private var hoverRightBar = false

    /// Live row/column drag: (original index, current index).
    @State private var movingRow: (start: Int, current: Int)?
    @State private var movingCol: (start: Int, current: Int)?

    // Fixed geometry so hit-testing and reordering stay simple.
    private let cellW: CGFloat = 132
    private let cellH: CGFloat = 28
    private let gap: CGFloat = 1
    private let gutter: CGFloat = 22

    private var rowCount: Int { cells.count }
    private var colCount: Int { cells.first?.count ?? 0 }
    private var gridW: CGFloat { CGFloat(colCount) * (cellW + gap) - gap }
    private var gridH: CGFloat { CGFloat(rowCount) * (cellH + gap) - gap }

    private var selection: (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
        guard let a = anchor else { return nil }
        let e = extent ?? a
        return (min(a.r, e.r)...max(a.r, e.r), min(a.c, e.c)...max(a.c, e.c))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: gutter, height: gutter)
                        columnGutter
                    }
                    HStack(alignment: .top, spacing: 0) {
                        rowGutter
                        gridBody
                        addColumnBar
                    }
                    HStack(spacing: 0) {
                        Color.clear.frame(width: gutter, height: 1)
                        addRowBar
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
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

            Spacer()
            Text("click selects · double-click edits · drag or ⇧-arrows extend")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var firstSelected: TableCell? {
        guard let sel = selection else { return nil }
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

    private var highlightMenu: some View {
        Menu {
            ForEach(["yellow", "green", "blue", "pink", "orange"], id: \.self) { name in
                Button {
                    mutateSelection { $0.highlight = true; $0.highlightColor = name == "yellow" ? nil : name }
                } label: {
                    Label(name.capitalized, systemImage: "square.fill")
                }
            }
            Divider()
            Button("No highlight") {
                mutateSelection { $0.highlight = nil; $0.highlightColor = nil }
            }
        } label: {
            Image(systemName: "highlighter")
                .foregroundStyle(firstSelected?.highlight == true ? Color.accentColor : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(selection == nil)
        .help("Highlight the selected cells")
    }

    private func mutateSelection(_ change: (inout TableCell) -> Void) {
        guard let sel = selection else { return }
        for r in sel.rows where cells.indices.contains(r) {
            for c in sel.cols where cells[r].indices.contains(c) {
                change(&cells[r][c])
            }
        }
    }

    // MARK: gutters (hover: drag handle + remove)

    /// Top gutter: the hovered COLUMN's grab handle and "−".
    private var columnGutter: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: gridW, height: gutter)
            if let h = hoverColumn {
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("Drag to reorder this column")
                        .gesture(columnDragGesture(from: h))
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
                }
                .frame(width: cellW)
                .offset(x: CGFloat(h) * (cellW + gap), y: 4)
            }
        }
        .frame(height: gutter)
    }

    /// Left gutter: the hovered ROW's grab handle and "−".
    private var rowGutter: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: gutter, height: gridH)
            if let h = hoverRow {
                VStack(spacing: 1) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .help("Drag to reorder this row")
                        .gesture(rowDragGesture(from: h))
                    Button {
                        removeRow(h)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(rowCount <= 1)
                    .help("Remove this row")
                }
                .frame(height: cellH)
                .offset(x: 2, y: CGFloat(h) * (cellH + gap))
            }
        }
        .frame(width: gutter)
    }

    private var hoverRow: Int? { movingRow?.current ?? hover?.r }
    private var hoverColumn: Int? { movingCol?.current ?? hover?.c }

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
            .onEnded { _ in movingRow = nil }
    }

    private func columnDragGesture(from col: Int) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if movingCol == nil { movingCol = (col, col) }
                guard var m = movingCol else { return }
                let target = min(max(m.start + Int((value.translation.width / (cellW + gap)).rounded()), 0),
                                 colCount - 1)
                if target != m.current {
                    for r in cells.indices where cells[r].indices.contains(m.current) {
                        cells[r].move(fromOffsets: IndexSet(integer: m.current),
                                      toOffset: target > m.current ? target + 1 : target)
                    }
                    m.current = target
                    movingCol = m
                }
            }
            .onEnded { _ in movingCol = nil }
    }

    // MARK: grid body

    private var gridBody: some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(cells.indices, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(cells[r].indices, id: \.self) { c in
                        cellView(r: r, c: c)
                    }
                }
            }
        }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress { press in handleKey(press) }
        // Drag across cells extends the selection (taps pass through).
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .onChanged { value in
                    guard editingCell == nil else { return }
                    if anchor == nil || value.translation == .zero {
                        anchor = cellAt(value.startLocation)
                    }
                    if let start = cellAt(value.startLocation) {
                        anchor = anchor ?? start
                    }
                    extent = cellAt(value.location)
                    gridFocused = true
                }
        )
    }

    private func cellAt(_ p: CGPoint) -> CellID? {
        let c = Int(p.x / (cellW + gap))
        let r = Int(p.y / (cellH + gap))
        guard cells.indices.contains(r), cells[r].indices.contains(c) else { return nil }
        return CellID(r: r, c: c)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard editingCell == nil, let a = anchor else { return .ignored }
        let base = press.modifiers.contains(.shift) ? (extent ?? a) : a
        var next = base
        switch press.key {
        case .upArrow:    next = CellID(r: max(base.r - 1, 0), c: base.c)
        case .downArrow:  next = CellID(r: min(base.r + 1, rowCount - 1), c: base.c)
        case .leftArrow:  next = CellID(r: base.r, c: max(base.c - 1, 0))
        case .rightArrow: next = CellID(r: base.r, c: min(base.c + 1, colCount - 1))
        case .return:
            editingCell = a
            fieldFocused = true
            return .handled
        default:
            return .ignored
        }
        if press.modifiers.contains(.shift) {
            extent = next
        } else {
            anchor = next
            extent = nil
        }
        return .handled
    }

    private func isSelected(_ r: Int, _ c: Int) -> Bool {
        guard let sel = selection else { return false }
        return sel.rows.contains(r) && sel.cols.contains(c)
    }

    @ViewBuilder
    private func cellView(r: Int, c: Int) -> some View {
        let cell = cells[r][c]
        let selected = isSelected(r, c)
        Group {
            if editingCell == CellID(r: r, c: c) {
                TextField("", text: Binding(
                    get: {
                        guard cells.indices.contains(r), cells[r].indices.contains(c) else { return "" }
                        return cells[r][c].text
                    },
                    set: { value in
                        guard cells.indices.contains(r), cells[r].indices.contains(c) else { return }
                        cells[r][c].text = value
                    }
                ))
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { editingCell = nil; gridFocused = true }
                .font(cellDisplayFont(cell, header: r == 0))
            } else {
                Text(cell.text)
                    .font(cellDisplayFont(cell, header: r == 0))
                    .underline(cell.underline == true)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity,
                           alignment: cell.align == "center" ? .center
                                    : cell.align == "right" ? .trailing : .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        anchor = CellID(r: r, c: c); extent = nil
                        editingCell = CellID(r: r, c: c)
                        fieldFocused = true
                    }
                    .onTapGesture {
                        anchor = CellID(r: r, c: c); extent = nil
                        editingCell = nil
                        gridFocused = true
                    }
            }
        }
        .padding(.horizontal, 6)
        .frame(width: cellW, height: cellH, alignment: .leading)
        .background(cellBackground(cell, header: r == 0, selected: selected))
        .overlay(
            Rectangle().strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                     lineWidth: selected ? 1.2 : 0.5)
        )
        .onHover { inside in
            if inside { hover = CellID(r: r, c: c) }
            else if hover == CellID(r: r, c: c) { hover = nil }
        }
    }

    private func cellDisplayFont(_ cell: TableCell, header: Bool) -> Font {
        var font: Font = .system(size: 12, weight: (cell.bold ?? header) ? .semibold : .regular)
        if cell.italic == true { font = font.italic() }
        return font
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

    private func cellBackground(_ cell: TableCell, header: Bool, selected: Bool) -> Color {
        if cell.highlight == true {
            return Self.highlightColor(cell.highlightColor).opacity(0.3)
        }
        if selected { return Color.accentColor.opacity(0.10) }
        return header ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.04)
    }
}
