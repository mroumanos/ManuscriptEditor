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
// `[[authors.names]]` with an invented author list.  They are not touched here
// — they simply fall under the same "keep every [[…]] exactly as it is" rule in
// the prompt, and `restore` checks they came back too.
//
// See MasterContext/11-ai-integration.md §7.2.

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
    /// Styling is deliberately not carried over: the adapted prose is new text,
    /// and the app's editing typography is applied everywhere anyway (global
    /// editing typography, Aug 2026).  What must survive is *identity*, and
    /// that lives in the link attribute.
    static func restore(_ text: String, from prepared: Prepared) -> Restored {
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
                result.append(NSAttributedString(string: marked.displayText,
                                                 attributes: [.link: marked.url]))
            } else {
                // A part token, or something the model invented: keep the text
                // exactly as it stands.  Inventing a reference is not possible
                // this way, which is the point.
                result.append(NSAttributedString(string: token))
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
