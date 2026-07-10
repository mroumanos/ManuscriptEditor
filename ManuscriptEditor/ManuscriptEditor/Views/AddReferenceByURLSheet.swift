// AddReferenceByURLSheet.swift
//
// Adds a bibliography reference from a pasted DOI or URL. The DOI/URL is stored
// on a new (editable) entry that the user can then complete. (Automatic metadata
// lookup via Crossref is a possible future enhancement.)

import SwiftUI

struct AddReferenceByURLSheet: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(\.dismiss)            private var dismiss

    /// The version whose bibliography receives the new reference.
    let versionRef: VersionRef
    /// Called with the new entry's id so the caller can select it for editing.
    var onCreated: (UUID) -> Void

    @State private var input = ""

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
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func add() {
        var entry = BibEntry.empty()
        entry.authors = []
        entry.title = ""
        if let doi = extractDOI(trimmed) {
            entry.doi = doi
            entry.type = .article
        } else {
            entry.url = trimmed
            entry.type = .website
        }
        store.addBibEntry(entry, ref: versionRef)
        if let id = store.manuscript(for: versionRef)?.bibliography.last?.id {
            onCreated(id)
        }
        dismiss()
    }

    /// Pulls a bare DOI out of a DOI string or a doi.org URL, else returns nil.
    private func extractDOI(_ s: String) -> String? {
        let lower = s.lowercased()
        if let range = lower.range(of: #"10\.\d{4,9}/[^\s]+"#, options: .regularExpression) {
            return String(s[range])
        }
        return nil
    }
}
