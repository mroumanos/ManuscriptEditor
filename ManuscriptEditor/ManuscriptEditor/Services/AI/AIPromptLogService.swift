// AIPromptLogService.swift
//
// Reads and writes the prompt log in `<manuscript>/ai/`.
//
// Append-only by design: an entry is written when a request finishes, whatever
// the outcome, and nothing in the app rewrites or removes one.  A log that can
// be quietly tidied answers no question worth asking.
//
// See MasterContext/features/ai-assist.md §6.

import Foundation

struct AIPromptLogService: Sendable {

    let persistence: PersistenceService

    init(persistence: PersistenceService = PersistenceService()) {
        self.persistence = persistence
    }

    // MARK: - Reading

    /// Every entry, newest first.
    func entries(for manuscriptID: UUID) -> [AIPromptLogEntry] {
        let url = persistence.aiDirectory(for: manuscriptID)
            .appendingPathComponent("log.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? decoder.decode([AIPromptLogEntry].self, from: data)) ?? []
        return entries.sorted { $0.startedAt > $1.startedAt }
    }

    /// The prompt exactly as it was sent.  Kept beside the log rather than in
    /// it: one fast-forward prompt can run to hundreds of kilobytes.
    func promptText(_ id: UUID, in manuscriptID: UUID) -> String? {
        try? String(contentsOf: promptURL(id, in: manuscriptID), encoding: .utf8)
    }

    func responseText(_ id: UUID, in manuscriptID: UUID) -> String? {
        try? String(contentsOf: responseURL(id, in: manuscriptID), encoding: .utf8)
    }

    // MARK: - Writing

    /// Appends one entry and its payloads.  Returns false if the log couldn't
    /// be written — the caller reports that rather than pretending it ran
    /// unrecorded.
    @discardableResult
    func append(_ entry: AIPromptLogEntry,
                prompt: String,
                response: String,
                to manuscriptID: UUID) -> Bool {
        let dir = persistence.aiDirectory(for: manuscriptID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Read-modify-write of a file only this app appends to; a manuscript is
        // open in one window at a time.
        var all = entries(for: manuscriptID)
        all.append(entry)
        all.sort { $0.startedAt < $1.startedAt }

        do {
            try encoder.encode(all).write(to: dir.appendingPathComponent("log.json"), options: .atomic)
            try prompt.write(to: promptURL(entry.id, in: manuscriptID),
                             atomically: true, encoding: .utf8)
            try response.write(to: responseURL(entry.id, in: manuscriptID),
                               atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Paths

    private func promptURL(_ id: UUID, in manuscriptID: UUID) -> URL {
        persistence.aiPromptsDirectory(for: manuscriptID)
            .appendingPathComponent("\(id.uuidString.lowercased()).txt")
    }

    private func responseURL(_ id: UUID, in manuscriptID: UUID) -> URL {
        persistence.aiResponsesDirectory(for: manuscriptID)
            .appendingPathComponent("\(id.uuidString.lowercased()).txt")
    }
}
