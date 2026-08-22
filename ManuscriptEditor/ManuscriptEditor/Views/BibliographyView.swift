// BibliographyView.swift
//
// Two-pane view for managing the manuscript's reference list.
//
// Layout (HSplitView):
//   LEFT   — searchable list of references grouped by type, "Add Reference" button
//   RIGHT  — BibEntryEditor form for the selected reference
//
// References are grouped by `BibEntryType` (Journal Article, Book, etc.) and sorted
// newest-first within each group.  The search bar filters across title, authors,
// citation key, and journal name.

import SwiftUI

// MARK: - BibliographyView

/// The bibliography panel: searchable reference list on the left, editor on the right.
struct BibliographyView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    /// UUID of the currently selected reference.
    @State private var selectedID: UUID?
    /// Text typed in the search bar; empty means show all.
    @State private var searchText = ""
    /// Drives the Zotero import sheet.
    @State private var showZoteroImport = false

    /// The local Zotero library, fetched once per appearance (nil =
    /// unreachable / not yet loaded) — drives the per-entry link status.
    @State private var zoteroLibrary: [ZoteroItem]? = nil

    /// A locked entry's live relationship to the local Zotero library.
    enum ZoteroStatus {
        case unlocked          // normal editable reference (grey open lock)
        case linked(ZoteroItem)  // found in the library (green lock)
        case broken            // locked but not found (orange lock)
        case unknown           // Zotero not reachable / still loading
    }

    private func zoteroStatus(_ entry: BibEntry) -> ZoteroStatus {
        guard entry.isZoteroLocked else { return .unlocked }
        guard let items = zoteroLibrary else { return .unknown }
        if let hit = Self.zoteroMatch(for: entry, in: items) { return .linked(hit) }
        return .broken
    }

    /// The matching ladder: key > DOI > title+authors > URL.  Found matches
    /// are never written back to the entry — the link stays dynamic.
    static func zoteroMatch(for entry: BibEntry, in items: [ZoteroItem]) -> ZoteroItem? {
        if let key = entry.zoteroKey, let hit = items.first(where: { $0.key == key }) { return hit }
        func normDOI(_ raw: String?) -> String? {
            guard var d = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !d.isEmpty else { return nil }
            for prefix in ["https://doi.org/", "http://doi.org/", "doi:"]
                where d.hasPrefix(prefix) { d = String(d.dropFirst(prefix.count)) }
            return d
        }
        if let doi = normDOI(entry.doi),
           let hit = items.first(where: { normDOI($0.doi) == doi }) { return hit }
        let title = entry.title.lowercased().trimmingCharacters(in: .whitespaces)
        if !title.isEmpty {
            let lastName = entry.authors.first?.components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if let hit = items.first(where: { item in
                item.title.lowercased().trimmingCharacters(in: .whitespaces) == title
                    && (lastName.isEmpty || item.creators.first?.lastName.lowercased() == lastName)
            }) { return hit }
        }
        if let url = entry.url?.lowercased(), !url.isEmpty,
           let hit = items.first(where: { $0.url?.lowercased() == url }) { return hit }
        return nil
    }

    /// The CSL style for this pane's journal (Source and custom → APA).
    private var cslStyle: String {
        guard case .version(let id) = versionRef,
              let jid = store.versions.first(where: { $0.id == id })?.journalID,
              let journal = store.manuscript?.journals.first(where: { $0.id == jid })
        else { return "apa" }
        switch journal.requirements.citationStyle {
        case .apa:       return "apa"
        case .mla:       return "modern-language-association"
        case .chicago:   return "chicago-author-date"
        case .vancouver: return "vancouver"
        case .harvard:   return "harvard-cite-them-right"
        case .ama:       return "american-medical-association"
        case .custom:    return "apa"
        }
    }

    private func loadZoteroLibrary() async {
        zoteroLibrary = try? await ZoteroService().fetchItems(matching: "", limit: 500)
    }

    /// "Refresh from Zotero" (Add Reference menu): every locked entry with a
    /// live match re-pulls its fields from the library.  Stored keys are
    /// never added or rewritten — matching stays dynamic.
    private func refreshFromZotero() {
        Task {
            guard let items = try? await ZoteroService().fetchItems(matching: "", limit: 500) else {
                store.showBanner(.error, "Zotero isn't reachable — is it running with \"Allow other applications\" enabled?")
                return
            }
            zoteroLibrary = items
            let service = ZoteroService()
            // Zotero's citation processor formats every entry in the pane
            // journal's style (org authors, italics, access dates).
            let style = cslStyle
            let formatted = (try? await service.formattedBibliography(style: style)) ?? [:]
            var refreshed = 0, broken = 0
            for entry in allEntries where entry.isZoteroLocked {
                guard let item = Self.zoteroMatch(for: entry, in: items) else { broken += 1; continue }
                let fresh = service.bibEntry(from: item)
                var updated = entry
                updated.type = fresh.type
                updated.authors = fresh.authors
                updated.title = fresh.title
                updated.year = fresh.year
                updated.journal = fresh.journal
                updated.volume = fresh.volume
                updated.issue = fresh.issue
                updated.pages = fresh.pages
                updated.doi = fresh.doi
                updated.url = fresh.url
                updated.publisher = fresh.publisher
                if let bib = formatted[item.key] {
                    updated.formattedReference = bib
                    updated.formattedStyle = style
                }
                if updated != entry {
                    store.updateBibEntry(updated, ref: versionRef)
                    refreshed += 1
                }
            }
            let skipped = broken > 0 ? " \(broken) locked entr\(broken == 1 ? "y has" : "ies have") no Zotero match (orange) and kept their saved data." : ""
            store.showBanner(.success, "Refreshed \(refreshed) Zotero reference\(refreshed == 1 ? "" : "s") from your library.\(skipped)")
        }
    }
    /// Drives the add-by-URL sheet.
    @State private var showURLSheet = false

    /// All references, filtered by `searchText`.
    private var entries: [BibEntry] {
        let all = store.manuscript(for: versionRef)?.bibliography ?? []
        guard !searchText.isEmpty else { return all }
        let q = searchText.lowercased()
        return all.filter {
            $0.title.lowercased().contains(q) ||
            $0.authorsFormatted.lowercased().contains(q) ||
            $0.key.lowercased().contains(q) ||
            ($0.journal?.lowercased().contains(q) ?? false)
        }
    }

    private var allEntries: [BibEntry] {
        store.manuscript(for: versionRef)?.bibliography ?? []
    }

    var body: some View {
        Group {
        if allEntries.isEmpty && searchText.isEmpty {
            emptyState
        } else {
            HSplitView {
                // MARK: Left — searchable list
                VStack(spacing: 0) {
                    searchBar
                    Divider()

                    if entries.isEmpty {
                        VStack { Spacer(); Text("No results").foregroundStyle(.tertiary); Spacer() }
                            .frame(maxWidth: .infinity)
                    } else {
                        // Flat list in bibliography order.  Cited entries are
                        // pinned to the top in citation order automatically;
                        // dragging arranges the uncited tail (a dragged cited
                        // entry snaps back to its citation position).
                        let index = store.citationIndex(ref: versionRef)
                        List(selection: $selectedID) {
                            ForEach(entries) { entry in
                                entryRow(entry,
                                         number: index.numbers[entry.id],
                                         citedCount: index.counts[entry.id])
                                    .tag(entry.id)
                            }
                            .onMove { source, destination in
                                // Reordering only makes sense on the unfiltered list.
                                guard searchText.isEmpty else { return }
                                store.moveBibEntries(from: source, to: destination, ref: versionRef)
                            }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.windowBackgroundColor))
                        .onAppear { autoSelect() }
                        .onChange(of: entries.map(\.id)) { _, _ in autoSelect() }
                    }

                    Divider()

                    HStack(spacing: 2) {
                        addReferenceMenu
                            .padding(.leading, 10).padding(.vertical, 10)
                        Spacer()
                        Text("\(allEntries.count) reference\(allEntries.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 10)
                    }
                    .background(Color(NSColor.windowBackgroundColor))
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))

                // MARK: Right — reference editor
                if let id = selectedID,
                   let entry = store.manuscript(for: versionRef)?.bibliography.first(where: { $0.id == id }) {
                    BibEntryEditor(entry: entry, versionRef: versionRef)
                } else {
                    Color.clear
                }
            }
        }
        }
        .task { await loadZoteroLibrary() }
        .sheet(isPresented: $showZoteroImport) {
            ZoteroImportSheet(versionRef: versionRef)
        }
        .sheet(isPresented: $showURLSheet) {
            AddReferenceByURLSheet(versionRef: versionRef) { newID in
                selectedID = newID
            }
        }
    }

    /// "Add Reference" as a menu: Manual, From Zotero…, or From URL….
    private var addReferenceMenu: some View {
        Menu {
            Button("Manual") {
                store.addBibEntry(ref: versionRef)
                selectedID = store.manuscript(for: versionRef)?.bibliography.last?.id
            }
            Button("From Zotero…") { showZoteroImport = true }
            Button("From URL…") { showURLSheet = true }
            Divider()
            Button("Refresh from Zotero") { refreshFromZotero() }
        } label: {
            Label("Add Reference", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No References Yet")
                .font(.title3.weight(.semibold))
            Text("Add references manually, from Zotero, or by URL.")
                .foregroundStyle(.secondary)
            addReferenceMenu
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.secondary.opacity(0.12), in: Capsule())
            BibSearchBar(
                entries: allEntries,
                query: $searchText,
                onOpen: { selectedID = $0 },
                onAdd: { entry in
                    store.addBibEntry(entry, ref: versionRef)
                    selectedID = entry.id
                }
            )
            .frame(width: 320)
            .zIndex(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sub-views

    private var searchBar: some View {
        BibSearchBar(
            entries: allEntries,
            query: $searchText,
            onOpen: { selectedID = $0 },
            onAdd: { entry in
                store.addBibEntry(entry, ref: versionRef)
                // addBibEntry dedupes on zoteroKey, so resolve the id of
                // whichever entry actually represents this reference now.
                selectedID = store.manuscript(for: versionRef)?.bibliography.first(where: {
                    $0.id == entry.id
                        || ($0.zoteroKey != nil && $0.zoteroKey == entry.zoteroKey)
                })?.id
            }
        )
        .padding(8)
        // Above the List so the results dropdown paints over it.
        .zIndex(1)
    }

    /// The per-entry lock: state + live link status, hover info on every
    /// state, click to toggle.
    @ViewBuilder
    private func zoteroLockButton(_ entry: BibEntry) -> some View {
        let status = zoteroStatus(entry)
        Button {
            var updated = entry
            updated.zoteroLocked = !entry.isZoteroLocked
            store.updateBibEntry(updated, ref: versionRef)
        } label: {
            switch status {
            case .unlocked:
                Image(systemName: "lock.open").foregroundStyle(.secondary)
            case .linked:
                Image(systemName: "lock.fill").foregroundStyle(.green)
            case .broken:
                Image(systemName: "lock.fill").foregroundStyle(.orange)
            case .unknown:
                Image(systemName: "lock.fill").foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help({
            switch status {
            case .unlocked:
                return "Unlocked — a normal reference, editable in ME (originally from Zotero). Click to lock it back to your Zotero library."
            case .linked(let item):
                return "Locked to Zotero — matched in your library (\"\(item.title)\"). Read-only here; \"Refresh from Zotero\" pulls updates. Click to unlock and edit in ME."
            case .broken:
                return "Locked, but NOT found in your Zotero library (tried key, DOI, title+authors, URL). The saved data still cites and exports fine. Click to unlock and edit in ME."
            case .unknown:
                return "Locked to Zotero — link not checked (Zotero isn't reachable). The saved data still cites and exports fine."
            }
        }())
    }

    /// One row in the reference list: citation number (when cited), key, year,
    /// cited badge, title, first author.
    private func entryRow(_ entry: BibEntry, number: Int? = nil, citedCount: Int? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Uncited references are hand-arranged — show the drag handle.
            // Cited ones sit in citation order and snap back if dragged, so
            // no handle (their [n] badge marks them).
            if number == nil {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .padding(.top, 3)
                    .help("Drag to arrange — uncited references keep the order you set")
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let number {
                        Text("[\(number)]")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.blue)
                            .help("Citation number \(number) — set by first citation in the text")
                    }
                    Text(entry.key.isEmpty ? "(no key)" : entry.key)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                    if let year = entry.year {
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.type.rawValue)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    if let citedCount {
                        Label("\(citedCount)", systemImage: "quote.opening")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                            .help("Cited \(citedCount) time\(citedCount == 1 ? "" : "s") in the text")
                    }
                }
                Text(entry.title.isEmpty ? "(no title)" : entry.title)
                    .font(.callout).lineLimit(2)
                if !entry.authorsFormatted.isEmpty {
                    Text(entry.authorsFormatted)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if entry.zoteroKey != nil {
                zoteroLockButton(entry)
            }
            Button {
                guard let idx = store.manuscript(for: versionRef)?.bibliography.firstIndex(where: { $0.id == entry.id }) else { return }
                store.deleteBibEntries(at: IndexSet([idx]), ref: versionRef)
                if selectedID == entry.id {
                    selectedID = store.manuscript(for: versionRef)?.bibliography.first(where: { $0.id != entry.id })?.id
                }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove reference")
        }
        .padding(.vertical, 2)
    }

    private func autoSelect() {
        let all = store.manuscript(for: versionRef)?.bibliography ?? []
        if selectedID == nil || !all.contains(where: { $0.id == selectedID }) {
            selectedID = all.first?.id
        }
    }
}

// MARK: - BibEntryEditor

/// Full form for editing all fields of one bibliography entry.
// MARK: - BibSearchBar

/// Categorized reference search (top of the Bibliography pane), the same
/// pattern as the Authors pane.  "Saved" text-matches existing entries —
/// clicking one opens it.  Source sections add with a +, chosen by input
/// shape: plain text searches Zotero, a DOI resolves full metadata via
/// doi.org (issue #9), and a web URL fetches the page title.  The query
/// doubles as the saved-list filter (same binding).
private struct BibSearchBar: View {
    let entries: [BibEntry]
    @Binding var query: String
    let onOpen: (UUID) -> Void
    let onAdd: (BibEntry) -> Void

    @State private var zoteroHits: [ZoteroItem] = []
    /// Resolved DOI or Web result (those sections hold at most one hit).
    @State private var lookupEntry: BibEntry?
    /// Which single-hit section is active: "DOI" or "Web".
    @State private var lookupSection: String?
    @State private var searching = false
    @State private var errorText: String?

    /// Existing entries every ≥2-letter term matches (key, title, authors,
    /// journal, year, or DOI).
    private var savedMatches: [BibEntry] {
        let terms = query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init).filter { $0.count >= 2 }
        guard !terms.isEmpty else { return [] }
        return entries.filter { entry in
            let hay = """
            \(entry.key) \(entry.title) \(entry.authorsFormatted) \
            \(entry.journal ?? "") \(entry.year.map(String.init) ?? "") \(entry.doi ?? "")
            """.lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    private var noMatches: Bool {
        savedMatches.isEmpty && zoteroHits.isEmpty && lookupEntry == nil
            && errorText == nil && !searching
            && query.trimmingCharacters(in: .whitespaces).count >= 3
    }

    private var dropdownVisible: Bool {
        !savedMatches.isEmpty || !zoteroHits.isEmpty || lookupEntry != nil
            || errorText != nil || noMatches
    }

    var body: some View {
        SearchDropdownBar(placeholder: "Search - text, DOI, or URL",
                          query: $query,
                          searching: searching,
                          dropdownVisible: dropdownVisible) {
            if !savedMatches.isEmpty {
                SearchSectionHeader(title: "Saved", count: savedMatches.count)
                ForEach(savedMatches) { entry in
                    SearchResultRow(
                        title: entry.title.isEmpty ? (entry.key.isEmpty ? "(untitled)" : entry.key)
                                                   : entry.title,
                        subtitle: [entry.authorsFormatted,
                                   entry.year.map(String.init) ?? "",
                                   entry.journal ?? ""]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                    ) {
                        onOpen(entry.id)
                        query = ""
                    }
                }
            }
            if let errorText {
                SearchNoteRow(text: errorText, color: .red)
            } else if let section = lookupSection, let entry = lookupEntry {
                SearchSectionHeader(title: section, count: 1)
                SearchResultRow(
                    icon: "plus.circle",
                    title: entry.title.isEmpty ? (entry.doi ?? entry.url ?? "(untitled)")
                                               : entry.title,
                    subtitle: [entry.authorsFormatted,
                               entry.year.map(String.init) ?? "",
                               entry.journal ?? entry.url ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                    linkURL: entry.url.flatMap(URL.init(string:))
                ) {
                    onAdd(entry)
                    query = ""
                }
            } else if !zoteroHits.isEmpty {
                SearchSectionHeader(title: "Zotero", count: zoteroHits.count)
                ForEach(zoteroHits) { item in
                    SearchResultRow(
                        icon: "plus.circle",
                        title: item.title,
                        subtitle: [item.creators.first?.formatted ?? "",
                                   item.date,
                                   item.publicationTitle ?? ""]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                    ) {
                        onAdd(ZoteroService().bibEntry(from: item))
                        query = ""
                    }
                }
            } else if noMatches {
                SearchNoteRow(text: "No matches in Zotero.")
            }
        }
        // Debounced source lookup, routed by input shape.
        .task(id: query) {
            errorText = nil
            zoteroHits = []
            lookupEntry = nil
            lookupSection = nil
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 3 else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                if let doi = ReferenceLookupService.extractDOI(text) {
                    lookupSection = "DOI"
                    lookupEntry = try await ReferenceLookupService().entry(forDOI: doi)
                } else if let url = ReferenceLookupService.webURL(text) {
                    lookupSection = "Web"
                    lookupEntry = try await ReferenceLookupService().entry(forWebPage: url)
                } else {
                    zoteroHits = try await ZoteroService().fetchItems(matching: text, limit: 20)
                }
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
        }
    }
}

struct BibEntryEditor: View {
    @Environment(ManuscriptStore.self) private var store
    let entry: BibEntry
    /// Which version this reference belongs to.
    var versionRef: VersionRef = .source

    /// Mutable working copy.
    @State private var draft: BibEntry
    /// Authors are edited as a multi-line TextEditor (one author per line).
    @State private var authorsText = ""

    init(entry: BibEntry, versionRef: VersionRef = .source) {
        self.entry = entry
        self.versionRef = versionRef
        _draft = State(initialValue: entry)
        _authorsText = State(initialValue: entry.authors.joined(separator: "\n"))
    }

    /// Zotero-imported references are managed in Zotero and shown read-only here.
    private var isReadOnly: Bool { entry.isZoteroLocked }

    var body: some View {
        ScrollView {
            if isReadOnly {
                Label("Locked to Zotero — read-only. Manage it in Zotero (\"Refresh from Zotero\" pulls changes), or click its lock in the list to unlock and edit here.",
                      systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .padding([.horizontal, .top], 16)
            }
            Form {
                citationsSection

                // Editable fields only — the citations summary above stays
                // interactive even for read-only (Zotero-managed) entries.
                Group {
                Section("Citation Key & Type") {
                    TextField("Citation key (e.g. Smith2023)", text: $draft.key)
                    Picker("Type", selection: $draft.type) {
                        ForEach(BibEntryType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                }

                // One author per line, "Last, First" format.
                Section("Authors (one per line, Last, First format)") {
                    PlainTextEditor(text: $authorsText)
                        .frame(minHeight: 80)
                        .onChange(of: authorsText) { _, new in
                            draft.authors = new.components(separatedBy: "\n")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        }
                }

                Section("Publication Details") {
                    TextField("Title", text: $draft.title)
                    LabeledContent("Year") {
                        TextField("Year", value: $draft.year, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Journal / Publisher",   text: optionalBinding(\.journal))
                    TextField("Volume",                text: optionalBinding(\.volume))
                    TextField("Issue / Number",        text: optionalBinding(\.issue))
                    TextField("Pages (e.g. 123–145)", text: optionalBinding(\.pages))
                }

                Section("Identifiers") {
                    HStack(spacing: 8) {
                        TextField("DOI", text: optionalBinding(\.doi))
                        // Once a DOI is entered, link straight to the paper
                        // (same affordance as the author editor's ORCID row).
                        if let doi = draft.doi?.trimmingCharacters(in: .whitespaces),
                           !doi.isEmpty,
                           let url = URL(string: "https://doi.org/\(doi)") {
                            Link(destination: url) {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .help("Open on doi.org")
                        }
                    }
                    TextField("URL", text: optionalBinding(\.url))
                }

                Section("Notes") {
                    PlainTextEditor(text: optionalBinding(\.note))
                        .frame(minHeight: 50)
                }
                }
                .disabled(isReadOnly)   // Zotero entries are read-only
            }
            .formStyle(.grouped)
            .padding(.bottom, 16)
        }
        .onChange(of: draft.key)        { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.type)       { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.title)      { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.authors)    { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.year)       { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.journal)    { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.volume)     { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.issue)      { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.pages)      { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.doi)        { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.url)        { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: draft.note)       { _, _ in store.updateBibEntry(draft, ref: versionRef) }
        .onChange(of: entry)            { _, new in
            // External change (selection switch or document undo).
            guard new != draft else { return }
            draft = new
            authorsText = new.authors.joined(separator: "\n")
        }
    }

    /// Where (and how often) this entry is cited in the text: citation number,
    /// then one row per prose field in document order.  Lives in the details —
    /// no extra list column needed.
    @ViewBuilder
    private var citationsSection: some View {
        let index = store.citationIndex(ref: versionRef)
        Section("Cited In") {
            if let number = index.numbers[entry.id] {
                LabeledContent("Citation number") {
                    Text("[\(number)]").font(.callout.weight(.semibold)).foregroundStyle(.blue)
                }
                ForEach(index.usage[entry.id] ?? [], id: \.location) { use in
                    LabeledContent(use.location) {
                        Text(use.count == 1 ? "once" : "×\(use.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Not cited in the text yet — type “/” in any prose field to reference it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Converts an `Optional<String>` key-path into a `Binding<String>` so SwiftUI
    /// TextFields can bind to optional properties without needing a separate `@State`.
    private func optionalBinding(_ keyPath: WritableKeyPath<BibEntry, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
