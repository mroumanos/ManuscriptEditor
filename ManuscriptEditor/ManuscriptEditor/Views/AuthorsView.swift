// AuthorsView.swift
//
// Two-pane view for managing the manuscript's author list and the
// institution registry the authors reference.
//
// Layout (HSplitView):
//   LEFT   — author list (drag-to-reorder) + the Institutions section, with
//            "Add Author" / "Add Institution" buttons beneath
//   RIGHT  — `AuthorEditor` form for the selected author, or a placeholder
//
// Institutions are first-class: authors affiliate by REFERENCING registry
// entries (checkboxes in the editor), and every author is required to
// reference at least one — rows and the editor flag violations.

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

    private var institutions: [Institution] {
        store.manuscript(for: versionRef)?.institutions ?? []
    }

    var body: some View {
        if authors.isEmpty && institutions.isEmpty {
            emptyState
        } else {
            HSplitView {
                // MARK: Left — authors + institution registry
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        Section("Authors") {
                            ForEach(authors) { author in
                                authorRow(author).tag(author.id)
                            }
                            .onMove { store.moveAuthors(from: $0, to: $1, ref: versionRef) }
                        }
                        Section("Institutions") {
                            ForEach(institutions) { institution in
                                institutionRow(institution)
                            }
                            if institutions.isEmpty {
                                Text("None yet — authors must reference one.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.windowBackgroundColor))
                    .onAppear { autoSelect() }
                    .onChange(of: authors.map(\.id)) { _, _ in autoSelect() }

                    Divider()

                    HStack(spacing: 4) {
                        Button {
                            store.addAuthor(ref: versionRef)
                            selectedID = store.manuscript(for: versionRef)?.authors.last?.id
                        } label: {
                            Label("Add Author", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 10)
                        .padding(.leading, 10)

                        Button {
                            store.addInstitution(ref: versionRef)
                        } label: {
                            Label("Add Institution", systemImage: "building.columns")
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 10)
                        .help("Institutions are referenced by authors — every author needs at least one")

                        Spacer()
                        Text("\(authors.count) author\(authors.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 10)
                    }
                    .background(Color(NSColor.windowBackgroundColor))
                }
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 330)
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))

                // MARK: Right — author editor
                if let id = selectedID,
                   let author = authors.first(where: { $0.id == id }) {
                    AuthorEditor(author: author, institutions: institutions) { updated in
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
            Text("Add authors and the institutions they reference.")
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    store.addAuthor(ref: versionRef)
                } label: {
                    Label("Add Author", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    store.addInstitution(ref: versionRef)
                } label: {
                    Label("Add Institution", systemImage: "building.columns")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func autoSelect() {
        if selectedID == nil || !authors.contains(where: { $0.id == selectedID }) {
            selectedID = authors.first?.id
        }
    }

    private func authorRow(_ author: Author) -> some View {
        let m = store.manuscript(for: versionRef)
        return HStack(spacing: 8) {
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
                    if let m, author.missingInstitution(in: m) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("No institution referenced — every author needs one")
                    }
                }
                if let m, let first = author.affiliationNames(in: m).first {
                    Text(first)
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

    /// One registry entry: name edited inline, delete strips references.
    private func institutionRow(_ institution: Institution) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "building.columns")
                .foregroundStyle(.tertiary)
                .font(.caption)
            TextField("Institution name", text: Binding(
                get: { institution.name },
                set: { store.updateInstitution(Institution(id: institution.id, name: $0), ref: versionRef) }
            ))
            .textFieldStyle(.plain)
            Button {
                store.deleteInstitution(id: institution.id, ref: versionRef)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove institution (authors referencing it lose the reference)")
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
    /// The manuscript's institution registry (for the reference checkboxes).
    let institutions: [Institution]
    /// Callback invoked whenever any field changes.
    let onChange: (Author) -> Void

    /// Mutable working copy of the author.
    @State private var draft: Author

    init(author: Author, institutions: [Institution], onChange: @escaping (Author) -> Void) {
        self.author = author
        self.institutions = institutions
        self.onChange = onChange
        _draft = State(initialValue: author)
    }

    private var selectedInstitutions: Set<UUID> { Set(draft.institutionIDs ?? []) }

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

                Section("Institutions") {
                    if institutions.isEmpty {
                        Text("No institutions in the registry yet — use \"Add Institution\" under the author list first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(institutions) { institution in
                            Toggle(institution.name.isEmpty ? "(unnamed)" : institution.name,
                                   isOn: Binding(
                                get: { selectedInstitutions.contains(institution.id) },
                                set: { on in
                                    var ids = draft.institutionIDs ?? []
                                    if on {
                                        if !ids.contains(institution.id) { ids.append(institution.id) }
                                    } else {
                                        ids.removeAll { $0 == institution.id }
                                    }
                                    draft.institutionIDs = ids
                                }
                            ))
                        }
                    }
                    if selectedInstitutions.isEmpty && draft.affiliations.allSatisfy(\.isEmpty) {
                        Label("Required — reference at least one institution.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
        .onChange(of: draft.institutionIDs)  { _, _ in onChange(draft) }
        .onChange(of: draft.isCorresponding) { _, _ in onChange(draft) }
        // If the user clicks a different author row, reload from the new author.
        .onChange(of: author.id) { _, _ in draft = author }
    }

}
