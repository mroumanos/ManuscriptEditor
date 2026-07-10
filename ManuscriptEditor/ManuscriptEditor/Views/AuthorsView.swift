// AuthorsView.swift
//
// Two-pane view for managing the manuscript's author list.
//
// Layout (HSplitView):
//   LEFT   — scrollable author list with drag-to-reorder and "Add Author" button
//   RIGHT  — `AuthorEditor` form for the selected author, or a placeholder
//
// Authors can be reordered by dragging rows up/down.  The underlying `order` field
// is automatically re-numbered by the store after every move.
// Rows can be deleted by swiping left on them (standard macOS List gesture).

import SwiftUI

/// The author-management view: list on the left, editor form on the right.
struct AuthorsView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    /// UUID of the currently selected author, used to highlight the list row and
    /// show the matching `AuthorEditor` on the right.
    @State private var selectedID: UUID?

    /// Authors sorted by their `order` field (ascending = display order).
    private var authors: [Author] {
        (store.manuscript(for: versionRef)?.authors ?? []).sorted { $0.order < $1.order }
    }

    var body: some View {
        if authors.isEmpty {
            emptyState
        } else {
            HSplitView {
                // MARK: Left — author list
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(authors) { author in
                            authorRow(author).tag(author.id)
                        }
                        .onMove { store.moveAuthors(from: $0, to: $1, ref: versionRef) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.windowBackgroundColor))
                    .onAppear { autoSelect() }
                    .onChange(of: authors.map(\.id)) { _, _ in autoSelect() }

                    Divider()

                    HStack {
                        Button {
                            store.addAuthor(ref: versionRef)
                            selectedID = store.manuscript(for: versionRef)?.authors.last?.id
                        } label: {
                            Label("Add Author", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .padding(10)
                        Spacer()
                        Text("\(authors.count) author\(authors.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 10)
                    }
                    .background(Color(NSColor.windowBackgroundColor))
                }
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))

                // MARK: Right — author editor
                if let id = selectedID,
                   let author = authors.first(where: { $0.id == id }) {
                    AuthorEditor(author: author) { updated in
                        store.updateAuthor(updated, ref: versionRef)
                    }
                } else {
                    Color.clear
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No Authors Yet")
                .font(.title3.weight(.semibold))
            Text("Add authors to get started.")
                .foregroundStyle(.secondary)
            Button {
                store.addAuthor(ref: versionRef)
            } label: {
                Label("Add Author", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func autoSelect() {
        if selectedID == nil || !authors.contains(where: { $0.id == selectedID }) {
            selectedID = authors.first?.id
        }
    }

    private func authorRow(_ author: Author) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(author.displayName.isEmpty ? "(unnamed)" : author.displayName)
                        .fontWeight(author.isCorresponding ? .semibold : .regular)
                    if author.isCorresponding {
                        Image(systemName: "envelope.badge.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                let affiliations = author.affiliations.filter { !$0.isEmpty }
                if !affiliations.isEmpty {
                    Text(affiliations.first!)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                guard let idx = authors.firstIndex(where: { $0.id == author.id }) else { return }
                store.deleteAuthors(at: IndexSet([idx]), ref: versionRef)
                if selectedID == author.id {
                    selectedID = authors.first(where: { $0.id != author.id })?.id
                }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove author")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - AuthorEditor

/// A form for editing all fields of one author.
///
/// `draft` is a local copy of the author.  Every field change immediately calls
/// `onChange` to push the update to the store — the same auto-save pattern used
/// throughout the app.
struct AuthorEditor: View {
    /// The author value as last saved in the store.
    let author: Author
    /// Callback invoked whenever any field changes.
    let onChange: (Author) -> Void

    /// Mutable working copy of the author.
    @State private var draft: Author

    init(author: Author, onChange: @escaping (Author) -> Void) {
        self.author = author
        self.onChange = onChange
        _draft = State(initialValue: author)
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Name") {
                    TextField("First name", text: $draft.firstName)
                    TextField("Last name",  text: $draft.lastName)
                }

                Section("Contact") {
                    TextField("Email address", text: $draft.email)
                    HStack(spacing: 8) {
                        TextField("ORCID", text: $draft.orcid)
                        // Once an iD is entered, link straight to the ORCID record.
                        if !draft.orcid.trimmingCharacters(in: .whitespaces).isEmpty,
                           let url = URL(string: "https://orcid.org/\(draft.orcid.trimmingCharacters(in: .whitespaces))") {
                            Link(destination: url) {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .help("Open on orcid.org")
                        }
                    }
                }

                Section("Signatures") {
                    // Public signing keys tied to this author (0 to many).
                    // Activity signed by a tied key displays this author's
                    // name with a verified ✓ (see SignatureBadge).
                    let keys = draft.publicKeys ?? []
                    if keys.isEmpty {
                        Text("No signing keys tied — this author's edits show under the signer's system name with a ?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(keys, id: \.self) { key in
                        HStack {
                            Image(systemName: "signature")
                                .foregroundStyle(.secondary)
                            Text(key)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if key == SigningService.publicKeyBase64 {
                                Text("this Mac")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                draft.publicKeys = keys.filter { $0 != key }
                                if draft.publicKeys?.isEmpty == true { draft.publicKeys = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let myKey = SigningService.publicKeyBase64, !keys.contains(myKey) {
                        Button {
                            draft.publicKeys = keys + [myKey]
                        } label: {
                            Label("Tie My Signing Key to This Author", systemImage: "signature")
                        }
                        .help("Your stamps and comments will show as \(draft.fullName.isEmpty ? "this author" : draft.fullName) ✓")
                    }
                }

                Section("Affiliations") {
                    // One text field per affiliation; the user can add more.
                    ForEach(draft.affiliations.indices, id: \.self) { i in
                        HStack {
                            TextField("Institution / Department", text: $draft.affiliations[i])
                            // Remove button shown when there is more than one affiliation.
                            if draft.affiliations.count > 1 {
                                Button {
                                    draft.affiliations.remove(at: i)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button {
                        draft.affiliations.append("")
                    } label: {
                        Label("Add Affiliation", systemImage: "plus")
                    }
                }

                Section("Role") {
                    Toggle("Corresponding Author", isOn: $draft.isCorresponding)
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 16)
        }
        // Push every field change back to the store immediately.
        .onChange(of: draft.firstName)       { _, _ in onChange(draft) }
        .onChange(of: draft.lastName)        { _, _ in onChange(draft) }
        .onChange(of: draft.email)           { _, _ in onChange(draft) }
        .onChange(of: draft.orcid)           { _, _ in onChange(draft) }
        .onChange(of: draft.affiliations)    { _, _ in onChange(draft) }
        .onChange(of: draft.isCorresponding) { _, _ in onChange(draft) }
        .onChange(of: draft.publicKeys)      { _, _ in onChange(draft) }
        // If the user clicks a different author row, reload from the new author.
        .onChange(of: author.id) { _, _ in draft = author }
    }
}
