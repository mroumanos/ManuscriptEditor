// SmartSyncService.swift
//
// Smart sync (Phase II AI capability, explicitly approved Aug 2026): adapts
// manuscript sections from one journal toward another's requirements using
// the manuscript's connected AI service — any provider the app supports
// (Claude, ChatGPT, Gemini, or a local Ollama), one non-streaming call per
// sync.  Every provider is asked for the same JSON shape
// {"sections": [{"id", "content"}]}; Claude uses structured outputs, the
// others their JSON-mode equivalents.

import Foundation

struct SmartSyncService {

    enum SmartSyncError: LocalizedError {
        case badResponse(String)
        case refused

        var errorDescription: String? {
            switch self {
            case .badResponse(let detail): return "AI service error: \(detail)"
            case .refused: return "The AI declined to process this content."
            }
        }
    }

    private struct AdaptedSection: Decodable { let id: String; let content: String }
    private struct AdaptedPayload: Decodable { let sections: [AdaptedSection] }

    /// Rewrites each active, non-empty section toward `targetName`'s
    /// requirements.  Returns section id → adapted plain text.
    func adaptSections(_ sections: [ManuscriptSection],
                       targetName: String,
                       requirements: JournalRequirements?,
                       account: AIServiceAccount,
                       apiKey: String?) async throws -> [UUID: String] {
        let payload = sections
            .filter { $0.active && !$0.content.isEmpty }
            .map { ["id": $0.id.uuidString, "title": $0.title, "text": $0.content.plain] }
        guard !payload.isEmpty else { return [:] }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let reqText = (try? requirements.map { String(data: try encoder.encode($0), encoding: .utf8) ?? "" })
            .flatMap { $0 } ?? "none specified — use a clear, general scientific register"
        let sectionsJSON = String(data: try JSONSerialization.data(withJSONObject: payload,
                                                                   options: [.sortedKeys]),
                                  encoding: .utf8) ?? "[]"

        let prompt = """
        You are adapting sections of a scientific manuscript for submission to \
        "\(targetName)". Rewrite each section's text to suit that venue while \
        preserving every scientific claim, number, and citation marker exactly \
        as written — adapt register, structure, and length toward the \
        requirements; never invent or drop content.

        Target journal requirements (JSON): \(reqText)

        Sections (JSON array of {id, title, text}): \(sectionsJSON)

        Respond with JSON only, in the shape \
        {"sections": [{"id": "<same id>", "content": "<adapted text>"}]} — \
        one entry per input section.
        """

        let text = try await complete(prompt: prompt, account: account, apiKey: apiKey)
        guard let adapted = try? JSONDecoder().decode(AdaptedPayload.self, from: Data(text.utf8))
        else { throw SmartSyncError.badResponse("missing or malformed JSON in the reply") }

        var out: [UUID: String] = [:]
        for section in adapted.sections {
            if let id = UUID(uuidString: section.id) { out[id] = section.content }
        }
        return out
    }

    // MARK: - Provider dispatch

    /// One prompt in, the model's text out — per provider.
    private func complete(prompt: String,
                          account: AIServiceAccount,
                          apiKey: String?) async throws -> String {
        var request: URLRequest
        let custom = account.customEndpoint.isEmpty ? nil : URL(string: account.customEndpoint)

        switch account.provider {
        case .claude:
            request = URLRequest(url: custom ?? URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let schema: [String: Any] = [
                "type": "object",
                "properties": ["sections": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["id": ["type": "string"], "content": ["type": "string"]],
                    "required": ["id", "content"], "additionalProperties": false]]],
                "required": ["sections"], "additionalProperties": false,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "claude-opus-5",
                "max_tokens": 16000,
                "output_config": ["format": ["type": "json_schema", "schema": schema]],
                "messages": [["role": "user", "content": prompt]],
            ] as [String: Any])
        case .chatgpt:
            request = URLRequest(url: custom ?? URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(apiKey ?? "")", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-4o",
                "response_format": ["type": "json_object"],
                "messages": [["role": "user", "content": prompt]],
            ] as [String: Any])
        case .gemini:
            let base = custom ?? URL(string:
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent?key=\(apiKey ?? "")")!
            request = URLRequest(url: base)
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["responseMimeType": "application/json"],
            ] as [String: Any])
        case .ollama:
            request = URLRequest(url: custom ?? URL(string: "http://localhost:11434/api/chat")!)
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "llama3.1",
                "format": "json",
                "stream": false,
                "messages": [["role": "user", "content": prompt]],
            ] as [String: Any])
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600   // a full manuscript can take minutes

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw SmartSyncError.badResponse(message ?? "HTTP \(code) from \(account.provider.rawValue)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartSyncError.badResponse("unparseable response")
        }

        switch account.provider {
        case .claude:
            if json["stop_reason"] as? String == "refusal" { throw SmartSyncError.refused }
            if let content = json["content"] as? [[String: Any]],
               let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                return text
            }
        case .chatgpt:
            if let choices = json["choices"] as? [[String: Any]],
               let text = (choices.first?["message"] as? [String: Any])?["content"] as? String {
                return text
            }
        case .gemini:
            if let candidates = json["candidates"] as? [[String: Any]],
               let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                return text
            }
        case .ollama:
            if let text = (json["message"] as? [String: Any])?["content"] as? String {
                return text
            }
        }
        throw SmartSyncError.badResponse("no text content in the reply")
    }
}
