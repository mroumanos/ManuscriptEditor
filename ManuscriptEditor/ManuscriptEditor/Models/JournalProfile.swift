// JournalProfile.swift
//
// A journal's configuration is THREE files in one folder:
//
//   <slug>/requirements.json   the journal's own instructions, as bullets,
//                              plus a link to the page they came from
//   <slug>/checks.json         the executable rules (automatic and manual)
//   <slug>/structure.json      the sections a manuscript for this journal
//                              starts with — and that checks verify
//
// Splitting them means a diff shows WHICH half changed, and the Checks pane
// can flag "your copy of the checks differs from your library" without
// implying the requirements moved too.
//
// IDENTITY
// ─────────────────────────────────────────────────────────────────────────
// A profile is identified by a GUID, not by its name: one journal can carry
// several profiles (Nature "Article" vs "Letter"), and a rename must not
// orphan a manuscript's copy.  The GUID is what maps a manuscript's journal
// to an entry in the user's library, and what comparisons run on.
//
// PROVENANCE
// ─────────────────────────────────────────────────────────────────────────
// Three places hold profiles, in order of authority for a given manuscript:
//
//   bundled     ships with the app (`JournalProfiles/<slug>/`, on GitHub)
//   library     the user's own copy (Application Support), seeded from
//               bundled on first run and updated via Save to Library
//   manuscript  the copy that TRAVELS with the manuscript
//               (`journals/<slug>/`), so a collaborator opening it gets the
//               same rules the author used
//
// The manuscript's copy always wins for evaluation.  When it differs from
// the library's, the Checks pane marks the part that differs and offers to
// save it back.

import Foundation
import CryptoKit

// MARK: - ProfilePart

/// One of the three files a profile is made of.  Comparison, warnings, and
/// the Checks pane's cards are all per-part.
enum ProfilePart: String, Codable, CaseIterable, Sendable {
    case requirements, checks, structure

    var fileName: String { "\(rawValue).json" }

    var label: String {
        switch self {
        case .requirements: return "Requirements"
        case .checks:       return "Checks"
        case .structure:    return "Structure"
        }
    }
}

// MARK: - SourceRequirements

/// The journal's own submission instructions: a link plus the distilled
/// bullets.  Bulleted rather than free prose because that is how journals
/// publish them and how they are read — one rule per line, editable.
struct SourceRequirements: Codable, Sendable, Equatable {

    /// The journal's author-instructions page.
    var url: String = ""

    /// One requirement per bullet, in the journal's own terms.
    var bullets: [String] = []

    /// When this was last edited in this manuscript.
    var editedAt: Date? = nil

    var isEmpty: Bool {
        url.trimmingCharacters(in: .whitespaces).isEmpty && bullets.isEmpty
    }

    /// The bullets as editable plain text — one per line.  Pasted bullet
    /// characters are stripped, so pasting from a journal's page does the
    /// obvious thing.
    var text: String {
        get { bullets.joined(separator: "\n") }
        set {
            bullets = newValue
                .components(separatedBy: .newlines)
                .map { line -> String in
                    var trimmed = line.trimmingCharacters(in: .whitespaces)
                    while let first = trimmed.first, "-•*–—".contains(first) {
                        trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    }
                    return trimmed
                }
                .filter { !$0.isEmpty }
        }
    }

    private enum CodingKeys: String, CodingKey { case url, bullets, summary, editedAt }

    init(url: String = "", bullets: [String] = [], editedAt: Date? = nil) {
        self.url = url; self.bullets = bullets; self.editedAt = editedAt
    }

    /// Files written before requirements were bulleted carry a `summary`
    /// paragraph; split it into bullets so nothing is lost.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
        if let list = try c.decodeIfPresent([String].self, forKey: .bullets) {
            bullets = list
        } else if let summary = try c.decodeIfPresent(String.self, forKey: .summary) {
            bullets = summary
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            bullets = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(bullets, forKey: .bullets)
        try c.encodeIfPresent(editedAt, forKey: .editedAt)
    }
}

// MARK: - JournalStructure

/// One prose section a manuscript for this journal is expected to have.
///
/// Only the CONFIGURABLE sections live here.  The fixed parts of a manuscript
/// — title, authors, abstract, keywords, figures, tables, bibliography, cover
/// letter — come with every manuscript regardless of journal, so a structure
/// file has nothing to say about them.
struct StructureSection: Codable, Sendable, Equatable, Identifiable {
    var title: String
    /// Required sections fail a structure check when missing; optional ones
    /// are part of the journal's shape but never fail.
    var required: Bool = true
    /// Why the journal asks for it — shown in the structure editor.
    var note: String? = nil

    /// Set when this entry came from a file that also listed the app's fixed
    /// parts.  Those are dropped on read and never written again; the flag
    /// exists only so the filtering can happen at one place.
    var isFixedPart: Bool = false

    var id: String { title.lowercased() }

    private enum CodingKeys: String, CodingKey { case title, required, note, kind, core }

    init(title: String, required: Bool = true, note: String? = nil) {
        self.title = title; self.required = required; self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note)
        isFixedPart = (try? c.decodeIfPresent(String.self, forKey: .kind)) == "core"
            || (try? c.decodeIfPresent(String.self, forKey: .core)) != nil
    }

    /// `isFixedPart` is deliberately absent: it is a read-time concern, and
    /// encoding it would change every profile's fingerprint.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(required, forKey: .required)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

/// The configurable sections a manuscript for this journal is expected to
/// have, in order.
struct JournalStructure: Codable, Sendable, Equatable {
    var sections: [StructureSection] = []

    var isEmpty: Bool { sections.isEmpty }
    var requiredTitles: [String] { sections.filter(\.required).map(\.title) }

    init(sections: [StructureSection] = []) {
        self.sections = StructureSection.configurable(sections)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = StructureSection.configurable(
            try c.decodeIfPresent([StructureSection].self, forKey: .sections) ?? [])
    }
}

extension StructureSection {
    /// Drops entries describing the app's fixed parts.
    static func configurable(_ sections: [StructureSection]) -> [StructureSection] {
        sections.filter { !$0.isFixedPart }
    }
}

// MARK: - The three documents

/// `requirements.json`
struct RequirementsDoc: Codable, Sendable, Equatable {
    var id: UUID
    var journal: String
    var articleType: String? = nil
    /// The profiles this one was branched from, nearest ancestor first.
    /// Lineage rather than identity: it survives sharing, so a collaborator
    /// whose library holds ANY ancestor — not just the immediate one — is
    /// told this is a MODIFIED version of what they have, rather than an
    /// unrelated journal.
    var lineage: [UUID] = []
    var url: String = ""
    var bullets: [String] = []
    var updatedAt: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case id, journal, articleType, lineage, derivedFrom, url, bullets, updatedAt
    }

    init(id: UUID, journal: String, articleType: String? = nil, lineage: [UUID] = [],
         url: String = "", bullets: [String] = [], updatedAt: Date? = nil) {
        self.id = id; self.journal = journal; self.articleType = articleType
        self.lineage = lineage; self.url = url; self.bullets = bullets
        self.updatedAt = updatedAt
    }

    /// Tolerates the single-parent `derivedFrom` written by the first cut of
    /// profile lineage.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        journal = try c.decode(String.self, forKey: .journal)
        articleType = try c.decodeIfPresent(String.self, forKey: .articleType)
        if let chain = try? c.decodeIfPresent([UUID].self, forKey: .lineage) {
            lineage = chain ?? []
        } else {
            lineage = []
        }
        if lineage.isEmpty, let parent = try? c.decodeIfPresent(UUID.self, forKey: .derivedFrom) {
            lineage = [parent]
        }
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        bullets = try c.decodeIfPresent([String].self, forKey: .bullets) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(journal, forKey: .journal)
        try c.encodeIfPresent(articleType, forKey: .articleType)
        if !lineage.isEmpty { try c.encode(lineage, forKey: .lineage) }
        try c.encode(url, forKey: .url)
        try c.encode(bullets, forKey: .bullets)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

/// `checks.json`
struct ChecksDoc: Codable, Sendable, Equatable {
    var id: UUID
    var journal: String
    var checks: [CheckRule] = []
    var updatedAt: Date? = nil
}

/// `structure.json`
struct StructureDoc: Codable, Sendable, Equatable {
    var id: UUID
    var journal: String
    var sections: [StructureSection] = []
    var updatedAt: Date? = nil
}

// MARK: - JournalProfile

/// The three files, read into one value.
struct JournalProfile: Codable, Identifiable, Sendable, Equatable {

    /// Where a profile's configuration lives.
    enum Origin: String, Codable, Sendable {
        /// Ships with the app (`JournalProfiles/<slug>/`).
        case bundled
        /// The user's own library (Application Support).
        case library
        /// Edited here, so it travels with the manuscript
        /// (`journals/<slug>/`).
        case manuscript

        var label: String {
            switch self {
            case .bundled:    return "App defaults"
            case .library:    return "Your library"
            case .manuscript: return "This manuscript"
            }
        }
    }

    /// The GUID.  Stable across renames; this is what maps a manuscript's
    /// journal to a library entry.
    var id: UUID
    var name: String
    var articleType: String?

    /// The profiles this one was branched from — see `RequirementsDoc`.
    var lineage: [UUID] = []

    /// The immediate ancestor, when there is one.
    var derivedFrom: UUID? { lineage.first }

    var requirements: SourceRequirements = SourceRequirements()
    var checks: [CheckRule] = []
    var structure: JournalStructure = JournalStructure()

    var origin: Origin = .bundled
    /// Link to where this configuration came from, when it has one.
    var originURL: String? = nil
    var updatedAt: Date? = nil

    var displayName: String { articleType.map { "\(name) — \($0)" } ?? name }

    /// Folder name — human-readable, so the files stay browsable on GitHub
    /// and on disk.  Identity is the GUID; this is only the address.
    var slug: String { JournalProfile.slug(name: name, articleType: articleType) }

    init(id: UUID, name: String, articleType: String? = nil,
         lineage: [UUID] = [],
         requirements: SourceRequirements = SourceRequirements(),
         checks: [CheckRule] = [], structure: JournalStructure = JournalStructure(),
         origin: Origin = .bundled, originURL: String? = nil, updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.articleType = articleType
        self.lineage = lineage
        self.requirements = requirements; self.checks = checks; self.structure = structure
        self.origin = origin; self.originURL = originURL; self.updatedAt = updatedAt
    }

    // MARK: Slug and GUID

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

    /// The GUID the app ships for a given slug.  Derived FROM the slug so
    /// every install agrees on it without a registry, and so a profile the
    /// app ships keeps its identity across releases.
    static func bundledID(slug: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(slug.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version-5 shaped
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: Documents

    var requirementsDoc: RequirementsDoc {
        RequirementsDoc(id: id, journal: name, articleType: articleType,
                        lineage: lineage,
                        url: requirements.url, bullets: requirements.bullets,
                        updatedAt: updatedAt)
    }
    var checksDoc: ChecksDoc {
        ChecksDoc(id: id, journal: name, checks: checks, updatedAt: updatedAt)
    }
    var structureDoc: StructureDoc {
        StructureDoc(id: id, journal: name, sections: structure.sections, updatedAt: updatedAt)
    }

    /// The content signature of one part — what "differs from your library"
    /// is decided on.  Ignores identifiers and timestamps, so re-saving an
    /// unchanged profile never lights the warning.
    func fingerprint(_ part: ProfilePart) -> String {
        switch part {
        case .requirements: return ProfileFingerprint.of(requirementsDoc)
        case .checks:       return ProfileFingerprint.of(checksDoc)
        case .structure:    return ProfileFingerprint.of(structureDoc)
        }
    }

    // MARK: Reading and writing a folder

    static func read(from folder: URL, origin: Origin, originURL: String? = nil) -> JournalProfile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func load<T: Decodable>(_ part: ProfilePart, as type: T.Type) -> T? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(part.fileName))
            else { return nil }
            return try? decoder.decode(type, from: data)
        }
        // Requirements carries the identity, so it is the one file a profile
        // cannot do without.
        guard let req = load(.requirements, as: RequirementsDoc.self) else { return nil }
        return JournalProfile(
            id: req.id, name: req.journal, articleType: req.articleType,
            lineage: req.lineage,
            requirements: SourceRequirements(url: req.url, bullets: req.bullets,
                                             editedAt: req.updatedAt),
            checks: load(.checks, as: ChecksDoc.self)?.checks ?? [],
            structure: JournalStructure(sections: load(.structure, as: StructureDoc.self)?.sections ?? []),
            origin: origin, originURL: originURL, updatedAt: req.updatedAt
        )
    }

    /// Writes all three files, creating the folder.  Returns false if any
    /// write fails, so a caller can report rather than silently drop edits.
    @discardableResult
    func write(to folder: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(requirementsDoc)
                .write(to: folder.appendingPathComponent(ProfilePart.requirements.fileName), options: .atomic)
            try encoder.encode(checksDoc)
                .write(to: folder.appendingPathComponent(ProfilePart.checks.fileName), options: .atomic)
            try encoder.encode(structureDoc)
                .write(to: folder.appendingPathComponent(ProfilePart.structure.fileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Bundled defaults

    static let bundledFolder = "JournalProfiles"

    /// The canonical GitHub link for a bundled profile's folder.
    static func bundledURL(slug: String) -> String {
        "https://github.com/mroumanos/ManuscriptEditor/tree/main/ManuscriptEditor/JournalProfiles/\(slug)"
    }

    /// Every profile shipped with the app, keyed by GUID.
    ///
    /// `JournalProfiles` is a FOLDER REFERENCE in the target, not part of the
    /// synchronized source group: a synchronized group flattens resources
    /// into `Contents/Resources`, where seventeen files named
    /// `requirements.json` collide and the build fails outright (verified).
    static func bundled(in bundle: Bundle = .containingCode) -> [UUID: JournalProfile] {
        guard let root = bundle.url(forResource: bundledFolder, withExtension: nil),
              let folders = try? FileManager.default.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [:] }
        var out: [UUID: JournalProfile] = [:]
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let profile = read(from: folder, origin: .bundled,
                                     originURL: bundledURL(slug: folder.lastPathComponent))
            else { continue }
            out[profile.id] = profile
        }
        return out
    }

    /// The profile shipped for a journal, matched by name + article type.
    static func bundled(name: String, articleType: String?) -> JournalProfile? {
        let wanted = slug(name: name, articleType: articleType)
        return bundled().values.first { $0.slug == wanted }
    }
}

// MARK: - ProfileFingerprint

/// Content signatures for profile documents.
///
/// Comparing decoded values directly would be wrong: `CheckRule` mints a
/// fresh UUID for any hand-written rule that omits one, so the same file read
/// twice is never equal to itself.  The fingerprint strips identifiers and
/// timestamps and hashes what remains, which is what the user means by
/// "different".
enum ProfileFingerprint {

    private static let ignored: Set<String> = [
        "id", "derivedFrom", "lineage", "journal", "articleType", "updatedAt", "editedAt",
    ]

    static func of(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(withJSONObject: strip(object),
                                                          options: [.sortedKeys, .fragmentsAllowed])
        else { return "" }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    private static func strip(_ object: Any) -> Any {
        if let dict = object as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict where !ignored.contains(key) {
                out[key] = strip(value)
            }
            return out
        }
        if let array = object as? [Any] { return array.map(strip) }
        return object
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
