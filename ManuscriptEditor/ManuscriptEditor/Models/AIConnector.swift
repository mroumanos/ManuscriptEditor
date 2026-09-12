// AIConnector.swift
//
// A **connector** is a locally installed service the app drives — an agent CLI
// the user is already signed into (Claude Code, Codex, Gemini) or a local model
// server (Ollama).
//
// WHY THERE IS NO CREDENTIAL HERE
// ─────────────────────────────────────────────────────────────────────────────
// The whole point of a connector is that the app borrows an authentication the
// user has already made somewhere else: they ran `claude` once and signed in,
// or they started Ollama.  Nothing is stored, transmitted, or billed by us, and
// there is no key to leak.  That is why this type has no Keychain entry and the
// settings row has no password field — only a path, a model, and a Test button.
//
// See MasterContext/features/ai-assist.md for the design this implements.

import Foundation

// MARK: - AIConnectorKind

enum AIConnectorKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCLI
    case codexCLI
    case geminiCLI
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCLI: return "Claude Code"
        case .codexCLI:  return "Codex"
        case .geminiCLI: return "Gemini CLI"
        case .ollama:    return "Ollama"
        }
    }

    var systemImage: String {
        switch self {
        case .claudeCLI: return "sparkles"
        case .codexCLI:  return "chevron.left.forwardslash.chevron.right"
        case .geminiCLI: return "diamond"
        case .ollama:    return "cpu"
        }
    }

    /// Shown under the row: what this connector is and how to get it running.
    var howToStart: String {
        switch self {
        case .claudeCLI:
            return "Runs on your Claude subscription — no API key. Install the CLI, then sign in by running it once."
        case .codexCLI:
            return "Runs on your ChatGPT subscription — no API key. The ChatGPT app for Mac bundles the CLI; otherwise install it. Sign in once with `codex login`."
        case .geminiCLI:
            return "Runs on your Google account. Install the CLI, then sign in by running it once."
        case .ollama:
            return "Runs models locally — free, offline, private. Start Ollama and pull a model."
        }
    }

    /// A copyable command that gets the user from nothing to working.
    var installCommand: String {
        switch self {
        case .claudeCLI: return "npm install -g @anthropic-ai/claude-code"
        case .codexCLI:  return "npm install -g @openai/codex"
        case .geminiCLI: return "npm install -g @google/gemini-cli"
        case .ollama:    return "brew install ollama && ollama serve"
        }
    }

    /// The executable's name on `PATH`, for CLI connectors.
    var executableName: String? {
        switch self {
        case .claudeCLI: return "claude"
        case .codexCLI:  return "codex"
        case .geminiCLI: return "gemini"
        case .ollama:    return nil        // reached over HTTP, not spawned
        }
    }

    /// Ollama answers on a URL rather than a path.
    var defaultEndpoint: String? {
        self == .ollama ? "http://localhost:11434" : nil
    }

    /// Whether the app can drive this connector yet.  Gemini is modelled so
    /// the settings UI and the plan are honest about what is coming.
    var isImplemented: Bool { self == .claudeCLI || self == .codexCLI || self == .ollama }
}

// MARK: - Model catalog

/// The models a connector offers.
///
/// Only Ollama can be enumerated honestly (`/api/tags` lists what is actually
/// installed).  For the CLIs the list is curated and will age, so every
/// connector also accepts a **free-text** model id — a user on a newer CLI must
/// not be blocked by a stale app release.  The dropdown offers; `Test` confirms.
enum AIModelCatalog {

    struct Entry: Identifiable, Hashable {
        let id: String          // what gets passed to --model
        let label: String
    }

    static func models(for kind: AIConnectorKind) -> [Entry] {
        switch kind {
        case .claudeCLI:
            return [
                Entry(id: "claude-opus-5",     label: "Claude Opus 5"),
                Entry(id: "claude-fable-5-1",  label: "Claude Fable 5.1"),
                Entry(id: "claude-fable-5",    label: "Claude Fable 5"),
                Entry(id: "claude-opus-4-8",   label: "Claude Opus 4.8"),
                Entry(id: "claude-opus-4-7",   label: "Claude Opus 4.7"),
                Entry(id: "claude-opus-4-6",   label: "Claude Opus 4.6"),
                Entry(id: "claude-sonnet-5",   label: "Claude Sonnet 5"),
                Entry(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6"),
                Entry(id: "claude-haiku-4-5",  label: "Claude Haiku 4.5"),
            ]
        case .codexCLI, .geminiCLI:
            return []           // curated once verified; free text until then
        case .ollama:
            return []           // discovered live: `AIModelCatalog.installedOllamaModels`
        }
    }

    /// What an Ollama server actually has pulled — the only model list this
    /// app can give honestly, since it is read off the server rather than
    /// remembered from a release.  Empty when the server isn't answering.
    static func installedOllamaModels(endpoint: String) async -> [Entry] {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces))?
                .appendingPathComponent("api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let name = model["name"] as? String else { return nil }
            let details = model["details"] as? [String: Any]
            let size = details?["parameter_size"] as? String
            return Entry(id: name, label: size.map { "\(name) (\($0))" } ?? name)
        }
    }

    static func defaultModel(for kind: AIConnectorKind) -> String {
        switch kind {
        case .claudeCLI: return "claude-opus-5"
        case .codexCLI:  return ""
        case .geminiCLI: return ""
        case .ollama:    return ""     // whatever the server has pulled; Test picks the first
        }
    }
}

// MARK: - AIConnector

struct AIConnector: Identifiable, Codable, Sendable, Equatable {

    var id: UUID = UUID()
    var kind: AIConnectorKind

    /// Where the executable actually is.  **Editable, and it has to be:** a GUI
    /// app launched from Finder does not inherit the shell's `PATH`, so a CLI in
    /// `/opt/homebrew/bin` or `~/.local/bin` is invisible to a naive spawn.
    /// `Test` resolves this and writes back what it found.
    var executablePath: String = ""

    /// Ollama's base URL, where a path makes no sense.
    var endpoint: String = ""

    var selectedModel: String = ""

    /// The models this connector was seen to offer, as of the last `Test`.
    ///
    /// Only Ollama fills this — it is read off the server (`/api/tags`), so
    /// it is the one model list the app can give honestly.  Kept on the
    /// connector so the manuscript's model picker can list it without a
    /// network call in the middle of a render.
    var availableModels: [String] = []

    /// Result of the last `Test`, kept so the row can say something useful
    /// without re-running anything.
    var lastTestedAt: Date? = nil
    var lastTestSucceeded: Bool? = nil
    var lastTestMessage: String? = nil

    init(kind: AIConnectorKind) {
        self.kind = kind
        self.selectedModel = AIModelCatalog.defaultModel(for: kind)
        self.endpoint = kind.defaultEndpoint ?? ""
    }

    var displayName: String { kind.displayName }

    /// "Local" — there is no account name, because there is no account.
    var subtitle: String { "Local" }

    /// Whether this connector is ready to be used for real work.
    var isReady: Bool { lastTestSucceeded == true }

    /// The models to offer for this connector: the curated list for a CLI,
    /// what the server has pulled for Ollama.
    var modelEntries: [AIModelCatalog.Entry] {
        if kind == .ollama {
            return availableModels.map { AIModelCatalog.Entry(id: $0, label: $0) }
        }
        return AIModelCatalog.models(for: kind)
    }

    // MARK: Codable (tolerant — new fields must not break old app.json)

    private enum CodingKeys: String, CodingKey {
        case id, kind, executablePath, endpoint, selectedModel, availableModels
        case lastTestedAt, lastTestSucceeded, lastTestMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(AIConnectorKind.self, forKey: .kind) ?? .claudeCLI
        executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint)
            ?? (kind.defaultEndpoint ?? "")
        selectedModel = try c.decodeIfPresent(String.self, forKey: .selectedModel)
            ?? AIModelCatalog.defaultModel(for: kind)
        availableModels = try c.decodeIfPresent([String].self, forKey: .availableModels) ?? []
        lastTestedAt = try c.decodeIfPresent(Date.self, forKey: .lastTestedAt)
        lastTestSucceeded = try c.decodeIfPresent(Bool.self, forKey: .lastTestSucceeded)
        lastTestMessage = try c.decodeIfPresent(String.self, forKey: .lastTestMessage)
    }
}
