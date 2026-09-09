// SmartSyncService.swift
//
// The keyed-HTTP half of the AI transport: one prompt in, the model's text
// out, for any provider the app supports (Claude, ChatGPT, Gemini, or a local
// Ollama), non-streaming.
//
// It knows nothing about manuscripts.  What to ask and what to do with the
// answer belong to an intent (`Services/AI/Intents/`), and every caller
// arrives through `AIRequestService`, which is where the context checkboxes
// and the prompt log are enforced.
//
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

    // MARK: - Provider dispatch

    /// One prompt in, the model's text out — per provider.
    ///
    /// Internal rather than private: `AIRequestService` sends every intent's
    /// prompt through here, so the keyed-API path has one implementation
    /// rather than a second one that drifts.
    /// `expectsJSON` puts the provider into its JSON mode.  An intent that
    /// wants prose back passes false, rather than every provider branch
    /// assuming the shape the first intent happened to need.
    func sendPrompt(_ prompt: String,
                    account: AIServiceAccount,
                    apiKey: String?,
                    expectsJSON: Bool = true) async throws -> String {
        var request: URLRequest
        let custom = account.customEndpoint.isEmpty ? nil : URL(string: account.customEndpoint)

        switch account.provider {
        case .claude:
            request = URLRequest(url: custom ?? URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "claude-opus-5",
                "max_tokens": 16000,
                "messages": [["role": "user", "content": prompt]],
            ] as [String: Any])
        case .chatgpt:
            request = URLRequest(url: custom ?? URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(apiKey ?? "")", forHTTPHeaderField: "Authorization")
            var body: [String: Any] = [
                "model": "gpt-4o",
                "messages": [["role": "user", "content": prompt]],
            ]
            if expectsJSON { body["response_format"] = ["type": "json_object"] }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        case .gemini:
            let base = custom ?? URL(string:
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent?key=\(apiKey ?? "")")!
            request = URLRequest(url: base)
            var body: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
            if expectsJSON {
                body["generationConfig"] = ["responseMimeType": "application/json"]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        case .ollama:
            request = URLRequest(url: custom ?? URL(string: "http://localhost:11434/api/chat")!)
            var body: [String: Any] = [
                "model": "llama3.1",
                "stream": false,
                "messages": [["role": "user", "content": prompt]],
            ]
            if expectsJSON { body["format"] = "json" }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
