// TemplateFile.swift
//
// A journal template as ONE file: `<slug>.journaltemplate.json`.
//
// A template is four JSON files in a folder, which is the right shape on disk
// and the wrong shape to send someone.  This is the same four parts in one
// document, carrying the GUID, the version and the checksum, so the receiving
// end can answer the only two questions that matter: *is this one I already
// have?* and *what is different about it?*
//
// IMPORT RESOLVES BY GUID
// ─────────────────────────────────────────────────────────────────────────────
//   unknown GUID  → a new template
//   known GUID    → the same template, later (or earlier): the parts that
//                   differ are named before anything is overwritten
//   descends from → someone's modified copy of one you hold
//
// CONTRIBUTING UPSTREAM
// ─────────────────────────────────────────────────────────────────────────────
// The app's own corpus is a folder per template under
// `ManuscriptEditor/JournalProfiles/`, so a contribution is a pull request
// adding or changing one folder.  `writeFolder` writes exactly that layout,
// which is why the export offers both shapes: one file to send a person, one
// folder to open a PR with.
//
// See MasterContext/features/journal-templates.md §3.7.

import Foundation
import UniformTypeIdentifiers

enum TemplateFile {

    /// The extension a shared template carries.  Double-barrelled on purpose:
    /// it is a JSON file, and every editor should still open it as one.
    static let fileExtension = "journaltemplate.json"

    static func fileName(for template: JournalTemplate) -> String {
        let slug = template.slug.isEmpty ? template.id.uuidString.lowercased() : template.slug
        return "\(slug).\(fileExtension)"
    }

    // MARK: - The document

    /// The wire format.  Flat, four parts, and self-describing — a file whose
    /// first line says what it is can be identified without a file extension.
    struct Document: Codable, Sendable {
        var format: String = Document.marker
        var formatVersion: Int = 1
        /// Who exported it, when they say so — free text, never an account.
        var exportedBy: String?
        var exportedAt: Date?
        /// The whole-template checksum at export time; a receiver compares it
        /// with the one it computes to know the file arrived intact.
        var checksum: String?

        var requirements: RequirementsDoc
        var checks: ChecksDoc
        var structure: StructureDoc
        var export: ExportConfig?

        static let marker = "manuscript-editor/journal-template"
    }

    // MARK: - Writing

    static func document(for template: JournalTemplate, exportedBy: String?) -> Document {
        Document(exportedBy: exportedBy?.isEmpty == false ? exportedBy : nil,
                 exportedAt: Date(),
                 checksum: template.checksum,
                 requirements: template.requirementsDocForWriting,
                 checks: template.checksDoc,
                 structure: template.structureDoc,
                 export: template.export)
    }

    static func data(for template: JournalTemplate, exportedBy: String? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document(for: template, exportedBy: exportedBy))
    }

    /// Writes the single-file form.
    @discardableResult
    static func write(_ template: JournalTemplate, to url: URL,
                      exportedBy: String? = nil) -> String? {
        do {
            try data(for: template, exportedBy: exportedBy).write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Writes the repository layout — `<folder>/<slug>/{requirements,checks,
    /// structure,export}.json` — which is what a pull request against the
    /// app's corpus adds.
    /// The failure a share can hit, as a message worth showing.
    struct Failure: Error { let message: String }

    @discardableResult
    static func writeFolder(_ template: JournalTemplate, into parent: URL) -> Result<URL, Failure> {
        let slug = template.slug.isEmpty ? template.id.uuidString.lowercased() : template.slug
        let folder = parent.appendingPathComponent(slug, isDirectory: true)
        guard template.write(to: folder) else {
            return .failure(Failure(message: "Couldn't write \(slug) into \(parent.lastPathComponent)."))
        }
        return .success(folder)
    }

    // MARK: - Reading

    /// Reads a shared template file.  Tolerates a plain four-part document
    /// without the marker, since that is what hand-assembly produces.
    static func read(_ url: URL) -> Result<JournalTemplate, Failure> {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(Failure(message: "Couldn't read \(url.lastPathComponent)."))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data) else {
            return .failure(Failure(message: "\(url.lastPathComponent) isn't a journal template file."))
        }
        guard document.format == Document.marker || document.format.isEmpty else {
            return .failure(Failure(message: "\(url.lastPathComponent) says it is “\(document.format)”, not a journal template."))
        }
        return .success(template(from: document))
    }

    static func template(from document: Document) -> JournalTemplate {
        let req = document.requirements
        return JournalTemplate(
            id: req.id, name: req.journal, articleType: req.articleType,
            lineage: req.lineage,
            requirements: SourceRequirements(url: req.url, bullets: req.bullets,
                                             editedAt: req.updatedAt),
            checks: document.checks.checks,
            structure: JournalStructure(sections: document.structure.sections,
                                        coreFormats: document.structure.coreFormats,
                                        documentFormat: document.structure.documentFormat),
            export: document.export,
            origin: .library, updatedAt: req.updatedAt,
            version: req.version, partChecksums: req.partChecksums)
    }

    // MARK: - Resolving an import

    /// What importing this file would do, decided by GUID and then by lineage
    /// — never by name, which is the one thing that legitimately changes.
    enum Resolution: Equatable {
        /// Nothing in the library relates to it.
        case new
        /// The library holds this GUID; these parts differ (empty = identical).
        case replaces(name: String, parts: Set<ProfilePart>, fromVersion: Int, toVersion: Int)
        /// A modified copy of something in the library, under its own GUID.
        case branchOf(name: String, parts: Set<ProfilePart>)

        var isDestructive: Bool {
            if case .replaces(_, let parts, _, _) = self { return !parts.isEmpty }
            return false
        }
    }

    static func resolve(_ incoming: JournalTemplate,
                        in library: JournalProfileLibrary) -> Resolution {
        func differences(_ mine: JournalTemplate) -> Set<ProfilePart> {
            Set(ProfilePart.allCases.filter { mine.fingerprint($0) != incoming.fingerprint($0) })
        }
        if let mine = library.profile(id: incoming.id) {
            return .replaces(name: mine.displayName, parts: differences(mine),
                             fromVersion: mine.version, toVersion: incoming.version)
        }
        for ancestorID in incoming.lineage {
            if let ancestor = library.profile(id: ancestorID) {
                return .branchOf(name: ancestor.displayName, parts: differences(ancestor))
            }
        }
        return .new
    }
}
