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
// How the section prints is NOT here.  It is set on the template's Export
// pane, on the row that prints it — the only place, because a section can
// print in two documents and only the row says which copy.
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

    /// What the section is called, what shape it is, whether the venue
    /// requires it, the prompt and the AI context — one per line, the way
    /// the Details boxes read.
    @ViewBuilder
    private func identity(_ section: StructureSection) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    label("Title")
                    // Every entry, the abstract's included, is called what the
                    // venue calls it; the abstract's shape is fixed by its type.
                    TextField("Section title", text: Binding(
                        get: { section.title },
                        set: { value in edit { $0.title = value; if isAbstract { $0.type = .abstract } } }))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("Type")
                    if isAbstract {
                        Text("Abstract")
                            .font(.callout)
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
                }
                GridRow {
                    label("Required")
                    Toggle("", isOn: Binding(
                        get: { section.required },
                        set: { value in edit { $0.required = value } }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                GridRow {
                    label("Prompt")
                    TextField("Shown while the section is empty; sent when adapting", text: Binding(
                        get: { section.formatNote ?? "" },
                        set: { value in edit { $0.formatNote = value.isEmpty ? nil : value } }))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("AI context")
                    TextField("Anything else the model should know (optional, sent when adapting)", text: Binding(
                        get: { section.note ?? "" },
                        set: { value in edit { $0.note = value.isEmpty ? nil : value } }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 640)
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 70, alignment: .leading)
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

