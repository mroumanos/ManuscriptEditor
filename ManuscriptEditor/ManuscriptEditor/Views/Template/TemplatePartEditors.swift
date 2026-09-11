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

/// The venue's instructions, distilled — one requirement per line, in the
/// standard vocabulary (`description:` / `limits:` / `components:` /
/// `format:` / `extra:`).  The link at the top is always the authority; this
/// is a distillation and says so.
struct TemplateSummaryView: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID
    @State private var previewing = false

    private var template: JournalTemplate? { templates.template(templateID) }

    var body: some View {
        VStack(spacing: 0) {
            TemplatePaneHeader(
                templateID: templateID, title: "Summary",
                subtitle: "The journal's own instructions, distilled. The Tests are what the app can enforce of them.")

            if let template {
                ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Link to the journal's author instructions", text: Binding(
                            get: { template.requirements.url },
                            set: { value in
                                templates.edit(templateID) { $0.requirements.url = value }
                            }))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        if let url = URL(string: template.requirements.url),
                           !template.requirements.url.isEmpty {
                            Link(destination: url) {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .help(template.requirements.url)
                        }
                        Picker("", selection: $previewing) {
                            Text("Edit").tag(false)
                            Text("Preview").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                        .labelsHidden()
                    }

                    if previewing {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(SourceRequirements.grouped(template.requirements.bullets)
                                    .enumerated()), id: \.offset) { _, group in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text((group.category ?? "other").uppercased())
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                        ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text("•").foregroundStyle(.tertiary)
                                                Text(item)
                                                    .textSelection(.enabled)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                }
                                if template.requirements.bullets.isEmpty {
                                    Text("No summary yet — switch to Edit and paste this journal's instructions, one per line.")
                                        .font(.callout).foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        }
                        .frame(height: 360)
                        .background(Color(NSColor.textBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    } else {
                        // A real height: an NSScrollView with no height of its
                        // own reports an unbounded ideal, and an unbounded
                        // ideal in a split view's detail is how the sidebar
                        // gets squeezed off the window.
                        PlainTextEditor(text: Binding(
                            get: { template.requirements.text },
                            set: { value in
                                templates.edit(templateID) { $0.requirements.text = value }
                            }))
                            .frame(height: 360)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    }

                    Text("One requirement per line. Start each with a category — description: / limits: / components: / format: / extra: — so every journal's summary reads the same way and the limits can be found without reading the prose. Leading bullet characters are stripped, so pasting from the journal's page works.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: TemplateLayout.contentWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if sections.isEmpty {
                        Text("No sections yet. Add the ones this venue expects — its title page, the statements it requires, the questions it asks.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                    }
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        row(section, at: index)
                    }

                    Text("Title, authors, abstract, keywords, figures, tables, bibliography come with every manuscript, so they aren't listed here — a venue has an opinion about how they are SET (Export), never about what they say.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .padding(20)
                .frame(maxWidth: TemplateLayout.contentWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

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

    private func row(_ section: StructureSection, at index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: section.role == .letter ? "envelope"
                  : section.kind == .questions ? "list.bullet.rectangle" : "text.alignleft")
                .foregroundStyle(.tertiary)
                .font(.caption)
                .frame(width: 18)

            TextField("Section title", text: Binding(
                get: { section.title },
                set: { value in edit(section) { $0.title = value } }))
                .textFieldStyle(.roundedBorder)

            if section.role == nil {
                Picker("", selection: Binding(
                    get: { section.kind },
                    set: { value in edit(section) { $0.kind = value } })) {
                    ForEach(SectionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("A question series arrives as the venue's submission questions when a journal is added")
            } else {
                Text("cover letter")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
                    .help("Lands in the manuscript's Letter to Editor, not in a body section")
            }

            // What this section carries, said here so the list is worth
            // reading on its own.
            Text(detail(section))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            Button("Open") { selection = .templateSection(section.id.uuidString) }
                .controlSize(.small)
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0)
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == sections.count - 1)
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

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard sections.indices.contains(target) else { return }
        templates.edit(templateID) { $0.structure.sections.swapAt(index, target) }
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
        (template?.structure.sections ?? []).filter { $0.role == nil }.map(\.title)
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

    private var template: JournalTemplate? { templates.template(templateID) }

    /// The template's sections as a manuscript, so the outline can name them.
    ///
    /// Ids are the sections' own (`StructureSection.uid`), which is what makes
    /// an outline item survive a rename here exactly as it does in a paper.
    private var asManuscript: Manuscript? {
        guard let template else { return nil }
        var made = Manuscript.new()
        made.title = template.displayName
        made.sections = template.structure.sections.enumerated().map { index, section in
            ManuscriptSection(id: section.uid, type: .custom, title: section.displayTitle,
                              content: RichText(plain: section.boilerplate ?? ""), order: index)
        }
        return made
    }

    /// The outline as it stands, or the standard one derived from the
    /// template's own sections when it has never been configured.
    private var config: ExportConfig {
        if let export = template?.export, !export.documents.isEmpty { return export }
        guard let content = asManuscript else { return ExportConfig(documents: []) }
        return ExportConfig.standard(content: content, journal: nil)
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
                            templates.setExport(edited, for: templateID)
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
    }

    private func replace(_ document: ExportDocument) {
        var edited = config
        guard let index = edited.documents.firstIndex(where: { $0.id == document.id }) else { return }
        edited.documents[index] = document
        templates.setExport(edited, for: templateID)
    }

    private func remove(_ id: UUID) {
        var edited = config
        edited.documents.removeAll { $0.id == id }
        templates.setExport(edited, for: templateID)
    }
}

// MARK: - ExportFormatForm

/// The typography controls, over a plain binding.
///
/// Deliberately not `ComponentSettingsButton`: that one edits a manuscript's
/// export config through the store, and a template has no manuscript behind
/// it.  Same vocabulary, no owner.
struct ExportFormatForm: View {
    @Binding var format: ExportDocumentFormat
    /// Page geometry belongs to a document, not to a component inside one.
    var showsPage: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $format.fontFamily) {
                    ForEach(ExportFontFamily.allCases) { family in
                        Text(family.shortLabel).tag(family)
                    }
                }
                .labelsHidden().controlSize(.small).fixedSize()

                HStack(spacing: 1) {
                    TextField("", value: Binding(
                        get: { Int(format.fontSize.rounded()) },
                        set: { format.fontSize = Double(min(max($0, 6), 99)) }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder).controlSize(.mini)
                    .multilineTextAlignment(.trailing).frame(width: 30)
                    Stepper("", value: Binding(
                        get: { Int(format.fontSize.rounded()) },
                        set: { format.fontSize = Double(min(max($0, 6), 99)) }
                    ), in: 6...99)
                    .labelsHidden().controlSize(.mini)
                }
                .help("Font size (pt)")

                Picker("", selection: $format.lineSpacing) {
                    Text("1×").tag(1.0)
                    Text("1.15").tag(1.15)
                    Text("1.5").tag(1.5)
                    Text("2×").tag(2.0)
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .help("Line spacing")

                if showsPage {
                    Text("margins").font(.caption2).foregroundStyle(.secondary)
                    TextField("", value: $format.marginInches, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).controlSize(.mini)
                        .multilineTextAlignment(.trailing).frame(width: 38)
                        .help("Page margins, in inches")
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Toggle("Line numbers", isOn: $format.lineNumbers)
                Toggle("Page numbers", isOn: $format.pageNumbers)
                if showsPage {
                    Toggle("Two columns", isOn: $format.twoColumn)
                }
                Spacer()
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
    }
}

// MARK: - Safe indexing

extension Array {
    /// Index that returns nil rather than trapping — a binding into an array
    /// that another edit may have shortened.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
