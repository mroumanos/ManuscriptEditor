// BackendView.swift
//
// Global panel for managing external storage/sync backend accounts.
//
// WHAT THIS PANEL DOES
// ─────────────────────────────────────────────────────────────────────────────
// Users can add any number of backend accounts (GitHub, Google Docs, etc.).
// These accounts are global — shared across all manuscripts.
//
// Each manuscript then picks its "active" backend in Manuscript → Settings.
// This panel is only for adding, naming, and removing accounts, not for
// selecting which manuscript uses which one.
//
// CONNECTION STATUS (Phase 2)
// ─────────────────────────────────────────────────────────────────────────────
// OAuth / token authentication is Phase 2.  For now, accounts are stored as
// stubs with `isConnected = false`.  The "Connect" button is present but
// disabled, so the user can see the full intended flow.

import SwiftUI

// MARK: - BackendView

/// List of backend accounts on the left; detail form on the right.
struct BackendView: View {
    @Environment(AppStore.self) private var appStore

    @State private var selectedID: UUID?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            accountList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            detail
        }
        .sheet(isPresented: $showAddSheet) {
            AddBackendSheet(isPresented: $showAddSheet) { account in
                appStore.addBackend(account)
                selectedID = account.id
            }
        }
    }

    // MARK: - Left: account list

    private var accountList: some View {
        VStack(spacing: 0) {
            if appStore.backends.isEmpty {
                emptyState
            } else {
                List(selection: $selectedID) {
                    ForEach(appStore.backends) { account in
                        accountRow(account).tag(account.id)
                    }
                    .onDelete { appStore.deleteBackends(at: $0) }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Backend", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(10)
                Spacer()
                Text("\(appStore.backends.count) account\(appStore.backends.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No backends configured")
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            Text("Add a backend to sync manuscripts\nto GitHub, Google Docs, or other services.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.quaternary)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func accountRow(_ account: BackendAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.provider.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).fontWeight(.medium).lineLimit(1)
                Text(account.provider.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Status dot
            Circle()
                .fill(account.isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Right: detail form

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID,
           let account = appStore.backends.first(where: { $0.id == id }) {
            BackendDetailForm(account: account)
        } else {
            ContentUnavailableView(
                "No Backend Selected",
                systemImage: "externaldrive.connected.to.line.below",
                description: Text("Add a backend or select one to configure it.")
            )
        }
    }
}

// MARK: - BackendDetailForm

/// Edit form for one backend account.
struct BackendDetailForm: View {
    @Environment(AppStore.self) private var appStore
    let account: BackendAccount
    @State private var draft: BackendAccount

    /// Token draft — read from / written to the **Keychain**, never persisted
    /// with the account (app.json is a plain file).
    @State private var token = ""

    init(account: BackendAccount) {
        self.account = account
        _draft = State(initialValue: account)
        _token = State(initialValue: KeychainService.secret(for: account.id) ?? "")
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Identity") {
                    TextField("Display name", text: $draft.displayName)
                    LabeledContent("Provider") {
                        Text(draft.provider.rawValue).foregroundStyle(.secondary)
                    }
                    TextField("Username / email", text: $draft.username)
                }

                if draft.provider == .github {
                    githubSection
                }

                Section("Connection") {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(draft.isConnected ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(draft.syncStatus.rawValue)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = draft.lastErrorMessage, draft.syncStatus == .error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if draft.provider == .github {
                        Text("Select this backend in Manuscript → Settings, then use Manuscript → Save to Remote (⇧⌘S) / Load from Remote.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Connect Account (coming later)") {}
                            .buttonStyle(.borderedProminent)
                            .disabled(true)
                    }
                }

                Section {
                    Text(draft.provider.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: draft.displayName) { _, _ in appStore.updateBackend(draft) }
        .onChange(of: draft.username)    { _, _ in appStore.updateBackend(draft) }
        .onChange(of: draft.repository)  { _, _ in appStore.updateBackend(draft) }
        .onChange(of: draft.branch)      { _, _ in appStore.updateBackend(draft) }
        .onChange(of: token)             { _, new in KeychainService.setSecret(new, for: account.id) }
        .onChange(of: account.id) { _, _ in
            draft = account
            token = KeychainService.secret(for: account.id) ?? ""
        }
    }

    /// GitHub push/pull configuration: which repository/branch, and the
    /// personal access token (stored in the Keychain as the user types).
    @ViewBuilder
    private var githubSection: some View {
        Section("GitHub Repository") {
            TextField("Repository (owner/name)", text: Binding(
                get: { draft.repository ?? "" },
                set: { draft.repository = $0.isEmpty ? nil : $0 }
            ))
            .autocorrectionDisabled()
            TextField("Branch", text: Binding(
                get: { draft.branch ?? "" },
                set: { draft.branch = $0.isEmpty ? nil : $0 }
            ), prompt: Text("main"))
            .autocorrectionDisabled()
            SecureField("Personal access token", text: $token)
            Text("Create a fine-grained token with Contents read & write access to that repository (github.com → Settings → Developer settings). The token is stored in your Keychain only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AddBackendSheet

/// Sheet for adding a new backend account.
struct AddBackendSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (BackendAccount) -> Void

    @State private var provider: BackendProvider = .github
    @State private var displayName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Backend").font(.headline)

            Picker("Provider", selection: $provider) {
                ForEach(BackendProvider.allCases, id: \.self) { p in
                    Label(p.rawValue, systemImage: p.systemImage).tag(p)
                }
            }
            .labelsHidden()
            .onChange(of: provider) { _, new in
                if displayName.isEmpty { displayName = new.rawValue }
            }

            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)

            Text(provider.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    var account = BackendAccount.empty(provider: provider)
                    account.displayName = displayName.isEmpty ? provider.rawValue : displayName
                    onAdd(account)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { displayName = provider.rawValue }
    }
}
