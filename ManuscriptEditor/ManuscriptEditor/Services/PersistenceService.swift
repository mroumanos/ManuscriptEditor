// PersistenceService.swift
//
// Handles all file system I/O for manuscript data.
//
// DIRECTORY LAYOUT
// ─────────────────────────────────────────────────────────────────────────────
// Default (App Support) layout:
//   ~/Library/Application Support/ManuscriptEditor/
//     manuscripts/
//       {manuscript-uuid}/
//         manuscript.json
//         figures/
//           {figure-uuid}.png  …
//         data/
//           {asset-uuid}.sqlite  …
//           {asset-uuid}.png     …
//
// User-chosen folder layout (when the user picks a folder via NSOpenPanel):
//   {userPickedFolder}/
//     manuscript.json
//     figures/  …
//     data/     …
//
// The mapping from manuscript UUID → folder URL is persisted in UserDefaults:
//   "manuscriptFolder_{uuid}" → absolute path string
//   "allManuscriptIDs"        → JSON-encoded [String] of known manuscript UUIDs
//
// Security-scoped bookmarks allow the sandboxed app to retain write access
// across launches to user-chosen folders.

import Foundation

// MARK: - PersistenceService

struct PersistenceService: Sendable {

    // MARK: - Base directories

    /// Default root: `~/Library/Application Support/ManuscriptEditor/`
    private let defaultBase: URL

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        defaultBase = appSupport.appendingPathComponent("ManuscriptEditor", isDirectory: true)
        try? FileManager.default.createDirectory(at: manuscriptsURL, withIntermediateDirectories: true)
    }

    /// `…/ManuscriptEditor/manuscripts/`  (default storage for new manuscripts)
    var manuscriptsURL: URL {
        defaultBase.appendingPathComponent("manuscripts", isDirectory: true)
    }

    // MARK: - Per-manuscript directory resolution

    /// Returns the directory where this manuscript's files live.
    ///
    /// Priority: user-chosen folder (from UserDefaults) → default App Support path.
    func manuscriptDirectory(for id: UUID) -> URL {
        if let custom = customFolderURL(for: id) {
            return custom
        }
        let dir = manuscriptsURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Looks up the user-chosen folder URL from UserDefaults.
    /// Returns `nil` when no custom folder has been set.
    func customFolderURL(for id: UUID) -> URL? {
        let key = "manuscriptFolder_\(id.uuidString)"
        guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return FileManager.default.fileExists(atPath: path) ? url : nil
    }

    /// Stores `folderURL` as the custom save location for `id`.
    func setCustomFolder(_ folderURL: URL, for id: UUID) {
        let key = "manuscriptFolder_\(id.uuidString)"
        UserDefaults.standard.set(folderURL.path, forKey: key)
        addToKnownIDs(id)
    }

    // MARK: - Sub-directory helpers

    /// `{manuscriptDir}/figures/`
    func figuresDirectory(for manuscriptID: UUID) -> URL {
        let dir = manuscriptDirectory(for: manuscriptID).appendingPathComponent("figures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `{manuscriptDir}/data/`
    func dataDirectory(for manuscriptID: UUID) -> URL {
        let dir = manuscriptDirectory(for: manuscriptID).appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Full URL for a figure image file.
    func figureURL(fileName: String, manuscriptID: UUID) -> URL {
        figuresDirectory(for: manuscriptID).appendingPathComponent(fileName)
    }

    /// Full URL for a data asset file (SQLite or image).
    func dataFileURL(fileName: String, manuscriptID: UUID) -> URL {
        dataDirectory(for: manuscriptID).appendingPathComponent(fileName)
    }

    // MARK: - Save / Load

    /// Encodes `manuscript` to JSON and writes it atomically.
    ///
    /// Also updates the known-IDs index and `lastOpenedManuscriptID` in UserDefaults.
    func save(_ manuscript: Manuscript) throws {
        let dir = manuscriptDirectory(for: manuscript.id)
        let url = dir.appendingPathComponent("manuscript.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manuscript)
        try data.write(to: url, options: .atomic)
        UserDefaults.standard.set(manuscript.id.uuidString, forKey: "lastOpenedManuscriptID")
        addToKnownIDs(manuscript.id)
    }

    /// Saves `manuscript` to a user-specified folder and records the mapping.
    func save(_ manuscript: Manuscript, to folderURL: URL) throws {
        setCustomFolder(folderURL, for: manuscript.id)
        try save(manuscript)
    }

    /// Loads and decodes the manuscript with the given `id`.
    func load(id: UUID) -> Manuscript? {
        let url = manuscriptDirectory(for: id).appendingPathComponent("manuscript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manuscript.self, from: data)
    }

    // MARK: - Listing saved manuscripts

    /// Returns a summary of every known manuscript, sorted newest-first.
    func listManuscripts() -> [ManuscriptSummary] {
        // Collect from both the default directory and any custom-folder IDs.
        var ids: [UUID] = knownIDs()

        // Also scan the default manuscripts/ directory for older entries.
        if let dirs = try? FileManager.default.contentsOfDirectory(
            at: manuscriptsURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) {
            for dir in dirs {
                if let id = UUID(uuidString: dir.lastPathComponent), !ids.contains(id) {
                    ids.append(id)
                }
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ids.compactMap { id in
            let url = manuscriptDirectory(for: id).appendingPathComponent("manuscript.json")
            guard let data = try? Data(contentsOf: url),
                  let m = try? decoder.decode(Manuscript.self, from: data)
            else { return nil }
            return ManuscriptSummary(id: m.id, title: m.title, updatedAt: m.updatedAt,
                                     createdAt: m.createdAt,
                                     location: manuscriptDirectory(for: id))
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Figure file management

    /// Copies an image file into the manuscript's `figures/` folder.
    func importFigure(from sourceURL: URL, figureID: UUID, manuscriptID: UUID) throws -> String {
        let ext = sourceURL.pathExtension.lowercased()
        let fileName = "\(figureID.uuidString).\(ext)"
        let dest = figuresDirectory(for: manuscriptID).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return fileName
    }

    // MARK: - Known IDs index

    private func knownIDs() -> [UUID] {
        guard let raw = UserDefaults.standard.array(forKey: "allManuscriptIDs") as? [String]
        else { return [] }
        return raw.compactMap { UUID(uuidString: $0) }
    }

    /// Drops a manuscript from the known list and its custom-folder mapping
    /// (used after its files are trashed).
    func forget(id: UUID) {
        var existing = (UserDefaults.standard.array(forKey: "allManuscriptIDs") as? [String]) ?? []
        existing.removeAll { $0 == id.uuidString }
        UserDefaults.standard.set(existing, forKey: "allManuscriptIDs")
        UserDefaults.standard.removeObject(forKey: "manuscriptFolder_\(id.uuidString)")
    }

    private func addToKnownIDs(_ id: UUID) {
        var existing = (UserDefaults.standard.array(forKey: "allManuscriptIDs") as? [String]) ?? []
        let s = id.uuidString
        if !existing.contains(s) {
            existing.append(s)
            UserDefaults.standard.set(existing, forKey: "allManuscriptIDs")
        }
    }
}

// MARK: - ManuscriptSummary

/// Lightweight summary for the "Recent" list on the Welcome screen.
struct ManuscriptSummary: Identifiable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let createdAt: Date
    /// Where the project lives (app data or a user folder).
    let location: URL
}
