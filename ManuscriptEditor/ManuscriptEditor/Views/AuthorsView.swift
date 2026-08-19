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
                    // ORCID search up top where it's visible (it hid at the
                    // bottom between the add buttons at first, Aug 2026).
                    OrcidSearchBar { candidate in
                        selectedID = store.addAuthor(from: candidate, ref: versionRef)
                    }
                    .padding(8)
                    // Above the List so the results dropdown paints over it.
                    .zIndex(1)

                    Divider()

                    List(selection: $selectedID) {
                        Section("Authors") {
                            ForEach(authors) { author in
                                authorRow(author).tag(author.id)
                            }
                            .onMove { store.moveAuthors(from: $0, to: $1, ref: versionRef) }
                        }
                        Section("Institutions") {
                            ForEach(institutions) { institution in
                                institutionRow(institution).tag(institution.id)
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

                // MARK: Right — author or institution editor
                if let id = selectedID,
                   let author = authors.first(where: { $0.id == id }) {
                    AuthorEditor(author: author, institutions: institutions) { updated in
                        store.updateAuthor(updated, ref: versionRef)
                    }
                } else if let id = selectedID,
                          let institution = institutions.first(where: { $0.id == id }) {
                    InstitutionEditor(
                        institution: institution,
                        referencingAuthors: authors.filter { ($0.institutionIDs ?? []).contains(id) }
                    ) { updated in
                        store.updateInstitution(updated, ref: versionRef)
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
            OrcidSearchBar { candidate in
                store.addAuthor(from: candidate, ref: versionRef)
            }
            .frame(width: 320)
            .zIndex(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func autoSelect() {
        let known = authors.map(\.id) + institutions.map(\.id)
        if selectedID == nil || !known.contains(where: { $0 == selectedID }) {
            selectedID = authors.first?.id ?? institutions.first?.id
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

    /// One registry entry — select it to edit the name in the right pane.
    private func institutionRow(_ institution: Institution) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "building.columns")
                .foregroundStyle(.tertiary)
                .font(.caption)
            Text(institution.name.isEmpty ? "(unnamed)" : institution.name)
                .lineLimit(1)
            Spacer()
            Button {
                if selectedID == institution.id { selectedID = nil }
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

// MARK: - InstitutionEditor

// MARK: - OrcidSearchBar

/// Inline ORCID author search (sits at the top of the Authors pane): type a
/// name ("marie curie", "curie, marie") or a full iD, and the top-20 hits
/// drop down live.  Picking one adds the author with names, iD, public
/// email, and primary institution filled in, then clears the search.
private struct OrcidSearchBar: View {
    let onPick: (OrcidService.Candidate) -> Void

    @State private var query = ""
    @State private var results: [OrcidService.Candidate] = []
    @State private var searching = false
    @State private var errorText: String?
    /// Measured field height, so the floating dropdown lands just below it.
    @State private var fieldHeight: CGFloat = 28

    /// Anything worth floating under the field: hits, an error, or the
    /// no-match note once a real query has finished searching.
    private var dropdownVisible: Bool {
        errorText != nil || !results.isEmpty
            || (!searching && query.trimmingCharacters(in: .whitespaces).count >= 3)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search - ORCID or name", text: $query)
                .textFieldStyle(.plain)
            if searching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color(NSColor.textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .onGeometryChange(for: CGFloat.self,
                          of: { $0.size.height },
                          action: { fieldHeight = $0 })
        // The dropdown FLOATS over whatever sits below (call sites raise the
        // bar's zIndex) — in the layout it would shove the author list down.
        .overlay(alignment: .topLeading) {
            if dropdownVisible {
                dropdown.offset(y: fieldHeight + 4)
            }
        }
        // Live search, debounced: each keystroke restarts the task; the
        // sleep absorbs typing bursts before the request goes out.
        .task(id: query) {
            errorText = nil
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 3 else { results = []; return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do { results = try await OrcidService().search(text) }
            catch { if !Task.isCancelled { errorText = error.localizedDescription } }
        }
    }

    /// The floating results card (also carries error / no-match states so
    /// none of them reflow the layout underneath).
    private var dropdown: some View {
        Group {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            } else if results.isEmpty {
                Text("No matches on ORCID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(results) { candidate in
                            row(candidate)
                            if candidate.id != results.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    /// Two-line row sized for the narrow pane: name, then iD · institution.
    private func row(_ candidate: OrcidService.Candidate) -> some View {
        Button {
            onPick(candidate)
            query = ""
            results = []
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.displayName.isEmpty ? "(no public name)"
                                                   : candidate.displayName)
                    .font(.callout)
                Text([candidate.orcid, candidate.institutionNames.first ?? ""]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

/// Right-pane form for a selected institution: the name lives here (not in
/// the list row), plus which authors reference it.
struct InstitutionEditor: View {
    let institution: Institution
    let referencingAuthors: [Author]
    let onChange: (Institution) -> Void

    @State private var draft: Institution

    init(institution: Institution, referencingAuthors: [Author],
         onChange: @escaping (Institution) -> Void) {
        self.institution = institution
        self.referencingAuthors = referencingAuthors
        self.onChange = onChange
        _draft = State(initialValue: institution)
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Institution") {
                    TextField("Display Name",
                              text: $draft.name)
                }
                Section("Referenced By") {
                    if referencingAuthors.isEmpty {
                        Text("No authors reference this institution yet — check it in an author's Institutions section.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(referencingAuthors) { author in
                            Label(author.displayName.isEmpty ? "(unnamed)" : author.displayName,
                                  systemImage: "person")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 16)
        }
        .onChange(of: draft.name) { _, _ in onChange(draft) }
        .onChange(of: institution) { _, new in
            guard new != draft else { return }
            draft = new
        }
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

    /// Free-form credentials text.  Reading joins the tag list when a file
    /// has one; writing stores the raw text in `degrees` and clears the tags
    /// so the text becomes the single source of truth.
    private var credentialsBinding: Binding<String> {
        Binding(
            get: {
                if let titles = draft.titles { return titles.joined(separator: ", ") }
                return draft.degrees ?? ""
            },
            set: {
                draft.degrees = $0.isEmpty ? nil : $0
                draft.titles = nil
            }
        )
    }

    /// Bridges an optional model field to a TextField; empty text stores nil
    /// so untouched fields stay absent from manuscript.json.
    private func optionalField(_ keyPath: WritableKeyPath<Author, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Name") {
                    TextField("First name", text: $draft.firstName)
                    TextField("Middle name / initials", text: optionalField(\.middleName))
                    TextField("Last name",  text: $draft.lastName)
                    // One free-form credentials line — replaces the separate
                    // honorific ("Dr., Prof.") and title-tag rows, which were
                    // two fields for one idea (Aug 2026 feedback).
                    TextField("Credentials (MD, PhD, Prof., …)", text: credentialsBinding)
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
        .onChange(of: draft.middleName)      { _, _ in onChange(draft) }
        .onChange(of: draft.degrees)         { _, _ in onChange(draft) }
        .onChange(of: draft.titles)          { _, _ in onChange(draft) }
        .onChange(of: draft.email)           { _, _ in onChange(draft) }
        .onChange(of: draft.orcid)           { _, _ in onChange(draft) }
        .onChange(of: draft.affiliations)    { _, _ in onChange(draft) }
        .onChange(of: draft.institutionIDs)  { _, _ in onChange(draft) }
        .onChange(of: draft.isCorresponding) { _, _ in onChange(draft) }
        // If the user clicks a different author row, reload from the new author.
        .onChange(of: author) { _, new in
            // External change (selection switch or document undo).
            guard new != draft else { return }
            draft = new
        }
    }

}
