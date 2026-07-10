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
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Reads the secret for an account, or nil when none is stored.
    static func secret(for accountID: UUID) -> String? {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
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
