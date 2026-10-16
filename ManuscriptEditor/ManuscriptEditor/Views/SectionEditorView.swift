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
    /// The journal's settings for this section, open.
    @State private var showingJournalSettings = false

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
        if let section, section.active {
            RichEditor(value: $content,
                       placeholder: entry(for: section)?.formatNote.flatMap { $0.isEmpty ? nil : $0 }
                           ?? "Start writing your \(section.title.lowercased())…",
                       versionRef: versionRef,
                       formatItem: .section(section.id))
                // In a journal's tab, the journal's say about this section
                // sits where a pane keeps its settings: top right.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let journal {
                        HStack {
                            Spacer()
                            Button {
                                showingJournalSettings = true
                            } label: {
                                let inJournal = entry(for: section) != nil
                                Label(inJournal ? "In \(journal.name)" : "Not in \(journal.name)",
                                      systemImage: inJournal ? "checkmark.circle" : "circle.dashed")
                                    .font(.caption)
                                    .foregroundStyle(inJournal ? Color.secondary : Color.orange)
                            }
                            .buttonStyle(.borderless)
                            .help("Whether this section is part of a submission at \(journal.name), and the venue's say about it: required, type, prompt, AI context, default content")
                            .popover(isPresented: $showingJournalSettings, arrowEdge: .bottom) {
                                JournalSectionSettings(journal: journal, section: section)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(.bar)
                    }
                }
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


// MARK: - The journal's say about a section

/// Edited from the section itself, in a journal's tab: whether the section
/// is part of a submission here, whether it is required, its type, the
/// prompt shown while it is empty, the AI context, and the default content
/// — the journal's own structure entry, so the Structure page needs no
/// page of its own.
struct JournalSectionSettings: View {
    @Environment(ManuscriptStore.self) private var store

    let journal: Journal
    let section: ManuscriptSection

    private var structure: JournalStructure { journal.structure ?? JournalStructure() }
    private var entry: StructureSection? {
        structure.journalEntries.first { $0.key == section.title.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Part of a submission at \(journal.name)", isOn: Binding(
                get: { entry != nil },
                set: { on in
                    var edited = structure
                    if on, entry == nil {
                        var made = StructureSection(title: section.title)
                        made.type = section.sectionKind == .questions ? .questions : .text
                        edited.sections.append(made)
                    } else if !on, let entry {
                        edited.sections.removeAll { $0.uid == entry.uid }
                    }
                    store.updateStructure(edited, journalID: journal.id)
                }))
            if let entry {
                Toggle("Required", isOn: field(\.required, entry))
                Picker("Type", selection: Binding(
                    get: { entry.type == .questions ? SectionKind.questions : .text },
                    set: { value in update(entry) { $0.type = value } })) {
                    Text("Text").tag(SectionKind.text)
                    Text("Questions").tag(SectionKind.questions)
                }
                TextField("Prompt — shown while the section is empty; sent when adapting", text: Binding(
                    get: { entry.formatNote ?? "" },
                    set: { value in update(entry) { $0.formatNote = value.isEmpty ? nil : value } }))
                TextField("AI context (optional — sent when adapting)", text: Binding(
                    get: { entry.note ?? "" },
                    set: { value in update(entry) { $0.note = value.isEmpty ? nil : value } }))
                Text("DEFAULT CONTENT").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                TextEditor(text: Binding(
                    get: { entry.boilerplate ?? "" },
                    set: { value in update(entry) { $0.boilerplate = value.isEmpty ? nil : value } }))
                    .font(.body)
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Text("The boilerplate a new cut starts with — `[[title]]`, `[[authors.names]]` resolve. Prompt, AI context and this all go to the model on a fast-forward.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 360)
    }

    private func field(_ keyPath: WritableKeyPath<StructureSection, Bool>, _ entry: StructureSection) -> Binding<Bool> {
        Binding(get: { entry[keyPath: keyPath] }, set: { value in update(entry) { $0[keyPath: keyPath] = value } })
    }

    private func update(_ entry: StructureSection, _ mutate: (inout StructureSection) -> Void) {
        var edited = structure
        guard let idx = edited.sections.firstIndex(where: { $0.uid == entry.uid }) else { return }
        mutate(&edited.sections[idx])
        store.updateStructure(edited, journalID: journal.id)
    }
}
