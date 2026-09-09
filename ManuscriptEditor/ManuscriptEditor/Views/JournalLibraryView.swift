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

    @State private var showingDetails = false
    @State private var cloning = false
    @State private var cloneName = ""
    @State private var confirmingDelete = false

    @Environment(AppStore.self) private var appStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Metadata is editable here; the RULES are not.  A template's
                // tests are written against a manuscript's real content, so
                // there is nothing here to write them against.
                Form {
                    Section("Template") {
                        TextField("Name", text: $nameDraft, onEditingChanged: { editing in
                            if !editing { commitMetadata() }
                        })
                        .onSubmit(commitMetadata)
                        TextField("Type (Research Article, Research Brief…)", text: $typeDraft,
                                  onEditingChanged: { editing in if !editing { commitMetadata() } })
                            .onSubmit(commitMetadata)
                        TextField("Country", text: $countryDraft,
                                  onEditingChanged: { editing in if !editing { commitCountry() } })
                            .onSubmit(commitCountry)
                    }
                }
                .formStyle(.grouped)
                .frame(height: 150)

                VStack(spacing: 0) {
                    row("doc.text", "Summary", summaryDetail)
                    Divider()
                    row("list.bullet.indent", "Structure",
                        profile.structure.sections.isEmpty
                            ? "No structure recorded"
                            : "\(profile.structure.sections.count) sections · \(profile.structure.requiredTitles.count) required")
                    Divider()
                    row("checklist", "Tests",
                        profile.checks.isEmpty
                            ? "No tests recorded"
                            : "\(profile.checks.filter { !$0.isManual }.count) automatic · \(profile.checks.filter(\.isManual).count) manual")
                    Divider()
                    row("square.and.arrow.up", "Export", exportDetail)
                }
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

                Text("A template's summary, structure, tests and export outline are edited from a manuscript that uses it — add this template to a manuscript, change it there, and save it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        showingDetails = true
                    } label: {
                        Label("Details", systemImage: "doc.text.magnifyingglass")
                    }
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
        .sheet(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName).font(.headline)
                    Text("Read-only — add this template to a manuscript to edit its rules.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                JournalProfileReview(profile: profile)
                    .frame(height: 380)
                HStack {
                    Spacer()
                    Button("Done") { showingDetails = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 560)
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
        .confirmationDialog("Delete “\(profile.displayName)” from your library?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Manuscripts already using it keep their own copy — they'll show as edited, with nothing to compare against.")
        }
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

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
    }


}
