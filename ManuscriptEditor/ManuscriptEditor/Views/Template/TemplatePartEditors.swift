// TemplatePartEditors.swift
//
// The four parts of a template, edited: Summary · Structure · Tests · Export.
//
// The same four in the same order a journal cut shows them, because they are
// the same four things — a venue's rules, and your copy of them.  What differs
// is who owns the edit: here it is the template, held in memory until Overview
// saves it; in a manuscript it is that manuscript's own copy.
//
// See MasterContext/features/journal-templates.md §3.2–§3.4.

import SwiftUI

// MARK: - Summary

/// The venue's instructions, distilled — **in a text box**, like everything
/// else you write in this app.
///
/// It was a bespoke editor: a bullet field, a preview toggle, its own rules
/// about blank lines.  None of that was worth learning. It is prose with a
/// convention: one requirement per line, each starting with a category
/// (`description:` / `limits:` / `components:` / `format:` / `extra:`) so
/// every journal's summary reads the same way and the limits can be found
/// without reading everything.  The convention is a habit the text has, not a
/// schema the editor enforces — grouped on display wherever it is shown.
///
/// The link to the journal's own page sits above it, because that page is
/// always the authority and this is a distillation.
struct TemplateSummaryView: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID

    /// The prose being edited, mirrored out of the template's bullets.
    @State private var content = RichText()

    private var template: JournalTemplate? { templates.template(templateID) }

    var body: some View {
        VStack(spacing: 0) {
            if let template {
                TemplatePaneHeader(
                    templateID: templateID, title: "Summary",
                    subtitle: "The journal's own instructions, distilled. The Tests are what the app can enforce of them.")

                HStack(spacing: 8) {
                    TextField("Link to the journal's author instructions", text: Binding(
                        get: { template.requirements.url },
                        set: { value in
                            templates.edit(templateID) { $0.requirements.url = value }
                        }))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    if !template.requirements.url.isEmpty,
                       let url = URL(string: template.requirements.url) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .help("Open the journal's author instructions — always the authority")
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))

                Divider()

                RichEditor(value: $content,
                           placeholder: "One requirement per line — description: / limits: / components: / format: / extra:",
                           templateMode: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { load() }
        .onChange(of: templateID) { _, _ in load() }
        .onChange(of: content) { _, new in
            // The model keeps bullets; the editor keeps the text.  Only this
            // direction is written, so normalising a line can never yank the
            // cursor out from under someone mid-sentence.
            templates.edit(templateID) { $0.requirements.text = new.plain }
        }
    }

    private func load() {
        content = RichText(plain: template?.requirements.text ?? "")
    }
}

// MARK: - Structure

/// Which sections a submission at this venue has.
///
/// Not "Content": the content lives in the sections themselves, edited from
/// the sidebar.  This is the list, and editing it adds and removes those
/// sections — the two are the same thing seen from two ends.
///
/// There is no `required` column.  Every section here is one the venue wants;
/// a section you don't want is one you delete.
struct TemplateStructureView: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID
    @Binding var selection: SidebarItem?

    @State private var newTitle = ""

    private var template: JournalTemplate? { templates.template(templateID) }
    private var sections: [StructureSection] { template?.structure.sections ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            TemplatePaneHeader(
                templateID: templateID, title: "Structure",
                subtitle: "What a submission here is made of. Adding a section here creates it in every manuscript that adds this journal.")

            // A List, so rows drag to reorder — the same gesture the sidebar
            // and the Authors list use.  Chevrons were the odd one out.
            List {
                if sections.isEmpty {
                    Text("No sections yet. Add the ones this venue expects — its title page, the statements it requires, the questions it asks.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .listRowSeparator(.hidden)
                }
                ForEach(sections) { section in
                    row(section)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
                .onMove { from, to in
                    templates.edit(templateID) { $0.structure.sections.move(fromOffsets: from, toOffset: to) }
                }

                Text("Title, authors, abstract, keywords, figures, tables, bibliography come with every manuscript, so they aren't listed here — a venue has an opinion about how they are SET (Export), never about what they say.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Divider()
            HStack(spacing: 8) {
                TextField("Add a section (e.g. \"Public Health Implications\")", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
            .frame(maxWidth: TemplateLayout.contentWidth + 40, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ section: StructureSection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.caption)
                .help("Drag to reorder")
            Image(systemName: section.kind.systemImage)
                .foregroundStyle(.tertiary)
                .font(.caption)
                .frame(width: 18)

            TextField("Section title", text: Binding(
                get: { section.title },
                set: { value in edit(section) { $0.title = value } }))
                .textFieldStyle(.roundedBorder)

            Picker("", selection: Binding(
                get: { section.kind },
                set: { value in edit(section) { $0.kind = value } })) {
                ForEach(SectionKind.addable, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("A question series arrives as the venue's submission questions when a journal is added; a letter arrives with a letterhead and a signature")

            // What this section carries, said here so the list is worth
            // reading on its own.
            Text(detail(section))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            Button("Open") { selection = .templateSection(section.id.uuidString) }
                .controlSize(.small)
            Button(role: .destructive) {
                if selection == .templateSection(section.id.uuidString) { selection = .structure }
                templates.edit(templateID) { $0.structure.sections.removeAll { $0.id == section.id } }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detail(_ section: StructureSection) -> String {
        var parts: [String] = []
        if let boilerplate = section.boilerplate, !boilerplate.isEmpty {
            let words = boilerplate.split(whereSeparator: \.isWhitespace).count
            parts.append("\(words) words")
        }
        if let questions = section.questions, !questions.isEmpty {
            parts.append("\(questions.count) question\(questions.count == 1 ? "" : "s")")
        }
        // Formats are not mentioned: they are edited in Export now, and a
        // row that names something it can't change only sends people looking.
        return parts.joined(separator: " · ")
    }

    private func edit(_ section: StructureSection,
                      _ mutate: @escaping (inout StructureSection) -> Void) {
        templates.edit(templateID) { template in
            guard let idx = template.structure.sections.firstIndex(where: { $0.id == section.id })
            else { return }
            mutate(&template.structure.sections[idx])
        }
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !sections.contains(where: { $0.key == title.lowercased() }) else { return }
        templates.edit(templateID) { $0.structure.sections.append(StructureSection(title: title)) }
        newTitle = ""
    }
}

// MARK: - Tests

/// One test per requirement, written against the venue's rules rather than
/// against any one manuscript.
///
/// No pass rate here, deliberately: a template has no content to measure, and
/// a percentage with nothing behind it would be a number people trusted.  The
/// rate belongs to a cut, where the sidebar carries it — "Tests (86%)".
struct TemplateTestsView: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID

    private var template: JournalTemplate? { templates.template(templateID) }

    var body: some View {
        VStack(spacing: 0) {
            TemplatePaneHeader(
                templateID: templateID, title: "Tests",
                subtitle: detail)

            if template != nil {
                CheckRulesList(
                    rules: Binding(
                        get: { templates.template(templateID)?.checks ?? [] },
                        set: { value in templates.edit(templateID) { $0.checks = value } }),
                    sectionTitles: sectionTitles,
                    footnote: "Written into this template — every manuscript that adopts it starts with these.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detail: String {
        guard let template, !template.checks.isEmpty else {
            return "Every requirement that can be checked. Sections the venue requires should each have their own EXISTS test, so a missing one names itself."
        }
        let manual = template.checks.filter(\.isManual).count
        return "\(template.checks.count) test\(template.checks.count == 1 ? "" : "s") · "
            + "\(template.checks.count - manual) automatic, \(manual) manual"
    }

    /// The venue's own sections — what a condition can be scoped to here.
    /// A template has no manuscript behind it, so its structure is the list.
    private var sectionTitles: [String] {
        (template?.structure.sections ?? []).map(\.title)
    }
}

// MARK: - Export

/// How this venue sets a submission: **the same outline editor a manuscript
/// has**, over the template's own sections.
///
/// The export options used to be scattered — a format popover on each section,
/// a list of fixed parts here — which meant learning two places and keeping
/// them in step by hand.  One place: the outline. `ExportDocumentCard` is
/// literally the card the Export pane shows for a manuscript, given the
/// template's sections instead of a paper's, so a venue's typography is
/// arranged exactly where anyone already knows how to arrange it.
///
/// What a journal ADOPTS when it is added still comes from the structure
/// (`coreFormats`, `documentFormat`, each section's `format`); those are
/// derived from this outline on every change — see
/// `TemplateWorkspace.setExport`.
struct TemplateExportView: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID

    /// The outline being edited.  Held in state, not recomputed per access:
    /// a template that never configured one gets the standard outline
    /// DERIVED, and a derivation mints fresh item ids every time — so the
    /// settings popover bound "by id" edited an item that no longer existed
    /// by the next render, and the row's summary never moved.  (The
    /// manuscript's Export pane learned the same lesson first.)
    @State private var config = ExportConfig(documents: [])

    private var template: JournalTemplate? { templates.template(templateID) }

    /// The template's sections as a manuscript, so the outline can name them.
    private var asManuscript: Manuscript? {
        template.map(TemplateWorkspace.asManuscript)
    }

    /// What the state is seeded from: the stored outline, or the standard one
    /// derived from the template's sections — repaired either way.
    private func seed() -> ExportConfig {
        guard let template else { return ExportConfig(documents: []) }
        if let export = template.export, !export.documents.isEmpty {
            return TemplateWorkspace.repaired(export, for: template)
        }
        return TemplateWorkspace.standardOutline(for: template)
    }

    var body: some View {
        VStack(spacing: 0) {
            TemplatePaneHeader(
                templateID: templateID, title: "Export",
                subtitle: "The documents a submission here is, what goes in each, and how every part is set. A journal cut from this template adopts it.")

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(config.documents) { document in
                        ExportDocumentCard(
                            document: document,
                            content: asManuscript,
                            onChange: { replace($0) },
                            onDelete: { remove(document.id) })
                    }

                    HStack(spacing: 12) {
                        Button {
                            var edited = config
                            edited.documents.append(ExportDocument(name: "New Document", items: []))
                            commit(edited)
                        } label: {
                            Label("Add Document", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        if template?.export == nil {
                            Text("Not configured — this is the standard outline, derived from the sections above. Change anything and it becomes this template's.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }

                    Text("Page geometry sits on the Section rows, typography on each component — the same places a manuscript keeps them. A journal added from this template takes all of it, and can then change its own copy freely.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: TemplateLayout.exportWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { config = seed() }
        .onChange(of: templateID) { _, _ in config = seed() }
        // Sections added or removed in Structure appear here at once; an
        // edit made HERE round-trips through the draft unchanged.
        .onChange(of: template?.structure.sections.map(\.uid)) { _, _ in config = seed() }
        .onChange(of: template?.export) { _, new in
            if let new, new != config { config = seed() }
        }
    }

    /// Writes the outline into the draft and keeps the state in step.
    private func commit(_ edited: ExportConfig) {
        config = edited
        templates.setExport(edited, for: templateID)
    }

    private func replace(_ document: ExportDocument) {
        var edited = config
        guard let index = edited.documents.firstIndex(where: { $0.id == document.id }) else { return }
        edited.documents[index] = document
        commit(edited)
    }

    private func remove(_ id: UUID) {
        var edited = config
        edited.documents.removeAll { $0.id == id }
        commit(edited)
    }
}
