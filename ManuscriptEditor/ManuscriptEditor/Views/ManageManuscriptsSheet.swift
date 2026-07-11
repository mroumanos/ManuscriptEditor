// ManageManuscriptsSheet.swift
//
// File → Manage Manuscripts…: curate the known-projects list.
//
//   ADD     — register an existing project folder (with a manuscript.json)
//             so it shows on the Welcome screen; nothing is copied or opened.
//   EDIT    — rename a project's title in place (writes its manuscript.json).
//   REMOVE  — drop an entry from the list; the files stay untouched.
//   DELETE  — move the whole project folder to the Trash (recoverable).

import SwiftUI
import AppKit

struct ManageManuscriptsSheet: View {
    @Environment(ManuscriptStore.self) private var store
    @Binding var isPresented: Bool

    @State private var summaries: [ManuscriptSummary] = []
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var confirmDeleteID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage Manuscripts").font(.headline)
            Text("Projects known to this app. Removing an entry keeps its files; Delete moves the whole folder to the Trash.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(summaries) { summary in
                    row(summary)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 260)

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack {
                Button {
                    addExisting()
                } label: {
                    Label("Add Existing…", systemImage: "plus")
                }
                .help("Register a project folder that holds a manuscript.json")
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 460)
        .onAppear { refresh() }
        .confirmationDialog(
            "Delete this manuscript?",
            isPresented: Binding(get: { confirmDeleteID != nil },
                                 set: { if !$0 { confirmDeleteID = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let id = confirmDeleteID {
                    errorMessage = store.deleteManuscript(id: id)
                    refresh()
                }
                confirmDeleteID = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteID = nil }
        } message: {
            Text("The project folder moves to the Trash (recoverable) and leaves this list.")
        }
    }

    @ViewBuilder
    private func row(_ summary: ManuscriptSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                if renamingID == summary.id {
                    TextField("Title", text: $renameDraft, onCommit: { commitRename(summary) })
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                } else {
                    Text(summary.title.isEmpty ? "Untitled" : summary.title)
                        .fontWeight(.medium)
                }
                Text(summary.location.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text("Created \(summary.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if renamingID == summary.id {
                Button("Save") { commitRename(summary) }
                    .controlSize(.small)
            } else {
                Button {
                    renameDraft = summary.title
                    renamingID = summary.id
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rename this manuscript's title")
            }

            Button {
                store.forgetManuscript(id: summary.id)
                refresh()
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Remove from this list — files stay on disk")

            Button {
                confirmDeleteID = summary.id
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Move the project folder to the Trash")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([summary.location])
            }
        }
    }

    private func commitRename(_ summary: ManuscriptSummary) {
        errorMessage = store.renameManuscript(id: summary.id, to: renameDraft)
        renamingID = nil
        refresh()
    }

    private func addExisting() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a project folder that contains a manuscript.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        errorMessage = store.addKnown(folder: url)
        refresh()
    }

    private func refresh() {
        summaries = store.listSaved().sorted { $0.updatedAt > $1.updatedAt }
    }
}
