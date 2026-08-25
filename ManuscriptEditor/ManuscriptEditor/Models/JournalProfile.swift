// JournalProfile.swift
//
// One journal's configuration in ONE file: where its rules come from, and
// what the app checks.
//
//   sourceRequirements — the journal's own instructions: a link to the page
//                        plus a distilled free-text summary the user can
//                        edit.  Not executable; it's the reference.
//   checks             — the executable rules (automatic and manual alike).
//
// PROVENANCE
// ─────────────────────────────────────────────────────────────────────────
// A profile is either BUNDLED (ships with the app, in
// `JournalProfiles/<slug>.json`, viewable on GitHub) or MANUSCRIPT-OWNED
// (the user edited it, so a copy is written into the manuscript folder at
// `journals/<slug>.json` and travels with it — locally and, when the
// manuscript has a remote, in that repository).  Either way `originURL`
// links to the file it came from, so "where did this rule come from?" is
// always one click away.

import Foundation

// MARK: - SourceRequirements

/// The journal's own submission instructions: a link and a summary.
struct SourceRequirements: Codable, Sendable, Equatable {
    /// The journal's author-instructions page.
    var url: String = ""
    /// Distilled, free-text summary — the user edits this directly.
    var summary: String = ""
    /// When the summary was last edited in this manuscript.
    var editedAt: Date? = nil

    var isEmpty: Bool {
        url.trimmingCharacters(in: .whitespaces).isEmpty
            && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - JournalProfile

struct JournalProfile: Codable, Identifiable, Sendable, Equatable {

    /// Where this profile's configuration lives.
    enum Origin: String, Codable, Sendable {
        /// Ships with the app (`JournalProfiles/<slug>.json` in the repo).
        case bundled
        /// Edited here, so it lives in the manuscript folder and travels
        /// with it (`journals/<slug>.json`).
        case manuscript

        var label: String {
            switch self {
            case .bundled:    return "App defaults"
            case .manuscript: return "This manuscript"
            }
        }
    }

    /// Slug, also the file name: "journal-of-nutrition-education-research-article".
    var id: String
    var name: String
    var articleType: String?
    var sourceRequirements: SourceRequirements = SourceRequirements()
    var checks: [CheckRule] = []

    var origin: Origin = .bundled

    /// Link to the file this configuration came from, when it has one.
    var originURL: String? = nil
    var updatedAt: Date? = nil

    var displayName: String { articleType.map { "\(name) — \($0)" } ?? name }

    private enum CodingKeys: String, CodingKey {
        case id, name, articleType, sourceRequirements, checks, origin, originURL, updatedAt
    }

    init(id: String, name: String, articleType: String? = nil,
         sourceRequirements: SourceRequirements = SourceRequirements(),
         checks: [CheckRule] = [], origin: Origin = .bundled,
         originURL: String? = nil, updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.articleType = articleType
        self.sourceRequirements = sourceRequirements; self.checks = checks
        self.origin = origin; self.originURL = originURL; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        articleType = try c.decodeIfPresent(String.self, forKey: .articleType)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? JournalProfile.slug(name: name, articleType: articleType)
        sourceRequirements = try c.decodeIfPresent(SourceRequirements.self,
                                                   forKey: .sourceRequirements) ?? SourceRequirements()
        checks = try c.decodeIfPresent([CheckRule].self, forKey: .checks) ?? []
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .bundled
        originURL = try c.decodeIfPresent(String.self, forKey: .originURL)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// A file-name-safe slug for a journal + article type.
    static func slug(name: String, articleType: String?) -> String {
        let joined = [name, articleType].compactMap { $0 }.joined(separator: "-")
        let allowed = joined.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        return String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    /// The canonical GitHub link for a bundled profile.  The files live in
    /// the app target so they ship in the bundle AND stay readable on
    /// GitHub — one copy, no drift.
    static let bundledFolder = "JournalProfiles"

    static func bundledURL(slug: String) -> String {
        "https://github.com/mroumanos/ManuscriptEditor/blob/main/ManuscriptEditor/ManuscriptEditor/JournalProfiles/\(slug).json"
    }

    /// Every profile shipped with the app, keyed by slug.
    ///
    /// The synchronized-folder build phase flattens resources into
    /// `Contents/Resources`, so the `JournalProfiles/` subdirectory may or
    /// may not survive — look in both places and take whichever has files.
    /// A JSON that isn't a profile simply fails to decode and is skipped.
    static func bundled(in bundle: Bundle = .containingCode) -> [String: JournalProfile] {
        let inFolder = bundle.urls(forResourcesWithExtension: "json",
                                   subdirectory: bundledFolder) ?? []
        let flat = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [String: JournalProfile] = [:]
        for url in inFolder + flat {
            guard let data = try? Data(contentsOf: url),
                  let profile = try? decoder.decode(JournalProfile.self, from: data),
                  !profile.name.isEmpty
            else { continue }
            out[profile.id] = profile
        }
        return out
    }

    /// The profile shipped for a journal, if one exists.
    static func bundled(name: String, articleType: String?) -> JournalProfile? {
        bundled()[slug(name: name, articleType: articleType)]
    }
}

// MARK: - Bundle lookup

/// Anchors `Bundle(for:)` to the bundle holding this code.
private final class BundleMarker {}

extension Bundle {
    /// The bundle that contains the app's code.  This is the app bundle when
    /// running normally, and still the app bundle when the binary is loaded
    /// by something else (a test harness), where `Bundle.main` would be the
    /// host executable and carry no resources.
    static let containingCode = Bundle(for: BundleMarker.self)
}

// MARK: - Subsections

/// Headings found inside a body section or the abstract.  Structured
/// abstracts ("Objective:", "Methods:") and heading paragraphs both count,
/// so a check can target one part of a section.
enum SubsectionParser {

    /// Heading-like lines: a short line ending in ':' or a line that looks
    /// like a run-in heading ("Objective: ...").
    static func headings(in text: String) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let colon = line.firstIndex(of: ":") {
                let head = String(line[line.startIndex..<colon])
                    .trimmingCharacters(in: .whitespaces)
                let words = head.split(separator: " ").count
                if words <= 5, !head.isEmpty, !out.contains(head) { out.append(head) }
            }
        }
        return out
    }

    /// The text belonging to `heading`: everything from that heading up to
    /// the next one.
    static func body(of heading: String, in text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var collecting = false
        var collected: [String] = []
        let all = headings(in: text)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lead = line.firstIndex(of: ":").map {
                String(line[line.startIndex..<$0]).trimmingCharacters(in: .whitespaces)
            }
            if let lead, all.contains(lead) {
                if lead.compare(heading, options: .caseInsensitive) == .orderedSame {
                    collecting = true
                    let after = line.drop(while: { $0 != ":" }).dropFirst()
                    collected.append(String(after))
                    continue
                } else if collecting {
                    break
                }
            }
            if collecting { collected.append(raw) }
        }
        return collected.joined(separator: "\n")
    }
}
