// UserIdentityView.swift
//
// Preferences → User: the identity that attributes manuscript activity.
//
// Four identity types:
//   Local   — freeform name; the app's auto-generated signing key is all
//             that vouches for you (badges cap at "?").
//   GitHub  — pair the signing key with a GPG public key registered to a
//             GitHub username (public API check) → badges earn the green ✓.
//   GitLab  — same, against a GitLab username.
//   OpenPGP — same, against an email on the keys.openpgp.org keyserver.
//
// The app's P-256 key does the actual signing either way; the GPG key is the
// publicly verifiable anchor tying that identity to a real account.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct UserIdentityView: View {

    @State private var name = SigningService.userName
    @State private var type = SigningService.identityType
    @State private var handle = SigningService.identityHandle
    @State private var gpgKey = SigningService.identityGPGKey
    @State private var remoteVerified = SigningService.identityRemoteVerified
    @State private var publicKey = SigningService.publicKeyBase64 ?? ""
    @State private var confirmRegenerate = false
    @State private var showKeyImporter = false
    @State private var isTesting = false
    @State private var testResult: Result<String, Error>?
    /// Local gpg keyring contents (nil = gpg unavailable/blocked).
    @State private var localKeys: [SigningService.GPGKey]?

    var body: some View {
        Form {
            Section("Identity") {
                Picker("Type", selection: $type) {
                    ForEach(IdentityType.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: type) { _, new in
                    SigningService.identityType = new
                    remoteVerified = false
                    SigningService.identityRemoteVerified = false
                    testResult = nil
                }

                TextField("Name", text: $name)
                    .onChange(of: name) { _, new in SigningService.userName = new }

                if type == .local {
                    Label("Local identities can't be authenticated: collaborators see your edits with a \"?\" — they can't verify who actually made them. Use GitHub/GitLab/OpenPGP to earn the verified ✓.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    TextField(type.handlePrompt ?? "", text: $handle)
                        .autocorrectionDisabled()
                        .onChange(of: handle) { _, new in
                            SigningService.identityHandle = new
                            remoteVerified = false
                            SigningService.identityRemoteVerified = false
                        }
                }
            }

            if type != .local {
                Section("GPG Key") {
                    HStack(spacing: 10) {
                        // The user's local gpg keyring as a menu.  The App
                        // Sandbox blocks ~/.gnupg until the user grants it
                        // once; the file picker below always works.
                        if let localKeys {
                            // "<name>, <email> (<long ID>, <algorithm>)"
                            Menu {
                                ForEach(localKeys) { key in
                                    Button(key.display) {
                                        if let armored = SigningService.exportLocalGPGKey(fingerprint: key.fingerprint) {
                                            gpgKey = armored
                                            SigningService.identityGPGKey = armored
                                            testResult = nil
                                        } else {
                                            testResult = .failure(AccountTestError.failed(
                                                "Couldn't export that key — try the file picker (gpg --armor --export > key.asc)."))
                                        }
                                    }
                                }
                            } label: {
                                Label("Choose from local GPG…", systemImage: "key.viewfinder")
                            }
                            .fixedSize()
                        } else {
                            Button {
                                grantKeyringAccess()
                            } label: {
                                Label("Allow Access to GPG Keyring…", systemImage: "lock.open")
                            }
                            .help("The sandbox blocks ~/.gnupg until you grant it once; gpg is then queried with --homedir")
                        }
                        Button {
                            showKeyImporter = true
                        } label: {
                            Label(gpgKey.isEmpty ? "Select Key File…" : "GPG key selected",
                                  systemImage: gpgKey.isEmpty ? "key" : "key.fill")
                        }
                        if !gpgKey.isEmpty {
                            Button("Clear") {
                                gpgKey = ""
                                SigningService.identityGPGKey = ""
                                remoteVerified = false
                                SigningService.identityRemoteVerified = false
                            }
                            .controlSize(.small)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            runTest()
                        } label: {
                            if isTesting {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Test", systemImage: "bolt")
                            }
                        }
                        .disabled(isTesting || handle.isEmpty || gpgKey.isEmpty)

                        switch testResult {
                        case .success(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        case .failure(let error):
                            Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                                .font(.caption).foregroundStyle(.red).lineLimit(2)
                        case nil:
                            if remoteVerified {
                                Label("Verified", systemImage: "checkmark.seal.fill")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                    }

                    if let url = type.howToURL {
                        Link("How to register a GPG key with \(type.label)", destination: url)
                            .font(.caption)
                    }
                }
            }

            if type == .local {
            Section("Signing Key (this Mac)") {
                LabeledContent("Public key") {
                    HStack(spacing: 8) {
                        Text(publicKey.isEmpty ? "unavailable" : publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(publicKey, forType: .string)
                        }
                        .controlSize(.small)
                        .disabled(publicKey.isEmpty)
                    }
                }
                Button("Regenerate Key…", role: .destructive) {
                    confirmRegenerate = true
                }
                Text("Signs every stamp/comment; the private half stays in your Keychain. Editors are independent of manuscript authors — your name and this key travel with your activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { localKeys = SigningService.localGPGKeys() }
        .fileImporter(isPresented: $showKeyImporter,
                      allowedContentTypes: [.plainText, .data, .item]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8),
               text.contains("PGP PUBLIC KEY") {
                gpgKey = text
                SigningService.identityGPGKey = text
                testResult = nil
            } else {
                testResult = .failure(AccountTestError.failed("That file isn't an ASCII-armored GPG public key (export with: gpg --armor --export you@example.com)."))
            }
        }
        .confirmationDialog("Regenerate Signing Key?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) {
                SigningService.regenerateKey()
                publicKey = SigningService.publicKeyBase64 ?? ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Past signatures keep verifying against the old public key; new activity signs with the new key.")
        }
    }

    /// One-time sandbox grant: the user points an open panel at ~/.gnupg;
    /// the bookmark persists and gpg runs against it via --homedir.
    private func grantKeyringAccess() {
        let panel = NSOpenPanel()
        panel.title = "Allow Access to GPG Keyring"
        panel.message = "Select your GPG home folder (usually ~/.gnupg) so the app can list your keys."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gnupg", isDirectory: true)
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SigningService.grantGnupgAccess(url)
        localKeys = SigningService.localGPGKeys()
        if localKeys == nil {
            testResult = .failure(AccountTestError.failed(
                "Still couldn't read the keyring — gpg may be storing keys elsewhere. The file picker (gpg --armor --export > key.asc) always works."))
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            do {
                let message = try await SigningService.verifyRemoteKey(
                    type: type, handle: handle, armoredKey: gpgKey)
                testResult = .success(message)
                remoteVerified = true
                SigningService.identityRemoteVerified = true
            } catch {
                testResult = .failure(error)
                remoteVerified = false
                SigningService.identityRemoteVerified = false
            }
            isTesting = false
        }
    }
}
