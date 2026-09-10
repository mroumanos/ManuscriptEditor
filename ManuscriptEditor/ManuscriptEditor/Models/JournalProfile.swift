// JournalProfile.swift
//
// A journal **template**: the reusable configuration a manuscript's journal is
// created from, and compared against afterwards.
//
// A journal in a manuscript is an INSTANCE — it has its own name ("BMJ test
// 1"), its own content, and its own copy of the rules.  The template is what
// it was cut from, identified by GUID and by a CHECKSUM of its contents, so a
// manuscript can say "this came from BMJ, and I have edited it since" even
// after either side is renamed.  See `Journal.templateID` / `templateChecksum`.
//
// A template's configuration is FOUR files in one folder:
//
//   <slug>/requirements.json   the journal's own instructions, as bullets,
//                              plus a link to the page they came from
//   <slug>/checks.json         the executable rules (automatic and manual)
//   <slug>/structure.json      the sections a manuscript for this journal
//                              starts with — and that checks verify
//   <slug>/export.json         the export outline and its formatting
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
/// A journal template, in the words the app uses for it.  The type keeps its
/// original name so the on-disk format and every existing file stay valid.
typealias JournalTemplate = JournalProfile

enum ProfilePart: String, Codable, CaseIterable, Sendable, Identifiable {
    var id: String { rawValue }

    case requirements, checks, structure
    /// The export outline and its formatting.  Part of the profile since Sep
    /// 2026: it used to be saved into a second, parallel library from the
    /// Export pane, which is why a profile saved under a new name never showed
    /// up when adding a journal.  One library, one save.
    case export

    var fileName: String { "\(rawValue).json" }

    /// What the user calls it.  The raw values stay `requirements`/`checks`
    /// because they are the file names on disk, but "Summary" and "Tests" are
    /// what these things actually are: a distilled summary of the journal's
    /// instructions, and the tests that decide whether a cut satisfies them.
    var label: String {
        switch self {
        case .requirements: return "Summary"
        case .checks:       return "Tests"
        // "Content", not "Structure": it carries the sections, what goes in
        // them, how they are set, and the questions a venue asks — a list of
        // headings was only ever the smallest part of it.
        case .structure:    return "Content"
        case .export:       return "Export"
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
    ///
    /// Bullets are written in **standard categories** — `description:`,
    /// `limits:`, `components:`, `format:`, `extra:` — so a summary reads the
    /// same way for every journal and the interesting half (the limits) can be
    /// found without reading the prose.  The prefix is a convention, not a
    /// schema: a bullet without one still shows, ungrouped.
    var bullets: [String] = []

    /// When this was last edited in this manuscript.
    var editedAt: Date? = nil

    var isEmpty: Bool {
        url.trimmingCharacters(in: .whitespaces).isEmpty && bullets.isEmpty
    }

    // MARK: - Categories

    /// The standard categories, in the order a summary reads best: what this
    /// format is, what it caps, what it is made of, how it is laid out, and
    /// what else decides whether it is taken.
    static let categoryOrder = ["description", "limits", "components", "format", "extra"]

    /// Splits a bullet into its category and its text.
    static func category(of bullet: String) -> (category: String?, text: String) {
        guard let colon = bullet.firstIndex(of: ":") else { return (nil, bullet) }
        let head = String(bullet[bullet.startIndex..<colon]).lowercased()
        guard categoryOrder.contains(head) else { return (nil, bullet) }
        let rest = bullet[bullet.index(after: colon)...]
        return (head, String(rest).trimmingCharacters(in: .whitespaces))
    }

    /// How many bullets sit in each category, for the one-line detail.
    static func categoryCounts(_ bullets: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for bullet in bullets {
            if let key = category(of: bullet).category { counts[key, default: 0] += 1 }
        }
        return counts
    }

    /// The bullets grouped for display, categories first in standard order,
    /// then anything uncategorised.
    static func grouped(_ bullets: [String]) -> [(category: String?, items: [String])] {
        var out: [(String?, [String])] = []
        for key in categoryOrder {
            let items = bullets.compactMap { bullet -> String? in
                let parsed = category(of: bullet)
                return parsed.category == key ? parsed.text : nil
            }
            if !items.isEmpty { out.append((key, items)) }
        }
        let loose = bullets.filter { category(of: $0).category == nil }
        if !loose.isEmpty { out.append((nil, loose)) }
        return out
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

/// One submission question as a template carries it.
///
/// Not a `QuestionEntry`: that one has an id and an answer, which belong to a
/// manuscript.  A template carries the question and its limit — the parts that
/// are the journal's, not the author's.
struct TemplateQuestion: Codable, Sendable, Equatable {
    var prompt: String
    var wordLimit: Int? = nil
    /// Words or characters — journals ask for both, so the template carries
    /// which one this question means.  nil = words.
    var limitUnit: QuestionEntry.LimitUnit? = nil
    /// A sample or starter answer, when the journal's instructions imply one.
    var sample: String? = nil
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
    /// Prose, or the journal's submission questions.  Recorded here so a
    /// journal that asks a set of questions brings them with it: forking to
    /// that journal adds the section already in question form.
    var kind: SectionKind = .text
    /// How this section must be WRITTEN at this venue, in words: the layout a
    /// title page needs, the headings a structured abstract uses, the order a
    /// venue expects an argument in.
    ///
    /// Distinct from `format`, which is typography the exporter applies. This
    /// is guidance a person — or a model — has to read and follow, and it goes
    /// into the fast-forward prompt for exactly that reason.
    var formatNote: String? = nil

    /// Why the journal asks for it, and anything else worth knowing.  Also
    /// sent when adapting, after the format.
    var note: String? = nil

    /// The section's SAMPLE CONTENT, carried by the template.
    ///
    /// A structure that only names sections says a journal wants a title page
    /// without saying what one looks like there.  The sample is the layout —
    /// the title block a venue expects, the boilerplate paragraph, the phrasing
    /// of a statement — so a journal cut from this template starts from
    /// something, not from an empty box.  Plain text: a template should carry
    /// wording, not one manuscript's typography.
    var sample: String? = nil

    /// How this section is FORMATTED on export at this venue — font, size,
    /// spacing, line and page numbers.
    ///
    /// A journal's shape is not only which sections exist: two venues can want
    /// the same sections set in different type.  Captured as the effective
    /// format (the item's override, or the document's), so a journal cut from
    /// this template adopts something concrete rather than inheriting whatever
    /// the new document happens to default to.
    var format: ExportDocumentFormat? = nil

    /// The journal's submission questions, for a `.questions` section.
    ///
    /// The questions ARE the requirement, so they belong to the template: cut
    /// a journal from it and the series arrives already asked, each with its
    /// word limit.
    var questions: [TemplateQuestion]? = nil

    /// Set when this entry came from a file that also listed the app's fixed
    /// parts.  Those are dropped on read and never written again; the flag
    /// exists only so the filtering can happen at one place.
    var isFixedPart: Bool = false

    var id: String { title.lowercased() }

    private enum CodingKeys: String, CodingKey {
        case title, required, note, kind, core, sample, questions, format, formatNote
    }

    init(title: String, required: Bool = true, kind: SectionKind = .text,
         note: String? = nil, sample: String? = nil,
         questions: [TemplateQuestion]? = nil,
         format: ExportDocumentFormat? = nil, formatNote: String? = nil) {
        self.title = title; self.required = required; self.kind = kind; self.note = note
        self.sample = sample; self.questions = questions; self.format = format
        self.formatNote = formatNote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note)
        sample = try c.decodeIfPresent(String.self, forKey: .sample)
        questions = try c.decodeIfPresent([TemplateQuestion].self, forKey: .questions)
        format = try c.decodeIfPresent(ExportDocumentFormat.self, forKey: .format)
        formatNote = try c.decodeIfPresent(String.self, forKey: .formatNote)
        // `kind` briefly meant "core"/"text" when structure files also listed
        // the app's fixed parts; anything but a section kind marks the entry
        // for dropping, and only "questions" changes what gets created.
        let rawKind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        isFixedPart = rawKind == "core" || (try? c.decodeIfPresent(String.self, forKey: .core)) != nil
        kind = rawKind.flatMap(SectionKind.init(rawValue:)) ?? .text
    }

    /// `isFixedPart` is deliberately absent: it is a read-time concern, and
    /// encoding it would change every profile's fingerprint.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(required, forKey: .required)
        if kind != .text { try c.encode(kind.rawValue, forKey: .kind) }
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(sample, forKey: .sample)
        try c.encodeIfPresent(questions, forKey: .questions)
        try c.encodeIfPresent(format, forKey: .format)
        try c.encodeIfPresent(formatNote, forKey: .formatNote)
    }
}

/// The configurable sections a manuscript for this journal is expected to
/// have, in order.
struct JournalStructure: Codable, Sendable, Equatable {
    var sections: [StructureSection] = []

    /// Export formatting for the app's FIXED parts — title page, byline,
    /// abstract, keywords, figures, tables, references, cover letter — keyed
    /// by `ExportItem.Kind`.
    ///
    /// The fixed parts are the same everywhere, but how a venue sets them is
    /// not, and that is exactly what a journal template should carry: fork a
    /// new journal and the title block, byline and abstract adopt the target's
    /// typography while their CONTENT copies over one for one.
    var coreFormats: [String: ExportDocumentFormat]? = nil

    /// The document-level format — page geometry (margins, columns) and the
    /// defaults everything inherits.
    var documentFormat: ExportDocumentFormat? = nil

    var isEmpty: Bool { sections.isEmpty }
    var requiredTitles: [String] { sections.filter(\.required).map(\.title) }

    init(sections: [StructureSection] = [],
         coreFormats: [String: ExportDocumentFormat]? = nil,
         documentFormat: ExportDocumentFormat? = nil) {
        self.sections = StructureSection.configurable(sections)
        self.coreFormats = coreFormats
        self.documentFormat = documentFormat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = StructureSection.configurable(
            try c.decodeIfPresent([StructureSection].self, forKey: .sections) ?? [])
        coreFormats = try c.decodeIfPresent([String: ExportDocumentFormat].self,
                                            forKey: .coreFormats)
        documentFormat = try c.decodeIfPresent(ExportDocumentFormat.self,
                                               forKey: .documentFormat)
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
    /// The export outline this journal expects.  nil = never configured, so
    /// the standard outline is derived instead.
    var export: ExportConfig? = nil

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
         export: ExportConfig? = nil,
         origin: Origin = .bundled, originURL: String? = nil, updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.articleType = articleType
        self.lineage = lineage
        self.requirements = requirements; self.checks = checks; self.structure = structure
        self.export = export
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
    /// One checksum over every part.
    ///
    /// This is what a manuscript stores when it adopts a template, and what
    /// tells it later that its copy has been edited — a comparison that must
    /// survive either side being renamed, so it deliberately covers the
    /// configuration and not the name.
    var checksum: String {
        ProfilePart.allCases.map { fingerprint($0) }.joined(separator: ":")
    }

    func fingerprint(_ part: ProfilePart) -> String {
        switch part {
        case .requirements: return ProfileFingerprint.of(requirementsDoc)
        case .checks:       return ProfileFingerprint.of(checksDoc)
        case .structure:    return ProfileFingerprint.of(structureDoc)
        // No outline and an empty outline are the same thing here, so a
        // journal that never configured one doesn't read as "differs".
        case .export:       return export.map { ProfileFingerprint.of($0) } ?? ""
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
            export: load(.export, as: ExportConfig.self),
            origin: origin, originURL: originURL, updatedAt: req.updatedAt
        )
    }

    /// Writes the profile's files, creating the folder.  Returns false if any
    /// write fails, so a caller can report rather than silently drop edits.
    ///
    /// `export.json` is written only when there is one: a journal that never
    /// had its outline configured should not gain an empty file that then
    /// reads as "differs from your library".
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
            let exportURL = folder.appendingPathComponent(ProfilePart.export.fileName)
            if let export {
                try encoder.encode(export).write(to: exportURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: exportURL)
            }
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
