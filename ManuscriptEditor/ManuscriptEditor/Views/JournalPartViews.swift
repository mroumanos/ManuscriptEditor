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
    @Environment(TemplateWorkspace.self) private var templates

    let journal: Journal
    let part: ProfilePart
    /// Kept for call sites; a header says nothing but the journal.
    var subtitle: String = ""
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
        // The same row on Summary, Tests and Export, the way the versions
        // section shows a journal: its icon, its name, its type, and the
        // link and warning icons.  Summary alone carries the three actions.
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                .overlay(Circle().strokeBorder(.primary.opacity(0.35), lineWidth: 1))
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
                    Button("Manage") {
                        NotificationCenter.default.post(name: .manageTemplate, object: nil,
                                                        userInfo: ["template": template.id])
                    }
                    .help("Edit the original — “\(template.displayName)”, in its own tab")
                    Button("Load") { loading = true }
                        .help("Load the original: replace this journal's summary, structure, tests and export with the template's copy from your library")
                    Button("Copy") {
                        // A fork: a copy of the template, this journal pointed
                        // at it, opened for editing — a version of your own.
                        if let made = templates.openCopy(of: template.id) {
                            _ = store.linkToTemplate(made, journalID: journal.id)
                            NotificationCenter.default.post(name: .manageTemplate, object: nil,
                                                            userInfo: ["template": made])
                        } else {
                            store.showBanner(.error, "Couldn't copy “\(template.displayName)”.")
                        }
                    }
                    .help("Fork: a copy of the template as a new version, named “\(JournalProfileLibrary.shared.copyName(for: template))”, with this journal following it")
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
        .confirmationDialog("Replace this journal's configuration with its template's?",
                            isPresented: $loading, titleVisibility: .visible) {
            Button("Load", role: .destructive) { _ = store.adoptLibraryProfile(journalID: journal.id) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The summary, structure, tests and export outline are replaced with “\(template?.displayName ?? "the template")”'s. Nothing you have written in the manuscript changes, and ⌘Z undoes it.")
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

// MARK: - Summary

/// **Summary** — the journal's own instructions, distilled, as this cut holds
/// them.
struct JournalSummaryView: View {
    @Environment(ManuscriptStore.self) private var store

    var versionRef: VersionRef = .source

    @State private var editing = false
    @State private var urlDraft = ""
    @State private var bulletDraft = ""

    private var journal: Journal? { store.paneJournal(for: versionRef) }

    var body: some View {
        VStack(spacing: 0) {
            if let journal {
                let requirements = journal.sourceRequirements ?? SourceRequirements()
                JournalPartHeader(
                    journal: journal, part: .requirements,
                    subtitle: "The journal's instructions, distilled. Tests are what the app enforces of them.",
                    edited: store.partDiffersFromTemplate(.requirements, journal: journal))

                // A pencil, not a page of controls: the bullets and the link
                // are edited in place and saved on the second click.
                HStack(spacing: 8) {
                    Button {
                        if editing {
                            var edited = requirements
                            edited.url = urlDraft.trimmingCharacters(in: .whitespaces)
                            edited.text = bulletDraft
                            store.updateSourceRequirements(edited, journalID: journal.id)
                        } else {
                            urlDraft = requirements.url.isEmpty ? journal.submissionURL : requirements.url
                            bulletDraft = requirements.text
                        }
                        editing.toggle()
                    } label: {
                        Image(systemName: editing ? "checkmark.circle.fill" : "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help(editing ? "Save" : "Edit the summary")
                    if editing { Button("Cancel") { editing = false }.buttonStyle(.borderless) }
                    Spacer()
                }
                .controlSize(.small)
                .padding(.horizontal, 20)
                .padding(.horizontal, 20)

                if editing {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Link to the journal's author instructions", text: $urlDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        PlainTextEditor(text: $bulletDraft)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        Text("One requirement per line. Start each with a category — description: / limits: / components: / format: / extra: — to keep the summary readable.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if requirements.bullets.isEmpty {
                                Text("No summary yet — Edit to paste this journal's instructions, one per line, or Load the template's.")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                            ForEach(Array(SourceRequirements.grouped(requirements.bullets)
                                .enumerated()), id: \.offset) { _, group in
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
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                }
            } else {
                JournalPartPlaceholder(part: .requirements)
            }
        }
    }
}

// MARK: - Structure

/// **Structure** — which sections a submission at this venue has, as this cut
/// holds them.
///
/// No `required` column: every section here is one the venue wants, and a
/// section you don't want is one you delete.  What a cut adds for itself is
/// added the ordinary way, from the sidebar — it simply isn't part of the
/// template.
struct JournalStructureView: View {
    @Environment(ManuscriptStore.self) private var store

    var versionRef: VersionRef = .source

    @State private var newTitle = ""

    private var journal: Journal? { store.paneJournal(for: versionRef) }
    private var sections: [StructureSection] { journal?.structure?.sections ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if let journal {
                JournalPartHeader(
                    journal: journal, part: .structure,
                    subtitle: "What a submission at this venue contains, as this cut holds it. A section the manuscript has that isn't named here is greyed in the sidebar and left out of the export; the components, their typography, boilerplate and AI context are edited in the template (Edit).",
                    edited: store.partDiffersFromTemplate(.structure, journal: journal))

                List {
                    if sections.isEmpty {
                        Text("No sections recorded — Load the template's structure, or add the ones this journal expects below.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(sections) { section in
                        row(journal, section)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                    Text("Title, authors, abstract, keywords, figures, tables and bibliography come with every manuscript, so they aren't listed here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                JournalPartPlaceholder(part: .structure)
            }
        }
    }

    private func row(_ journal: Journal, _ section: StructureSection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary).font(.caption)
                .help("Drag to reorder")
            Image(systemName: section.type.systemImage)
                .foregroundStyle(.tertiary).font(.caption).frame(width: 18)
            Text(section.displayTitle)
            if let boilerplate = section.boilerplate, !boilerplate.isEmpty {
                Text("has content")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
                    .help("\(boilerplate)\n\nThe venue's default content for this section — edited in the template.")
            }
            if let questions = section.questions, !questions.isEmpty {
                Text("\(questions.count) question\(questions.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(role: .destructive) {
                var edited = sections
                edited.removeAll { $0.id == section.id }
                store.updateStructure(rebuilt(journal, sections: edited), journalID: journal.id)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Removes it from this journal's structure. The section itself, and anything written in it, stays.")
        }
        .controlSize(.small)
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// A structure with these sections, keeping the formats the journal
    /// already carries.
    private func rebuilt(_ journal: Journal, sections: [StructureSection]) -> JournalStructure {
        JournalStructure(sections: sections,
                         coreFormats: journal.structure?.coreFormats,
                         documentFormat: journal.structure?.documentFormat)
    }

    private func add(_ journal: Journal) {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !sections.contains(where: { $0.key == title.lowercased() }) else { return }
        store.updateStructure(rebuilt(journal, sections: sections + [StructureSection(title: title)]),
                              journalID: journal.id)
        newTitle = ""
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
