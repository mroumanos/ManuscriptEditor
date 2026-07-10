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
    /// Dropdown selection (fingerprint).
    @State private var selectedFingerprint: String?

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
                    if let localKeys {
                        // Dropdown of the local keyring, with a compact Test
                        // right beside it — green seal once verified.
                        HStack(spacing: 8) {
                            Picker("GPG key", selection: $selectedFingerprint) {
                                Text("Select a key…").tag(String?.none)
                                ForEach(localKeys) { key in
                                    Text(key.display).tag(Optional(key.fingerprint))
                                }
                            }
                            .labelsHidden()
                            .onChange(of: selectedFingerprint) { _, new in
                                testResult = nil
                                remoteVerified = false
                                SigningService.identityRemoteVerified = false
                                guard let new else { return }
                                if let armored = SigningService.exportLocalGPGKey(fingerprint: new) {
                                    gpgKey = armored
                                    SigningService.identityGPGKey = armored
                                } else {
                                    testResult = .failure(AccountTestError.failed(
                                        SigningService.lastGPGError ?? "Couldn't export that key."))
                                }
                                SigningService.killMirrorDaemons()
                            }

                            Button {
                                runTest()
                            } label: {
                                if isTesting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "bolt")
                                }
                            }
                            .controlSize(.small)
                            .disabled(isTesting || handle.isEmpty || selectedFingerprint == nil)
                            .help("Verify this key is registered to \(handle.isEmpty ? "your account" : handle)")

                            if remoteVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                                    .help("Verified against \(handle)")
                            }
                        }
                        // Confirm which key is in force: every stamp and note
                        // from now on is signed with the checked key.
                        if let fp = selectedFingerprint,
                           let key = localKeys.first(where: { $0.fingerprint == fp }) {
                            Label("\(key.name) (\(key.longID)) signs your stamps and notes",
                                  systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if case .failure(let error) = testResult {
                            Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                                .font(.caption).foregroundStyle(.red).lineLimit(3)
                        }
                    } else {
                        // Keyring unreadable: one-time grant, or a key file.
                        HStack(spacing: 10) {
                            Button {
                                grantKeyringAccess()
                            } label: {
                                Label("Allow Access to GPG Keyring…", systemImage: "lock.open")
                            }
                            .help("The sandbox blocks ~/.gnupg until you grant it once")
                            Button {
                                showKeyImporter = true
                            } label: {
                                Label(gpgKey.isEmpty ? "Select Key File…" : "GPG key selected",
                                      systemImage: gpgKey.isEmpty ? "key" : "key.fill")
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
                                    .font(.caption).foregroundStyle(.red).lineLimit(3)
                            case nil:
                                if remoteVerified {
                                    Label("Verified", systemImage: "checkmark.seal.fill")
                                        .font(.caption).foregroundStyle(.green)
                                }
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
        // Browse from HOME so .gnupg is selected as an item — starting inside
        // it made it too easy to grant a subfolder by accident.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The pick must be the gpg home itself, not something inside it.
        let looksLikeGPGHome = url.lastPathComponent == ".gnupg"
            || FileManager.default.fileExists(
                atPath: url.appendingPathComponent("private-keys-v1.d").path)
        guard looksLikeGPGHome else {
            testResult = .failure(AccountTestError.failed(
                "\"\(url.lastPathComponent)\" isn't a GPG home — select the .gnupg folder itself."))
            return
        }
        SigningService.grantGnupgAccess(url)
        localKeys = SigningService.localGPGKeys()
        if localKeys == nil {
            let detail = SigningService.lastGPGError.map { "\n\ngpg said: \($0)" } ?? ""
            testResult = .failure(AccountTestError.failed(
                "Couldn't read the keyring.\(detail)\n\nThe file picker (gpg --armor --export > key.asc) always works."))
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
