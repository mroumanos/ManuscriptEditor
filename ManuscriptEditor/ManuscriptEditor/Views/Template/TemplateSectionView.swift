// TemplateSectionView.swift
//
// One of the venue's own sections, edited in the template.
//
// THIS IS THE POINT OF THE TEMPLATE EDITOR
// ─────────────────────────────────────────────────────────────────────────────
// A venue's title page, the statement it requires, the letter it expects, the
// questions it asks — these ARE its requirements, and they have to be written
// somewhere.  Until now that somewhere was a manuscript: you wrote a title
// page in your paper, pressed Save, and your text became everyone's starting
// point.  Here the text belongs to the template, and a manuscript only ever
// receives it.
//
// THE SAME EDITOR AS ANY OTHER SECTION
// ─────────────────────────────────────────────────────────────────────────────
// `RichEditor` — the one a body section uses — so "/" opens the same reference
// picker and typing is the same thing you already know.  In a template it
// offers the **part tokens only** (`/title`, `/authors` → `[[title]]`,
// `[[authors.names]]`, `[[authors.institutes]]`): those resolve against
// whatever manuscript adopts the template, which is how a venue's layout is
// expressed.  A citation or a figure reference would point at one paper's
// bibliography and be wrong in every other, so the picker doesn't offer them.
//
// Export formatting is NOT here.  It lives in the template's Export pane, in
// the same outline card a manuscript uses, because a format on one screen and
// an outline on another is two places to learn and two places to fall out of
// step.
//
// The text itself is stored as the section's `boilerplate` — plain, because
// that is what a manuscript receives (`RichText(plain:)`) and what the model
// is given when adapting.  Formatting a template's boilerplate would promise
// something the other end never reads.
//
// See MasterContext/features/journal-templates.md §3.1.

import SwiftUI
import AppKit

struct TemplateSectionView: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID
    /// `StructureSection.uid`, as a string — stable across a rename, which
    /// is the whole reason sections have one.
    let sectionKey: String

    /// The prose being edited, mirrored out of the template's boilerplate.
    @State private var content = RichText()

    private var template: JournalTemplate? { templates.template(templateID) }
    /// The abstract's row is there before its entry is (see
    /// `TemplateWorkspace.editSection`); until then it edits a stand-in.
    private var isAbstract: Bool { sectionKey == TemplateWorkspace.abstractUID.uuidString }
    private var section: StructureSection? {
        template?.structure.sections.first { $0.id.uuidString == sectionKey }
            ?? (isAbstract ? StructureSection(title: "Abstract", kind: .abstract, uid: TemplateWorkspace.abstractUID) : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let section {
                TemplatePaneHeader(templateID: templateID,
                                   title: section.displayTitle,
                                   subtitle: subtitle(section))
                identity(section)
                Divider()
                switch section.type {
                case .text, .letter, .abstract: editor(section)
                case .questions:     questions(section)
                }
            } else {
                ContentUnavailableView("Section Removed", systemImage: "text.alignleft",
                                       description: Text("Pick another from the sidebar."))
            }
        }
        .onAppear { load() }
        .onChange(of: sectionKey) { _, _ in load() }
        .onChange(of: content) { _, new in
            edit { $0.boilerplate = new.plain.isEmpty ? nil : new.plain }
        }
    }

    private func subtitle(_ section: StructureSection) -> String {
        if isAbstract {
            return "The abstract as this venue wants it. A manuscript's abstract starts from this when it adds the journal, and Assist writes to it."
        }
        return section.type == .letter
            ? "Created in every manuscript that adds this journal — with a letterhead and a signature of its own."
            : "Created in every manuscript that adds this journal."
    }

    /// Opens the section's boilerplate, putting its tokens back.
    ///
    /// The file stores plain text — that is what a manuscript receives and
    /// what a model is given — so `[[title]]` arrives as characters.
    /// `PartEngine.tokenized` makes them live again, which is the difference
    /// between a template you can click through and one that reads as "pure
    /// text" the second time you open it.
    private func load() {
        let plain = section?.boilerplate ?? ""
        let attributed = PartEngine.tokenized(
            plain, attributes: [.font: EditorTypography.current.nsFont,
                                .foregroundColor: NSColor.labelColor])
        let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                                 documentAttributes: [:])
        content = RichText(plain: plain, rtf: rtf)
    }

    // MARK: - Identity

    /// One slim bar, the way a section pane's header is slim: what it is
    /// called, what shape it is, why the venue asks for it, and the gear.
    @ViewBuilder
    private func identity(_ section: StructureSection) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Every entry, the abstract's included, is called what the
                // venue calls it; the abstract's shape is fixed by its type.
                TextField("Section title", text: Binding(
                    get: { section.title },
                    set: { value in edit { $0.title = value; if isAbstract { $0.type = .abstract } } }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)

                if isAbstract {
                    Text("Abstract")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("The abstract field, under the name this venue gives it.")
                } else {
                    Picker("", selection: Binding(
                        get: { section.type },
                        set: { value in edit { $0.type = value } })) {
                        ForEach(SectionKind.addable, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Toggle("Required", isOn: Binding(
                    get: { section.required },
                    set: { value in edit { $0.required = value } }))
                    .toggleStyle(.checkbox)
                Spacer()
                typography(section)
            }
            HStack(spacing: 8) {
                TextField("Prompt — shown while the section is empty; sent when adapting", text: Binding(
                    get: { section.formatNote ?? "" },
                    set: { value in edit { $0.formatNote = value.isEmpty ? nil : value } }))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                TextField("AI context — anything else the model should know (optional, sent when adapting)", text: Binding(
                    get: { section.note ?? "" },
                    set: { value in edit { $0.note = value.isEmpty ? nil : value } }))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// The section's typography — family, size, spacing — where a section
    /// pane keeps its settings: top right.  Unset, it prints in the
    /// document's.
    private func typography(_ section: StructureSection) -> some View {
        let current = section.format ?? ExportDocumentFormat()
        func set(_ mutate: (inout ExportDocumentFormat) -> Void) {
            var format = section.format ?? ExportDocumentFormat()
            mutate(&format)
            edit { $0.format = format }
        }
        return Menu {
            Picker("Font", selection: Binding(get: { current.fontFamily }, set: { v in set { $0.fontFamily = v } })) {
                ForEach(ExportFontFamily.allCases) { Text($0.label).tag($0) }
            }
            Picker("Size", selection: Binding(get: { current.fontSize }, set: { v in set { $0.fontSize = v } })) {
                ForEach([9.0, 10.0, 10.5, 11.0, 12.0, 14.0], id: \.self) { Text("\($0.formatted()) pt").tag($0) }
            }
            Picker("Spacing", selection: Binding(get: { current.lineSpacing }, set: { v in set { $0.lineSpacing = v } })) {
                ForEach([1.0, 1.15, 1.5, 2.0], id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            if section.format != nil {
                Divider()
                Button("Use the document's") { edit { $0.format = nil } }
            }
        } label: {
            Label(section.format.map { "\($0.fontFamily.shortLabel) \($0.fontSize.formatted()) · \($0.lineSpacing.formatted())×" } ?? "Document typography",
                  systemImage: "textformat.size")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How this section prints at this venue — font family, size and line spacing. Kept with the section, so an outline that prints it twice cannot disagree.")
    }

    // MARK: - Content

    /// The venue's default content for this section, in the ordinary editor.
    @ViewBuilder
    private func editor(_ section: StructureSection) -> some View {
        RichEditor(value: $content,
                   placeholder: isAbstract
                       ? "How this venue's abstract reads — its headings, in its order — “/” inserts [[title]]…"
                       : section.type == .letter
                       ? "The letter this venue expects — “/” inserts [[title]], [[authors.names]]…"
                       : "What this section contains at this venue — “/” inserts [[title]], [[authors.names]]…",
                   templateMode: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Questions

    @ViewBuilder
    private func questions(_ section: StructureSection) -> some View {
        let asked = section.questions ?? []
        // A List, so questions drag to reorder like everything else does.
        List {
            HStack {
                Text("QUESTIONS")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    edit { $0.questions = ($0.questions ?? []) + [TemplateQuestion(prompt: "")] }
                } label: {
                    Label("Add Question", systemImage: "plus")
                }
                .controlSize(.small)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
            if asked.isEmpty {
                Text("The questions this venue asks at submission. A manuscript adding this journal gets the series already asked, each with its limit.")
                    .font(.callout).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            }
            ForEach(Array(asked.enumerated()), id: \.offset) { index, question in
                questionRow(index, question)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            }
            .onMove { from, to in
                edit { section in
                    var questions = section.questions ?? []
                    questions.move(fromOffsets: from, toOffset: to)
                    section.questions = questions
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func questionRow(_ index: Int, _ question: TemplateQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary).font(.caption)
                    .help("Drag to reorder")
                Text("\(index + 1).")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                TextField("What the venue asks", text: Binding(
                    get: { question.prompt },
                    set: { value in editQuestion(index) { $0.prompt = value } }))
                    .textFieldStyle(.roundedBorder)
                // Journals cap answers in both currencies, so the template
                // carries which one this question means.
                TextField("limit", value: Binding(
                    get: { question.wordLimit ?? 0 },
                    set: { value in editQuestion(index) { $0.wordLimit = value <= 0 ? nil : value } }
                ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Picker("", selection: Binding(
                    get: { question.limitUnit ?? .words },
                    set: { value in editQuestion(index) { $0.limitUnit = value } })) {
                    ForEach(QuestionEntry.LimitUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .labelsHidden().fixedSize()
                Button(role: .destructive) {
                    edit { $0.questions?.remove(at: index) }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            TextField("Boilerplate — what the answer starts as (optional)", text: Binding(
                get: { question.boilerplate ?? "" },
                set: { value in editQuestion(index) { $0.boilerplate = value.isEmpty ? nil : value } }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .font(.caption)
        }
        .controlSize(.small)
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Editing

    private func edit(_ mutate: @escaping (inout StructureSection) -> Void) {
        guard let uid = UUID(uuidString: sectionKey) else { return }
        templates.editSection(uid, in: templateID, mutate)
    }

    private func editQuestion(_ index: Int, _ mutate: @escaping (inout TemplateQuestion) -> Void) {
        edit { section in
            guard var questions = section.questions, questions.indices.contains(index) else { return }
            mutate(&questions[index])
            section.questions = questions
        }
    }

}
