// BibliographyView.swift
//
// Two-pane view for managing the manuscript's reference list.
//
// Layout (HSplitView):
//   LEFT   — searchable list of references grouped by type, "Add Reference" button
//   RIGHT  — BibEntryEditor form for the selected reference
//
// References are grouped by `BibEntryType` (Journal Article, Book, etc.) and sorted
// newest-first within each group.  The search bar filters across title, authors,
// citation key, and journal name.

import SwiftUI

// MARK: - BibliographyView

/// The bibliography panel: searchable reference list on the left, editor on the right.
struct BibliographyView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    /// UUID of the currently selected reference.
    @State private var selectedID: UUID?
    /// Text typed in the search bar; empty means show all.
    @State private var searchText = ""
    /// Drives the Zotero import sheet.
    @State private var showZoteroImport = false
    /// Drives the add-by-URL sheet.
    @State private var showURLSheet = false

    /// All references, filtered by `searchText`.
    private var entries: [BibEntry] {
        let all = store.manuscript(for: versionRef)?.bibliography ?? []
        guard !searchText.isEmpty else { return all }
        let q = searchText.lowercased()
        return all.filter {
            $0.title.lowercased().contains(q) ||
            $0.authorsFormatted.lowercased().contains(q) ||
            $0.key.lowercased().contains(q) ||
            ($0.journal?.lowercased().contains(q) ?? false)
        }
    }

    private var allEntries: [BibEntry] {
        store.manuscript(for: versionRef)?.bibliography ?? []
    }

    var body: some View {
        Group {
        if allEntries.isEmpty && searchText.isEmpty {
            emptyState
        } else {
            HSplitView {
                // MARK: Left — searchable list
                VStack(spacing: 0) {
                    searchBar
                    Divider()

                    if entries.isEmpty {
                        VStack { Spacer(); Text("No results").foregroundStyle(.tertiary); Spacer() }
                            .frame(maxWidth: .infinity)
                    } else {
                        // Flat list in bibliography order.  Cited entries are
                        // pinned to the top in citation order automatically;
                        // dragging arranges the uncited tail (a dragged cited
                        // entry snaps back to its citation position).
                        let index = store.citationIndex(ref: versionRef)
                        List(selection: $selectedID) {
                            ForEach(entries) { entry in
                                entryRow(entry,
                                         number: index.numbers[entry.id],
                                         citedCount: index.counts[entry.id])
                                    .tag(entry.id)
                            }
                            .onMove { source, destination in
                                // Reordering only makes sense on the unfiltered list.
                                guard searchText.isEmpty else { return }
                                store.moveBibEntries(from: source, to: destination, ref: versionRef)
                            }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.windowBackgroundColor))
                        .onAppear { autoSelect() }
                        .onChange(of: entries.map(\.id)) { _, _ in autoSelect() }
                    }

                    Divider()

                    HStack(spacing: 2) {
                        addReferenceMenu
                            .padding(.leading, 10).padding(.vertical, 10)
                        Spacer()
                        Text("\(allEntries.count) reference\(allEntries.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 10)
                    }
                    .background(Color(NSColor.windowBackgroundColor))
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))

                // MARK: Right — reference editor
                if let id = selectedID,
                   let entry = store.manuscript(for: versionRef)?.bibliography.first(where: { $0.id == id }) {
                    BibEntryEditor(entry: entry, versionRef: versionRef)
                } else {
                    Color.clear
                }
            }
        }
        }
        .sheet(isPresented: $showZoteroImport) {
            ZoteroImportSheet(versionRef: versionRef)
        }
        .sheet(isPresented: $showURLSheet) {
            AddReferenceByURLSheet(versionRef: versionRef) { newID in
                selectedID = newID
            }
        }
    }

    /// "Add Reference" as a menu: Manual, From Zotero…, or From URL….
    private var addReferenceMenu: some View {
        Menu {
            Button("Manual") {
                store.addBibEntry(ref: versionRef)
                selectedID = store.manuscript(for: versionRef)?.bibliography.last?.id
            }
            Button("From Zotero…") { showZoteroImport = true }
            Button("From URL…") { showURLSheet = true }
        } label: {
            Label("Add Reference", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No References Yet")
                .font(.title3.weight(.semibold))
            Text("Add references manually, from Zotero, or by URL.")
                .foregroundStyle(.secondary)
            addReferenceMenu
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.secondary.opacity(0.12), in: Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sub-views

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search references…", text: $searchText).textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// One row in the reference list: citation number (when cited), key, year,
    /// cited badge, title, first author.
    private func entryRow(_ entry: BibEntry, number: Int? = nil, citedCount: Int? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let number {
                        Text("[\(number)]")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.blue)
                            .help("Citation number \(number) — set by first citation in the text")
                    }
                    Text(entry.key.isEmpty ? "(no key)" : entry.key)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                    if let year = entry.year {
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.type.rawValue)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    if let citedCount {
                        Label("\(citedCount)", systemImage: "quote.opening")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                            .help("Cited \(citedCount) time\(citedCount == 1 ? "" : "s") in the text")
                    }
                }
                Text(entry.title.isEmpty ? "(no title)" : entry.title)
                    .font(.callout).lineLimit(2)
                if !entry.authorsFormatted.isEmpty {
                    Text(entry.authorsFormatted)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button {
                guard let idx = store.manuscript(for: versionRef)?.bibliography.firstIndex(where: { $0.id == entry.id }) else { return }
                store.deleteBibEntries(at: IndexSet([idx]), ref: versionRef)
                if selectedID == entry.id {
                    selectedID = store.manuscript(for: versionRef)?.bibliography.first(where: { $0.id != entry.id })?.id
                }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove reference")
        }
        .padding(.vertical, 2)
    }

    private func autoSelect() {
        let all = store.manuscript(for: versionRef)?.bibliography ?? []
        if selectedID == nil || !all.contains(where: { $0.id == selectedID }) {
            selectedID = all.first?.id
        }
    }
}

// MARK: - BibEntryEditor

/// Full form for editing all fields of one bibliography entry.
struct BibEntryEditor: View {
    @Environment(ManuscriptStore.self) private var store
    let entry: BibEntry
    /// Which version this reference belongs to.
    var versionRef: VersionRef = .source

    /// Mutable working copy.
    @State private var draft: BibEntry
    /// Authors are edited as a multi-line TextEditor (one author per line).
    @State private var authorsText = ""

    init(entry: BibEntry, versionRef: VersionRef = .source) {
        self.entry = entry
        self.versionRef = versionRef
        _draft = State(initialValue: entry)
        _authorsText = State(initialValue: entry.authors.joined(separator: "\n"))
    }

    /// Zotero-imported references are managed in Zotero and shown read-only here.
    private var isReadOnly: Bool { entry.zoteroKey != nil }

    var body: some View {
        ScrollView {
            if isReadOnly {
                Label("Managed in Zotero — read-only. Add, edit, and organize this reference in Zotero.",
                      systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .padding([.horizontal, .top], 16)
            }
            Form {
                citationsSection

                // Editable fields only — the citations summary above stays
                // interactive even for read-only (Zotero-managed) entries.
                Group {
                Section("Citation Key & Type") {
                    TextField("Citation key (e.g. Smith2023)", text: $draft.key)
                    Picker("Type", selection: $draft.type) {
                        ForEach(BibEntryType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                }

                // One author per line, "Last, First" format.
                Section("Authors (one per line, Last, First format)") {
                    PlainTextEditor(text: $authorsText)
                        .frame(minHeight: 80)
                        .onChange(of: authorsText) { _, new in
                            draft.authors = new.components(separatedBy: "\n")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        }
                }

                Section("Publication Details") {
                    TextField("Title", text: $draft.title)
                    LabeledContent("Year") {
                        TextField("Year", value: $draft.year, format: .number)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Journal / Publisher",   text: optionalBinding(\.journal))
                    TextField("Volume",                text: optionalBinding(\.volume))
                    TextField("Issue / Number",        text: optionalBinding(\.issue))
                    TextField("Pages (e.g. 123–145)", text: optionalBinding(\.pages))
                }

                Section("Identifiers") {
                    TextField("DOI", text: optionalBinding(\.doi))
                    TextField("URL", text: optionalBinding(\.url))
                }

                Section("Notes") {
                    PlainTextEditor(text: optionalBinding(\.note))
                        .frame(minHeight: 50)
                }
                }
                .disabled(isReadOnly)   // Zotero entries are read-only
            }
            .formStyle(.grouped)
            .padding(.bottom, 16)
        }
        .onChange(of: draft.key)        { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.type)       { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.title)      { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.authors)    { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.year)       { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.journal)    { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.volume)     { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.issue)      { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.pages)      { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.doi)        { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.url)        { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.note)       { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: entry.id)         { _, _ in
            draft = entry
            authorsText = entry.authors.joined(separator: "\n")
        }
    }

    /// Where (and how often) this entry is cited in the text: citation number,
    /// then one row per prose field in document order.  Lives in the details —
    /// no extra list column needed.
    @ViewBuilder
    private var citationsSection: some View {
        let index = store.citationIndex(ref: versionRef)
        Section("Cited In") {
            if let number = index.numbers[entry.id] {
                LabeledContent("Citation number") {
                    Text("[\(number)]").font(.callout.weight(.semibold)).foregroundStyle(.blue)
                }
                ForEach(index.usage[entry.id] ?? [], id: \.location) { use in
                    LabeledContent(use.location) {
                        Text(use.count == 1 ? "once" : "×\(use.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Not cited in the text yet — type “/” in any prose field to reference it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Converts an `Optional<String>` key-path into a `Binding<String>` so SwiftUI
    /// TextFields can bind to optional properties without needing a separate `@State`.
    private func optionalBinding(_ keyPath: WritableKeyPath<BibEntry, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
