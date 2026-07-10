// GlobalViewsView.swift
//
// Global panel for managing "View" templates — named configurations that
// describe how manuscript content is laid out and exported.
//
// WHAT A VIEW IS
// ─────────────────────────────────────────────────────────────────────────────
// A View has one or more Documents.  Each Document holds a list of manuscript
// sections in the order they appear in the output, along with per-section and
// per-document settings:
//
//   Document settings:  name, line numbering, export format (DOCX / PDF / …)
//   Section settings:   which section to include, custom heading override,
//                       font style, word limit, line spacing
//
// This allows a "Nature Submission" view to have:
//   Document 1 "Main Text": Abstract (250w limit), Introduction, Methods …
//   Document 2 "Figures":   Figure 1, Figure 2, … (submitted separately)
//
// HOW VIEWS ARE USED
// ─────────────────────────────────────────────────────────────────────────────
// A manuscript's active view is set in Manuscript → Settings.
// The Checks panel uses the active view's word limits to flag over-limit sections.
// Export (Phase 2) will render content through this template to produce files.

import SwiftUI

// MARK: - GlobalViewsView

/// List of view configs on the left; document + section editor on the right.
struct GlobalViewsView: View {
    @Environment(AppStore.self) private var appStore

    @State private var selectedID: UUID?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            viewList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            detail
        }
        .sheet(isPresented: $showAddSheet) {
            AddViewSheet(isPresented: $showAddSheet) { config in
                appStore.addViewConfig(config)
                selectedID = config.id
            }
        }
    }

    // MARK: - Left: view list

    private var viewList: some View {
        VStack(spacing: 0) {
            if appStore.views.isEmpty {
                emptyState
            } else {
                List(selection: $selectedID) {
                    ForEach(appStore.views) { config in
                        viewRow(config).tag(config.id)
                    }
                    .onDelete { appStore.deleteViewConfigs(at: $0) }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add View", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(10)
                Spacer()
                Text("\(appStore.views.count) view\(appStore.views.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No views configured")
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            Text("Views define how content is arranged\nand exported. Add one to get started.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.quaternary)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func viewRow(_ config: ViewConfig) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(config.name.isEmpty ? "(unnamed view)" : config.name)
                .fontWeight(.medium).lineLimit(1)
            Text("\(config.documents.count) document\(config.documents.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Right: detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID,
           let config = appStore.views.first(where: { $0.id == id }) {
            ViewConfigDetail(config: config)
        } else {
            ContentUnavailableView(
                "No View Selected",
                systemImage: "rectangle.split.3x1",
                description: Text("Add a view or select one to configure its documents and sections.")
            )
        }
    }
}

// MARK: - ViewConfigDetail

/// Editor for one ViewConfig: rename the view, manage documents, and edit section settings.
struct ViewConfigDetail: View {
    @Environment(AppStore.self) private var appStore
    let config: ViewConfig
    @State private var draft: ViewConfig
    @State private var selectedDocID: UUID?

    init(config: ViewConfig) {
        self.config = config
        _draft = State(initialValue: config)
        _selectedDocID = State(initialValue: config.documents.first?.id)
    }

    var body: some View {
        VSplitView {
            topPane
                .frame(minHeight: 180)
            bottomPane
                .frame(minHeight: 200)
        }
        .onChange(of: config.id) { _, _ in
            draft = config
            selectedDocID = config.documents.first?.id
        }
    }

    // MARK: - Top: view name + document list

    private var topPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("View Name") {
                    TextField("Name", text: $draft.name)
                        .onChange(of: draft.name) { _, _ in appStore.updateViewConfig(draft) }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 80)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                // Document list
                VStack(spacing: 0) {
                    List(selection: $selectedDocID) {
                        ForEach(draft.documents.sorted(by: { $0.order < $1.order })) { doc in
                            Text(doc.name.isEmpty ? "(unnamed)" : doc.name).tag(doc.id)
                        }
                        .onDelete { offsets in
                            draft.documents.remove(atOffsets: offsets)
                            renumberDocuments()
                            appStore.updateViewConfig(draft)
                        }
                        .onMove { from, to in
                            draft.documents.move(fromOffsets: from, toOffset: to)
                            renumberDocuments()
                            appStore.updateViewConfig(draft)
                        }
                    }
                    .listStyle(.plain)
                    Divider()
                    Button {
                        let doc = ViewDocument(
                            id: UUID(), name: "Document \(draft.documents.count + 1)",
                            sections: [], lineNumbering: false, exportFormat: .docx,
                            order: draft.documents.count
                        )
                        draft.documents.append(doc)
                        selectedDocID = doc.id
                        appStore.updateViewConfig(draft)
                    } label: {
                        Label("Add Document", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                }
                .frame(width: 180)

                Divider()

                // Document settings
                if let docID = selectedDocID,
                   let docIdx = draft.documents.firstIndex(where: { $0.id == docID }) {
                    DocumentSettingsForm(
                        document: $draft.documents[docIdx],
                        onChange: { appStore.updateViewConfig(draft) }
                    )
                } else {
                    ContentUnavailableView("Select a Document", systemImage: "doc")
                }
            }
        }
    }

    // MARK: - Bottom: sections for selected document

    @ViewBuilder
    private var bottomPane: some View {
        if let docID = selectedDocID,
           let docIdx = draft.documents.firstIndex(where: { $0.id == docID }) {
            SectionConfigList(
                document: $draft.documents[docIdx],
                onChange: { appStore.updateViewConfig(draft) }
            )
        } else {
            ContentUnavailableView("Select a document to edit its sections", systemImage: "list.bullet")
        }
    }

    private func renumberDocuments() {
        for i in draft.documents.indices { draft.documents[i].order = i }
    }
}

// MARK: - DocumentSettingsForm

/// Form for one document's name, line numbering, and export format.
struct DocumentSettingsForm: View {
    @Binding var document: ViewDocument
    let onChange: () -> Void

    var body: some View {
        Form {
            Section("Document") {
                TextField("Name", text: $document.name)
                Toggle("Line numbering", isOn: $document.lineNumbering)
                Picker("Export format", selection: $document.exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: document.name)          { _, _ in onChange() }
        .onChange(of: document.lineNumbering) { _, _ in onChange() }
        .onChange(of: document.exportFormat)  { _, _ in onChange() }
    }
}

// MARK: - SectionConfigList

/// List of section configs for one document, with per-section settings.
struct SectionConfigList: View {
    @Binding var document: ViewDocument
    let onChange: () -> Void

    @State private var selectedSectionID: UUID?

    private var sorted: [ViewSectionConfig] {
        document.sections.sorted { $0.order < $1.order }
    }

    var body: some View {
        HSplitView {
            // Section list with add/delete
            VStack(spacing: 0) {
                List(selection: $selectedSectionID) {
                    ForEach(sorted) { sec in
                        Text(sec.customTitle ?? sectionLabel(sec)).tag(sec.id)
                    }
                    .onDelete { offsets in
                        // Map filtered offsets back to indices in document.sections
                        let ids = offsets.map { sorted[$0].id }
                        document.sections.removeAll { ids.contains($0.id) }
                        renumberSections()
                        onChange()
                    }
                    .onMove { from, to in
                        var s = sorted
                        s.move(fromOffsets: from, toOffset: to)
                        document.sections = s
                        renumberSections()
                        onChange()
                    }
                }
                .listStyle(.plain)
                Divider()
                Button {
                    addSection()
                } label: {
                    Label("Add Section", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 160, maxWidth: 200)

            // Section settings
            if let id = selectedSectionID,
               let idx = document.sections.firstIndex(where: { $0.id == id }) {
                SectionConfigForm(
                    section: $document.sections[idx],
                    onChange: onChange
                )
            } else {
                ContentUnavailableView("Select a Section", systemImage: "text.alignleft")
            }
        }
    }

    private func sectionLabel(_ sec: ViewSectionConfig) -> String {
        switch sec.sectionRef {
        case .byType(let t): return t.rawValue
        case .byID:          return "Custom Section"
        }
    }

    private func addSection() {
        let sec = ViewSectionConfig(
            id: UUID(),
            sectionRef: .byType(.introduction),
            customTitle: nil,
            fontStyle: "Serif",
            wordLimit: nil,
            lineSpacing: 1.5,
            order: document.sections.count
        )
        document.sections.append(sec)
        selectedSectionID = sec.id
        onChange()
    }

    private func renumberSections() {
        let order = document.sections.sorted { $0.order < $1.order }
        for (i, sec) in order.enumerated() {
            if let idx = document.sections.firstIndex(where: { $0.id == sec.id }) {
                document.sections[idx].order = i
            }
        }
    }
}

// MARK: - SectionConfigForm

/// Form for one section's config: type, title override, font, word limit, spacing.
struct SectionConfigForm: View {
    @Binding var section: ViewSectionConfig
    let onChange: () -> Void

    var body: some View {
        Form {
            Section("Section") {
                Picker("Type", selection: Binding(
                    get: {
                        if case .byType(let t) = section.sectionRef { return t }
                        return SectionType.custom
                    },
                    set: { section.sectionRef = .byType($0) }
                )) {
                    ForEach(SectionType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                TextField("Custom heading (optional)", text: Binding(
                    get: { section.customTitle ?? "" },
                    set: { section.customTitle = $0.isEmpty ? nil : $0 }
                ))
            }

            Section("Formatting") {
                Picker("Font style", selection: $section.fontStyle) {
                    Text("Serif").tag("Serif")
                    Text("Sans-serif").tag("Sans")
                    Text("Monospace").tag("Mono")
                }
                LabeledContent("Word limit") {
                    TextField("No limit", value: $section.wordLimit, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                LabeledContent("Line spacing") {
                    Stepper(
                        "\(section.lineSpacing, specifier: "%.1f")×",
                        value: $section.lineSpacing,
                        in: 1.0...3.0, step: 0.25
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: section.sectionRef)  { _, _ in onChange() }
        .onChange(of: section.customTitle) { _, _ in onChange() }
        .onChange(of: section.fontStyle)   { _, _ in onChange() }
        .onChange(of: section.wordLimit)   { _, _ in onChange() }
        .onChange(of: section.lineSpacing) { _, _ in onChange() }
    }
}

// MARK: - AddViewSheet

/// Sheet for naming and creating a new view config.
struct AddViewSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (ViewConfig) -> Void

    @State private var name = ""
    @State private var startWithDefault = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New View").font(.headline)

            TextField("View name (e.g. Nature Submission)", text: $name)
                .textFieldStyle(.roundedBorder)

            Toggle("Start with default IMRAD document", isOn: $startWithDefault)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    var config = ViewConfig.empty(name: name.isEmpty ? "New View" : name)
                    if !startWithDefault { config.documents = [] }
                    onAdd(config)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
