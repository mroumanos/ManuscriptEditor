// TemplatePartEditors.swift
//
// A template's Tests and Export, edited.  (Details is its own file; the
// structure has no pane — it is the sections in the sidebar.)
//
// The same pages in the same order a journal cut shows them, because they are
// the same things — a venue's rules, and your copy of them.  What differs is
// who owns the edit: here it is the template, held in memory until Details
// saves it; in a manuscript it is that manuscript's own copy.
//
// See MasterContext/features/journal-templates.md §3.2–§3.4.

import SwiftUI

// MARK: - Tests

/// One test per requirement, written against the venue's rules rather than
/// against any one manuscript.
///
/// No pass rate here, deliberately: a template has no content to measure, and
/// a percentage with nothing behind it would be a number people trusted.  The
/// rate belongs to a cut, where the sidebar carries it — "Tests (86%)".
struct TemplateTestsView: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID

    private var template: JournalTemplate? { templates.template(templateID) }

    var body: some View {
        VStack(spacing: 0) {
            TemplatePaneHeader(
                templateID: templateID, title: "Tests",
                subtitle: detail)

            if template != nil {
                ScrollView {
                    CheckRulesList(
                        rules: Binding(
                            get: { templates.template(templateID)?.checks ?? [] },
                            set: { value in templates.edit(templateID) { $0.checks = value } }),
                        sectionTitles: sectionTitles)
                        .padding(20)
                        .frame(maxWidth: TemplateLayout.contentWidth, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detail: String {
        guard let template, !template.checks.isEmpty else {
            return "Every requirement that can be checked. Sections the venue requires should each have their own EXISTS test, so a missing one names itself."
        }
        let manual = template.checks.filter(\.isManual).count
        return "\(template.checks.count) test\(template.checks.count == 1 ? "" : "s") · "
            + "\(template.checks.count - manual) automatic, \(manual) manual"
    }

    /// The venue's own sections — what a condition can be scoped to here.
    /// A template has no manuscript behind it, so its structure is the list.
    private var sectionTitles: [String] {
        (template?.structure.sections ?? []).map(\.title)
    }
}

// MARK: - Export

/// How this venue sets a submission: **the same outline editor a manuscript
/// has**, over the template's own sections.
///
/// The export options used to be scattered — a format popover on each section,
/// a list of fixed parts here — which meant learning two places and keeping
/// them in step by hand.  One place: the outline. `ExportDocumentCard` is
/// literally the card the Export pane shows for a manuscript, given the
/// template's sections instead of a paper's, so a venue's typography is
/// arranged exactly where anyone already knows how to arrange it.
///
/// What a journal ADOPTS when it is added still comes from the structure
/// (`coreFormats`, `documentFormat`, each section's `format`); those are
/// derived from this outline on every change — see
/// `TemplateWorkspace.setExport`.
struct TemplateExportView: View {
    @Environment(TemplateWorkspace.self) private var templates

    let templateID: UUID

    /// The outline being edited.  Held in state, not recomputed per access:
    /// a template that never configured one gets the standard outline
    /// DERIVED, and a derivation mints fresh item ids every time — so the
    /// settings popover bound "by id" edited an item that no longer existed
    /// by the next render, and the row's summary never moved.  (The
    /// manuscript's Export pane learned the same lesson first.)
    @State private var config = ExportConfig(documents: [])

    private var template: JournalTemplate? { templates.template(templateID) }

    /// The template's sections as a manuscript, so the outline can name them.
    private var asManuscript: Manuscript? {
        template.map(TemplateWorkspace.asManuscript)
    }

    /// What the state is seeded from: the stored outline, or the standard one
    /// derived from the template's sections — repaired either way.
    private func seed() -> ExportConfig {
        guard let template else { return ExportConfig(documents: []) }
        if let export = template.export, !export.documents.isEmpty {
            return TemplateWorkspace.repaired(export, for: template)
        }
        return TemplateWorkspace.standardOutline(for: template)
    }

    var body: some View {
        VStack(spacing: 0) {
            TemplatePaneHeader(
                templateID: templateID, title: "Export",
                subtitle: "The documents a submission here is, what goes in each, and how every part is set. A journal cut from this template adopts it.")

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(config.documents) { document in
                        ExportDocumentCard(
                            document: document,
                            content: asManuscript,
                            onChange: { replace($0) },
                            onDelete: { remove(document.id) })
                    }

                    HStack(spacing: 12) {
                        Button {
                            var edited = config
                            edited.documents.append(ExportDocument(name: "New Document", items: []))
                            commit(edited)
                        } label: {
                            Label("Add Document", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        if template?.export == nil {
                            Text("Not configured — this is the standard outline, derived from the sections above. Change anything and it becomes this template's.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }

                    Text("Page geometry sits on the Section rows, typography on each component — the same places a manuscript keeps them. A journal added from this template takes all of it, and can then change its own copy freely.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: TemplateLayout.exportWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { config = seed() }
        .onChange(of: templateID) { _, _ in config = seed() }
        // Sections added or removed in Structure appear here at once; an
        // edit made HERE round-trips through the draft unchanged.
        .onChange(of: template?.structure.sections.map(\.uid)) { _, _ in config = seed() }
        .onChange(of: template?.export) { _, new in
            if let new, new != config { config = seed() }
        }
    }

    /// Writes the outline into the draft and keeps the state in step.
    private func commit(_ edited: ExportConfig) {
        config = edited
        templates.setExport(edited, for: templateID)
    }

    private func replace(_ document: ExportDocument) {
        var edited = config
        guard let index = edited.documents.firstIndex(where: { $0.id == document.id }) else { return }
        edited.documents[index] = document
        commit(edited)
    }

    private func remove(_ id: UUID) {
        var edited = config
        edited.documents.removeAll { $0.id == id }
        commit(edited)
    }
}
