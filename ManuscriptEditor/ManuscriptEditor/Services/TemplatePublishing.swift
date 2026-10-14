// TemplatePublishing.swift
//
// Templates have a shared home: the app's own repository, under
// `ManuscriptEditor/JournalProfiles/<slug>/`, where the bundled corpus lives
// and is reviewed.  This is the app's side of it.
//
//   Check     — fetch the published copy of a template (by its slug, the
//               folder name a name and type derive) and compare it with the
//               copy in hand, part by part.  The GUID has to match too: a
//               folder that holds a different GUID is somebody else's
//               template under the same name.
//   Load      — take the published copy.
//   Propose   — write the template's files to a branch (in the repository
//               when the token may push, in a fork of it otherwise) and open
//               a pull request.  Never a merge: a template that every
//               install seeds from is reviewed before it changes.
//
// Reads need no token (the repository is public); a token lifts the rate
// limit, and proposing needs one.  Nothing here touches the Keychain on its
// own: the token comes from the account the caller chose.

import Foundation

@MainActor
@Observable
final class TemplatePublishing {

    static let shared = TemplatePublishing()

    /// Where templates are published.  The folder is the bundled corpus,
    /// so a merged proposal ships with the next release.
    static let owner = "mroumanos"
    static let repository = "ManuscriptEditor"
    static let branch = "main"
    static let folder = "ManuscriptEditor/JournalProfiles"

    static func url(forSlug slug: String) -> URL? {
        URL(string: "https://github.com/\(owner)/\(repository)/tree/\(branch)/\(folder)/\(slug)")
    }

    /// How a template in hand relates to its published copy.
    enum Status: Equatable {
        case unknown              // not checked, or the network didn't answer
        case checking
        case absent               // nothing published under this name and type
        case matches
        case differs(Set<ProfilePart>)
        case differentIdentity    // published under this name: another GUID

        /// What the warning icon says, or nil when there is nothing to warn about.
        var warning: String? {
            switch self {
            case .unknown, .checking, .matches:
                return nil
            case .absent:
                return "Not in the shared template repository — propose it from the template's Overview."
            case .differs(let parts):
                let names = ProfilePart.displayOrder.filter(parts.contains).map(\.label)
                return "Differs from the shared repository's copy: \(names.joined(separator: ", ")). Load the published copy from the template's Overview, or propose this one."
            case .differentIdentity:
                return "A different template is published under this name and type. Rename this one, or load the published copy."
            }
        }
    }

    private struct Checked { var status: Status; var at: Date; var checksum: String }
    private var checked: [UUID: Checked] = [:]
    private let service = GitHubBackendService()

    private init() {}

    // MARK: - Status

    func status(for template: JournalProfile) -> Status {
        checked[template.id]?.status ?? .unknown
    }

    /// The pure comparison — what the harness holds to its word.
    static func compare(_ mine: JournalProfile, published: JournalProfile?) -> Status {
        guard let published else { return .absent }
        guard published.id == mine.id else { return .differentIdentity }
        let parts = Set(ProfilePart.allCases.filter { mine.fingerprint($0) != published.fingerprint($0) })
        return parts.isEmpty ? .matches : .differs(parts)
    }

    /// Checks a template against its published copy, at most once every
    /// ten minutes unless forced.  A network failure leaves `.unknown`:
    /// no warning is better than a false one.
    func refresh(_ template: JournalProfile, token: String? = nil, force: Bool = false) {
        if !force, let last = checked[template.id], last.status != .unknown,
           last.checksum == template.checksum, Date().timeIntervalSince(last.at) < 600 { return }
        if checked[template.id]?.status == .checking { return }
        let checksum = template.checksum
        checked[template.id] = Checked(status: .checking, at: Date(), checksum: checksum)
        let id = template.id
        Task {
            let status: Status
            do {
                let published = try await self.published(slug: template.slug, token: token)
                status = Self.compare(template, published: published)
            } catch {
                status = .unknown
            }
            checked[id] = Checked(status: status, at: Date(), checksum: checksum)
        }
    }

    /// Forgets a template's status (after a load or a proposal).
    func invalidate(_ id: UUID) { checked[id] = nil }

    // MARK: - The published copy

    /// The template published under `slug`, or nil when there is none.
    func published(slug: String, token: String?) async throws -> JournalProfile? {
        var files: [ProfilePart: Data] = [:]
        for part in ProfilePart.allCases {
            if let data = try await service.fileContent(
                owner: Self.owner, repo: Self.repository,
                path: "\(Self.folder)/\(slug)/\(part.fileName)", ref: Self.branch, token: token) {
                files[part] = data
            }
            // Requirements carries the identity; without it there is no profile.
            if part == .requirements && files[.requirements] == nil { return nil }
        }
        return JournalProfile.decode(files: files, origin: .bundled,
                                     originURL: Self.url(forSlug: slug)?.absoluteString)
    }

    // MARK: - Proposing

    /// Writes the template to a branch and opens a pull request against the
    /// shared repository; returns the pull request's URL.
    func propose(_ template: JournalProfile, token: String, login: String) async throws -> URL {
        let files = try template.fileData()
        let branchName = "template/\(template.slug)"
        let base = try await service.headSHA(owner: Self.owner, repo: Self.repository,
                                             branch: Self.branch, token: token)

        // Where the branch lives: here when the token may push, else a fork.
        let pushable = try await service.canPush(owner: Self.owner, repo: Self.repository, token: token)
        let headOwner: String
        if pushable {
            headOwner = Self.owner
        } else {
            let forkName = try await service.fork(owner: Self.owner, repo: Self.repository, token: token)
            headOwner = String(forkName.split(separator: "/").first ?? Substring(login))
            // GitHub forks asynchronously; the fork answers once it exists.
            for _ in 0..<10 {
                if (try? await service.headSHA(owner: headOwner, repo: Self.repository,
                                               branch: Self.branch, token: token)) != nil { break }
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        try await service.createBranch(owner: headOwner, repo: Self.repository,
                                       name: branchName, sha: base, token: token)
        let config = GitHubBackendService.Config(owner: headOwner, repo: Self.repository,
                                                 branch: branchName, token: token)
        _ = try await service.push(
            files: ProfilePart.allCases.compactMap { part in
                files[part].map { GitHubBackendService.File(path: "\(Self.folder)/\(template.slug)/\(part.fileName)", data: $0) }
            },
            message: "Template: \(template.displayName) v\(template.version)",
            config: config)
        let body = """
        Proposed from Manuscript Editor by @\(login).

        Template: **\(template.displayName)**
        Identity: `\(template.id.uuidString.lowercased())` (v\(template.version))
        Source: \(template.requirements.url.isEmpty ? "—" : template.requirements.url)

        Files under `\(Self.folder)/\(template.slug)/`: \(files.keys.map(\.fileName).sorted().joined(separator: ", ")).
        """
        return try await service.createPullRequest(
            owner: Self.owner, repo: Self.repository,
            title: "Template: \(template.displayName)", body: body,
            head: pushable ? branchName : "\(headOwner):\(branchName)",
            base: Self.branch, token: token)
    }
}
