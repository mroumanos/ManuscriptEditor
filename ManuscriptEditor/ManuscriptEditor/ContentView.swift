// ContentView.swift
//
// Root layout of the app's main window.
//
// NAVIGATION OVERVIEW
// ─────────────────────────────────────────────────────────────────────────────
// NavigationSplitView
//   LEFT  → SidebarView    (Manuscript section + settings gear at bottom)
//   RIGHT → detail pane
//            ├─ CutTabBar  (always pinned at top via .safeAreaInset)
//            └─ content    (single pane or side-by-side split)
//
// TAB BAR PINNING
// ─────────────────────────────────────────────────────────────────────────────
// The CutTabBar sits at the top of a VStack in the detail column, with
// detailPaneContent filling the remaining space.  This is more reliable than
// .safeAreaInset on macOS, where the top safe area maps to the title bar.
//
// FOLDER PICKER FLOW
// ─────────────────────────────────────────────────────────────────────────────
// When the user triggers "New Manuscript" (⌘N or WelcomeView button), a
// folder picker is shown before the manuscript is created.  The selected
// folder is passed to `store.createNew(in:)`.

import SwiftUI
import AppKit

// MARK: - SidebarItem

enum SidebarItem: Hashable {
    // ── Manuscript ──────────────────────────────────────────────────────────
    case overview
    case sync
    case checks
    case export
    case data
    case versions
    case manuscriptSettings

    // ── Content ─────────────────────────────────────────────────────────────
    case authors
    case abstract
    case keywords
    case section(UUID)
    case figures
    case tables
    case bibliography
    case letterToEditor

    /// Content items are editable prose/component views.  Used to gate the
    /// sidebar's Content section (shown only when a version tab is open).
    var isContent: Bool {
        switch self {
        case .authors, .abstract, .keywords, .section,
             .figures, .tables, .bibliography, .letterToEditor:
            return true
        case .overview, .sync, .checks, .export, .data, .versions, .manuscriptSettings:
            return false
        }
    }

    /// Comparable items render one pane per open journal tab in side-by-side.
    /// This is the Content items plus **Checks** (each pane evaluates its own
    /// journal's content against its own view — live).
    var isComparable: Bool {
        isContent || self == .checks
    }

    /// Stable key used to anchor `Note`s to this content item.
    var notesKey: String {
        switch self {
        case .overview:           return "overview"
        case .sync:               return "sync"
        case .checks:             return "checks"
        case .export:             return "export"
        case .data:               return "data"
        case .versions:           return "versions"
        case .manuscriptSettings: return "settings"
        case .authors:            return "authors"
        case .abstract:           return "abstract"
        case .keywords:           return "keywords"
        case .section(let id):    return "section:\(id.uuidString)"
        case .figures:            return "figures"
        case .tables:             return "tables"
        case .bibliography:       return "bibliography"
        case .letterToEditor:     return "letter"
        }
    }
}

// MARK: - Version colours

/// Stable per-tab colour palette.  A version's pane capsule and its tab chip
/// both derive their colour from the version's index in `openTabs`, so the two
/// always match.  Source is normally index 0 → blue.
func versionColor(at index: Int) -> Color {
    let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]
    return palette[index % palette.count]
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    @State private var selection: SidebarItem? = .overview

    /// Versions currently open for side-by-side comparison.  Source is a normal,
    /// closable tab.  When empty, the sidebar hides its Content section.
    @State private var openTabs: [VersionRef] = [.source]

    /// Drives the NSOpenPanel shown before a new manuscript is created.
    @State private var showingFolderPicker = false

    /// Drives the Export sheet (File → Export Submission Package…).
    @State private var showingExport = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, hasOpenTabs: !openTabs.isEmpty)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 290)
        } detail: {
            if store.manuscript != nil {
                VStack(spacing: 0) {
                    CutTabBar(
                        openTabs: $openTabs,
                        versions: store.manuscript?.versions ?? []
                    )
                    Divider()
                    detailPaneContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The window title is the manuscript's name (not the app name).
                .navigationTitle(windowTitle)
            } else {
                WelcomeView(onNewManuscript: pickFolderThenCreate)
                    .navigationTitle("Manuscript Editor")
            }
        }
        .textSelection(.disabled)
        .onAppear {
            store.loadMostRecent()
            appStore.load()
        }
        // If every comparison tab is closed, the Content section disappears —
        // redirect any content selection back to the manuscript overview.
        .onChange(of: openTabs.isEmpty) { _, isEmpty in
            if isEmpty, selection?.isContent == true {
                selection = .overview
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newManuscript)) { _ in
            pickFolderThenCreate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveManuscript)) { _ in
            store.trySave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportManuscript)) { _ in
            if store.manuscript != nil { showingExport = true }
        }
        // After a sync, retarget any open tab from the journal's old head to
        // its new one so the synced content is what the user sees.
        .onReceive(NotificationCenter.default.publisher(for: .journalHeadChanged)) { note in
            guard let old = note.userInfo?["old"] as? UUID,
                  let new = note.userInfo?["new"] as? UUID else { return }
            openTabs = openTabs.map { $0 == .version(old) ? .version(new) : $0 }
        }
        .sheet(isPresented: $showingExport) {
            ExportSheet()
        }
    }

    /// The manuscript's title, falling back to the app name when unnamed.
    private var windowTitle: String {
        let title = store.manuscript?.title.trimmingCharacters(in: .whitespaces) ?? ""
        return title.isEmpty ? "Manuscript Editor" : title
    }

    // MARK: - Detail pane

    /// For a Content selection with open tabs, render one pane per open version
    /// side-by-side; navigating the sidebar moves every pane together.  For
    /// manuscript-level items (Overview, Checks, …) render a single pane against
    /// the live Source.
    @ViewBuilder
    private var detailPaneContent: some View {
        if let sel = selection, sel.isComparable, !openTabs.isEmpty {
            HSplitView {
                ForEach(Array(openTabs.enumerated()), id: \.element) { index, ref in
                    versionPane(ref, item: sel, index: index)
                        .frame(minWidth: 360)
                }
            }
        } else {
            DetailRouter(selection: $selection)
        }
    }

    /// One comparison pane: a colored capsule holding the section title (which
    /// version it belongs to is shown by the colour, matching the tab chip),
    /// then the editable content view bound to that version.  Both Source and
    /// versions are fully editable.
    @ViewBuilder
    private func versionPane(_ ref: VersionRef, item: SidebarItem, index: Int) -> some View {
        let color = versionColor(at: index)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                paneTitleCapsule(item: item, ref: ref, color: color)
                Spacer()
                if let words = wordCount(for: item, ref: ref) {
                    Label("\(words) words", systemImage: "text.word.spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                sectionActivationControl(item: item, ref: ref)
                NotesButton(versionKey: ref.id, itemKey: item.notesKey)
            }
            // Align the title past the editor's line-number gutter so it doesn't
            // sit over the gutter's edge.
            .padding(.leading, EditorLayout.leftInset)
            .padding(.trailing, 12)
            .padding(.vertical, 7)

            contentView(for: item, ref: ref)
        }
        .id(ref)
    }

    /// The colored title capsule.  Active body sections are editable inline
    /// (rename applies everywhere); a deactivated or absent section shows a
    /// dimmed static capsule; other items show a static title.
    @ViewBuilder
    private func paneTitleCapsule(item: SidebarItem, ref: VersionRef, color: Color) -> some View {
        if case .section(let id) = item {
            let section = resolvedSection(id, ref)
            if let section, section.active {
                TextField("", text: sectionTitleBinding(id, ref))
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
                    .frame(maxWidth: 260)
            } else {
                let title = section?.title
                    ?? store.manuscript?.sections.first(where: { $0.id == id })?.title
                    ?? "Section"
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz")
                    Text(title)
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        } else {
            Text(itemTitle(item))
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(color.opacity(0.18), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
        }
    }

    /// Per-journal activate/deactivate control for a section pane.
    @ViewBuilder
    private func sectionActivationControl(item: SidebarItem, ref: VersionRef) -> some View {
        if case .section(let id) = item, let section = resolvedSection(id, ref) {
            Button {
                store.setSectionActive(!section.active, id: id, ref: ref)
            } label: {
                Image(systemName: section.active ? "eye" : "eye.slash")
                    .foregroundStyle(section.active ? Color.secondary : Color.orange)
            }
            .buttonStyle(.borderless)
            .help(section.active
                  ? "Active in this journal — click to deactivate"
                  : "Deactivated in this journal — click to activate")
        }
    }

    /// Fixed display title for non-section content items.
    private func itemTitle(_ item: SidebarItem) -> String {
        switch item {
        case .authors:        return "Authors"
        case .abstract:       return "Abstract"
        case .keywords:       return "Keywords"
        case .figures:        return "Figures"
        case .tables:         return "Tables"
        case .bibliography:   return "Bibliography"
        case .letterToEditor: return "Cover Letter"
        case .checks:         return "Checks"
        default:              return ""
        }
    }

    /// Live word count shown in the pane header, where meaningful.
    private func wordCount(for item: SidebarItem, ref: VersionRef) -> Int? {
        guard let m = store.manuscript(for: ref) else { return nil }
        switch item {
        case .abstract:        return m.abstractWordCount
        case .section(let id):
            let s = resolvedSection(id, ref)
            return (s?.active ?? false) ? s?.wordCount : nil
        default:               return nil
        }
    }

    /// Resolves a section within a version by id, then by type (versions keep
    /// the source ids at cut time; type-matching keeps it robust afterwards).
    private func resolvedSection(_ id: UUID, _ ref: VersionRef) -> ManuscriptSection? {
        let target = store.manuscript(for: ref)
        if let byID = target?.sections.first(where: { $0.id == id }) { return byID }
        if let type = store.manuscript?.sections.first(where: { $0.id == id })?.type, type != .custom {
            return target?.sections.first { $0.type == type }
        }
        return nil
    }

    /// Section titles are shared structure — renaming applies to every version.
    private func sectionTitleBinding(_ id: UUID, _ ref: VersionRef) -> Binding<String> {
        Binding(
            get: { resolvedSection(id, ref)?.title ?? "" },
            set: { newValue in store.renameSection(id: id, title: newValue) }
        )
    }

    /// The editable content view for a sidebar item, bound to a specific version.
    @ViewBuilder
    private func contentView(for item: SidebarItem, ref: VersionRef) -> some View {
        switch item {
        case .authors:           AuthorsView(versionRef: ref)
        case .abstract:          AbstractView(versionRef: ref)
        case .keywords:          KeywordsView(versionRef: ref)
        case .section(let id):   SectionEditorView(sectionID: id, versionRef: ref)
        case .figures:           FiguresView(versionRef: ref)
        case .tables:            TablesView(versionRef: ref)
        case .bibliography:      BibliographyView(versionRef: ref)
        case .letterToEditor:    LetterToEditorView(versionRef: ref)
        case .checks:            ChecksView(versionRef: ref)
        default:                 EmptyView()
        }
    }

    // MARK: - Folder picker

    private func pickFolderThenCreate() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for your manuscript"
        panel.message = "All manuscript files will be saved here."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        store.createNew(in: url)
        selection = .overview
        openTabs  = [.source]
    }
}

// MARK: - DetailRouter

struct DetailRouter: View {
    @Environment(ManuscriptStore.self) private var store
    @Binding var selection: SidebarItem?

    var body: some View {
        switch selection {
        case .overview, .none:      OverviewView()
        case .sync:                 SyncView()
        case .checks:               ChecksView()
        case .export:               ExportView()
        case .data:                 DataView()
        case .versions:             VersionsView()
        case .manuscriptSettings:   ManuscriptSettingsView()
        case .authors:              AuthorsView()
        case .abstract:             AbstractView()
        case .keywords:             KeywordsView()
        case .section(let id):      SectionEditorView(sectionID: id)
        case .figures:              FiguresView()
        case .tables:               TablesView()
        case .bibliography:         BibliographyView()
        case .letterToEditor:       LetterToEditorView()
        }
    }
}

// MARK: - CutTabBar

struct CutTabBar: View {
    @Environment(ManuscriptStore.self) private var store

    @Binding var openTabs: [VersionRef]
    let versions: [ManuscriptVersion]

    @State private var showAddPicker = false

    /// References that can still be opened: Source (if closed) + unopened
    /// versions — journal working heads first, so "open Nature" naturally means
    /// the head, not an older cut that happens to carry the journal's name as
    /// its label.
    private var availableRefs: [VersionRef] {
        var refs: [VersionRef] = []
        if !openTabs.contains(.source) { refs.append(.source) }
        let sorted = versions.sorted { a, b in
            if isHead(a) != isHead(b) { return isHead(a) }
            return a.number < b.number
        }
        for v in sorted where !openTabs.contains(.version(v.id)) {
            refs.append(.version(v.id))
        }
        return refs
    }

    /// Whether a version is the current working head of its journal chain.
    private func isHead(_ version: ManuscriptVersion) -> Bool {
        store.latestVersion(forJournal: version.journalID)?.id == version.id
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(openTabs.enumerated()), id: \.element) { index, tab in
                        tabButton(for: tab, index: index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            Divider().frame(height: 20)

            Button {
                showAddPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(availableRefs.isEmpty)
            .padding(.horizontal, 6)
            .popover(isPresented: $showAddPicker, arrowEdge: .bottom) {
                addTabPicker
            }
        }
        .frame(height: 36)
        .background(.bar)
    }

    /// Every open tab is shown side-by-side, each coloured to match its pane.
    private func tabButton(for tab: VersionRef, index: Int) -> some View {
        let color = versionColor(at: index)
        return HStack(spacing: 5) {
            Image(systemName: tab == .source ? "doc.text" : "arrow.triangle.branch")
                .font(.caption2)
                .foregroundStyle(color)
            Text(tabLabel(for: tab))
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(color)

            Button {
                closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(0.45), lineWidth: 1)
        )
    }

    private var addTabPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open a version")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if availableRefs.isEmpty {
                Text("All versions are already open")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                ForEach(availableRefs) { ref in
                    Button {
                        openTabs.append(ref)
                        showAddPicker = false
                    } label: {
                        HStack {
                            Image(systemName: ref == .source ? "doc.text" : "arrow.triangle.branch")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tabLabel(for: ref))
                                    .font(.callout)
                                if let subtitle = subtitle(for: ref) {
                                    Text(subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .padding(.bottom, 4)
            }
        }
        .frame(minWidth: 200)
    }

    /// Journal versions are labelled "\(journal) v\(ordinal)": the free-text
    /// version label alone hides which journal a tab shows — after a sync the
    /// head is called "Synced from …", which names the *upstream*, not the
    /// journal the user is looking for.
    private func tabLabel(for tab: VersionRef) -> String {
        switch tab {
        case .source:
            return "Source"
        case .version(let id):
            guard let version = versions.first(where: { $0.id == id }) else { return "Version" }
            guard let jid = version.journalID,
                  let journal = store.manuscript?.journals.first(where: { $0.id == jid })
            else {
                return version.label.isEmpty ? "v\(version.number)" : version.label
            }
            let name = "\(journal.name) v\(store.journalOrdinal(of: version))"
            return isHead(version) ? name : "\(name) (older)"
        }
    }

    /// The version's own label, shown in the picker as secondary context
    /// (e.g. "Synced from Source") under the journal-based title.
    private func subtitle(for tab: VersionRef) -> String? {
        guard case .version(let id) = tab,
              let version = versions.first(where: { $0.id == id }),
              version.journalID != nil, !version.label.isEmpty
        else { return nil }
        return version.label
    }

    private func closeTab(_ tab: VersionRef) {
        openTabs.removeAll { $0 == tab }
    }
}
