// PaneSettingsPopover.swift
//
// The gear in a section pane's header, in a journal's tab — beside the eye,
// the preview and the notes: the journal's say about THIS section, edited
// where the writing happens — required, type, the prompt shown while it is
// empty, the AI context and the default content (its structure entry).
//
// Not how it prints.  A section can print in two documents of the outline,
// so typography, heading and options are edited on the Export page's row —
// the one place that names which copy.  See
// MasterContext/features/journal-templates.md §3.3.

import SwiftUI

struct PaneSettingsButton: View {
    @Environment(ManuscriptStore.self) private var store

    let item: SidebarItem
    let ref: VersionRef

    @State private var showing = false

    /// The journal and section this gear is for — a journal-content
    /// section, in a journal's tab.  Elsewhere there is no gear.
    private var target: (journal: Journal, section: ManuscriptSection)? {
        guard case .section(let id) = item,
              let journal = store.paneJournal(for: ref),
              let section = store.manuscript(for: ref)?.sections.first(where: { $0.id == id }),
              section.isJournalContent, section.sectionKind != .abstract
        else { return nil }
        return (journal, section)
    }

    var body: some View {
        if let target {
            Button { showing = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("This section at \(target.journal.name) — required, type, prompt, AI context, default content")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                JournalSectionSettings(journal: target.journal, section: target.section)
                    .padding(14)
                    .frame(width: 380)
            }
        }
    }
}
