// SyncView.swift
//
// The "Sync" pane (Manuscript section) — the manuscript's flow-of-content hub.
// Three jobs live here:
//
//   1. SAVING   — Save (Local) writes to the manuscript folder on disk;
//                 Save (Remote) pushes to the active backend account.
//   2. SYNCING  — fast-forward any journal from its upstream.  Every sync
//                 edge A→B is checksum-verified first: identical latest
//                 contents short-circuit to an "already in sync" banner, and
//                 an upstream whose latest drifted from its own last stamp
//                 refuses to sync until it's stamped (Versions tab) — lineage
//                 always hangs from frozen versions.
//   3. ADDING   — cut a new journal: FROM any journal (or Source), TO a
//                 journal profile from the app-settings library (or custom).
//                 The new journal appears in the lineage and gets a tab
//                 automatically.
//
// Lineage visual: children render contiguous with their parent — attached
// directly beneath it, tabbed on the left, right edges aligned.

import SwiftUI

struct SyncView: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    /// Journal awaiting the sync confirmation itself.
    @State private var pendingSync: Journal?
    @State private var showAddJournal = false

    private var journals: [Journal] { store.manuscript?.journals ?? [] }
    private let cardWidth: CGFloat = 640
    private let indent: CGFloat = 28

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sync").font(.title2.weight(.semibold))

                savingCard

                HStack {
                    Text("Journals & Lineage").font(.headline)
                    Spacer()
                    Button {
                        showAddJournal = true
                    } label: {
                        Label("Add Journal", systemImage: "plus")
                    }
                }
                .frame(maxWidth: cardWidth)

                lineageTree

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showAddJournal) {
            AddJournalSheet(isPresented: $showAddJournal)
        }
        // The sync confirmation, stating plainly whether AI is involved.
        // (Reached only after the checksum precheck says the edge is ready.)
        .alert(item: $pendingSync) { journal in
            syncAlert(journal)
        }
    }

    // MARK: - 1. Saving

    private var savingCard: some View {
        let m = store.manuscript
        // Equal-width columns so the two Save buttons sit evenly.
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    store.trySave()   // always writes the file, dirty or not
                    if let error = store.saveError {
                        showError("Local save failed: \(error)")
                    } else {
                        showSuccess("Saved to disk at \((store.lastSaved ?? Date()).formatted(date: .omitted, time: .standard)).")
                    }
                } label: {
                    Label("Save (Local)", systemImage: "internaldrive")
                }
                Text(store.lastSaved.map { "Saved \($0.formatted(date: .abbreviated, time: .shortened))" }
                     ?? m.map { "Edited \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 250, alignment: .leading)

            Divider().frame(height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Button {
                    store.saveToRemote(appStore: appStore)
                } label: {
                    Label("Save (Remote)", systemImage: "icloud.and.arrow.up")
                }
                .disabled(store.isRemoteBusy)
                Text(m?.lastSyncedAt.map { "Synced \($0.formatted(date: .abbreviated, time: .shortened))" }
                     ?? "Never synced — configure a backend in Manuscript → Backend")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 250, alignment: .leading)

            Spacer()

            if store.isRemoteBusy { ProgressView().controlSize(.small) }
        }
        // Remote pushes banner their own result from the store.
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
        .frame(maxWidth: cardWidth)
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
                journalRow(entry.journal)
                    .padding(.leading, CGFloat(entry.depth) * indent + 10)
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
                    Text(stamps > 0 ? "v\(stamps) / latest" : "latest")
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
    private func journalRow(_ journal: Journal) -> some View {
        let head = store.latestVersion(forJournal: journal.id)
        let source = store.syncSource(forJournal: journal.id)

        HStack(spacing: 12) {
            // Curved branch arrow — the row's indent already conveys depth.
            Image(systemName: "arrow.turn.down.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)

            // The journal's configured icon (Preferences → Journals).
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
                        Text(count > 1 ? "v\(count - 1) / latest" : "latest")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    edgeBadge(for: head)
                }
                statusLine(journal, head: head, source: source)
            }

            Spacer()

            if head != nil {
                Button {
                    // Checksum-verify the A→B edge before anything happens.
                    switch store.syncPrecheck(forJournal: journal.id) {
                    case .alreadyInSync(let upstream):
                        showSuccess("\(journal.name) and \(upstream) are already in sync — their latest contents are identical.")
                    case .upstreamNeedsStamp(let upstream):
                        showError("\(upstream)'s latest has changes that aren't stamped. Stamp \(upstream) in its Versions tab first — syncing pulls a frozen version so the lineage stays intact.")
                    case .ready:
                        pendingSync = journal
                    }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.bordered)
                .help("Fast-forward \(journal.name) from \(source?.upstreamName ?? "upstream")")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
    }

    /// Small inline chip showing which upstream version the head hangs from.
    @ViewBuilder
    private func edgeBadge(for head: ManuscriptVersion?) -> some View {
        if let head, let pid = head.parentID,
           let parent = store.versions.first(where: { $0.id == pid }) {
            let label = parent.sourceStamp == true
                ? "S\(store.sourceOrdinal(of: parent))"
                : "v\(store.journalOrdinal(of: parent))"
            Text("from \(label)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color(NSColor.windowBackgroundColor)))
                .overlay(Capsule().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                .help("Derived from \(parent.sourceStamp == true ? "Source stamp" : "upstream version") \(label)")
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

    private func syncAlert(_ journal: Journal) -> Alert {
        let source = store.syncSource(forJournal: journal.id)
        let upstream = source?.upstreamName ?? "its upstream"
        var message = "This creates a new \(journal.name) version from \(upstream)'s latest stamped content — overwriting what currently exists in \(journal.name)'s working head. Previous versions remain in its history."
        // Be explicit about whether AI participates in the copy.
        if store.manuscript?.settings.activeAIServiceID != nil {
            message += "\n\nAI is connected — it may modify what's copied over to fit \(journal.name)'s requirements."
        } else {
            message += "\n\nNo AI is connected — this is a straight copy."
        }
        // The precheck already guaranteed the upstream stamp is current.
        if let target = source?.targetVersion {
            let when = target.sourceSnapshotDate.formatted(date: .abbreviated, time: .omitted)
            let label = target.sourceStamp == true
                ? "Source v\(store.sourceOrdinal(of: target))"
                : "\(upstream) v\(store.journalOrdinal(of: target))"
            message += "\n\nContent copied: \(label), which carries content from \(when)."
        }
        return Alert(
            title: Text("Sync \(journal.name) from \(upstream)?"),
            message: Text(message),
            primaryButton: .destructive(Text("Sync")) {
                performSync(journal)
            },
            secondaryButton: .cancel()
        )
    }

    /// Runs the sync and surfaces an explicit confirmation — the status line
    /// alone was too quiet to read as success.
    private func performSync(_ journal: Journal) {
        guard let synced = store.syncJournal(journal.id) else { return }
        let from = syncedFromLabel(of: synced)
        let ordinal = store.versions(forJournal: journal.id).count
        showSuccess("Successfully synced \(journal.name) from \(from) — now at v\(ordinal) / latest.")
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
/// global journal library (Preferences → Journals) or a custom name.
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

            Text("The new journal is cut from the FROM journal's latest stamped version (stamping it first if needed), appears in the lineage, and gets its own tab. Manage reusable journal profiles in Preferences → Journals.")
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
