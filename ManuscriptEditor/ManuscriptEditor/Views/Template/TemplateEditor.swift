// TemplateEditor.swift
//
// Editing a journal template as an object: its sidebar, its router, and the
// header every one of its panes wears.
//
// WHY A TAB AND NOT A SHEET
// ─────────────────────────────────────────────────────────────────────────────
// A template used to be something you *captured* from a cut: write a title
// page in a manuscript, press Save, and that text became the template's
// sample.  That works exactly once.  It made editing a template mean editing
// some manuscript that happened to be linked to it, it made "which manuscript
// is the good one" a real question, and it turned every template edit into a
// decision about somebody's paper.
//
// So a template is edited directly, in a tab of its own — and visibly not a
// manuscript (`TemplateStyle`), because the two live in the same window and
// typing into the wrong one changes what every manuscript using that template
// starts from.
//
// WHAT IS EDITABLE HERE
// ─────────────────────────────────────────────────────────────────────────────
//   editable    the venue's own sections — its title page, the letter it
//               expects, the questions it asks — plus the four parts
//   inactive    title, authors, abstract, keywords, figures, tables,
//               bibliography.  Journal-agnostic: a venue has an opinion about
//               how they are SET, never about what they say.  They stay
//               REFERENCEABLE — `[[title]]`, `[[authors.names]]` — which is
//               how a venue's layout is expressed.
//
// Nothing here is written until Overview's Save; see `TemplateWorkspace`.
//
// See MasterContext/features/journal-templates.md §3.

import SwiftUI

// MARK: - Sidebar

struct TemplateSidebarView: View {
    @Environment(TemplateWorkspace.self) private var templates
    @Environment(ManuscriptStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openSettings) private var openSettings

    let templateID: UUID
    @Binding var selection: SidebarItem?

    /// Renaming a section from the sidebar (same gesture as a manuscript's).
    @State private var renamingKey: String?
    @State private var renameDraft = ""

    private var template: JournalTemplate? { templates.template(templateID) }
    private var sections: [StructureSection] { template?.structure.sections ?? [] }
    private var editedParts: Set<ProfilePart> { templates.editedParts(templateID) }


    var body: some View {
        List(selection: $selection) {
            Section("Template") {
                Label("Overview", systemImage: "info.circle")
                    .tag(SidebarItem.templateOverview)
            }

            // The same four parts, in the same order, as a journal cut's —
            // that symmetry is the point: one object, two places to meet it.
            Section("Journal") {
                partRow(.requirements, SidebarItem.summary, "doc.text")
                partRow(.structure, SidebarItem.structure, "list.bullet.indent")
                partRow(.checks, SidebarItem.checks, "checklist")
                partRow(.export, SidebarItem.export, "square.and.arrow.up")
            }

            // Content reads exactly as a manuscript's does — the fixed parts
            // first, in their usual order, then the sections past the rule.
            // The difference is that the fixed parts are DEAD here: a venue
            // has an opinion about how a title is set, never about what it
            // says.  Listing them greyed says that; hiding them would suggest
            // a template could supply them.
            Section("Content") {
                ForEach(TemplateSidebarView.fixedParts, id: \.title) { part in
                    Label(part.title, systemImage: part.icon)
                        .foregroundStyle(.tertiary)
                        .help(part.token.isEmpty
                              ? "The author's, not the venue's."
                              : "The manuscript's, not the venue's. Refer to it from a section with \(part.token).")
                }
                .selectionDisabled()

                sectionsDelimiter

                // Past the rule, everything is the venue's — the abstract
                // first, which has a row whether or not the template says
                // anything about it yet (the entry is made on the first
                // edit).  The letter is not here: it is the author's, with a
                // fixed row above the rule, and an entry for it is ignored.
                abstractRow
                ForEach(sections.filter { $0.key != "abstract" && $0.kind != .letter }) { section in
                    sectionRow(section)
                }
                addSectionRow
            }
        }
        // Nothing here touches the window's own chrome: the title and subtitle
        // above the sidebar stay the manuscript's, because that is what the
        // window is.  A template says what it is in its tab and in its panes.
        .navigationTitle(store.manuscript?.title ?? "Manuscript Editor")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 4) {
                    Button { openSettings() } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("App Settings")
                    Spacer()
                    if templates.isDirty(templateID) {
                        // A dot, not a sentence: the footer is 30 points tall
                        // and the Overview says the rest.
                        Circle()
                            .fill(TemplateStyle.accent(scheme))
                            .frame(width: 6, height: 6)
                            .help("This template has unsaved changes — save it from its Overview.")
                            .padding(.trailing, 8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    /// The app's fixed parts, in the order a manuscript's sidebar lists them,
    /// and the token that reaches each one.
    static let fixedParts: [(title: String, icon: String, token: String)] = [
        ("Title",        "textformat",                 "[[title]]"),
        ("Authors",      "person.2",                   "[[authors.names]]"),
        ("Keywords",     "tag",                        "[[keywords]]"),
        ("Figures",      "photo.on.rectangle.angled",  "a figure reference"),
        ("Tables",       "tablecells",                 "a table reference"),
        ("Bibliography", "books.vertical",             "a citation"),
        ("Letter to the Editor", "envelope",           ""),
    ]

    /// The same hairline a manuscript's sidebar uses between the parts every
    /// manuscript has and the sections an author shapes.
    private var sectionsDelimiter: some View {
        Divider()
            .padding(.vertical, 2)
            .opacity(0.6)
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .accessibilityLabel("Sections")
    }

    /// One of the four parts, with the orange pencil when it has moved away
    /// from the library's copy — the same badge a manuscript's pane uses, for
    /// the same reason.
    ///
    /// No counts beside the name: a sidebar this narrow spent them on
    /// "Summa… 15…", and the pane itself says how many of everything there is.
    private func partRow(_ part: ProfilePart, _ item: SidebarItem,
                         _ icon: String) -> some View {
        HStack {
            // The name wins the space: a truncated "Struc…" beside an intact
            // badge is the wrong way round.
            Label(part.label, systemImage: icon)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if editedParts.contains(part) {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("Edited since this template was last saved")
            }
        }
        .tag(item)
    }

    /// The venue's say about the abstract: the entry when there is one, a
    /// stand-in with the same uid until then.
    @ViewBuilder
    private var abstractRow: some View {
        if let existing = sections.first(where: { $0.key == "abstract" }) {
            sectionRow(existing)
        } else {
            Label("Abstract", systemImage: "text.quote")
                .tag(SidebarItem.templateSection(TemplateWorkspace.abstractUID.uuidString))
                .help("The abstract as this venue wants it — its headings, notes, a boilerplate.")
        }
    }

    private func sectionRow(_ section: StructureSection) -> some View {
        Label(section.displayTitle, systemImage: icon(for: section))
            .tag(SidebarItem.templateSection(section.id.uuidString))
            .contextMenu {
                // Renamed, the Abstract would become an ordinary section.
                if section.key != "abstract" {
                    Button("Rename…") {
                        renameDraft = section.title
                        renamingKey = section.id.uuidString
                    }
                }
                Button("Delete Section", role: .destructive) { delete(section) }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { delete(section) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .alert("Rename Section", isPresented: Binding(
                get: { renamingKey == section.id.uuidString },
                set: { if !$0 { renamingKey = nil } }
            )) {
                TextField("Section title", text: $renameDraft)
                Button("Rename") { rename(section) }
                Button("Cancel", role: .cancel) { renamingKey = nil }
            } message: {
                Text("Renames it in this template. Manuscripts that already have a section by the old name keep it — the template's sections are matched by name.")
            }
    }

    private func icon(for section: StructureSection) -> String {
        section.key == "abstract" ? "text.quote" : section.kind.systemImage
    }

    /// Adding a section here adds it to the template's structure — the two are
    /// the same list, which is what §3.4 means by staying in sync.
    private var addSectionRow: some View {
        Menu {
            // The same three kinds a manuscript offers, in the same words.
            ForEach(SectionKind.addable, id: \.self) { kind in
                Button {
                    switch kind {
                    case .text:      add(StructureSection(title: uniqueTitle("New Section")))
                    case .questions: add(StructureSection(title: uniqueTitle("Submission Questions"),
                                                          kind: .questions, questions: []))
                    case .letter:    add(StructureSection(title: uniqueTitle("Letter to the Editor"),
                                                          kind: .letter))
                    }
                } label: {
                    Label(kind.label, systemImage: kind.systemImage)
                }
            }
        } label: {
            Label("Add Section", systemImage: "plus")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("A section this venue expects. It is created in every manuscript that adds this journal.")
    }

    private func uniqueTitle(_ base: String) -> String {
        var candidate = base
        var n = 2
        while sections.contains(where: { $0.key == candidate.lowercased() }) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    private func add(_ section: StructureSection) {
        templates.edit(templateID) { $0.structure.sections.append(section) }
        selection = .templateSection(section.id.uuidString)
    }

    private func rename(_ section: StructureSection) {
        let title = renameDraft.trimmingCharacters(in: .whitespaces)
        renamingKey = nil
        guard !title.isEmpty, title.lowercased() != section.key else { return }
        templates.edit(templateID) { template in
            guard let idx = template.structure.sections.firstIndex(where: { $0.id == section.id })
            else { return }
            template.structure.sections[idx].title = title
        }
    }

    private func delete(_ section: StructureSection) {
        if selection == .templateSection(section.id.uuidString) { selection = .structure }
        templates.edit(templateID) { template in
            template.structure.sections.removeAll { $0.id == section.id }
        }
    }
}

// MARK: - Router

struct TemplateDetailRouter: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID
    @Binding var selection: SidebarItem?

    var body: some View {
        Group {
            if templates.template(templateID) == nil {
                ContentUnavailableView(
                    "Template Not Available",
                    systemImage: "building.columns",
                    description: Text("It was deleted from your library. Close this tab.")
                )
            } else {
                switch selection {
                case .templateOverview, .none: TemplateOverviewView(templateID: templateID)
                case .summary:                 TemplateSummaryView(templateID: templateID)
                case .structure:               TemplateStructureView(templateID: templateID,
                                                                     selection: $selection)
                case .checks:                  TemplateTestsView(templateID: templateID)
                case .export:                  TemplateExportView(templateID: templateID)
                case .templateSection(let key):
                    TemplateSectionView(templateID: templateID, sectionKey: key)
                default:
                    // A manuscript pane selected before the tab switched.
                    TemplateOverviewView(templateID: templateID)
                }
            }
        }
        // A container with NO intrinsic size of its own.
        //
        // A `NavigationSplitView`'s detail hands its ideal height up to the
        // split view, and a pane is a header over a ScrollView whose ideal
        // height is its whole content — so a long Summary or a long outline
        // made the split taller than the window, which pushed the sidebar's
        // rows off the top and left the window looking empty.  That is the
        // "every option disappears" bug.  A `GeometryReader` reports the size
        // it is PROPOSED and nothing about its content, so the pane fills the
        // column instead of telling the column how big to be.  See gotcha 24.
        .modifier(PaneContainment())
    }
}

/// Lets a pane fill its column without dictating the column's size.
private struct PaneContainment: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { _ in
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Pane header

/// The header every template pane wears: what you are editing, and the fact
/// that it is a template rather than a paper.
struct TemplatePaneHeader: View {
    @Environment(TemplateWorkspace.self) private var templates
    @Environment(\.colorScheme) private var scheme

    let templateID: UUID
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if let template = templates.template(templateID) {
                        Text(template.displayName)
                            .font(.caption)
                            .foregroundStyle(TemplateStyle.accent(scheme))
                            .lineLimit(1)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Capped, not free: this header's ideal width is the pane's, and
            // the pane's is the split view's (gotcha 24).
            .frame(maxWidth: TemplateLayout.contentWidth, alignment: .leading)
            Spacer(minLength: 8)
            if templates.isDirty(templateID) {
                Label("Unsaved", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(TemplateStyle.accent(scheme))
                    .help("Held in memory. Save it from Overview to change the template itself.")
            }
        }
        // Left-justified like the tabs above it.  It used to be inset past
        // the editor's gutter so the gutter's rule wouldn't run through it;
        // the rule is clipped to the editor now, so nothing needs dodging.
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .templateSurface()
    }
}
