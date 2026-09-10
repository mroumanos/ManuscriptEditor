// QuestionSeriesView.swift
//
// A **question series**: the prompts a journal asks at submission — "Why is
// this an important submission?", "What is novel here?" — each with its own
// answer and its own word limit.
//
// Laid out like Figures, Tables and the Bibliography: the questions listed on
// the left, the selected one edited on the right.  A question series is a
// SECTION, so it sits in the sidebar beside the prose sections, exports with a
// heading like any other, and can be recorded in a journal's structure so
// forking to that journal brings the questions along.
//
// Questions are per-cut content: journals ask different things, and the same
// question is answered differently for different journals.

import SwiftUI

struct QuestionSeriesView: View {
    @Environment(ManuscriptStore.self) private var store

    let sectionID: UUID
    var versionRef: VersionRef = .source

    @State private var selectedID: UUID?
    /// Local copy of the response being edited, so typing doesn't round-trip
    /// through the store on every keystroke.
    @State private var draftResponse = RichText()
    @State private var draftPrompt = ""
    @State private var draftLimit = ""
    @State private var draftUnit: QuestionEntry.LimitUnit = .words

    private var section: ManuscriptSection? {
        let target = store.manuscript(for: versionRef)
        if let byID = target?.sections.first(where: { $0.id == sectionID }) { return byID }
        if let type = store.manuscript?.sections.first(where: { $0.id == sectionID })?.type,
           type != .custom {
            return target?.sections.first { $0.type == type }
        }
        return nil
    }

    private var questions: [QuestionEntry] { section?.orderedQuestions ?? [] }
    private var selected: QuestionEntry? { questions.first { $0.id == selectedID } }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            detail
                .frame(minWidth: 340, maxWidth: .infinity)
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: sectionID) { _, _ in selectedID = nil; selectFirstIfNeeded() }
        // Questions can arrive AFTER this view appears — a section created
        // from a journal template brings its questions with it — and without
        // this the list showed two questions beside "No Questions Yet",
        // because the selection was made once, while there were none.
        .onChange(of: questions.map(\.id)) { _, _ in selectFirstIfNeeded() }
        .onChange(of: selectedID) { _, _ in loadDraft() }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(questions) { question in
                    row(question)
                        .tag(question.id)
                }
                .onMove { offsets, destination in
                    store.moveQuestions(sectionID: sectionID, from: offsets,
                                        to: destination, ref: versionRef)
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button {
                    if let id = store.addQuestion(sectionID: sectionID, ref: versionRef) {
                        selectedID = id
                    }
                } label: {
                    Label("Add Question", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("\(questions.count) question\(questions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func row(_ question: QuestionEntry) -> some View {
        let position = (questions.firstIndex(where: { $0.id == question.id }) ?? 0) + 1
        return HStack(alignment: .top, spacing: 8) {
            // Journals ask their questions in order and refer to them by
            // number, so the list numbers them.
            Text("\(position).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(question.prompt.isEmpty ? "New question" : question.prompt)
                    .lineLimit(2)
                    .foregroundStyle(question.prompt.isEmpty ? .tertiary : .primary)
                HStack(spacing: 6) {
                    Text(question.countLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(question.isOverLimit ? Color.red : .secondary)
                    if question.isOverLimit {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .help("This answer is past the journal's limit")
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(spacing: 0) {
                Button { move(question, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(position == 1)
                Button { move(question, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(position == questions.count)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help("Move this question up or down")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Move Up") { move(question, by: -1) }
                .disabled(position == 1)
            Button("Move Down") { move(question, by: 1) }
                .disabled(position == questions.count)
            Divider()
            Button("Delete Question", role: .destructive) {
                store.deleteQuestion(id: question.id, sectionID: sectionID, ref: versionRef)
                if selectedID == question.id { selectedID = questions.first?.id }
            }
        }
    }

    /// Shifts one question by a place.  `move(fromOffsets:toOffset:)` inserts
    /// BEFORE the destination, so moving down needs the extra step.
    private func move(_ question: QuestionEntry, by delta: Int) {
        guard let index = questions.firstIndex(where: { $0.id == question.id }) else { return }
        let target = index + delta
        guard questions.indices.contains(target) else { return }
        store.moveQuestions(sectionID: sectionID, from: IndexSet(integer: index),
                            to: delta > 0 ? target + 1 : target, ref: versionRef)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let question = selected {
            VStack(alignment: .leading, spacing: 0) {
                // Inset to the editor's text column: the gutter rule below
                // runs the full height of the pane, and fields that started
                // left of it were cut in half by it.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Question")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("What the journal asks…", text: $draftPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onChange(of: draftPrompt) { _, new in
                            var edited = question
                            edited.prompt = new
                            store.updateQuestion(edited, sectionID: sectionID, ref: versionRef)
                        }

                    HStack(spacing: 8) {
                        Text("Limit")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("none", text: $draftLimit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onChange(of: draftLimit) { _, new in
                                var edited = question
                                // Empty means the journal set no cap — a real
                                // state, not zero.
                                let digits = new.filter(\.isNumber)
                                if digits != new { draftLimit = digits }
                                edited.wordLimit = digits.isEmpty ? nil : Int(digits)
                                store.updateQuestion(edited, sectionID: sectionID, ref: versionRef)
                            }
                        // Journals ask for both, and counting the wrong one
                        // silently is worse than not counting.
                        Picker("", selection: $draftUnit) {
                            ForEach(QuestionEntry.LimitUnit.allCases, id: \.self) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: draftUnit) { _, new in
                            var edited = question
                            edited.limitUnit = new
                            store.updateQuestion(edited, sectionID: sectionID, ref: versionRef)
                        }
                        Spacer()
                        Text(question.countLabel)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(question.isOverLimit ? Color.red : .secondary)
                            .help(question.wordLimit == nil
                                  ? "No limit set for this question"
                                  : "\(question.unit.label.capitalized) used against this question's limit")
                    }
                }
                .padding(.leading, EditorLayout.leftInset)
                .padding(.trailing, 14)
                .padding(.vertical, 12)
                Divider()

                RichEditor(value: $draftResponse,
                           placeholder: "Answer…",
                           versionRef: versionRef,
                           formatItem: .section(sectionID))
                    .onChange(of: draftResponse) { _, new in
                        var edited = question
                        edited.response = new
                        store.updateQuestion(edited, sectionID: sectionID, ref: versionRef)
                    }
            }
        } else if questions.isEmpty {
            ContentUnavailableView(
                "No Questions Yet",
                systemImage: "list.bullet.rectangle",
                description: Text("Add the questions this journal asks at submission — each keeps its own answer and limit."))
        } else {
            // Questions exist but none is selected: say that, rather than
            // claiming there are none.
            ContentUnavailableView(
                "No Question Selected",
                systemImage: "list.bullet.rectangle",
                description: Text("Pick a question on the left to write its answer."))
        }
    }

    // MARK: - Drafts

    private func selectFirstIfNeeded() {
        if selectedID == nil || !questions.contains(where: { $0.id == selectedID }) {
            selectedID = questions.first?.id
        }
        loadDraft()
    }

    private func loadDraft() {
        guard let question = selected else {
            draftPrompt = ""; draftLimit = ""; draftUnit = .words; draftResponse = RichText()
            return
        }
        draftPrompt = question.prompt
        draftLimit = question.wordLimit.map(String.init) ?? ""
        draftUnit = question.unit
        draftResponse = question.response
    }
}
