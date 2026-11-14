import Foundation

/// Long-running counterpart to `exec`. `exec_start` spawns and returns a `job_id`
/// immediately; `exec_poll` fetches incremental output and state; `exec_cancel` signals
/// the process group. Designed for builds and other work that outlives a single MCP
/// request/response (which is otherwise capped by the client's read timeout).

func resolveJobEnv(_ arguments: JSONValue) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = env["TERM"] ?? "dumb"
    if let extra = arguments["env"]?.objectValue {
        for (k, v) in extra { if let s = v.stringValue { env[k] = s } }
    }
    // After the caller overrides, so a caller cannot put it back: an orphan of ours must not look like the launchd job.
    return LaunchdJob.childEnvironment(env)
}

public struct ExecStartTool: Tool {
    public let name = "exec_start"
    public let description = """
        Start a shell command in the background and return a job_id immediately, for work \
        that outlives one request (e.g. a release build). Poll it with `exec_poll` and stop \
        it with `exec_cancel`. Same shell/session/TCC context as `exec` (zsh -f, GUI session, \
        add /opt/homebrew/bin to PATH via `env` if needed). Output is buffered (newest bytes \
        kept if it overflows). Prefer plain `exec` for anything that finishes in a few seconds.
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "command": ["type": "string", "description": "Shell command line, run via `zsh -f -c`."],
            "cwd": ["type": "string", "description": "Working directory (a leading ~ is expanded). Default: user's home."],
            "timeout_secs": ["type": "number", "description": "Kill the job after this many seconds. 0 = no timeout (stop it with exec_cancel). Default 0."],
            "env": ["type": "object", "additionalProperties": ["type": "string"], "description": "Extra environment variables."],
        ],
        "required": ["command"],
    ]
    public init() {}

    public func call(arguments: JSONValue) async throws -> ToolResult {
        guard let command = arguments["command"]?.stringValue, !command.isEmpty else {
            throw JSONRPCError.invalidParams("command is required")
        }
        let timeout = max(arguments["timeout_secs"]?.doubleValue ?? 0, 0)
        let rawCwd = arguments["cwd"]?.stringValue ?? FileManager.default.homeDirectoryForCurrentUser.path
        let cwd: String
        switch ExecCwd.resolve(rawCwd) {
        case .ok(let p): cwd = p
        case .failure(let why): return .error(why)
        }
        let env = resolveJobEnv(arguments)

        let job: Job
        do {
            job = try await JobRegistry.shared.start(command: command, cwd: cwd, env: env, timeout: timeout)
        } catch let e as ToolError {
            return .error(e.description)
        }

        let structured: JSONValue = [
            "job_id": .string(job.id),
            "pid": .number(Double(job.pid)),
            "state": .string(job.state.rawValue),
            "cwd": .string(cwd),
        ]
        return ToolResult(
            content: [.text("started \(job.id) (pid \(job.pid)); poll with exec_poll")],
            structured: structured)
    }
}

public struct ExecPollTool: Tool {
    public let name = "exec_poll"
    public let description = """
        Fetch a background job's state and any output produced since your last poll. Pass the \
        `job_id` from exec_start and, to get only new output, the `stdout_since`/`stderr_since` \
        byte offsets returned by the previous poll. When `state` is `exited` or `killed`, \
        `exit_code` is set and no more output will appear. Output is read from the job's log \
        files (never truncated); terminal-job metadata is retained ~10 min, and the log files \
        themselves persist on disk (~/Library/Logs/oab-computer/jobs/<job_id>.out/.err).
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "job_id": ["type": "string"],
            "stdout_since": ["type": "integer", "description": "Byte offset from a prior poll; omit for all stdout."],
            "stderr_since": ["type": "integer", "description": "Byte offset from a prior poll; omit for all stderr."],
        ],
        "required": ["job_id"],
    ]
    public init() {}

    public func call(arguments: JSONValue) async throws -> ToolResult {
        guard let id = arguments["job_id"]?.stringValue else { throw JSONRPCError.invalidParams("job_id is required") }
        guard let job = await JobRegistry.shared.job(id) else {
            return .error("unknown job_id: \(id) (its metadata may have been garbage-collected; the log files may still exist under ~/Library/Logs/oab-computer/jobs/)")
        }
        let outSince = arguments["stdout_since"]?.intValue ?? 0
        let errSince = arguments["stderr_since"]?.intValue ?? 0
        let out = Job.readLog(path: job.outPath, from: outSince)
        let err = Job.readLog(path: job.errPath, from: errSince)

        let state = job.state
        let stdout = String(decoding: out.data, as: UTF8.self)
        let stderr = String(decoding: err.data, as: UTF8.self)

        var structured: [String: JSONValue] = [
            "job_id": .string(id),
            "state": .string(state.rawValue),
            "stdout": .string(stdout),
            "stderr": .string(stderr),
            "stdout_next": .number(Double(out.nextOffset)),
            "stderr_next": .number(Double(err.nextOffset)),
            "out_path": .string(job.outPath),
            "err_path": .string(job.errPath),
        ]
        if let code = job.exitCode { structured["exit_code"] = .number(Double(code)) }

        var text = ""
        if !stdout.isEmpty { text += stdout }
        if !stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + stderr }
        var trailer = "[\(state.rawValue)"
        if let code = job.exitCode { trailer += " exit \(code)" }
        trailer += "]"
        text += (text.isEmpty ? "" : "\n") + trailer

        return ToolResult(content: [.text(text)], structured: .object(structured))
    }
}

public struct ExecListTool: Tool {
    public let name = "exec_list"
    public let description = """
        List background jobs: all currently running ones plus the 10 most recently finished. \
        For each: job_id, state (running/exited/killed), pid, exit_code, command, cwd, \
        started_at, finished_at, and current stdout/stderr byte sizes. Use it to recover a \
        forgotten job_id or to see what is running; then `exec_poll` a specific job.
        """
    public let inputSchema: JSONValue = ["type": "object", "properties": [:]]
    public init() {}

    public func call(arguments: JSONValue) async throws -> ToolResult {
        let jobs = await JobRegistry.shared.list(recentFinished: 10)
        let iso = ISO8601DateFormatter()
        let arr: [JSONValue] = jobs.map { job in
            var o: [String: JSONValue] = [
                "job_id": .string(job.id),
                "state": .string(job.state.rawValue),
                "pid": .number(Double(job.pid)),
                "command": .string(job.command),
                "cwd": .string(job.cwd),
                "started_at": .string(iso.string(from: job.startedAt)),
                "stdout_bytes": .number(Double(Job.fileSize(job.outPath))),
                "stderr_bytes": .number(Double(Job.fileSize(job.errPath))),
            ]
            if let code = job.exitCode { o["exit_code"] = .number(Double(code)) }
            if let fin = job.finishedAt { o["finished_at"] = .string(iso.string(from: fin)) }
            return .object(o)
        }

        let running = jobs.filter { $0.state == .running }.count
        let text: String
        if jobs.isEmpty {
            text = "no jobs"
        } else {
            text = jobs.map { j in
                let ex = j.exitCode.map { " exit \($0)" } ?? ""
                return "\(j.id)  \(j.state.rawValue)\(ex)  pid \(j.pid)  \(j.command)"
            }.joined(separator: "\n") + "\n[\(running) running, \(jobs.count - running) recent finished]"
        }
        return ToolResult(content: [.text(text)], structured: ["jobs": .array(arr)])
    }
}

public struct ExecCancelTool: Tool {
    public let name = "exec_cancel"
    public let description = """
        Stop a background job by signalling its process group, or drop a finished job to free \
        its buffers. `signal` is `KILL` (default, immediate) or `TERM` (let it clean up). \
        Poll once more afterwards to read the final output.
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "job_id": ["type": "string"],
            "signal": ["type": "string", "enum": ["KILL", "TERM"], "default": "KILL"],
        ],
        "required": ["job_id"],
    ]
    public init() {}

    public func call(arguments: JSONValue) async throws -> ToolResult {
        guard let id = arguments["job_id"]?.stringValue else { throw JSONRPCError.invalidParams("job_id is required") }
        guard let job = await JobRegistry.shared.job(id) else {
            return .error("unknown job_id: \(id)")
        }
        if job.state != .running {
            // Already finished: drop it so buffers are freed.
            _ = await JobRegistry.shared.drop(id)
            return ToolResult(
                content: [.text("job \(id) already \(job.state.rawValue) (exit \(job.exitCode ?? -1)); dropped")],
                structured: ["job_id": .string(id), "state": .string(job.state.rawValue), "dropped": .bool(true)])
        }
        let sig: Int32 = arguments["signal"]?.stringValue == "TERM" ? SIGTERM : SIGKILL
        let ok = await JobRegistry.shared.cancel(id, signal: sig)
        return ToolResult(
            content: [.text(ok ? "signalled \(id) (\(sig == SIGTERM ? "TERM" : "KILL")); poll for final output" : "could not signal \(id)")],
            structured: ["job_id": .string(id), "signalled": .bool(ok), "state": .string(job.state.rawValue)])
    }
}
