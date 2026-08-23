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
import UniformTypeIdentifiers

// MARK: - SidebarItem

enum SidebarItem: Hashable {
    // ── Manuscript ──────────────────────────────────────────────────────────
    case overview
    case log
    case checks
    case export
    case data
    case versions

    // ── Content ─────────────────────────────────────────────────────────────
    case title
    case authors
    case abstract
    case keywords
    case section(UUID)
    case figures
    case tables
    case bibliography
    case letterToEditor

    /// Content items are editable prose/component views.
    var isContent: Bool {
        switch self {
        case .title, .authors, .abstract, .keywords, .section,
             .figures, .tables, .bibliography, .letterToEditor:
            return true
        case .overview, .log, .checks, .export, .data, .versions:
            return false
        }
    }

    /// Comparable items render one pane per open journal tab in side-by-side.
    /// This is the Content items plus the per-journal panes — **Checks**,
    /// **Versions**, and **Export** — each pane representing its own tab's
    /// journal (starting with Source), with no journal picker of its own.
    var isComparable: Bool {
        isContent || self == .checks || self == .versions || self == .export
    }

    /// Stable key used to anchor `Note`s to this content item.
    var notesKey: String {
        switch self {
        case .overview:           return "overview"
        case .log:                return "log"
        case .checks:             return "checks"
        case .export:             return "export"
        case .data:               return "data"
        case .versions:           return "versions"
        case .title:              return "title"
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

// MARK: - JournalTab

/// One tab in the journal tab bar.  Tabs are journal-identity based (not
/// version ids), so a stamp/sync/rollback that moves a journal's head never
/// invalidates a tab — it just resolves to the new head.
enum JournalTab: Hashable, Identifiable {
    case source
    case journal(UUID)

    var id: String {
        switch self {
        case .source:           return "source"
        case .journal(let id):  return id.uuidString
        }
    }
}

/// How the tab bar presents journals: one active pane, or side-by-side.
enum TabViewMode: String, CaseIterable {
    case active  = "Active"
    case compare = "Compare"
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore
    @Environment(\.undoManager)        private var windowUndoManager
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var selection: SidebarItem? = .overview

    /// Tab presentation: one active journal, or a side-by-side comparison of
    /// an explicit subset.  Tabs themselves load automatically (Source +
    /// every journal) — they are never added or removed by hand.
    @State private var tabMode: TabViewMode = .active
    @State private var activeTab: JournalTab = .source
    @State private var compareTabs: [JournalTab] = [.source]

    /// Drives the NSOpenPanel shown before a new manuscript is created.
    @State private var showingFolderPicker = false

    /// Drives the Export sheet (File → Export Submission Package…).
    @State private var showingExport = false

    /// A requested "new manuscript" awaiting the unsaved-work confirmation.
    enum PendingNew: String, Identifiable {
        case file, remote, openLocal
        var id: String { rawValue }
    }
    @State private var pendingNew: PendingNew?
    /// Drives the Open Manuscript (Remote) sheet.
    @State private var showingNewRemote = false
    /// Open/Export project failures (bad folder, zip error).
    @State private var projectError: String?

    /// Every tab, in stable order: Source first, then journals in manuscript
    /// order.  Loaded automatically — adding a journal (Sync pane) adds its
    /// tab; there is no manual tab management.
    private var allTabs: [JournalTab] {
        [.source] + (store.manuscript?.journals ?? []).map { .journal($0.id) }
    }

    /// The tabs whose panes are currently rendered.
    private var displayedTabs: [JournalTab] {
        switch tabMode {
        case .active:  return [activeTab]
        case .compare: return allTabs.filter { compareTabs.contains($0) }
        }
    }

    /// A tab's content reference: Source is the live manuscript; a journal
    /// resolves to its current working head (nil = the journal has no
    /// versions yet).
    private func ref(for tab: JournalTab) -> VersionRef? {
        switch tab {
        case .source:
            return .source
        case .journal(let id):
            return store.latestVersion(forJournal: id).map { .version($0.id) }
        }
    }

    var body: some View {
        dialogLayer(notificationLayer(splitView))
            // Document-level undo (store snapshots) registers with the key
            // window's manager so ⌘Z routes there whenever no text view
            // claims it first.
            .onAppear { store.activeUndoManager = windowUndoManager }
            .onChange(of: controlActiveState) { _, state in
                if state == .key { store.activeUndoManager = windowUndoManager }
            }
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, activeRef: ref(for: activeTab) ?? .source)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 290)
        } detail: {
            if store.manuscript != nil {
                VStack(spacing: 0) {
                    JournalTabBar(
                        allTabs: allTabs,
                        mode: $tabMode,
                        activeTab: $activeTab,
                        compareTabs: $compareTabs
                    )
                    Divider()
                    detailPaneContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The window title is the manuscript's name (not the app name).
                .navigationTitle(windowTitle)
                // Title-bar chrome: notification banner centered, save status
                // in the otherwise-empty top-right corner.
                .toolbar {
                    // Breadcrumb (issue #20): "Manuscripts ›" before the
                    // window title reads as "Manuscripts > <name>"; clicking
                    // it saves + closes back to the manager, exactly like
                    // File → Manage Manuscripts….
                    ToolbarItem(placement: .navigation) {
                        Button {
                            store.closeToWelcome()
                            resetWorkspace()
                        } label: {
                            HStack(spacing: 3) {
                                Text("Manuscripts")
                                    .underline(hoveringBreadcrumb)
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                            // Link-blue + underline-on-hover + pointing hand:
                            // unmistakably clickable, never a bubble.
                            .foregroundStyle(hoveringBreadcrumb ? Color.accentColor.opacity(0.75)
                                                                : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            hoveringBreadcrumb = hovering
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        .help("Back to Manage Manuscripts (saves and closes this manuscript)")
                    }
                    .sharedBackgroundVisibility(.hidden)
                    // Plain text in the title bar — no liquid-glass bubbles.
                    ToolbarItem(placement: .principal) { ToolbarBanner() }
                        .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) { SaveStatusIndicator() }
                        .sharedBackgroundVisibility(.hidden)
                }
            } else {
                WelcomeView(onNewManuscript: createInAppData,
                            onOpenLocal: openLocalFolder,
                            onOpenRemote: { showingNewRemote = true })
                    .navigationTitle("Manuscript Editor")
            }
        }
        .textSelection(.disabled)
        .onAppear {
            // The app always launches on the Welcome screen (the project
            // manager) — manuscripts open from there, never automatically.
            appStore.load()
            SigningService.debugProbe()   // container-side keyring trace
        }
        // A removed journal must not leave a dangling tab selection.
        .onChange(of: allTabs) { _, tabs in
            if !tabs.contains(activeTab) { activeTab = .source }
            compareTabs = compareTabs.filter(tabs.contains)
            if compareTabs.isEmpty { compareTabs = [.source] }
        }
    }

    /// Menu-bar notifications (split out to keep type-checking fast; two
    /// halves — one chain grew past what the type-checker will solve).
    private func notificationLayer(_ content: some View) -> some View {
        notificationLayerB(notificationLayerA(content))
    }

    private func notificationLayerA(_ content: some View) -> some View {
        content
        .onReceive(NotificationCenter.default.publisher(for: .newManuscript)) { _ in
            if store.manuscript == nil { createInAppData() } else { pendingNew = .file }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openManuscriptLocal)) { _ in
            if store.manuscript == nil { openLocalFolder() } else { pendingNew = .openLocal }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportProject)) { _ in
            exportProjectZip()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newManuscriptRemote)) { _ in
            if store.manuscript == nil { showingNewRemote = true } else { pendingNew = .remote }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveManuscript)) { _ in
            store.trySave()
            if let error = store.saveError {
                store.showBanner(.error, "Local save failed: \(error)")
            } else if store.manuscript != nil {
                store.showBanner(.success, "Saved to disk at \((store.lastSaved ?? Date()).formatted(date: .omitted, time: .standard)).")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .manageManuscripts)) { _ in
            // Manage = the Welcome screen: save + close the current
            // manuscript so nothing you're loaded on can be deleted.
            store.closeToWelcome()
            resetWorkspace()
        }
    }

    private func notificationLayerB(_ content: some View) -> some View {
        content
        // Repo existence check on manuscript load — drives Overview's
        // adaptive Remote controls (Save|Load vs Create).
        .onChange(of: store.manuscript?.id) { _, _ in
            store.validateRemoteRepository(appStore: appStore)
        }
        // Citation-format changes from a token's context menu.
        .onReceive(NotificationCenter.default.publisher(for: .setCitationFormat),
                   perform: applyCitationFormat)
        .onReceive(NotificationCenter.default.publisher(for: .exportManuscript)) { _ in
            if store.manuscript != nil { showingExport = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveToRemote)) { _ in
            store.saveToRemote(appStore: appStore)
        }
        // ⌘⇧←/→ cycles the active journal tab.
        .onReceive(NotificationCenter.default.publisher(for: .previousJournalTab)) { _ in
            cycleActiveTab(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextJournalTab)) { _ in
            cycleActiveTab(by: 1)
        }
    }

    /// Alerts, dialogs, and sheets (split out to keep type-checking fast).
    private func dialogLayer(_ content: some View) -> some View {
        content
        .alert("Project Error", isPresented: Binding(
            get: { projectError != nil },
            set: { if !$0 { projectError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(projectError ?? "")
        }
        // Remote successes AND failures surface in the toolbar banner.
        .sheet(isPresented: $showingExport) {
            ExportSheet()
        }
        // Warn before leaving the current manuscript for a new one.
        .confirmationDialog(
            "Start a New Manuscript?",
            isPresented: Binding(get: { pendingNew != nil },
                                 set: { if !$0 { pendingNew = nil } })
        ) {
            Button("Proceed") {
                let kind = pendingNew
                pendingNew = nil
                switch kind {
                case .file:      createInAppData()
                case .remote:    showingNewRemote = true
                case .openLocal: openLocalFolder()
                case .none:      break
                }
            }
            Button("Cancel", role: .cancel) { pendingNew = nil }
        } message: {
            Text(newManuscriptWarning)
        }
        .sheet(isPresented: $showingNewRemote) {
            NewRemoteManuscriptSheet(isPresented: $showingNewRemote) {
                selection = .overview
                tabMode = .active
                activeTab = .source
                compareTabs = [.source]
            }
        }
    }

    /// Plain-language state of the manuscript being left behind.
    private var newManuscriptWarning: String {
        guard let m = store.manuscript else { return "" }
        var text = "\"\(m.title)\" is saved locally."
        if m.settings.activeBackendID != nil {
            if let synced = m.lastSyncedAt, m.updatedAt <= synced {
                text += " Its remote copy is up to date."
            } else {
                text += " It has changes NOT yet saved to its remote — use File → Save (Remote) first if you want them there."
            }
        }
        return text + " You can reopen it any time from the Welcome screen."
    }

    /// The manuscript's title, falling back to the app name when unnamed.
    /// Pointer over the "Manuscripts ›" breadcrumb (underline + dimmed tint).
    @State private var hoveringBreadcrumb = false

    private func applyCitationFormat(_ note: Notification) {
        guard let code = note.userInfo?["code"] as? String else { return }
        store.setCitationStyle(code)
    }

    private var windowTitle: String {
        let title = store.manuscript?.title.trimmingCharacters(in: .whitespaces) ?? ""
        return title.isEmpty ? "Manuscript Editor" : title
    }

    /// Moves the active tab left/right, wrapping (⌘⇧←/→).  Also snaps the
    /// bar back to Active mode — the shortcut is about driving one pane.
    private func cycleActiveTab(by delta: Int) {
        let tabs = allTabs
        guard !tabs.isEmpty else { return }
        tabMode = .active
        let current = tabs.firstIndex(of: activeTab) ?? 0
        activeTab = tabs[(current + delta + tabs.count) % tabs.count]
    }

    // MARK: - Detail pane

    /// For a comparable selection, render one pane per displayed tab (a
    /// single pane in Active mode; side-by-side, split evenly, in Compare
    /// mode); navigating the sidebar moves every pane together.  For
    /// manuscript-level items (Overview, Data, Sync, …) a single pane renders
    /// against the live Source.
    @ViewBuilder
    private var detailPaneContent: some View {
        if let sel = selection, sel.isComparable {
            HSplitView {
                ForEach(displayedTabs) { tab in
                    Group {
                        if let ref = ref(for: tab) {
                            versionPane(ref, item: sel)
                        } else {
                            ContentUnavailableView(
                                "No Versions Yet",
                                systemImage: "arrow.triangle.branch",
                                description: Text("This journal has no versions — add it a cut in Sync.")
                            )
                        }
                    }
                    .frame(minWidth: 320)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            DetailRouter(selection: $selection)
        }
    }

    /// One comparison pane: a slim header (word count, per-journal section
    /// activation, notes) over the editable content view bound to that
    /// version.  The selected item's name is NOT repeated here — the sidebar
    /// selection already names it; which journal a pane shows is carried by
    /// the tab chip above it (panes render in tab order).  Both Source and
    /// versions are fully editable.
    @ViewBuilder
    private func versionPane(_ ref: VersionRef, item: SidebarItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                deactivatedBadge(item: item, ref: ref)
                Spacer()
                if let words = wordCount(for: item, ref: ref) {
                    Label("\(words) words", systemImage: "text.word.spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                sectionActivationControl(item: item, ref: ref)
                SectionFormatButton(item: item, versionRef: ref)
                SectionPreviewButton(item: item, versionRef: ref)
                NotesButton(versionKey: ref.id, itemKey: item.notesKey)
            }
            // Align the header past the editor's line-number gutter so it
            // doesn't sit over the gutter's edge.
            .padding(.leading, EditorLayout.leftInset)
            .padding(.trailing, 12)
            .padding(.vertical, 7)

            contentView(for: item, ref: ref)
        }
        .id(ref)
    }

    /// A quiet "deactivated" marker for sections switched off in this journal —
    /// the only state the slim pane header still needs to carry.
    @ViewBuilder
    private func deactivatedBadge(item: SidebarItem, ref: VersionRef) -> some View {
        if case .section(let id) = item,
           let section = resolvedSection(id, ref), !section.active {
            Label("Deactivated in this journal", systemImage: "moon.zzz")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// The editable content view for a sidebar item, bound to a specific version.
    @ViewBuilder
    private func contentView(for item: SidebarItem, ref: VersionRef) -> some View {
        switch item {
        case .title:             TitleView(versionRef: ref)
        case .authors:           AuthorsView(versionRef: ref)
        case .abstract:          AbstractView(versionRef: ref)
        case .keywords:          KeywordsView(versionRef: ref)
        case .section(let id):   SectionEditorView(sectionID: id, versionRef: ref)
        case .figures:           FiguresView(versionRef: ref)
        case .tables:            TablesView(versionRef: ref)
        case .bibliography:      BibliographyView(versionRef: ref)
        case .letterToEditor:    LetterToEditorView(versionRef: ref)
        case .checks:            ChecksView(versionRef: ref)
        case .versions:          VersionsView(versionRef: ref)
        case .export:            ExportView(versionRef: ref)
        default:                 EmptyView()
        }
    }

    // MARK: - Folder picker

    /// File → New: a fresh manuscript in the app-data folder (move it later
    /// from Overview → Saving & Backend if you want it somewhere visible).
    private func createInAppData() {
        store.createNew()
        resetWorkspace()
    }

    /// File → Open (Local)…: point at an existing project folder; files are
    /// edited in place.
    private func openLocalFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open Manuscript Project"
        panel.message = "Choose a project folder containing manuscript.json."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let error = store.openLocal(folder: url) {
            projectError = error
        } else {
            resetWorkspace()
        }
    }

    /// File → Export Project…: the whole project as a reopenable zip.
    private func exportProjectZip() {
        guard let m = store.manuscript else { return }
        let panel = NSSavePanel()
        panel.title = "Export Project"
        panel.nameFieldStringValue = "\(m.title.isEmpty ? "Manuscript" : m.title).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let error = store.exportProject(to: url) {
            projectError = error
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func resetWorkspace() {
        selection = .overview
        tabMode   = .active
        activeTab = .source
        compareTabs = [.source]
    }
}

// MARK: - Toolbar chrome

/// The reusable notification slot centered in the title bar: sync results,
/// save confirmations, and future messages — green success / red failure,
/// auto-dismissing (see `ManuscriptStore.showBanner`).
struct ToolbarBanner: View {
    @Environment(ManuscriptStore.self) private var store

    var body: some View {
        Group {
            if let banner = store.banner {
                // Explicit icon + text: toolbars collapse `Label`s to their
                // icon, which swallowed the message.
                HStack(spacing: 6) {
                    Image(systemName: banner.kind == .success
                          ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    Text(banner.message)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(banner.kind == .success ? Color.green : .red)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background((banner.kind == .success ? Color.green : .red).opacity(0.12), in: Capsule())
                .help(banner.message)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 480)
        .animation(.easeInOut(duration: 0.2), value: store.banner?.message)
    }
}

/// Top-right corner: when the manuscript was last saved locally and last
/// pushed to its remote ("N/A" when no backend is configured).
struct SaveStatusIndicator: View {
    @Environment(ManuscriptStore.self) private var store

    /// Full date + time for both timestamps (the local one used to drop the
    /// date when it was today, which read as a different format from remote).
    private func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// " (2d 4h 12m ago)"-style suffix; "<1 min ago" under a minute.
    private func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        guard seconds >= 60 else { return " (<1 min ago)" }
        let minutes = Int(seconds / 60)
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        return " (\(parts.joined(separator: " ")) ago)"
    }

    var body: some View {
        if let m = store.manuscript {
            // The "ago" suffixes drift; re-render once a minute.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let localDate = store.lastSaved ?? m.updatedAt
                let local = time(localDate) + ago(localDate, now: context.date)
                let remote = m.settings.activeBackendID == nil
                    ? "N/A"
                    : time(m.lastSyncedAt) + ago(m.lastSyncedAt, now: context.date)
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive")
                    Text(local)
                    Text("/").foregroundStyle(.tertiary)
                    Image(systemName: "icloud")
                    Text(remote)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Last saved — locally \(local) · remote \(remote == "N/A" ? "not configured" : remote)")
            }
        }
    }
}

// MARK: - DetailRouter

struct DetailRouter: View {
    @Environment(ManuscriptStore.self) private var store
    @Binding var selection: SidebarItem?

    var body: some View {
        switch selection {
        case .overview, .none:      OverviewView()
        case .log:                  LogView()
        case .checks:               ChecksView()
        case .export:               ExportView()
        case .data:                 DataView()
        case .versions:             VersionsView()
        case .title:                TitleView()
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

/// Browser-style journal tab bar.  Tabs load automatically (Source + every
/// journal) and are never opened/closed by hand.  A mode toggle switches
/// between **Active** (one highlighted tab drives a single pane; ⌘⇧←/→
/// cycles) and **Compare** (each tab gains a +/x affordance to include or
/// remove it from the side-by-side split).
struct JournalTabBar: View {
    @Environment(ManuscriptStore.self) private var store

    let allTabs: [JournalTab]
    @Binding var mode: TabViewMode
    @Binding var activeTab: JournalTab
    @Binding var compareTabs: [JournalTab]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(allTabs) { tab in
                        tabButton(for: tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Divider().frame(height: 20)

            Picker("", selection: $mode) {
                ForEach(TabViewMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .padding(.horizontal, 8)
            .help("Active: one journal at a time (⌘⇧←/→ to switch). Compare: pick tabs with + to view side-by-side.")
        }
        .frame(height: 36)
        // No material behind the strip — .bar rendered as a lighter glassy
        // bubble over the tabs in dark mode; the divider below is enough.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func label(for tab: JournalTab) -> String {
        switch tab {
        case .source:
            return "Source"
        case .journal(let id):
            return store.manuscript?.journals.first { $0.id == id }?.name ?? "Journal"
        }
    }

    private func icon(for tab: JournalTab) -> String {
        tab == .source ? "doc.text" : "building.columns"
    }

    /// Whether the tab currently contributes a pane.
    private func isShown(_ tab: JournalTab) -> Bool {
        switch mode {
        case .active:  return tab == activeTab
        case .compare: return compareTabs.contains(tab)
        }
    }

    @ViewBuilder
    private func tabButton(for tab: JournalTab) -> some View {
        let shown = isShown(tab)
        HStack(spacing: 5) {
            Image(systemName: icon(for: tab))
                .font(.caption2)
                .foregroundStyle(shown ? .primary : .secondary)
            Text(label(for: tab))
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(shown ? .primary : .secondary)

            // Compare mode: + to include, x to remove (last pane can't go).
            if mode == .compare {
                if shown {
                    Button {
                        compareTabs.removeAll { $0 == tab }
                        if compareTabs.isEmpty { compareTabs = [.source] }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove from comparison")
                } else {
                    Button {
                        compareTabs.append(tab)
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add to comparison")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Browser-tab look: the shown tab(s) sit on a lighter raised surface.
        .background(
            shown ? AnyShapeStyle(Color(nsColor: .textBackgroundColor)) : AnyShapeStyle(.clear),
            in: UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: 7)
        )
        .overlay(alignment: .bottom) {
            if shown {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            switch mode {
            case .active:
                activeTab = tab
            case .compare:
                if !compareTabs.contains(tab) { compareTabs.append(tab) }
            }
        }
        .help(label(for: tab))
    }
}
