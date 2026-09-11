// FastForwardIntent.swift
//
// AI INTENT  journal.fastForward
//   Sends:   enabled context rows · the manuscript's references, figures and
//            tables as a keyed legend · the sections as the copy would bring
//            them down (the upstream's text where it has some, the cut's own
//            — its boilerplate — where it hasn't), citing by key · the
//            target journal's profile · **the target's checks, evaluated,
//            with their current numbers**
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
// 1. **Never invent a result; cite like a co-author.** Every claim, number
//    and statistic survives verbatim — a model that improves a result is worse
//    than useless in a scientific manuscript.  Citations are handled by
//    understanding, not by copying: the model sees the reference list and
//    keeps each claim's citations with the claim, moving them when it merges
//    sentences and letting them go with a claim it cuts (see AIRefMarkers).
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
                "The manuscript's references, figures and tables, keyed (R1…, F1…, T1…) with each reference's text",
                "The sections a fast-forward would copy — the upstream's text, the cut's own where the upstream is empty — citing by key",
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

    /// The abstract's id in the payload — it is a field of the manuscript,
    /// not a section, but it is a cut's prose like any section: a structured
    /// abstract at one venue is a paragraph at another, and a fast-forward
    /// that left it out could never satisfy the abstract checks it was sent.
    static let abstractID = UUID(uuidString: "AB57AC70-0000-4000-8000-000000000001")!

    /// The abstract as a section, so it travels and returns like one.
    static func abstractSection(_ content: Manuscript) -> ManuscriptSection {
        ManuscriptSection(id: abstractID, type: .custom, title: "Abstract",
                          content: content.abstract, order: -1, active: true)
    }

    /// Everything that goes out for a manuscript: the abstract first, then
    /// its active sections — all citing by the same legend.
    static func payloads(for content: Manuscript, target: Journal? = nil) -> [Payload] {
        let legend = AIRefMarkers.Legend(
            content: content, citationStyle: target?.requirements.citationStyle.cslID ?? "apa")
        return payloads([abstractSection(content)], target: target, legend: legend)
            + payloads(content.sections, target: target, legend: legend)
    }

    /// One section as it goes out, and everything needed to put it back.
    struct Payload {
        let section: ManuscriptSection
        /// Prose sections: the marked text.
        let prepared: AIRefMarkers.Prepared?
        /// Question series: each question, prepared separately.
        let questions: [(question: QuestionEntry, prepared: AIRefMarkers.Prepared)]
        /// What the target venue says this section is — its boilerplate,
        /// format and notes — when its structure has an entry for it.
        let template: StructureSection?
        /// The section's text IS the venue's boilerplate, nothing of the
        /// author's: it goes out as an empty section with a template, so
        /// the model writes it rather than echoing the placeholder.
        let holdsTemplate: Bool
    }

    /// The sections that will be sent.
    ///
    /// Active sections, **including empty ones** — an empty required section is
    /// exactly the case that needs writing, and skipping it was why submission
    /// questions came back untouched.
    ///
    /// With a `target`, each section is paired with the venue's entry for it
    /// (by title).  The entry's boilerplate is a **specification**, not text:
    /// the model writes the section to it, and every `[[…]]` token it uses is
    /// required in the answer just as one already in the text would be.
    static func payloads(_ sections: [ManuscriptSection], target: Journal? = nil,
                         legend: AIRefMarkers.Legend? = nil) -> [Payload] {
        let legend = legend ?? AIRefMarkers.Legend(content: Manuscript.new())
        let entries = Dictionary((target?.structure?.journalEntries ?? []).map { ($0.key, $0) },
                                 uniquingKeysWith: { first, _ in first })
        // Journal content only: core content is the author's, never adapted.
        return sections.filter { $0.active && $0.isJournalContent }
            .sorted { $0.order < $1.order }.map { section in
            let entry = entries[section.title.lowercased()]
            let sample = entry?.sample?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch section.sectionKind {
            case .text, .letter:
                var prepared = AIRefMarkers.prepare(section.content, legend: legend)
                let holds = !sample.isEmpty
                    && section.content.plain.trimmingCharacters(in: .whitespacesAndNewlines) == sample
                if !sample.isEmpty {
                    // Written to the template, the section keeps the
                    // template's field tokens — not the old text's, which
                    // the template supersedes.  (A title page whose old text
                    // said `[[authors]]` was refused for dropping it, when
                    // the template had replaced it with `[[authors.names]]`.)
                    prepared = AIRefMarkers.Prepared(text: prepared.text, citedKeys: prepared.citedKeys,
                                                     partTokens: AIRefMarkers.partTokenList(in: sample),
                                                     legend: legend)
                }
                return Payload(section: section, prepared: prepared, questions: [],
                               template: entry, holdsTemplate: holds)
            case .questions:
                return Payload(section: section, prepared: nil,
                               questions: section.orderedQuestions.map {
                                   ($0, AIRefMarkers.prepare($0.response, legend: legend))
                               },
                               template: entry, holdsTemplate: false)
            }
        }
    }

    // MARK: - Prompt

    /// Builds the task half of the prompt.  Context is prepended by
    /// `AIRequestService.prompt(context:task:)`, which is the only thing that
    /// reads the checkboxes.
    static func task(content: Manuscript, target: Journal) throws -> String {
        let payloads = payloads(for: content, target: target)
        guard payloads.count > 1 else { throw FastForwardError.nothingToAdapt }

        var sectionJSON: [[String: Any]] = []
        for payload in payloads {
            var entry: [String: Any] = [
                "id": payload.section.id.uuidString,
                "title": payload.section.title,
            ]
            // The venue's specification for this section travels WITH the
            // section, not only in the profile above: what it must look
            // like, how it must be written, and why it is asked for.
            if let template = payload.template {
                if let sample = template.sample, !sample.isEmpty { entry["template"] = sample }
                if let format = template.formatNote, !format.isEmpty { entry["format"] = format }
                if let note = template.note, !note.isEmpty { entry["notes"] = note }
            }
            switch payload.section.sectionKind {
            case .text, .letter:
                entry["kind"] = "prose"
                entry["words"] = payload.holdsTemplate ? 0 : payload.section.wordCount
                entry["text"] = payload.holdsTemplate ? "" : (payload.prepared?.text ?? "")
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

        let legend = payloads.first?.prepared?.legend
            ?? payloads.first?.questions.first?.prepared.legend
        let legendText = legend.map { $0.isEmpty ? "" : $0.promptText } ?? ""

        return """
        Adapt this manuscript for submission to "\(target.displayName)".

        \(profileText(for: target))

        \(checkText(content: content, target: target))

        \(legendText)

        RULES — in order of importance

        1. CITATIONS ARE PART OF THE ARGUMENT — USE THEM AS A CO-AUTHOR WOULD. \
        The manuscript's references are listed above by key. In the text, \
        `[[cite:R3]]` cites reference R3 and `[[cite:R3,R7]]` cites two at once; \
        `[[fig:F2]]` and `[[tab:T1]]` refer to a figure or a table, and \
        `[[figplace:F2]]` marks where one is placed. Write them exactly in that \
        form, in the running text where the citation belongs. A claim keeps \
        the citations that support it. When you merge or move sentences, \
        their citations move with the claim. When you cut a claim, its \
        citations go with it — and a reference no longer cited anywhere leaves \
        the reference list, which is how a reference limit is met: cut the \
        claims that need the extra references, never the citations alone. \
        Where a listed reference supports a claim better than what is there, \
        or a claim you keep has lost its support, cite it. Cite only \
        references in the list above — never invent one, never write a \
        citation as words or as a bare number, never change a key. A figure \
        or table that stays in the paper keeps its references.

        2. MANUSCRIPT FIELDS ARE NOT TEXT. `[[title]]`, `[[authors.names]]`, \
        `[[authors.institutes]]` and any other `[[…]]` without a colon stand \
        for values filled in on export. Reproduce each exactly as written, \
        where it belongs — never as words: `[[authors.names]]` comes back as \
        `[[authors.names]]`, not as a list of names. A section that comes back \
        without a field it had, or citing a key that is not in the list, is \
        rejected whole and the old text kept.

        3. PRESERVE THE SCIENCE. Every claim, number, statistic, p-value, \
        confidence interval, unit, sample size and date exactly as given. Never \
        add a finding, never remove one, never soften or strengthen a claim, \
        never introduce a fact that is not already in the material you were sent.

        4. MEET THE CHECKS ABOVE. Every check listed as FAILING must pass after \
        your rewrite; every check listed as passing must still pass. Where a \
        length limit is failing, cut — tighten sentences, remove redundancy, \
        drop background that the target's readers already have — rather than \
        deleting findings. Respect the per-section budgets where they are given.

        5. A "template" IS THE VENUE'S BOILERPLATE FOR THAT SECTION. Follow its \
        format: reuse its layout, its headings, its statements and its \
        `[[…]]` tokens as they stand, and fill in where it calls for the \
        manuscript's own content — its "format" says how it must be written \
        and its "notes" say why it is asked for. Return the whole section in \
        that format, with the manuscript's material in place of the \
        boilerplate's placeholders and nothing of the placeholder wording \
        left. A section whose "text" is empty and that has a template is \
        written from the template alone.

        6. WRITE THE EMPTY ONES. A section or question that arrives empty still \
        has to be answered, from the manuscript's own content, within its word \
        limit. Do not leave it blank and do not answer with a placeholder.

        7. ADAPT, DON'T RESTRUCTURE. Keep each section's subject matter; do not \
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

    /// A second, smaller request: only the sections the first reply lost
    /// tokens from, each with the exact list it dropped.
    ///
    /// A section that came back without a citation is refused and the old
    /// text kept, which is right — and it is also how a 26B model cutting a
    /// paper by half handed back most of it "unchanged".  Naming the dropped
    /// tokens and asking again is cheap (one more request, free on a local
    /// model) and turns most refusals into landed sections.
    static func repairTask(payloads: [Payload], problems: [UUID: [String]],
                           target: Journal) throws -> String {
        guard !payloads.isEmpty else { throw FastForwardError.nothingToAdapt }
        var sectionJSON: [[String: Any]] = []
        for payload in payloads {
            var entry: [String: Any] = [
                "id": payload.section.id.uuidString,
                "title": payload.section.title,
                "problems": problems[payload.section.id] ?? [],
            ]
            if let template = payload.template {
                if let sample = template.sample, !sample.isEmpty { entry["template"] = sample }
                if let format = template.formatNote, !format.isEmpty { entry["format"] = format }
                if let note = template.note, !note.isEmpty { entry["notes"] = note }
            }
            switch payload.section.sectionKind {
            case .text, .letter:
                entry["kind"] = "prose"
                entry["text"] = payload.holdsTemplate ? "" : (payload.prepared?.text ?? "")
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

        let legend = payloads.first?.prepared?.legend
            ?? payloads.first?.questions.first?.prepared.legend
        let legendText = legend.map { $0.isEmpty ? "" : $0.promptText } ?? ""

        return """
        You were adapting this manuscript for submission to "\(target.displayName)". \
        Your answer for the sections below was REJECTED — each one's "problems" \
        says why. Nothing from that answer was used.

        \(profileText(for: target))

        \(legendText)

        Adapt these sections again, toward the same target and the same limits, \
        without those problems. Citations are written as `[[cite:R3]]` (or \
        `[[cite:R3,R7]]`), figure and table references as `[[fig:F2]]` and \
        `[[tab:T1]]`, using only keys from the list above; a claim keeps the \
        citations that support it, and a claim you cut takes its citations \
        with it — but a section that keeps its claims keeps their citations. \
        A `[[title]]` or `[[authors.names]]` stands for a manuscript field and \
        stays exactly as written, where the template puts it. Preserve every \
        claim, number and statistic; add nothing.

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
                if let note = section.note, !note.isEmpty {
                    lines.append("    Notes: \(note)")
                }
                if let format = section.formatNote, !format.isEmpty {
                    lines.append("    Format: \(format)")
                }
                // The boilerplate itself travels with the section it is for
                // (see `task`), where the model reads it as that section's
                // specification rather than as journal trivia.
                if let sample = section.sample, !sample.isEmpty {
                    lines.append("    Has a template (sent with the section).")
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
        /// Why a section was refused, per section title.
        var problems: [String: [String]] = [:]
        /// The same, by section id — what a repair round is built from.
        var problemsByID: [UUID: [String]] = [:]
        /// What each accepted prose section cited before and after, by key —
        /// for the log, so a run's citation changes are visible.
        var citations: [UUID: (before: [String], after: [String])] = [:]
        /// Sections REFUSED: a field dropped, a reference invented, or every
        /// citation gone from a section that had several.
        ///
        /// Refused, not written-with-a-warning: a section that lost its
        /// references is worse than a section that wasn't adapted.  The
        /// upstream text stays and the log names the problem — the title page
        /// came back once with `[[authors.names]]` replaced by an invented
        /// author list, and that must not be able to land.
        var refused: [String] = []

        var isEmpty: Bool { sections.isEmpty && answers.isEmpty }
        var sectionCount: Int { sections.count + answers.count }

        /// Takes a repair round's accepted sections: each one replaces its
        /// refusal.  What the repair still lost stays refused.
        mutating func merge(_ repair: Adaptation, sent: [Payload]) {
            let byID = Dictionary(uniqueKeysWithValues: sent.map { ($0.section.id, $0) })
            for (id, rich) in repair.sections {
                sections[id] = rich
                citations[id] = repair.citations[id]
                accepted(id, byID: byID)
            }
            for (id, answersFor) in repair.answers {
                answers[id, default: [:]].merge(answersFor) { _, new in new }
                accepted(id, byID: byID)
            }
        }

        private mutating func accepted(_ id: UUID, byID: [UUID: Payload]) {
            problemsByID[id] = nil
            guard let title = byID[id]?.section.title else { return }
            problems[title] = nil
            refused.removeAll { $0 == title || $0.hasPrefix(title + " — ") }
        }
    }

    /// Reads the reply and rebuilds rich text, turning every key back into
    /// the link it stands for.
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
                if restored.isAccepted {
                    out.sections[id] = restored.rich
                    out.citations[id] = (restored.citedBefore, restored.citedAfter)
                } else {
                    out.problems[sent.section.title, default: []] += restored.problems
                    out.problemsByID[id, default: []] += restored.problems
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
                if restored.isAccepted {
                    out.answers[id, default: [:]][questionID] = restored.rich
                } else {
                    out.problems[sent.section.title, default: []] += restored.problems
                    out.problemsByID[id, default: []] += restored.problems
                    out.refused.append("\(sent.section.title) — \(item.question.prompt.prefix(40))")
                }
            }
        }

        // A reply whose every section was refused is still a result — the
        // refusals are what a repair round is built from.  Only a reply that
        // matched nothing at all is unreadable.
        guard !out.isEmpty || !out.refused.isEmpty else {
            throw FastForwardError.unreadable("no sections came back that matched the ones sent")
        }
        return out
    }
}
