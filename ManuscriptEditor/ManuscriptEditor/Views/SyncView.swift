// SyncView.swift
//
// The "Sync" pane (sidebar, between Settings and Checks) — lineage management,
// modeled on MasterContext/examples/lineage-management.png.
//
// Each target journal is shown as a node with the lineage edge it hangs from:
// the badge on the edge is the upstream version it was last cut/synced from,
// the badge on the journal is its current working head.  The blue sync button
// fast-forwards ONE edge (never recursive): it snapshots the upstream's latest
// content as a new version of the journal — after a confirmation warning,
// because it replaces the journal's current working content (previous versions
// stay in its history).

import SwiftUI

struct SyncView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Journal awaiting sync confirmation (drives the warning alert).
    @State private var pendingSync: Journal?

    private var journals: [Journal] { store.manuscript?.journals ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sync").font(.title2.weight(.semibold))
                Text("Fast-forward a journal from the lineage it was cut from. Each sync updates exactly one edge — it snapshots the upstream's latest content as a new version of that journal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)

                sourceRow

                if journals.isEmpty {
                    Text("No target journals yet. Cut a version for a journal in Versions to create a lineage.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                } else {
                    // Nested lineage: each journal sits indented under the
                    // journal (or Source) it syncs from, so the tree reads
                    // top-down and each edge carries its own Sync button.
                    ForEach(flattenedTree, id: \.journal.id) { entry in
                        HStack(alignment: .center, spacing: 6) {
                            if entry.depth > 0 {
                                Color.clear.frame(width: CGFloat(entry.depth - 1) * 32)
                                Image(systemName: "arrow.turn.down.right")
                                    .foregroundStyle(.tertiary)
                            }
                            journalRow(entry.journal)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .alert(item: $pendingSync) { journal in
            let source = store.syncSource(forJournal: journal.id)
            let upstream = source?.upstreamName ?? "its upstream"
            var message = "This creates a new \(journal.name) version from \(upstream)’s latest content — overwriting what currently exists in \(journal.name)’s working head. Previous versions remain in its history."
            // When the upstream is a journal (not the live Source), spell out
            // exactly which snapshot will be copied — users routinely expect
            // "sync" to pull the current Source, but only a direct child of
            // Source does that (syncs are one edge, never recursive).
            if let target = source?.targetVersion {
                let when = target.sourceSnapshotDate.formatted(date: .abbreviated, time: .omitted)
                message += "\n\nContent copied: \(upstream) v\(store.journalOrdinal(of: target)), which carries content from \(when). \(journal.name) does not pull from Source directly — to bring current Source content here, sync \(upstream) first, then \(journal.name)."
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

    // MARK: - Lineage tree shape

    /// Journals depth-first under their upstream journal (Source = depth 0),
    /// so the cards render as a nested tree.  Journals without versions (no
    /// lineage yet) list under Source.  `visited` guards a malformed cycle.
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
        // Anything unreachable (shouldn't happen) still gets listed flat.
        for journal in journals where !visited.contains(journal.id) {
            out.append((journal, 0))
        }
        return out
    }

    /// True when `journalID`'s own upstream has a newer version than the one its
    /// head was derived from — content synced *through* it would still be stale.
    private func upstreamHasDrifted(_ journalID: UUID) -> Bool {
        guard let head = store.latestVersion(forJournal: journalID),
              let source = store.syncSource(forJournal: journalID),
              let target = source.targetVersion else { return false }
        return target.id != head.parentID
    }

    // MARK: - Source (root) row

    private var sourceRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.accentColor.opacity(0.1)))
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                Text("Source").font(.headline)
                Text("The root of every lineage — always the live working manuscript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
        .frame(maxWidth: 620)
    }

    // MARK: - Journal rows

    @ViewBuilder
    private func journalRow(_ journal: Journal) -> some View {
        let head = store.latestVersion(forJournal: journal.id)
        let source = store.syncSource(forJournal: journal.id)

        HStack(spacing: 14) {
            // Edge: upstream name + the version badge the journal hangs from.
            VStack(spacing: 4) {
                Text(source?.upstreamName ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                edgeBadge(for: head, source: source)
            }
            .frame(width: 90)

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)

            // The journal node: a version bubble (v1, v2, …) for the current
            // head — the journal's name lives only in the text beside it.
            versionBubble(head)

            VStack(alignment: .leading, spacing: 3) {
                Text(journal.name).font(.headline)
                statusLine(journal, head: head, source: source)
            }

            Spacer()

            if head != nil {
                Button {
                    pendingSync = journal
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.bordered)
                .help("Fast-forward \(journal.name) from \(source?.upstreamName ?? "upstream")")
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
        .frame(maxWidth: 620)
    }

    /// The small circle on the edge: which upstream version the head hangs from.
    @ViewBuilder
    private func edgeBadge(for head: ManuscriptVersion?, source: (upstreamJournalID: UUID?, upstreamName: String, targetVersion: ManuscriptVersion?)?) -> some View {
        if let head, let pid = head.parentID,
           let parent = store.versions.first(where: { $0.id == pid }) {
            Text("v\(store.journalOrdinal(of: parent))")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(NSColor.controlBackgroundColor)))
                .overlay(Circle().strokeBorder(.primary.opacity(0.45), lineWidth: 1.25))
        } else if head != nil {
            Image(systemName: "doc.text")
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(NSColor.controlBackgroundColor)))
                .overlay(Circle().strokeBorder(.primary.opacity(0.45), lineWidth: 1.25))
                .help("Cut from the live Source")
        } else {
            Text("—")
                .frame(width: 36, height: 36)
                .foregroundStyle(.tertiary)
        }
    }

    /// "Upstream has moved — fast-forward available" vs "Up to date".
    @ViewBuilder
    private func statusLine(_ journal: Journal, head: ManuscriptVersion?,
                            source: (upstreamJournalID: UUID?, upstreamName: String, targetVersion: ManuscriptVersion?)?) -> some View {
        if head == nil {
            Text("No versions yet — cut one in Versions to create the lineage.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if let source {
            if let target = source.targetVersion, target.id != head?.parentID {
                Label("\(source.upstreamName) has moved to v\(store.journalOrdinal(of: target)) — fast-forward available",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.blue)
            } else if source.targetVersion == nil {
                Label("Cut from the live Source — sync pulls its current content",
                      systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let upstreamID = source.upstreamJournalID, upstreamHasDrifted(upstreamID) {
                // "Up to date" would be a lie here: the edge into this journal is
                // current, but the upstream journal is itself behind, so its
                // content — and anything synced from it — is stale.
                Label("Up to date with \(source.upstreamName), but \(source.upstreamName) is behind its own upstream — sync it first, then \(journal.name)",
                      systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Up to date with \(source.upstreamName)", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                    // A chain through another journal never sees Source edits on
                    // its own — date the content so staleness is visible.
                    if let upstreamID = source.upstreamJournalID,
                       let upstreamHead = store.latestVersion(forJournal: upstreamID) {
                        Text("\(source.upstreamName) carries content from \(upstreamHead.sourceSnapshotDate.formatted(date: .abbreviated, time: .omitted)) — sync it first to flow newer edits down to \(journal.name).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The journal's node: a thematic bubble holding just its current version
    /// number ("v2"), or a dash when the journal has no versions yet.
    private func versionBubble(_ head: ManuscriptVersion?) -> some View {
        let label = head.map { "v\(store.journalOrdinal(of: $0))" }
        return Text(label ?? "—")
            .font(.callout.weight(.bold).monospacedDigit())
            .foregroundStyle(label == nil ? Color.secondary : Color.accentColor)
            .frame(width: 52, height: 52)
            .background(Circle().fill(label == nil
                                      ? Color(NSColor.windowBackgroundColor)
                                      : Color.accentColor.opacity(0.12)))
            .overlay(Circle().strokeBorder(
                label == nil ? Color.secondary.opacity(0.4) : Color.accentColor.opacity(0.6),
                lineWidth: 1.5))
    }
}

// Journal already conforms to Identifiable — required by .alert(item:).
