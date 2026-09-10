// KeychainService.swift
//
// Minimal Keychain wrapper for backend/AI service credentials.
//
// Secrets (personal access tokens, API keys) must never land in app.json or
// manuscript.json — both are plain files the user may sync or publish.  The
// Keychain is the platform's credential store: sandboxed per app, encrypted,
// and survives app reinstalls.  Items are keyed by the owning account's UUID.

import Foundation
import Security

enum KeychainService {

    /// Namespaces this app's items in the Keychain.
    private static let service = "knktech.ManuscriptEditor"

    /// Stores (or replaces) a secret for an account.  Empty secrets delete.
    @discardableResult
    static func setSecret(_ secret: String, for accountID: UUID) -> Bool {
        guard !secret.isEmpty else { return deleteSecret(for: accountID) }
        guard let data = secret.data(using: .utf8) else { return false }

        var query = baseQuery(for: accountID)
        // Replace-then-add: SecItemUpdate can't create, SecItemAdd can't replace.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            var addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // An item exists but isn't accessible to this build (created
                // under a different sandbox partition — e.g. before the app
                // was unsandboxed).  Clear the slot and write fresh.
                SecItemDelete(baseQuery(for: accountID) as CFDictionary)
                addStatus = SecItemAdd(query as CFDictionary, nil)
            }
            return addStatus == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// What a read actually found.
    ///
    /// **"Nothing stored" and "couldn't read it" are different facts**, and
    /// collapsing them into `nil` caused real damage: `SigningService` read nil
    /// as "first run", minted a fresh signing key, and overwrote the stored
    /// one — so every denied prompt or code-signature change quietly created a
    /// NEW identity.  One manuscript ended up with three keys for the same
    /// person.  A caller holding a credential has to be able to tell the
    /// difference before it decides to replace anything.
    enum ReadOutcome {
        case found(String)
        /// The slot is genuinely empty.
        case notFound
        /// Something is stored but this build could not read it — denied,
        /// locked, or a different signing identity.  Never treat as empty.
        case unreadable(OSStatus)
    }

    static func read(for accountID: UUID) -> ReadOutcome {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                return .unreadable(status)
            }
            return .found(string)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unreadable(status)
        }
    }

    /// Reads the secret for an account, or nil when none is stored **or** it
    /// couldn't be read.  Callers that will WRITE on nil must use `read`
    /// instead — see `ReadOutcome`.
    static func secret(for accountID: UUID) -> String? {
        if case .found(let value) = read(for: accountID) { return value }
        return nil
    }

    /// Removes the secret for an account (e.g. when the account is deleted).
    @discardableResult
    static func deleteSecret(for accountID: UUID) -> Bool {
        let status = SecItemDelete(baseQuery(for: accountID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(for accountID: UUID) -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
    }
}
