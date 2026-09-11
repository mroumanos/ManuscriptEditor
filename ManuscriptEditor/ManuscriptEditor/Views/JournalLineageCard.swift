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
    @State private var showSyncInfo = false
    /// Journal awaiting the delete confirmation (context menu).
    @State private var pendingDelete: Journal?
    /// The journal being renamed.  A journal's name is its own — the template
    /// it came from keeps its name and its link.
    @State private var renamingJournal: Journal?
    @State private var renameDraft = ""
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
                    Button {
                        showSyncInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showSyncInfo, arrowEdge: .bottom) {
                        Text("""
                        Every sync is a full override in one direction:

                        ⏪  Fast-backward pushes this journal's latest \
                        content UP to its upstream.
                        ⏩  Fast-forward pulls the upstream's latest \
                        content DOWN into this journal.

                        The overridden side's previous content is stamped \
                        into its version history first, so either direction \
                        is recoverable.

                        With ✦ Assist on (title bar), the selected model \
                        rewrites each section toward the target journal's \
                        requirements and checks as it copies, instead of \
                        making a verbatim copy. Either way the same version \
                        is stamped, and every request is recorded in the \
                        prompt log.
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
                // The delete alert lives on the header row — a SIBLING of
                // lineageTree (which holds the sync alert).  On macOS an
                // alert(item:) on an ANCESTOR suppresses one on a descendant
                // just like two on the same node do: with this alert on the
                // outer VStack, the ⏪⏩ sync confirmations never fired.
                .alert("Rename Journal", isPresented: Binding(
                    get: { renamingJournal != nil },
                    set: { if !$0 { renamingJournal = nil } })) {
                    TextField("Journal name", text: $renameDraft)
                    Button("Rename") {
                        if var journal = renamingJournal {
                            let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                journal.name = trimmed
                                store.updateJournal(journal)
                            }
                        }
                        renamingJournal = nil
                    }
                    Button("Cancel", role: .cancel) { renamingJournal = nil }
                } message: {
                    Text("Only this journal is renamed. The template it was created from keeps its own name, and stays linked.")
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

                lineageTree
                    // Attached here, NOT on the outer VStack: two
                    // alert(item:) modifiers on one view conflict on macOS —
                    // only the last fires (the original Sync button's silent
                    // failure).
                    .alert(item: $pendingSync) { pending in
                        syncAlert(pending)
                    }
        }
        .sheet(isPresented: $showAddJournal) {
            AddJournalSheet(isPresented: $showAddJournal)
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
                    Text(journal.displayName).font(.headline)
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
                // Assist off, this is the mechanical copy it always was.
                // Assist on, the same button adapts on the way — so it wears
                // the assist treatment rather than becoming a second button.
                let assisting = assistActive
                // Only this journal's row reacts: a request on one cut says
                // nothing about the others.
                let running = store.isAssisting(journal.id)
                if let run = store.assistRun(journal.id) {
                    AssistRunIndicator(run: run,
                                       timeout: AIRequestService.longRunTimeout)
                }
                Button {
                    pendingSync = PendingSync(journal: journal, forward: false)
                } label: {
                    Image(systemName: "backward.fill")
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        // No .bordered: its capsule put an oval around every
                        // glyph, and the only frame these buttons should ever
                        // wear is the assist treatment.
                        .assistAffordance(active: assisting, busy: store.isAssistBusy)
                }
                .buttonStyle(.plain)
                .disabled(running)
                .help(assisting
                      ? "Assisted fast-backward: adapt \(journal.name)'s latest toward \(upstreamName) and override it"
                      : "Fast-backward: override \(upstreamName) with \(journal.name)'s latest")
                Button {
                    // Checksum short-circuit: identical latest contents mean
                    // there is nothing to pull.  An assisted run has work to
                    // do even then — it rewrites rather than copies.
                    if !assistActive,
                       case .alreadyInSync(let upstream) = store.syncPrecheck(forJournal: journal.id) {
                        showSuccess("\(journal.name) and \(upstream) are already in sync — their latest contents are identical.")
                        return
                    }
                    pendingSync = PendingSync(journal: journal, forward: true)
                } label: {
                    Image(systemName: "forward.fill")
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .assistAffordance(active: assisting, busy: store.isAssistBusy)
                }
                .buttonStyle(.plain)
                .disabled(running)
                .help(assisting
                      ? "Assisted fast-forward: adapt \(upstreamName)'s latest toward \(journal.name)'s requirements and override it"
                      : "Fast-forward: override \(journal.name) with \(upstreamName)'s latest")
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
            Button("Rename Journal…") {
                renameDraft = journal.name
                renamingJournal = journal
            }
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
                Label("\(source.upstreamName) has newer content — ⏩ fast-forward pulls it in",
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
        message += assistActive
            ? "\n\n✦ Assist is ON: \(modelLabel) rewrites each section toward \(to)'s requirements and checks as it copies. The sections and your enabled context leave this machine, it can take a few minutes, and the request is recorded in the prompt log."
            : "\n\nAssist is off — this is a straight copy."
        let verb = assistActive ? "Assisted" : "Fast"
        // Three outcomes, not two: replace what is there, or keep it and add
        // to it.  A cut you have already worked on shouldn't have to be
        // overwritten to take an upstream revision.
        return Alert(
            title: Text("\(verb) \(pending.forward ? "fast-forward" : "fast-backward") of \(journal.name)?"),
            message: Text(message + "\n\nOverwrite replaces the target's content. Append keeps what is there and adds the incoming content after it."),
            primaryButton: .destructive(Text("Overwrite")) {
                perform(pending, mode: .overwrite)
            },
            secondaryButton: .default(Text("Append")) {
                perform(pending, mode: .append)
            }
        )
    }

    private func perform(_ pending: PendingSync, mode: ManuscriptStore.SyncMode) {
        if assistActive {
            // AI INTENT  journal.fastForward
            Task { await store.assistFastForward(journalID: pending.journal.id,
                                                 forward: pending.forward,
                                                 appStore: appStore,
                                                 mode: mode) }
        } else if pending.forward {
            if let synced = store.syncJournal(pending.journal.id, mode: mode) {
                let ordinal = store.versions(forJournal: pending.journal.id).count
                showSuccess("Fast-forwarded \(pending.journal.name) from \(syncedFromLabel(of: synced)) — now at v\(ordinal) / latest.")
            }
        } else {
            let upstream = store.syncSource(forJournal: pending.journal.id)?.upstreamName ?? "upstream"
            if store.pushToUpstream(pending.journal.id, mode: mode) {
                showSuccess("Fast-backward: \(upstream) now carries \(pending.journal.name)'s latest content.")
            }
        }
    }

    /// Whether this sync will go through a model: the manuscript's Assist
    /// toggle is on AND there is somewhere to send it.  One predicate, so the
    /// button's look, its confirmation and what it actually does can never
    /// disagree.
    private var assistActive: Bool {
        store.isAssistEnabled && store.canAssist(appStore: appStore)
    }

    /// The model named in the confirmation, so "this leaves your machine" is
    /// attached to who receives it.
    ///
    /// Reads the settings rather than resolving a destination: resolving one
    /// reads the stored API key, and this is computed on every row render.
    private var modelLabel: String {
        guard let settings = store.manuscript?.settings else { return "the selected model" }
        if let id = settings.activeConnectorID,
           let connector = appStore.connectors.first(where: { $0.id == id }) {
            let model = settings.aiModel ?? connector.selectedModel
            return connector.modelEntries.first { $0.id == model }?.label
                ?? connector.kind.displayName
        }
        if let id = settings.activeAIServiceID,
           let account = appStore.aiServices.first(where: { $0.id == id }) {
            return account.displayName
        }
        return "the selected model"
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
/// **template** in the library (Settings → Journals) or a custom name.
///
/// A template is a starting point, not an identity: the journal it creates
/// takes its own name, keeps a pointer to the template it came from, and can
/// be renamed on either side without breaking the link.
struct AddJournalSheet: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    @Binding var isPresented: Bool

    @State private var fromJournalID: UUID?          // nil = Source
    @State private var libraryChoice: UUID?          // journalLibrary entry id
    @State private var customName = ""
    @State private var customType = ""
    @State private var journalQuery = ""

    private var journals: [Journal] { store.manuscript?.journals ?? [] }

    /// Every template in the library.
    ///
    /// **Nothing is hidden.**  Templates used to disappear once a manuscript
    /// had a journal using them — a rule that made sense when a library entry
    /// WAS the journal, and stopped making sense the moment journals became
    /// instances: two cuts at the same venue ("BMJ test 1" and "BMJ test 2")
    /// are exactly what a template is for.  A template already in use says so
    /// in its row instead of vanishing from it.
    private var availableProfiles: [JournalTemplate] {
        JournalProfileLibrary.shared.profiles.values
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The journals in this manuscript already cut from a template.
    private func journalsUsing(_ profile: JournalTemplate) -> [Journal] {
        journals.filter {
            $0.profileID == profile.id
                || ($0.profileID == nil && $0.name == profile.name
                    && $0.articleType == profile.articleType)
        }
    }

    /// The registry entry behind a profile, when there is one — publisher,
    /// country, and the numeric requirement fields older checks still read.
    private func registryEntry(for profile: JournalProfile) -> Journal? {
        appStore.journalLibrary.first {
            $0.name == profile.name && $0.articleType == profile.articleType
        } ?? appStore.journalLibrary.first { $0.name == profile.name }
    }

    /// What the list shows: every available template, narrowed by the search
    /// as you type.  It used to show nothing until you typed, so a library
    /// full of templates looked empty from here.
    private var browsable: [JournalTemplate] {
        journalQuery.trimmingCharacters(in: .whitespaces).count >= 2
            ? journalMatches
            : availableProfiles
    }

    /// Templates every ≥2-letter search term matches (name, article type,
    /// publisher, or country).
    private var journalMatches: [JournalTemplate] {
        let terms = journalQuery.lowercased()
            .split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !terms.isEmpty else { return [] }
        return availableProfiles.filter { profile in
            let entry = registryEntry(for: profile)
            let hay = "\(profile.name) \(profile.articleType ?? "") "
                + "\(entry?.publisher ?? "") \(entry?.country ?? "")"
            return terms.allSatisfy { hay.lowercased().contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Journal").font(.headline)

            Picker("From", selection: $fromJournalID) {
                Label("Source", systemImage: "doc.text").tag(Optional<UUID>.none)
                ForEach(journals) { journal in
                    Label(journal.displayName, systemImage: "building.columns").tag(Optional(journal.id))
                }
            }

            // The templates, browsable and searchable — the list shows
            // everything until you narrow it, because a library full of
            // templates looked empty when this was search-only.
            if let choice = libraryChoice,
               let profile = JournalProfileLibrary.shared.profile(id: choice) {
                HStack(spacing: 6) {
                    Text("Template:").foregroundStyle(.secondary)
                    Text(profile.displayName).fontWeight(.medium)
                    Button {
                        libraryChoice = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Choose a different template")
                    Spacer()
                }
                // The journal's name is its own: a template is a starting
                // point, and you can cut "BMJ test 1" from BMJ without
                // renaming the template or losing the link to it.
                TextField("Name for this journal", text: $customName,
                          prompt: Text(profile.displayName))
                    .textFieldStyle(.roundedBorder)
                // Review what you're signing up for BEFORE adding: the
                // journal's summary, the shape it expects, and the tests that
                // will start running.
                JournalProfileReview(profile: profile)
                    .frame(height: 260)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Search templates…", text: $journalQuery)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color(NSColor.textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))

                    if !browsable.isEmpty {
                        // Inline (not floating): a sheet's window would clip
                        // an overlay card at its edge.
                        FitScrollView(maxScreenFraction: 0.3) {
                            VStack(alignment: .leading, spacing: 0) {
                                SearchSectionHeader(title: journalQuery.isEmpty ? "Templates" : "Matches",
                                                    count: browsable.count)
                                ForEach(browsable) { profile in
                                    let entry = registryEntry(for: profile)
                                    let inUse = journalsUsing(profile)
                                    SearchResultRow(
                                        icon: "plus.circle",
                                        title: profile.displayName,
                                        subtitle: [entry?.publisher ?? "", entry?.country ?? "",
                                                   "\(profile.checks.count) tests",
                                                   inUse.isEmpty ? ""
                                                       : "in use by \(inUse.map(\.name).joined(separator: ", "))"]
                                            .filter { !$0.isEmpty }.joined(separator: " · ")
                                    ) {
                                        libraryChoice = profile.id
                                        journalQuery = ""
                                    }
                                }
                            }
                        }
                        .background(Color(NSColor.controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
                    } else {
                        Text(journalQuery.isEmpty
                             ? "No templates in your library yet — name a custom journal below."
                             : "No templates match — name a custom journal below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("…or custom journal name", text: $customName)
                        .textFieldStyle(.roundedBorder)
                    // Free-form on purpose: "Research Brief", "Rapid
                    // Communication", "Registered Report" — journals invent
                    // these, and a fixed list would be wrong within a year.
                    // It groups a journal's formats and names its profile.
                    TextField("…and type, optionally (Research Article, Research Brief…)",
                              text: $customType)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("A template is a starting point: the new journal takes its summary, structure, tests and export outline, keeps its own name, and remembers which template it came from. It is cut from the FROM journal's latest stamped version (stamping it first if needed), appears in the lineage, and gets its own tab. Manage templates in Settings → Journals.")
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
                .disabled(libraryChoice == nil
                          && customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)

    }

    private func add() {
        var template: Journal
        if let choice = libraryChoice,
           let profile = JournalProfileLibrary.shared.profile(id: choice) {
            // The registry entry, when there is one, contributes only what a
            // profile doesn't carry: publisher, country, and the numeric
            // requirement fields the older checks read.
            template = registryEntry(for: profile) ?? Journal.empty()
            template.id = UUID()
            let chosenName = customName.trimmingCharacters(in: .whitespaces)
            template.name = chosenName.isEmpty ? profile.name : chosenName
            template.articleType = profile.articleType
            template.templateName = profile.name
            template.templateChecksum = profile.checksum
            template.profileID = profile.id
            template.profileLineage = profile.lineage.isEmpty ? nil : profile.lineage
            template.sourceRequirements = profile.requirements
            template.checkRules = profile.checks
            template.structure = profile.structure
            if let export = profile.export { template.exportConfig = export }
            template.configOrigin = profile.origin
            template.configURL = profile.originURL
            if template.submissionURL.isEmpty {
                template.submissionURL = profile.requirements.url
            }
        } else {
            var custom = Journal.empty()
            custom.name = customName.trimmingCharacters(in: .whitespaces)
            custom.articleType = customType.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : customType.trimmingCharacters(in: .whitespaces)
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
