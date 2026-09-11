// AIRefMarkers.swift
//
// Citations survive a rewrite — and move with the claims they support.
//
// WHAT A CITATION IS HERE
// ─────────────────────────────────────────────────────────────────────────────
// A citation in this app is not a character in the text — it is a `.link`
// attribute on the RTF, carrying `cite://<uuid>`.  The plain-text mirror has
// no trace of it: the first fast-forward sent an Introduction with fourteen
// citations and the model saw none, then wrote the answer back as
// `RichText(plain:)`, which discarded the RTF and every reference with it.
//
// HOW THE MODEL SEES THEM (second design, Sep 2026)
// ─────────────────────────────────────────────────────────────────────────────
// The first design sent each citation RUN as an opaque marker — `[[cite:3]]`
// meant "the third run in this section" — which had to come back verbatim or
// the section was refused.  Safe, and wrong for the work: a model adapting a
// paper merges sentences, moves claims, cuts the ones a limit can't afford —
// and a citation belongs to a CLAIM, not to a position.  A 26B model halving
// a paper dropped citations with the sentences and handed most of it back
// "unchanged".
//
// Now the manuscript's references are a LEGEND — every bibliography entry as
// R1…Rn in the order the list prints, every figure F1…, every table T1… — that
// means the same thing in every section and in the reply.  In the text,
// `[[cite:R3]]` cites entry R3 and `[[cite:R3,R7]]` cites two; `[[fig:F2]]`
// and `[[tab:T1]]` refer to a figure or table; `[[figplace:F2]]` marks where
// one is placed.  The prompt lists the legend (with each reference's text)
// and says how citations are used, and the model does what a co-author does:
// keeps a claim's citations with the claim, moves them when it merges
// sentences, lets them go with a claim it cuts, cites a listed entry where it
// supports a claim.  On the way back every key becomes the link it stands
// for, displayed the way the editor displays it.
//
// What is still refused — a section kept unchanged, with the reason named:
// a key that is not in the legend (an invented reference), a section that
// cited several entries and comes back citing none (the system ignored, not
// a judgement), and a manuscript FIELD (`[[title]]`, `[[authors.names]]`)
// that went missing — those stand for values filled in on export and a title
// page without them is broken.
//
// See MasterContext/features/ai-assist.md §7.2.

import AppKit
import Foundation

enum AIRefMarkers {

    // MARK: - The legend

    /// The manuscript's references, figures and tables as the model sees
    /// them: one key each, the same in every section and in the reply.
    struct Legend {
        struct Item {
            let key: String
            let id: UUID
            let text: String
        }

        let references: [Item]
        let figures: [Item]
        let tables: [Item]
        private let idByKey: [String: UUID]
        private let keyByID: [UUID: String]

        /// R-keys follow the bibliography's order, which the store keeps in
        /// citation order (cited first, by first citation) — so R3 is the
        /// reference printed as [3].  F- and T-keys follow the numbering the
        /// editor shows.
        init(content m: Manuscript, citationStyle: String = "apa") {
            references = m.bibliography.enumerated().map { i, e in
                Item(key: "R\(i + 1)", id: e.id, text: RefEngine.referenceText(e, style: citationStyle))
            }
            let figureNumbers = RefEngine.effectiveFigureNumbers(in: m)
            figures = m.figures
                .map { f in (number: figureNumbers[f.id] ?? f.number, figure: f) }
                .sorted { $0.number < $1.number }
                .map { n, f in
                    Item(key: "F\(n)", id: f.id,
                         text: f.title + (f.caption.isEmpty ? "" : " — \(f.caption)"))
                }
            let tableNumbers = RefEngine.effectiveTableNumbers(in: m)
            tables = m.tables
                .map { t in (number: tableNumbers[t.id] ?? t.number, table: t) }
                .sorted { $0.number < $1.number }
                .map { n, t in Item(key: "T\(n)", id: t.id, text: t.title) }
            var byKey: [String: UUID] = [:]
            var byID: [UUID: String] = [:]
            for item in references + figures + tables {
                byKey[item.key] = item.id
                byID[item.id] = item.key
            }
            idByKey = byKey
            keyByID = byID
        }

        func key(for id: UUID) -> String? { keyByID[id] }
        func id(for key: String) -> UUID? { idByKey[key] }
        var isEmpty: Bool { references.isEmpty && figures.isEmpty && tables.isEmpty }

        /// The legend as it goes into the prompt.
        var promptText: String {
            var lines: [String] = []
            if !references.isEmpty {
                lines.append("REFERENCES — the manuscript's bibliography. The text cites an entry by its key:")
                lines += references.map { "\($0.key). \($0.text)" }
            }
            if !figures.isEmpty {
                lines.append("\nFIGURES — referred to by key:")
                lines += figures.map { "\($0.key). \($0.text)" }
            }
            if !tables.isEmpty {
                lines.append("\nTABLES — referred to by key:")
                lines += tables.map { "\($0.key). \($0.text)" }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// A section prepared for a model: text with every reference as a key,
    /// and what the reply must still contain.
    struct Prepared {
        let text: String
        /// The R-keys the text cites, distinct, in order of first citation.
        let citedKeys: [String]
        /// Manuscript fields (`[[title]]`) in the text — or, with a template,
        /// the template's — which must come back.
        let partTokens: [String]
        let legend: Legend

        var isEmpty: Bool { citedKeys.isEmpty && partTokens.isEmpty }
        /// Every token the reply must still contain.  Citations are not on
        /// this list: they are the model's to place.
        var required: [String] { partTokens }
    }

    // MARK: - Outbound

    /// Replaces every reference run with its key.
    ///
    /// Falls back to the plain mirror when there is no RTF — an unstyled
    /// section cannot carry a reference in the first place.  A link whose
    /// target is not in the legend (a dangling reference) stays as the text
    /// it displayed.
    static func prepare(_ rich: RichText, legend: Legend) -> Prepared {
        let partTokens = partTokenList(in: rich.plain)
        guard let rtf = rich.rtf,
              let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil)
        else {
            return Prepared(text: rich.plain, citedKeys: [], partTokens: partTokens, legend: legend)
        }

        var out = ""
        var cited: [String] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.link, in: full) { value, range, _ in
            let piece = attributed.attributedSubstring(from: range).string
            guard let url = linkURL(value), let token = RefEngine.Token.parse(url) else {
                out += piece
                return
            }
            let keys = token.allIDs.compactMap { legend.key(for: $0) }
            guard keys.count == token.allIDs.count, let first = keys.first else {
                out += piece
                return
            }
            switch token.kind {
            case .bib:
                out += "[[cite:\(keys.joined(separator: ","))]]"
                for key in keys where !cited.contains(key) { cited.append(key) }
            case .figure:          out += "[[fig:\(first)]]"
            case .table:           out += "[[tab:\(first)]]"
            case .figurePlacement: out += "[[figplace:\(first)]]"
            case .tablePlacement:  out += "[[tabplace:\(first)]]"
            }
        }
        return Prepared(text: out, citedKeys: cited, partTokens: partTokens, legend: legend)
    }

    // MARK: - Inbound

    /// What came back, and what to make of it.
    struct Restored {
        let rich: RichText
        /// Fields the reply lost — a title page without `[[title]]`.
        let missing: [String]
        /// Keys the reply used that are not in the legend, or used with the
        /// wrong kind (`[[fig:R3]]`) — an invented reference.
        let unknown: [String]
        let citedBefore: [String]
        let citedAfter: [String]

        /// Several citations in, none out: the system was ignored, which is
        /// not the same as a judgement about one claim.
        var droppedEveryCitation: Bool { citedBefore.count >= 2 && citedAfter.isEmpty }

        /// Why the section is refused, in words — empty when it is accepted.
        var problems: [String] {
            var out: [String] = []
            if !missing.isEmpty { out.append("dropped \(missing.joined(separator: ", "))") }
            if !unknown.isEmpty {
                out.append("cited \(unknown.joined(separator: ", ")), which is not in the reference list")
            }
            if droppedEveryCitation {
                out.append("cited nothing where it cited \(citedBefore.joined(separator: ", ")) before")
            }
            return out
        }
        var isAccepted: Bool { problems.isEmpty }
    }

    private static let markerPattern = try! NSRegularExpression(
        pattern: "\\[\\[(cite|fig|tab|figplace|tabplace):([A-Za-z0-9,\\s]+)\\]\\]|\\[\\[([A-Za-z0-9_.]+)\\]\\]")

    /// Rebuilds rich text from the model's reply: every key becomes the link
    /// it stands for, every field token comes back live.
    ///
    /// Prose styling is deliberately not carried over: the adapted text is
    /// new text, and the app's editing typography is applied everywhere
    /// anyway.  What must survive is *identity* — the link — and the
    /// citation's own styling (a superscripted citation is a smaller font
    /// plus a baseline offset; without it every reference sat flat in the
    /// line).  With a `context` the display text is computed as the editor
    /// shows it; without one it is a placeholder the editor rewrites on load.
    static func restore(_ text: String, from prepared: Prepared,
                        context: RefEngine.Context? = nil) -> Restored {
        let result = NSMutableAttributedString()
        let ns = text as NSString
        var seenFields = Set<String>()
        var unknown: [String] = []
        var citedAfter: [String] = []
        var last = 0

        for match in markerPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result.append(NSAttributedString(
                string: ns.substring(with: NSRange(location: last, length: match.range.location - last))))
            let whole = ns.substring(with: match.range)
            if match.range(at: 1).location != NSNotFound {
                let kind = ns.substring(with: match.range(at: 1))
                let keys = ns.substring(with: match.range(at: 2))
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let prefix = kind == "cite" ? "R" : (kind.hasPrefix("fig") ? "F" : "T")
                let ids = keys.compactMap { key -> UUID? in
                    key.hasPrefix(prefix) ? prepared.legend.id(for: key) : nil
                }
                if !ids.isEmpty, ids.count == keys.count, (kind == "cite" || ids.count == 1),
                   let run = referenceRun(kind: kind, ids: ids, keys: keys, context: context) {
                    result.append(run)
                    if kind == "cite" {
                        for key in keys where !citedAfter.contains(key) { citedAfter.append(key) }
                    }
                } else {
                    // Kept as text so nothing is lost, and named as a problem
                    // so the section is not written this way.
                    unknown.append(whole)
                    result.append(NSAttributedString(string: whole))
                }
            } else {
                // A field: `[[title]]` comes back live, or stays as typed if
                // it is nothing the catalog knows.
                result.append(PartEngine.tokenized(whole, attributes: [:]))
                seenFields.insert(whole)
            }
            last = match.range.location + match.range.length
        }
        result.append(NSAttributedString(string: ns.substring(from: last)))

        let full = NSRange(location: 0, length: result.length)
        let rtf = result.rtf(from: full, documentAttributes: [:])
        let rich = RichText(plain: result.string, rtf: rtf, refs: RefEngine.scanRefs(in: result))
        var missing: [String] = []
        for token in prepared.partTokens where !seenFields.contains(token) && !missing.contains(token) {
            missing.append(token)
        }
        return Restored(rich: rich, missing: missing, unknown: unknown,
                        citedBefore: prepared.citedKeys, citedAfter: citedAfter)
    }

    /// One reference, rendered the way the editor renders it.
    private static func referenceRun(kind: String, ids: [UUID], keys: [String],
                                     context: RefEngine.Context?) -> NSAttributedString? {
        let token: RefEngine.Token
        switch kind {
        case "cite":
            token = RefEngine.Token(kind: .bib, targetID: ids[0],
                                    style: context?.defaultStyle ?? .numeric,
                                    extraIDs: Array(ids.dropFirst()))
        case "fig":      token = RefEngine.Token(kind: .figure, targetID: ids[0], style: .numeric)
        case "tab":      token = RefEngine.Token(kind: .table, targetID: ids[0], style: .numeric)
        case "figplace": token = RefEngine.Token(kind: .figurePlacement, targetID: ids[0], style: .numeric)
        case "tabplace": token = RefEngine.Token(kind: .tablePlacement, targetID: ids[0], style: .numeric)
        default:         return nil
        }
        guard let url = token.url else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [.link: url]
        guard let context else {
            // No context: a placeholder the editor rewrites against current
            // numbering when the section is opened.
            return NSAttributedString(string: "[\(keys.joined(separator: ","))]", attributes: attributes)
        }
        if let tip = RefEngine.tooltip(for: token, context: context) { attributes[.toolTip] = tip }
        CitationTextView.applyCitationRaise(
            &attributes,
            raised: RefEngine.isSuperscripted(token, context: context),
            // The raise is proportional to the body size, and the editing
            // typography is global, so the user's configured size is the
            // right base even though the family is applied by the editor.
            baseFont: NSFont.systemFont(ofSize: EditorTypography.current.size))
        let text = RefEngine.displayText(for: token, context: context)
        return NSAttributedString(string: text.isEmpty ? "[\(keys.joined(separator: ","))]" : text,
                                  attributes: attributes)
    }

    // MARK: - Helpers

    /// The field tokens living in a text (`[[title]]`), which the model must
    /// return untouched.  Reference keys carry a colon; fields never do.
    static func partTokenList(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[["),
              let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            let token = String(rest[open.lowerBound..<close.upperBound])
            if !token.contains(":") { out.append(token) }
            rest = rest[close.upperBound...]
        }
        return out
    }

    /// `.link` values arrive as either `URL` or `String` depending on how the
    /// RTF was written.
    private static func linkURL(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}
