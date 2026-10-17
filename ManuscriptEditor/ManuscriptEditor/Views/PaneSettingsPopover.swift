// PaneSettingsPopover.swift
//
// The gear at the end of a pane's format bar: everything a journal says
// about THIS component, edited where the writing happens.
//
//   In a journal's tab, for a section   the journal's structure entry —
//                                       required, type, the prompt shown
//                                       while it is empty, the AI context
//                                       and the default content.
//   Everywhere                          how it prints: the export item's
//                                       typography, heading and options —
//                                       the same form the Export page opens,
//                                       bound to the same item.
//
// There is no Structure page and the Export page mirrors these: a cut's
// active sections ARE its structure, and the gear is where each one's
// fields live.  See MasterContext/features/journal-templates.md §3.3.

import SwiftUI

struct PaneSettingsPopover: View {
    @Environment(ManuscriptStore.self) private var store

    let item: SidebarItem
    let ref: VersionRef

    private var journal: Journal? { store.paneJournal(for: ref) }
    private var content: Manuscript? { store.manuscript(for: ref) }
    private var section: ManuscriptSection? {
        guard case .section(let id) = item else { return nil }
        return content?.sections.first { $0.id == id }
    }

    /// This pane's export item and the document carrying it — the first
    /// copy; a write reaches every copy (`updateExportEntry`).
    private var exportEntry: (item: ExportItem, document: ExportDocument)? {
        guard let key = ManuscriptStore.exportItemKey(for: item) else { return nil }
        let config = store.exportConfig(forJournal: store.journalID(for: ref))
        for document in config.documents {
            if let found = document.items.first(where: { $0.type == key.type && $0.sectionID == key.sectionID }) {
                return (found, document)
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let journal, let section, section.isJournalContent, section.sectionKind != .abstract {
                JournalSectionSettings(journal: journal, section: section)
                Divider()
            }
            if let entry = exportEntry {
                Text("EXPORT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ComponentSettingsForm(
                    item: Binding(
                        get: { exportEntry?.item ?? entry.item },
                        set: { edited in
                            // Every copy of the component takes the change,
                            // each keeping its own id.
                            store.updateExportEntry(for: item, ref: ref, mutateItem: { copy in
                                var made = edited
                                made.id = copy.id
                                copy = made
                            })
                        }),
                    inherited: entry.document.format,
                    content: content)
            } else {
                Text("Not in the export outline — add it on the Export page to set how it prints.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}
