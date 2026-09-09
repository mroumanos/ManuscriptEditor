// JournalLibraryView.swift
//
// Settings → Journals: the global journal library.  Search reusable
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
                TextField("Search journals…", text: $query)
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
                    // Profiles are created from a manuscript, where there is
                    // something to configure them against — an empty profile
                    // made here would have no cut to test.
                    Text("Profiles are created by saving a journal from a manuscript")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(10)
                    Spacer()
                    Text("\(profiles.count) in library")
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
                "No Journal Selected",
                systemImage: "building.columns",
                description: Text("Search the library and select a journal to see its profile.")
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
    let profile: JournalProfile
    let registry: Journal?
    let onDelete: () -> Void

    @State private var showingSummary = false
    @State private var showingStructure = false
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        if let type = profile.articleType, !type.isEmpty {
                            Text(type)
                                .font(.caption)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        Text([registry?.publisher, registry?.country]
                            .compactMap { $0?.isEmpty == false ? $0 : nil }
                            .joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    row("doc.text", "Summary", summaryDetail, open: { showingSummary = true })
                    Divider()
                    row("list.bullet.indent", "Structure",
                        profile.structure.sections.isEmpty
                            ? "No structure recorded"
                            : "\(profile.structure.sections.count) sections · \(profile.structure.requiredTitles.count) required",
                        open: { showingStructure = true })
                    Divider()
                    row("square.and.arrow.up", "Export", exportDetail, open: nil,
                        disabledNote: "Add this journal to a manuscript to edit its outline")
                }
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Tests").font(.headline)
                    Text("edited from a manuscript that has adopted this journal")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                if profile.checks.isEmpty {
                    Text("No tests recorded for this journal.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(profile.checks) { rule in
                            HStack(spacing: 8) {
                                Image(systemName: rule.isManual ? "hand.raised" : "checklist")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 14)
                                Text(rule.displayName)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                                if rule.isManual {
                                    Text("manual").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            if rule.id != profile.checks.last?.id { Divider().padding(.leading, 34) }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                }

                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete Profile", systemImage: "trash").foregroundStyle(.red)
                }
                .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("Delete “\(profile.displayName)” from your library?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Manuscripts already using it keep their own copy — they'll show as not in your library.")
        }
        .sheet(isPresented: $showingSummary) {
            profileSheet("Summary") { JournalProfileReview(profile: profile) }
        }
        .sheet(isPresented: $showingStructure) {
            profileSheet("Structure") { JournalProfileReview(profile: profile) }
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

    private func row(_ icon: String, _ title: String, _ detail: String,
                     open: (() -> Void)?, disabledNote: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open…") { open?() }
                .controlSize(.small)
                .disabled(open == nil)
                .help(disabledNote ?? "")
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
    }

    @ViewBuilder
    private func profileSheet(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(profile.displayName) — \(title)").font(.headline)
            content()
                .frame(height: 380)
            HStack {
                Spacer()
                Button("Done") {
                    showingSummary = false
                    showingStructure = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}
