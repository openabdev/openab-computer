import Foundation

/// Background `exec` jobs: spawn once, then poll/cancel/list across separate MCP calls.
///
/// Output model: each job's stdout and stderr are **tee'd to files** —
/// `<logDir>/<job_id>.out` and `<job_id>.err` — which are the single source of truth.
/// `exec_poll` reads them by byte offset (lseek), so there is no in-memory ring buffer,
/// no truncation of long build logs, and a log survives even after the job's metadata is
/// garbage-collected (as long as the file is still on disk). A human can `tail -f` them.
///
/// The registry is an `actor` (MCP tools are `Sendable`, called concurrently). Terminal
/// jobs' metadata is kept for `retention`; log files are cleaned on startup by age.

public enum JobState: String, Sendable {
    case running
    case exited     // process finished on its own
    case killed     // cancelled or timed out (SIGKILL/SIGTERM)
}

public final class Job: @unchecked Sendable {
    public let id: String
    public let pid: pid_t
    public let command: String
    public let cwd: String
    public let startedAt: Date
    public let outPath: String
    public let errPath: String

    private let lock = NSLock()
    private var _state: JobState = .running
    private var _exitCode: Int32? = nil
    private var _finishedAt: Date? = nil

    init(id: String, pid: pid_t, command: String, cwd: String, outPath: String, errPath: String) {
        self.id = id; self.pid = pid; self.command = command; self.cwd = cwd
        self.startedAt = Date()
        self.outPath = outPath; self.errPath = errPath
    }

    public var state: JobState { lock.lock(); defer { lock.unlock() }; return _state }
    public var exitCode: Int32? { lock.lock(); defer { lock.unlock() }; return _exitCode }
    public var finishedAt: Date? { lock.lock(); defer { lock.unlock() }; return _finishedAt }

    func finish(state: JobState, exitCode: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard _state == .running else { return }
        _state = state; _exitCode = exitCode; _finishedAt = Date()
    }

    /// Bytes of a log file at absolute offset ≥ `from`, and the file's current size.
    /// Returns empty data (with the current size) if `from` is at/after EOF.
    static func readLog(path: String, from: Int) -> (data: Data, nextOffset: Int) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return (Data(), from) }
        defer { close(fd) }
        let size = Int(lseek(fd, 0, SEEK_END))
        guard size > from else { return (Data(), max(size, 0)) }
        lseek(fd, off_t(from), SEEK_SET)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var remaining = size - from
        while remaining > 0 {
            let n = read(fd, &buf, min(buf.count, remaining))
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            remaining -= n
        }
        return (out, from + out.count)
    }

    static func fileSize(_ path: String) -> Int {
        var st = stat()
        return stat(path, &st) == 0 ? Int(st.st_size) : 0
    }
}

public actor JobRegistry {
    public static let shared = JobRegistry()

    private var jobs: [String: Job] = [:]
    private let logDir: String
    private let retention: TimeInterval   // keep terminal-job *metadata* this long
    private let maxJobs: Int
    private let maxAgeDays: Double        // startup GC threshold for log *files*

    public init(logDir: String? = nil, retention: TimeInterval = 600, maxJobs: Int = 64, maxAgeDays: Double = 7) {
        self.logDir = logDir ?? (NSHomeDirectory() + "/Library/Logs/oab-computer/jobs")
        self.retention = retention
        self.maxJobs = maxJobs
        self.maxAgeDays = maxAgeDays
        try? FileManager.default.createDirectory(atPath: self.logDir, withIntermediateDirectories: true)
        cleanupOldLogFiles()
    }

    /// Delete job log files older than `maxAgeDays`. Called once at construction.
    /// `nonisolated` so it can run synchronously from `init`; it only reads immutable
    /// stored properties and touches the filesystem.
    private nonisolated func cleanupOldLogFiles() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: logDir) else { return }
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400)
        for name in entries where name.hasSuffix(".out") || name.hasSuffix(".err") {
            let path = logDir + "/" + name
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mod = attrs[.modificationDate] as? Date, mod < cutoff {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    /// Start a background job. `cwd` must already be resolved (see `ExecCwd`). `timeout`
    /// of 0 means "no timeout" — the job runs until it exits or is cancelled.
    public func start(command: String, cwd: String, env: [String: String], timeout: TimeInterval) throws -> Job {
        gc()
        guard jobs.count < maxJobs else {
            throw ToolError("too many jobs (\(maxJobs)); cancel/let existing ones finish first")
        }
        let id = "job-" + UUID().uuidString.lowercased()
        let outPath = logDir + "/" + id + ".out"
        let errPath = logDir + "/" + id + ".err"
        FileManager.default.createFile(atPath: outPath, contents: nil)
        FileManager.default.createFile(atPath: errPath, contents: nil)
        let outFile = open(outPath, O_WRONLY | O_APPEND)
        let errFile = open(errPath, O_WRONLY | O_APPEND)
        guard outFile >= 0, errFile >= 0 else {
            if outFile >= 0 { close(outFile) }
            if errFile >= 0 { close(errFile) }
            throw ToolError("cannot open job log files in \(logDir)")
        }

        let proc: SpawnedProcess
        do {
            proc = try ExecSpawn.spawn(command: command, cwd: cwd, env: env)
        } catch {
            close(outFile); close(errFile)
            throw error
        }
        let job = Job(id: id, pid: proc.pid, command: command, cwd: cwd, outPath: outPath, errPath: errPath)
        jobs[id] = job
        superviseDetached(job: job, proc: proc, timeout: timeout, outFile: outFile, errFile: errFile)
        return job
    }

    public func job(_ id: String) -> Job? { jobs[id] }

    /// All running jobs plus the most recent `recentFinished` terminal jobs (newest first).
    public func list(recentFinished: Int = 10) -> [Job] {
        gc()
        let running = jobs.values.filter { $0.state == .running }
            .sorted { $0.startedAt > $1.startedAt }
        let finished = jobs.values.filter { $0.state != .running }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
            .prefix(recentFinished)
        return running + Array(finished)
    }

    /// Signal a running job's process group. Returns false if unknown or already terminal.
    public func cancel(_ id: String, signal: Int32) -> Bool {
        guard let job = jobs[id], job.state == .running else { return false }
        killpg(job.pid, signal)
        return true
    }

    /// Drop a terminal job's metadata (log files are left on disk for later inspection).
    public func drop(_ id: String) -> Bool {
        guard let job = jobs[id], job.state != .running else { return false }
        jobs.removeValue(forKey: id)
        return true
    }

    private func gc() {
        let now = Date()
        for (id, job) in jobs {
            if let done = job.finishedAt, now.timeIntervalSince(done) > retention {
                jobs.removeValue(forKey: id)
            }
        }
    }

    /// Drain both pipes into the job's log files and reap the child on a detached task, so
    /// the spawning MCP call returns immediately. A timeout (> 0) kills the process group.
    private nonisolated func superviseDetached(job: Job, proc: SpawnedProcess, timeout: TimeInterval, outFile: Int32, errFile: Int32) {
        let ioQueue = DispatchQueue(label: "oab-computer.job.io", attributes: .concurrent)
        let group = DispatchGroup()
        for (readFD, writeFD) in [(proc.stdoutFD, outFile), (proc.stderrFD, errFile)] {
            group.enter()
            ioQueue.async {
                let h = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    d.withUnsafeBytes { raw in
                        var p = raw.baseAddress!
                        var left = raw.count
                        while left > 0 {
                            let n = write(writeFD, p, left)
                            if n <= 0 { break }
                            p = p.advanced(by: n); left -= n
                        }
                    }
                }
                close(writeFD)
                group.leave()
            }
        }

        let fired = LockedFlag()
        var timer: DispatchSourceTimer? = nil
        if timeout > 0 {
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now() + timeout)
            t.setEventHandler { if fired.trySet() { killpg(proc.pid, SIGKILL) } }
            t.resume()
            timer = t
        }

        DispatchQueue.global().async {
            var st: Int32 = 0
            while waitpid(proc.pid, &st, 0) < 0 && errno == EINTR {}
            timer?.cancel()
            group.notify(queue: .global()) {
                let exitCode: Int32
                let signalled = (st & 0x7f) != 0
                if signalled { exitCode = 128 + (st & 0x7f) } else { exitCode = (st >> 8) & 0xff }
                let state: JobState = (fired.isSet || signalled) ? .killed : .exited
                job.finish(state: state, exitCode: exitCode)
            }
        }
    }
}
