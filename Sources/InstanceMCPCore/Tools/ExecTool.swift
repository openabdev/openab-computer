import Foundation

/// Run a shell command in the daemon's (Aqua) session. Equivalent trust to SSH as the
/// same user, plus GUI/TCC context SSH lacks.
public struct ExecTool: Tool {
    public let name = "exec"
    public let description = """
        Run a shell command on this Mac with zsh -c, inside the logged-in GUI session \
        (so `open`, `osascript`, `screencapture` and other GUI-touching commands work). \
        Returns exit code, stdout and stderr. Output is truncated to max_output_bytes \
        (default 64 KiB) per stream; a timeout kills the process group and reports timed_out=true.
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "command": ["type": "string", "description": "Shell command line, run via `zsh -c`."],
            "cwd": ["type": "string", "description": "Working directory. Default: user's home."],
            "timeout_secs": ["type": "number", "description": "Kill after this many seconds. Default 60, max 600 (100 on openab-pty attaches; use exec_start + exec_poll for longer work)."],
            "max_output_bytes": ["type": "integer", "description": "Per-stream cap. Default 65536, max 1048576."],
            "env": ["type": "object", "additionalProperties": ["type": "string"], "description": "Extra environment variables."],
        ],
        "required": ["command"],
    ]

    public var defaultTimeout: TimeInterval = 60
    public var maxTimeout: TimeInterval = 600

    public init() {}

    public func call(arguments: JSONValue) async throws -> ToolResult {
        guard let command = arguments["command"]?.stringValue, !command.isEmpty else {
            throw JSONRPCError.invalidParams("command is required")
        }
        let timeout = min(arguments["timeout_secs"]?.doubleValue ?? defaultTimeout, maxTimeout)
        let cap = min(arguments["max_output_bytes"]?.intValue ?? 65536, 1 << 20)
        let rawCwd = arguments["cwd"]?.stringValue ?? FileManager.default.homeDirectoryForCurrentUser.path
        let cwd: String
        switch ExecCwd.resolve(rawCwd) {
        case .ok(let p): cwd = p
        case .failure(let why): return .error(why)
        }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = env["TERM"] ?? "dumb"
        if let extra = arguments["env"]?.objectValue {
            for (k, v) in extra { if let s = v.stringValue { env[k] = s } }
        }
        env = LaunchdJob.childEnvironment(env)   // an orphan of ours must not look like the launchd job

        let r = try await Self.run(command: command, cwd: cwd, env: env, timeout: timeout, cap: cap)

        var text = ""
        if !r.stdout.isEmpty { text += r.stdout }
        if !r.stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + r.stderr }
        var trailer = "[exit \(r.exitCode)"
        if r.timedOut { trailer += ", timed out after \(Int(timeout))s" }
        if r.stdoutTruncated || r.stderrTruncated { trailer += ", output truncated" }
        trailer += "]"
        text += (text.isEmpty ? "" : "\n") + trailer

        let structured: JSONValue = [
            "exit_code": .number(Double(r.exitCode)),
            "timed_out": .bool(r.timedOut),
            "stdout": .string(r.stdout), "stderr": .string(r.stderr),
            "stdout_truncated": .bool(r.stdoutTruncated), "stderr_truncated": .bool(r.stderrTruncated),
            "duration_ms": .number(Double(Int(r.duration * 1000))),
        ]
        return ToolResult(content: [.text(text)], isError: r.exitCode != 0 || r.timedOut, structured: structured)
    }

    public struct Outcome: Sendable {
        public var exitCode: Int32
        public var timedOut: Bool
        public var stdout: String
        public var stderr: String
        public var stdoutTruncated: Bool
        public var stderrTruncated: Bool
        public var duration: TimeInterval
    }

    /// Spawns `zsh -f -c command` as the leader of a *new session* (POSIX_SPAWN_SETSID), so
    /// on timeout `killpg(pid)` takes the whole child tree and can never reach the daemon's
    /// own process group. Foundation's `Process` cannot do this, hence posix_spawn (see
    /// `ExecSpawn.spawn`). Callers pass an already-resolved `cwd` (see `ExecCwd`).
    public static func run(command: String, cwd: String, env: [String: String], timeout: TimeInterval, cap: Int) async throws -> Outcome {
        let start = Date()

        let proc = try ExecSpawn.spawn(command: command, cwd: cwd, env: env)
        let pid = proc.pid

        let collector = OutputCollector(cap: cap)
        let ioQueue = DispatchQueue(label: "oab-instance-mcp.exec.io", attributes: .concurrent)
        let group = DispatchGroup()
        for (fd, stream) in [(proc.stdoutFD, 0), (proc.stderrFD, 1)] {
            group.enter()
            ioQueue.async {
                let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                while true {
                    let d = h.availableData     // blocks; empty ⇒ EOF
                    if d.isEmpty { break }
                    collector.append(d, stream: stream)
                }
                group.leave()
            }
        }

        let fired = LockedFlag()
        let killer = ProcessGroupKiller(pid)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if fired.trySet() { killer.kill() } }
        timer.resume()

        // Cancelling the calling task (the caller went away, or the grant was
        // revoked) kills the process group while its leader is alive.
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    // Wait without reaping first, so a kill racing the exit can
                    // never hit a recycled pid.
                    var info = siginfo_t()
                    while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
                    killer.markExited()
                    var st: Int32 = 0
                    while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
                    cont.resume(returning: st)
                }
            }
        } onCancel: {
            killer.kill()
        }
        timer.cancel()
        // Pipes reach EOF once every writer in the (now dead) session has exited.
        // A child backgrounded by the shell (`cmd &`) can hold them open after the
        // leader exits; it can no longer be killed safely (the pid may be
        // recycled), but a cancelled call stops waiting for it and returns.
        let drained = OneShotResume()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                drained.set(cont)
                group.notify(queue: .global()) { drained.fire() }
            }
        } onCancel: {
            drained.fire()
        }

        let exitCode: Int32
        if (status & 0x7f) == 0 { exitCode = (status >> 8) & 0xff }        // WIFEXITED → WEXITSTATUS
        else { exitCode = 128 + (status & 0x7f) }                           // signalled, shell convention

        let (out, outT, err, errT) = collector.snapshot()
        return Outcome(
            exitCode: exitCode, timedOut: fired.isSet,
            stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self),
            stdoutTruncated: outT, stderrTruncated: errT,
            duration: Date().timeIntervalSince(start))
    }
}

/// NULL-terminated `char *[]` for posix_spawn, valid for the duration of `body`.
func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    ptrs.append(nil)
    defer { for p in ptrs { free(p) } }
    return body(ptrs)
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bufs = [Data(), Data()]
    private var truncated = [false, false]
    private let cap: Int
    init(cap: Int) { self.cap = cap }
    func append(_ d: Data, stream: Int) {
        guard !d.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let room = cap - bufs[stream].count
        if room <= 0 { truncated[stream] = true; return }
        if d.count > room { bufs[stream].append(d.prefix(room)); truncated[stream] = true }
        else { bufs[stream].append(d) }
    }
    func snapshot() -> (Data, Bool, Data, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (bufs[0], truncated[0], bufs[1], truncated[1])
    }
}

/// `killpg(pid, SIGKILL)` until the leader has exited, never after: once it is
/// reaped its pid may belong to someone else.
final class ProcessGroupKiller: @unchecked Sendable {
    private let lock = NSLock(); private let pid: pid_t; private var exited = false
    init(_ pid: pid_t) { self.pid = pid }
    func kill() { lock.lock(); defer { lock.unlock() }; if !exited { killpg(pid, SIGKILL) } }
    func markExited() { lock.lock(); exited = true; lock.unlock() }
}

/// Resumes a continuation exactly once, whether `fire()` comes before or after `set`.
final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock(); private var cont: CheckedContinuation<Void, Never>?; private var fired = false
    func set(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if fired { lock.unlock(); c.resume(); return }
        cont = c; lock.unlock()
    }
    func fire() {
        lock.lock()
        if fired { lock.unlock(); return }
        fired = true; let c = cont; cont = nil; lock.unlock()
        c?.resume()
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func trySet() -> Bool { lock.lock(); defer { lock.unlock() }; if v { return false }; v = true; return true }
}
