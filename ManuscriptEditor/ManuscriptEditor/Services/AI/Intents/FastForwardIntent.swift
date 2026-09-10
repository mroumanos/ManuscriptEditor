// FastForwardIntent.swift
//
// AI INTENT  journal.fastForward
//   Sends:   enabled context rows · the upstream's sections, with every
//            citation and part token marked · the target journal's profile ·
//            **the target's checks, evaluated, with their current numbers**
//   Writes:  the downstream cut's sections and submission answers, as a new
//            stamped version
//   Reverts: the overridden content is stamped into version history first,
//            so the previous state is a version, not a lost edit
//
// A fast-forward already exists as a mechanical copy: the upstream's latest
// content replaces the downstream cut's, verbatim.  With Assist on, the same
// button asks the model to ADAPT each section toward the target journal on the
// way down — which is the work a researcher actually does by hand between two
// venues, and the reason cuts exist at all.
//
// THREE RULES THIS PROMPT IS BUILT AROUND
// ─────────────────────────────────────────────────────────────────────────────
// 1. **Never invent, never drop.** Every claim, number, citation marker and
//    figure/table reference survives verbatim.  A model that improves a result
//    is worse than useless in a scientific manuscript.
//
// 2. **The checks are the specification, with their numbers.**  The first
//    version sent the checks as names ("Body ≤ 1200 words") and got back prose
//    that ignored them.  A rule is only actionable with its measurement, so
//    every check is evaluated against the content being adapted and sent as
//    *failing, 2,360 of 1,200 words* — and where a limit spans several sections
//    the prompt hands over an explicit per-section budget, because "make these
//    six sections total under 1,200 words" is arithmetic, not judgement.
//
// 3. **Required sections get written, not skipped.**  A section that is empty
//    upstream but required by the target — submission questions, most often —
//    is sent with its questions and their word limits and must come back
//    answered from the manuscript's own content.
//
// See MasterContext/features/ai-assist.md §7.2.

import Foundation

struct FastForwardIntent: AIIntent {

    static let descriptor = AIIntentDescriptor(
        id: "journal.fastForward",
        title: "Fast-forward a journal",
        summary: "Adapts the upstream's content toward the target journal's requirements, limits and checks while copying it down.",
        sends: ["Enabled context rows",
                "The upstream's sections, with citations and part tokens marked",
                "The target journal's requirements, structure and checks",
                "Each check's current measurement against the content being adapted"],
        writes: "The target journal's sections and submission answers, stamped as a new version",
        reversal: "The previous content is stamped into version history first")

    // MARK: - Errors

    enum FastForwardError: LocalizedError {
        case nothingToAdapt
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .nothingToAdapt:
                return "There are no sections to adapt."
            case .unreadable(let detail):
                return "The model's reply couldn't be read: \(detail)"
            }
        }
    }

    // MARK: - What gets sent

    /// One section as it goes out, and everything needed to put it back.
    struct Payload {
        let section: ManuscriptSection
        /// Prose sections: the marked text.
        let prepared: AIRefMarkers.Prepared?
        /// Question series: each question, prepared separately.
        let questions: [(question: QuestionEntry, prepared: AIRefMarkers.Prepared)]
    }

    /// The sections that will be sent.
    ///
    /// Active sections, **including empty ones** — an empty required section is
    /// exactly the case that needs writing, and skipping it was why submission
    /// questions came back untouched.
    static func payloads(_ sections: [ManuscriptSection]) -> [Payload] {
        sections.filter(\.active).sorted { $0.order < $1.order }.map { section in
            switch section.sectionKind {
            case .text:
                return Payload(section: section,
                               prepared: AIRefMarkers.prepare(section.content),
                               questions: [])
            case .questions:
                return Payload(section: section, prepared: nil,
                               questions: section.orderedQuestions.map {
                                   ($0, AIRefMarkers.prepare($0.response))
                               })
            }
        }
    }

    // MARK: - Prompt

    /// Builds the task half of the prompt.  Context is prepended by
    /// `AIRequestService.prompt(context:task:)`, which is the only thing that
    /// reads the checkboxes.
    static func task(content: Manuscript, target: Journal) throws -> String {
        let payloads = payloads(content.sections)
        guard !payloads.isEmpty else { throw FastForwardError.nothingToAdapt }

        var sectionJSON: [[String: Any]] = []
        for payload in payloads {
            var entry: [String: Any] = [
                "id": payload.section.id.uuidString,
                "title": payload.section.title,
            ]
            switch payload.section.sectionKind {
            case .text:
                entry["kind"] = "prose"
                entry["words"] = payload.section.wordCount
                entry["text"] = payload.prepared?.text ?? ""
            case .questions:
                entry["kind"] = "questions"
                entry["questions"] = payload.questions.map { item -> [String: Any] in
                    var q: [String: Any] = [
                        "id": item.question.id.uuidString,
                        "prompt": item.question.prompt,
                        "answer": item.prepared.text,
                    ]
                    if let limit = item.question.wordLimit { q["wordLimit"] = limit }
                    return q
                }
            }
            sectionJSON.append(entry)
        }
        let sectionsText = String(
            data: try JSONSerialization.data(withJSONObject: sectionJSON, options: [.sortedKeys]),
            encoding: .utf8) ?? "[]"

        return """
        Adapt this manuscript for submission to "\(target.displayName)".

        \(profileText(for: target))

        \(checkText(content: content, target: target))

        RULES — in order of importance

        1. TOKENS IN DOUBLE BRACKETS ARE NOT TEXT. `[[cite:3]]`, `[[figref:1]]`, \
        `[[tabref:2]]`, `[[title]]`, `[[authors.names]]` and any other `[[…]]` \
        stand for citations, figures, tables and manuscript fields. Reproduce \
        every one of them exactly as written, in the same place in the argument. \
        Never delete one, never renumber one, never invent a new one, and never \
        replace one with words of your own — `[[authors.names]]` must come back \
        as `[[authors.names]]`, not as a list of names. A dropped token is a \
        lost citation.

        2. PRESERVE THE SCIENCE. Every claim, number, statistic, p-value, \
        confidence interval, unit, sample size and date exactly as given. Never \
        add a finding, never remove one, never soften or strengthen a claim, \
        never introduce a fact that is not already in the material you were sent.

        3. MEET THE CHECKS ABOVE. Every check listed as FAILING must pass after \
        your rewrite; every check listed as passing must still pass. Where a \
        length limit is failing, cut — tighten sentences, remove redundancy, \
        drop background that the target's readers already have — rather than \
        deleting findings. Respect the per-section budgets where they are given.

        4. WRITE THE EMPTY ONES. A section or question that arrives empty still \
        has to be answered, from the manuscript's own content, within its word \
        limit. Do not leave it blank and do not answer with a placeholder.

        5. ADAPT, DON'T RESTRUCTURE. Keep each section's subject matter; do not \
        move content between sections, merge them or split them.

        SECTIONS (JSON):
        \(sectionsText)

        Reply with JSON only, in exactly this shape — one entry per section, \
        with the same ids. Prose sections use "content"; question sections use \
        "answers", one entry per question id:

        {"sections": [
          {"id": "<section id>", "content": "<the adapted text>"},
          {"id": "<section id>", "answers": [{"id": "<question id>", "content": "<the answer>"}]}
        ]}
        """
    }

    /// The target journal as the model needs to see it.
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
            lines.append("\nWhat a submission here contains:")
            for section in structure.sections {
                lines.append("- \(section.title)\(section.required ? " (required)" : " (optional)")")
                // The venue's own guidance, in the order it is written down:
                // how the section must be written, then why it is asked for.
                if let format = section.formatNote, !format.isEmpty {
                    lines.append("    Format: \(format)")
                }
                if let note = section.note, !note.isEmpty {
                    lines.append("    Notes: \(note)")
                }
                if let sample = section.sample, !sample.isEmpty {
                    lines.append("    This journal's required layout for it:")
                    lines.append(sample.split(separator: "\n")
                        .map { "      \($0)" }.joined(separator: "\n"))
                }
                for q in section.questions ?? [] {
                    let limit = q.wordLimit.map { " (\($0) \((q.limitUnit ?? .words).label))" } ?? ""
                    lines.append("    Asks: \(q.prompt)\(limit)")
                }
            }
        }

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
        return lines.joined(separator: "\n")
    }

    // MARK: - The checks, with their numbers

    /// Every automatic check, evaluated against the content being adapted.
    ///
    /// This is the part that makes limits actionable.  "Body ≤ 1200 words" is a
    /// rule; "FAILING — 2,360 of 1,200 words used, cut 1,160" is an
    /// instruction, and where the limit spans sections the budget is worked out
    /// here rather than left to the model's arithmetic.
    static func checkText(content: Manuscript, target: Journal) -> String {
        let results = ChecklistService.run(manuscript: content, journal: target)
            .filter { !$0.manual }
        guard !results.isEmpty else { return "" }

        var lines = ["CHECKS — these are evaluated automatically after you answer:"]
        for result in results {
            lines.append("- \(result.passed ? "passing" : "FAILING") · \(result.rule) · \(result.details)")
        }

        let budgets = wordBudgets(content: content, target: target)
        if !budgets.isEmpty {
            lines.append("\nWORD BUDGET — the length limits above, divided across the sections they cover, keeping each section's share of the current text:")
            lines.append(contentsOf: budgets.map { "- \($0.title): about \($0.budget) words (currently \($0.current))" })
        }
        return lines.joined(separator: "\n")
    }

    /// Splits each failing length limit across the sections it measures.
    ///
    /// Proportional to what each section currently contributes, so a limit that
    /// covers six sections doesn't turn into six guesses — and the arithmetic
    /// the model would otherwise have to do in its head is done here, where it
    /// can be checked.
    static func wordBudgets(content: Manuscript,
                            target: Journal) -> [(title: String, current: Int, budget: Int)] {
        var out: [(String, Int, Int)] = []
        var claimed = Set<UUID>()

        for rule in (target.checkRules ?? []) where rule.isEnabled && !rule.isManual {
            for condition in rule.conditions
            where condition.metric == .words && condition.comparator == .atMost {
                let covered = sections(for: condition, in: content)
                    .filter { !claimed.contains($0.id) }
                guard covered.count > 1 else { continue }
                let total = covered.reduce(0) { $0 + $1.wordCount }
                let limit = Int(condition.number)
                guard total > limit, total > 0 else { continue }
                for section in covered {
                    claimed.insert(section.id)
                    let share = Double(section.wordCount) / Double(total)
                    out.append((section.title, section.wordCount,
                                max(25, Int((Double(limit) * share).rounded()))))
                }
            }
        }
        return out
    }

    /// The body sections a condition measures.
    private static func sections(for condition: CheckCondition,
                                 in content: Manuscript) -> [ManuscriptSection] {
        var out: [ManuscriptSection] = []
        for scope in condition.scopes {
            switch scope.kind {
            case .body:
                out.append(contentsOf: content.sections.filter(\.active))
            case .section:
                let name = (scope.name ?? "").lowercased()
                out.append(contentsOf: content.sections.filter {
                    $0.active && $0.title.lowercased() == name
                })
            default:
                continue
            }
        }
        var seen = Set<UUID>()
        return out.filter { seen.insert($0.id).inserted }.sorted { $0.order < $1.order }
    }

    // MARK: - Response

    private struct AdaptedAnswer: Decodable { let id: String; let content: String }
    private struct AdaptedSection: Decodable {
        let id: String
        let content: String?
        let answers: [AdaptedAnswer]?
    }
    private struct AdaptedPayload: Decodable { let sections: [AdaptedSection] }

    /// What the model returned, ready to write.
    struct Adaptation {
        /// Prose sections: section id → rebuilt rich text.
        var sections: [UUID: RichText] = [:]
        /// Question series: section id → (question id → rebuilt answer).
        var answers: [UUID: [UUID: RichText]] = [:]
        /// Markers the model failed to return, per section title.
        var missingTokens: [String: [String]] = [:]
        /// Sections REFUSED because the reply dropped a citation or a field.
        ///
        /// Refused, not written-with-a-warning: a section that lost a
        /// reference is worse than a section that wasn't adapted.  The
        /// upstream text stays and the log names what was dropped — the title
        /// page came back once with `[[authors.names]]` replaced by an
        /// invented author list, and that must not be able to land.
        var refused: [String] = []

        var isEmpty: Bool { sections.isEmpty && answers.isEmpty }
        var sectionCount: Int { sections.count + answers.count }
    }

    /// Reads the reply and rebuilds rich text, restoring every marked
    /// reference to the link it stood for.
    ///
    /// Entries with an unknown id or empty text are dropped rather than
    /// guessed at: writing a section the model didn't actually return would be
    /// the worst possible failure mode here.
    /// - Parameter context: the manuscript's reference context, so a restored
    ///   citation comes back numbered and styled the way the editor draws it.
    static func adaptation(from reply: String, sent: [Payload],
                           context: RefEngine.Context? = nil) throws -> Adaptation {
        guard let data = AIRequestService.extractJSONObject(from: reply) else {
            throw FastForwardError.unreadable("no JSON object in the reply")
        }
        guard let payload = try? JSONDecoder().decode(AdaptedPayload.self, from: data) else {
            throw FastForwardError.unreadable("the JSON didn't have the expected shape")
        }

        let bySection = Dictionary(uniqueKeysWithValues: sent.map { ($0.section.id, $0) })
        var out = Adaptation()

        for entry in payload.sections {
            guard let id = UUID(uuidString: entry.id), let sent = bySection[id] else { continue }

            if let text = entry.content,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let prepared = sent.prepared {
                let restored = AIRefMarkers.restore(text, from: prepared, context: context)
                if restored.missing.isEmpty {
                    out.sections[id] = restored.rich
                } else {
                    out.missingTokens[sent.section.title, default: []] += restored.missing
                    out.refused.append(sent.section.title)
                }
            }

            for answer in entry.answers ?? [] {
                guard let questionID = UUID(uuidString: answer.id),
                      let item = sent.questions.first(where: { $0.question.id == questionID }),
                      !answer.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                let restored = AIRefMarkers.restore(answer.content, from: item.prepared,
                                                    context: context)
                if restored.missing.isEmpty {
                    out.answers[id, default: [:]][questionID] = restored.rich
                } else {
                    out.missingTokens[sent.section.title, default: []] += restored.missing
                    out.refused.append("\(sent.section.title) — \(item.question.prompt.prefix(40))")
                }
            }
        }

        guard !out.isEmpty else {
            if !out.refused.isEmpty {
                throw FastForwardError.unreadable(
                    "every section came back with a citation or field missing (\(out.refused.joined(separator: ", ")))")
            }
            throw FastForwardError.unreadable("no sections came back that matched the ones sent")
        }
        return out
    }
}
