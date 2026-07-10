// ChecksView.swift
//
// The Checks panel: the live submission **checklist** for a journal — every
// requirement (word limits, asset limits, required sections, custom rules)
// evaluated against the pane's content with a green ✓ / red ✗ per rule.
//
// Version-aware: a journal pane evaluates that version's content against its
// own journal's requirements, so Checks renders one live pane per open tab in
// side-by-side (just like Abstract).  The Source pane picks a journal to check
// against.  Everything recomputes on every edit because the stores are
// `@Observable`.
//
// Requirements *editing* lives in the Journals settings (JournalDetailView);
// this pane is intentionally just the checklist.

import SwiftUI

struct ChecksView: View {
    @Environment(ManuscriptStore.self) private var store

    /// Which version this checklist evaluates (Source by default).
    var versionRef: VersionRef = .source

    /// Journal picked in the Source pane (version panes use their own journal).
    @State private var pickedJournalID: UUID?

    private var journals: [Journal] { store.manuscript?.journals ?? [] }

    /// The journal behind this pane's version, when it is journal-based.
    private var paneJournal: Journal? {
        guard case .version(let id) = versionRef,
              let jid = store.versions.first(where: { $0.id == id })?.journalID
        else { return nil }
        return journals.first { $0.id == jid }
    }

    /// The journal whose requirements drive this pane's checklist.
    private var activeJournal: Journal? {
        paneJournal
            ?? journals.first(where: { $0.id == pickedJournalID })
            ?? journals.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if store.manuscript(for: versionRef) == nil {
                    ContentUnavailableView("No manuscript open", systemImage: "doc")
                } else if let journal = activeJournal {
                    header(journal)
                    checklist(journal)
                } else {
                    noJournalState
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if pickedJournalID == nil { pickedJournalID = journals.first?.id }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ journal: Journal) -> some View {
        HStack {
            Text(journal.name).font(.headline)
            Spacer()
            // The Source pane can check against any journal.
            if paneJournal == nil, journals.count > 1 {
                Picker("Journal", selection: $pickedJournalID) {
                    ForEach(journals) { j in
                        Text(j.name).tag(Optional(j.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
        }
    }

    // MARK: - Checklist

    @ViewBuilder
    private func checklist(_ journal: Journal) -> some View {
        if let manuscript = store.manuscript(for: versionRef) {
            let results = ChecklistService.run(manuscript: manuscript,
                                               requirements: journal.requirements)
            summaryBanner(results)
            ForEach(results) { result in
                ChecklistRow(result: result)
            }
            if results.isEmpty {
                Text("This journal has no requirements configured yet — add limits and rules in its journal settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryBanner(_ results: [ChecklistResult]) -> some View {
        let passed  = results.filter(\.passed).count
        let total   = results.count
        let allPass = total > 0 && passed == total
        let color: Color = allPass ? .green : (passed == 0 ? .red : .orange)

        return HStack(spacing: 12) {
            Image(systemName: allPass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(allPass
                     ? "Ready to submit"
                     : "\(total - passed) item\(total - passed == 1 ? "" : "s") need attention")
                    .fontWeight(.semibold)
                Text("\(passed) of \(total) checks passed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Empty state

    private var noJournalState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("No Journal to Check Against")
                    .font(.title3.weight(.semibold))
                Text("Checks evaluate your content against a journal's requirements.\nCut a version for a journal in Versions to get started.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 400)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
