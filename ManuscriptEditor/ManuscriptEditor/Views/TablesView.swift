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
                    Text(draft.dataAssetID == nil ? "Table Content (Markdown)" : "Data Preview")
                        .font(.headline)
                    Spacer()
                    if draft.dataAssetID == nil {
                        Text("Tip: use | Col1 | Col2 | syntax")
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
                    // Monospaced font makes pipe-table columns easier to align visually.
                    PlainTextEditor(text: $draft.content,
                                    font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                                    smartSubstitutions: false)
                        .padding(12)
                }
            }
            .frame(minHeight: 200)

            // MARK: Metadata form
            Form {
                Section("Metadata") {
                    LabeledContent("Number") {
                        TextField("", value: $draft.number, format: .number)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Title", text: $draft.title)
                }
                Section("Caption") {
                    PlainTextEditor(text: $draft.caption)
                        .frame(minHeight: 60)
                }
                Section("Footnotes") {
                    PlainTextEditor(text: $draft.footnotes)
                        .frame(minHeight: 40)
                    Text("Exports as a \"Note.\" paragraph beneath the table.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Export Formatting") {
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
                dataSourceSection
            }
            .formStyle(.grouped)
            .frame(minHeight: 200)
        }
        .onChange(of: draft.openSides)        { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.alternateShading) { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.content)      { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.title)        { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.caption)      { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.footnotes)    { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.number)       { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.dataAssetID)  { _, _ in store.updateTable(draft, ref: versionRef); refreshPreview() }
        .onChange(of: draft.dataQuery)    { _, _ in store.updateTable(draft, ref: versionRef); refreshPreview(debounced: true) }
        .onChange(of: table) { _, new in
            // External change (selection switch or document undo) — the form's
            // own commits arrive back equal to the draft and are skipped.
            guard new != draft else { return }
            draft = new
            refreshPreview()
        }
        .onAppear                         { refreshPreview() }
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
                Text("The query result populates the table. Markdown content is ignored when a data source is linked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
