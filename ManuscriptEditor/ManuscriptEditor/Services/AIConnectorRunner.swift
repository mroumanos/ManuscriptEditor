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
// 2. **Streaming, not a black box.**  `--output-format json` returns nothing
//    until the run is over, so a request that thinks for six minutes is
//    indistinguishable from one that has hung — which is exactly the question
//    asked at minute three.  This reads `stream-json` line by line instead:
//    thinking tokens and response characters are reported as they arrive, and
//    "no event for a while" (not a total wall clock) is what counts as stuck.
//
// 3. **Working directory.**  A non-`--bare` run loads whatever ambient config
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
    case stalled(Int)
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
        case .stalled(let seconds):
            return "The tool went quiet for \(seconds / 60) min — no thinking, no output — so the request was given up on and nothing was written. If this tool has never run here it may be waiting for a sign-in: run it once in Terminal."
        case .timedOut(let seconds):
            // Two very different causes, and the second only looks like a
            // hang: a first run waiting on a sign-in, or a request genuinely
            // bigger than the time allowed.
            return "No answer after \(seconds / 60) min, so the request was given up on and nothing was written. If this tool has never run here, it may be waiting for a sign-in — run it once in Terminal. Otherwise the manuscript may simply be too large for one pass."
        case .toolFailed(let detail):
            return detail
        case .emptyResponse:
            return "The tool returned nothing."
        }
    }
}

// MARK: - Progress

/// What a run is doing right now, reported as it happens.
struct AIRunProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case starting
        /// Extended thinking, before a single character of the answer exists.
        /// On a manuscript-sized adaptation this is most of the wait.
        case thinking
        case writing
    }
    var phase: Phase = .starting
    var thinkingTokens: Int = 0
    var responseCharacters: Int = 0

    /// The most recent stretch of the answer, for watching it arrive.
    ///
    /// A tail rather than the whole buffer: a full-manuscript run produced
    /// 71,000 output tokens, and copying that string on every delta would cost
    /// more than the request.  What a live view can show is the end anyway.
    var tail: String = ""

    var summary: String {
        switch phase {
        case .starting: return "Starting…"
        case .thinking: return "Thinking · \(thinkingTokens.formatted()) tokens"
        case .writing:  return "Writing · \(responseCharacters.formatted()) characters"
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

    /// Silence that means stuck.  A working run emits thinking-token or text
    /// events every few seconds, so three minutes of nothing is a real stall —
    /// a far better signal than a total wall clock, which cannot tell a big
    /// job from a dead one.
    static let stallTimeout: Int = 180

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
                    sessionID: UUID? = nil,
                    timeout: Int = defaultTimeout,
                    onResolvePath: ((String) -> Void)? = nil,
                    onProgress: (@Sendable (AIRunProgress) -> Void)? = nil) async throws -> AIRunResult {
        switch connector.kind {
        case .claudeCLI:
            return try await runClaudeCode(prompt: prompt, connector: connector,
                                           sessionID: sessionID,
                                           timeout: timeout, onResolvePath: onResolvePath,
                                           onProgress: onProgress)
        case .codexCLI, .geminiCLI, .ollama:
            throw AIConnectorError.notImplemented(connector.kind.displayName)
        }
    }

    /// `claude -p <prompt> --model <id> --output-format stream-json --verbose
    /// --include-partial-messages --session-id <uuid>`
    ///
    /// Two deliberate choices beyond the minimum:
    ///
    /// **stream-json** so the run is observable while it happens (see the file
    /// header).  **Our own session id** so the CLI's transcript for this run is
    /// at a path the app can compute — `transcriptURL(for:)` — and offer to
    /// open, instead of the user hunting through `~/.claude/projects/`.  It
    /// works even when the run fails, which is when it matters most.
    private static func runClaudeCode(prompt: String,
                                      connector: AIConnector,
                                      sessionID: UUID?,
                                      timeout: Int,
                                      onResolvePath: ((String) -> Void)?,
                                      onProgress: (@Sendable (AIRunProgress) -> Void)?) async throws -> AIRunResult {
        let path = try resolve(tool: "claude", storedPath: connector.executablePath)
        onResolvePath?(path)

        var arguments = ["-p", prompt,
                         "--output-format", "stream-json",
                         "--verbose", "--include-partial-messages"]
        if !connector.selectedModel.isEmpty {
            arguments.append(contentsOf: ["--model", connector.selectedModel])
        }
        if let sessionID {
            arguments.append(contentsOf: ["--session-id", sessionID.uuidString.lowercased()])
        }

        let started = Date()
        let collector = StreamCollector(onProgress: onProgress)
        let output = try await execute(path: path, arguments: arguments,
                                       stallTimeout: stallTimeout, hardTimeout: timeout,
                                       onLine: { collector.consume($0) })
        let duration = Date().timeIntervalSince(started)

        if output.stoppedBecause == .stall { throw AIConnectorError.stalled(stallTimeout) }
        if output.stoppedBecause == .deadline { throw AIConnectorError.timedOut(timeout) }

        // The last line of a stream-json run is the same object the
        // non-streaming format returns, so failures still report themselves
        // through the result rather than stderr.
        guard let json = collector.result else {
            let detail = output.stderr.isEmpty ? collector.text : output.stderr
            throw AIConnectorError.toolFailed(
                detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "The tool exited with code \(output.status) and said nothing."
                    : detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let result = (json["result"] as? String) ?? collector.text
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
                           sessionID: (json["session_id"] as? String)
                                      ?? sessionID?.uuidString.lowercased(),
                           duration: duration)
    }

    /// Where Claude Code keeps the transcript of a run the app started.
    ///
    /// It encodes the working directory into the folder name by replacing the
    /// characters that can't appear in one, so the app's own workspace maps to
    /// a directory it can compute rather than guess.
    static func transcriptURL(for sessionID: String) -> URL? {
        let workspace = workspaceDirectory().path
        let encoded = workspace
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)")
            .appendingPathComponent("\(sessionID.lowercased()).jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    // MARK: Reading the stream

    /// Accumulates a `stream-json` run: the answer text, the final result
    /// object, and enough of a running tally to show progress.
    ///
    /// `@unchecked Sendable` with a lock: lines arrive on a background reader
    /// while the caller may be reading progress, and this is the whole of the
    /// shared state.
    private final class StreamCollector: @unchecked Sendable {
        /// How much of the answer's end to keep for the live view.
        private let tailLength = 4_000
        private let lock = NSLock()
        private let onProgress: (@Sendable (AIRunProgress) -> Void)?
        private var progress = AIRunProgress()
        private var buffer = ""
        private(set) var result: [String: Any]?

        init(onProgress: (@Sendable (AIRunProgress) -> Void)?) {
            self.onProgress = onProgress
        }

        /// Text assembled from the deltas — the fallback when the final result
        /// object never arrives.
        var text: String { lock.withLock { buffer } }

        func consume(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            var snapshot: AIRunProgress?
            lock.withLock {
                switch json["type"] as? String {
                case "system":
                    // Claude Code reports its thinking as an estimated running
                    // total, which is the only signal of life during a long
                    // deliberation — there is no text yet to show.
                    if json["subtype"] as? String == "thinking_tokens",
                       let tokens = json["estimated_tokens"] as? Int {
                        progress.phase = .thinking
                        progress.thinkingTokens = tokens
                        snapshot = progress
                    }
                case "stream_event":
                    guard let event = json["event"] as? [String: Any],
                          let delta = event["delta"] as? [String: Any] else { return }
                    if delta["type"] as? String == "text_delta",
                       let piece = delta["text"] as? String {
                        buffer += piece
                        progress.phase = .writing
                        progress.responseCharacters = buffer.count
                        progress.tail = String(buffer.suffix(tailLength))
                        snapshot = progress
                    }
                case "result":
                    result = json
                default:
                    break
                }
            }
            if let snapshot { onProgress?(snapshot) }
        }
    }

    // MARK: Process plumbing

    private struct Output {
        enum Stop { case finished, stall, deadline }
        let stderr: String
        let status: Int32
        /// Why the run ended — the tool exiting on its own is not the same as
        /// us killing it, and the old code could not tell them apart (a
        /// terminated `claude` exits 143 by itself, which read as a normal
        /// failure).
        let stoppedBecause: Stop
    }

    /// Spawns the tool, feeds every stdout line to `onLine` as it arrives, and
    /// gives up either when the stream goes quiet or when the hard deadline
    /// passes.
    private static func execute(path: String,
                                arguments: [String],
                                stallTimeout: Int,
                                hardTimeout: Int,
                                onLine: @escaping @Sendable (String) -> Void) async throws -> Output {
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

        let clock = ActivityClock()

        // Read on background queues: a full pipe buffer deadlocks a process
        // that is still writing while we wait for it to exit.
        async let lines: Void = readLines(outPipe) { line in
            clock.touch()
            onLine(line)
        }
        async let errData = readToEnd(errPipe)

        let watchdog = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                guard process.isRunning else { return }
                if clock.elapsedSinceLastEvent > Double(stallTimeout) {
                    clock.stop(.stall)
                    process.terminate()
                    return
                }
                if clock.totalElapsed > Double(hardTimeout) {
                    clock.stop(.deadline)
                    process.terminate()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        await lines
        let err = await errData
        process.waitUntilExit()

        return Output(stderr: err,
                      status: process.terminationStatus,
                      stoppedBecause: clock.stop)
    }

    /// Tracks when the run last said anything, and who ended it.
    private final class ActivityClock: @unchecked Sendable {
        private let lock = NSLock()
        private let started = Date()
        private var last = Date()
        private var reason: Output.Stop = .finished

        func touch() { lock.withLock { last = Date() } }
        func stop(_ reason: Output.Stop) { lock.withLock { self.reason = reason } }
        var stop: Output.Stop { lock.withLock { reason } }
        var elapsedSinceLastEvent: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
        var totalElapsed: TimeInterval { Date().timeIntervalSince(started) }
    }

    /// Streams stdout a chunk at a time, handing over each complete line.
    private static func readLines(_ pipe: Pipe,
                                  _ handle: @escaping @Sendable (String) -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var pending = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let lineData = pending[pending.startIndex..<newline]
                        pending.removeSubrange(pending.startIndex...newline)
                        if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                            handle(line)
                        }
                    }
                }
                if !pending.isEmpty, let line = String(data: pending, encoding: .utf8) {
                    handle(line)
                }
                continuation.resume()
            }
        }
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
