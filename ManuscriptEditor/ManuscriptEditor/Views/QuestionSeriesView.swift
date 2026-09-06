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
        .padding(.vertical, 2)
        .contextMenu {
            Button("Delete Question", role: .destructive) {
                store.deleteQuestion(id: question.id, sectionID: sectionID, ref: versionRef)
                if selectedID == question.id { selectedID = questions.first?.id }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let question = selected {
            VStack(alignment: .leading, spacing: 0) {
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
                        Text("Word limit")
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
                        Spacer()
                        Text(question.countLabel)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(question.isOverLimit ? Color.red : .secondary)
                            .help(question.wordLimit == nil
                                  ? "No limit set for this question"
                                  : "Words used against this question's limit")
                    }
                }
                .padding(14)
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
        } else {
            ContentUnavailableView(
                "No Questions Yet",
                systemImage: "list.bullet.rectangle",
                description: Text("Add the questions this journal asks at submission — each keeps its own answer and word limit."))
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
            draftPrompt = ""; draftLimit = ""; draftResponse = RichText()
            return
        }
        draftPrompt = question.prompt
        draftLimit = question.wordLimit.map(String.init) ?? ""
        draftResponse = question.response
    }
}
