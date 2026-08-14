// JournalLineageCard.swift
//
// The Journals & Lineage card, embedded in Overview (the Sync pane it grew
// out of was retired Aug 2026 — its saving buttons live in the Overview
// summary and its history in the Log pane).  Two jobs:
//
//   1. SYNCING  — fast-forward any journal from its upstream.  Every sync
//                 edge A→B is checksum-verified first: identical latest
//                 contents short-circuit to an "already in sync" banner, and
//                 an upstream whose latest drifted from its own last stamp
//                 refuses to sync until it's stamped (Versions tab) — lineage
//                 always hangs from frozen versions.
//   2. ADDING   — cut a new journal: FROM any journal (or Source), TO a
//                 journal profile from the app-settings library (or custom).
//                 The new journal appears in the lineage and gets a tab
//                 automatically.
//
// Lineage visual: children render contiguous with their parent — attached
// directly beneath it, tabbed on the left, right edges aligned.

import SwiftUI

struct JournalLineageCard: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    /// A sync awaiting confirmation: which journal, and which direction.
    struct PendingSync: Identifiable {
        let journal: Journal
        let forward: Bool
        var id: UUID { journal.id }
    }
    @State private var pendingSync: PendingSync?
    /// Smart mode: the AI adapts sections during the override (needs a
    /// Claude account with a stored key, selected in Manuscript → AI).
    @State private var smartSync = false
    @State private var showSmartInfo = false
    /// Journal awaiting the delete confirmation (context menu).
    @State private var pendingDelete: Journal?
    /// Lineage row under the pointer — interactive rows highlight on hover.
    @State private var hoveredJournalID: UUID?
    @State private var showAddJournal = false

    private var journals: [Journal] { store.manuscript?.journals ?? [] }
    private let cardWidth: CGFloat = 640
    private let indent: CGFloat = 28

    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Journals & Lineage")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle(isOn: $smartSync) {
                        Label("Smart", systemImage: "sparkles")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .disabled(!aiReady)
                    .help(aiReady
                          ? "Smart mode: the AI adapts sections to the target's requirements during a sync"
                          : "Needs a Claude account with a key (Settings → Accounts), selected in Manuscript → AI")
                    Button {
                        showSmartInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showSmartInfo, arrowEdge: .bottom) {
                        Text("""
                        Every sync is a full override in one direction:

                        ⏪  Fast-backward pushes this journal's latest \
                        content UP to its upstream.
                        ⏩  Fast-forward pulls the upstream's latest \
                        content DOWN into this journal.

                        The overridden side's previous content is stamped \
                        into its version history first, so either direction \
                        is recoverable.

                        With Smart on, the connected AI (Claude) rewrites \
                        each section toward the target's requirements as it \
                        copies — instead of a verbatim copy.
                        """)
                        .font(.callout)
                        .padding(16)
                        .frame(width: 340)
                    }
                    Button {
                        showAddJournal = true
                    } label: {
                        Label("Add Journal", systemImage: "plus")
                    }
                }
                .frame(maxWidth: cardWidth)

                lineageTree
        }
        .sheet(isPresented: $showAddJournal) {
            AddJournalSheet(isPresented: $showAddJournal)
        }
        // The sync confirmation, stating plainly whether AI is involved.
        // (Reached only after the checksum precheck says the edge is ready.)
        .alert(item: $pendingSync) { pending in
            syncAlert(pending)
        }
        .alert(item: $pendingDelete) { journal in
            Alert(
                title: Text("Delete \(journal.name)?"),
                message: Text("Removes the journal's tab and its whole version history from this manuscript"
                              + (store.manuscript?.settings.remoteRepository != nil
                                 ? ", and deletes its snapshot branch on the remote." : ".")
                              + " Source and other journals are untouched. This cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    if let error = store.deleteJournal(id: journal.id, appStore: appStore) {
                        showError(error)
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - 2/3. Lineage tree

    /// Journals depth-first under their upstream journal (Source = depth 0).
    private var flattenedTree: [(journal: Journal, depth: Int)] {
        var childrenByUpstream: [UUID?: [Journal]] = [:]
        for journal in journals {
            let upstream = store.syncSource(forJournal: journal.id)?.upstreamJournalID
            childrenByUpstream[upstream, default: []].append(journal)
        }
        var out: [(Journal, Int)] = []
        var visited = Set<UUID>()
        func walk(_ upstream: UUID?, depth: Int) {
            for child in childrenByUpstream[upstream] ?? [] where visited.insert(child.id).inserted {
                out.append((child, depth))
                walk(child.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        for journal in journals where !visited.contains(journal.id) {
            out.append((journal, 0))
        }
        return out
    }

    /// One connected container — the tree reads like a dropdown unfolding
    /// from Source: uniform row heights, children indented (narrower), rows
    /// separated by hairlines instead of being distinct boxes.
    private var lineageTree: some View {
        VStack(spacing: 0) {
            sourceRow
            ForEach(flattenedTree, id: \.journal.id) { entry in
                Divider()
                journalRow(entry.journal, depth: entry.depth)
            }
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
        .frame(width: cardWidth)
    }

    /// Uniform row height across Source and journal rows.
    private let rowHeight: CGFloat = 66

    // MARK: Source (root) row

    private var sourceRow: some View {
        let stamps = store.sourceStamps.count
        return HStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accentColor.opacity(0.1)))
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Source").font(.headline)
                    Text("v\(stamps)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Last edited \(store.manuscript?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: rowHeight)
    }

    // MARK: Journal rows

    /// The journal's lineage icon — configured per journal in the app
    /// settings library (falls back to the manuscript's own copy, then "?").
    private func journalIcon(_ journal: Journal) -> String {
        let name = appStore.journalLibrary.first(where: { $0.name == journal.name })?.icon
            ?? journal.icon
        if let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return "questionmark"
    }

    @ViewBuilder
    private func journalRow(_ journal: Journal, depth: Int = 0) -> some View {
        let head = store.latestVersion(forJournal: journal.id)
        let source = store.syncSource(forJournal: journal.id)

        HStack(spacing: 12) {
            // Curved branch arrow — the row's indent already conveys depth.
            Image(systemName: "arrow.turn.down.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)

            // The journal's configured icon (Settings → Journals).
            Image(systemName: journalIcon(journal))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                .overlay(Circle().strokeBorder(.primary.opacity(0.35), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(journal.name).font(.headline)
                    if head != nil {
                        let count = store.versions(forJournal: journal.id).count
                        Text("v\(count - 1)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    edgeBadge(for: head)
                }
                statusLine(journal, head: head, source: source)
            }

            Spacer()

            if head != nil {
                let upstreamName = source?.upstreamName ?? "upstream"
                let mode = smartSync ? "Smart" : "Fast"
                if store.isSmartSyncBusy { ProgressView().controlSize(.small) }
                Button {
                    pendingSync = PendingSync(journal: journal, forward: false)
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.bordered)
                .disabled(store.isSmartSyncBusy)
                .help("\(mode)-backward: override \(upstreamName) with \(journal.name)'s latest")
                Button {
                    // Checksum short-circuit: identical latest contents mean
                    // there is nothing to pull.
                    if case .alreadyInSync(let upstream) = store.syncPrecheck(forJournal: journal.id) {
                        showSuccess("\(journal.name) and \(upstream) are already in sync — their latest contents are identical.")
                        return
                    }
                    pendingSync = PendingSync(journal: journal, forward: true)
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.bordered)
                .disabled(store.isSmartSyncBusy)
                .help("\(mode)-forward: override \(journal.name) with \(upstreamName)'s latest")
            }
        }
        // Indent INSIDE the row (before the background) so the hover tint
        // spans the whole container width, not just the tabbed remainder.
        .padding(.leading, CGFloat(depth) * indent + 22)
        .padding(.trailing, 12)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        // Hover highlight: signals the row itself is interactive
        // (right-click for Delete Journal…), matching the Welcome list.
        .background(hoveredJournalID == journal.id ? Color.primary.opacity(0.06) : .clear)
        .onHover { hovering in
            if hovering {
                hoveredJournalID = journal.id
            } else if hoveredJournalID == journal.id {
                hoveredJournalID = nil
            }
        }
        .contextMenu {
            Button("Delete Journal…", role: .destructive) { pendingDelete = journal }
        }
    }

    /// Small inline chip naming the exact upstream version this journal's
    /// head was derived from at its last sync/cut — numbered the same way
    /// the rows are (stamps are v1…vN; an un-stamped working head is
    /// "latest", never a number).
    @ViewBuilder
    private func edgeBadge(for head: ManuscriptVersion?) -> some View {
        if let head, let pid = head.parentID,
           let parent = store.versions.first(where: { $0.id == pid }) {
            let label: String = {
                if parent.sourceStamp == true {
                    return "Source v\(store.sourceOrdinal(of: parent))"
                }
                let name = store.manuscript?.journals
                    .first(where: { $0.id == parent.journalID })?.name ?? "upstream"
                // Chain-final = the upstream's working head (a pre-stamp-rule
                // edge): show "latest", matching how the rows label it.
                let isWorkingHead = store.versions(forJournal: parent.journalID).last?.id == parent.id
                return isWorkingHead ? "\(name) latest" : "\(name) v\(store.journalOrdinal(of: parent))"
            }()
            Text("from \(label)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color(NSColor.windowBackgroundColor)))
                .overlay(Capsule().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                .help("This journal's working content was derived from \(label) at its last sync or cut")
        }
    }

    /// Status caption: last synced · last edited, plus the actionable
    /// fast-forward hint when the upstream has a newer stamp.
    @ViewBuilder
    private func statusLine(_ journal: Journal, head: ManuscriptVersion?,
                            source: (upstreamJournalID: UUID?, upstreamName: String, targetVersion: ManuscriptVersion?)?) -> some View {
        if let head {
            let synced = store.lastSynced(journalID: journal.id)
                .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"
            let edited = head.content.updatedAt.formatted(date: .abbreviated, time: .shortened)
            Text("Last synced \(synced) · Last edited \(edited)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let source, source.targetVersion.map({ $0.id != head.parentID }) ?? false {
                Label("\(source.upstreamName) has moved — fast-forward available",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        } else {
            Text("No versions yet — Add Journal creates one automatically; older journals can sync to start.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Sync confirmation

    private func syncAlert(_ pending: PendingSync) -> Alert {
        let journal = pending.journal
        let upstream = store.syncSource(forJournal: journal.id)?.upstreamName ?? "its upstream"
        let (from, to) = pending.forward ? (upstream, journal.name) : (journal.name, upstream)
        var message = "Fully overrides \(to)'s content with \(from)'s latest. \(to)'s current content is stamped into its version history first, so this is recoverable."
        message += smartSync
            ? "\n\nSmart mode is ON: the connected AI rewrites each section toward \(to)'s requirements as it copies. This sends the sections to the Claude API and can take a few minutes."
            : "\n\nSmart mode is off — this is a straight copy."
        let verb = smartSync ? "Smart" : "Fast"
        return Alert(
            title: Text("\(verb)-\(pending.forward ? "forward" : "backward") \(journal.name)?"),
            message: Text(message),
            primaryButton: .destructive(Text("\(verb)-\(pending.forward ? "Forward" : "Backward")")) {
                perform(pending)
            },
            secondaryButton: .cancel()
        )
    }

    private func perform(_ pending: PendingSync) {
        if smartSync {
            Task { await store.smartSync(journalID: pending.journal.id,
                                         forward: pending.forward,
                                         appStore: appStore) }
        } else if pending.forward {
            if let synced = store.syncJournal(pending.journal.id) {
                let ordinal = store.versions(forJournal: pending.journal.id).count
                showSuccess("Fast-forwarded \(pending.journal.name) from \(syncedFromLabel(of: synced)) — now at v\(ordinal) / latest.")
            }
        } else {
            let upstream = store.syncSource(forJournal: pending.journal.id)?.upstreamName ?? "upstream"
            if store.pushToUpstream(pending.journal.id) {
                showSuccess("Fast-backward: \(upstream) now carries \(pending.journal.name)'s latest content.")
            }
        }
    }

    /// Smart mode needs a Claude account with a stored key, selected for
    /// this manuscript.
    private var aiReady: Bool {
        guard let id = store.manuscript?.settings.activeAIServiceID,
              let account = appStore.aiServices.first(where: { $0.id == id }) else { return false }
        return account.provider == .claude && account.hasKey
    }

    // Sync messages live in the window-toolbar banner (shared app-wide).
    private func showSuccess(_ message: String) { store.showBanner(.success, message) }
    private func showError(_ message: String)   { store.showBanner(.error, message) }

    /// "Source v3" / "NEJM v2" — what the fresh head was derived from.
    private func syncedFromLabel(of version: ManuscriptVersion) -> String {
        guard let pid = version.parentID,
              let parent = store.versions.first(where: { $0.id == pid }) else { return "Source" }
        if parent.sourceStamp == true { return "Source v\(store.sourceOrdinal(of: parent))" }
        if let jid = parent.journalID,
           let journal = store.manuscript?.journals.first(where: { $0.id == jid }) {
            return "\(journal.name) v\(store.journalOrdinal(of: parent))"
        }
        return "Source"
    }
}

// MARK: - AddJournalSheet

/// Cut a new journal: FROM Source or any journal, TO a profile from the
/// global journal library (Settings → Journals) or a custom name.
struct AddJournalSheet: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    @Binding var isPresented: Bool

    @State private var fromJournalID: UUID?          // nil = Source
    @State private var libraryChoice: UUID?          // journalLibrary entry id
    @State private var customName = ""

    private var journals: [Journal] { store.manuscript?.journals ?? [] }

    /// Library entries not already added to this manuscript (by name).
    private var availableLibrary: [Journal] {
        appStore.journalLibrary.filter { entry in
            !journals.contains { $0.name == entry.name }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Journal").font(.headline)

            Picker("From", selection: $fromJournalID) {
                Label("Source", systemImage: "doc.text").tag(Optional<UUID>.none)
                ForEach(journals) { journal in
                    Label(journal.name, systemImage: "building.columns").tag(Optional(journal.id))
                }
            }

            Picker("To", selection: $libraryChoice) {
                ForEach(availableLibrary) { entry in
                    Text(entry.name + (entry.country.map { " (\($0))" } ?? ""))
                        .tag(Optional(entry.id))
                }
                Text("Custom journal…").tag(Optional<UUID>.none)
            }

            if libraryChoice == nil {
                TextField("Custom journal name", text: $customName)
                    .textFieldStyle(.roundedBorder)
            }

            Text("The new journal is cut from the FROM journal's latest stamped version (stamping it first if needed), appears in the lineage, and gets its own tab. Manage reusable journal profiles in Settings → Journals.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    add()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(libraryChoice == nil && customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { libraryChoice = availableLibrary.first?.id }
    }

    private func add() {
        let template: Journal
        if let choice = libraryChoice,
           let entry = appStore.journalLibrary.first(where: { $0.id == choice }) {
            template = entry
        } else {
            var custom = Journal.empty()
            custom.name = customName.trimmingCharacters(in: .whitespaces)
            template = custom
        }
        // Every journal gets its 1-1 auto-generated view (export/checks basis).
        let view = ViewConfig.from(journal: template)
        appStore.addViewConfig(view)
        if var added = store.addJournalCut(template: template,
                                           fromJournalID: fromJournalID,
                                           viewConfigID: view.id) {
            added.viewConfigID = view.id
            store.updateJournal(added)
        }
    }
}
