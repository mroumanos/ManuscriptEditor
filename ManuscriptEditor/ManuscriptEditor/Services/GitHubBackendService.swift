// GitHubBackendService.swift
//
// "Save to remote" / "Load from remote" against a GitHub repository — the
// first concrete backend (Phase II save-and-share; see MasterContext
// 05-features §K).  Account-free: the user supplies their own repository and
// a personal access token (stored in the Keychain, never in app files).
//
// PUSH — one commit per save, via the Git Data API:
//   1. GET  the branch ref (base commit), if the branch exists
//   2. POST a blob per file (base64)
//   3. POST a tree containing the blobs (base_tree = base commit's tree, so
//      files other than ours — README, LICENSE — are never touched)
//   4. POST a commit pointing at the tree
//   5. PATCH (or POST, first push) the branch ref to the commit
//
// PULL — GET the branch's tree recursively, download the blobs this app
// manages (manuscript.json, figures/, data/), and hand them to the caller to
// write into the manuscript folder.
//
// The service is deliberately synchronous-per-call (async/await, no state):
// the store decides when to push/pull and owns status reporting.

import Foundation

// MARK: - Errors

enum GitHubBackendError: LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m): return m
        case .http(let code, let m):
            switch code {
            case 401: return "GitHub rejected the token (401). Check the personal access token in Settings → Backend."
            case 404: return "Repository or branch not found (404). Check the \"owner/name\" repository and that the token can access it."
            default:  return "GitHub request failed (\(code)): \(m)"
            }
        case .badResponse(let m): return "Unexpected GitHub response: \(m)"
        }
    }
}

// MARK: - GitHubBackendService

struct GitHubBackendService {

    /// Everything needed to talk to one repository.
    struct Config {
        let owner: String
        let repo: String
        let branch: String
        let token: String

        /// The same repository, different branch (the app manages a fixed
        /// branch layout: main / source / journal-*).
        func with(branch newBranch: String) -> Config {
            Config(owner: owner, repo: repo, branch: newBranch, token: token)
        }

        /// Builds a config from a backend account + its Keychain token.
        /// The repository/branch are **per-manuscript** (ManuscriptSettings),
        /// falling back to legacy account-level fields.
        /// Throws a user-actionable message when anything is missing.
        static func from(account: BackendAccount,
                         repository: String? = nil,
                         branch: String? = nil) throws -> Config {
            guard account.provider == .github else {
                throw GitHubBackendError.notConfigured("The active account is \(account.provider.rawValue) — only GitHub is supported so far. Pick a GitHub account in Overview → Saving & Backend.")
            }
            let repoString = repository ?? account.repository ?? ""
            let parts = repoString.split(separator: "/").map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw GitHubBackendError.notConfigured("Set the repository as \"owner/name\" in Overview → Saving & Backend (or create one there).")
            }
            guard let token = KeychainService.secret(for: account.id), !token.isEmpty else {
                throw GitHubBackendError.notConfigured("No personal access token stored for \"\(account.displayName)\". Add one in Settings → Accounts.")
            }
            let effectiveBranch = branch ?? account.branch
            return Config(owner: parts[0], repo: parts[1],
                          branch: effectiveBranch?.isEmpty == false ? effectiveBranch! : "main",
                          token: token)
        }
    }

    // MARK: - Account-level operations (no repository required)

    /// Verifies a token by fetching the authenticated user; returns the login.
    func authenticatedLogin(token: String) async throws -> String {
        let user = try await rawRequest("GET", url: "https://api.github.com/user", token: token, body: nil)
        guard let login = user["login"] as? String else {
            throw GitHubBackendError.badResponse("no login in /user response")
        }
        return login
    }

    /// Creates a private repository for the authenticated user; returns
    /// ("owner/name", web URL).
    func createRepository(named name: String, token: String) async throws -> (fullName: String, htmlURL: URL) {
        let repo = try await rawRequest("POST", url: "https://api.github.com/user/repos", token: token, body: [
            "name": name,
            "private": true,
            "description": "Manuscript Editor project",
            "auto_init": false,
        ])
        guard let fullName = repo["full_name"] as? String,
              let html = repo["html_url"] as? String,
              let url = URL(string: html) else {
            throw GitHubBackendError.badResponse("repository creation returned no name/url")
        }
        return (fullName, url)
    }

    /// One file to push / pulled from the remote, path relative to the
    /// manuscript folder (e.g. "manuscript.json", "figures/x.png").
    struct File {
        let path: String
        let data: Data
    }

    // MARK: - Push

    /// Pushes `files` as a single commit; returns the new commit's short SHA.
    /// `attempt` guards the single self-retry on ref races (see step 5).
    func push(files: [File], message: String, config: Config, attempt: Int = 0) async throws -> String {
        // 1. Base commit (nil on a brand-new branch/empty repository).
        var (base, repoEmpty) = try await branchState(config: config)

        // A completely empty repository rejects the whole Git Data API with
        // 409 "Git Repository is empty." — bootstrap the initial commit
        // through the Contents API, then continue normally on top of it.
        // (Only for the EMPTY-repo case: a merely missing branch on a repo
        // with commits proceeds as a rootless commit + ref creation — the
        // Contents API can't write to a branch that doesn't exist.)
        if repoEmpty, let first = files.first {
            _ = try await request("PUT", "contents/\(first.path)", config: config, body: [
                "message": "Initialize manuscript",
                "content": first.data.base64EncodedString(),
                "branch": config.branch,
            ])
            (base, _) = try await branchState(config: config)
        }

        // 2. One blob per file.
        var treeEntries: [[String: Any]] = []
        for file in files {
            let blob: [String: Any] = try await post("git/blobs", config: config, body: [
                "content": file.data.base64EncodedString(),
                "encoding": "base64",
            ])
            guard let sha = blob["sha"] as? String else {
                throw GitHubBackendError.badResponse("blob for \(file.path) returned no sha")
            }
            treeEntries.append(["path": file.path, "mode": "100644", "type": "blob", "sha": sha])
        }

        // 3. Tree on top of the base tree (leaves unrelated repo files alone).
        var treeBody: [String: Any] = ["tree": treeEntries]
        if let base { treeBody["base_tree"] = base.treeSHA }
        let tree: [String: Any] = try await post("git/trees", config: config, body: treeBody)
        guard let treeSHA = tree["sha"] as? String else {
            throw GitHubBackendError.badResponse("tree returned no sha")
        }

        // 4. Commit.
        var commitBody: [String: Any] = ["message": message, "tree": treeSHA]
        if let base { commitBody["parents"] = [base.commitSHA] }
        let commit: [String: Any] = try await post("git/commits", config: config, body: commitBody)
        guard let commitSHA = commit["sha"] as? String else {
            throw GitHubBackendError.badResponse("commit returned no sha")
        }

        // 5. Move (or create) the branch ref.  A 422 here means the branch
        //    moved (not a fast forward) or appeared (reference already
        //    exists) after we read it — GitHub reads can lag right after a
        //    repository/branch is created.  Rebuild once on the fresh head.
        do {
            if base != nil {
                _ = try await request("PATCH", "git/refs/heads/\(config.branch)", config: config,
                                      body: ["sha": commitSHA])
            } else {
                _ = try await request("POST", "git/refs", config: config,
                                      body: ["ref": "refs/heads/\(config.branch)", "sha": commitSHA])
            }
        } catch GitHubBackendError.http(let code, _) where code == 422 && attempt == 0 {
            return try await push(files: files, message: message, config: config, attempt: 1)
        }
        return String(commitSHA.prefix(7))
    }

    // MARK: - Branch deletion

    /// Deletes the config's branch ref (journal removal).  A branch that's
    /// already gone counts as success.
    func deleteBranch(config: Config) async throws {
        do {
            _ = try await request("DELETE", "git/refs/heads/\(config.branch)", config: config, body: nil)
        } catch GitHubBackendError.http(let code, _) where code == 404 || code == 422 {
            // 404/422: no such ref — nothing to delete.
        }
    }

    // MARK: - Pull

    /// Paths (exact or directory prefixes) this app owns in the repository.
    private static let managedPrefixes = ["manuscript.json", "figures/", "data/"]

    /// Downloads the manuscript files from the branch head.
    struct Commit: Identifiable, Sendable {
        let sha: String
        let message: String
        let date: Date?
        var id: String { sha }
    }

    /// Recent commits on the branch, newest first (the changelog dropdown).
    func commits(config: Config, limit: Int = 20) async throws -> [Commit] {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(config.owner)/\(config.repo)/commits?sha=\(config.branch)&per_page=\(limit)")!)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubBackendError.badResponse("commit list unavailable")
        }
        let iso = ISO8601DateFormatter()
        return array.compactMap { entry in
            guard let sha = entry["sha"] as? String,
                  let commit = entry["commit"] as? [String: Any] else { return nil }
            let date = ((commit["author"] as? [String: Any])?["date"] as? String)
                .flatMap { iso.date(from: $0) }
            return Commit(sha: sha, message: (commit["message"] as? String) ?? "", date: date)
        }
    }

    /// manuscript.json exactly as of one commit (raw contents API).
    func manuscriptJSON(atCommit sha: String, config: Config) async throws -> Data {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(config.owner)/\(config.repo)/contents/manuscript.json?ref=\(sha)")!)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GitHubBackendError.badResponse("manuscript.json missing at \(sha.prefix(7))")
        }
        return data
    }

    func pull(config: Config) async throws -> [File] {
        guard let base = try await branchHead(config: config) else {
            throw GitHubBackendError.notConfigured("Branch \"\(config.branch)\" has no commits yet — save to remote first.")
        }
        let tree: [String: Any] = try await get("git/trees/\(base.treeSHA)?recursive=1", config: config)
        guard let entries = tree["tree"] as? [[String: Any]] else {
            throw GitHubBackendError.badResponse("tree listing missing entries")
        }

        var files: [File] = []
        for entry in entries {
            guard let path = entry["path"] as? String,
                  let type = entry["type"] as? String, type == "blob",
                  let sha = entry["sha"] as? String,
                  Self.managedPrefixes.contains(where: { path == $0 || path.hasPrefix($0) })
            else { continue }
            let blob: [String: Any] = try await get("git/blobs/\(sha)", config: config)
            guard let b64 = blob["content"] as? String,
                  let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
            else { throw GitHubBackendError.badResponse("blob \(path) not decodable") }
            files.append(File(path: path, data: data))
        }
        guard files.contains(where: { $0.path == "manuscript.json" }) else {
            throw GitHubBackendError.notConfigured("The repository has no manuscript.json on \"\(config.branch)\" — nothing to load.")
        }
        return files
    }

    // MARK: - HTTP plumbing

    /// The branch's current commit + tree, or nil when the branch/repo is empty.
    private func branchHead(config: Config) async throws -> (commitSHA: String, treeSHA: String)? {
        try await branchState(config: config).head
    }

    /// Like `branchHead`, but distinguishes a missing BRANCH (repo has
    /// commits elsewhere) from a commitless REPOSITORY — the two need
    /// different bootstrapping.
    private func branchState(config: Config) async throws
        -> (head: (commitSHA: String, treeSHA: String)?, repoEmpty: Bool) {
        do {
            let ref: [String: Any] = try await get("git/ref/heads/\(config.branch)", config: config)
            guard let object = ref["object"] as? [String: Any],
                  let commitSHA = object["sha"] as? String else {
                throw GitHubBackendError.badResponse("ref missing object sha")
            }
            let commit: [String: Any] = try await get("git/commits/\(commitSHA)", config: config)
            guard let tree = commit["tree"] as? [String: Any],
                  let treeSHA = tree["sha"] as? String else {
                throw GitHubBackendError.badResponse("commit missing tree sha")
            }
            return ((commitSHA, treeSHA), false)
        } catch GitHubBackendError.http(let code, _) where code == 404 {
            return (nil, false)   // branch doesn't exist; repo has commits
        } catch GitHubBackendError.http(let code, _) where code == 409 {
            return (nil, true)    // repository has no commits at all
        }
    }

    private func get(_ path: String, config: Config) async throws -> [String: Any] {
        try await request("GET", path, config: config, body: nil)
    }

    private func post(_ path: String, config: Config, body: [String: Any]) async throws -> [String: Any] {
        try await request("POST", path, config: config, body: body)
    }

    @discardableResult
    private func request(_ method: String, _ path: String, config: Config,
                         body: [String: Any]?) async throws -> [String: Any] {
        try await rawRequest(
            method,
            url: "https://api.github.com/repos/\(config.owner)/\(config.repo)/\(path)",
            token: config.token,
            body: body)
    }

    @discardableResult
    private func rawRequest(_ method: String, url: String, token: String,
                            body: [String: Any]?) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String } ?? ""
            throw GitHubBackendError.http(code, message)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0 } ?? [:]
    }
}
