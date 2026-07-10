// ManuscriptSettingsView.swift
//
// Manuscript-scoped settings, split by concern into two sidebar items under
// the Manuscript section:
//
//   ManuscriptBackendView — where THIS manuscript lives: its local folder,
//                           its active backend account, its remote repository
//                           (create one right here for local-first projects).
//   ManuscriptAIView      — which AI service THIS manuscript uses (Phase II).
//
// App-wide settings (accounts, journal library, user identity, editor) live
// in Preferences (⌘,) — the two layers deliberately don't overlap.

import SwiftUI
import AppKit

// MARK: - ManuscriptBackendView

struct ManuscriptBackendView: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    @State private var newRepoName = ""
    @State private var createdRepoURL: URL?
    @State private var isCreating = false

    private var manuscript: Manuscript? { store.manuscript }

    /// Git-hosting accounts (LLM accounts can't store a manuscript).
    private var backendAccounts: [BackendAccount] {
        appStore.backends.filter { $0.provider == .github || $0.provider == .gitlab }
    }

    private var settingsBinding: Binding<ManuscriptSettings> {
        Binding(
            get: { store.manuscript?.settings ?? .empty() },
            set: { store.updateManuscriptSettings($0) }
        )
    }

    var body: some View {
        Form {
            Section("Local Copy") {
                LabeledContent("Folder") {
                    let dir = manuscript.map { store.persistence.manuscriptDirectory(for: $0.id) }
                    HStack(spacing: 8) {
                        Text(dir?.path(percentEncoded: false) ?? "—")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let dir {
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([dir])
                            }
                            .controlSize(.small)
                        }
                    }
                }
                LabeledContent("Last saved") {
                    Text(manuscript?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Backend Account") {
                Picker("Account", selection: settingsBinding.activeBackendID) {
                    Text("None (local only)").tag(Optional<UUID>.none)
                    ForEach(backendAccounts) { account in
                        Label("\(account.displayName) (\(account.provider.rawValue))",
                              systemImage: account.provider.systemImage)
                            .tag(Optional(account.id))
                    }
                }
                if backendAccounts.isEmpty {
                    Text("Add accounts in Preferences → Accounts (⌘,).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Remote Repository") {
                if let repo = manuscript?.settings.remoteRepository {
                    LabeledContent("Repository") {
                        HStack(spacing: 8) {
                            Text(repo).foregroundStyle(.secondary)
                            if let url = URL(string: "https://github.com/\(repo)") {
                                Link("Open on GitHub", destination: url)
                                    .font(.caption)
                            }
                        }
                    }
                    TextField("Branch", text: Binding(
                        get: { manuscript?.settings.remoteBranch ?? "" },
                        set: { newValue in
                            var s = settingsBinding.wrappedValue
                            s.remoteBranch = newValue.isEmpty ? nil : newValue
                            settingsBinding.wrappedValue = s
                        }
                    ), prompt: Text("main"))
                    LabeledContent("Last synced") {
                        Text(manuscript?.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened)
                             ?? "never")
                            .foregroundStyle(.secondary)
                    }
                    Text("Save/Load live in Sync, or File → Save (Remote) ⇧⌘S.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Local-first manuscript: create its repository from here.
                    TextField("Repository name", text: $newRepoName, prompt: Text("my-manuscript"))
                        .autocorrectionDisabled()
                    HStack(spacing: 10) {
                        Button {
                            isCreating = true
                            store.createRemoteRepository(named: newRepoName, appStore: appStore) { url in
                                isCreating = false
                                createdRepoURL = url
                            }
                        } label: {
                            if isCreating {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Create Repository & Push", systemImage: "plus.square.on.square")
                            }
                        }
                        .disabled(newRepoName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || manuscript?.settings.activeBackendID == nil
                                  || isCreating)
                        if manuscript?.settings.activeBackendID == nil {
                            Text("Pick a backend account above first.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Creates a private repository on the account, binds it to this manuscript, and pushes the current content.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let url = createdRepoURL {
                    Link(destination: url) {
                        Label("Repository created — open \(url.absoluteString)", systemImage: "checkmark.circle")
                    }
                    .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - ManuscriptAIView

struct ManuscriptAIView: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    private var settingsBinding: Binding<ManuscriptSettings> {
        Binding(
            get: { store.manuscript?.settings ?? .empty() },
            set: { store.updateManuscriptSettings($0) }
        )
    }

    var body: some View {
        Form {
            Section("AI Service") {
                Picker("Service", selection: settingsBinding.activeAIServiceID) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(appStore.aiServices) { service in
                        Label("\(service.displayName) (\(service.provider.rawValue))",
                              systemImage: service.provider.systemImage)
                            .tag(Optional(service.id))
                    }
                }
                if appStore.aiServices.isEmpty {
                    Text("Add AI accounts in Preferences → Accounts (⌘,).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("AI adaptation of journal cuts is a Phase II feature: the configured service will derive cut content toward each journal's requirements. Cuts are created and edited manually until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
