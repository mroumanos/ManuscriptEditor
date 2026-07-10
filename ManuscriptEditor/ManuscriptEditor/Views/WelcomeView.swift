// WelcomeView.swift
//
// Screen shown when no manuscript is open — the project manager: create a
// new manuscript, open one from a local folder or a remote repository, and
// see/delete every known manuscript (app-data AND custom-folder projects).

import SwiftUI

struct WelcomeView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Actions injected by ContentView (they own pickers/sheets).
    var onNewManuscript: () -> Void
    var onOpenLocal: () -> Void = {}
    var onOpenRemote: () -> Void = {}

    @State private var recentManuscripts: [ManuscriptSummary] = []
    /// Manuscript awaiting delete confirmation.
    @State private var pendingDelete: ManuscriptSummary?
    @State private var deleteError: String?

    var body: some View {
        HStack(spacing: 0) {
            // Left column — branding and project actions
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "doc.richtext")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text("Manuscript Editor")
                        .font(.largeTitle.weight(.semibold))
                    Text("A source-of-truth for every paper you write.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    Button(action: onNewManuscript) {
                        Label("New Manuscript", systemImage: "plus.circle.fill")
                            .frame(width: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: onOpenLocal) {
                        Label("Open (Local)…", systemImage: "folder")
                            .frame(width: 220)
                    }
                    .controlSize(.large)

                    Button(action: onOpenRemote) {
                        Label("Open (Remote)…", systemImage: "icloud.and.arrow.down")
                            .frame(width: 220)
                    }
                    .controlSize(.large)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Right column — every known manuscript, with delete
            VStack(alignment: .leading, spacing: 0) {
                Text("Manuscripts")
                    .font(.headline)
                    .padding([.horizontal, .top], 20)
                    .padding(.bottom, 12)

                if recentManuscripts.isEmpty {
                    VStack {
                        Spacer()
                        Text("No manuscripts yet")
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(recentManuscripts) { summary in
                        row(summary)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(width: 320)
        }
        .onAppear { refresh() }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let summary = pendingDelete {
                    deleteError = store.deleteManuscript(id: summary.id)
                    refresh()
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Moves the manuscript folder (\(pendingDelete?.location.path(percentEncoded: false) ?? "")) to the Trash — recoverable from there.")
        }
        .alert("Couldn't Delete", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func row(_ summary: ManuscriptSummary) -> some View {
        HStack(spacing: 8) {
            Button {
                store.open(id: summary.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(.body)
                        .lineLimit(1)
                    Text("Created \(summary.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary.location.path(percentEncoded: false))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                pendingDelete = summary
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Move this manuscript's folder to the Trash")
        }
        .contextMenu {
            Button("Open") { store.open(id: summary.id) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([summary.location])
            }
            Button("Delete…", role: .destructive) { pendingDelete = summary }
        }
    }

    private func refresh() {
        recentManuscripts = store.listSaved()
    }
}
