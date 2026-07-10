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

    /// Tables sorted by number (Table 1, Table 2, …).
    private var tables: [ManuscriptTable] {
        (store.manuscript(for: versionRef)?.tables ?? []).sorted { $0.number < $1.number }
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
                                Text("Table \(table.number)").font(.callout.weight(.medium))
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

    init(table: ManuscriptTable, versionRef: VersionRef = .source) {
        self.table = table
        self.versionRef = versionRef
        _draft = State(initialValue: table)
    }

    var body: some View {
        VSplitView {
            // MARK: Markdown content editor
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Table Content (Markdown)").font(.headline)
                    Spacer()
                    Text("Tip: use | Col1 | Col2 | syntax")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)
                Divider()
                // Monospaced font makes pipe-table columns easier to align visually.
                TextEditor(text: $draft.content)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
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
                    TextEditor(text: $draft.caption)
                        .frame(minHeight: 60)
                        .font(.callout)
                }
                Section("Footnotes") {
                    TextEditor(text: $draft.footnotes)
                        .frame(minHeight: 40)
                        .font(.callout)
                }
                dataSourceSection
            }
            .formStyle(.grouped)
            .frame(minHeight: 200)
        }
        .onChange(of: draft.content)      { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.title)        { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.caption)      { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.footnotes)    { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.number)       { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.dataAssetID)  { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: draft.dataQuery)    { _, _ in store.updateTable(draft, ref: versionRef) }
        .onChange(of: table.id)           { _, _ in draft = table }
    }

    // MARK: - Data source section

    private var csvAssets: [DataAsset] {
        (store.manuscript(for: versionRef)?.dataAssets ?? []).filter { $0.type == .csv }
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
                TextField("SQL Query", text: Binding(
                    get: { draft.dataQuery ?? "SELECT * FROM data" },
                    set: { draft.dataQuery = $0 }
                ), axis: .vertical)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2...4)
                Text("The query result populates the table. Markdown content is ignored when a data source is linked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
