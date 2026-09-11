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
    @Environment(\.colorScheme) private var scheme

    let journal: Journal
    let part: ProfilePart
    let subtitle: String
    /// Set when this part differs from the template it came from.
    var edited: Bool = false

    @State private var loading = false

    private var template: JournalTemplate? {
        journal.profileID.flatMap { JournalProfileLibrary.shared.profile(id: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(part.label).font(.headline)
                if edited {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .help("Differs from the template it came from — its checksum for this part doesn't match")
                }
                Spacer()
                if let template {
                    Button {
                        NotificationCenter.default.post(
                            name: .manageTemplate, object: nil,
                            userInfo: ["template": template.id])
                    } label: {
                        Label("Manage \(template.displayName)", systemImage: TemplateStyle.symbol)
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(TemplateStyle.accent(scheme))
                    .help("Open the template itself, in its own tab")
                    Button("Load") { loading = true }
                        .controlSize(.small)
                        .help("Replace this journal's \(part.label.lowercased()) with the template's copy")
                } else {
                    Text("Not linked to a template")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("This journal's configuration exists only here — link it in Tests.")
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Replace this journal's \(part.label.lowercased()) with the template's?",
                            isPresented: $loading, titleVisibility: .visible) {
            Button("Load", role: .destructive) {
                store.loadTemplatePart(part, journalID: journal.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Takes “\(template?.displayName ?? "the template")”'s copy of this part. Nothing you have written in the manuscript changes, and ⌘Z undoes it.")
        }
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

                HStack(spacing: 8) {
                    if !editing {
                        let link = requirements.url.isEmpty ? journal.submissionURL : requirements.url
                        if !link.isEmpty, let url = URL(string: link) {
                            Link(destination: url) {
                                Label("Author instructions", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                            .help(link)
                        }
                    }
                    Spacer()
                    Button(editing ? "Save" : "Edit") {
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
                    }
                    .controlSize(.small)
                }
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
                    subtitle: "What a submission at this venue contains. Add or remove sections for this cut here, and set how they print in Export — the template's own copy is edited in its tab.",
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
                    .onMove { from, to in
                        var edited = sections
                        edited.move(fromOffsets: from, toOffset: to)
                        store.updateStructure(rebuilt(journal, sections: edited), journalID: journal.id)
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

                Divider()
                HStack(spacing: 8) {
                    TextField("Add a section this journal expects", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { add(journal) }
                    Button("Add") { add(journal) }
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(14)
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
            Image(systemName: section.role?.systemImage
                  ?? (section.kind == .questions ? "list.bullet.rectangle" : "text.alignleft"))
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
