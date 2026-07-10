// SyncView.swift
//
// The "Sync" pane (Manuscript section) — the manuscript's flow-of-content hub.
// Three jobs live here:
//
//   1. SAVING   — Save (Local) writes to the manuscript folder on disk;
//                 Save (Remote) pushes to the active backend account.
//   2. SYNCING  — fast-forward any journal from its upstream.  When the
//                 upstream's latest has unstamped changes, the action becomes
//                 **Stamp & Sync**: the upstream is stamped first so lineage
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

    /// Journal awaiting the stamp prompt (upstream has unstamped changes) —
    /// declining cancels the sync entirely.
    @State private var pendingStamp: Journal?
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
        // Prompt 1 (only when needed): stamp the drifted upstream, or cancel
        // the whole sync.
        .alert(item: $pendingStamp) { journal in
            let upstream = store.syncSource(forJournal: journal.id)?.upstreamName ?? "the upstream"
            return Alert(
                title: Text("Stamp \(upstream) First?"),
                message: Text("\(upstream)'s latest has changes that aren't stamped. To keep proper lineage, syncing stamps \(upstream) first. Cancel to leave everything untouched."),
                primaryButton: .default(Text("Stamp & Continue")) {
                    // Presenting a second alert from the first one's dismiss
                    // handler gets silently dropped by SwiftUI — defer a beat
                    // so the sync confirmation actually appears.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        pendingSync = journal   // stamping happens inside syncJournal
                    }
                },
                secondaryButton: .cancel()
            )
        }
        // Prompt 2: the sync itself, stating plainly whether AI is involved.
        .alert(item: $pendingSync) { journal in
            syncAlert(journal)
        }
    }

    // MARK: - 1. Saving

    private var savingCard: some View {
        let m = store.manuscript
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    store.trySave()
                } label: {
                    Label("Save (Local)", systemImage: "internaldrive")
                }
                Text(m.map { "Edited \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Button {
                        store.saveToRemote(appStore: appStore)
                    } label: {
                        Label("Save (Remote)", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(store.isRemoteBusy)
                }
                Text(m?.lastSyncedAt.map { "Synced \($0.formatted(date: .abbreviated, time: .shortened))" }
                     ?? "Never synced — configure a backend in Manuscript → Backend")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isRemoteBusy { ProgressView().controlSize(.small) }
        }
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

    /// Parent/child blocks contiguous: no vertical gap, children tabbed on
    /// the left with right edges aligned to the parent's.
    private var lineageTree: some View {
        VStack(alignment: .trailing, spacing: 1) {
            sourceRow
            ForEach(flattenedTree, id: \.journal.id) { entry in
                journalRow(entry.journal)
                    .frame(width: cardWidth - CGFloat(entry.depth + 1) * indent)
            }
        }
        .frame(width: cardWidth, alignment: .trailing)
    }

    // MARK: Source (root) row

    private var sourceRow: some View {
        let stamps = store.sourceStamps.count
        return HStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.accentColor.opacity(0.1)))
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Source").font(.headline)
                    Text(stamps > 0 ? "v\(stamps) / latest" : "latest")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Original source of manuscript content."
                     + (store.sourceHasUnstampedChanges ? " Has changes since its last stamp." : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
        .frame(width: cardWidth)
    }

    // MARK: Journal rows

    /// Whether syncing this journal requires stamping its upstream first.
    private func upstreamNeedsStamp(_ journal: Journal) -> Bool {
        guard let source = store.syncSource(forJournal: journal.id) else { return false }
        if let upstreamID = source.upstreamJournalID {
            return store.headHasUnstampedChanges(journalID: upstreamID)
        }
        return store.sourceHasUnstampedChanges
    }

    @ViewBuilder
    private func journalRow(_ journal: Journal) -> some View {
        let head = store.latestVersion(forJournal: journal.id)
        let source = store.syncSource(forJournal: journal.id)

        HStack(spacing: 12) {
            // Edge badge: which upstream version the head hangs from.
            edgeBadge(for: head)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(journal.name).font(.headline)
                    if let head {
                        let count = store.versions(forJournal: journal.id).count
                        Text(count > 1 ? "v\(count - 1) / latest" : "latest")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                        let _ = head   // silence unused in release analysis
                    }
                }
                statusLine(journal, head: head, source: source)
            }

            Spacer()

            if head != nil {
                Button {
                    // Stamping is its own prompt; declining cancels the sync.
                    if upstreamNeedsStamp(journal) {
                        pendingStamp = journal
                    } else {
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
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
    }

    /// The small circle showing which upstream version the head hangs from.
    @ViewBuilder
    private func edgeBadge(for head: ManuscriptVersion?) -> some View {
        if let head, let pid = head.parentID,
           let parent = store.versions.first(where: { $0.id == pid }) {
            let label = parent.sourceStamp == true
                ? "S\(store.sourceOrdinal(of: parent))"
                : "v\(store.journalOrdinal(of: parent))"
            Text(label)
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                .overlay(Circle().strokeBorder(.primary.opacity(0.45), lineWidth: 1.25))
                .help("Derived from \(parent.sourceStamp == true ? "Source stamp" : "upstream version") \(label)")
        } else if head != nil {
            Image(systemName: "doc.text")
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                .overlay(Circle().strokeBorder(.primary.opacity(0.45), lineWidth: 1.25))
                .help("Cut from the live Source")
        } else {
            Text("—")
                .frame(width: 36, height: 36)
                .foregroundStyle(.tertiary)
        }
    }

    /// Drift status: current / upstream moved / upstream itself stale.
    @ViewBuilder
    private func statusLine(_ journal: Journal, head: ManuscriptVersion?,
                            source: (upstreamJournalID: UUID?, upstreamName: String, targetVersion: ManuscriptVersion?)?) -> some View {
        if head == nil {
            Text("No versions yet — Add Journal creates one automatically; older journals can sync to start.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if let source {
            if upstreamNeedsStamp(journal) {
                Label("\(source.upstreamName)'s latest has unstamped changes — syncing stamps it first",
                      systemImage: "seal")
                    .font(.caption)
                    .foregroundStyle(.blue)
            } else if let target = source.targetVersion, target.id != head?.parentID {
                Label("\(source.upstreamName) has moved — fast-forward available",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.blue)
            } else if let upstreamID = source.upstreamJournalID,
                      store.syncSource(forJournal: upstreamID)?.targetVersion?.id
                        != store.latestVersion(forJournal: upstreamID)?.parentID {
                Label("Up to date with \(source.upstreamName), but \(source.upstreamName) is behind its own upstream — sync it first",
                      systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("Up to date with \(source.upstreamName)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
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
        if let target = source?.targetVersion, !upstreamNeedsStamp(journal) {
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
                store.syncJournal(journal.id)
            },
            secondaryButton: .cancel()
        )
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
