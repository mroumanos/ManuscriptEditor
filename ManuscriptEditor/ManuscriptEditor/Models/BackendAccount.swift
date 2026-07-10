// BackendAccount.swift
//
// Represents an external storage/sync backend that the user has connected.
//
// DESIGN INTENT
// ─────────────────────────────────────────────────────────────────────────────
// The app is "backend-free" by default — all manuscript data is stored locally.
// Users who want cloud persistence, collaboration, or backups can connect an
// external backend here.  Multiple accounts can be added, but only one is the
// "active" backend for a given manuscript (chosen in ManuscriptSettings).
//
// CONNECTION MODEL (Phase 2)
// ─────────────────────────────────────────────────────────────────────────────
// Phase 1 stubs the connection flow.  Phase 2 will implement OAuth / token auth
// for each provider and live bi-directional sync.  The `isConnected` flag and
// `syncStatus` are placeholders so the UI can be built now.

import Foundation

// MARK: - BackendProvider

/// The external service that hosts/syncs the manuscript data.
enum BackendProvider: String, Codable, CaseIterable, Sendable {
    case github     = "GitHub"
    case googleDocs = "Google Docs"
    case gitlab     = "GitLab"
    case office365  = "Office 365"
    case dropbox    = "Dropbox"

    /// SF Symbol name used to represent this provider in the UI.
    var systemImage: String {
        switch self {
        case .github:     return "chevron.left.forwardslash.chevron.right"
        case .googleDocs: return "doc.richtext"
        case .gitlab:     return "server.rack"
        case .office365:  return "doc.text"
        case .dropbox:    return "tray.2"
        }
    }

    /// Short description shown in the "Add Backend" picker.
    var description: String {
        switch self {
        case .github:     return "Git repository hosted on GitHub"
        case .googleDocs: return "Google Docs folder"
        case .gitlab:     return "Git repository hosted on GitLab"
        case .office365:  return "Microsoft OneDrive / SharePoint"
        case .dropbox:    return "Dropbox folder"
        }
    }
}

// MARK: - BackendSyncStatus

/// The current sync state of a connected backend account.
enum BackendSyncStatus: String, Codable, Sendable {
    /// Connection has never been tested or is unconfigured.
    case unknown        = "Unknown"
    /// Successfully connected and able to sync.
    case available      = "Sync Available"
    /// Currently in the process of syncing.
    case syncing        = "Syncing…"
    /// Last sync attempt failed; see `lastErrorMessage`.
    case error          = "Sync Error"
    /// Connection has been deliberately paused by the user.
    case paused         = "Paused"
}

// MARK: - BackendAccount

/// One external storage/sync account the user has configured.
///
/// Accounts are stored in `AppStore` (not per-manuscript).  Any manuscript can
/// reference an account's `id` as its `activeBackendID` in `ManuscriptSettings`.
struct BackendAccount: Codable, Identifiable, Sendable {

    /// Stable unique identifier.  Never changes after creation.
    var id: UUID

    /// The service this account connects to (GitHub, Google Docs, etc.).
    var provider: BackendProvider

    /// User-assigned nickname shown in pickers and lists (e.g. "Work GitHub").
    var displayName: String

    /// The login name or email on the remote service (informational only).
    var username: String

    /// Whether the connection has been authenticated and tested.
    /// `false` until the OAuth/token flow completes in Phase 2.
    var isConnected: Bool

    /// Current sync health, updated by the sync engine.
    var syncStatus: BackendSyncStatus

    /// The most recent error from the sync engine, if `syncStatus == .error`.
    var lastErrorMessage: String?

    /// When this account was first added.
    var addedAt: Date

    // MARK: - Factory

    /// A blank, disconnected account ready to be configured.
    static func empty(provider: BackendProvider) -> BackendAccount {
        BackendAccount(
            id: UUID(),
            provider: provider,
            displayName: provider.rawValue,
            username: "",
            isConnected: false,
            syncStatus: .unknown,
            lastErrorMessage: nil,
            addedAt: Date()
        )
    }
}
