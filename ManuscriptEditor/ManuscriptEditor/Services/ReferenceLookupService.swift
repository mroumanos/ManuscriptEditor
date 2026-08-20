// ReferenceLookupService.swift
//
// Metadata lookups behind the bibliography search bar: a DOI resolves
// through doi.org content negotiation (CSL JSON — the fix for "DOI fills
// only the DOI field", issue #9), and a plain web URL is fetched for its
// <title> to seed a website entry.  Plain URLSession, no dependencies.

import Foundation

struct ReferenceLookupService {

    enum LookupError: LocalizedError {
        case badResponse(Int)
        case noTitle

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Lookup failed (HTTP \(code))."
            case .noTitle: return "The page didn't offer a readable title."
            }
        }
    }

    /// Pulls a bare DOI ("10.1234/abc") out of raw text, a "doi:" prefix,
    /// or a doi.org URL; nil when the text isn't DOI-shaped.
    static func extractDOI(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://doi.org/", "http://doi.org/",
                       "https://dx.doi.org/", "http://dx.doi.org/", "doi:"] {
            if s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        return s.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil ? s : nil
    }

    /// The URL for the "Web" section — http(s) input that is not a DOI link
    /// (doi.org links belong to the DOI section).
    static func webURL(_ text: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://"),
              extractDOI(s) == nil,
              let url = URL(string: s)
        else { return nil }
        return url
    }

    /// Resolves a DOI to a fully populated entry via doi.org content
    /// negotiation (Accept: CSL JSON, the Crossref/DataCite-backed format).
    func entry(forDOI doi: String) async throws -> BibEntry {
        var request = URLRequest(url: URL(string: "https://doi.org/\(doi)")!)
        request.setValue("application/vnd.citationstyles.csl+json",
                         forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LookupError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let csl = try JSONDecoder().decode(CSL.self, from: data)

        var entry = BibEntry.empty()
        entry.type = Self.mapCSLType(csl.type ?? "")
        entry.title = csl.title ?? ""
        entry.authors = (csl.author ?? []).map { name in
            if let family = name.family, !family.isEmpty {
                return name.given.map { "\(family), \($0)" } ?? family
            }
            return name.literal ?? ""
        }.filter { !$0.isEmpty }
        if entry.authors.isEmpty { entry.authors = [""] }
        entry.year = csl.issued?.year
        entry.journal = csl.containerTitle
        entry.volume = csl.volume
        entry.issue = csl.issue
        entry.pages = csl.page
        entry.publisher = csl.publisher
        entry.doi = doi
        entry.url = "https://doi.org/\(doi)"
        let last = entry.authors.first?
            .components(separatedBy: ",").first?.filter(\.isLetter) ?? ""
        entry.key = "\(last)\(entry.year.map(String.init) ?? "")"
        return entry
    }

    /// Fetches a web page and seeds a website entry from its <title>.
    func entry(forWebPage url: URL) async throws -> BibEntry {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LookupError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        guard let range = html.range(of: #"(?is)<title[^>]*>.*?</title>"#,
                                     options: .regularExpression) else {
            throw LookupError.noTitle
        }
        let title = Self.decodeEntities(
            String(html[range])
                .replacingOccurrences(of: #"(?is)</?title[^>]*>"#,
                                      with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        guard !title.isEmpty else { throw LookupError.noTitle }

        var entry = BibEntry.empty()
        entry.type = .website
        entry.title = title
        entry.authors = [""]
        entry.url = url.absoluteString
        let host = url.host?.replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: ".").first ?? "web"
        entry.key = host + (entry.year.map(String.init) ?? "")
        return entry
    }

    // MARK: - Helpers

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func mapCSLType(_ type: String) -> BibEntryType {
        switch type {
        case "journal-article", "article-journal": return .article
        case "book", "monograph":                  return .book
        case "book-chapter", "chapter":            return .bookChapter
        case "proceedings-article", "paper-conference": return .conference
        case "dissertation", "thesis":             return .thesis
        case "posted-content", "preprint":         return .preprint
        case "webpage":                            return .website
        default:                                   return .other
        }
    }

    // The slice of CSL JSON the entry needs.
    private struct CSL: Decodable {
        let type: String?
        let title: String?
        let author: [Name]?
        let containerTitle: String?
        let volume: String?
        let issue: String?
        let page: String?
        let publisher: String?
        let issued: DateParts?

        enum CodingKeys: String, CodingKey {
            case type, title, author, volume, issue, page, publisher, issued
            case containerTitle = "container-title"
        }

        struct Name: Decodable { let family: String?; let given: String?; let literal: String? }

        /// "issued": {"date-parts": [[2023, 5, 1]]} — decoded leniently, some
        /// registrars put strings or nulls in the parts.
        struct DateParts: Decodable {
            let year: Int?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let parts = try? c.decode([[Int?]].self, forKey: .dateParts)
                year = parts?.first?.first ?? nil
            }
            enum CodingKeys: String, CodingKey { case dateParts = "date-parts" }
        }
    }
}
