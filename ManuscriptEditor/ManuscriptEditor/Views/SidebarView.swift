// SidebarView.swift
//
// The left navigation column.
//
// STRUCTURE
// ─────────────────────────────────────────────────────────────────────────────
//   MANUSCRIPT — Overview, Checks, Data, Versions, Settings.
//   CONTENT    — Authors, Abstract, Keywords, the body sections, an inline
//                "Add Section" row, then Figures, Tables, Bibliography, Letter.
//                Only visible when at least one comparison tab is open.
//   BOTTOM BAR — the app Preferences gear (⌘,) and the appearance toggle.
//
// Sections are shared structure: they exist for every version. New sections are
// added via the inline row at the bottom of the section list (not a toolbar
// button), and each carries a unique title.

import SwiftUI

struct SidebarView: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore
    @Environment(\.openSettings)       private var openSettings

    @Binding var selection: SidebarItem?

    /// The active tab's content reference — item counts reflect the **active
    /// journal** (Data stays global; sections are shared structure).
    var activeRef: VersionRef = .source

    /// App-wide appearance, also editable from Preferences.
    @AppStorage(EditorPrefs.appearanceKey) private var appearance = AppearanceMode.system.rawValue

    /// Section being renamed via the context menu (drives the rename alert).
    /// Renaming lives here since the pane headers no longer carry a title field.
    @State private var renamingSectionID: UUID?
    @State private var renameDraft = ""
    /// Fixed pane ("figures"/"tables"/…) being renamed via the context menu.
    @State private var renamingPaneKey: String?

    private var manuscript: Manuscript? { store.manuscript }

    /// The active journal's content (counts source).
    private var active: Manuscript? { store.manuscript(for: activeRef) }

    /// Version count for the active journal (Source = its stamp chain).
    private var versionCount: Int {
        if case .version(let id) = activeRef,
           let jid = store.versions.first(where: { $0.id == id })?.journalID {
            return store.versions(forJournal: jid).count
        }
        return store.sourceStamps.count
    }

    var body: some View {
        List(selection: $selection) {
            if manuscript != nil {
                manuscriptSection
                journalSection
                contentSection
            }
        }
        // Show manuscript title in the sidebar header; it stays there always.
        .navigationTitle(manuscript?.title ?? "Manuscript Editor")
        .navigationSubtitle(saveSubtitle)
        // Settings gear pinned to the bottom of the sidebar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 4) {
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("App Settings")

                    appearanceMenu

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    // MARK: - Appearance quick toggle

    private var currentAppearance: AppearanceMode {
        AppearanceMode(rawValue: appearance) ?? .system
    }

    private var appearanceMenu: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: currentAppearance.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance: \(currentAppearance.label)")
    }

    // MARK: - Manuscript section (overview + meta)

    @ViewBuilder
    private var manuscriptSection: some View {
        Section("Manuscript") {
            Label("Overview", systemImage: "doc.text.magnifyingglass")
                .tag(SidebarItem.overview)
            Label("Data (\(manuscript?.dataAssets.count ?? 0))", systemImage: "externaldrive")
                .tag(SidebarItem.data)
            // Sync is manuscript-level: saving (local/remote), syncing
            // between journals, and adding journals.
            Label("Log", systemImage: "list.bullet.rectangle")
                .tag(SidebarItem.log)
            // Manuscript-scoped settings, split by concern; app-wide settings
            // stay in Preferences (gear below).
        }
    }

    // MARK: - Journal section (per-journal: checks, export, versions)

    @ViewBuilder
    private var journalSection: some View {
        Section("Journal") {
            row(SidebarItem.checks, checksTitle, "checklist")
            row(SidebarItem.export, "Export", "square.and.arrow.up")
            row(SidebarItem.versions, "Versions (\(versionCount))", "arrow.triangle.branch")
        }
    }

    /// "Checks (86%)" — the active journal's live pass rate; plain
    /// "Checks" for Source or when nothing is configured.
    private var checksTitle: String {
        guard case .version(let id) = activeRef,
              let jid = store.versions.first(where: { $0.id == id })?.journalID,
              let journal = store.manuscript?.journals.first(where: { $0.id == jid }),
              let content = store.manuscript(for: activeRef)
        else { return "Checks" }
        let results = ChecklistService.run(manuscript: content, journal: journal)
        guard !results.isEmpty else { return "Checks" }
        let pct = Int((Double(results.filter(\.passed).count) / Double(results.count) * 100).rounded())
        return "Checks (\(pct)%)"
    }

    /// A sidebar row: label plus the trailing comment bubble (only once the
    /// item has comments — the pane header's bubble adds the first one).
    private func row(_ item: SidebarItem, _ title: String, _ icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            checkBadge(item)
            notesBadge(item)
        }
        .tag(item)
    }

    /// A red dot on any pane a failing check covers — a word limit that's
    /// been exceeded shows on the section itself, not just in Checks.
    @ViewBuilder
    private func checkBadge(_ item: SidebarItem) -> some View {
        if let key = scopeKey(for: item), checkStatus[key] == false {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help("A check for this section is failing — see Checks")
        }
    }

    /// Maps a sidebar pane to the check scope that covers it.
    private func scopeKey(for item: SidebarItem) -> String? {
        switch item {
        case .title:          return CheckScope(kind: .title).key
        case .authors:        return CheckScope(kind: .authors).key
        case .abstract:       return CheckScope(kind: .abstract).key
        case .keywords:       return CheckScope(kind: .keywords).key
        case .figures:        return CheckScope(kind: .figures).key
        case .tables:         return CheckScope(kind: .tables).key
        case .bibliography:   return CheckScope(kind: .references).key
        case .letterToEditor: return CheckScope(kind: .coverLetter).key
        case .section(let id):
            guard let title = store.manuscript?.sections.first(where: { $0.id == id })?.title
            else { return nil }
            return CheckScope(kind: .section, name: title).key
        default: return nil
        }
    }

    /// Scope pass/fail for the ACTIVE journal (Source has no requirements,
    /// so its panes never carry a check badge).
    private var checkStatus: [String: Bool] {
        guard case .version(let id) = activeRef,
              let jid = store.versions.first(where: { $0.id == id })?.journalID,
              let journal = store.manuscript?.journals.first(where: { $0.id == jid }),
              let content = store.manuscript(for: activeRef)
        else { return [:] }
        return ChecklistService.scopeStatus(manuscript: content, journal: journal,
                                            figureURL: { store.figureURL(for: $0) })
    }

    /// Blue comment bubble opening the notes popover — shown only while the
    /// item has UNRESOLVED comments in the active version (checked-off
    /// comments are done and need no attention flag).
    @ViewBuilder
    private func notesBadge(_ item: SidebarItem) -> some View {
        if store.openNoteCount(versionKey: activeRef.id, itemKey: item.notesKey) > 0 {
            NotesButton(versionKey: activeRef.id, itemKey: item.notesKey,
                        idleColor: .blue)
        }
    }

    // MARK: - Content section

    /// The fixed content panes: key (persistence), default name, icon, item.
    private var fixedPanes: [(key: String, name: String, icon: String, item: SidebarItem)] {
        [("figures",      "Figures (\(active?.figures.count ?? 0))",           "photo.on.rectangle.angled", .figures),
         ("tables",       "Tables (\(active?.tables.count ?? 0))",             "tablecells",                .tables),
         ("bibliography", "Bibliography (\(active?.bibliography.count ?? 0))", "books.vertical",            .bibliography),
         ("letter",       "Letter to Editor",                                  "envelope",                  .letterToEditor)]
    }

    /// Default (count-free) name of a fixed pane, for rename prompts.
    private func defaultPaneName(_ key: String) -> String {
        switch key {
        case "figures": return "Figures"
        case "tables": return "Tables"
        case "bibliography": return "Bibliography"
        default: return "Letter to Editor"
        }
    }

    /// Content splits in two.  FIRST the parts every manuscript has, in a
    /// fixed order — they can't be reordered or switched off, because a
    /// manuscript without a title or a bibliography isn't a manuscript.
    /// THEN, past a soft rule, the sections the author actually shapes:
    /// drag to reorder, deactivate per journal, rename, delete.
    @ViewBuilder
    private var contentSection: some View {
        Section("Content") {
            row(SidebarItem.title, "Title", "textformat")
            row(SidebarItem.authors, "Authors (\(active?.authors.count ?? 0))", "person.2")
            row(SidebarItem.abstract, "Abstract", "text.quote")
            row(SidebarItem.keywords, "Keywords (\(active?.keywords.count ?? 0))", "tag")
            ForEach(fixedPanes, id: \.key) { pane in
                fixedPaneRow(pane)
            }

            sectionsDelimiter

            bodySection

            // Inline "add section" row at the very bottom of the Content list.
            addSectionRow
        }
    }

    /// The soft rule between the two halves — a hairline, not a header: the
    /// split is meant to be felt, not announced.
    private var sectionsDelimiter: some View {
        Divider()
            .padding(.vertical, 2)
            .opacity(0.6)
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .accessibilityLabel("Sections")
    }

    /// A fixed pane row with rename/remove context actions (mirrors sections).
    private func fixedPaneRow(_ pane: (key: String, name: String, icon: String, item: SidebarItem)) -> some View {
        // A custom name replaces the default, keeping the count suffix.
        let custom = store.manuscript?.paneTitles?[pane.key]
        let display = custom.map { name in
            pane.name.contains("(") ? "\(name) (\(pane.name.split(separator: "(").last?.dropLast() ?? ""))" : name
        } ?? pane.name
        return HStack {
            Label(display, systemImage: pane.icon)
            Spacer()
            checkBadge(pane.item)
            notesBadge(pane.item)
        }
            .tag(pane.item)
            .contextMenu {
                Button("Rename…") {
                    renameDraft = custom ?? defaultPaneName(pane.key)
                    renamingPaneKey = pane.key
                }
            }
            .alert("Rename Pane", isPresented: Binding(
                get: { renamingPaneKey == pane.key },
                set: { if !$0 { renamingPaneKey = nil } }
            )) {
                TextField("Name", text: $renameDraft)
                Button("Rename") {
                    store.renamePane(pane.key, to: renameDraft == defaultPaneName(pane.key) ? "" : renameDraft)
                    renamingPaneKey = nil
                }
                Button("Cancel", role: .cancel) { renamingPaneKey = nil }
            } message: {
                Text("Renames this pane in the sidebar. Its contents are untouched.")
            }
    }

    @ViewBuilder
    private var bodySection: some View {
        ForEach(sortedSections) { section in
            sectionRow(section)
        }
        .onMove  { store.moveSections(from: $0, to: $1) }
        .onDelete { store.deleteSections(at: $0) }
    }

    private var addSectionRow: some View {
        Button {
            if let id = store.addSection() { selection = .section(id) }
        } label: {
            Label("Add Section", systemImage: "plus")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Add a section (shared across all journals; deactivate per journal in its editor)")
    }

    // MARK: - Row helpers

    private func sectionRow(_ section: ManuscriptSection) -> some View {
        // Activation is PER JOURNAL, so it reads from the active tab's copy
        // rather than from Source's.
        let isActive = active?.sections.first { $0.id == section.id }?.active ?? section.active
        return HStack {
            Label(section.title, systemImage: section.type.systemImage)
                .foregroundStyle(isActive ? .primary : .tertiary)
            Spacer()
            if !isActive {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("Deactivated in this journal — its text is kept")
            }
            notesBadge(.section(section.id))
        }
        .tag(SidebarItem.section(section.id))
        // Reliable delete affordances (macOS swipe can be non-obvious).
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteSection(section) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button("Rename Section…") {
                renameDraft = section.title
                renamingSectionID = section.id
            }
            Button(isActive ? "Deactivate in This Journal" : "Activate in This Journal") {
                store.setSectionActive(!isActive, id: section.id, ref: activeRef)
            }
            Button("Delete Section", role: .destructive) { deleteSection(section) }
        }
        .alert("Rename Section", isPresented: Binding(
            get: { renamingSectionID == section.id },
            set: { if !$0 { renamingSectionID = nil } }
        )) {
            TextField("Section title", text: $renameDraft)
            Button("Rename") {
                store.renameSection(id: section.id, title: renameDraft)
                renamingSectionID = nil
            }
            Button("Cancel", role: .cancel) { renamingSectionID = nil }
        } message: {
            Text("Renames this section in every journal (shared structure).")
        }
    }

    private func deleteSection(_ section: ManuscriptSection) {
        if selection == .section(section.id) { selection = .overview }
        store.deleteSection(id: section.id)
    }

    private var sortedSections: [ManuscriptSection] {
        (manuscript?.sections ?? []).sorted { $0.order < $1.order }
    }

    private var saveSubtitle: String {
        var parts: [String] = []
        if let saved = store.lastSaved {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .abbreviated
            parts.append("Saved \(fmt.localizedString(for: saved, relativeTo: Date()))")
        }
        // Remote push/pull state rides along quietly (errors alert instead).
        if store.isRemoteBusy {
            parts.append("Syncing with remote…")
        } else if let remote = store.remoteStatus {
            parts.append(remote)
        }
        return parts.joined(separator: " · ")
    }
}
