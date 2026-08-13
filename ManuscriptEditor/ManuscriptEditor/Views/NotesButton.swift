// NotesButton.swift
//
// A compact notes affordance shown in each content pane's header. It displays a
// note-count badge and opens a popover to read, add, resolve, and delete notes
// anchored to that content item within that version (Source or a cut).
//
// This is the element-level notes UI. Prose text-range anchoring
// (highlight-to-comment inside the editor) is a planned additive extension; the
// model (`Note`) already carries the version + item keys it needs.

import SwiftUI

struct NotesButton: View {
    @Environment(ManuscriptStore.self) private var store

    /// `VersionRef.id` of the pane's version.
    let versionKey: String
    /// `SidebarItem.notesKey` of the pane's content item.
    let itemKey: String

    @State private var showPopover = false
    @State private var draft = ""

    private var notes: [Note] { store.notes(versionKey: versionKey, itemKey: itemKey) }
    private var openCount: Int { notes.filter { !$0.resolved }.count }

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: notes.isEmpty ? "bubble.left" : "bubble.left.fill")
                if !notes.isEmpty {
                    Text("\(notes.count)").font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(openCount > 0 ? Color.blue : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("Notes")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) { popover }
    }

    // MARK: - Popover

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notes").font(.headline)
                Spacer()
                if !notes.isEmpty {
                    Text("\(openCount) open").font(.caption).foregroundStyle(.secondary)
                }
            }

            if notes.isEmpty {
                Text("No notes yet. Add feedback for yourself or collaborators.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes) { note in noteRow(note) }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 6) {
                TextField("Add a note…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(addNote)
                Button("Add", action: addNote)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func noteRow(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                // Signed identity: an author-tied key shows the author's name
                // with ✓; untied shows the signer name with ?; broken shows ✗.
                SignatureBadge(
                    signerName: note.author,
                    signerKey: note.authorKey,
                    signerType: note.authorType,
                    message: SigningService.noteMessage(
                        id: note.id, createdAt: note.createdAt, body: note.body),
                    signature: note.signature
                )
                .font(.caption.weight(.semibold))
                Text(note.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    var n = note; n.resolved.toggle(); store.updateNote(n)
                } label: {
                    Image(systemName: note.resolved ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(note.resolved ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(note.resolved ? "Resolved — click to reopen" : "Mark resolved")
                Button { store.deleteNote(id: note.id) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Delete note")
            }
            Text(note.body)
                .font(.callout)
                .strikethrough(note.resolved)
                .foregroundStyle(note.resolved ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func addNote() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Author = the app-wide user identity (Settings → User); the store
        // signs the note with the identity key.
        store.addNote(versionKey: versionKey, itemKey: itemKey,
                      author: SigningService.userName, body: text)
        draft = ""
    }
}
