// PartEngine.swift
//
// "Section part" tokens: [[authors]]-style live references the "/" picker
// injects into any rich text, so sections can be composed out of other
// sections' data (a hand-built Title section, say).  The editor shows the
// literal [[path]] marker — format it like any prose; the injected output
// inherits that formatting on export.  Clicking a token picks its
// delimiter (space / semicolon / newline) and, where authors meet
// institutes, the linkage markers (superscript / cross / double cross /
// none).
//
// Token identity is a part:// link: part://t/<path>?d=<delim>&m=<marker>
// (a constant "t" host keeps dots/underscores safely in the URL path).

import AppKit

enum PartEngine {

    struct Part {
        let path: String
        var delimiter: String = "semicolon"   // "space" | "semicolon" | "newline"
        var marker: String = "superscript"    // "superscript" | "cross" | "doublecross" | "none"

        var url: URL? { URL(string: "part://t/\(path)?d=\(delimiter)&m=\(marker)") }
        var markerText: String { "[[\(path)]]" }
        /// Marker options only matter where authors meet institutes.
        var hasMarkerOptions: Bool { path == "authors" }
    }

    /// Everything "/" offers, with the label shown in the picker.
    static let catalog: [(path: String, label: String)] = [
        ("authors", "Authors — full byline (names + institutes)"),
        ("authors.names", "Authors — names only"),
        ("authors.institutes", "Authors — institutes"),
        ("authors.corresponding_author", "Corresponding author — name"),
        ("authors.corresponding_author.first_name", "Corresponding author — first name"),
        ("authors.corresponding_author.last_name", "Corresponding author — last name"),
        ("authors.corresponding_author.email", "Corresponding author — email"),
        ("authors.corresponding_author.details", "Corresponding author — details"),
    ]

    static func parse(_ url: URL) -> Part? {
        guard url.scheme == "part" else { return nil }
        let path = String(url.path.dropFirst())
        guard !path.isEmpty else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return Part(path: path,
                    delimiter: items?.first(where: { $0.name == "d" })?.value ?? "semicolon",
                    marker: items?.first(where: { $0.name == "m" })?.value ?? "superscript")
    }

    static func delimiterText(_ d: String) -> String {
        switch d {
        case "space":   return " "
        case "newline": return "\n"
        default:        return "; "
        }
    }

    private static func markerText(_ style: String, index: Int) -> String {
        switch style {
        case "cross":       return String(repeating: "†", count: index + 1)
        case "doublecross": return String(repeating: "‡", count: index + 1)
        case "none":        return ""
        default:            return String(index + 1)
        }
    }

    // MARK: - Rendering

    /// The expansion as (text, isMarker) runs — markers render raised in
    /// the attributed form and inline in plain text.
    private static func pieces(for part: Part, content m: Manuscript) -> [(text: String, marker: Bool)] {
        let authors = m.authors.sorted { $0.order < $1.order }
        let corresponding = authors.filter(\.isCorresponding)
        let delim = delimiterText(part.delimiter)

        var lines: [String] = []
        var indexByLine: [String: Int] = [:]
        for a in authors {
            for l in a.affiliationLines(in: m) where indexByLine[l] == nil {
                indexByLine[l] = lines.count
                lines.append(l)
            }
        }
        func markers(_ a: Author) -> String {
            guard part.marker != "none" else { return "" }
            return a.affiliationLines(in: m).compactMap { indexByLine[$0] }.sorted()
                .map { markerText(part.marker, index: $0) }.joined(separator: ",")
        }
        func joined(_ values: [String]) -> [(String, Bool)] {
            values.isEmpty ? [] : [(values.joined(separator: delim), false)]
        }

        switch part.path {
        case "authors":
            var out: [(String, Bool)] = []
            for (i, a) in authors.enumerated() {
                out.append((a.fullName, false))
                let mk = markers(a)
                if !mk.isEmpty { out.append((mk, true)) }
                if a.isCorresponding { out.append(("*", false)) }
                if i < authors.count - 1 { out.append((delim, false)) }
            }
            if !lines.isEmpty {
                out.append(("\n", false))
                for (i, l) in lines.enumerated() {
                    if part.marker != "none" {
                        out.append((markerText(part.marker, index: i), true))
                        out.append((" ", false))
                    }
                    out.append((l + (i < lines.count - 1 ? "\n" : ""), false))
                }
            }
            return out
        case "authors.names":
            return joined(authors.map(\.fullName))
        case "authors.institutes":
            return joined(lines)
        case "authors.corresponding_author":
            return joined(corresponding.map(\.fullName))
        case "authors.corresponding_author.first_name":
            return joined(corresponding.map(\.firstName))
        case "authors.corresponding_author.last_name":
            return joined(corresponding.map(\.lastName))
        case "authors.corresponding_author.email":
            return joined(corresponding.map(\.email))
        case "authors.corresponding_author.details":
            return joined(corresponding.compactMap(\.correspondingDetails).filter { !$0.isEmpty })
        default:
            return []
        }
    }

    /// Plain-text expansion (LaTeX, plain mirrors); markers inline.
    static func plainText(for part: Part, content m: Manuscript) -> String {
        pieces(for: part, content: m).map(\.text).joined()
    }

    /// Expands `[[path]]` markers in plain prose with default options —
    /// the LaTeX path, where token URLs (and their settings) are gone.
    static func expandPlainMarkers(_ text: String, content m: Manuscript) -> String {
        var out = text
        for (path, _) in catalog {
            let marker = "[[\(path)]]"
            guard out.contains(marker) else { continue }
            out = out.replacingOccurrences(
                of: marker, with: plainText(for: Part(path: path), content: m))
        }
        return out
    }

    /// Attributed expansion inheriting the token's own attributes — the
    /// injected text is "freetext in the section's formatting".  Markers
    /// get the materialized superscript raise off the token's font.
    static func attributed(for part: Part, content m: Manuscript,
                           tokenAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var clean = tokenAttributes
        clean.removeValue(forKey: .link)
        clean.removeValue(forKey: .toolTip)
        let baseFont = (clean[.font] as? NSFont) ?? .systemFont(ofSize: 12)
        let markerFont = NSFont(descriptor: baseFont.fontDescriptor,
                                size: (baseFont.pointSize * 0.65).rounded()) ?? baseFont
        let out = NSMutableAttributedString()
        for piece in pieces(for: part, content: m) {
            var attrs = clean
            if piece.marker {
                attrs[.font] = markerFont
                attrs[.baselineOffset] = baseFont.pointSize * 0.33
            }
            out.append(NSAttributedString(string: piece.text, attributes: attrs))
        }
        return out
    }
}
