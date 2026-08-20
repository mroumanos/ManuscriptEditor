// AddReferenceByURLSheet.swift
//
// Adds a bibliography reference from a pasted DOI or URL.  A DOI resolves
// full metadata through doi.org (issue #9); a web URL fetches the page
// title.  If the lookup fails, the entry is still created with the DOI/URL
// filled so the user can complete it by hand.

import SwiftUI

struct AddReferenceByURLSheet: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(\.dismiss)            private var dismiss

    /// The version whose bibliography receives the new reference.
    let versionRef: VersionRef
    /// Called with the new entry's id so the caller can select it for editing.
    var onCreated: (UUID) -> Void

    @State private var input = ""
    /// True while the metadata lookup runs (Add shows a spinner).
    @State private var looking = false

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Reference from URL").font(.headline)
            Text("Paste a DOI or URL. You can fill in the remaining details after adding it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("https://doi.org/…  or  https://…", text: $input)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if looking { ProgressView().controlSize(.small) }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || looking)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func add() {
        let input = trimmed
        looking = true
        Task {
            let entry = await lookedUpEntry(for: input)
            looking = false
            store.addBibEntry(entry, ref: versionRef)
            if let id = store.manuscript(for: versionRef)?.bibliography.last?.id {
                onCreated(id)
            }
            dismiss()
        }
    }

    /// Resolves metadata for the input; falls back to a bare DOI/URL entry
    /// when the lookup fails so Add always succeeds.
    private func lookedUpEntry(for input: String) async -> BibEntry {
        if let doi = ReferenceLookupService.extractDOI(input) {
            if let entry = try? await ReferenceLookupService().entry(forDOI: doi) {
                return entry
            }
            var entry = BibEntry.empty()
            entry.authors = []
            entry.doi = doi
            entry.type = .article
            return entry
        }
        if let url = ReferenceLookupService.webURL(input),
           let entry = try? await ReferenceLookupService().entry(forWebPage: url) {
            return entry
        }
        var entry = BibEntry.empty()
        entry.authors = []
        entry.url = input
        entry.type = .website
        return entry
    }
}
