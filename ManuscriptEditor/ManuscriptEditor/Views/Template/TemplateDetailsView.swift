// TemplateDetailsView.swift
//
// A template's Details: where a save goes, what the template is (About), and
// what the venue asks (Requirements).  The same page a journal cut has, with
// one difference: here the fields write straight into the draft — nothing
// reaches the library until Save — so there are no pencils, only the Save
// and Load rows.
//
//   Save (Local)        keeps the identity, takes the next version, and
//                       rewrites every part's checksum.  Re-saving an
//                       untouched template takes no version.
//                       With the NAME OR TYPE changed, Save makes a NEW
//                       template instead — its own identity at version 1,
//                       branched from this one — and never asks about
//                       overwriting, because nothing is overwritten.
//   Load (Local)        takes your library's copy back into the draft.
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
// A draft that a manuscript's Save brought here (`TemplateWorkspace.
// seededJournal`) goes back to that journal on save: it takes the saved copy,
// and if the save made a new template, its link moves to the new identity —
// the one thing a rename does that you cannot see, so the dialog says it.
//
// See MasterContext/features/journal-templates.md §3.2, §3.6 and §3.7.

import SwiftUI
import AppKit

struct TemplateDetailsView: View {
    @Environment(TemplateWorkspace.self) private var templates
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self) private var appStore

    let templateID: UUID

    @State private var confirmingSave = false
    @State private var confirmingSaveAsNew = false
    @State private var confirmingDelete = false
    @State private var confirmingRevert = false
    @State private var confirmingPropose = false
    @State private var confirmingLoadRemote = false
    @State private var accountID: UUID?
    @State private var remoteBusy = false
    @State private var proposedURL: URL?

    private var template: JournalTemplate? { templates.template(templateID) }
    /// The library's copy — what a save overwrites, or branches from.
    private var stored: JournalTemplate? { JournalProfileLibrary.shared.profile(id: templateID) }
    private var isDirty: Bool { templates.isDirty(templateID) }
    private var savesAsNew: Bool { templates.savesAsNew(templateID) }
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
    /// The manuscript journal whose Save brought this draft here, if one did.
    private var seededJournal: Journal? {
        templates.seededJournal[templateID].flatMap { id in
            store.manuscript?.journals.first { $0.id == id }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TemplatePaneHeader(templateID: templateID, title: "Details",
                               subtitle: "What this template is, what the venue asks, and where a save goes.")
            ScrollView {
                if let template {
                    VStack(alignment: .leading, spacing: 14) {
                        actions(template)
                        about(template)
                        requirements(template)
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
            Text("Opens a pull request under \(account?.displayName ?? "the account"). Nothing is merged.")
        }
        .confirmationDialog("Replace this draft with the published “\(template?.displayName ?? "")”?",
                            isPresented: $confirmingLoadRemote, titleVisibility: .visible) {
            Button("Load", role: .destructive) { loadRemote() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Replaces this draft with the published copy. Save to keep it.")
        }
        .confirmationDialog(saveTitle, isPresented: $confirmingSave, titleVisibility: .visible) {
            Button("Save") { saveOverwriting() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(saveMessage)
        }
        .confirmationDialog("Save as the new template “\(template?.displayName ?? "")”?",
                            isPresented: $confirmingSaveAsNew, titleVisibility: .visible) {
            Button("Save as New") { saveAsNew() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(saveAsNewMessage)
        }
        .confirmationDialog("Discard your changes to “\(template?.displayName ?? "")”?",
                            isPresented: $confirmingRevert, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { templates.revert(templateID) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Restores your library's copy. ⌘Z can't undo this.")
        }
        .confirmationDialog("Delete “\(template?.displayName ?? "")” from your library?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { templates.delete(templateID) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Manuscripts using it keep their own copy.")
        }
    }

    // MARK: - Save and Load

    /// Local and Remote, each with Save | Load — the shape a manuscript's
    /// Overview has, because the question is the same: where does this copy
    /// go, and where does it come from.
    @ViewBuilder
    private func actions(_ template: JournalTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                rowLabel("Local")
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || nameHolder != nil)
                    .help(nameHolder != nil ? "Another template holds this name and type"
                          : savesAsNew ? "The name or type changed: saves a new template, branched from “\(stored?.displayName ?? "")”"
                          : isDirty ? "Save this template to your library: same identity, next version"
                                    : "Nothing to save — this matches your library")
                Button("Load") { confirmingRevert = true }
                    .disabled(!isDirty)
                    .help("Take your library's copy back, discarding the edits held here")
                Spacer()
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete", systemImage: "trash").foregroundStyle(.red)
                }
                .help("Remove this template from your library")
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
            if let journal = seededJournal {
                Text("Brought here by \(journal.name)'s Save. Saving gives \(journal.name) this copy\(savesAsNew ? ", and moves its link to the new template" : "").")
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

    // MARK: - About

    /// Typed straight into the draft: nothing here reaches the library until
    /// Save, so there is no reason to make you press Enter twice.
    @ViewBuilder
    private func about(_ template: JournalTemplate) -> some View {
        JournalBox(title: "About") {
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
                if savesAsNew, nameHolder == nil, let stored {
                    Label("The name or type changed: Save makes a new template, branched from “\(stored.displayName)”, which stays as it is.",
                          systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // One fact per line: four labels across a row read as a
                // toolbar and wrapped badly the moment one was a name.
                VStack(alignment: .leading, spacing: 4) {
                    fact("Version", "v\(template.version)")
                    fact("Last saved", template.updatedAt?
                        .formatted(date: .abbreviated, time: .shortened) ?? "never")
                    if !template.lineage.isEmpty {
                        fact("Branched from",
                             JournalProfileLibrary.shared.profile(id: template.lineage[0])?.displayName
                                ?? String(template.lineage[0].uuidString.prefix(8)).lowercased())
                    }
                }
                .padding(.top, 4)
            }
        }
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

    // MARK: - Requirements

    /// The journal's own instructions, distilled: a link to the authority
    /// and one requirement per line.  The Tests are what the app can
    /// enforce of them.
    @ViewBuilder
    private func requirements(_ template: JournalTemplate) -> some View {
        JournalBox(title: "Requirements") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Link to the journal's author instructions", text: Binding(
                        get: { template.requirements.url },
                        set: { value in templates.edit(templateID) { $0.requirements.url = value } }))
                        .textFieldStyle(.roundedBorder)
                    if !template.requirements.url.isEmpty,
                       let url = URL(string: template.requirements.url) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .help("Open the journal's author instructions — always the authority")
                    }
                }
                .controlSize(.small)
                // The model keeps bullets; the editor keeps the text.  Only
                // this direction is written on each keystroke, so normalising
                // a line can never yank the cursor out from under someone.
                PlainTextEditor(text: Binding(
                    get: { template.requirements.text },
                    set: { value in templates.edit(templateID) { $0.requirements.text = value } }))
                    .frame(minHeight: 260)
                Text("One requirement per line. A `category:` prefix (description, limits, components, format, extra) groups it; the description lines are the About description.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Saving

    private func save() {
        guard isDirty, nameHolder == nil else { return }
        if savesAsNew {
            // Nothing is overwritten, so nothing to warn about — unless a
            // journal's link moves, which you cannot see happen.
            if seededJournal != nil { confirmingSaveAsNew = true } else { saveAsNew() }
        } else {
            confirmingSave = true
        }
    }

    private func saveOverwriting() {
        guard let template else { return }
        guard templates.save(templateID) else {
            store.showBanner(.error, "Couldn't write “\(template.displayName)” to your library.")
            return
        }
        if let journal = seededJournal {
            _ = store.adoptLibraryProfile(journalID: journal.id)
        }
        store.showBanner(.success, "Saved “\(template.displayName)” to your library.")
    }

    private func saveAsNew() {
        guard let template else { return }
        let from = stored?.displayName ?? "the original"
        let journal = seededJournal
        guard let made = templates.saveAsNew(templateID) else {
            store.showBanner(.error, "Couldn't save “\(template.displayName)” as a new template.")
            return
        }
        if let journal {
            // The journal came here with its copy; it follows the template
            // its copy became.
            _ = store.linkToTemplate(made, journalID: journal.id)
        }
        // This tab is the new template's now.
        NotificationCenter.default.post(name: .manageTemplate, object: nil, userInfo: ["template": made])
        store.showBanner(.success, journal.map {
            "Saved “\(template.displayName)” as a new template, branched from “\(from)”; \($0.name) now follows it."
        } ?? "Saved “\(template.displayName)” as a new template, branched from “\(from)”.")
    }

    private var saveTitle: String {
        "Save “\(template?.displayName ?? "")” to your library?"
    }

    private var saveMessage: String {
        let parts = ProfilePart.displayOrder.filter(editedParts.contains).map(\.label)
        let changed = parts.isEmpty ? "Nothing has changed" : "Changes: \(parts.joined(separator: ", "))"
        var text = "\(changed). Becomes v\((stored?.version ?? 1) + (isDirty ? 1 : 0))."
        if let journal = seededJournal {
            text += " \(journal.name) takes this copy."
        }
        return text
    }

    private var saveAsNewMessage: String {
        let name = template?.displayName ?? ""
        let from = stored?.displayName ?? "the original"
        var text = "The name or type changed: this becomes a new template, v1, branched from “\(from)”. “\(from)” is unchanged."
        if let journal = seededJournal {
            text += " \(journal.name) follows “\(name)” from now on."
        }
        return text
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
                    draft.publishedChecksum = copy.checksum
                }
                publishing.invalidate(template.id)
                store.showBanner(.success, "Loaded the published “\(template.displayName)” — Save to keep it.")
            } catch {
                store.showBanner(.error, "Couldn't load the published template: \(error.localizedDescription)")
            }
            remoteBusy = false
        }
    }
}
