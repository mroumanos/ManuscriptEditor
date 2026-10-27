// SectionEditorView.swift
//
// The main prose editor for a single manuscript body section
// (Introduction, Methods, Results, etc.).
//
// Layout:
//   TOP    — thin toolbar: section-type badge, editable title, word count
//   BOTTOM — full-height TextEditor for the section content
//
// The title can be edited inline by clicking the pencil-icon button.
// Content is saved to the store on every keystroke.

import SwiftUI

/// Full-page editor for one `ManuscriptSection`.
///
/// `sectionID` is a UUID rather than the section itself so the view can stay
/// alive across section content changes without needing to be recreated.
struct SectionEditorView: View {
    @Environment(ManuscriptStore.self) private var store

    /// The UUID of the section being edited.  Used to look up the section in the store.
    let sectionID: UUID

    /// Which version this editor edits (Source by default).
    var versionRef: VersionRef = .source

    /// Local copy of the section's prose content.
    @State private var content = RichText()
    /// Which section `content` was loaded for.  The pane is reused across
    /// sections, and its editor branch is absent while a section is
    /// deactivated — so without this, the last section's text sat in
    /// `content` and was written into whichever section was activated or
    /// opened next.  A write goes through only when the copy is that
    /// section's.
    @State private var loadedFor: UUID?

    /// The journal this pane belongs to, if it is a journal's tab.
    private var journal: Journal? { store.paneJournal(for: versionRef) }

    /// The journal's entry for this section — what makes it part of the
    /// submission — by title.
    private func entry(for section: ManuscriptSection) -> StructureSection? {
        journal?.structure?.journalEntries.first { $0.key == section.title.lowercased() }
    }

    /// Look up the section value from the targeted manuscript.  Matches by id
    /// first, then falls back to the same section *type* — a version snapshot
    /// keeps the source ids at cut time, but type-matching keeps comparison
    /// robust if the source section was later replaced.  Returns `nil` if the
    /// section isn't present in this version.
    private var section: ManuscriptSection? {
        let target = store.manuscript(for: versionRef)
        if let byID = target?.sections.first(where: { $0.id == sectionID }) { return byID }
        if let sourceType = store.manuscript?.sections.first(where: { $0.id == sectionID })?.type,
           sourceType != .custom {
            return target?.sections.first { $0.type == sourceType }
        }
        return nil
    }

    var body: some View {
        Group {
            if let section, section.active {
                RichEditor(value: $content,
                           placeholder: entry(for: section)?.formatNote.flatMap { $0.isEmpty ? nil : $0 }
                               ?? "Start writing your \(section.title.lowercased())…",
                           versionRef: versionRef,
                           formatItem: .section(section.id))
                    .onChange(of: content) { _, new in
                        // Only this section's own copy may be written back.
                        guard var s = self.section, loadedFor == s.id, s.content != new else { return }
                        s.content = new
                        store.updateSection(s, ref: versionRef)
                    }
                    .onAppear { loadSection(section) }
            } else if let section {
                // Section exists here but is deactivated for this journal.
                DeactivatedSectionState(title: section.title)
            } else {
                // Not present in this version (e.g. an older cut predating the section).
                notIncludedState
            }
        }
        // On the pane itself, not the editor branch: a section switch while
        // a deactivated one shows must still move the copy along.
        .onChange(of: sectionID) { _, _ in
            if let s = self.section { loadSection(s) } else { loadedFor = nil }
        }
        // The cut changed under the pane — a smart refresh, a sync into this
        // head, ⌘Z — so the local copy follows it.  The pane kept its own
        // copy of the old text through a refresh once, showed it, and wrote
        // it back over the new text at the next keystroke.
        .onChange(of: self.section?.content) { _, new in
            if let new, let s = self.section, loadedFor == s.id, new != content { content = new }
        }
    }


    private var notIncludedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Not included in this version")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Helpers

    /// Loads a fresh section's content into local state.
    /// Called on first appear and when navigating between sections.
    private func loadSection(_ section: ManuscriptSection) {
        content = section.content
        loadedFor = section.id
    }
}

// MARK: - Deactivated

/// What a pane shows when its section is deactivated in this journal:
/// nothing to edit, and the way back.  The same page for a text box and
/// a question series.
struct DeactivatedSectionState: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("“\(title)” is off for this journal")
                .font(.title3.weight(.semibold))
            Text("Deactivated sections are excluded from Checks and Export.\nYour text is kept — use the eye toggle above to bring it back.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
