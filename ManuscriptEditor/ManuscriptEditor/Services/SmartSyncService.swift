// SmartSyncService.swift
//
// Smart sync (Phase II AI capability, explicitly approved Aug 2026): adapts
// manuscript sections from one journal toward another's requirements using
// the connected Claude account, ahead of a fast-forward/backward override.
//
// One non-streaming Claude API call per sync (claude-opus-5, structured
// outputs so the response is guaranteed-parseable JSON).  Claude is the only
// provider implemented; other AI accounts get an honest error upstream.

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

    private struct AdaptedSection: Decodable {
        let id: String
        let content: String
    }
    private struct AdaptedPayload: Decodable {
        let sections: [AdaptedSection]
    }

    /// Rewrites each active, non-empty section toward `targetName`'s
    /// requirements.  Returns section id → adapted plain text.
    func adaptSections(_ sections: [ManuscriptSection],
                       targetName: String,
                       requirements: JournalRequirements?,
                       apiKey: String) async throws -> [UUID: String] {
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

        Return every section with its original id and the adapted text.
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "sections": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string"],
                            "content": ["type": "string"],
                        ],
                        "required": ["id", "content"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["sections"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": 16000,
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": prompt]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 600   // adaptation of a full manuscript can take minutes
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SmartSyncError.badResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
            throw SmartSyncError.badResponse(message ?? "HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartSyncError.badResponse("unparseable response")
        }
        // Check stop_reason before reading content — safety classifiers can
        // decline with a 200 + "refusal".
        if json["stop_reason"] as? String == "refusal" { throw SmartSyncError.refused }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let adapted = try? JSONDecoder().decode(AdaptedPayload.self, from: Data(text.utf8))
        else { throw SmartSyncError.badResponse("missing or malformed text content") }

        var out: [UUID: String] = [:]
        for section in adapted.sections {
            if let id = UUID(uuidString: section.id) { out[id] = section.content }
        }
        return out
    }
}
