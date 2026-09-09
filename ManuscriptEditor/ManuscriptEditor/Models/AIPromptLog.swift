// AIPromptLog.swift
//
// A record of every request this manuscript has made to a model.
//
// WHY THIS EXISTS BEFORE ANY FEATURE THAT USES IT
// ─────────────────────────────────────────────────────────────────────────────
// For scientific work, *"which parts of this were AI-written, from what prompt,
// by which model"* is a question that will be asked — by a co-author, a
// journal, or the writer themselves a year later.  A log that ships with the
// manuscript answers it without anyone having to remember, so it is built
// first: no intent runs before there is somewhere to record it.
//
// It lives in `<manuscript>/ai/`, NOT in `manuscript.json` — a fast-forward
// prompt carries an entire journal, and burying that in the file the app
// rewrites on every save would cost save speed and make git diffs unreadable.
//
//   ai/log.json              this index
//   ai/prompts/<id>.txt      the rendered prompt, verbatim
//   ai/responses/<id>.txt    the raw response
//
// See MasterContext/11-ai-integration.md §6.

import Foundation

// MARK: - What one request changed

/// A summary of what a response did to one piece of the manuscript.
///
/// Measured with `SentenceSimilarity` — the same comparison compare mode uses,
/// so "changed" means the same thing in the log as it does on screen.
struct AIPromptLogChange: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// The section (or other component) that was rewritten.
    var title: String
    var wordsBefore: Int
    var wordsAfter: Int
    /// Share of the new text's sentences with no counterpart in the old, 0…1.
    var rewrittenFraction: Double
    /// Share carried over untouched, 0…1.
    var unchangedFraction: Double

    /// "312 → 287 words · 41% rewritten"
    var summary: String {
        let pct = Int((rewrittenFraction * 100).rounded())
        return "\(wordsBefore) → \(wordsAfter) words · \(pct)% rewritten"
    }

    /// Built from the two texts, so callers can't disagree about the measure.
    static func measure(title: String, before: String, after: String) -> AIPromptLogChange {
        let matches = SentenceSimilarity.matches(in: after, against: before)
        let total = SentenceSimilarity.sentences(in: after).count
        let exact = matches.filter { $0.kind == .exact }.count
        let matched = matches.count
        return AIPromptLogChange(
            title: title,
            wordsBefore: WordCountService.count(before),
            wordsAfter: WordCountService.count(after),
            rewrittenFraction: total == 0 ? 0 : Double(total - matched) / Double(total),
            unchangedFraction: total == 0 ? 0 : Double(exact) / Double(total))
    }
}

// MARK: - One entry

struct AIPromptLogEntry: Identifiable, Codable, Sendable, Equatable {

    enum Outcome: String, Codable, Sendable {
        /// The response was accepted and written into the manuscript.
        case applied
        /// The request ran but nothing was written (nothing came back to write).
        case noChange
        /// The request failed; `detail` says how.
        case failed

        var systemImage: String {
            switch self {
            case .applied:  return "checkmark.circle.fill"
            case .noChange: return "minus.circle.fill"
            case .failed:   return "exclamationmark.triangle.fill"
            }
        }
    }

    var id: UUID = UUID()

    /// The intent's stable id — `grep -rn "AI INTENT"` finds the code.
    var intentID: String
    /// What the user asked for, in a line: "Fast-forward NEJM from Source".
    var summary: String

    /// Which tool answered and which model, recorded from what the tool
    /// reported rather than what was requested — they can differ.
    var connectorLabel: String
    var model: String

    var startedAt: Date
    var duration: TimeInterval

    var outcome: Outcome
    /// Error text for a failure; a note otherwise.
    var detail: String?

    /// The context rows that were enabled when this ran — the answer to
    /// "what did it see", which the checkbox table decided.
    var contextTitles: [String] = []
    /// Rows the user had switched off, so the log records what was withheld.
    var excludedContextTitles: [String] = []

    var promptCharacters: Int = 0
    var responseCharacters: Int = 0

    var changes: [AIPromptLogChange] = []

    /// The CLI session id, which is also this entry's id: the app hands the
    /// tool a session id of its own choosing so the tool's transcript for this
    /// run sits at a path the app can compute and open.  That matters most
    /// when a run fails, which is when someone wants the tool's own log.
    var sessionID: String? = nil

    /// Tolerant decoding: the log ships with the manuscript and outlives any
    /// one version of the app.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        intentID = try c.decodeIfPresent(String.self, forKey: .intentID) ?? "unknown"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        connectorLabel = try c.decodeIfPresent(String.self, forKey: .connectorLabel) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        outcome = try c.decodeIfPresent(Outcome.self, forKey: .outcome) ?? .applied
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        contextTitles = try c.decodeIfPresent([String].self, forKey: .contextTitles) ?? []
        excludedContextTitles = try c.decodeIfPresent([String].self, forKey: .excludedContextTitles) ?? []
        promptCharacters = try c.decodeIfPresent(Int.self, forKey: .promptCharacters) ?? 0
        responseCharacters = try c.decodeIfPresent(Int.self, forKey: .responseCharacters) ?? 0
        changes = try c.decodeIfPresent([AIPromptLogChange].self, forKey: .changes) ?? []
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
    }

    init(id: UUID = UUID(), intentID: String, summary: String,
         connectorLabel: String, model: String,
         startedAt: Date, duration: TimeInterval, outcome: Outcome, detail: String? = nil,
         contextTitles: [String] = [], excludedContextTitles: [String] = [],
         promptCharacters: Int = 0, responseCharacters: Int = 0,
         changes: [AIPromptLogChange] = [], sessionID: String? = nil) {
        self.id = id
        self.intentID = intentID
        self.summary = summary
        self.connectorLabel = connectorLabel
        self.model = model
        self.startedAt = startedAt
        self.duration = duration
        self.outcome = outcome
        self.detail = detail
        self.contextTitles = contextTitles
        self.excludedContextTitles = excludedContextTitles
        self.promptCharacters = promptCharacters
        self.responseCharacters = responseCharacters
        self.changes = changes
        self.sessionID = sessionID
    }
}
