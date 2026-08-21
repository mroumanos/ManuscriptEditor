// RefEngine.swift
//
// The single home for in-text references: citations of bibliography entries
// and cross-references to figures/tables.
//
// TOKEN MODEL
// ─────────────────────────────────────────────────────────────────────────────
// A reference lives in the styled text as a run of characters carrying a
// `.link` attribute with one of our private URL schemes:
//
//     cite://<entry-uuid>?f=<style-code>     bibliography citation
//     figref://<figure-uuid>                 figure cross-reference
//     tabref://<table-uuid>                  table cross-reference
//
// The URL is the token's *identity* (it survives the RTF round-trip); the
// visible characters are just its current *rendering* and are rewritten
// whenever numbering or entry details change.  Legacy `{Key}` tokens carry a
// bare cite:// URL and are upgraded to the default style on the same pass.
//
// CITATION STYLES
// ─────────────────────────────────────────────────────────────────────────────
// The common academic in-text conventions, selectable per token:
//   [1]                      numeric, bracketed        (IEEE / Vancouver)
//   (1)                      numeric, parenthesized    (Vancouver variant)
//   ¹                        superscript numeric       (AMA / Nature / NEJM)
//   (Smith et al., 2024)     author–year parenthetical (APA / Harvard / Chicago)
//   Smith et al. (2024)      narrative author–year     (APA narrative)
//
// NUMBERING & ORDER
// ─────────────────────────────────────────────────────────────────────────────
// Numbers are assigned by first appearance in document order (abstract →
// active body sections → letter to editor); re-citing an entry reuses its
// number.  The bibliography array is kept in the same order automatically
// (cited entries first, uncited after in their manual order).  All of this is
// computed from `RichText.refs` — the ordered token list each editor extracts
// on change — so no step here ever decodes RTF on a hot path.

import AppKit

enum RefEngine {

    // MARK: - Citation styles

    /// An in-text citation rendering convention.  Raw value is the `f=` code
    /// persisted in the token URL — keep codes stable across releases.
    enum CitationStyle: String, CaseIterable {
        case numeric        = "n"    // [1]
        case parenthetical  = "p"    // (1)
        case superscripted  = "s"    // ¹
        case authorYear     = "ay"   // (Smith et al., 2024)
        case narrative      = "na"   // Smith et al. (2024)

        /// Menu label with a live example, e.g. "Numeric — [3]".
        func menuLabel(number: Int, info: BibInfo?) -> String {
            let example = CitationStyle.bibText(self, info: info, number: number)
            switch self {
            case .numeric:       return "Numeric — \(example)"
            case .parenthetical: return "Parenthesized — \(example)"
            case .superscripted: return "Superscript — \(example)"
            case .authorYear:    return "Author–Year — \(example)"
            case .narrative:     return "Narrative — \(example)"
            }
        }

        /// Rendered token text for a bibliography citation.
        static func bibText(_ style: CitationStyle, info: BibInfo?, number: Int) -> String {
            guard let info else { return "[?]" }
            switch style {
            case .numeric:       return "[\(number)]"
            case .parenthetical: return "(\(number))"
            case .superscripted: return superscriptDigits(number)
            case .authorYear:    return "(\(authorNames(info.authors, ampersand: true)), \(info.year.map(String.init) ?? "n.d."))"
            case .narrative:     return "\(authorNames(info.authors, ampersand: false)) (\(info.year.map(String.init) ?? "n.d."))"
            }
        }

        /// "Smith", "Smith & Jones" / "Smith and Jones", or "Smith et al." —
        /// the standard author–date surname forms.
        private static func authorNames(_ authors: [String], ampersand: Bool) -> String {
            // Authors are stored "Last, First"; surnames are the part before the comma.
            let lasts = authors
                .map { $0.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "" }
                .filter { !$0.isEmpty }
            switch lasts.count {
            case 0:  return "Anon."
            case 1:  return lasts[0]
            case 2:  return "\(lasts[0]) \(ampersand ? "&" : "and") \(lasts[1])"
            default: return "\(lasts[0]) et al."
            }
        }

        /// Unicode superscript digits (survive plain text and RTF unchanged).
        private static func superscriptDigits(_ n: Int) -> String {
            let map: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
                                               "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
            return String(String(n).map { map[$0] ?? $0 })
        }
    }

    // MARK: - Token (identity carried by the link URL)

    struct Token {
        let kind: RefOccurrence.Kind
        let targetID: UUID
        /// Rendering style; only meaningful for `.bib` tokens.  Kept for
        /// URL compatibility — rendering follows the manuscript's default
        /// citation format (`Context.defaultStyle`) since Aug 2026.
        let style: CitationStyle
        /// Additional cited entries for a multi-citation ("[3-6]") — bib
        /// tokens only; persisted in the URL's `m=` list (Aug 2026).
        var extraIDs: [UUID] = []

        /// Every entry this token cites (primary first).
        var allIDs: [UUID] { [targetID] + extraIDs }

        /// The `.link` URL persisting this token's identity + style.
        var url: URL? {
            switch kind {
            case .bib:
                let more = extraIDs.isEmpty ? ""
                    : "&m=" + extraIDs.map(\.uuidString).joined(separator: ",")
                return URL(string: "cite://\(targetID.uuidString)?f=\(style.rawValue)\(more)")
            case .figure: return URL(string: "figref://\(targetID.uuidString)")
            case .table:  return URL(string: "tabref://\(targetID.uuidString)")
            case .figurePlacement: return URL(string: "figplace://\(targetID.uuidString)")
            case .tablePlacement:  return URL(string: "tabplace://\(targetID.uuidString)")
            }
        }

        /// Parses a token URL; returns nil for foreign links (http, mailto, …).
        /// A bare `cite://<uuid>` (the legacy `{Key}` form) parses as `.numeric`.
        static func parse(_ url: URL) -> Token? {
            let kind: RefOccurrence.Kind
            switch url.scheme {
            case "cite":     kind = .bib
            case "figref":   kind = .figure
            case "tabref":   kind = .table
            case "figplace": kind = .figurePlacement
            case "tabplace": kind = .tablePlacement
            default:         return nil
            }
            // The UUID sits in the host position; fall back to string surgery
            // in case URL normalization moved it.
            let idString = url.host
                ?? url.absoluteString
                    .replacingOccurrences(of: "\(url.scheme ?? "")://", with: "")
                    .components(separatedBy: "?").first
                ?? ""
            guard let id = UUID(uuidString: idString) else { return nil }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let code = items?.first(where: { $0.name == "f" })?.value
            let style = code.flatMap(CitationStyle.init(rawValue:)) ?? .numeric
            let extras = (items?.first(where: { $0.name == "m" })?.value ?? "")
                .split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            return Token(kind: kind, targetID: id, style: style, extraIDs: extras)
        }
    }

    // MARK: - Context (everything a token needs to render itself)

    /// Display-relevant details of one bibliography entry.
    struct BibInfo {
        let key: String
        let authors: [String]
        let year: Int?
        let tooltip: String
    }

    /// A snapshot of the manuscript state that token rendering depends on:
    /// citation numbers, entry details, and figure/table numbers.  Editors
    /// compare `signature` to skip the rewrite pass when nothing relevant
    /// changed since their last one.
    struct Context {
        var numbers: [UUID: Int] = [:]          // cited entries → 1-based number
        var nextNumber: Int = 1                  // number a newly cited entry gets
        var bib: [UUID: BibInfo] = [:]
        var figures: [UUID: (number: Int, tooltip: String)] = [:]
        var tables: [UUID: (number: Int, tooltip: String)] = [:]
        /// The manuscript-wide citation format — EVERY bib token renders
        /// with this (per-token styles retired Aug 2026); part of the
        /// signature so changing the setting re-renders live.
        var defaultStyle: CitationStyle = .numeric
        var signature: Int = 0
    }

    /// Builds the rendering context for one manuscript (Source or a version
    /// snapshot).  Cost is O(citations + bibliography + figures + tables) —
    /// no text scanning.
    static func context(for m: Manuscript) -> Context {
        var ctx = Context()
        var hasher = Hasher()
        ctx.defaultStyle = m.settings.defaultCitationStyle
            .flatMap(CitationStyle.init(rawValue:)) ?? .numeric
        hasher.combine(ctx.defaultStyle.rawValue)

        let order = citedOrder(in: m)
        for (i, id) in order.enumerated() { ctx.numbers[id] = i + 1 }
        ctx.nextNumber = order.count + 1
        hasher.combine(order)

        for e in m.bibliography {
            let tooltip = fullReference(e)
            ctx.bib[e.id] = BibInfo(key: e.key, authors: e.authors, year: e.year, tooltip: tooltip)
            hasher.combine(e.id); hasher.combine(tooltip)
        }
        // Figure/table numbers follow reference order, like citations: the
        // first-referenced figure is "Figure 1", unreferenced figures follow.
        let figureNumbers = effectiveFigureNumbers(in: m)
        for f in m.figures {
            let number = figureNumbers[f.id] ?? f.number
            let tip = "Figure \(number) — \(f.title)" + (f.caption.isEmpty ? "" : "\n\(f.caption)")
            ctx.figures[f.id] = (number, tip)
            hasher.combine(f.id); hasher.combine(tip)
        }
        let tableNumbers = effectiveTableNumbers(in: m)
        for t in m.tables {
            let number = tableNumbers[t.id] ?? t.number
            let tip = "Table \(number) — \(t.title)" + (t.caption.isEmpty ? "" : "\n\(t.caption)")
            ctx.tables[t.id] = (number, tip)
            hasher.combine(t.id); hasher.combine(tip)
        }
        ctx.signature = hasher.finalize()
        return ctx
    }

    // MARK: - Reference-order numbering (figures & tables)

    /// Figure display numbers assigned like citation numbers: first-referenced
    /// = Figure 1, and so on; unreferenced figures follow in their manual
    /// order.  Placement markers don't count as references.
    static func effectiveFigureNumbers(in m: Manuscript) -> [UUID: Int] {
        effectiveNumbers(ids: m.figures.sorted { $0.number < $1.number }.map(\.id),
                         in: m, kind: .figure)
    }

    /// Table display numbers, same rule as figures.
    static func effectiveTableNumbers(in m: Manuscript) -> [UUID: Int] {
        effectiveNumbers(ids: m.tables.sorted { $0.number < $1.number }.map(\.id),
                         in: m, kind: .table)
    }

    private static func effectiveNumbers(ids: [UUID], in m: Manuscript,
                                         kind: RefOccurrence.Kind) -> [UUID: Int] {
        let valid = Set(ids)
        var seen = Set<UUID>()
        var order: [UUID] = []
        for (occ, _) in orderedRefs(in: m)
        where occ.kind == kind && valid.contains(occ.targetID) && seen.insert(occ.targetID).inserted {
            order.append(occ.targetID)
        }
        for id in ids where !seen.contains(id) { order.append(id) }
        return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0 + 1) })
    }

    /// "Authors (Year). Title. Journal Vol, Pages. doi:…" — the hover tooltip
    /// and the bibliography line used on export.
    static func fullReference(_ e: BibEntry) -> String {
        var parts: [String] = []
        if !e.authorsFormatted.isEmpty { parts.append(e.authorsFormatted) }
        if let year = e.year { parts.append("(\(year))") }
        if !e.title.isEmpty { parts.append(e.title + ".") }
        if let journal = e.journal, !journal.isEmpty { parts.append(journal) }
        if let vol = e.volume, !vol.isEmpty { parts.append(vol) }
        if let pages = e.pages, !pages.isEmpty { parts.append(pages) }
        if let doi = e.doi, !doi.isEmpty { parts.append("doi:\(doi)") }
        return parts.joined(separator: " ")
    }

    // MARK: - Rendering

    /// The text a token should currently display.  Unknown targets (entry or
    /// figure deleted) render as "[?]" so a stale number never masquerades as
    /// a live citation.
    static func displayText(for token: Token, context: Context) -> String {
        switch token.kind {
        case .bib:
            let style = context.defaultStyle
            if token.extraIDs.isEmpty {
                guard let info = context.bib[token.targetID] else { return "[?]" }
                let number = context.numbers[token.targetID] ?? context.nextNumber
                return CitationStyle.bibText(style, info: info, number: number)
            }
            // Multi-citation: entries ordered by citation number, sequential
            // runs of ≥3 compressed ("3-6"), otherwise comma-delimited.
            let pairs = token.allIDs
                .map { (id: $0, number: context.numbers[$0] ?? context.nextNumber) }
                .sorted { $0.number < $1.number }
            switch style {
            case .numeric:       return "[\(compressedNumbers(pairs.map(\.number)))]"
            case .parenthetical: return "(\(compressedNumbers(pairs.map(\.number))))"
            case .superscripted:
                let map: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³",
                                                   "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷",
                                                   "8": "⁸", "9": "⁹", "-": "⁻"]
                return String(compressedNumbers(pairs.map(\.number)).map { map[$0] ?? $0 })
            case .authorYear, .narrative:
                let inner = pairs.map { pair in
                    guard let info = context.bib[pair.id] else { return "?" }
                    // Reuse the single-entry renderer, minus its parentheses.
                    return CitationStyle.bibText(.authorYear, info: info, number: pair.number)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                }.joined(separator: "; ")
                return "(\(inner))"
            }
        case .figure:
            guard let (number, _) = context.figures[token.targetID] else { return "[?]" }
            return "Figure \(number)"
        case .table:
            guard let (number, _) = context.tables[token.targetID] else { return "[?]" }
            return "Table \(number)"
        case .figurePlacement:
            guard let (number, _) = context.figures[token.targetID] else { return "⟦?⟧" }
            return "⟦Figure \(number) here⟧"
        case .tablePlacement:
            guard let (number, _) = context.tables[token.targetID] else { return "⟦?⟧" }
            return "⟦Table \(number) here⟧"
        }
    }

    /// The hover tooltip for a token, or nil when the target no longer exists.
    static func tooltip(for token: Token, context: Context) -> String? {
        switch token.kind {
        case .bib:
            // A multi-citation's hover lists every cited entry.
            let tips = token.allIDs.compactMap { context.bib[$0]?.tooltip }
            return tips.isEmpty ? nil : tips.joined(separator: "\n\n")
        case .figure, .figurePlacement: return context.figures[token.targetID]?.tooltip
        case .table, .tablePlacement:   return context.tables[token.targetID]?.tooltip
        }
    }

    /// "3,4,5,6" → "3-6"; non-sequential stay comma-delimited ("3,4,6").
    /// Runs need ≥3 members to compress ("3,4" stays "3,4"); duplicates drop.
    static func compressedNumbers(_ numbers: [Int]) -> String {
        let sorted = Array(Set(numbers)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            if j - i >= 2 {
                parts.append("\(sorted[i])-\(sorted[j])")
            } else {
                for k in i...j { parts.append("\(sorted[k])") }
            }
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    // MARK: - Scanning

    /// Extracts the ordered token list from styled text (document order).
    static func scanRefs(in attributed: NSAttributedString) -> [RefOccurrence] {
        var refs: [RefOccurrence] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.link, in: full) { value, _, _ in
            guard let url = value as? URL, let token = Token.parse(url) else { return }
            // A multi-citation counts each cited entry (numbering, index).
            for id in token.allIDs {
                refs.append(RefOccurrence(kind: token.kind, targetID: id))
            }
        }
        return refs
    }

    /// One-time extraction for a pre-refs `RichText` (decodes its RTF).  Used
    /// by the store on load; never on an editing hot path.
    static func extractRefs(from rt: RichText) -> [RefOccurrence] {
        guard let rtf = rt.rtf,
              let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil)
        else { return [] }
        return scanRefs(in: attributed)
    }

    // MARK: - Document order & numbering

    /// Every token in the manuscript with the name of the prose field it sits
    /// in, in document order: abstract → active sections → letter to editor.
    static func orderedRefs(in m: Manuscript) -> [(occ: RefOccurrence, location: String)] {
        var out: [(RefOccurrence, String)] = []
        out += (m.abstract.refs ?? []).map { ($0, "Abstract") }
        for s in m.sections.sorted(by: { $0.order < $1.order }) where s.active {
            out += (s.content.refs ?? []).map { ($0, s.title) }
        }
        out += (m.letterToEditor.body.refs ?? []).map { ($0, "Letter to Editor") }
        return out
    }

    /// Bibliography entry ids in first-citation order (dangling ids excluded).
    static func citedOrder(in m: Manuscript) -> [UUID] {
        let valid = Set(m.bibliography.map(\.id))
        var seen = Set<UUID>()
        var order: [UUID] = []
        for (occ, _) in orderedRefs(in: m)
        where occ.kind == .bib && valid.contains(occ.targetID) && seen.insert(occ.targetID).inserted {
            order.append(occ.targetID)
        }
        return order
    }

    /// Keeps the bibliography array in citation order: cited entries first,
    /// by first citation; uncited entries after, keeping their manual order.
    /// Called from every store mutation so the invariant always holds.
    static func autoOrderBibliography(_ m: inout Manuscript) {
        let order = citedOrder(in: m)
        guard !order.isEmpty else { return }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let cited = m.bibliography.filter { rank[$0.id] != nil }
            .sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        let uncited = m.bibliography.filter { rank[$0.id] == nil }
        let reordered = cited + uncited
        if reordered.map(\.id) != m.bibliography.map(\.id) {
            m.bibliography = reordered
        }
    }

    // MARK: - Citation index (for the Bibliography view)

    /// How one prose field cites an entry.
    struct Usage {
        let location: String   // "Abstract", section title, "Letter to Editor"
        let count: Int
    }

    /// Per-entry citation facts for list badges and the entry details pane.
    struct CitationIndex {
        var numbers: [UUID: Int] = [:]
        var counts: [UUID: Int] = [:]
        var usage: [UUID: [Usage]] = [:]
    }

    static func citationIndex(for m: Manuscript) -> CitationIndex {
        var index = CitationIndex()
        for (i, id) in citedOrder(in: m).enumerated() { index.numbers[id] = i + 1 }
        // Count per (entry, location), preserving first-appearance order of locations.
        var perEntry: [UUID: [(location: String, count: Int)]] = [:]
        for (occ, location) in orderedRefs(in: m) where occ.kind == .bib {
            index.counts[occ.targetID, default: 0] += 1
            var list = perEntry[occ.targetID] ?? []
            if let i = list.firstIndex(where: { $0.location == location }) {
                list[i].count += 1
            } else {
                list.append((location, 1))
            }
            perEntry[occ.targetID] = list
        }
        for (id, list) in perEntry {
            index.usage[id] = list.map { Usage(location: $0.location, count: $0.count) }
        }
        return index
    }

    // MARK: - Rewrite pass

    /// One pending token correction: the visible text and/or tooltip no longer
    /// match what the context says they should be.
    struct TokenUpdate {
        let range: NSRange
        let text: String
        let textChanged: Bool
        let url: URL
        let tooltip: String?
    }

    /// Diffs every token in `attributed` against `context`.  Applying the
    /// returned updates **back-to-front** keeps the earlier ranges valid.
    static func plannedUpdates(in attributed: NSAttributedString, context: Context) -> [TokenUpdate] {
        var updates: [TokenUpdate] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.link, in: full) { value, range, _ in
            guard let url = value as? URL, let token = Token.parse(url) else { return }
            let desired = displayText(for: token, context: context)
            let tip = tooltip(for: token, context: context)
            let current = attributed.attributedSubstring(from: range).string
            let currentTip = attributed.attribute(.toolTip, at: range.location, effectiveRange: nil) as? String
            if desired != current || tip != currentTip {
                updates.append(TokenUpdate(range: range, text: desired,
                                           textChanged: desired != current,
                                           url: url, tooltip: tip))
            }
        }
        return updates
    }

    /// Export copy: tokens re-rendered against `context`, then stripped of the
    /// app-internal chrome (link, tooltip, and the bold affordance) so the
    /// submitted document reads like a normal paper.
    static func exportReady(_ attributed: NSAttributedString, context: Context) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: attributed)
        for u in plannedUpdates(in: out, context: context).sorted(by: { $0.range.location > $1.range.location })
        where u.textChanged {
            var attrs = out.attributes(at: u.range.location, effectiveRange: nil)
            attrs[.toolTip] = u.tooltip
            out.replaceCharacters(in: u.range, with: NSAttributedString(string: u.text, attributes: attrs))
        }
        let full = NSRange(location: 0, length: out.length)
        var tokenRanges: [NSRange] = []
        out.enumerateAttribute(.link, in: full) { value, range, _ in
            guard let url = value as? URL, Token.parse(url) != nil else { return }
            tokenRanges.append(range)
        }
        for range in tokenRanges {
            out.removeAttribute(.link, range: range)
            out.removeAttribute(.toolTip, range: range)
            out.enumerateAttribute(.font, in: range) { value, sub, _ in
                guard let font = value as? NSFont else { return }
                out.addAttribute(.font,
                                 value: NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask),
                                 range: sub)
            }
        }
        return out
    }
}
