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
        if let section, section.active {
            RichEditor(value: $content,
                       placeholder: "Start writing your \(section.title.lowercased())…",
                       versionRef: versionRef)
                .onChange(of: content) { _, new in
                    guard var s = self.section else { return }
                    s.content = new
                    store.updateSection(s, ref: versionRef)
                }
                .onAppear { loadSection(section) }
                .onChange(of: sectionID) { _, _ in
                    if let s = self.section { loadSection(s) }
                }
        } else if let section {
            // Section exists here but is deactivated for this journal.
            deactivatedState(title: section.title)
        } else {
            // Not present in this version (e.g. an older cut predating the section).
            notIncludedState
        }
    }

    /// Shown when the section is deactivated for this version: empty and uneditable.
    private func deactivatedState(title: String) -> some View {
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
    }
}
