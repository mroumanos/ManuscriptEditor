// FastForwardIntent.swift
//
// AI INTENT  journal.fastForward
//   Sends:   enabled context rows · the upstream's section text ·
//            the target journal's profile (requirements bullets, structure,
//            and every check with its limits)
//   Writes:  the downstream cut's sections, as a new stamped version
//   Reverts: the overridden content is stamped into version history first,
//            so the previous state is a version, not a lost edit
//
// A fast-forward already exists as a mechanical copy: the upstream's latest
// content replaces the downstream cut's, verbatim.  With Assist on, the same
// button asks the model to ADAPT each section toward the target journal on the
// way down — which is the work a researcher actually does by hand between two
// venues, and the reason cuts exist at all.
//
// TWO RULES THIS PROMPT IS BUILT AROUND
// ─────────────────────────────────────────────────────────────────────────────
// 1. **Never invent, never drop.** Every claim, number, citation marker and
//    figure/table reference survives verbatim.  A model that improves a result
//    is worse than useless in a scientific manuscript.
// 2. **The checks are the specification.** The target's checks are already
//    machine-evaluated by `ChecklistService`; sending them means the model is
//    aiming at the same limits the app will grade it against afterwards,
//    rather than at a paraphrase of them.
//
// See MasterContext/11-ai-integration.md §7.2.

import Foundation

struct FastForwardIntent: AIIntent {

    static let descriptor = AIIntentDescriptor(
        id: "journal.fastForward",
        title: "Fast-forward a journal",
        summary: "Adapts the upstream's content toward the target journal's requirements while copying it down.",
        sends: ["Enabled context rows",
                "The upstream's section text",
                "The target journal's requirements, structure and checks"],
        writes: "The target journal's sections, stamped as a new version",
        reversal: "The previous content is stamped into version history first")

    // MARK: - Errors

    enum FastForwardError: LocalizedError {
        case nothingToAdapt
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .nothingToAdapt:
                return "There are no sections with content to adapt."
            case .unreadable(let detail):
                return "The model's reply couldn't be read: \(detail)"
            }
        }
    }

    // MARK: - Prompt

    /// The sections that will be sent — active and non-empty, in order.
    static func adaptableSections(_ sections: [ManuscriptSection]) -> [ManuscriptSection] {
        sections.filter { $0.active && !$0.isEmptyContent }.sorted { $0.order < $1.order }
    }

    /// Builds the task half of the prompt.  Context is prepended by
    /// `AIRequestService.prompt(context:task:)`, which is the only thing that
    /// reads the checkboxes.
    static func task(sections: [ManuscriptSection], target: Journal) throws -> String {
        let adaptable = adaptableSections(sections)
        guard !adaptable.isEmpty else { throw FastForwardError.nothingToAdapt }

        let payload = adaptable.map {
            ["id": $0.id.uuidString, "title": $0.title, "text": $0.plainText]
        }
        let sectionsJSON = String(
            data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            encoding: .utf8) ?? "[]"

        return """
        Adapt the sections of this manuscript for submission to \
        "\(target.displayName)".

        \(profileText(for: target))

        RULES
        - Preserve every scientific claim, number, statistic, p-value, unit, \
        citation marker and figure/table reference exactly as written. Never \
        add a finding, never remove one, never soften or strengthen a claim.
        - Adapt register, structure, emphasis and LENGTH toward the \
        requirements and limits above. Where a limit applies, come in under it.
        - Keep each section's subject matter; do not move content between \
        sections and do not merge or split them.
        - If a section already suits the target, return it unchanged.

        SECTIONS (JSON array of {id, title, text}):
        \(sectionsJSON)

        Reply with JSON only, in exactly this shape, one entry per input \
        section, with the same ids:
        {"sections": [{"id": "<the same id>", "content": "<the adapted text>"}]}
        """
    }

    /// The target journal as the model needs to see it: what the journal asks
    /// for, the shape it expects, and the limits the app will check.
    static func profileText(for journal: Journal) -> String {
        var lines: [String] = ["TARGET JOURNAL: \(journal.displayName)"]
        if !journal.publisher.isEmpty { lines.append("Publisher: \(journal.publisher)") }
        if let type = journal.articleType, !type.isEmpty {
            lines.append("Article type: \(type)")
        }

        if let source = journal.sourceRequirements, !source.bullets.isEmpty {
            lines.append("\nThe journal's own instructions:")
            lines.append(contentsOf: source.bullets.map { "- \($0)" })
        }

        if let structure = journal.structure, !structure.isEmpty {
            lines.append("\nExpected structure:")
            for section in structure.sections {
                var line = "- \(section.title)\(section.required ? " (required)" : " (optional)")"
                if let note = section.note, !note.isEmpty { line += " — \(note)" }
                lines.append(line)
            }
        }

        // The limits, spelled out: these are exactly what ChecklistService
        // grades the result against afterwards.
        var limits: [String] = []
        let r = journal.requirements
        if let n = r.maxBodyWords      { limits.append("body: at most \(n) words in total") }
        if let n = r.maxAbstractWords  { limits.append("abstract: at most \(n) words") }
        if let n = r.maxFigures        { limits.append("at most \(n) figures") }
        if let n = r.maxTables         { limits.append("at most \(n) tables") }
        if let n = r.maxReferences     { limits.append("at most \(n) references") }
        if !r.customRules.isEmpty      { limits.append(contentsOf: r.customRules) }
        if !limits.isEmpty {
            lines.append("\nLimits:")
            lines.append(contentsOf: limits.map { "- \($0)" })
        }

        let checks = (journal.checkRules ?? []).filter { $0.isEnabled && !$0.isManual }
        if !checks.isEmpty {
            lines.append("\nThe adapted text will be checked automatically against these rules:")
            for check in checks {
                var line = "- \(check.displayName)"
                if let note = check.note, !note.isEmpty { line += " — \(note)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Response

    private struct AdaptedSection: Decodable { let id: String; let content: String }
    private struct AdaptedPayload: Decodable { let sections: [AdaptedSection] }

    /// Reads the reply into section id → adapted text.
    ///
    /// Entries with an unknown id or empty text are dropped rather than
    /// guessed at: writing a section the model didn't actually return would be
    /// the worst possible failure mode here.
    static func adaptedSections(from reply: String,
                                expecting sections: [ManuscriptSection]) throws -> [UUID: String] {
        guard let data = AIRequestService.extractJSONObject(from: reply) else {
            throw FastForwardError.unreadable("no JSON object in the reply")
        }
        guard let payload = try? JSONDecoder().decode(AdaptedPayload.self, from: data) else {
            throw FastForwardError.unreadable("the JSON didn't have the expected shape")
        }
        let known = Set(sections.map(\.id))
        var out: [UUID: String] = [:]
        for entry in payload.sections {
            guard let id = UUID(uuidString: entry.id), known.contains(id) else { continue }
            let text = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out[id] = entry.content }
        }
        guard !out.isEmpty else {
            throw FastForwardError.unreadable("no sections came back that matched the ones sent")
        }
        return out
    }
}
