// ExportView.swift
//
// The "Export" pane in the Journal sidebar section — the visual editor for a
// journal's **export outline** plus the export action itself.
//
// LAYOUT
// ─────────────────────────────────────────────────────────────────────────────
//   Journal picker (Source + each target journal; each has its own outline)
//   ┌─ Document card ────────────────────────────────┐   stacked, one per
//   │ name · file type · delete                      │   output file
//   │ format row (font, size, spacing, margins,      │
//   │             line numbers, columns)             │
//   │ ordered items (sections, blocks, page breaks)  │
//   │ ＋ Add Item menu                                │
//   └────────────────────────────────────────────────┘
//   ＋ Add Document          [Choose Folder & Export…]
//
// The outline starts as `ExportConfig.standard` for the journal and is
// persisted (per journal) on first edit.  Exported content is the journal's
// latest version (its working head) — or the live Source.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ExportView: View {
    @Environment(ManuscriptStore.self) private var store

    /// When set, this pane represents one comparison tab's journal (Source or
    /// a cut) and edits/exports **that journal's** outline — no journal
    /// picker.  nil = standalone (no tabs open); falls back to Source.
    var versionRef: VersionRef? = nil

    @State private var lastPackage: URL?
    @State private var errorMessage: String?
    /// The journal being saved into the global library (drives the sheet).
    @State private var savingToLibrary: Journal?

    /// Which journal's outline is being edited/exported (nil = Source),
    /// derived from the pane's tab.
    private var journalID: UUID? {
        guard case .version(let id) = versionRef ?? .source else { return nil }
        return store.versions.first { $0.id == id }?.journalID
    }

    /// Display name for the pane's journal.
    private var journalName: String {
        guard let journalID else { return "Source" }
        return journals.first { $0.id == journalID }?.name ?? "Journal"
    }

    /// The outline being edited.  Held in state (not recomputed per access):
    /// an unsaved standard outline gets fresh item ids on every derivation, so
    /// mutating "the config" by id only works against a stable snapshot.
    @State private var config = ExportConfig(documents: [])

    private let service = ExportService()

    private var journals: [Journal] { store.manuscript?.journals ?? [] }

    /// The content a run would export: the journal's working head, or Source.
    private var exportContent: Manuscript? {
        if let journalID {
            return store.latestVersion(forJournal: journalID)?.content
        }
        return store.manuscript
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                ForEach(config.documents) { document in
                    ExportDocumentCard(
                        document: document,
                        content: store.manuscript,
                        onChange: { replace(document: $0) },
                        onDelete: { remove(documentID: document.id) }
                    )
                }

                HStack(spacing: 12) {
                    Button {
                        config.documents.append(ExportDocument(name: "New Document", items: []))
                        persist()
                    } label: {
                        Label("Add Document", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        runExport()
                    } label: {
                        Label("Choose Folder & Export…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(exportContent == nil || config.documents.allSatisfy(\.items.isEmpty))

                    if let lastPackage {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([lastPackage])
                        } label: {
                            Label("Reveal", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 640)

                if journalID != nil && exportContent == nil {
                    Label("This journal has no versions yet — cut one in Versions (or sync it) before exporting.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { reloadConfig() }
        .onChange(of: journalID) { _, _ in reloadConfig() }
        .onChange(of: store.manuscript?.id) { _, _ in reloadConfig() }
        .sheet(item: $savingToLibrary) { journal in
            SaveToJournalLibrarySheet(journal: journal, isPresented: Binding(
                get: { savingToLibrary != nil },
                set: { if !$0 { savingToLibrary = nil } }
            ))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export").font(.title2.weight(.semibold))
            Text("Each journal has its own export outline: the documents in its submission package, what goes into each (with page breaks), and each document's format and file type.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                // The pane IS its tab's journal — no picker to re-litigate it.
                Label(journalName, systemImage: journalID == nil ? "doc.text" : "building.columns")
                    .font(.headline)

                if let journal = journals.first(where: { $0.id == journalID }) {
                    Button {
                        savingToLibrary = journal
                    } label: {
                        Label("Save to Journal Library…", systemImage: "books.vertical")
                    }
                    .controlSize(.small)
                    .help("Store this journal's export outline (and checks) as a reusable library profile")
                }

                if let content = exportContent, journalID != nil,
                   let head = store.latestVersion(forJournal: journalID) {
                    Text("Exports v\(store.journalOrdinal(of: head)) · \(content.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    // MARK: - Config mutation

    private func reloadConfig() {
        config = store.exportConfig(forJournal: journalID)
    }

    /// Persists the edited outline (first edit customizes a standard outline).
    private func persist() {
        store.updateExportConfig(config, forJournal: journalID)
    }

    private func replace(document: ExportDocument) {
        guard let idx = config.documents.firstIndex(where: { $0.id == document.id }) else { return }
        config.documents[idx] = document
        persist()
    }

    private func remove(documentID: UUID) {
        config.documents.removeAll { $0.id == documentID }
        persist()
    }

    // MARK: - Export

    private func runExport() {
        guard let content = exportContent else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where to save the submission package"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let name = journalID.flatMap { id in journals.first { $0.id == id }?.name }
            ?? store.manuscript?.title ?? "Manuscript"
        do {
            let journalStyle = journals.first { $0.id == journalID }?
                .requirements.citationStyle.cslID ?? "apa"
            let folder = try service.exportPackage(
                config: config,
                content: content,
                packageName: name,
                citationStyleDefault: journalStyle,
                figureURL: { store.figureURL(for: $0) },
                chartImage: { ExportRendering.chartImage(for: $0, store: store) },
                tableData: { ExportRendering.tableData(for: $0, store: store) },
                into: destination
            )
            lastPackage = folder
            errorMessage = nil
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - ExportRendering

/// Bridges data-linked figures/tables into exportable form: charts rendered
/// to images (SwiftUI ImageRenderer over the same DataChartView the editor
/// shows — the editor is the preview), tables resolved to their SQL rows.
@MainActor
enum ExportRendering {

    static func chartImage(for figure: Figure, store: ManuscriptStore) -> NSImage? {
        guard let assetID = figure.dataAssetID,
              let asset = store.manuscript?.dataAssets.first(where: { $0.id == assetID })
        else { return nil }
        let result = store.runQuery(figure.chartQuery ?? "SELECT * FROM data", for: asset)
        guard result.errorMessage == nil, !result.rows.isEmpty else { return nil }
        let chart = DataChartView(
            result: result,
            chartType: figure.chartType == .histogram ? .bar : (figure.chartType ?? .bar),
            palette: ChartPalette(rawValue: figure.chartPalette ?? "") ?? .standard
        )
        .frame(width: 560, height: 320)
        .padding(14)
        .background(Color.white)
        .environment(\.colorScheme, .light)   // print output is always light

        let renderer = ImageRenderer(content: chart)
        renderer.scale = 2
        return renderer.nsImage
    }

    static func tableData(for table: ManuscriptTable, store: ManuscriptStore) -> QueryResult? {
        guard let assetID = table.dataAssetID,
              let asset = store.manuscript?.dataAssets.first(where: { $0.id == assetID })
        else { return nil }
        let result = store.runQuery(table.dataQuery ?? "SELECT * FROM data", for: asset)
        return result.errorMessage == nil ? result : nil
    }
}

// MARK: - ExportDocumentCard

/// One stacked card = one output file: name/type header, format controls, and
/// the ordered item list with add/remove/reorder.
private struct ExportDocumentCard: View {
    let document: ExportDocument
    let content: Manuscript?
    let onChange: (ExportDocument) -> Void
    let onDelete: () -> Void

    /// Item currently being dragged by its handle (drag-to-reorder).
    @State private var draggingItemID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(12)
            Divider()
            itemsList
                .padding(.vertical, 4)
            Divider()
            addItemRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
        .frame(maxWidth: 640)
    }

    // MARK: header

    /// Name, file type, and the page-geometry settings (margins/columns can't
    /// vary per section — everything typographic lives in the item columns).
    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(Color.accentColor)
            TextField("Document name", text: binding(\.name))
                .textFieldStyle(.plain)
                .font(.headline)
            Spacer()
            Picker("", selection: binding(\.fileType)) {
                ForEach(ExportFileType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            .fixedSize()
            Picker("", selection: binding(\.format.lineSpacing)) {
                Text("1× spacing").tag(1.0)
                Text("1.15 spacing").tag(1.15)
                Text("1.5 spacing").tag(1.5)
                Text("2× spacing").tag(2.0)
            }
            .labelsHidden()
            .fixedSize()
            .help("Line spacing (whole document — keeps headings and body uniform)")
            Picker("", selection: binding(\.format.marginInches)) {
                Text("0.75″ margins").tag(0.75)
                Text("1″ margins").tag(1.0)
                Text("1.25″ margins").tag(1.25)
            }
            .labelsHidden()
            .fixedSize()
            .help("Page margins (whole document)")
            Picker("", selection: binding(\.format.twoColumn)) {
                Text("1 column").tag(false)
                Text("2 columns").tag(true)
            }
            .labelsHidden()
            .fixedSize()
            .help("Column layout (whole document) — applies to PDF and LaTeX")
            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove this document from the package")
        }
        .controlSize(.small)
    }

    // MARK: items

    /// Fixed widths so the per-item format controls align as columns.
    private var colFont: CGFloat { 108 }
    private var colSize: CGFloat { 62 }
    private var colSpacing: CGFloat { 72 }
    private var colLines: CGFloat { 40 }

    private var itemsList: some View {
        VStack(spacing: 0) {
            if document.items.isEmpty {
                Text("Empty document — add sections below.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(10)
            } else {
                columnHeader
                Divider()
            }
            ForEach(Array(document.items.enumerated()), id: \.element.id) { index, item in
                itemRow(item, index: index)
                if index < document.items.count - 1 {
                    Divider().padding(.leading, 40)
                }
            }
        }
    }

    /// Column titles above the per-item format controls.
    private var columnHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16 + 20 + 8, height: 1)   // handle + icon
            Text("Section")
            Spacer(minLength: 4)
            Text("Font").frame(width: colFont)
            Text("Size").frame(width: colSize)
            Text("Lines").frame(width: colLines)
            Color.clear.frame(width: 16, height: 1)            // remove button
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func itemRow(_ item: ExportItem, index: Int) -> some View {
        HStack(spacing: 8) {
            dragHandle(item)
            Image(systemName: item.systemImage)
                .foregroundStyle(item.kind == .pageBreak ? Color.secondary : Color.accentColor)
                .frame(width: 20)

            if item.kind == .pageBreak {
                line
                Text("Page Break").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                line
            } else {
                // Click the name to rename the heading in this document
                // (export-level override; the manuscript section keeps its title).
                TextField(item.title(in: content), text: titleBinding(index))
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(item.titleShown ? .primary : .tertiary)
                // Print/hide this item's heading in the export.  The content
                // always exports; only the printed title toggles ("H" ≠ the
                // remove ✕, which drops the whole item).
                if item.kind != .titlePage && item.kind != .authors {
                    // References: which citation style the list renders in
                    // (default = the journal's required style) — sits LEFT
                    // of the heading controls.
                    if item.kind == .references {
                        Picker("", selection: Binding(
                            get: { item.citationStyle },
                            set: { style in
                                var doc = document
                                guard doc.items.indices.contains(index) else { return }
                                doc.items[index].citationStyle = style
                                onChange(doc)
                            }
                        )) {
                            Text("Journal style").tag(String?.none)
                            Text("APA").tag(String?.some("apa"))
                            Text("AMA").tag(String?.some("american-medical-association"))
                            Text("Vancouver").tag(String?.some("vancouver"))
                            Text("MLA").tag(String?.some("modern-language-association"))
                            Text("Chicago").tag(String?.some("chicago-author-date"))
                            Text("Harvard").tag(String?.some("harvard-cite-them-right"))
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .help("Citation style for the reference list — \"Journal style\" follows the journal's requirements")
                    }
                    Button {
                        var doc = document
                        guard doc.items.indices.contains(index) else { return }
                        doc.items[index].titleShown.toggle()
                        onChange(doc)
                    } label: {
                        Image(systemName: item.titleShown ? "h.square.fill" : "h.square")
                            .foregroundStyle(item.titleShown ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Include heading in the export")
                    // Heading format, revealed while the heading is included.
                    if item.titleShown {
                        headingStyleControls(item, index: index)
                    }
                } else if item.kind == .authors
                            || !document.items.contains(where: { $0.kind == .authors }) {
                    // Append the authors' credentials ("Jane Doe, MD") to
                    // the byline — on the Authors item, or on Title only for
                    // pre-split configs where Title still renders the byline.
                    // Author delimiter: what separates the names (and the
                    // affiliation lines below them).
                    Picker("", selection: Binding(
                        get: { item.authorDelimiter ?? "semicolon" },
                        set: { value in
                            var doc = document
                            guard doc.items.indices.contains(index) else { return }
                            doc.items[index].authorDelimiter = value == "semicolon" ? nil : value
                            onChange(doc)
                        }
                    )) {
                        Text("semicolon").tag("semicolon")
                        Text("comma").tag("comma")
                        Text("space").tag("space")
                        Text("slash").tag("slash")
                        Text("hyphen").tag("hyphen")
                        Text("newline").tag("newline")
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                    .help("Delimiter between authors (and affiliation lines)")
                    // Author ↔ institution linkage markers.
                    Picker("", selection: Binding(
                        get: {
                            let v = item.affiliationMarker ?? "superscript"
                            return v == "doublecross" ? "cross" : v   // legacy value
                        },
                        set: { value in
                            var doc = document
                            guard doc.items.indices.contains(index) else { return }
                            doc.items[index].affiliationMarker = value == "superscript" ? nil : value
                            onChange(doc)
                        }
                    )) {
                        Text("a¹").tag("superscript")
                        Text("a†").tag("cross")
                        Text("none").tag("none")
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                    .help("How authors link to their institutions — crosshatches escalate †, ‡, ††† with each institution")
                    Button {
                        var doc = document
                        guard doc.items.indices.contains(index) else { return }
                        doc.items[index].authorTitlesShown.toggle()
                        onChange(doc)
                    } label: {
                        Text("+ cred")
                            .font(.caption)
                            .foregroundStyle(item.authorTitlesShown
                                ? Color.accentColor
                                : Color(nsColor: .tertiaryLabelColor))
                    }
                    .buttonStyle(.plain)
                    .help("Append author credentials (MD, PhD…) to the byline")
                }
                Spacer(minLength: 4)
                formatColumns(item, index: index)
            }

            Button {
                var doc = document
                doc.items.remove(at: index)
                onChange(doc)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.caption)
            }
            .buttonStyle(.plain)
            .help("Remove from this document")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, item.kind == .pageBreak ? 4 : 6)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.text], delegate: ItemDropDelegate(
            targetID: item.id,
            draggingID: $draggingItemID,
            moveAction: { moveItem($0, before: $1) }
        ))
        .contextMenu {
            if item.kind != .pageBreak, item.format != nil {
                Button("Reset Formatting to Document") {
                    var doc = document
                    guard doc.items.indices.contains(index) else { return }
                    doc.items[index].format = nil
                    onChange(doc)
                }
            }
        }
    }

    /// Bold / underline / center / size for the printed heading, shown only
    /// while its "H" toggle is on.
    private func headingStyleControls(_ item: ExportItem, index: Int) -> some View {
        let style = item.effectiveHeadingStyle
        func mutate(_ change: @escaping (inout ExportItem.HeadingStyle) -> Void) {
            var doc = document
            guard doc.items.indices.contains(index) else { return }
            var s = doc.items[index].effectiveHeadingStyle
            change(&s)
            doc.items[index].headingStyle = s
            onChange(doc)
        }
        func toggle(_ symbol: String, _ active: Bool, _ help: String,
                    _ change: @escaping (inout ExportItem.HeadingStyle) -> Void) -> some View {
            Button { mutate(change) } label: {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(active ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .help(help)
        }
        return HStack(spacing: 3) {
            toggle("bold", style.bold, "Bold heading") { $0.bold.toggle() }
            toggle("underline", style.underline, "Underlined heading") { $0.underline.toggle() }
            toggle("text.aligncenter", style.centered, "Centered heading") { $0.centered.toggle() }
            // Word-style level instead of a typed point size: click cycles
            // H1 → H2 → H3; the level sets the size off the document font.
            Button {
                mutate {
                    $0.level = $0.effectiveLevel % 3 + 1
                    $0.pointSize = nil   // level now governs the size
                }
            } label: {
                Text("H\(style.effectiveLevel)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Heading level — click to cycle H1 → H2 → H3")
        }
    }

    /// Inline, per-item format controls (aligned under the column header).
    /// Values show the item's effective format; editing creates its override.
    private func formatColumns(_ item: ExportItem, index: Int) -> some View {
        let overridden = item.format != nil
        return HStack(spacing: 8) {
            Picker("", selection: fmtBinding(index, \.fontFamily)) {
                ForEach(ExportFontFamily.allCases) { family in
                    Text(family.shortLabel).tag(family)
                }
            }
            .frame(width: colFont)

            HStack(spacing: 1) {
                let sizeBinding = Binding(
                    get: { Int((item.format?.fontSize ?? document.format.fontSize).rounded()) },
                    set: { newValue in fmtBinding(index, \.fontSize).wrappedValue = Double(min(max(newValue, 6), 99)) }
                )
                TextField("", value: sizeBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.mini)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 28)
                Stepper("", value: sizeBinding, in: 6...99)
                    .labelsHidden()
                    .controlSize(.mini)
            }
            .frame(width: colSize)

            Toggle("", isOn: fmtBinding(index, \.lineNumbers))
                .toggleStyle(.checkbox)
                .frame(width: colLines)
        }
        .labelsHidden()
        .controlSize(.small)
        .tint(overridden ? Color.accentColor : nil)
        .help(overridden
              ? "Custom format for this item (right-click to reset to the document's)"
              : "Inherits the document format — change any value to customize this item")
    }

    /// Effective-format binding for one item: reads the override (or the
    /// document format), writes by creating/extending the item's override.
    private func fmtBinding<T>(_ index: Int,
                               _ keyPath: WritableKeyPath<ExportDocumentFormat, T>) -> Binding<T> {
        Binding(
            get: {
                guard document.items.indices.contains(index) else {
                    return document.format[keyPath: keyPath]
                }
                return (document.items[index].format ?? document.format)[keyPath: keyPath]
            },
            set: { newValue in
                var doc = document
                guard doc.items.indices.contains(index) else { return }
                var format = doc.items[index].format ?? doc.format
                format[keyPath: keyPath] = newValue
                doc.items[index].format = format
                onChange(doc)
            }
        )
    }

    /// The three-line grab handle: drag it to reorder items.
    private func dragHandle(_ item: ExportItem) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(width: 16)
            .contentShape(Rectangle())
            .onDrag {
                draggingItemID = item.id
                return NSItemProvider(object: item.id.uuidString as NSString)
            }
            .help("Drag to reorder")
    }

    private var line: some View {
        Rectangle().fill(.separator).frame(height: 1).frame(maxWidth: .infinity)
    }

    /// Reorders the dragged item to the hovered row's position (live, while
    /// dragging — the standard SwiftUI move-on-hover pattern).
    private func moveItem(_ draggedID: UUID, before targetID: UUID) {
        var doc = document
        guard let from = doc.items.firstIndex(where: { $0.id == draggedID }),
              let to = doc.items.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            doc.items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            onChange(doc)
        }
    }

    /// Export-heading override binding: empty text reverts to the default title.
    private func titleBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard document.items.indices.contains(index) else { return "" }
                let item = document.items[index]
                return item.customTitle ?? item.title(in: content)
            },
            set: { newValue in
                var doc = document
                guard doc.items.indices.contains(index) else { return }
                doc.items[index].customTitle = newValue.isEmpty ? nil : newValue
                onChange(doc)
            }
        )
    }

    // MARK: add item

    /// Components not yet present (page breaks can repeat; sections listed by name).
    private var addItemRow: some View {
        Menu {
            Section("Components") {
                ForEach(missingSimpleKinds, id: \.self) { kind in
                    Button {
                        append(ExportItem(kind: kind))
                    } label: {
                        Label(ExportItem(kind: kind).title(in: content),
                              systemImage: ExportItem(kind: kind).systemImage)
                    }
                }
            }
            if !missingSections.isEmpty {
                Section("Body Sections") {
                    ForEach(missingSections) { section in
                        Button {
                            append(ExportItem(kind: .section, sectionID: section.id))
                        } label: {
                            Label(section.title, systemImage: "doc.text")
                        }
                    }
                }
            }
            Divider()
            Button {
                append(ExportItem(kind: .pageBreak))
            } label: {
                Label("Page Break", systemImage: "arrow.down.to.line.compact")
            }
        } label: {
            Label("Add Item", systemImage: "plus")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var missingSimpleKinds: [ExportItem.Kind] {
        let present = Set(document.items.map(\.kind))
        return [.titlePage, .authors, .abstract, .keywords, .figures, .tables, .references, .coverLetter]
            .filter { !present.contains($0) }
    }

    private var missingSections: [ManuscriptSection] {
        let present = Set(document.items.compactMap(\.sectionID))
        return (content?.sections ?? [])
            .sorted { $0.order < $1.order }
            .filter { !present.contains($0.id) }
    }

    private func append(_ item: ExportItem) {
        var doc = document
        doc.items.append(item)
        onChange(doc)
    }

    // MARK: binding plumbing

    /// A binding into the document value that routes writes through `onChange`.
    private func binding<T>(_ keyPath: WritableKeyPath<ExportDocument, T>) -> Binding<T> {
        Binding(
            get: { document[keyPath: keyPath] },
            set: { newValue in
                var doc = document
                doc[keyPath: keyPath] = newValue
                onChange(doc)
            }
        )
    }
}

// MARK: - ItemDropDelegate

/// Move-on-hover drop delegate for the drag-handle reorder.
private struct ItemDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggingID: UUID?
    let moveAction: (_ dragged: UUID, _ target: UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != targetID else { return }
        moveAction(draggingID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
