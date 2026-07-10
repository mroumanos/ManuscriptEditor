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

    /// The App Sandbox blocks ~/.gnupg by default; the user can grant access
    /// once via an open panel (Preferences → User) and we keep a
    /// security-scoped bookmark, passing the folder to gpg as --homedir.
    static func grantGnupgAccess(_ url: URL) {
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "gnupgHomeBookmark")
        }
    }

    /// The granted GPG home (access started), or nil when never granted.
    private static var gnupgHome: URL? {
        guard let data = UserDefaults.standard.data(forKey: "gnupgHomeBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    static var hasGnupgGrant: Bool {
        UserDefaults.standard.data(forKey: "gnupgHomeBookmark") != nil
    }

    /// One secret key from the local keyring, formatted for the dropdown as
    /// "<name>, <email> (<long ID>, <algorithm>)".
    struct GPGKey: Identifiable {
        let fingerprint: String
        let name: String
        let email: String
        let longID: String
        let algorithm: String

        var id: String { fingerprint }
        var display: String {
            let who = [name, email].filter { !$0.isEmpty }.joined(separator: ", ")
            return "\(who.isEmpty ? "(no uid)" : who) (\(longID), \(algorithm))"
        }
    }

    /// gpg public-key algorithm ids (RFC 4880 + ECC extensions).
    private static let gpgAlgorithms: [String: String] = [
        "1": "RSA", "2": "RSA", "3": "RSA", "16": "ElGamal", "17": "DSA",
        "18": "ECDH", "19": "ECDSA", "22": "EdDSA",
    ]

    /// Where gpg should look for the keyring: the granted folder when the
    /// spawned child can read it, else a **mirror inside our own container**.
    /// Sandbox children don't reliably inherit the parent's folder grant, but
    /// the PARENT does hold it — so the app copies the keyring into its
    /// container (always readable by children), points gpg at the mirror, and
    /// nothing ever leaves the machine.
    private static var effectiveGPGHome: URL?

    /// Secret keys from the user's local gpg (`--list-secret-keys
    /// --keyid-format=long`), for the identity dropdown.  Returns nil when
    /// gpg is missing or the keyring is unreachable — callers fall back to
    /// the key-file picker.
    static func localGPGKeys() -> [GPGKey]? {
        // 1. Direct (works when unsandboxed or the grant carries through).
        if let home = gnupgHome, let keys = parseSecretKeys(runGPG(home: home)) {
            effectiveGPGHome = home
            return keys
        }
        if let keys = parseSecretKeys(runGPG(home: nil)) {
            effectiveGPGHome = nil
            return keys
        }
        // 2. Container mirror: the parent copies the granted keyring into the
        //    sandbox container, where the child can always read it.
        guard let mirror = mirrorGrantedKeyring(),
              let keys = parseSecretKeys(runGPG(home: mirror)) else { return nil }
        effectiveGPGHome = mirror
        return keys
    }

    /// The armored public key for a local gpg fingerprint.
    static func exportLocalGPGKey(fingerprint: String) -> String? {
        var arguments = ["--armor", "--export", fingerprint]
        if let home = effectiveGPGHome {
            arguments = ["--homedir", home.path, "--no-permission-warning"] + arguments
        }
        guard let armored = runGPGRaw(arguments), armored.contains("PGP PUBLIC KEY") else { return nil }
        return armored
    }

    private static func runGPG(home: URL?) -> String? {
        var arguments = ["--list-secret-keys", "--keyid-format=long", "--with-colons"]
        if let home {
            arguments = ["--homedir", home.path, "--no-permission-warning"] + arguments
        }
        return runGPGRaw(arguments)
    }

    private static func parseSecretKeys(_ output: String?) -> [GPGKey]? {
        guard let output else { return nil }
        var keys: [GPGKey] = []
        var algorithm = ""
        var longID = ""
        var fingerprint: String?
        for line in output.components(separatedBy: .newlines) {
            let fields = line.components(separatedBy: ":")
            switch fields.first {
            case "sec" where fields.count > 4:
                algorithm = gpgAlgorithms[fields[3]] ?? "algo \(fields[3])"
                longID = fields[4]
                fingerprint = nil
            case "fpr" where fingerprint == nil && fields.count > 9:
                fingerprint = fields[9]
            case "uid" where fields.count > 9:
                guard let fpr = fingerprint else { break }
                // uid is "Name (comment) <email>".
                var uid = fields[9]
                var email = ""
                if let open = uid.range(of: "<"), let close = uid.range(of: ">") {
                    email = String(uid[open.upperBound..<close.lowerBound])
                    uid.removeSubrange(open.lowerBound..<close.upperBound)
                }
                let name = uid
                    .replacingOccurrences(of: "\\(.*\\)", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                keys.append(GPGKey(fingerprint: fpr, name: name, email: email,
                                   longID: longID, algorithm: algorithm))
                fingerprint = nil
            default:
                break
            }
        }
        return keys.isEmpty ? nil : keys
    }

    /// Copies the granted ~/.gnupg into the app container (skipping sockets
    /// and locks) so the sandboxed gpg child can read it.  Refreshed on every
    /// call; lives only inside this app's private container.
    private static func mirrorGrantedKeyring() -> URL? {
        guard let source = gnupgHome else { return nil }
        let fm = FileManager.default
        let mirror = fm.temporaryDirectory.appendingPathComponent("gnupg-mirror", isDirectory: true)
        try? fm.removeItem(at: mirror)
        do {
            try fm.createDirectory(at: mirror, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            else { return nil }
            for item in items {
                let name = item.lastPathComponent
                // Sockets (S.gpg-agent…) and locks can't/shouldn't be copied.
                if name.hasPrefix("S.") || name.hasSuffix(".lock") { continue }
                try? fm.copyItem(at: item, to: mirror.appendingPathComponent(name))
            }
            // Copied lock files deeper in the tree (keyboxd's
            // public-keys.d/pubring.db.lock) reference the user's LIVE
            // daemons — gpg would wait on them and time out.  Strip them all.
            if let walker = fm.enumerator(at: mirror, includingPropertiesForKeys: nil) {
                for case let url as URL in walker {
                    let name = url.lastPathComponent
                    if name.hasSuffix(".lock") || name.hasPrefix("S.") {
                        try? fm.removeItem(at: url)
                    }
                }
            }
            return mirror
        } catch {
            return nil
        }
    }

    /// Stops the gpg-agent/keyboxd instances spawned for the mirror homedir
    /// so queries don't leave daemons running against a temp folder.
    static func killMirrorDaemons() {
        guard let home = effectiveGPGHome else { return }
        _ = runTool("gpgconf", ["--homedir", home.path, "--kill", "all"])
    }

    /// The last gpg failure (stderr), surfaced by the identity UI.
    static private(set) var lastGPGError: String?

    private static func runGPGRaw(_ arguments: [String]) -> String? {
        runTool("gpg", arguments)
    }

    private static func runTool(_ tool: String, _ arguments: [String]) -> String? {
        let prefixes = ["/opt/homebrew/bin/", "/usr/local/bin/",
                        "/usr/local/MacGPG2/bin/", "/usr/bin/"]
        guard let path = prefixes.map({ $0 + tool })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            lastGPGError = "\(tool) not found (looked in Homebrew, MacGPG2, /usr/bin)."
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                lastGPGError = errText.isEmpty ? "\(tool) exited \(process.terminationStatus)" : errText
                return nil
            }
            lastGPGError = nil
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            lastGPGError = error.localizedDescription
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
