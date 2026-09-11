// TemplateWorkspace.swift
//
// The templates currently open for editing, and the one rule that governs
// them: **an edit is held in memory until it is saved.**
//
// A template is not a manuscript.  It has no versions of its own, no undo
// stack, no autosave — it is a small document that many manuscripts depend on,
// so a keystroke here must not reach anybody's paper.  Nothing this class does
// touches the library until `save`, `clone` or `delete` is called, and each of
// those is confirmed where it is offered.
//
//   Edit, don't save   →  held here.  Close the tab and it is offered back;
//                         discard it and the library is untouched.
//   Save               →  same GUID, next version, fresh per-part checksums
//                         (`JournalProfileLibrary.save`).
//   Save as new        →  new GUID, version 1, lineage back to the original
//                         (`JournalProfileLibrary.clone`).
//   Delete             →  gone from the library; manuscripts keep their copy.
//
// See MasterContext/features/journal-templates.md §3.
//
// One instance, injected into the environment like the two stores, because a
// template opened from Settings has to appear in the main window's tab bar.

import Foundation

@MainActor
@Observable
final class TemplateWorkspace {

    /// The open templates, in tab order.  Order is the tab bar's; the drafts
    /// are the content.
    private(set) var openIDs: [UUID] = []

    /// Each open template as it is being edited.  Seeded from the library
    /// when it opens and never written back on its own.
    private(set) var drafts: [UUID: JournalTemplate] = [:]

    private var library: JournalProfileLibrary { .shared }

    // MARK: - Opening and closing

    /// Opens a template for editing, seeding the draft from the library.
    /// Already open: left exactly as it is, edits and all.
    @discardableResult
    func open(_ id: UUID) -> Bool {
        if drafts[id] != nil {
            if !openIDs.contains(id) { openIDs.append(id) }
            return true
        }
        guard let template = library.profile(id: id) else { return false }
        drafts[id] = template
        openIDs.append(id)
        return true
    }

    func close(_ id: UUID) {
        openIDs.removeAll { $0 == id }
        drafts[id] = nil
    }

    func isOpen(_ id: UUID) -> Bool { drafts[id] != nil }

    /// The draft, or the library's copy for anything not open.
    func template(_ id: UUID) -> JournalTemplate? {
        drafts[id] ?? library.profile(id: id)
    }

    // MARK: - Editing

    /// Edits the draft in memory.  Nothing else happens — no file is written,
    /// no manuscript changes, and no other window is told.
    func edit(_ id: UUID, _ mutate: (inout JournalTemplate) -> Void) {
        guard var draft = drafts[id] else { return }
        mutate(&draft)
        drafts[id] = draft
    }

    /// Replaces the template's export outline.  Only that: the outline is the
    /// one place formats live, and nothing is mirrored into the structure.
    ///
    /// It used to be — every outline edit rewrote `coreFormats`,
    /// `documentFormat` and each section's `format` — which made changing a
    /// font show up as a change to the STRUCTURE, and coupled two parts that
    /// answer different questions ("what is a submission made of?" and "how
    /// is it set?").  Export options are in Export.
    func setExport(_ config: ExportConfig, for id: UUID) {
        edit(id) { $0.export = config }
    }

    /// The outline pointed at THIS template's sections.
    ///
    /// An outline saved from a manuscript names that manuscript's sections by
    /// id, and those ids mean nothing here — every one of them rendered as
    /// "(missing section)".  Unknown section items are dropped and the
    /// template's own body sections take their place, in Structure order.
    /// The cover letter is an item of its own kind, never a section.
    static func repaired(_ config: ExportConfig, for template: JournalTemplate) -> ExportConfig {
        let body = template.structure.sections.filter { $0.role == nil }
        let known = Set(body.map(\.uid))
        var out = config
        var seen: Set<UUID> = []
        for d in out.documents.indices {
            out.documents[d].items.removeAll { item in
                guard item.kind == .section else { return false }
                guard let id = item.sectionID, known.contains(id) else { return true }
                return !seen.insert(id).inserted        // and no duplicates
            }
        }
        let missing = body.filter { !seen.contains($0.uid) }
        if !missing.isEmpty,
           let main = out.documents.firstIndex(where: { !$0.isAttachment }) {
            let items = out.documents[main].items
            let insertAt = items.lastIndex { $0.kind == .section }.map { $0 + 1 } ?? items.count
            out.documents[main].items.insert(
                contentsOf: missing.map { ExportItem(kind: .section, sectionID: $0.uid) },
                at: insertAt)
        }
        // The cover letter is in the outline exactly when the template has
        // one.  It appeared in Export with no letter in the sidebar to match,
        // which read as a section that had gone missing.
        let hasLetter = template.structure.sections.contains { $0.role == .letter }
        let hasLetterItem = out.documents.contains { $0.items.contains { $0.kind == .coverLetter } }
        if !hasLetter, hasLetterItem {
            for d in out.documents.indices {
                out.documents[d].items.removeAll { $0.kind == .coverLetter }
            }
            out.documents.removeAll { !$0.isAttachment && $0.items.allSatisfy { $0.kind == .pageBreak } }
        } else if hasLetter, !hasLetterItem {
            out.documents.append(ExportDocument(name: "Cover Letter",
                                                items: [ExportItem(kind: .coverLetter)]))
        }
        return out
    }

    /// Whether this draft has moved away from the library's copy.
    ///
    /// Compared on content and identity — the checksum covers the rules, and
    /// name and type are not in it deliberately (a template stays itself
    /// through a rename), so they are compared here.
    func isDirty(_ id: UUID) -> Bool {
        guard let draft = drafts[id] else { return false }
        guard let stored = library.profile(id: id) else { return true }
        return draft.checksum != stored.checksum
            || draft.name != stored.name
            || draft.articleType != stored.articleType
    }

    /// Which parts differ from the library's copy — what the sidebar marks.
    func editedParts(_ id: UUID) -> Set<ProfilePart> {
        guard let draft = drafts[id], let stored = library.profile(id: id) else { return [] }
        return Set(ProfilePart.allCases.filter { draft.fingerprint($0) != stored.fingerprint($0) })
    }

    // MARK: - Saving

    /// Overwrite: same GUID, next version, new checksums.
    @discardableResult
    func save(_ id: UUID) -> Bool {
        guard let draft = drafts[id] else { return false }
        guard library.save(draft) else { return false }
        // Re-seed from what was actually written, so the version and
        // checksums on screen are the ones on disk.
        drafts[id] = library.profile(id: id) ?? draft
        return true
    }

    /// Save as a new template: new GUID, version 1, lineage back to this one.
    /// The new template is opened in place of nothing — the original stays
    /// open, unchanged on disk, with its edits still in memory.
    @discardableResult
    func saveAsNew(_ id: UUID, named name: String) -> UUID? {
        guard let draft = drafts[id] else { return nil }
        guard let made = library.clone(draft, named: name) else { return nil }
        drafts[made.id] = made
        if !openIDs.contains(made.id) { openIDs.append(made.id) }
        return made.id
    }

    /// Discards the draft's edits, reverting to the library's copy.
    func revert(_ id: UUID) {
        guard let stored = library.profile(id: id) else { return }
        drafts[id] = stored
    }

    /// Removes the template from the library and closes it.
    func delete(_ id: UUID) {
        library.remove(id: id)
        close(id)
    }

    // MARK: - Creating

    /// A new, empty template, opened for editing.
    @discardableResult
    func createAndOpen(named name: String, articleType: String? = nil) -> UUID? {
        guard let made = library.createEmpty(named: name, articleType: articleType)
        else { return nil }
        drafts[made.id] = made
        openIDs.append(made.id)
        return made.id
    }
}
