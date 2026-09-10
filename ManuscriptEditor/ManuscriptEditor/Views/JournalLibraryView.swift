// JournalLibraryView.swift
//
// Settings → Journals: the **template library**.  Search reusable
// journal profiles and inspect their details (name, country, publisher, how
// many requirements they carry, whether they bundle an export outline).
// Entries come from the built-in presets, "Save to Journal Library" in a
// manuscript's Export/Checks panes, and manual editing here.  Adding a
// journal to a manuscript (Sync → Add Journal) picks from this library.

import SwiftUI

struct JournalLibraryView: View {
    @Environment(AppStore.self) private var appStore

    @State private var query = ""
    @State private var selectedID: UUID?

    /// The library is the **profile** library — the same one a manuscript
    /// saves to, adds from, and diffs against.  It used to list a second,
    /// parallel registry, which is why a profile saved from a manuscript never
    /// appeared when adding a journal.
    private var profiles: [JournalProfile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = JournalProfileLibrary.shared.profiles.values
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.displayName.lowercased().contains(q)
                || (registry(for: $0)?.publisher ?? "").lowercased().contains(q)
                || (registry(for: $0)?.country ?? "").lowercased().contains(q)
        }
    }

    /// The old registry entry behind a profile, for the details a profile
    /// doesn't carry (publisher, country).
    private func registry(for profile: JournalProfile) -> Journal? {
        appStore.journalLibrary.first {
            $0.name == profile.name && $0.articleType == profile.articleType
        } ?? appStore.journalLibrary.first { $0.name == profile.name }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search templates…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)

                List(selection: $selectedID) {
                    ForEach(profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).fontWeight(.medium)
                                Text([profile.articleType, registry(for: profile)?.publisher,
                                      registry(for: profile)?.country]
                                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                                    .joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(profile.checks.count) tests")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .tag(profile.id)
                        .contextMenu {
                            Button("Delete Profile", role: .destructive) { delete(profile) }
                        }
                    }
                }
                .listStyle(.plain)

                Divider()
                HStack {
                    Button {
                        if let made = JournalProfileLibrary.shared
                            .createEmpty(named: "New Template", articleType: nil) {
                            selectedID = made.id
                        }
                    } label: {
                        Label("Add Template", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .padding(10)
                    .help("An empty template — its rules are written from a manuscript that adopts it")
                    Spacer()
                    Text("\(profiles.count) template\(profiles.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 10)
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let profile = JournalProfileLibrary.shared.profile(id: id) {
            LibraryProfileDetail(profile: profile, registry: registry(for: profile)) {
                delete(profile)
            }
        } else {
            ContentUnavailableView(
                "No Template Selected",
                systemImage: "building.columns",
                description: Text("Pick a template to see what it requires. Its rules are edited from a manuscript that uses it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    fileprivate func delete(_ profile: JournalProfile) {
        JournalProfileLibrary.shared.remove(id: profile.id)
        // Drop the matching registry entry too, so one delete means one thing.
        if let idx = appStore.journalLibrary.firstIndex(where: {
            $0.name == profile.name && $0.articleType == profile.articleType
        }) {
            appStore.deleteLibraryJournals(at: IndexSet([idx]))
        }
        if selectedID == profile.id { selectedID = nil }
    }
}

// MARK: - LibraryProfileDetail

/// A profile as Settings shows it: the same Summary / Structure / Export rows
/// the manuscript's profile pane has, and its tests compressed to one line
/// each.
///
/// Read-only, and Export's Open is **disabled**: an outline is edited against a
/// manuscript's actual content, so there is nothing here to open it on. Saying
/// that in the row is better than hiding it and leaving the shape different
/// from the pane people already know.
private struct LibraryProfileDetail: View {
    let profile: JournalTemplate
    let registry: Journal?
    let onDelete: () -> Void

    @State private var nameDraft = ""
    @State private var typeDraft = ""
    @State private var countryDraft = ""
    @State private var loadedFor: UUID?

    /// Which component's read-only view is open.
    @State private var openPart: ProfilePart?
    @State private var cloning = false
    @State private var cloneName = ""
    @State private var confirmingDelete = false
    @State private var confirmingRename = false

    @Environment(AppStore.self) private var appStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Metadata is editable here; the RULES are not.  A template's
                // tests are written against a manuscript's real content, so
                // there is nothing here to write them against.
                // Typing here changes nothing until Rename is pressed.  A
                // template lives outside any manuscript, so renaming it cannot
                // be undone with ⌘Z — and a change that can't be undone should
                // not happen because a field lost focus.
                Form {
                    Section("Template") {
                        TextField("Name", text: $nameDraft)
                        TextField("Type (Research Article, Research Brief…)", text: $typeDraft)
                        TextField("Country", text: $countryDraft)
                        HStack {
                            Text(metadataChanged
                                 ? "Not saved yet — renaming a template can't be undone."
                                 : "Renaming a template can't be undone.")
                                .font(.caption)
                                .foregroundStyle(metadataChanged
                                                 ? AnyShapeStyle(Color.orange)
                                                 : AnyShapeStyle(.tertiary))
                            Spacer()
                            Button("Revert") { loadedFor = nil; loadDrafts() }
                                .disabled(!metadataChanged)
                            Button("Rename…") { confirmingRename = true }
                                .disabled(!metadataChanged)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(height: 190)

                // The same four components, in the same order, opening the
                // same read-only view the profile pane opens — a template
                // should not look like a different object depending on where
                // you meet it.
                VStack(spacing: 0) {
                    row(.requirements, "doc.text", summaryDetail)
                    Divider()
                    row(.structure, "list.bullet.indent", contentDetail)
                    Divider()
                    row(.checks, "checklist",
                        profile.checks.isEmpty
                            ? "No tests recorded"
                            : "\(profile.checks.count) tests · \(profile.checks.filter { !$0.isManual }.count) automatic, \(profile.checks.filter(\.isManual).count) manual")
                    Divider()
                    row(.export, "square.and.arrow.up", exportDetail)
                }
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

                Text("A template's summary, structure, tests and export outline are edited from a manuscript that uses it — add this template to a manuscript, change it there, and save it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        cloneName = "\(profile.name) copy"
                        cloning = true
                    } label: {
                        Label("Clone", systemImage: "doc.on.doc")
                    }
                    .help("A copy under a new identity, carrying these rules — edit the copy from a manuscript")
                    Spacer()
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete", systemImage: "trash").foregroundStyle(.red)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: loadDrafts)
        .onChange(of: profile.id) { _, _ in loadDrafts() }
        .sheet(item: $openPart) { part in
            TemplatePartSheet(template: profile, part: part,
                              isPresented: Binding(get: { openPart != nil },
                                                   set: { if !$0 { openPart = nil } }))
        }
        .alert("Clone Template", isPresented: $cloning) {
            TextField("Name for the copy", text: $cloneName)
            Button("Clone") {
                _ = JournalProfileLibrary.shared.clone(profile, named: cloneName)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A copy of “\(profile.displayName)” with its own identity, carrying the same rules and remembering where it came from.")
        }
        .confirmationDialog("Rename “\(profile.displayName)”?",
                            isPresented: $confirmingRename, titleVisibility: .visible) {
            Button("Rename") { commitMetadata(); commitCountry() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Becomes “\(nameDraft.trimmingCharacters(in: .whitespaces))\(typeDraft.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " — " + typeDraft.trimmingCharacters(in: .whitespaces))”. Manuscripts stay linked to it — they follow the identity, not the name — but this cannot be undone with ⌘Z.")
        }
        .confirmationDialog("Delete “\(profile.displayName)” from your library?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Manuscripts already using it keep their own copy — they'll show as edited, with nothing to compare against.")
        }
    }

    /// Whether the fields differ from what is stored.
    private var metadataChanged: Bool {
        nameDraft.trimmingCharacters(in: .whitespaces) != profile.name
            || typeDraft.trimmingCharacters(in: .whitespaces) != (profile.articleType ?? "")
            || countryDraft.trimmingCharacters(in: .whitespaces) != (registry?.country ?? "")
    }

    private func loadDrafts() {
        guard loadedFor != profile.id else { return }
        loadedFor = profile.id
        nameDraft = profile.name
        typeDraft = profile.articleType ?? ""
        countryDraft = registry?.country ?? ""
    }

    private func commitMetadata() {
        let name = nameDraft.trimmingCharacters(in: .whitespaces)
        let type = typeDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              name != profile.name || type != (profile.articleType ?? "") else { return }
        _ = JournalProfileLibrary.shared.rename(id: profile.id, name: name,
                                                articleType: type.isEmpty ? nil : type)
        loadedFor = nil
    }

    /// Country isn't part of a template's rules, so it stays on the registry
    /// entry that carries publisher and country for display.
    private func commitCountry() {
        let country = countryDraft.trimmingCharacters(in: .whitespaces)
        var entry = registry ?? {
            var made = Journal.empty()
            made.name = profile.name
            made.articleType = profile.articleType
            return made
        }()
        entry.country = country.isEmpty ? nil : country
        appStore.upsertLibraryJournal(entry)
    }

    private var summaryDetail: String {
        guard !profile.requirements.bullets.isEmpty else { return "No summary recorded" }
        let counts = SourceRequirements.categoryCounts(profile.requirements.bullets)
        let parts = SourceRequirements.categoryOrder.compactMap { key in
            counts[key].map { "\($0) \(key)" }
        }
        let total = "\(profile.requirements.bullets.count) requirements"
        return parts.isEmpty ? total : "\(total) · \(parts.joined(separator: ", "))"
    }

    private var exportDetail: String {
        guard let export = profile.export, !export.documents.isEmpty else {
            return "Not configured — manuscripts derive the standard outline"
        }
        let format = export.documents[0].format
        return "\(export.documents.count) document\(export.documents.count == 1 ? "" : "s") · "
            + "\(String(format: "%g", format.fontSize)) pt · "
            + "\(String(format: "%g", format.lineSpacing))× spacing"
    }

    private func row(_ part: ProfilePart, _ icon: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(part.label).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open…") { openPart = part }
                .controlSize(.small)
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
    }

    /// The same one-line summary the profile pane shows for Content.
    private var contentDetail: String {
        let structure = profile.structure
        guard !structure.sections.isEmpty else { return "No content recorded" }
        var parts = ["\(structure.sections.count) section\(structure.sections.count == 1 ? "" : "s")",
                     "\(structure.requiredTitles.count) required"]
        let withSample = structure.sections.filter { $0.sample?.isEmpty == false }.count
        if withSample > 0 { parts.append("\(withSample) with content") }
        let questions = structure.sections.reduce(0) { $0 + ($1.questions?.count ?? 0) }
        if questions > 0 { parts.append("\(questions) question\(questions == 1 ? "" : "s")") }
        let formats = structure.sections.filter { $0.format != nil }.count
            + (structure.coreFormats?.count ?? 0)
        if formats > 0 { parts.append("\(formats) export format\(formats == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }


}
