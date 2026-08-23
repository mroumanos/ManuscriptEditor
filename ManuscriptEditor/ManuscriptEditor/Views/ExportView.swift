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
import PDFKit
import UniformTypeIdentifiers

struct ExportView: View {
    @Environment(ManuscriptStore.self) private var store

    /// When set, this pane represents one comparison tab's journal (Source or
    /// a cut) and edits/exports **that journal's** outline — no journal
    /// picker.  nil = standalone (no tabs open); falls back to Source.
    var versionRef: VersionRef? = nil

    @State private var lastPackage: URL?
    /// Drives the export-preview sheet (real pipeline → PDFKit).
    @State private var showingPreview = false
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
                        showingPreview = true
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)
                    .disabled(exportContent == nil || config.documents.allSatisfy(\.items.isEmpty))
                    .help("Render the export exactly as the pipeline will produce it")

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
        // Components edit their own export formatting (toolbar, heading row,
        // settings buttons) — reload so the mirrors and Preview stay live.
        .onChange(of: store.manuscript?.updatedAt) { _, _ in reloadConfig() }
        .sheet(isPresented: $showingPreview) {
            if let content = exportContent {
                let style = journals.first { $0.id == journalID }?
                    .requirements.citationStyle.cslID ?? "apa"
                ExportPreviewSheet(
                    documents: config.documents.filter { !$0.items.isEmpty },
                    isPresented: $showingPreview,
                    render: { document in
                        service.previewPDF(document: document, content: content,
                                           citationStyleDefault: style,
                                           figureURL: { store.figureURL(for: $0) },
                                           chartImage: { ExportRendering.chartImage(for: $0, store: store) },
                                           tableData: { ExportRendering.tableData(for: $0, store: store) })
                    })
            }
        }
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

// MARK: - ExportPreviewSheet

/// The export rendered through the REAL pipeline (segments + paginator)
/// into a PDFKit view — what the output will actually look like, per
/// document.  Documents with non-PDF file types preview their layout as
/// PDF (same typography, margins, and pagination).
struct ExportPreviewSheet: View {
    let documents: [ExportDocument]
    @Binding var isPresented: Bool
    let render: (ExportDocument) -> Data

    @State private var selectedID: UUID?
    @State private var pdfData: Data?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if documents.count > 1 {
                    Picker("", selection: $selectedID) {
                        ForEach(documents) { document in
                            Text(document.name).tag(Optional(document.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(documents.first?.name ?? "Preview").font(.headline)
                }
                Text("rendered with the export pipeline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let pdfData {
                PDFKitView(data: pdfData)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 780, height: 860)
        .onAppear {
            selectedID = documents.first?.id
            renderSelected()
        }
        .onChange(of: selectedID) { _, _ in renderSelected() }
    }

    private func renderSelected() {
        guard let document = documents.first(where: { $0.id == selectedID }) else { return }
        pdfData = nil
        // Next runloop tick so the spinner paints before the render blocks.
        DispatchQueue.main.async { pdfData = render(document) }
    }
}

/// PDFKit host — auto-scaling, continuous-page view of the rendered data.
struct PDFKitView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        context.coordinator.lastCount = data.count
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.lastCount != data.count else { return }
        context.coordinator.lastCount = data.count
        view.document = PDFDocument(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastCount = -1 }
}

// MARK: - SectionPreviewButton

/// Eye-glass button in a content pane's header: renders JUST this pane's
/// item through the real export pipeline — using the journal's export
/// document typography — into the preview sheet.
struct SectionPreviewButton: View {
    @Environment(ManuscriptStore.self) private var store

    let item: SidebarItem
    let versionRef: VersionRef

    @State private var showing = false

    /// The export item this pane maps to (nil = not previewable).
    private var exportItem: ExportItem? {
        switch item {
        case .title:           return ExportItem(kind: .titlePage)
        case .authors:         return ExportItem(kind: .authors)
        case .abstract:        return ExportItem(kind: .abstract)
        case .keywords:        return ExportItem(kind: .keywords)
        case .section(let id): return ExportItem(kind: .section, sectionID: id)
        case .figures:         return ExportItem(kind: .figures)
        case .tables:          return ExportItem(kind: .tables)
        case .bibliography:    return ExportItem(kind: .references)
        case .letterToEditor:  return ExportItem(kind: .coverLetter)
        default:               return nil
        }
    }

    private var journalID: UUID? {
        guard case .version(let id) = versionRef else { return nil }
        return store.versions.first { $0.id == id }?.journalID
    }

    var body: some View {
        if exportItem != nil {
            Button {
                showing = true
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Preview this section as it exports (the journal's typography)")
            .sheet(isPresented: $showing) { sheet }
        }
    }

    /// A one-item document for the pane preview: the journal outline's
    /// configured version of the item (heading level, options), its carrying
    /// document's typography, and the section geometry (margins, columns,
    /// line numbers) in effect at the item's position in that outline.
    static func previewDocument(for baseItem: ExportItem, content: Manuscript,
                                config: ExportConfig) -> ExportDocument {
        let carrying = config.documents.first { doc in
            doc.items.contains { $0.kind == baseItem.kind && $0.sectionID == baseItem.sectionID }
        }
        let item = carrying?.items
            .first { $0.kind == baseItem.kind && $0.sectionID == baseItem.sectionID }
            ?? baseItem
        var document = ExportDocument(
            name: item.title(in: content), fileType: .pdf, items: [item])
        document.format = (carrying ?? config.documents.first)?.format ?? ExportDocumentFormat()
        if let carrying {
            for outlineItem in carrying.items {
                if outlineItem.kind == .pageBreak {
                    document.format.marginInches =
                        outlineItem.sectionMarginInches ?? carrying.format.marginInches
                    document.format.twoColumn =
                        outlineItem.sectionTwoColumn ?? carrying.format.twoColumn
                    if let lines = outlineItem.sectionLineNumbers {
                        document.format.lineNumbers = lines
                    }
                }
                if outlineItem.id == item.id { break }
            }
        }
        return document
    }

    @ViewBuilder
    private var sheet: some View {
        if let content = store.manuscript(for: versionRef), let baseItem = exportItem {
            let config = store.exportConfig(forJournal: journalID)
            let style = store.manuscript?.journals.first { $0.id == journalID }?
                .requirements.citationStyle.cslID ?? "apa"
            let document = Self.previewDocument(for: baseItem, content: content, config: config)
            ExportPreviewSheet(
                documents: [document],
                isPresented: $showing,
                render: { doc in
                    ExportService().previewPDF(
                        document: doc, content: content,
                        citationStyleDefault: style,
                        figureURL: { store.figureURL(for: $0) },
                        chartImage: { ExportRendering.chartImage(for: $0, store: store) },
                        tableData: { ExportRendering.tableData(for: $0, store: store) })
                })
        }
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

    /// Name and file type only — page geometry lives on the Section rows,
    /// typography on the components themselves (the document is just the
    /// output file).
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

    private var itemsList: some View {
        VStack(spacing: 0) {
            if document.items.isEmpty {
                Text("Empty document — add sections below.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(10)
            }
            ForEach(Array(document.items.enumerated()), id: \.element.id) { index, item in
                itemRow(item, index: index)
                if index < document.items.count - 1 {
                    Divider().padding(.leading, 40)
                }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ExportItem, index: Int) -> some View {
        HStack(spacing: 8) {
            if index == 0 && item.kind == .pageBreak {
                // The document's first Section is pinned: it anchors the
                // format settings and can't be moved or removed.
                Image(systemName: "pin")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                    .help("The first Section is pinned — it anchors this document's format")
            } else {
                dragHandle(item)
            }
            Image(systemName: item.systemImage)
                .foregroundStyle(item.kind == .pageBreak ? Color.secondary : Color.accentColor)
                .frame(width: 20)

            if item.kind == .pageBreak {
                line
                // Geometry for the pages AFTER this boundary; values show
                // the effective setting (inheriting the document's until
                // touched).
                let effMargin = item.sectionMarginInches ?? document.format.marginInches
                let effTwoCol = item.sectionTwoColumn ?? document.format.twoColumn
                let effLines = item.sectionLineNumbers ?? document.format.lineNumbers
                HStack(spacing: 2) {
                    Text("margins: \(String(format: "%.2f", effMargin))″")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper("", value: Binding(
                        get: { item.sectionMarginInches ?? document.format.marginInches },
                        set: { value in
                            var doc = document
                            guard doc.items.indices.contains(index) else { return }
                            doc.items[index].sectionMarginInches = min(max(value, 0.25), 2.0)
                            onChange(doc)
                        }
                    ), in: 0.25...2.0, step: 0.25)
                    .labelsHidden()
                    .controlSize(.mini)
                }
                .help("Margins for the pages after this break (0.25–2″)")
                HStack(spacing: 3) {
                    Text("columns:").font(.caption).foregroundStyle(.secondary)
                    Text("1").font(.caption).foregroundStyle(effTwoCol ? .tertiary : .primary)
                    Toggle("", isOn: Binding(
                        get: { effTwoCol },
                        set: { on in
                            var doc = document
                            guard doc.items.indices.contains(index) else { return }
                            doc.items[index].sectionTwoColumn = on
                            onChange(doc)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                    Text("2").font(.caption).foregroundStyle(effTwoCol ? .primary : .tertiary)
                }
                .help("Column layout after this break (PDF and LaTeX)")
                HStack(spacing: 3) {
                    Text("line num.:").font(.caption).foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(
                        get: { effLines },
                        set: { on in
                            var doc = document
                            guard doc.items.indices.contains(index) else { return }
                            doc.items[index].sectionLineNumbers = on
                            onChange(doc)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                }
                .help("Line numbering for the pages after this break")
                line
            } else {
                // Read-only review row: the component's printed heading and
                // its formatting.  Editing happens on the component itself
                // (its toolbar, heading row, or settings button).
                Text(item.effectiveTitle(in: content))
                    .font(.callout)
                    .foregroundStyle(item.titleShown ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
                    .help(item.titleShown ? "" : "Heading hidden in the export (content still exports)")
                Spacer(minLength: 8)
                Text(formatSummary(item))
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .help("Formatting review (read-only) — edit on the component: its toolbar, heading controls, or settings gear")
            }

            if !(index == 0 && item.kind == .pageBreak) {
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

    /// One-line, right-justified formatting review in inactive grey —
    /// "+header H2 / Times / 12pt / 2× spacing" — with the component's own
    /// options up front (citation style, byline delimiter/markers).
    /// Editing happens on the component itself.
    private func formatSummary(_ item: ExportItem) -> String {
        var parts: [String] = []
        func delimiterPart(_ code: String?, defaultCode: String) {
            switch code ?? defaultCode {
            case "comma":   parts.append("\",\" delimiter")
            case "space":   parts.append("space delimiter")
            case "slash":   parts.append("\"/\" delimiter")
            case "hyphen":  parts.append("\"-\" delimiter")
            case "newline": parts.append("⏎ delimiter")
            default:        parts.append("\";\" delimiter")
            }
        }
        func bylineParts() {
            delimiterPart(item.authorDelimiter, defaultCode: "semicolon")
            switch item.affiliationMarker ?? "superscript" {
            case "superscript": parts.append("a¹ markers")
            case "none":        parts.append("no markers")
            default:            parts.append("a† markers")
            }
            if item.correspondingShown { parts.append("+corr") }
            if item.authorTitlesShown { parts.append("+cred") }
        }
        switch item.kind {
        case .references:
            switch item.citationStyle {
            case nil:                               parts.append("journal style")
            case "apa":                             parts.append("APA style")
            case "american-medical-association":    parts.append("AMA style")
            case "vancouver":                       parts.append("Vancouver style")
            case "modern-language-association":     parts.append("MLA style")
            case "chicago-author-date":             parts.append("Chicago style")
            case "harvard-cite-them-right":         parts.append("Harvard style")
            case .some(let other):                  parts.append(other)
            }
        case .authors:
            bylineParts()
        case .keywords:
            delimiterPart(item.authorDelimiter, defaultCode: "comma")
        case .titlePage:
            // Pre-split configs: the Title item renders the byline too.
            if !document.items.contains(where: { $0.kind == .authors }) {
                bylineParts()
            }
        default:
            break
        }
        switch item.kind {
        case .titlePage:
            parts.append("\(item.effectiveHeadingStyle.levelLabel) title")
        case .authors:
            break
        default:
            parts.append(item.titleShown
                         ? "+header \(item.effectiveHeadingStyle.levelLabel)"
                         : "no header")
        }
        let font = item.format?.fontFamily ?? document.format.fontFamily
        let size = Int((item.format?.fontSize ?? document.format.fontSize).rounded())
        parts.append(font.shortLabel)
        parts.append("\(size)pt")
        let spacing = item.format?.lineSpacing ?? document.format.lineSpacing
        parts.append("\(String(format: "%g", spacing))× spacing")
        return parts.joined(separator: " / ")
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
        // The pinned first Section neither moves nor accepts items above it.
        if doc.items.first?.kind == .pageBreak, from == 0 || to == 0 { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            doc.items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            onChange(doc)
        }
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
                Label("Add a Section", systemImage: "arrow.down.to.line.compact")
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
