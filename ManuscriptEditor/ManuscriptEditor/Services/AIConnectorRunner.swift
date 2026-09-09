// AIConnectorRunner.swift
//
// Runs one prompt through a connector and returns the text.
//
// For a CLI connector this spawns the tool in **non-interactive mode**
// (`claude -p …`) and reads its JSON result.  The user's own sign-in is what
// authorises the call, so nothing here handles a credential.
//
// TWO THINGS THIS FILE EXISTS TO GET RIGHT
// ─────────────────────────────────────────────────────────────────────────────
// 1. **PATH.**  A GUI app launched from Finder inherits a minimal environment,
//    not the user's shell `PATH`.  `claude` normally lives in
//    `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, or an nvm/bun
//    directory, so `Process` with a bare tool name finds nothing.  `resolve`
//    walks the likely places and, failing that, asks a **login shell** — which
//    does read the user's profile.
//
// 2. **Working directory.**  A non-`--bare` run loads whatever ambient config
//    sits in its working directory: hooks from `.claude/settings.json`, servers
//    from `.mcp.json` — with no trust prompt.  Pointing it at a manuscript
//    folder that arrived from a collaborator would execute their configuration.
//    So every run happens in an app-owned empty directory instead.
//
//    (`--bare` would avoid that, but bare mode ignores the subscription login
//    and demands `ANTHROPIC_API_KEY` — the opposite of the point.)

import Foundation

// MARK: - Errors

enum AIConnectorError: LocalizedError {
    case notImplemented(String)
    case executableNotFound(String)
    case launchFailed(String)
    case timedOut(Int)
    case toolFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notImplemented(let name):
            return "\(name) isn't wired up yet."
        case .executableNotFound(let tool):
            return "Couldn't find “\(tool)”. Install it, or set the path yourself with Browse…"
        case .launchFailed(let detail):
            return "Couldn't start the tool: \(detail)"
        case .timedOut(let seconds):
            return "No answer after \(seconds)s. The tool may be waiting for a sign-in — run it once in Terminal."
        case .toolFailed(let detail):
            return detail
        case .emptyResponse:
            return "The tool returned nothing."
        }
    }
}

// MARK: - Result

struct AIRunResult {
    let text: String
    /// Which model actually answered, confirmed from the tool's own usage
    /// report rather than assumed from what we asked for.
    let reportedModel: String?
    /// True when the model that answered is NOT the one that was requested —
    /// worth surfacing, since it means the selection didn't take.
    let modelWasSubstituted: Bool
    /// What the run cost, when the tool reports it (a client-side estimate).
    let costUSD: Double?
    /// The tool's session id, for continuing this conversation later.
    let sessionID: String?
    let duration: TimeInterval
}

// MARK: - Runner

enum AIConnectorRunner {

    /// How long to wait before giving up.  Generous, because a first run can
    /// stall on an interactive sign-in the app can't see.
    static let defaultTimeout: Int = 120

    // MARK: Resolving the executable

    /// Where these tools actually get installed, in the order worth trying.
    private static func candidatePaths(for tool: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "\(home)/.local/bin/\(tool)",
            "\(home)/.claude/local/\(tool)",
            "\(home)/.bun/bin/\(tool)",
            "\(home)/.npm-global/bin/\(tool)",
            "/usr/bin/\(tool)",
        ]
    }

    /// Finds the tool: the stored path, then the usual locations, then a login
    /// shell (which reads the user's profile and therefore their real `PATH`).
    /// Returns the resolved path so the caller can store it and skip all this
    /// next time.
    static func resolve(tool: String, storedPath: String) throws -> String {
        let fm = FileManager.default
        if !storedPath.isEmpty, fm.isExecutableFile(atPath: storedPath) {
            return storedPath
        }
        for candidate in candidatePaths(for: tool) where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let viaShell = loginShellLookup(tool), fm.isExecutableFile(atPath: viaShell) {
            return viaShell
        }
        throw AIConnectorError.executableNotFound(tool)
    }

    /// `zsh -lc "command -v <tool>"` — a login shell sources the user's profile,
    /// so it sees PATH entries added by nvm, mise, asdf and friends that no
    /// static list can predict.
    private static func loginShellLookup(_ tool: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    // MARK: The app-owned working directory

    /// An empty directory the app controls, so a run never picks up hooks or
    /// MCP servers from a folder someone else authored.
    static func workspaceDirectory() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support
            .appendingPathComponent("ManuscriptEditor", isDirectory: true)
            .appendingPathComponent("AIWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Running

    /// Sends one prompt and returns what came back.
    ///
    /// `resolvedPath` is handed back through `onResolvePath` so the caller can
    /// persist it — the expensive lookup should happen once, not per request.
    static func run(prompt: String,
                    connector: AIConnector,
                    timeout: Int = defaultTimeout,
                    onResolvePath: ((String) -> Void)? = nil) async throws -> AIRunResult {
        switch connector.kind {
        case .claudeCLI:
            return try await runClaudeCode(prompt: prompt, connector: connector,
                                           timeout: timeout, onResolvePath: onResolvePath)
        case .codexCLI, .geminiCLI, .ollama:
            throw AIConnectorError.notImplemented(connector.kind.displayName)
        }
    }

    /// `claude -p <prompt> --model <id> --output-format json`
    ///
    /// Deliberately a minimal argument list: every extra flag is a chance to
    /// hit a version that doesn't know it, and Claude Code rejects unknown
    /// options before the run starts.  No tools are requested, so no permission
    /// prompt should arise.
    private static func runClaudeCode(prompt: String,
                                      connector: AIConnector,
                                      timeout: Int,
                                      onResolvePath: ((String) -> Void)?) async throws -> AIRunResult {
        let path = try resolve(tool: "claude", storedPath: connector.executablePath)
        onResolvePath?(path)

        var arguments = ["-p", prompt, "--output-format", "json"]
        if !connector.selectedModel.isEmpty {
            arguments.append(contentsOf: ["--model", connector.selectedModel])
        }

        let started = Date()
        let output = try await execute(path: path, arguments: arguments, timeout: timeout)
        let duration = Date().timeIntervalSince(started)

        // `--output-format json` wraps the answer; a failure inside the run is
        // reported as the result rather than on stderr, so parse before judging.
        guard let data = output.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // No JSON at all: the tool failed before it got going.
            let detail = output.stderr.isEmpty ? output.stdout : output.stderr
            throw AIConnectorError.toolFailed(
                detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "The tool exited with code \(output.status) and said nothing."
                    : detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let result = (json["result"] as? String) ?? ""
        let isError = (json["is_error"] as? Bool) ?? (output.status != 0)
        if isError {
            throw AIConnectorError.toolFailed(result.isEmpty
                ? "The tool reported a failure (exit \(output.status))."
                : result)
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIConnectorError.emptyResponse
        }

        let (model, substituted) = answeringModel(in: json, requested: connector.selectedModel)
        return AIRunResult(text: result,
                           reportedModel: model,
                           modelWasSubstituted: substituted,
                           costUSD: json["total_cost_usd"] as? Double,
                           sessionID: json["session_id"] as? String,
                           duration: duration)
    }

    /// Works out which model actually answered.
    ///
    /// There is no top-level `model` field.  `modelUsage` is keyed by model id,
    /// but it lists **every** model the run touched — including the small one
    /// Claude Code uses for its own housekeeping, which routinely burns more
    /// tokens than the answer itself.  A real run asking for `claude-opus-5`
    /// reports `claude-haiku-4-5-…` at 9 output tokens beside `claude-opus-5`
    /// at 4, so "the busiest model" and "the first alphabetically" are both
    /// wrong.
    ///
    /// The requested model appearing in that report IS the confirmation we
    /// want; its absence is the interesting case, and gets flagged rather than
    /// papered over.
    private static func answeringModel(in json: [String: Any],
                                       requested: String) -> (String?, Bool) {
        guard let usage = json["modelUsage"] as? [String: Any], !usage.isEmpty else {
            return (json["model"] as? String, false)
        }
        let names = usage.keys.sorted()
        if !requested.isEmpty {
            // Ids carry date suffixes ("claude-haiku-4-5-20251001"), so match
            // on the prefix in both directions.
            if let hit = names.first(where: { $0 == requested
                                              || $0.hasPrefix(requested)
                                              || requested.hasPrefix($0) }) {
                return (hit, false)
            }
        }
        // Nothing matching what we asked for: report whichever produced the
        // most output and say that it wasn't the one requested.
        let busiest = names.max { lhs, rhs in
            outputTokens(usage[lhs]) < outputTokens(usage[rhs])
        }
        return (busiest, !requested.isEmpty)
    }

    private static func outputTokens(_ entry: Any?) -> Int {
        (entry as? [String: Any])?["outputTokens"] as? Int ?? 0
    }

    // MARK: Process plumbing

    private struct Output {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// Spawns the tool, enforces a deadline, and drains both pipes.
    private static func execute(path: String,
                                arguments: [String],
                                timeout: Int) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = workspaceDirectory()

        // Give the child a PATH that includes where these tools live, so a CLI
        // that shells out to node/npm finds them too.
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin"]
        let existing = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        environment["PATH"] = (extra + existing).reduced().joined(separator: ":")
        environment["HOME"] = home
        process.environment = environment

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice   // never block on stdin

        do {
            try process.run()
        } catch {
            throw AIConnectorError.launchFailed(error.localizedDescription)
        }

        // Read on background queues: a full pipe buffer deadlocks a process
        // that is still writing while we wait for it to exit.
        async let outData = readToEnd(outPipe)
        async let errData = readToEnd(errPipe)

        let deadline = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        defer { deadline.cancel() }

        let out = await outData
        let err = await errData
        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal, process.terminationStatus != 0,
           deadline.isCancelled == false, !process.isRunning, out.isEmpty {
            throw AIConnectorError.timedOut(timeout)
        }

        return Output(stdout: out, stderr: err, status: process.terminationStatus)
    }

    private static func readToEnd(_ pipe: Pipe) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}

private extension Array where Element == String {
    /// De-duplicates while keeping first-seen order.
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
