// TemplateOverviewView.swift
//
// A template's identity, and the three things you can do to it.
//
// Deliberately NOT a manuscript's Overview: no lineage graph, no versions
// list, no backend settings.  A template is a small shared document — a name,
// a type, a description, and the four parts edited in the panes beside this
// one.  What belongs here is what a manuscript's Overview has no equivalent
// of: what a save means.
//
//   Save                keeps the GUID, takes the next version, and rewrites
//                       every part's checksum.  Re-saving an untouched
//                       template takes no version — nobody else's copy should
//                       look stale because you pressed Save.
//   Save as New…        a new GUID at version 1, remembering where it came
//                       from, so "the same template, later" and "a different
//                       template" stay different questions.
//   Delete              gone from your library.  Manuscripts already using it
//                       keep their own copy and travel with it.
//
// See MasterContext/features/journal-templates.md §3.2 and §3.6.

import SwiftUI
import AppKit

struct TemplateOverviewView: View {
    @Environment(TemplateWorkspace.self) private var templates
    @Environment(ManuscriptStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    let templateID: UUID

    @State private var savingAsNew = false
    @State private var newName = ""
    @State private var confirmingSave = false
    @State private var confirmingDelete = false
    @State private var confirmingRevert = false
    @State private var shareError: String?

    private var template: JournalTemplate? { templates.template(templateID) }
    private var isDirty: Bool { templates.isDirty(templateID) }
    private var editedParts: Set<ProfilePart> { templates.editedParts(templateID) }

    /// Journals in the open manuscript that follow this template — who a save
    /// actually reaches.  Their own copy is what they evaluate against, so a
    /// save doesn't change them until they Load it; saying so is the point.
    private var usedBy: [Journal] {
        (store.manuscript?.journals ?? []).filter { $0.profileID == templateID }
    }

    var body: some View {
        VStack(spacing: 0) {
            TemplatePaneHeader(templateID: templateID, title: "Overview",
                               subtitle: "What this template is, and what saving it does.")
            ScrollView {
                if let template {
                    VStack(alignment: .leading, spacing: 16) {
                        identity(template)
                        parts(template)
                        actions(template)
                        sharing(template)
                        travelling
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .alert("Couldn't Share Template", isPresented: Binding(
            get: { shareError != nil }, set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(shareError ?? "")
        }
        .alert("Save as a New Template", isPresented: $savingAsNew) {
            TextField("Name", text: $newName)
            Button("Save as New") {
                _ = templates.saveAsNew(templateID, named: newName)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Creates a separate template with its own identity, at version 1, remembering that it came from “\(template?.displayName ?? "")”. This one is left exactly as it is — including the edits you haven't saved.")
        }
        .confirmationDialog(saveTitle, isPresented: $confirmingSave, titleVisibility: .visible) {
            Button("Save") { templates.save(templateID) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(saveMessage)
        }
        .confirmationDialog("Discard your changes to “\(template?.displayName ?? "")”?",
                            isPresented: $confirmingRevert, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { templates.revert(templateID) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everything goes back to the template as your library holds it. This cannot be undone with ⌘Z — a template lives outside any manuscript.")
        }
        .confirmationDialog("Delete “\(template?.displayName ?? "")” from your library?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { templates.delete(templateID) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: - Identity

    @ViewBuilder
    private func identity(_ template: JournalTemplate) -> some View {
        // Typed straight into the draft: nothing here reaches the library
        // until Save, so there is no reason to make you press Enter twice.
        Form {
            Section("Template") {
                TextField("Name", text: Binding(
                    get: { template.name },
                    set: { value in templates.edit(templateID) { $0.name = value } }))
                TextField("Type (Research Article, Research Brief…)", text: Binding(
                    get: { template.articleType ?? "" },
                    set: { value in
                        let trimmed = value.trimmingCharacters(in: .whitespaces)
                        templates.edit(templateID) { $0.articleType = trimmed.isEmpty ? nil : trimmed }
                    }))
                VStack(alignment: .leading, spacing: 4) {
                    TextField("What this format is for", text: Binding(
                        get: { template.summaryDescription },
                        set: { value in templates.edit(templateID) { $0.summaryDescription = value } }),
                              axis: .vertical)
                        .lineLimit(2...5)
                    Text("Stored as the summary's `description:` bullets — one place to say what this format is, rather than two that disagree.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 210)
        .scrollDisabled(true)

        HStack(spacing: 14) {
            fact("Version", "\(template.version)")
            fact("Last saved", template.updatedAt?
                .formatted(date: .abbreviated, time: .shortened) ?? "never")
            fact("Identity", String(template.id.uuidString.prefix(8)).lowercased())
            if !template.lineage.isEmpty {
                fact("Branched from",
                     JournalProfileLibrary.shared.profile(id: template.lineage[0])?.displayName
                        ?? String(template.lineage[0].uuidString.prefix(8)).lowercased())
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    // MARK: - Parts

    /// Which of the four parts you have moved, and by how much — the same
    /// orange pencil the sidebar shows, gathered in one place so "what am I
    /// about to save" has an answer before you press it.
    @ViewBuilder
    private func parts(_ template: JournalTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PARTS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                ForEach(ProfilePart.displayOrder) { part in
                    let edited = editedParts.contains(part)
                    HStack(spacing: 4) {
                        Image(systemName: edited ? "pencil.circle.fill" : "checkmark.circle")
                            .foregroundStyle(edited ? AnyShapeStyle(Color.orange)
                                                    : AnyShapeStyle(.tertiary))
                        Text(part.label)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor), in: Capsule())
                    .help(edited
                          ? "Edited since the last save — its checksum will change"
                          : "Unchanged since the last save")
                }
                Spacer()
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(_ template: JournalTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    confirmingSave = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty)
                .help(isDirty
                      ? "Overwrite this template in your library: same identity, next version"
                      : "Nothing to save — this matches your library")

                Button {
                    newName = "\(template.name) copy"
                    savingAsNew = true
                } label: {
                    Label("Save as New…", systemImage: "doc.on.doc")
                }
                .help("A separate template with its own identity, starting at version 1")

                Button("Discard Changes") { confirmingRevert = true }
                    .disabled(!isDirty)

                Spacer()

                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete", systemImage: "trash").foregroundStyle(.red)
                }
            }
            if !usedBy.isEmpty {
                Text("Used by \(usedBy.map(\.name).joined(separator: ", ")) in this manuscript. They each keep their own copy — a save here reaches them when they Load it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var saveTitle: String {
        isDirty ? "Overwrite “\(template?.displayName ?? "")” in your library?"
                : "Save “\(template?.displayName ?? "")”?"
    }

    private var saveMessage: String {
        let parts = ProfilePart.displayOrder.filter(editedParts.contains).map(\.label)
        let changed = parts.isEmpty ? "Nothing has changed" : "Changes: \(parts.joined(separator: ", "))"
        return "\(changed). The template keeps its identity and becomes version \((template?.version ?? 1) + (isDirty ? 1 : 0)), with a fresh checksum for every part. Manuscripts follow it by identity, so they stay linked — and keep their own copy until they Load this one."
    }

    private var deleteMessage: String {
        var text = "Manuscripts already using it keep their own copy — they'll show as edited, with nothing to compare against."
        if !usedBy.isEmpty {
            text = "\(usedBy.map(\.name).joined(separator: ", ")) in this manuscript " +
                   "\(usedBy.count == 1 ? "uses" : "use") it. " + text
        }
        return text
    }

    // MARK: - Sharing

    @ViewBuilder
    private func sharing(_ template: JournalTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SHARING")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                Button {
                    exportSingleFile(template)
                } label: {
                    Label("Export Template File…", systemImage: "square.and.arrow.up")
                }
                .help("One file — \(TemplateFile.fileName(for: template)) — carrying all four parts, the identity and the checksum")

                Button {
                    exportFolder(template)
                } label: {
                    Label("Export for Pull Request…", systemImage: "folder.badge.plus")
                }
                .help("The repository layout: a folder of four JSON files, ready to add under ManuscriptEditor/JournalProfiles/")
                Spacer()
            }
            Text("Sending someone the file is enough: identity is a GUID, so importing it says whether it is one they already have and which parts differ. Contributing it to the app is a pull request adding the folder — same identity, reviewable as a diff.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every template ships with the manuscript — stated here because it is
    /// the question people ask when they edit one: does my collaborator get
    /// this?
    private var travelling: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
            Text("Every manuscript carries the rules it was written to. Each journal writes its template into journals/<template>/ on every save, modified or not, so a collaborator opens it with the rules you used.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func exportSingleFile(_ template: JournalTemplate) {
        let panel = NSSavePanel()
        panel.title = "Export Journal Template"
        panel.nameFieldStringValue = TemplateFile.fileName(for: template)
        panel.message = "One file carrying all four parts, the identity and the checksum."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let error = TemplateFile.write(template, to: url) {
            shareError = error
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func exportFolder(_ template: JournalTemplate) {
        let panel = NSOpenPanel()
        panel.title = "Export Template Folder"
        panel.message = "Choose where to write <slug>/{requirements,checks,structure,export}.json — the layout ManuscriptEditor/JournalProfiles/ uses."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch TemplateFile.writeFolder(template, into: url) {
        case .success(let folder): NSWorkspace.shared.activateFileViewerSelecting([folder])
        case .failure(let error):  shareError = error.message
        }
    }
}
