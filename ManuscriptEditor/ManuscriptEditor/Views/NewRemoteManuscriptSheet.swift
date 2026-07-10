// NewRemoteManuscriptSheet.swift
//
// File → New Manuscript (Remote)…: create a manuscript bound to a backend
// repository.  The user picks the backend type + account (from Preferences →
// Accounts) and enters the repository link ("owner/name" or a full GitHub
// URL).  A local copy is always kept (visible in Manuscript → Backend); if
// the repository already holds a manuscript it is pulled, otherwise the new
// manuscript becomes its first commit.

import SwiftUI

struct NewRemoteManuscriptSheet: View {
    @Environment(ManuscriptStore.self) private var store
    @Environment(AppStore.self)        private var appStore

    @Binding var isPresented: Bool
    /// Called after creation so the window can reset selection/tabs.
    let onCreated: () -> Void

    @State private var accountID: UUID?
    @State private var link = ""
    @State private var branch = ""

    /// Git-hosting accounts only (a manuscript can't live in an LLM).
    private var accounts: [BackendAccount] {
        appStore.backends.filter { $0.provider == .github || $0.provider == .gitlab }
    }

    /// "owner/name" from either a bare slug or a pasted URL.
    private var repository: String? {
        var s = link.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://github.com/", "http://github.com/", "git@github.com:"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        let parts = s.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Manuscript (Remote)").font(.headline)

            if accounts.isEmpty {
                Text("No Git-hosting accounts configured yet. Add a GitHub account in Preferences → Accounts (⌘,) first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Account", selection: $accountID) {
                    ForEach(accounts) { account in
                        Label("\(account.displayName) (\(account.provider.rawValue))",
                              systemImage: account.provider.systemImage)
                            .tag(Optional(account.id))
                    }
                }

                TextField("Repository (owner/name or URL)", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                TextField("Branch", text: $branch, prompt: Text("main"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                Text("A local copy is kept on this Mac (see Manuscript → Backend). If the repository already contains a manuscript, it is loaded; an empty repository gets this new manuscript pushed to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    guard let accountID, let repository else { return }
                    store.createNewRemote(repository: repository, branch: branch,
                                          accountID: accountID, appStore: appStore)
                    isPresented = false
                    onCreated()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(accountID == nil || repository == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { accountID = accounts.first?.id }
    }
}
