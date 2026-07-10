// ZoteroService.swift
//
// Connects to a locally-running Zotero (Zotero 7's built-in local HTTP API,
// which mirrors the Zotero Web API v3) so the user can browse and import
// references without an account or cloud round-trip.
//
//   Base URL:  http://127.0.0.1:23119/api/users/0/items
//   Format:    ?format=json  (with header  Zotero-API-Version: 3)
//
// The app is sandboxed; outgoing connections are enabled via the
// ENABLE_OUTGOING_NETWORK_CONNECTIONS build setting. The service degrades
// gracefully (throws `ZoteroError.unreachable`) when Zotero isn't running, so
// bibliography editing is never blocked by it.
//
// NOTE: This talks to a live local process, so behavior must be confirmed
// against a running Zotero. Decoding is deliberately permissive.

import Foundation

// MARK: - Errors

enum ZoteroError: LocalizedError {
    case unreachable
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unreachable: return "Couldn't reach Zotero. Make sure Zotero is running (local API on port 23119)."
        case .badResponse: return "Zotero returned an unexpected response."
        }
    }
}

// MARK: - Wire model (subset of the Zotero Web API item schema)

/// One item as returned by the local API; only the fields we use are decoded.
struct ZoteroItem: Identifiable, Sendable {
    let key: String
    let itemType: String
    let title: String
    let creators: [Creator]
    let date: String
    let publicationTitle: String?
    let volume: String?
    let issue: String?
    let pages: String?
    let doi: String?
    let url: String?
    let publisher: String?

    var id: String { key }

    struct Creator: Sendable {
        let firstName: String
        let lastName: String
        /// Falls back to a single "name" field some creators use.
        let name: String

        /// "Last, First" (or the raw name for single-field creators).
        var formatted: String {
            if !lastName.isEmpty || !firstName.isEmpty {
                return firstName.isEmpty ? lastName : "\(lastName), \(firstName)"
            }
            return name
        }
    }
}

// MARK: - Service

struct ZoteroService {

    private let base = URL(string: "http://127.0.0.1:23119/api/users/0/items")!

    /// Fetches library items, optionally filtered by a search string. Excludes
    /// attachments and notes (top-level bibliographic items only).
    func fetchItems(matching query: String = "", limit: Int = 100) async throws -> [ZoteroItem] {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "itemType", value: "-attachment || note"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "dateModified"),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: trimmed))
            items.append(URLQueryItem(name: "qmode", value: "everything"))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        request.timeoutInterval = 8

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ZoteroError.unreachable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ZoteroError.badResponse
        }
        return try decodeItems(data)
    }

    /// Maps a Zotero item to a `BibEntry`, tagging it with `zoteroKey`.
    func bibEntry(from item: ZoteroItem) -> BibEntry {
        BibEntry(
            id: UUID(),
            key: citationKey(for: item),
            type: mapType(item.itemType),
            authors: item.creators.map(\.formatted).filter { !$0.isEmpty },
            title: item.title,
            year: parseYear(item.date),
            journal: item.publicationTitle,
            volume: item.volume,
            issue: item.issue,
            pages: item.pages,
            doi: item.doi,
            url: item.url,
            publisher: item.publisher,
            booktitle: nil,
            note: nil,
            zoteroKey: item.key
        )
    }

    // MARK: - Decoding (permissive)

    private func decodeItems(_ data: Data) throws -> [ZoteroItem] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ZoteroError.badResponse
        }
        return array.compactMap { obj in
            let key = (obj["key"] as? String) ?? ""
            guard let d = obj["data"] as? [String: Any] else { return nil }
            let creators: [ZoteroItem.Creator] = (d["creators"] as? [[String: Any]] ?? []).map {
                ZoteroItem.Creator(
                    firstName: ($0["firstName"] as? String) ?? "",
                    lastName: ($0["lastName"] as? String) ?? "",
                    name: ($0["name"] as? String) ?? ""
                )
            }
            return ZoteroItem(
                key: key,
                itemType: (d["itemType"] as? String) ?? "",
                title: (d["title"] as? String) ?? "(untitled)",
                creators: creators,
                date: (d["date"] as? String) ?? "",
                publicationTitle: d["publicationTitle"] as? String,
                volume: d["volume"] as? String,
                issue: d["issue"] as? String,
                pages: d["pages"] as? String,
                doi: d["DOI"] as? String,
                url: d["url"] as? String,
                publisher: d["publisher"] as? String
            )
        }
    }

    // MARK: - Mapping helpers

    private func mapType(_ itemType: String) -> BibEntryType {
        switch itemType {
        case "journalArticle":              return .article
        case "book":                        return .book
        case "bookSection":                 return .bookChapter
        case "conferencePaper":             return .conference
        case "thesis":                      return .thesis
        case "preprint":                    return .preprint
        case "webpage", "blogPost":         return .website
        default:                            return .other
        }
    }

    private func parseYear(_ date: String) -> Int? {
        // Zotero dates vary ("2020", "2020-05", "May 2020"); grab the first 4-digit run.
        if let match = date.range(of: #"\d{4}"#, options: .regularExpression) {
            return Int(date[match])
        }
        return nil
    }

    private func citationKey(for item: ZoteroItem) -> String {
        let last = item.creators.first?.lastName.filter(\.isLetter) ?? ""
        let year = parseYear(item.date).map(String.init) ?? ""
        let base = (last.isEmpty ? "Ref" : last) + year
        return base.isEmpty ? "Ref" : base
    }
}
