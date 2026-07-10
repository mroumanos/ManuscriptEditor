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

enum SigningService {

    /// Reserved Keychain slot for the user's signing key (KeychainService is
    /// keyed by UUID; this one is never used by a backend account).
    private static let keySlot = UUID(uuidString: "51674E00-0000-4000-8000-000000000001")!

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
