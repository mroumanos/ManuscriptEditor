// ManuscriptSettings.swift
//
// Per-manuscript configuration: which backend, view template, and AI service
// to use for this manuscript.
//
// WHY PER-MANUSCRIPT
// ─────────────────────────────────────────────────────────────────────────────
// Backends, view configs, and AI services are global (stored in AppStore and
// reusable across all manuscripts).  But a researcher may be working on two
// papers simultaneously: one synced to GitHub, the other to Google Docs, each
// using a different view template.  Storing the active selections here means
// each manuscript remembers its own setup independently.

import Foundation

/// Per-manuscript selections for backend, view, and AI service.
struct ManuscriptSettings: Codable, Sendable {
    /// Manuscript-wide citation format (RefEngine.CitationStyle raw code:
    /// "n" numeric, "p" parenthesized, "s" superscript, "ay" author–year,
    /// "na" narrative).  Every in-text citation renders with this.
    /// Optional for backward-compatible decoding; nil = numeric.
    var defaultCitationStyle: String? = nil


    /// The `BackendAccount.id` of the account currently used to sync this manuscript.
    /// `nil` means local-only storage (no sync).
    var activeBackendID: UUID?

    /// The `ViewConfig.id` of the view template applied to the source manuscript.
    /// `nil` means no view has been configured; Checks will show a placeholder.
    var activeViewID: UUID?

    /// The `AIServiceAccount.id` of the AI service to use for cuts and suggestions.
    /// `nil` means no AI configured; cut creation will be disabled.
    var activeAIServiceID: UUID?

    /// The remote repository this manuscript syncs to, in "owner/name" form.
    /// Per-manuscript (two manuscripts can use one account with different
    /// repos).  nil = no remote configured yet.  Optional fields keep older
    /// files decoding.
    var remoteRepository: String?

    /// Remote branch.  nil = "main".
    var remoteBranch: String?

    // MARK: - Factory

    /// Default settings: nothing selected (local-only, no view, no AI).
    static func empty() -> ManuscriptSettings {
        ManuscriptSettings(
            activeBackendID: nil,
            activeViewID: nil,
            activeAIServiceID: nil
        )
    }
}
