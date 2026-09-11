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

struct TemplateSectionView: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID
    /// `StructureSection.uid`, as a string — stable across a rename, which
    /// is the whole reason sections have one.
    let sectionKey: String

    /// The prose being edited, mirrored out of the template's boilerplate.
    @State private var content = RichText()

    private var template: JournalTemplate? { templates.template(templateID) }
    private var section: StructureSection? {
        template?.structure.sections.first { $0.id.uuidString == sectionKey }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let section {
                TemplatePaneHeader(templateID: templateID,
                                   title: section.displayTitle,
                                   subtitle: subtitle(section))
                identity(section)
                Divider()
                switch section.kind {
                case .text:      editor(section)
                case .questions: questions(section)
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
        section.role == .letter
            ? "Lands in a manuscript's Letter to Editor when this journal is added."
            : "Created in every manuscript that adds this journal."
    }

    private func load() {
        content = RichText(plain: section?.boilerplate ?? "")
    }

    // MARK: - Identity

    /// One slim bar, the way a section pane's header is slim: what it is
    /// called, what shape it is, why the venue asks for it, and the gear.
    @ViewBuilder
    private func identity(_ section: StructureSection) -> some View {
        HStack(spacing: 8) {
            TextField("Section title", text: Binding(
                get: { section.title },
                set: { value in edit { $0.title = value } }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            if section.role == nil {
                Picker("", selection: Binding(
                    get: { section.kind },
                    set: { value in edit { $0.kind = value } })) {
                    ForEach(SectionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }

            TextField("Why this venue asks for it (optional — sent when adapting)", text: Binding(
                get: { section.note ?? "" },
                set: { value in edit { $0.note = value.isEmpty ? nil : value } }))
                .textFieldStyle(.roundedBorder)
                .font(.caption)

        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    // MARK: - Content

    /// The venue's default content for this section, in the ordinary editor.
    @ViewBuilder
    private func editor(_ section: StructureSection) -> some View {
        RichEditor(value: $content,
                   placeholder: section.role == .letter
                       ? "The letter this venue expects — “/” inserts [[title]], [[authors.names]]…"
                       : "What this section contains at this venue — “/” inserts [[title]], [[authors.names]]…",
                   templateMode: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Questions

    @ViewBuilder
    private func questions(_ section: StructureSection) -> some View {
        let asked = section.questions ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
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
                if asked.isEmpty {
                    Text("The questions this venue asks at submission. A manuscript adding this journal gets the series already asked, each with its limit.")
                        .font(.callout).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(asked.enumerated()), id: \.offset) { index, question in
                    questionRow(index, question, count: asked.count)
                }
            }
            .padding(16)
            .frame(maxWidth: TemplateLayout.contentWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func questionRow(_ index: Int, _ question: TemplateQuestion, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
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
                Button { moveQuestion(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(index == 0)
                Button { moveQuestion(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(index == count - 1)
                Button(role: .destructive) {
                    edit { $0.questions?.remove(at: index) }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            TextField("Starter answer (optional)", text: Binding(
                get: { question.sample ?? "" },
                set: { value in editQuestion(index) { $0.sample = value.isEmpty ? nil : value } }),
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
        templates.edit(templateID) { template in
            guard let idx = template.structure.sections
                .firstIndex(where: { $0.id.uuidString == sectionKey }) else { return }
            mutate(&template.structure.sections[idx])
        }
    }

    private func editQuestion(_ index: Int, _ mutate: @escaping (inout TemplateQuestion) -> Void) {
        edit { section in
            guard var questions = section.questions, questions.indices.contains(index) else { return }
            mutate(&questions[index])
            section.questions = questions
        }
    }

    private func moveQuestion(_ index: Int, by offset: Int) {
        edit { section in
            guard var questions = section.questions,
                  questions.indices.contains(index),
                  questions.indices.contains(index + offset) else { return }
            questions.swapAt(index, index + offset)
            section.questions = questions
        }
    }
}
