// AIContextTable.swift
//
// Overview → Settings → Context: what this manuscript is willing to tell an AI.
//
// One row per piece of context, each with a checkbox. Unticking a row is the
// privacy control — it means that content is not in the payload at all — so the
// table says plainly what each row is and roughly how big it is, and the total
// is shown, because "what am I about to send" should not require guessing.

import SwiftUI

struct AIContextTable: View {
    @Environment(ManuscriptStore.self) private var store

    @State private var editingEntry: AIContextEntry?
    @State private var confirmingRemove: AIContextEntry?

    private var entries: [AIContextEntry] { store.aiContextEntries }
    private var bundle: AIContextBundle { store.aiContextBundle() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                row(entry)
                if entry.id != entries.last?.id { Divider() }
            }
            Divider()
            addRow
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .sheet(item: $editingEntry) { entry in
            AIContextNoteEditor(entry: entry) { edited in
                store.updateContextEntry(edited)
            }
        }
        .confirmationDialog("Remove “\(confirmingRemove?.title ?? "")” from context?",
                            isPresented: Binding(get: { confirmingRemove != nil },
                                                 set: { if !$0 { confirmingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let entry = confirmingRemove { store.removeContextEntry(id: entry.id) }
                confirmingRemove = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemove = nil }
        } message: {
            Text(confirmingRemove?.kind == .file
                 ? "The copy kept with this manuscript is deleted. Your original file is untouched."
                 : "This note is deleted from the manuscript.")
        }
    }

    // MARK: rows

    private func row(_ entry: AIContextEntry) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { store.setContextEnabled($0, id: entry.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(entry.isLocked)
            .help(entry.isLocked
                  ? "Always sent — it explains how the app is structured and contains none of your content"
                  : "Unticked means this is never sent")

            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(entry.isEnabled ? .primary : .tertiary)
                    if entry.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Built in — not editable")
                    }
                }
                Text(subtitle(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if entry.isEditable {
                // Files are shown, not edited — a disabled Edit button on every
                // attachment row is noise.
                if entry.kind == .freeText {
                    Button("Edit") { editingEntry = entry }
                        .controlSize(.small)
                }
                Button {
                    confirmingRemove = entry
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Remove from context")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Says what a row actually contributes, and how much of it.
    private func subtitle(_ entry: AIContextEntry) -> String {
        switch entry.kind {
        case .appPrimer:
            return "How the app is structured — no manuscript content"
        case .manuscriptData:
            let count = store.manuscript.map {
                $0.sections.filter(\.active).count
            } ?? 0
            return "Title, authors, abstract, \(count) sections, journals and their checks"
        case .freeText:
            let words = WordCountService.count(entry.body)
            return entry.body.isEmpty ? "Empty — click Edit to write it" : "\(words) words"
        case .file:
            guard let name = entry.fileName else { return "Missing file" }
            guard let text = store.contextFileText(name) else {
                return "Attached — not readable as text, so it won't be sent"
            }
            return "\(text.count) characters"
        }
    }

    private var addRow: some View {
        HStack(spacing: 12) {
            Button {
                if let id = store.addContextNote() {
                    editingEntry = store.aiContextEntries.first { $0.id == id }
                }
            } label: {
                Label("Add Note", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.message = "Add a file as AI context. A copy is kept with the manuscript."
                if panel.runModal() == .OK, let url = panel.url {
                    _ = store.addContextFile(from: url)
                }
            } label: {
                Label("Add File…", systemImage: "paperclip")
            }
            .buttonStyle(.borderless)

            Spacer()

            // What is actually going to be sent, in one line.
            let sent = bundle
            Text(sent.isEmpty
                 ? "Nothing will be sent"
                 : "\(sent.pieces.count) included · ~\(sent.characterCount / 1000)k characters")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(sent.excludedTitles.isEmpty
                      ? "Everything ticked above is sent with each request"
                      : "Excluded: \(sent.excludedTitles.joined(separator: ", "))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Note editor

/// Edits one free-text context row.
///
/// The AI button described in the plan (compose a context note from what is
/// already typed) arrives with the intent layer and the prompt log, so that no
/// request can run before there is somewhere to record it.
private struct AIContextNoteEditor: View {
    @State var entry: AIContextEntry
    let onSave: (AIContextEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Context note").font(.headline)
                    Text("Anything the model should know that isn't in the manuscript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { onSave(entry); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            TextField("Title", text: $entry.title)
                .textFieldStyle(.roundedBorder)
            PlainTextEditor(text: $entry.body)
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .padding(18)
        .frame(width: 540, height: 380)
    }
}
