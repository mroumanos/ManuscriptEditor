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
// WHAT IT MAY REFER TO
// ─────────────────────────────────────────────────────────────────────────────
// The core parts are blank here, and deliberately still REFERENCEABLE:
// `[[title]]`, `[[authors.names]]`, `[[authors.institutes]]` are how a venue's
// layout is expressed, and they resolve against whatever manuscript adopts the
// template.  That is the difference between a template and a form letter.
//
// See MasterContext/features/journal-templates.md §3.1.

import SwiftUI

struct TemplateSectionView: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID
    /// `StructureSection.uid`, as a string — stable across a rename, which
    /// is the whole reason sections have one.
    let sectionKey: String

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        identity(section)
                        switch section.kind {
                        case .text:      content(section)
                        case .questions: questions(section)
                        }
                        formatting(section)
                    }
                    .padding(20)
                    .frame(maxWidth: 820, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ContentUnavailableView("Section Removed", systemImage: "text.alignleft",
                                       description: Text("Pick another from the sidebar."))
            }
        }
    }

    private func subtitle(_ section: StructureSection) -> String {
        section.role == .letter
            ? "Lands in a manuscript's Letter to Editor when this journal is added."
            : "Created in every manuscript that adds this journal."
    }

    // MARK: - Identity

    @ViewBuilder
    private func identity(_ section: StructureSection) -> some View {
        HStack(spacing: 10) {
            TextField("Section title", text: Binding(
                get: { section.title },
                set: { value in edit { $0.title = value } }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            if section.role == nil {
                Picker("", selection: Binding(
                    get: { section.kind },
                    set: { value in edit { $0.kind = value } })) {
                    ForEach(SectionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Spacer()
        }
        TextField("Why this venue asks for it (optional — sent when adapting)", text: Binding(
            get: { section.note ?? "" },
            set: { value in edit { $0.note = value.isEmpty ? nil : value } }))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ section: StructureSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.role == .letter ? "LETTER" : "CONTENT")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            PlainTextEditor(text: Binding(
                get: { templates.template(templateID)?.structure.sections
                        .first { $0.id.uuidString == sectionKey }?.boilerplate ?? "" },
                set: { value in edit { $0.boilerplate = value.isEmpty ? nil : value } }))
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            tokenHelp
        }
    }

    private var tokenHelp: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("This is the section's default content: a manuscript adding this journal starts with exactly this text, and a fast-forward writes it back over the section before adapting.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Refers to the manuscript:")
                    .font(.caption2).foregroundStyle(.tertiary)
                ForEach(["[[title]]", "[[authors.names]]", "[[authors.institutes]]"], id: \.self) { token in
                    Text(token)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .textSelection(.enabled)
                }
                Spacer()
            }
        }
    }

    // MARK: - Questions

    @ViewBuilder
    private func questions(_ section: StructureSection) -> some View {
        let asked = section.questions ?? []
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
            }
            ForEach(Array(asked.enumerated()), id: \.offset) { index, question in
                questionRow(index, question, count: asked.count)
            }
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

    // MARK: - Formatting

    @ViewBuilder
    private func formatting(_ section: StructureSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("EXPORT FORMATTING")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                Spacer()
                if section.format == nil {
                    Button("Set") {
                        edit { $0.format = template?.structure.documentFormat ?? ExportDocumentFormat() }
                    }
                    .controlSize(.small)
                    .help("Only when this venue sets this section differently from the rest of the document")
                } else {
                    Button("Clear") { edit { $0.format = nil } }
                        .controlSize(.small)
                }
            }
            if section.format != nil {
                ExportFormatForm(format: Binding(
                    get: { templates.template(templateID)?.structure.sections
                            .first { $0.id.uuidString == sectionKey }?.format ?? ExportDocumentFormat() },
                    set: { value in edit { $0.format = value } }))
            } else {
                Text("Follows the document — set it only where this venue asks for something different.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Editing

    private func edit(_ mutate: @escaping (inout StructureSection) -> Void) {
        templates.edit(templateID) { template in
            guard let idx = template.structure.sections.firstIndex(where: { $0.id.uuidString == sectionKey })
            else { return }
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
