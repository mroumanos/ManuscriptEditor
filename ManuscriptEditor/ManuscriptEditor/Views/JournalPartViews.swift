// JournalPartViews.swift
//
// Two of a journal cut's four parts, as panes: **Summary** and **Structure**.
//
// Summary · Structure · Tests · Export are sidebar sections for a cut now, not
// rows in a card inside Checks — the same four, in the same order, whether you
// are looking at a venue's template or at your cut of it.  Tests is
// `ChecksView` (it evaluates, which is what that pane is for) and Export is
// `ExportView`; these two were sheets behind an "Open…" button, and are now
// where they belong.
//
// WHAT A CUT MAY DO WITH THEM
// ─────────────────────────────────────────────────────────────────────────────
// Edit them: they are this manuscript's own copy, and a paper often needs a
// rule the venue's page didn't state.  **Load** them from the template, which
// replaces this copy.  What a cut cannot do is save back — editing a template
// from inside a manuscript made every template change also a decision about
// somebody's paper.  The header says so and links to where that happens.
//
// See MasterContext/features/journal-templates.md §3.3.

import SwiftUI

// MARK: - Header

/// The line every journal part carries: which template this cut follows,
/// whether this part has drifted from it, and the way to take the template's
/// copy back.
struct JournalPartHeader: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self) private var appStore
    let journal: Journal
    let part: ProfilePart
    /// Set when this part differs from the template it came from.
    var edited: Bool = false
    /// Off when the header sits inside a pane that pads its own content
    /// (the Export pane), so the row lines up with what is under it.
    var padded: Bool = true

    @State private var loading = false
    @State private var editingType = false
    @State private var typeDraft = ""

    private var template: JournalTemplate? {
        journal.profileID.flatMap { JournalProfileLibrary.shared.profile(id: $0) }
    }

    /// The journal's own instructions page, else its template's.
    private var instructionsURL: URL? {
        let own = journal.sourceRequirements?.url ?? ""
        let fallback = template?.requirements.url ?? journal.submissionURL
        return URL(string: own.isEmpty ? fallback : own)
    }

    /// The journal's configured icon (Settings → Journals), as the versions
    /// row shows it.
    private var icon: String {
        let name = appStore.journalLibrary.first(where: { $0.name == journal.name })?.icon ?? journal.icon
        if let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        return "building.columns"
    }

    /// Everything wrong with this journal's copy, for one icon.
    private var warnings: [String] {
        var out: [String] = []
        if edited {
            out.append("This \(part.label.lowercased()) differs from the template it came from — Load takes the template's copy.")
        }
        if let text = TemplatePublishing.shared.status(for: journal.profile).warning {
            out.append(text)
        }
        return out
    }

    var body: some View {
        // The same row on Details, Tests and Export, the way the versions
        // section names a journal: icon, name, type, the link and warning
        // icons.  Details alone carries Save and Load.
        HStack(spacing: 8) {
            Image(systemName: icon).font(.headline).foregroundStyle(.primary)
            Text(journal.name).font(.headline)
            typeButton
            if let url = instructionsURL {
                Link(destination: url) { Image(systemName: "globe").font(.caption) }
                    .help(url.absoluteString)
            }
            if !warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(warnings.joined(separator: "\n\n"))
                    .accessibilityLabel(warnings.joined(separator: " "))
            }
            if part == .requirements {
                Spacer()
                if let template {
                    // Save takes this manuscript's copy to the template
                    // editor — the only way to disk, and from there to the
                    // cloud.  Load takes disk's copy back.
                    Button("Save") {
                        NotificationCenter.default.post(name: .manageTemplate, object: nil,
                                                        userInfo: ["template": template.id, "journal": journal.id])
                    }
                    .help("Open the template editor with this manuscript's copy of “\(template.displayName)”, to save it to disk or propose it")
                    Button("Load") { loading = true }
                        .help("Replace this journal's details, structure, tests and export with the template's copy from disk")
                } else {
                    Text("Not linked to a template")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("This journal's configuration exists only here — link it in Tests.")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, padded ? 20 : 0)
        .padding(.vertical, padded ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: journal.profile.checksum) {
            let journal = journal
            TemplatePublishing.shared.refresh(journal.profile, exportDiffers: { published in
                store.exportDiffers(from: published, journal: journal)
            })
        }
        .confirmationDialog("Replace this journal's configuration with the template's copy on disk?",
                            isPresented: $loading, titleVisibility: .visible) {
            Button("Load", role: .destructive) { _ = store.adoptLibraryProfile(journalID: journal.id) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The details, structure, tests and export outline are replaced with “\(template?.displayName ?? "the template")”'s as your library holds it. Nothing you have written in the manuscript changes, and ⌘Z undoes it.")
        }
    }

    /// The article type as a button: free-form, because journals invent
    /// their own format names and a fixed list would be wrong within a year.
    private var typeButton: some View {
        Button {
            typeDraft = journal.articleType ?? ""
            editingType = true
        } label: {
            Text(journal.articleType?.isEmpty == false ? journal.articleType! : "Add type…")
                .font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.accentColor.opacity(journal.articleType == nil ? 0.06 : 0.12), in: Capsule())
                .foregroundStyle(journal.articleType == nil ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("The article format this cut targets — Research Article, Research Brief, …")
        .popover(isPresented: $editingType, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Article type").font(.callout.weight(.medium))
                TextField("Research Article, Research Brief, …", text: $typeDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { commitType() }
                HStack {
                    Spacer()
                    Button("Set") { commitType() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func commitType() {
        var edited = journal
        let trimmed = typeDraft.trimmingCharacters(in: .whitespaces)
        edited.articleType = trimmed.isEmpty ? nil : trimmed
        store.updateJournal(edited)
        editingType = false
    }
}

// MARK: - Details

/// **Details** — what the journal template is (About) and what the venue
/// asks (Requirements), as this cut holds them.  Two boxes, each edited in
/// place behind its pencil; the header's Save takes the copy to the
/// template editor, Load takes disk's back.
struct JournalSummaryView: View {
    @Environment(ManuscriptStore.self) private var store

    var versionRef: VersionRef = .source

    @State private var editingAbout = false
    @State private var aboutDraft = AboutDraft()
    @State private var editingRequirements = false
    @State private var urlDraft = ""
    @State private var bulletDraft = ""

    private var journal: Journal? { store.paneJournal(for: versionRef) }
    private var template: JournalTemplate? {
        journal?.profileID.flatMap { JournalProfileLibrary.shared.profile(id: $0) }
    }

    struct AboutDraft {
        var name = "", type = "", publisher = "", country = "", description = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            if let journal {
                let requirements = journal.sourceRequirements ?? SourceRequirements()
                JournalPartHeader(journal: journal, part: .requirements,
                                  edited: store.partDiffersFromTemplate(.requirements, journal: journal))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        about(journal)
                        requirementsBox(journal, requirements)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            } else {
                JournalPartPlaceholder(part: .requirements)
            }
        }
    }

    // MARK: About

    private func about(_ journal: Journal) -> some View {
        JournalBox(title: "About", editing: editingAbout,
                   onEdit: {
                       aboutDraft = AboutDraft(name: journal.templateName ?? journal.name,
                                               type: journal.articleType ?? "",
                                               publisher: journal.publisher, country: journal.country ?? "",
                                               description: journal.profile.summaryDescription)
                       editingAbout = true
                   },
                   onSave: {
                       var edited = journal
                       let name = aboutDraft.name.trimmingCharacters(in: .whitespaces)
                       // The template's name, not the cut's: a cut keeps the
                       // name it was given ("BMJ test 1") whatever it follows.
                       if !name.isEmpty { edited.templateName = name }
                       let type = aboutDraft.type.trimmingCharacters(in: .whitespaces)
                       edited.articleType = type.isEmpty ? nil : type
                       edited.publisher = aboutDraft.publisher.trimmingCharacters(in: .whitespaces)
                       let country = aboutDraft.country.trimmingCharacters(in: .whitespaces)
                       edited.country = country.isEmpty ? nil : country
                       store.updateJournal(edited)
                       var requirements = journal.sourceRequirements ?? SourceRequirements()
                       var profile = journal.profile
                       profile.summaryDescription = aboutDraft.description
                       requirements.bullets = profile.requirements.bullets
                       store.updateSourceRequirements(requirements, journalID: journal.id)
                       editingAbout = false
                   },
                   onDiscard: { editingAbout = false }) {
            if editingAbout {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow { label("Name");        TextField("", text: $aboutDraft.name).textFieldStyle(.roundedBorder) }
                    GridRow { label("Type");        TextField("Research Article, Research Brief…", text: $aboutDraft.type).textFieldStyle(.roundedBorder) }
                    GridRow { label("Publisher");   TextField("", text: $aboutDraft.publisher).textFieldStyle(.roundedBorder) }
                    GridRow { label("Country");     TextField("", text: $aboutDraft.country).textFieldStyle(.roundedBorder) }
                    GridRow(alignment: .top) { label("Description"); TextField("What this format is for", text: $aboutDraft.description, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6) }
                }
                .controlSize(.small)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { label("Name");        Text(journal.templateName ?? journal.name) }
                    GridRow { label("Type");        Text(journal.articleType ?? "—").foregroundStyle(journal.articleType == nil ? .tertiary : .primary) }
                    GridRow { label("Publisher");   Text(journal.publisher.isEmpty ? "—" : journal.publisher) }
                    GridRow { label("Country");     Text(journal.country ?? "—") }
                    GridRow(alignment: .top) { label("Description"); Text(journal.profile.summaryDescription.isEmpty ? "—" : journal.profile.summaryDescription).fixedSize(horizontal: false, vertical: true) }
                    GridRow { label("Version");     Text(template.map { "v\($0.version)" } ?? "—").monospacedDigit() }
                    GridRow { label("Last saved");  Text(template?.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never") }
                }
                .font(.callout)
            }
        }
    }

    // MARK: Requirements

    private func requirementsBox(_ journal: Journal, _ requirements: SourceRequirements) -> some View {
        JournalBox(title: "Requirements", editing: editingRequirements,
                   onEdit: {
                       urlDraft = requirements.url.isEmpty ? journal.submissionURL : requirements.url
                       bulletDraft = requirements.text
                       editingRequirements = true
                   },
                   onSave: {
                       var edited = requirements
                       edited.url = urlDraft.trimmingCharacters(in: .whitespaces)
                       edited.text = bulletDraft
                       store.updateSourceRequirements(edited, journalID: journal.id)
                       editingRequirements = false
                   },
                   onDiscard: { editingRequirements = false }) {
            if editingRequirements {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Link to the journal's author instructions", text: $urlDraft)
                        .textFieldStyle(.roundedBorder)
                    PlainTextEditor(text: $bulletDraft)
                        .frame(minHeight: 220)
                    Text("One requirement per line. A `category:` prefix (description, limits, components, format, extra) groups it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    let link = requirements.url.isEmpty ? journal.submissionURL : requirements.url
                    if !link.isEmpty, let url = URL(string: link) {
                        Link(destination: url) {
                            Label("Author instructions", systemImage: "arrow.up.right.square").font(.caption)
                        }
                    }
                    if requirements.bullets.isEmpty {
                        Text("No requirements recorded.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(Array(SourceRequirements.grouped(requirements.bullets).enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text((group.category ?? "other").uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(item)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 90, alignment: .leading)
    }
}

// MARK: - Placeholder

/// What these panes say for Source, which has no venue to have requirements.
struct JournalPartPlaceholder: View {
    let part: ProfilePart

    var body: some View {
        ContentUnavailableView(
            "No Journal Here",
            systemImage: "building.columns",
            description: Text("Source is your manuscript as you write it — a venue's \(part.label.lowercased()) belongs to a journal cut. Pick a journal's tab above.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
