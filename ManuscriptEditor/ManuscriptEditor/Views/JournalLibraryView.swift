// JournalLibraryView.swift
//
// Settings → Journals: the **template library**.  Search the templates you
// hold, see what each one requires, and open one for editing.
//
// Read-only on purpose.  A template is edited in its own tab — **Manage
// Template** opens it there — because editing it from a settings pane meant a
// second, smaller editor that could only ever do half of what the real one
// does.  What stays here is the library itself: finding a template, importing
// one someone sent, cloning, deleting.
//
// See MasterContext/features/journal-templates.md §3.

import SwiftUI
import AppKit

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
                || ($0.publisher ?? registry(for: $0)?.publisher ?? "").lowercased().contains(q)
                || ($0.country ?? registry(for: $0)?.country ?? "").lowercased().contains(q)
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
                                Text([profile.articleType,
                                      profile.publisher ?? registry(for: profile)?.publisher,
                                      profile.country ?? registry(for: profile)?.country]
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
                            manage(made.id)
                        }
                    } label: {
                        Label("Add Template", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .padding(10)
                    .help("An empty template, opened for editing")
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
            LibraryProfileDetail(profile: profile, registry: registry(for: profile),
                                 onManage: { manage(profile.id) },
                                 onDelete: { delete(profile) })
        } else {
            ContentUnavailableView(
                "No Template Selected",
                systemImage: "building.columns",
                description: Text("Pick a template to see what it requires. Manage Template opens it for editing, in its own tab.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Opens a template in the main window's tab bar.  Settings is its own
    /// scene and cannot add a tab, so it asks.
    private func manage(_ id: UUID) {
        NotificationCenter.default.post(name: .manageTemplate, object: nil,
                                        userInfo: ["template": id])
        // Bring the window that has the tab bar forward; the settings window
        // stays open behind it.
        NSApp.windows.first { $0.isVisible && $0.contentViewController != nil
            && $0.title != "Settings" }?.makeKeyAndOrderFront(nil)
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

/// A template as Settings shows it: what it is, what it requires, and the way
/// into it.
///
/// Read-only, and nothing is SET here — not even the country.  **Manage
/// Template** opens it in its own tab, which is where a template is edited:
/// one editor, not a small one here and a real one there.
private struct LibraryProfileDetail: View {
    let profile: JournalTemplate
    let registry: Journal?
    let onManage: () -> Void
    let onDelete: () -> Void

    @State private var cloning = false
    @State private var cloneName = ""
    @State private var confirmingDelete = false

    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                // The same four components, in the same order, opening the
                // same read-only view the journal panes open — a template
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

                HStack(spacing: 10) {
                    Button(action: onManage) {
                        Label("Manage Template", systemImage: TemplateStyle.symbol)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Open it in its own tab — its name, its sections, its rules")
                    Button {
                        cloneName = "\(profile.name) copy"
                        cloning = true
                    } label: {
                        Label("Clone", systemImage: "doc.on.doc")
                    }
                    .help("A copy under a new identity, carrying these rules")
                    Spacer()
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete", systemImage: "trash").foregroundStyle(.red)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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

    /// Name, type, description and version — what the template says it is.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: TemplateStyle.symbol)
                    .foregroundStyle(TemplateStyle.accent(scheme))
                Text(profile.name).font(.title3.weight(.semibold))
                if let type = profile.articleType, !type.isEmpty {
                    Text(type)
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("v\(profile.version)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help(profile.updatedAt.map {
                        "Last saved \($0.formatted(date: .abbreviated, time: .shortened))"
                    } ?? "Never saved")
            }
            if !profile.summaryDescription.isEmpty {
                Text(profile.summaryDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let where_ = [profile.publisher ?? registry?.publisher,
                          profile.country ?? registry?.country]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
            if !where_.isEmpty {
                Text(where_.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
            }
        }
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
