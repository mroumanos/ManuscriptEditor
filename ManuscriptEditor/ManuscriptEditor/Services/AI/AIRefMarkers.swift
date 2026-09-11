// AIRefMarkers.swift
//
// Citations survive a rewrite, or the rewrite is worthless.
//
// WHAT WENT WRONG, EXACTLY
// ─────────────────────────────────────────────────────────────────────────────
// A citation in this app is not a character in the text — it is a `.link`
// attribute on the RTF, carrying `cite://<uuid>`.  The plain-text mirror the
// first fast-forward sent contained no trace of it: a real run sent an
// Introduction with fourteen citations and the model saw none of them, then the
// adapted text was written back as `RichText(plain:)`, which discarded the RTF
// and with it all twenty-one references in the manuscript.
//
// So the model has to be shown the citations, in a form it cannot lose by
// accident and cannot rewrite by accident:
//
//     …food insecurity rose sharply [[cite:3]] in rural counties [[cite:4]].
//
// Each marker stands for one link run.  The model is told to carry them through
// untouched; on the way back each marker is restored to the exact run it stood
// for, with its URL, so identity survives even though every word around it
// changed.  A marker the model dropped is a citation lost, and `restore`
// reports that rather than letting it pass silently.
//
// The same protection covers **part tokens** (`[[title]]`, `[[authors.names]]`
// …), which are already literal text: the first run replaced
// `[[authors.names]]` with an invented author list.  They fall under the same
// "keep every [[…]] exactly as it is" rule in the prompt, `restore` checks
// they came back, and puts the `part://` link back on each one — a token the
// model returns is text until something makes it a token again.
//
// See MasterContext/features/ai-assist.md §7.2.

import AppKit
import Foundation

enum AIRefMarkers {

    /// One reference occurrence, as it was found in the text.
    struct Marked {
        /// `[[cite:3]]` — what the model sees.
        let marker: String
        /// The link URL that carries the reference's identity.
        let url: URL
        /// What the editor was showing for it, restored verbatim.
        let displayText: String
    }

    /// A section prepared for a model: text with markers, and what they mean.
    struct Prepared {
        let text: String
        let markers: [Marked]
        /// Part tokens (`[[title]]`) already present in the text, which must
        /// also come back intact.
        let partTokens: [String]

        var isEmpty: Bool { markers.isEmpty && partTokens.isEmpty }
        /// Every token the reply must still contain.
        var required: [String] { markers.map(\.marker) + partTokens }
    }

    // MARK: - Outbound

    /// Replaces every reference run with a marker.
    ///
    /// Falls back to the plain mirror when there is no RTF — an unstyled
    /// section cannot carry a reference in the first place.
    static func prepare(_ rich: RichText) -> Prepared {
        let partTokens = partTokenList(in: rich.plain)

        guard let rtf = rich.rtf,
              let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil)
        else {
            return Prepared(text: rich.plain, markers: [], partTokens: partTokens)
        }

        var out = ""
        var markers: [Marked] = []
        var counts: [String: Int] = [:]
        let full = NSRange(location: 0, length: attributed.length)

        attributed.enumerateAttribute(.link, in: full) { value, range, _ in
            let piece = attributed.attributedSubstring(from: range).string
            guard let url = linkURL(value), let token = RefEngine.Token.parse(url) else {
                out += piece
                return
            }
            let kind = markerKind(token.kind)
            let next = (counts[kind] ?? 0) + 1
            counts[kind] = next
            let marker = "[[\(kind):\(next)]]"
            markers.append(Marked(marker: marker, url: url, displayText: piece))
            out += marker
        }

        return Prepared(text: out, markers: markers, partTokens: partTokens)
    }

    // MARK: - Inbound

    /// What came back, and what it cost.
    struct Restored {
        let rich: RichText
        /// Markers the model failed to return — each one a lost reference.
        let missing: [String]
    }

    /// Rebuilds rich text from the model's reply, putting every reference back.
    ///
    /// Prose styling is deliberately not carried over: the adapted text is new
    /// text, and the app's editing typography is applied everywhere anyway
    /// (global editing typography, Aug 2026).  What must survive is *identity*
    /// — the link attribute — **and the citation's own styling**.
    ///
    /// That second half was missed the first time: a superscripted citation is
    /// a smaller font plus a baseline offset, and rebuilding a run with only
    /// the link left every reference sitting flat in the line.  The only way
    /// back was to change the citation format and change it again, which is
    /// the bug report that found this.  With a `context` the display text is
    /// also recomputed, so a citation renumbered by the adaptation comes back
    /// with the right number rather than the one it had.
    static func restore(_ text: String, from prepared: Prepared,
                        context: RefEngine.Context? = nil) -> Restored {
        let result = NSMutableAttributedString()
        let byMarker = Dictionary(uniqueKeysWithValues: prepared.markers.map { ($0.marker, $0) })
        var seen = Set<String>()

        var rest = Substring(text)
        while let open = rest.range(of: "[[") {
            result.append(NSAttributedString(string: String(rest[rest.startIndex..<open.lowerBound])))
            guard let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) else {
                // An unterminated "[[": keep it literally rather than eating
                // the rest of the section.
                rest = rest[open.lowerBound...]
                break
            }
            let token = String(rest[open.lowerBound..<close.upperBound])
            if let marked = byMarker[token] {
                seen.insert(token)
                result.append(citation(marked, context: context))
            } else {
                // A part token comes back LIVE — `[[title]]` is only a token
                // by its `part://` link, and appending it as text left every
                // adapted title page with fields that never resolved.  Only a
                // path in the catalog becomes one; anything else the model put
                // in brackets stays exactly as it stands, so inventing a
                // reference is not possible this way, which is the point.
                result.append(PartEngine.tokenized(token, attributes: [:]))
                seen.insert(token)
            }
            rest = rest[close.upperBound...]
        }
        result.append(NSAttributedString(string: String(rest)))

        let full = NSRange(location: 0, length: result.length)
        let rtf = result.rtf(from: full, documentAttributes: [:])
        let rich = RichText(plain: result.string, rtf: rtf,
                            refs: RefEngine.scanRefs(in: result))
        return Restored(rich: rich, missing: prepared.required.filter { !seen.contains($0) })
    }

    /// One reference, rendered the way the editor renders it.
    private static func citation(_ marked: Marked,
                                 context: RefEngine.Context?) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.link: marked.url]
        guard let context, let token = RefEngine.Token.parse(marked.url) else {
            return NSAttributedString(string: marked.displayText, attributes: attributes)
        }
        if let tip = RefEngine.tooltip(for: token, context: context) {
            attributes[.toolTip] = tip
        }
        CitationTextView.applyCitationRaise(
            &attributes,
            raised: RefEngine.isSuperscripted(token, context: context),
            // The raise is proportional to the body size, and the editing
            // typography is global (Aug 2026), so the user's configured size
            // is the right base even though the family is applied by the
            // editor when it renders.
            baseFont: NSFont.systemFont(ofSize: EditorTypography.current.size))
        let text = RefEngine.displayText(for: token, context: context)
        return NSAttributedString(string: text.isEmpty ? marked.displayText : text,
                                  attributes: attributes)
    }

    // MARK: - Helpers

    /// The part tokens already living in a section's text (`[[title]]`), which
    /// the model must return untouched.
    static func partTokenList(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[["),
              let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            let token = String(rest[open.lowerBound..<close.upperBound])
            // Reference markers are generated here, never authored, so anything
            // already in the text is a part token.
            if !token.contains(":") { out.append(token) }
            rest = rest[close.upperBound...]
        }
        return out
    }

    private static func markerKind(_ kind: RefOccurrence.Kind) -> String {
        switch kind {
        case .bib:              return "cite"
        case .figure:           return "figref"
        case .table:            return "tabref"
        case .figurePlacement:  return "figplace"
        case .tablePlacement:   return "tabplace"
        }
    }

    /// `.link` values arrive as either `URL` or `String` depending on how the
    /// RTF was written.
    private static func linkURL(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}
