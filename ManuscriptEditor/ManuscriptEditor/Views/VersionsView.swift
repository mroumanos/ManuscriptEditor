// VersionsView.swift
//
// The "Versions" pane — a per-tab, horizontal version history table.
//
// Each comparison tab (Source or a journal) gets its own pane showing that
// journal's lineage as a simple sorted table, newest first:
//
//   Version | Stamped            | From → To          | By
//   latest  | (working, editable)| Source v2 → latest | Michael ✓
//   v2      | Jul 9, 2026 14:02  | v1 → v2            | Michael ✓
//   v1      | Jun 12, 2026 09:15 | Source v1 → v1     | Shuo ?
//
// The working head is annotated "latest" (no number).  **Stamp Version**
// freezes the current content as a numbered version and moves "latest" to a
// new row.  Selecting a prior version enables **Roll Back…**, which restores
// it and drops everything after (confirmed; refused when another journal's
// cut hangs from a dropped version).
//
// Source maintains its own chain exactly the same way — its "latest" row is
// the live manuscript.

import SwiftUI

// MARK: - VersionsView

struct VersionsView: View {
    @Environment(ManuscriptStore.self) private var store

    /// The comparison tab this pane represents (nil = standalone → Source).
    var versionRef: VersionRef? = nil

    @State private var selectedRowID: String?
    @State private var confirmRollback = false
    @State private var rollbackError: String?

    private var manuscript: Manuscript? { store.manuscript }

    /// The journal this pane shows; nil = the Source chain.
    private var journalID: UUID? {
        guard case .version(let id) = versionRef ?? .source else { return nil }
        return store.versions.first { $0.id == id }?.journalID
    }

    private var isSourcePane: Bool { journalID == nil }

    private var journalName: String {
        guard let journalID else { return "Source" }
        return manuscript?.journals.first { $0.id == journalID }?.name ?? "Journal"
    }

    // MARK: Rows

    /// One table row.  The "latest" row is the editable working state: the
    /// live manuscript for Source, the working head for a journal.
    private struct Row: Identifiable {
        let id: String
        let versionLabel: String       // "latest" or "v3"
        let stamped: Date
        let from: String
        let to: String
        let byName: String
        let byKey: String?
        let byMessage: String?
        let bySignature: String?
        let version: ManuscriptVersion?   // nil = the live-Source latest row
        let isLatest: Bool
    }

    private var rows: [Row] {
        var out: [Row] = []
        if isSourcePane {
            // Synthetic latest row: the live manuscript.
            if let m = manuscript {
                let fromLabel = store.latestSourceStamp.map { "v\(store.sourceOrdinal(of: $0))" } ?? "—"
                out.append(Row(
                    id: "live-source", versionLabel: "latest", stamped: m.updatedAt,
                    from: fromLabel, to: "latest",
                    byName: "", byKey: nil, byMessage: nil, bySignature: nil,
                    version: nil, isLatest: true))
            }
            for stamp in store.sourceStamps.reversed() {
                out.append(row(for: stamp, label: "v\(store.sourceOrdinal(of: stamp))", isLatest: false))
            }
        } else {
            let chain = store.versions(forJournal: journalID)
            for (index, version) in chain.enumerated().reversed() {
                let isHead = index == chain.count - 1
                out.append(row(for: version,
                               label: isHead ? "latest" : "v\(index + 1)",
                               isLatest: isHead))
            }
        }
        return out
    }

    private func row(for version: ManuscriptVersion, label: String, isLatest: Bool) -> Row {
        Row(
            id: version.id.uuidString,
            versionLabel: label,
            stamped: version.createdAt,
            from: parentDescription(version),
            to: label,
            byName: version.author.isEmpty ? "—" : version.author,
            byKey: version.stampedByKey,
            byMessage: SigningService.stampMessage(
                id: version.id, createdAt: version.createdAt, author: version.author),
            bySignature: version.stampSignature,
            version: version,
            isLatest: isLatest
        )
    }

    /// "Source v2" / "NEJM v1" / "—" — where a version was stamped/cut from.
    private func parentDescription(_ version: ManuscriptVersion) -> String {
        guard let pid = version.parentID,
              let parent = store.versions.first(where: { $0.id == pid }) else {
            return version.sourceStamp == true ? "Source" : "Source"
        }
        if parent.sourceStamp == true {
            return "Source v\(store.sourceOrdinal(of: parent))"
        }
        if parent.journalID == version.journalID {
            let chain = store.versions(forJournal: version.journalID)
            let idx = chain.firstIndex { $0.id == parent.id } ?? 0
            return "v\(idx + 1)"
        }
        if let jid = parent.journalID,
           let journal = manuscript?.journals.first(where: { $0.id == jid }) {
            return "\(journal.name) v\(store.journalOrdinal(of: parent))"
        }
        return parent.label.isEmpty ? "Custom" : parent.label
    }

    // MARK: Actions

    private var hasUnstampedChanges: Bool {
        if isSourcePane { return store.sourceHasUnstampedChanges }
        guard let journalID else { return false }
        return headHasNeverBeenStamped || store.headHasUnstampedChanges(journalID: journalID)
    }

    /// A journal whose only version is v1 can still stamp meaningfully.
    private var headHasNeverBeenStamped: Bool {
        guard let journalID else { return false }
        return store.versions(forJournal: journalID).count <= 1
    }

    private var selectedRow: Row? {
        rows.first { $0.id == selectedRowID }
    }

    private var canRollback: Bool {
        guard let row = selectedRow else { return false }
        return !row.isLatest && row.version != nil
    }

    private func stamp() {
        if isSourcePane {
            store.stampSource()
        } else if let journalID {
            store.stampVersion(journalID: journalID)
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Versions",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Add this journal a cut in Sync to start its history."))
            } else {
                table
            }
        }
        .alert("Can't Roll Back", isPresented: Binding(
            get: { rollbackError != nil },
            set: { if !$0 { rollbackError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rollbackError ?? "")
        }
        .confirmationDialog("Roll Back to \(selectedRow?.versionLabel ?? "")?",
                            isPresented: $confirmRollback) {
            Button("Roll Back and Drop Later Versions", role: .destructive) {
                if let version = selectedRow?.version {
                    rollbackError = store.rollback(to: version)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(rollbackMessage)
        }
    }

    private var rollbackMessage: String {
        guard let row = selectedRow, let version = row.version else { return "" }
        let droppedCount: Int
        if version.sourceStamp == true {
            droppedCount = store.sourceStamps.filter { $0.number > version.number }.count
        } else {
            droppedCount = store.versions(forJournal: version.journalID)
                .filter { $0.number > version.number }.count
        }
        return "Restores \(journalName) to \(row.versionLabel) (stamped \(row.stamped.formatted(date: .abbreviated, time: .shortened))) and drops the \(droppedCount) version\(droppedCount == 1 ? "" : "s") after it — changes in between are discarded."
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Label(journalName, systemImage: isSourcePane ? "doc.text" : "building.columns")
                .font(.headline)
            Text("\(rows.count) row\(rows.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                confirmRollback = true
            } label: {
                Label("Roll Back…", systemImage: "arrow.uturn.backward")
            }
            .disabled(!canRollback)
            .help("Restore the selected version and drop everything after it")

            Button {
                stamp()
            } label: {
                Label("Stamp Version", systemImage: "seal")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasUnstampedChanges)
            .help(hasUnstampedChanges
                  ? "Freeze the current content as a numbered version; latest moves to a new row"
                  : "No changes since the last stamp")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var table: some View {
        Table(rows, selection: $selectedRowID) {
            TableColumn("Version") { (row: Row) in
                HStack(spacing: 6) {
                    Text(row.versionLabel)
                        .fontWeight(row.isLatest ? .semibold : .regular)
                        .foregroundStyle(row.isLatest ? Color.accentColor : Color.primary)
                    if row.isLatest {
                        Text("working")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 70, ideal: 90)

            TableColumn("Stamped") { (row: Row) in
                Text(row.isLatest && row.version == nil
                     ? "edited \(row.stamped.formatted(date: .abbreviated, time: .shortened))"
                     : row.stamped.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(row.isLatest ? .secondary : .primary)
            }
            .width(min: 140, ideal: 170)

            TableColumn("From → To") { (row: Row) in
                Text("\(row.from) → \(row.to)")
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 170)

            TableColumn("By") { (row: Row) in
                SignatureBadge(
                    signerName: row.byName,
                    signerKey: row.byKey,
                    message: row.byMessage,
                    signature: row.bySignature,
                    authors: store.signatureAuthors
                )
            }
            .width(min: 120, ideal: 160)
        }
        .alternatingRowBackgrounds(.enabled)
    }
}
