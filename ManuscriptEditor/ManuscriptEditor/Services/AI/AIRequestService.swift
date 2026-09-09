// AIRequestService.swift
//
// The one place a prompt leaves this app.
//
// Two shapes of destination exist — a local CLI the user is already signed
// into (`AIConnector`), and a keyed HTTP API (`AIServiceAccount`) — and both
// arrive here so that the things that must happen on *every* request happen in
// one place: the context checkboxes are honoured, the prompt is assembled, and
// the outcome is written to the prompt log.
//
// See MasterContext/11-ai-integration.md §6–7.

import Foundation

// MARK: - Destination

/// Where a request goes, resolved from the manuscript's settings.
enum AIDestination: Sendable {
    case connector(AIConnector)
    /// A keyed service and the secret read from the Keychain at call time.
    case service(AIServiceAccount, apiKey: String?)

    /// "Claude Code" / "Claude (Anthropic)" — what the log records.
    var label: String {
        switch self {
        case .connector(let c): return c.kind.displayName
        case .service(let a, _): return a.displayName
        }
    }

    /// The model this manuscript asked for.  What actually answered is read
    /// back from the tool where it reports it.
    var requestedModel: String {
        switch self {
        case .connector(let c):
            return c.selectedModel.isEmpty ? AIModelCatalog.defaultModel(for: c.kind) : c.selectedModel
        case .service(let a, _):
            return a.provider.rawValue
        }
    }
}

// MARK: - Result

struct AISendResult: Sendable {
    let text: String
    /// The CLI session this ran under, when there was one — the key to its
    /// transcript on disk.
    var sessionID: String? = nil
    /// The model that answered, as reported; falls back to what was requested.
    let model: String
    let duration: TimeInterval
    /// True when a different model answered than the one selected.
    let modelWasSubstituted: Bool
}

// MARK: - Service

struct AIRequestService: Sendable {

    /// How long a manuscript-sized request is given before it is abandoned.
    ///
    /// Fifteen minutes, against the connector's own 120 s default.  A
    /// fast-forward asks for every section of a paper to be rewritten, and the
    /// generation — not the network — is what takes the time: a real
    /// seven-section manuscript ran past ten minutes.  Killing a request that
    /// was about to land is the worse failure, and nothing is written until it
    /// returns, so the cutoff is generous and the row shows the clock against
    /// it.
    static let longRunTimeout = 900

    /// Sends one prompt and returns the raw text.  No parsing, no application —
    /// an intent owns both, so this stays the same for every future feature.
    static func send(prompt: String,
                     to destination: AIDestination,
                     sessionID: UUID? = nil,
                     expectsJSON: Bool = true,
                     timeout: Int = longRunTimeout,
                     onProgress: (@Sendable (AIRunProgress) -> Void)? = nil) async throws -> AISendResult {
        switch destination {
        case .connector(let connector):
            var edited = connector
            if edited.selectedModel.isEmpty {
                edited.selectedModel = AIModelCatalog.defaultModel(for: edited.kind)
            }
            let result = try await AIConnectorRunner.run(prompt: prompt,
                                                        connector: edited,
                                                        sessionID: sessionID,
                                                        timeout: timeout,
                                                        onProgress: onProgress)
            return AISendResult(text: result.text,
                                sessionID: result.sessionID,
                                model: result.reportedModel ?? edited.selectedModel,
                                duration: result.duration,
                                modelWasSubstituted: result.modelWasSubstituted)

        case .service(let account, let key):
            let started = Date()
            let text = try await SmartSyncService().sendPrompt(prompt, account: account,
                                                               apiKey: key, expectsJSON: expectsJSON)
            return AISendResult(text: text,
                                sessionID: nil,
                                model: account.provider.rawValue,
                                duration: Date().timeIntervalSince(started),
                                modelWasSubstituted: false)
        }
    }

    // MARK: - Prompt assembly

    /// Context first, then the task.
    ///
    /// The context comes from `AIContextBundle`, which has already dropped
    /// every row the user unticked — assembling it anywhere else is how a
    /// checkbox gets quietly ignored.
    static func prompt(context: AIContextBundle, task: String) -> String {
        guard !context.isEmpty else { return task }
        return """
        # Context

        \(context.promptText)

        # Task

        \(task)
        """
    }

    // MARK: - Reading a model's JSON

    /// Pulls the outermost JSON object out of a reply.
    ///
    /// Models wrap JSON in prose or a ``` fence often enough that refusing
    /// anything but a bare object throws away good answers; this takes the
    /// first `{` to the last `}` and lets the decoder judge the rest.
    static func extractJSONObject(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }
}
