// JournalProfileLibrary.swift
//
// The user's journal requirements library: their own copy of every journal
// profile, at
//
//   ~/Library/Application Support/ManuscriptEditor/JournalLibrary/<slug>/
//       requirements.json  checks.json  structure.json
//
// It is seeded from the profiles the app ships and then belongs to the user —
// editing a journal in one manuscript never reaches back into it; that only
// happens through "Save to Library".
//
// This is the reference a manuscript's own copy is COMPARED against.  A
// manuscript carries its profiles so it opens the same way on someone else's
// machine; the library is what this machine considers correct.  Where the two
// disagree, the Checks pane says so rather than silently picking one.

import Foundation

@MainActor
@Observable
final class JournalProfileLibrary {

    static let shared = JournalProfileLibrary()

    /// Every profile in the library, keyed by GUID.  Read once and kept in
    /// memory: the Checks pane compares against it on every keystroke.
    private(set) var profiles: [UUID: JournalProfile] = [:]

    private init() {}

    // MARK: - Location

    var root: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support
            .appendingPathComponent("ManuscriptEditor", isDirectory: true)
            .appendingPathComponent("JournalLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The folder a profile lives in.  Identity is the GUID, so an existing
    /// folder holding that GUID is reused whatever it is called; otherwise
    /// the slug, suffixed if a DIFFERENT profile already claimed it.
    func folder(for profile: JournalProfile) -> URL {
        if let existing = folderURLs().first(where: {
            JournalProfile.read(from: $0, origin: .library)?.id == profile.id
        }) { return existing }

        var candidate = profile.slug.isEmpty ? profile.id.uuidString.lowercased() : profile.slug
        var attempt = 1
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            attempt += 1
            candidate = "\(profile.slug)-\(attempt)"
        }
        return root.appendingPathComponent(candidate, isDirectory: true)
    }

    private func folderURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            ?? []
    }

    // MARK: - Loading

    /// Reads the library, first copying in any profile the app ships that
    /// isn't there yet.  Called once at launch; newly shipped journals reach
    /// existing installs the same way.
    func load() {
        var loaded: [UUID: JournalProfile] = [:]
        for folder in folderURLs() {
            guard let profile = JournalProfile.read(from: folder, origin: .library,
                                                    originURL: folder.path)
            else { continue }
            loaded[profile.id] = profile
        }
        for (id, var bundled) in JournalProfile.bundled() where loaded[id] == nil {
            bundled.origin = .library
            let destination = root.appendingPathComponent(bundled.slug, isDirectory: true)
            if bundled.write(to: destination) {
                bundled.originURL = destination.path
                loaded[id] = bundled
            }
        }
        profiles = loaded
    }

    // MARK: - Lookup

    func profile(id: UUID) -> JournalProfile? { profiles[id] }

    /// The library entry for a journal by NAME — the fallback when a
    /// manuscript's profile carries a GUID this library has never seen.
    func profile(name: String, articleType: String?) -> JournalProfile? {
        let wanted = JournalProfile.slug(name: name, articleType: articleType)
        return profiles.values.first { $0.slug == wanted }
    }

    // MARK: - Saving

    /// Writes a profile into the library, replacing whatever shared its GUID.
    @discardableResult
    func save(_ profile: JournalProfile) -> Bool {
        var stored = profile
        stored.origin = .library
        stored.updatedAt = Date()
        let destination = folder(for: stored)
        guard stored.write(to: destination) else { return false }
        stored.originURL = destination.path
        profiles[stored.id] = stored
        return true
    }

    /// Removes a profile from the library entirely.
    func remove(id: UUID) {
        guard let profile = profiles[id] else { return }
        try? FileManager.default.removeItem(at: folder(for: profile))
        profiles[id] = nil
    }
}

// MARK: - Comparison

/// How a manuscript's copy of a profile relates to the user's library.
enum ProfileLibraryStatus: Equatable {
    /// Same GUID, identical content in every part.
    case matches
    /// Same GUID, but these parts differ from the library's copy.
    case differs(Set<ProfilePart>)
    /// This GUID isn't in the library, but a profile with the same name is —
    /// saving offers to overwrite that one.
    case nameMatchDifferentID(UUID)
    /// Neither the GUID nor the name is in the library — saving is a net add.
    case absent

    /// The parts to flag with a warning.  A profile the library has never
    /// seen flags all three, since none of it is in the library yet.
    var flaggedParts: Set<ProfilePart> {
        switch self {
        case .matches:                 return []
        case .differs(let parts):      return parts
        case .nameMatchDifferentID,
             .absent:                  return Set(ProfilePart.allCases)
        }
    }

    /// Whether Save to Library has anything to do.
    var canSave: Bool { self != .matches }

    /// What the save button should say.
    var saveVerb: String {
        switch self {
        case .matches:              return "Saved to Library"
        case .differs:              return "Update Library"
        case .nameMatchDifferentID: return "Replace in Library…"
        case .absent:               return "Add to Library"
        }
    }
}

extension JournalProfileLibrary {

    /// Compares a manuscript's profile against the library, by GUID first and
    /// by name second — the three cases Save to Library has to handle.
    func status(of theirs: JournalProfile) -> ProfileLibraryStatus {
        if let mine = profiles[theirs.id] {
            let differing = ProfilePart.allCases.filter {
                mine.fingerprint($0) != theirs.fingerprint($0)
            }
            return differing.isEmpty ? .matches : .differs(Set(differing))
        }
        if let sameName = profile(name: theirs.name, articleType: theirs.articleType) {
            return .nameMatchDifferentID(sameName.id)
        }
        return .absent
    }
}
