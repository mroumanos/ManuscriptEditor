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
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                .tag(SidebarItem.sync)
            // Manuscript-scoped settings, split by concern; app-wide settings
            // stay in Preferences (gear below).
            Label("Backend", systemImage: "externaldrive.connected.to.line.below")
                .tag(SidebarItem.manuscriptBackend)
            Label("AI", systemImage: "sparkles")
                .tag(SidebarItem.manuscriptAI)
        }
    }

    // MARK: - Journal section (per-journal: checks, export, versions)

    @ViewBuilder
    private var journalSection: some View {
        Section("Journal") {
            Label("Checks", systemImage: "checklist")
                .tag(SidebarItem.checks)
            Label("Export", systemImage: "square.and.arrow.up")
                .tag(SidebarItem.export)
            Label("Versions (\(versionCount))", systemImage: "arrow.triangle.branch")
                .tag(SidebarItem.versions)
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

    @ViewBuilder
    private var contentSection: some View {
        Section("Content") {
            Label("Title", systemImage: "textformat")
                .tag(SidebarItem.title)
            Label("Authors (\(active?.authors.count ?? 0))", systemImage: "person.2")
                .tag(SidebarItem.authors)
            Label("Abstract", systemImage: "text.quote")
                .tag(SidebarItem.abstract)
            Label("Keywords (\(active?.keywords.count ?? 0))", systemImage: "tag")
                .tag(SidebarItem.keywords)
            bodySection

            ForEach(fixedPanes, id: \.key) { pane in
                if !store.isPaneHidden(pane.key) {
                    fixedPaneRow(pane)
                }
            }

            // Inline "add section" row at the very bottom of the Content list.
            addSectionRow

            // Removed panes come back from here.
            ForEach(fixedPanes, id: \.key) { pane in
                if store.isPaneHidden(pane.key) {
                    Button {
                        store.setPaneHidden(pane.key, hidden: false)
                    } label: {
                        Label("Show \(store.paneTitle(pane.key, default: defaultPaneName(pane.key)))",
                              systemImage: "eye.slash")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Restore this pane to the sidebar")
                }
            }
        }
    }

    /// A fixed pane row with rename/remove context actions (mirrors sections).
    private func fixedPaneRow(_ pane: (key: String, name: String, icon: String, item: SidebarItem)) -> some View {
        // A custom name replaces the default, keeping the count suffix.
        let custom = store.manuscript?.paneTitles?[pane.key]
        let display = custom.map { name in
            pane.name.contains("(") ? "\(name) (\(pane.name.split(separator: "(").last?.dropLast() ?? ""))" : name
        } ?? pane.name
        return Label(display, systemImage: pane.icon)
            .tag(pane.item)
            .contextMenu {
                Button("Rename…") {
                    renameDraft = custom ?? defaultPaneName(pane.key)
                    renamingPaneKey = pane.key
                }
                Button("Remove from Sidebar", role: .destructive) {
                    if selection == pane.item { selection = .overview }
                    store.setPaneHidden(pane.key, hidden: true)
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
        HStack {
            Label(section.title, systemImage: section.type.systemImage)
            Spacer()
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
