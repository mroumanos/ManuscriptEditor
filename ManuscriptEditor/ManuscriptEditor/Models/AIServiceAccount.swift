// AIServiceAccount.swift
//
// Represents a connected AI service for LLM-powered features (journal adaptation,
// writing assistance, etc.).
//
// DESIGN INTENT
// ─────────────────────────────────────────────────────────────────────────────
// AI integration is optional — the source manuscript editor works without it.
// AI is required for "cuts" (Phase 2): adapting the source to a journal's
// requirements using an LLM.
//
// Multiple AI accounts can be configured (e.g. Claude for main use, a local
// Ollama model for offline work).  The active service per manuscript is chosen
// in ManuscriptSettings.
//
// API KEY SECURITY (Phase 2)
// ─────────────────────────────────────────────────────────────────────────────
// In Phase 2, API keys will be stored in macOS Keychain, not in the JSON file.
// The `hasKey` flag here is just a UI indicator; the key itself lives in Keychain.

import Foundation

// MARK: - AIProvider

/// An AI service provider that can be connected to the app.
enum AIProvider: String, Codable, CaseIterable, Sendable {
    case claude  = "Claude (Anthropic)"
    case chatgpt = "ChatGPT (OpenAI)"
    case gemini  = "Gemini (Google)"
    case ollama  = "Ollama (Local)"

    /// SF Symbol representing this provider in the UI.
    var systemImage: String {
        switch self {
        case .claude:  return "sparkles"
        case .chatgpt: return "bubble.left.and.bubble.right"
        case .gemini:  return "diamond"
        case .ollama:  return "cpu"
        }
    }

    /// Short description shown in the "Add AI Service" sheet.
    var description: String {
        switch self {
        case .claude:  return "Anthropic's Claude — recommended for academic writing"
        case .chatgpt: return "OpenAI's GPT-4 and later models"
        case .gemini:  return "Google's Gemini models"
        case .ollama:  return "Locally-hosted models via Ollama (no internet required)"
        }
    }

    /// Whether this provider requires a remote API key.
    var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        default:      return true
        }
    }
}

// MARK: - AIServiceAccount

/// One configured AI service the user can use for LLM-powered features.
///
/// Stored globally in `AppStore`.  Per-manuscript activation is via
/// `ManuscriptSettings.activeAIServiceID`.
struct AIServiceAccount: Codable, Identifiable, Sendable {

    /// Stable unique identifier.
    var id: UUID

    /// Which AI service this account connects to.
    var provider: AIProvider

    /// User-assigned label (e.g. "My Anthropic Key" or "Lab Ollama").
    var displayName: String

    /// `true` when an API key (or local endpoint) has been configured.
    /// The key itself is stored in Keychain (Phase 2); this is just a UI flag.
    var hasKey: Bool

    /// For Ollama or custom deployments: the base URL of the API endpoint.
    /// Empty for cloud providers that use a fixed endpoint.
    var customEndpoint: String

    /// When this account was added.
    var addedAt: Date

    // MARK: - Factory

    /// A blank, unconfigured AI service account.
    static func empty(provider: AIProvider) -> AIServiceAccount {
        AIServiceAccount(
            id: UUID(),
            provider: provider,
            displayName: provider.rawValue,
            hasKey: false,
            customEndpoint: "",
            addedAt: Date()
        )
    }
}
