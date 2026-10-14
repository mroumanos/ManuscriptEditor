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
// And the shared repository (`TemplatePublishing`), on the Remote row:
//
//   Save (Remote)       proposes this template — its files on a branch and a
//                       pull request, never a merge — under the GitHub
//                       account you pick.
//   Load (Remote)       takes the published copy into the draft.
//
// See MasterContext/features/journal-templates.md §3.2, §3.6 and §3.7.

import SwiftUI
import AppKit

struct TemplateOverviewView: View {
    @Environment(TemplateWorkspace.self) private var templates
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var scheme

    let templateID: UUID

    @State private var savingAsNew = false
    @State private var newName = ""
    @State private var confirmingSave = false
    @State private var confirmingDelete = false
    @State private var confirmingRevert = false
    @State private var confirmingPropose = false
    @State private var confirmingLoadRemote = false
    @State private var accountID: UUID?
    @State private var remoteBusy = false
    @State private var proposedURL: URL?

    private var template: JournalTemplate? { templates.template(templateID) }
    private var isDirty: Bool { templates.isDirty(templateID) }
    private var editedParts: Set<ProfilePart> { templates.editedParts(templateID) }
    /// Another template already called this — what blocks Save.
    private var nameHolder: JournalTemplate? { templates.nameHolder(templateID) }
    private var publishing: TemplatePublishing { .shared }
    private var published: TemplatePublishing.Status {
        template.map { publishing.status(for: $0) } ?? .unknown
    }
    /// The GitHub accounts a proposal can go out under.
    private var accounts: [BackendAccount] { appStore.backends.filter { $0.provider == .github } }
    private var account: BackendAccount? { accounts.first { $0.id == accountID } }

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
                        travelling
                    }
                    .padding(20)
                    .frame(maxWidth: TemplateLayout.contentWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // The manuscript's account when it is a GitHub one, else the first.
            let manuscripts = store.manuscript?.settings.activeBackendID
            accountID = accounts.first { $0.id == manuscripts }?.id ?? accounts.first?.id
        }
        .task(id: template?.checksum) {
            if let template { publishing.refresh(template) }
        }
        .confirmationDialog("Propose “\(template?.displayName ?? "")” to the shared repository?",
                            isPresented: $confirmingPropose, titleVisibility: .visible) {
            Button("Open Pull Request") { propose() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Writes this template's files to a branch under \(account?.displayName ?? "the account") — in the repository if that account may push to it, in a fork of it otherwise — and opens a pull request for review. Nothing is merged by this.")
        }
        .confirmationDialog("Replace this draft with the published “\(template?.displayName ?? "")”?",
                            isPresented: $confirmingLoadRemote, titleVisibility: .visible) {
            Button("Load", role: .destructive) { loadRemote() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Takes the shared repository's copy of every part into this draft. Save it afterwards to keep it in your library.")
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
        //
        // A plain stack rather than a Form: a grouped Form right-aligns its
        // values, which reads as a settings sheet and sets a three-line
        // description ragged against the wrong edge.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                field("Name", "The journal's name", Binding(
                    get: { template.name },
                    set: { value in templates.edit(templateID) { $0.name = value } }))
                if let holder = nameHolder {
                    // Names are unique per type: the shared repository files
                    // templates by name and type, and two under one label
                    // would be two sets of rules nobody could tell apart.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.bottom, 6)
                        .help("“\(holder.displayName)” already has this name and type — Save is disabled until one of them is renamed.")
                }
            }
            field("Type", "Research Article, Research Brief…", Binding(
                get: { template.articleType ?? "" },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    templates.edit(templateID) { $0.articleType = trimmed.isEmpty ? nil : trimmed }
                }))
            HStack(spacing: 10) {
                field("Publisher", "Who publishes it", Binding(
                    get: { template.publisher ?? "" },
                    set: { value in
                        let trimmed = value.trimmingCharacters(in: .whitespaces)
                        templates.edit(templateID) { $0.publisher = trimmed.isEmpty ? nil : trimmed }
                    }))
                field("Country", "Where", Binding(
                    get: { template.country ?? "" },
                    set: { value in
                        let trimmed = value.trimmingCharacters(in: .whitespaces)
                        templates.edit(templateID) { $0.country = trimmed.isEmpty ? nil : trimmed }
                    }))
            }
            field("Description", "What this format is for", Binding(
                get: { template.summaryDescription },
                set: { value in templates.edit(templateID) { $0.summaryDescription = value } }),
                  lines: 2...6)
            Text("The description is the summary's `description:` bullets — one place to say what this format is, rather than two that disagree.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)

        // One fact per line: four labels across a row read as a toolbar and
        // wrapped badly the moment one of them was a name.
        VStack(alignment: .leading, spacing: 4) {
            fact("Version", "v\(template.version)")
            fact("Last saved", template.updatedAt?
                .formatted(date: .abbreviated, time: .shortened) ?? "never")
            fact("Identity", String(template.id.uuidString.prefix(8)).lowercased())
            if !template.lineage.isEmpty {
                fact("Branched from",
                     JournalProfileLibrary.shared.profile(id: template.lineage[0])?.displayName
                        ?? String(template.lineage[0].uuidString.prefix(8)).lowercased())
            }
        }
        .padding(.horizontal, 4)
    }

    /// One labelled field, label above, field below, left-aligned.
    private func field(_ label: String, _ prompt: String,
                       _ text: Binding<String>,
                       lines: ClosedRange<Int> = 1...1) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            if lines.upperBound > 1 {
                TextField(prompt, text: text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(lines)
            } else {
                TextField(prompt, text: text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)
            Text(value).font(.callout.monospacedDigit())
            Spacer()
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

    /// Local and Remote, each with Save | Load — the shape a manuscript's
    /// Overview has, because the question is the same: where does this copy
    /// go, and where does it come from.
    @ViewBuilder
    private func actions(_ template: JournalTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                rowLabel("Local")
                Button("Save") { confirmingSave = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || nameHolder != nil)
                    .help(nameHolder != nil ? "Another template holds this name and type"
                          : isDirty ? "Overwrite this template in your library: same identity, next version"
                                    : "Nothing to save — this matches your library")
                Button("Load") { confirmingRevert = true }
                    .disabled(!isDirty)
                    .help("Take your library's copy back, discarding the edits held here")
                Text("(last saved \(template.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never"))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Save as New…") {
                    newName = JournalProfileLibrary.shared.copyName(for: template)
                    savingAsNew = true
                }
                .help("A separate template with its own identity, starting at version 1")
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete", systemImage: "trash").foregroundStyle(.red)
                }
            }
            .controlSize(.small)

            HStack(spacing: 6) {
                rowLabel("Remote")
                Button("Save") { confirmingPropose = true }
                    .disabled(account == nil || isDirty || remoteBusy)
                    .help(account == nil ? "Add a GitHub account in Settings → Accounts to propose templates"
                          : isDirty ? "Save locally first — a proposal sends what your library holds"
                                    : "Propose this template to the shared repository as a pull request")
                Button("Load") { confirmingLoadRemote = true }
                    .disabled(remoteBusy || !{ if case .differs = published { return true }; return published == .matches }())
                    .help("Take the published copy into this draft")
                if remoteBusy { ProgressView().controlSize(.small) }
                Text(remoteCaption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let warning = published.warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(warning)
                }
                if let url = TemplatePublishing.url(forSlug: template.slug) {
                    Link(destination: url) { Image(systemName: "globe").font(.caption) }
                        .help(url.absoluteString)
                }
                Spacer()
                Picker("", selection: $accountID) {
                    if accounts.isEmpty { Text("No GitHub account").tag(UUID?.none) }
                    ForEach(accounts) { Text($0.displayName).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(width: 170)
                .help("The GitHub account a proposal goes out under — any of the accounts in Settings")
            }
            .controlSize(.small)
            if let proposedURL {
                Link(destination: proposedURL) {
                    Label("Pull request opened — \(proposedURL.absoluteString)", systemImage: "arrow.triangle.pull")
                        .font(.caption)
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

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 56, alignment: .leading)
    }

    private var remoteCaption: String {
        switch published {
        case .unknown:          return "(not checked)"
        case .checking:         return "(checking…)"
        case .absent:           return "(not published)"
        case .matches:          return "(published copy matches)"
        case .differs(let p):   return "(published copy differs: \(ProfilePart.displayOrder.filter(p.contains).map(\.label).joined(separator: ", ")))"
        case .differentIdentity: return "(another template is published under this name)"
        }
    }

    // MARK: - The shared repository

    private func propose() {
        guard let template, let account else { return }
        guard let token = KeychainService.secret(for: account.id), !token.isEmpty else {
            store.showBanner(.error, "No personal access token stored for “\(account.displayName)”. Add one in Settings → Accounts.")
            return
        }
        remoteBusy = true
        Task {
            do {
                let login = account.username.isEmpty
                    ? try await GitHubBackendService().authenticatedLogin(token: token)
                    : account.username
                let url = try await publishing.propose(template, token: token, login: login)
                proposedURL = url
                publishing.invalidate(template.id)
                store.showBanner(.success, "Pull request opened for “\(template.displayName)”.")
                NSWorkspace.shared.open(url)
            } catch {
                store.showBanner(.error, "Couldn't propose the template: \(error.localizedDescription)")
            }
            remoteBusy = false
        }
    }

    private func loadRemote() {
        guard let template else { return }
        remoteBusy = true
        Task {
            do {
                guard let copy = try await publishing.published(slug: template.slug, token: nil) else {
                    store.showBanner(.error, "“\(template.displayName)” is not published.")
                    remoteBusy = false
                    return
                }
                guard copy.id == template.id else {
                    store.showBanner(.error, "A different template is published under this name and type — rename this one first.")
                    remoteBusy = false
                    return
                }
                templates.edit(templateID) { draft in
                    draft.requirements = copy.requirements
                    draft.checks = copy.checks
                    draft.structure = copy.structure
                    draft.export = copy.export
                    draft.publisher = copy.publisher ?? draft.publisher
                    draft.country = copy.country ?? draft.country
                }
                publishing.invalidate(template.id)
                store.showBanner(.success, "Loaded the published “\(template.displayName)” — Save to keep it.")
            } catch {
                store.showBanner(.error, "Couldn't load the published template: \(error.localizedDescription)")
            }
            remoteBusy = false
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

    // MARK: - Where it goes

    /// Every template ships with the manuscript — stated here because it is
    /// the question people ask when they edit one: does anyone else get this?
    ///
    /// This is the whole of sharing. An export file and a contribution path
    /// were built and then taken back out: a feature nobody can explain is
    /// worse than one that isn't there.
    private var travelling: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "shippingbox").font(.caption2).foregroundStyle(.tertiary)
            Text("This template travels with every manuscript that uses it. Each journal writes its rules into the manuscript on every save — modified or not — so anyone you publish or share the manuscript with opens it with the rules you used.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var deleteMessage: String {
        var text = "Manuscripts already using it keep their own copy — they'll show as edited, with nothing to compare against."
        if !usedBy.isEmpty {
            text = "\(usedBy.map(\.name).joined(separator: ", ")) in this manuscript " +
                   "\(usedBy.count == 1 ? "uses" : "use") it. " + text
        }
        return text
    }
}
