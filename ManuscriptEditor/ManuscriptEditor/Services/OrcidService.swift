// OrcidService.swift
//
// Author lookup against ORCID's public API — no key, no account, plain
// URLSession like the Zotero and GitHub services.  A single expanded-search
// request returns everything the Add Author autofill needs: names, the
// ORCID iD, any public email, and affiliation names.

import Foundation

struct OrcidService {

    /// One search hit, ready to autofill an `Author`.
    struct Candidate: Identifiable, Sendable, Equatable {
        var orcid: String
        var givenNames: String
        var familyNames: String
        /// First public email on the record — most researchers keep email
        /// private, so this is usually nil.
        var email: String?
        /// Affiliation organization names, most relevant first.
        var institutionNames: [String]

        var id: String { orcid }
        var displayName: String {
            [givenNames, familyNames].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    enum OrcidError: LocalizedError {
        case badResponse(Int)
        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "ORCID search failed (HTTP \(code))."
            }
        }
    }

    /// Top-20 search.  A full iD ("0000-0002-1825-0097") matches its record
    /// directly; anything else matches given/family names, in either order
    /// ("marie curie" and "curie, marie" both hit).
    func search(_ raw: String) async throws -> [Candidate] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let query: String
        if text.range(of: #"^\d{4}-\d{4}-\d{4}-\d{3}[\dXx]$"#, options: .regularExpression) != nil {
            query = "orcid:\(text.uppercased())"
        } else {
            // Careful: the query index field is "family-name" (singular)
            // even though the response JSON says "family-names" — the
            // plural in a query is a Solr 500, verified Aug 2026.
            let terms = text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            if let first = terms.first, let last = terms.last, terms.count >= 2 {
                query = "(given-names:\(first)* AND family-name:\(last)*) OR "
                      + "(given-names:\(last)* AND family-name:\(first)*)"
            } else {
                query = "(given-names:\(text)* OR family-name:\(text)*)"
            }
        }

        var components = URLComponents(string: "https://pub.orcid.org/v3.0/expanded-search/")!
        components.queryItems = [.init(name: "q", value: query),
                                 .init(name: "rows", value: "20")]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OrcidError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let payload = try JSONDecoder().decode(SearchPayload.self, from: data)
        return (payload.results ?? []).map {
            Candidate(orcid: $0.orcid ?? "",
                      givenNames: $0.given ?? "",
                      familyNames: $0.family ?? "",
                      email: $0.email?.first,
                      institutionNames: $0.institutions ?? [])
        }
    }

    // The wire shape of /expanded-search — "expanded-result" is null (not
    // an empty array) when nothing matches.
    private struct SearchPayload: Decodable {
        let results: [Result]?
        enum CodingKeys: String, CodingKey { case results = "expanded-result" }

        struct Result: Decodable {
            let orcid: String?
            let given: String?
            let family: String?
            let email: [String]?
            let institutions: [String]?
            enum CodingKeys: String, CodingKey {
                case orcid = "orcid-id"
                case given = "given-names"
                case family = "family-names"
                case email
                case institutions = "institution-name"
            }
        }
    }
}
