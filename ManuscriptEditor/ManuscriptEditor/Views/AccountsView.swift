// AccountsView.swift
//
// Settings → Accounts: every external account in one panel — storage
// backends (GitHub, GitLab, Office 365, …) and AI services (Claude, OpenAI,
// Gemini, Ollama).  Each account stores its credential in the **Keychain**
// (keyed by account id) and offers **Test Connection** to verify it.
//
// Model note: backends and AI services remain separate arrays in AppStore
// (they're referenced by different ManuscriptSettings fields); this panel
// unifies the *management* UI, not the storage.

import SwiftUI

// MARK: - Unified row model

/// One row in the accounts list, wrapping either account flavor.
private enum AnyAccount: Identifiable {
    case backend(BackendAccount)
    case ai(AIServiceAccount)
    /// A local service with no credential at all — see `AIConnector`.
    case connector(AIConnector)

    var id: UUID {
        switch self {
        case .backend(let a):   return a.id
        case .ai(let a):        return a.id
        case .connector(let c): return c.id
        }
    }

    var displayName: String {
        switch self {
        case .backend(let a):   return a.displayName
        case .ai(let a):        return a.displayName
        case .connector(let c): return c.displayName
        }
    }

    var providerName: String {
        switch self {
        case .backend(let a):   return a.provider.rawValue
        case .ai(let a):        return a.provider.rawValue
        case .connector(let c): return c.subtitle
        }
    }

    var systemImage: String {
        switch self {
        case .backend(let a):   return a.provider.systemImage
        case .ai(let a):        return a.provider.systemImage
        case .connector(let c): return c.kind.systemImage
        }
    }

}

// MARK: - AccountsView

struct AccountsView: View {
    @Environment(AppStore.self) private var appStore

    @State private var selectedID: UUID?
    @State private var showAddSheet = false

    /// Connectors tested since this window opened.  Deliberately NOT read from
    /// the stored result: a tick that survives a relaunch reads as live status
    /// for a tool that might have been uninstalled since.  It means "I just
    /// watched this work", so it lives and dies with the window.
    @State private var testedThisSession: [UUID: Bool] = [:]

    private var accounts: [AnyAccount] {
        appStore.connectors.map(AnyAccount.connector)
            + appStore.backends.map(AnyAccount.backend)
            + appStore.aiServices.map(AnyAccount.ai)
    }

    var body: some View {
        HSplitView {
            accountList
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
            detail
        }
        .sheet(isPresented: $showAddSheet) {
            AddAccountSheet(isPresented: $showAddSheet) { id in
                selectedID = id
            }
        }
    }

    // MARK: Left: unified list

    private var accountList: some View {
        VStack(spacing: 0) {
            if accounts.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("No accounts configured")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                    Text("Add storage (GitHub, GitLab…) and AI\n(Claude, OpenAI…) accounts here.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.quaternary)
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(accounts) { account in
                        HStack(spacing: 10) {
                            Image(systemName: account.systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName).fontWeight(.medium).lineLimit(1)
                                Text(account.providerName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let ok = testedThisSession[account.id] {
                                Circle().fill(ok ? Color.green : Color.orange)
                                    .frame(width: 7, height: 7)
                                    .help(ok ? "Tested just now — working"
                                             : "Tested just now — failed")
                            }
                            // No delete button in the list: every account is
                            // removed from the bottom of its detail pane,
                            // out of reach of a mis-click in a list you scroll.
                        }
                        .padding(.vertical, 3)
                        .tag(account.id)
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(10)
                Spacer()
                Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
            }
        }
    }

    // MARK: Right: detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID,
           let backend = appStore.backends.first(where: { $0.id == id }) {
            BackendAccountForm(account: backend,
                               testedThisSession: $testedThisSession,
                               onRemove: { delete(.backend(backend)) })
        } else if let id = selectedID,
                  let ai = appStore.aiServices.first(where: { $0.id == id }) {
            AIAccountForm(account: ai,
                          testedThisSession: $testedThisSession,
                          onRemove: { delete(.ai(ai)) })
        } else if let id = selectedID,
                  let connector = appStore.connectors.first(where: { $0.id == id }) {
            ConnectorDetailView(connector: connector,
                                testedThisSession: $testedThisSession,
                                onRemove: { delete(.connector(connector)) })
        } else {
            ContentUnavailableView(
                "No Account Selected",
                systemImage: "person.crop.circle.badge.plus",
                description: Text("Add an account or select one to configure it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Deletes an account of any flavour (Keychain secret included where there
    /// is one — a connector holds no secret).
    fileprivate func delete(_ account: AnyAccount) {
        switch account {
        case .backend(let a):
            if let idx = appStore.backends.firstIndex(where: { $0.id == a.id }) {
                appStore.deleteBackends(at: IndexSet([idx]))
            }
        case .ai(let a):
            if let idx = appStore.aiServices.firstIndex(where: { $0.id == a.id }) {
                KeychainService.deleteSecret(for: a.id)
                appStore.deleteAIServices(at: IndexSet([idx]))
            }
        case .connector(let c):
            appStore.removeConnector(id: c.id)
        }
        if selectedID == account.id { selectedID = nil }
    }
}

// MARK: - Test-connection state (shared by both forms)

private struct TestConnectionRow: View {
    let run: () async throws -> String
    /// Reported so the list can show the session dot — see `AccountsView`.
    var onResult: ((Bool) -> Void)? = nil

    @State private var isTesting = false
    @State private var result: Result<String, Error>?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isTesting = true
                result = nil
                Task {
                    do { result = .success(try await run()); onResult?(true) }
                    catch { result = .failure(error); onResult?(false) }
                    isTesting = false
                }
            } label: {
                if isTesting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Test Connection", systemImage: "bolt")
                }
            }
            .disabled(isTesting)

            switch result {
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: - Secret field with inline test (same pattern as the GPG key row)

/// A redacted secret field with a compact ⚡ test button immediately to its
/// right and a green seal once the credential verifies.  The secret saves to
/// the Keychain as it's typed; a failed save is reported in place.
private struct SecretTestField: View {
    let prompt: String
    @Binding var secret: String
    let run: () async throws -> String
    var saveFailed = false
    /// Reported so the list can show the session dot — see `AccountsView`.
    var onResult: ((Bool) -> Void)? = nil

    @State private var isTesting = false
    @State private var result: Result<String, Error>?

    var body: some View {
        HStack(spacing: 8) {
            SecureField(prompt, text: $secret)
                .onChange(of: secret) { _, _ in result = nil }

            Button {
                isTesting = true
                result = nil
                Task {
                    do { result = .success(try await run()); onResult?(true) }
                    catch { result = .failure(error); onResult?(false) }
                    isTesting = false
                }
            } label: {
                if isTesting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "bolt")
                }
            }
            .controlSize(.small)
            .disabled(isTesting || secret.isEmpty)
            .help("Test the connection with this credential")

            if case .success = result {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .help("Connection verified")
            }
        }

        if saveFailed {
            Label("Couldn't save to the Keychain — try re-entering it.",
                  systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        }
        switch result {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Removal (same shape for every account flavour)

/// The last section of every detail pane: one red button behind a
/// confirmation.  Deleting an account is not a list gesture — it is a decision
/// made while looking at the account you mean.
struct RemoveAccountSection: View {
    let label: String
    let confirmTitle: String
    let confirmMessage: String
    let note: String
    let onRemove: () -> Void

    @State private var confirming = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                confirming = true
            } label: {
                Label(label, systemImage: "trash")
                    .foregroundStyle(.red)
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { onRemove() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(confirmMessage)
        }
    }
}

// MARK: - Backend account form

struct BackendAccountForm: View {
    @Environment(AppStore.self) private var appStore
    let account: BackendAccount
    /// Test results for this window's lifetime — see `AccountsView`.
    @Binding var testedThisSession: [UUID: Bool]
    let onRemove: () -> Void

    @State private var draft: BackendAccount
    @State private var token: String
    @State private var tokenSaveFailed = false

    init(account: BackendAccount,
         testedThisSession: Binding<[UUID: Bool]>,
         onRemove: @escaping () -> Void) {
        self.account = account
        _testedThisSession = testedThisSession
        self.onRemove = onRemove
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
                }

                Section("Credentials") {
                    SecretTestField(prompt: "Personal access token",
                                    secret: $token,
                                    run: { try await AccountTesting.test(backend: draft) },
                                    saveFailed: tokenSaveFailed,
                                    onResult: { testedThisSession[account.id] = $0 })
                    if draft.provider == .github {
                        Text("Fine-grained token with Contents read & write (plus \"Administration\" if you'll create repositories from the app). Stored in your Keychain only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text(draft.provider.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                RemoveAccountSection(
                    label: "Remove Account",
                    confirmTitle: "Remove “\(draft.displayName)”?",
                    confirmMessage: "The token is deleted from your Keychain. Manuscripts syncing to it stay local until you pick another account. Nothing on \(draft.provider.rawValue) is touched.",
                    note: "Removes this account and its Keychain token from the app.",
                    onRemove: onRemove)
            }
            .formStyle(.grouped)
        }
        .onChange(of: draft.displayName) { _, _ in appStore.updateBackend(draft) }
        .onChange(of: token) { _, new in
            tokenSaveFailed = !KeychainService.setSecret(new, for: account.id)
        }
        .onChange(of: account.id) { _, _ in
            draft = account
            token = KeychainService.secret(for: account.id) ?? ""
            tokenSaveFailed = false
        }
    }
}

// MARK: - AI account form

struct AIAccountForm: View {
    @Environment(AppStore.self) private var appStore
    let account: AIServiceAccount
    /// Test results for this window's lifetime — see `AccountsView`.
    @Binding var testedThisSession: [UUID: Bool]
    let onRemove: () -> Void

    @State private var draft: AIServiceAccount
    @State private var key: String

    init(account: AIServiceAccount,
         testedThisSession: Binding<[UUID: Bool]>,
         onRemove: @escaping () -> Void) {
        self.account = account
        _testedThisSession = testedThisSession
        self.onRemove = onRemove
        _draft = State(initialValue: account)
        _key = State(initialValue: KeychainService.secret(for: account.id) ?? "")
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Identity") {
                    TextField("Display name", text: $draft.displayName)
                    LabeledContent("Provider") {
                        Text(draft.provider.rawValue).foregroundStyle(.secondary)
                    }
                }

                Section("Credentials") {
                    if draft.provider.requiresAPIKey {
                        SecretTestField(prompt: "API key",
                                        secret: $key,
                                        run: { try await AccountTesting.test(aiService: draft) },
                                        onResult: { testedThisSession[account.id] = $0 })
                        Text("Stored in your Keychain only — never in app or manuscript files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No key needed — connects to the local service.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TestConnectionRow(run: { try await AccountTesting.test(aiService: draft) },
                                          onResult: { testedThisSession[account.id] = $0 })
                    }
                }

                Section {
                    Text(draft.provider.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                RemoveAccountSection(
                    label: "Remove Account",
                    confirmTitle: "Remove “\(draft.displayName)”?",
                    confirmMessage: "The API key is deleted from your Keychain. Manuscripts using it fall back to no AI until you pick another.",
                    note: "Removes this account and its Keychain key from the app.",
                    onRemove: onRemove)
            }
            .formStyle(.grouped)
        }
        .onChange(of: draft.displayName) { _, _ in appStore.updateAIService(draft) }
        .onChange(of: key) { _, new in
            KeychainService.setSecret(new, for: account.id)
            draft.hasKey = !new.isEmpty
            appStore.updateAIService(draft)
        }
        .onChange(of: account.id) { _, _ in
            draft = account
            key = KeychainService.secret(for: account.id) ?? ""
        }
    }
}

// MARK: - AddAccountSheet

/// One add sheet across both account flavors: pick any provider type
/// (GitHub, GitLab, …, Claude, OpenAI, …) and the right account is created.
struct AddAccountSheet: View {
    @Environment(AppStore.self) private var appStore
    @Binding var isPresented: Bool
    let onAdd: (UUID) -> Void

    private enum ProviderChoice: Hashable {
        case backend(BackendProvider)
        case ai(AIProvider)
        case connector(AIConnectorKind)
    }

    @State private var choice: ProviderChoice = .backend(.github)
    @State private var displayName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Account").font(.headline)

            Picker("Type", selection: $choice) {
                Section("Storage") {
                    ForEach(BackendProvider.allCases, id: \.self) { p in
                        Label(p.rawValue, systemImage: p.systemImage)
                            .tag(ProviderChoice.backend(p))
                    }
                }
                Section("AI — local (no key)") {
                    ForEach(AIConnectorKind.allCases) { kind in
                        Label(kind.displayName, systemImage: kind.systemImage)
                            .tag(ProviderChoice.connector(kind))
                    }
                }
                Section("AI — API key") {
                    ForEach(AIProvider.allCases, id: \.self) { p in
                        Label(p.rawValue, systemImage: p.systemImage)
                            .tag(ProviderChoice.ai(p))
                    }
                }
            }

            // A connector has no name to give: it is the local tool, and there
            // is only ever one of each.
            if case .connector(let kind) = choice {
                Text(kind.howToStart)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Display name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let id: UUID
                    switch choice {
                    case .backend(let provider):
                        var account = BackendAccount.empty(provider: provider)
                        if !displayName.isEmpty { account.displayName = displayName }
                        appStore.addBackend(account)
                        id = account.id
                    case .ai(let provider):
                        var account = AIServiceAccount.empty(provider: provider)
                        if !displayName.isEmpty { account.displayName = displayName }
                        appStore.addAIService(account)
                        id = account.id
                    case .connector(let kind):
                        let connector = AIConnector(kind: kind)
                        appStore.addConnector(connector)
                        id = connector.id
                    }
                    onAdd(id)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
