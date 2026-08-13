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

    var id: UUID {
        switch self {
        case .backend(let a): return a.id
        case .ai(let a):      return a.id
        }
    }

    var displayName: String {
        switch self {
        case .backend(let a): return a.displayName
        case .ai(let a):      return a.displayName
        }
    }

    var providerName: String {
        switch self {
        case .backend(let a): return a.provider.rawValue
        case .ai(let a):      return a.provider.rawValue
        }
    }

    var systemImage: String {
        switch self {
        case .backend(let a): return a.provider.systemImage
        case .ai(let a):      return a.provider.systemImage
        }
    }
}

// MARK: - AccountsView

struct AccountsView: View {
    @Environment(AppStore.self) private var appStore

    @State private var selectedID: UUID?
    @State private var showAddSheet = false

    private var accounts: [AnyAccount] {
        appStore.backends.map(AnyAccount.backend) + appStore.aiServices.map(AnyAccount.ai)
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
                            Button {
                                delete(account)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this account (its Keychain secret included)")
                        }
                        .padding(.vertical, 3)
                        .tag(account.id)
                        .contextMenu {
                            Button("Delete Account", role: .destructive) { delete(account) }
                        }
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
            BackendAccountForm(account: backend)
        } else if let id = selectedID,
                  let ai = appStore.aiServices.first(where: { $0.id == id }) {
            AIAccountForm(account: ai)
        } else {
            ContentUnavailableView(
                "No Account Selected",
                systemImage: "person.crop.circle.badge.plus",
                description: Text("Add an account or select one to configure it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Deletes an account of either flavor (Keychain secret included).
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
        }
        if selectedID == account.id { selectedID = nil }
    }
}

// MARK: - Test-connection state (shared by both forms)

private struct TestConnectionRow: View {
    let run: () async throws -> String

    @State private var isTesting = false
    @State private var result: Result<String, Error>?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isTesting = true
                result = nil
                Task {
                    do { result = .success(try await run()) }
                    catch { result = .failure(error) }
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

    @State private var isTesting = false
    @State private var result: Result<String, Error>?
    var saveFailed = false

    var body: some View {
        HStack(spacing: 8) {
            SecureField(prompt, text: $secret)
                .onChange(of: secret) { _, _ in result = nil }

            Button {
                isTesting = true
                result = nil
                Task {
                    do { result = .success(try await run()) }
                    catch { result = .failure(error) }
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

// MARK: - Backend account form

struct BackendAccountForm: View {
    @Environment(AppStore.self) private var appStore
    let account: BackendAccount
    @State private var draft: BackendAccount
    @State private var token: String
    @State private var tokenSaveFailed = false

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
                }

                Section("Credentials") {
                    SecretTestField(prompt: "Personal access token",
                                    secret: $token,
                                    run: { try await AccountTesting.test(backend: draft) },
                                    saveFailed: tokenSaveFailed)
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
    @State private var draft: AIServiceAccount
    @State private var key: String

    init(account: AIServiceAccount) {
        self.account = account
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
                                        run: { try await AccountTesting.test(aiService: draft) })
                        Text("Stored in your Keychain only — never in app or manuscript files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No key needed — connects to the local service.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TestConnectionRow { try await AccountTesting.test(aiService: draft) }
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
                Section("AI") {
                    ForEach(AIProvider.allCases, id: \.self) { p in
                        Label(p.rawValue, systemImage: p.systemImage)
                            .tag(ProviderChoice.ai(p))
                    }
                }
            }

            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)

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
