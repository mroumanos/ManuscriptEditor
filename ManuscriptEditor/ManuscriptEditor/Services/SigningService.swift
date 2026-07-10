// SigningService.swift
//
// The user's cryptographic identity: a P-256 signing keypair generated
// automatically on first use.  The private key lives in the **Keychain
// only** — it never enters manuscript files or app.json.  The public key is
// what travels: it can be tied to manuscript authors (`Author.publicKeys`),
// and every stamp/comment carries the signer's public key + a signature so
// collaborators can verify who did what (see `SignatureBadge`).
//
// Scope note: signatures attribute *identity* to an action (this key stamped
// this version / wrote this comment).  They deliberately do not hash the
// whole manuscript content — this is authorship attribution, not a
// tamper-evident ledger.

import Foundation
import CryptoKit

/// How the user's identity is anchored.  Local identities sign with the
/// app-generated key only — nothing external vouches for them; remote types
/// pair the app key with a GPG key that is publicly registered (GitHub,
/// GitLab, or the keys.openpgp.org keyserver), so collaborators can verify
/// who an editor actually is.
enum IdentityType: String, CaseIterable, Identifiable {
    case local, github, gitlab, openpgp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local:   return "Local"
        case .github:  return "GitHub"
        case .gitlab:  return "GitLab"
        case .openpgp: return "OpenPGP"
        }
    }

    /// What the handle field means (nil = no handle needed).
    var handlePrompt: String? {
        switch self {
        case .local:   return nil
        case .github:  return "GitHub username"
        case .gitlab:  return "GitLab username"
        case .openpgp: return "Email address"
        }
    }

    /// Provider documentation for registering a GPG key.
    var howToURL: URL? {
        switch self {
        case .local:   return nil
        case .github:  return URL(string: "https://docs.github.com/en/authentication/managing-commit-signature-verification/adding-a-gpg-key-to-your-github-account")
        case .gitlab:  return URL(string: "https://docs.gitlab.com/ee/user/gpg_signed_commits/")
        case .openpgp: return URL(string: "https://keys.openpgp.org/about/usage")
        }
    }
}

enum SigningService {

    /// Reserved Keychain slot for the user's signing key (KeychainService is
    /// keyed by UUID; this one is never used by a backend account).
    private static let keySlot = UUID(uuidString: "51674E00-0000-4000-8000-000000000001")!

    // MARK: - Identity (type + handle + GPG anchor)

    static var identityType: IdentityType {
        get { UserDefaults.standard.string(forKey: "identityType")
                .flatMap(IdentityType.init(rawValue:)) ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "identityType") }
    }

    /// GitHub/GitLab username or OpenPGP email.
    static var identityHandle: String {
        get { UserDefaults.standard.string(forKey: "identityHandle") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "identityHandle") }
    }

    /// The user's ASCII-armored GPG **public** key (remote types) — public
    /// material, safe in UserDefaults.
    static var identityGPGKey: String {
        get { UserDefaults.standard.string(forKey: "identityGPGKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "identityGPGKey") }
    }

    /// Whether the last remote check confirmed the GPG key is registered to
    /// the handle.
    static var identityRemoteVerified: Bool {
        get { UserDefaults.standard.bool(forKey: "identityRemoteVerified") }
        set { UserDefaults.standard.set(newValue, forKey: "identityRemoteVerified") }
    }

    /// The identity type recorded on artifacts at signing time: a remote type
    /// only counts once its GPG registration check passed; otherwise the
    /// artifact is honestly marked local (badge shows "?").
    static var effectiveIdentityType: String {
        (identityType != .local && identityRemoteVerified)
            ? identityType.rawValue
            : IdentityType.local.rawValue
    }

    // MARK: - Local GPG keyring (best effort)

    /// Secret keys from the user's local gpg, for the identity dropdown.
    /// Returns nil when gpg is missing or the sandbox blocks ~/.gnupg —
    /// callers fall back to the key-file picker.
    static func localGPGKeys() -> [(fingerprint: String, uid: String)]? {
        guard let output = runGPG(["--list-secret-keys", "--with-colons"]) else { return nil }
        var keys: [(String, String)] = []
        var fingerprint: String?
        for line in output.components(separatedBy: .newlines) {
            let fields = line.components(separatedBy: ":")
            switch fields.first {
            case "fpr" where fingerprint == nil && fields.count > 9:
                fingerprint = fields[9]
            case "uid" where fields.count > 9:
                if let fpr = fingerprint {
                    keys.append((fpr, fields[9]))
                    fingerprint = nil
                }
            case "sec":
                fingerprint = nil
            default:
                break
            }
        }
        return keys.isEmpty ? nil : keys
    }

    /// The armored public key for a local gpg fingerprint.
    static func exportLocalGPGKey(fingerprint: String) -> String? {
        guard let armored = runGPG(["--armor", "--export", fingerprint]),
              armored.contains("PGP PUBLIC KEY") else { return nil }
        return armored
    }

    private static func runGPG(_ arguments: [String]) -> String? {
        let candidates = ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg",
                          "/usr/local/MacGPG2/bin/gpg", "/usr/bin/gpg"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Remote GPG key verification

    /// Confirms the selected GPG public key is registered to the handle on
    /// the provider (GitHub/GitLab public API, or the keys.openpgp.org
    /// keyserver).  Returns a success line; throws a readable failure.
    static func verifyRemoteKey(type: IdentityType, handle: String, armoredKey: String) async throws -> String {
        let localBody = armorBody(armoredKey)
        guard !localBody.isEmpty else {
            throw AccountTestError.failed("Select an ASCII-armored GPG public key file first (-----BEGIN PGP PUBLIC KEY BLOCK-----).")
        }
        let remoteKeys: [String]
        switch type {
        case .local:
            return "Local identity — nothing to verify."
        case .github:
            let data = try await fetch("https://api.github.com/users/\(handle)/gpg_keys")
            let list = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            remoteKeys = (list ?? []).compactMap { $0["raw_key"] as? String }
        case .gitlab:
            let userData = try await fetch("https://gitlab.com/api/v4/users?username=\(handle)")
            guard let users = try? JSONSerialization.jsonObject(with: userData) as? [[String: Any]],
                  let id = users.first?["id"] as? Int else {
                throw AccountTestError.failed("GitLab user \"\(handle)\" not found.")
            }
            let keysData = try await fetch("https://gitlab.com/api/v4/users/\(id)/gpg_keys")
            let list = (try? JSONSerialization.jsonObject(with: keysData) as? [[String: Any]]) ?? []
            remoteKeys = (list ?? []).compactMap { $0["key"] as? String }
        case .openpgp:
            let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? handle
            let data = try await fetch("https://keys.openpgp.org/vks/v1/by-email/\(encoded)")
            remoteKeys = [String(data: data, encoding: .utf8) ?? ""]
        }
        guard remoteKeys.contains(where: { keysMatch(armorBody($0), localBody) }) else {
            throw AccountTestError.failed("The selected GPG key isn't registered to \"\(handle)\" — upload it there first (see How-To).")
        }
        return "Verified — the GPG key is registered to \(handle)."
    }

    /// The base64 payload of an armored block, whitespace/headers stripped —
    /// good enough to compare "same key" without a full PGP parser.
    private static func armorBody(_ armored: String) -> String {
        var lines = armored.components(separatedBy: .newlines)
        lines.removeAll {
            $0.hasPrefix("-----") || $0.contains(":") || $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // Drop the trailing CRC line ("=xxxx").
        if let last = lines.last, last.hasPrefix("=") { lines.removeLast() }
        return lines.joined()
    }

    private static func keysMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    private static func fetch(_ url: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 15
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AccountTestError.failed("Could not reach the service: \(error.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AccountTestError.failed(code == 404
                ? "Not found — check the username/email."
                : "The service returned HTTP \(code).")
        }
        return data
    }

    /// The user-facing signer name.  Defaults to the macOS account's full
    /// name; editable in Preferences → User.
    static var userName: String {
        get {
            UserDefaults.standard.string(forKey: "userIdentityName").flatMap {
                $0.isEmpty ? nil : $0
            } ?? NSFullUserName()
        }
        set { UserDefaults.standard.set(newValue, forKey: "userIdentityName") }
    }

    /// Loads the private key, generating and storing one on first use.
    private static func privateKey() -> P256.Signing.PrivateKey? {
        if let stored = KeychainService.secret(for: keySlot),
           let data = Data(base64Encoded: stored),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        guard KeychainService.setSecret(key.rawRepresentation.base64EncodedString(), for: keySlot) else {
            return nil
        }
        return key
    }

    /// The user's public key (base64 raw representation), creating the
    /// keypair on first access.  nil only if the Keychain is unavailable.
    static var publicKeyBase64: String? {
        privateKey()?.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Discards the current keypair and generates a new one (Preferences →
    /// User → Regenerate).  Old signatures then verify against authors only
    /// if the old public key was already tied to one.
    static func regenerateKey() {
        KeychainService.deleteSecret(for: keySlot)
        _ = publicKeyBase64
    }

    // MARK: - Signing

    /// Signs a message with the user's key; returns base64 DER, or nil when
    /// no key is available.
    static func sign(_ message: String) -> String? {
        guard let key = privateKey(),
              let data = message.data(using: .utf8),
              let signature = try? key.signature(for: data)
        else { return nil }
        return signature.derRepresentation.base64EncodedString()
    }

    /// Verifies a base64 DER signature over `message` against a base64
    /// public key.
    static func verify(message: String, signature: String, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? P256.Signing.PublicKey(rawRepresentation: keyData),
              let sigData = Data(base64Encoded: signature),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: sigData),
              let msg = message.data(using: .utf8)
        else { return false }
        return key.isValidSignature(sig, for: msg)
    }

    // MARK: - Message conventions (what exactly gets signed)

    private static let iso = ISO8601DateFormatter()

    /// Stamp attribution: version identity + moment + signer name.
    static func stampMessage(id: UUID, createdAt: Date, author: String) -> String {
        "stamp|\(id.uuidString)|\(iso.string(from: createdAt))|\(author)"
    }

    /// Note attribution: note identity + moment + body text (a body edit by
    /// the original signer re-signs; anyone else's edit breaks the badge).
    static func noteMessage(id: UUID, createdAt: Date, body: String) -> String {
        "note|\(id.uuidString)|\(iso.string(from: createdAt))|\(body)"
    }
}
