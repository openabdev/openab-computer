import Foundation
import Darwin

/// What the child's stderr said, as an app-defined class. The text itself is never kept past the
/// in-memory ring, never logged and never returned (R7.4).
public enum StderrClass: String, Sendable, Equatable {
    case profileLocked = "profile_locked"
    case executableNotFound = "executable_not_found"
    case moduleNotFound = "module_not_found"
    case launchRefused = "launch_refused"
}

/// A 64 KiB in-memory ring of the newest stderr bytes. There is no accessor that returns the
/// text: the only way out is `classify()`, which yields a fixed class.
public final class StderrRing: @unchecked Sendable {
    public static let capacity = 64 * 1024
    private let lock = NSLock()
    private var data = Data()

    public init() {}

    public func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > Self.capacity { data = Data(data.suffix(Self.capacity)) }
        }
    }

    /// The signature that occurs last in the buffer wins, so a stale message does not mask a new one.
    public func classify() -> StderrClass? {
        let text = lock.withLock { String(decoding: data, as: UTF8.self) }.lowercased()
        let table: [(String, StderrClass)] = [
            ("singleton lock", .profileLocked), ("processsingleton", .profileLocked),
            ("executable doesn't exist", .executableNotFound), ("cannot find module", .moduleNotFound),
            ("eacces", .launchRefused), ("operation not permitted", .launchRefused),
        ]
        var best: (Int, StderrClass)?
        for (sig, cls) in table {
            if let r = text.range(of: sig, options: .backwards) {
                let at = text.distance(from: text.startIndex, to: r.lowerBound)
                if best == nil || at > best!.0 { best = (at, cls) }
            }
        }
        return best?.1
    }

    var byteCount: Int { lock.withLock { data.count } }
    func snapshotForTests() -> String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

public enum ExitInfo: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    var summary: String {
        switch self { case .exited(let c): return "status=\(c)"; case .signaled(let s): return "signal=\(s)" }
    }
}

/// Process groups of live managed children, in memory only. `terminateAllSync` runs while the app
/// exits, so it blocks briefly by design.
public final class ManagedChildRegistry: @unchecked Sendable {
    public static let shared = ManagedChildRegistry()
    private let lock = NSLock()
    private var groups: Set<pid_t> = []

    func add(_ g: pid_t) { lock.withLock { _ = groups.insert(g) } }
    func remove(_ g: pid_t) { lock.withLock { _ = groups.remove(g) } }
    var count: Int { lock.withLock { groups.count } }

    public func terminateAllSync() {
        let gs = lock.withLock { groups }
        guard !gs.isEmpty else { return }
        for g in gs { killpg(g, SIGTERM) }
        for _ in 0..<40 {
            if lock.withLock({ groups.isEmpty }) { return }
            usleep(50_000)
        }
        for g in lock.withLock({ groups }) { killpg(g, SIGKILL) }
        for _ in 0..<20 {
            if lock.withLock({ groups.isEmpty }) { return }
            usleep(50_000)
        }
    }
}

/// A child process that speaks MCP over stdio. It leads its own process group, so Chromium and
/// other helpers can be signalled together. Limitation: a helper that calls `setsid` leaves the
/// group, and an orphan left by a crashed app is not killed because the app cannot prove it is
/// ours (R7.4).
public final class ManagedProcess: StdioChannel, @unchecked Sendable {
    public let pid: pid_t
    public let stderrRing = StderrRing()
    public let incoming: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var stdinFD: Int32
    private var exitStatus: ExitInfo?
    private let writeQueue = DispatchQueue(label: "oab.managed.stdin")
    private var onExit: (@Sendable (ExitInfo) -> Void)?
    private let stdoutDone = DispatchSemaphore(value: 0)

    public var exitInfo: ExitInfo? { lock.withLock { exitStatus } }
    public var hasExited: Bool { exitInfo != nil }

    private init(pid: pid_t, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid; self.stdinFD = stdinFD
        var c: AsyncStream<Data>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        ManagedChildRegistry.shared.add(pid)
        Self.startReader(fd: stdoutFD) { [weak self] chunk in self?.continuation.yield(chunk) } done: { [weak self] in
            self?.stdoutDone.signal()
        }
        Self.startReader(fd: stderrFD) { [weak self] chunk in self?.stderrRing.append(chunk) } done: {}
        let t = Thread { [weak self] in self?.waitForChild() }
        t.stackSize = 256 * 1024
        t.start()
    }

    /// `environment` is used as given: nothing is inherited.
    public static func spawn(executable: String, arguments: [String], environment: [String: String],
                             workingDirectory: String,
                             onExit: (@Sendable (ExitInfo) -> Void)? = nil) throws -> ManagedProcess {
        var inP = [Int32](repeating: -1, count: 2), outP = inP, errP = inP
        guard pipe(&inP) == 0, pipe(&outP) == 0, pipe(&errP) == 0 else {
            throw PlaywrightTransportError(errorClass: "playwright_spawn_failed")
        }
        var attr: posix_spawnattr_t?; posix_spawnattr_init(&attr)
        var fa: posix_spawn_file_actions_t?; posix_spawn_file_actions_init(&fa)
        defer { posix_spawnattr_destroy(&attr); posix_spawn_file_actions_destroy(&fa) }
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(); sigfillset(&all)
        var none = sigset_t(); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
                                              | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawn_file_actions_adddup2(&fa, inP[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errP[1], 2)
        posix_spawn_file_actions_addchdir_np(&fa, workingDirectory)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fa, &attr, argv, envp)
        Darwin.close(inP[0]); Darwin.close(outP[1]); Darwin.close(errP[1])
        guard rc == 0 else {
            Darwin.close(inP[1]); Darwin.close(outP[0]); Darwin.close(errP[0])
            throw PlaywrightTransportError(errorClass: "playwright_spawn_failed")
        }
        _ = fcntl(inP[1], F_SETNOSIGPIPE, 1)
        let p = ManagedProcess(pid: pid, stdinFD: inP[1], stdoutFD: outP[0], stderrFD: errP[0])
        p.lock.withLock { p.onExit = onExit }
        return p
    }

    private static func startReader(fd: Int32, _ chunk: @escaping @Sendable (Data) -> Void, done: @escaping @Sendable () -> Void) {
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = read(fd, &buf, buf.count)
                if n > 0 { chunk(Data(buf[0..<n])) }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
            Darwin.close(fd)
            done()
        }
        t.stackSize = 256 * 1024
        t.start()
    }

    private func waitForChild() {
        // Wait without reaping, so the group id cannot be reused while the sweep runs.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        killpg(pid, SIGKILL)   // leftover members of the group, such as Chromium helpers
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let e: ExitInfo = (status & 0x7f) == 0 ? .exited((status >> 8) & 0xff) : .signaled(status & 0x7f)
        // Give trailing stdout a moment; a surviving grandchild could hold the pipe open.
        _ = stdoutDone.wait(timeout: .now() + 0.3)
        let cb = lock.withLock { () -> (@Sendable (ExitInfo) -> Void)? in exitStatus = e; return onExit }
        continuation.finish()
        ManagedChildRegistry.shared.remove(pid)
        cb?(e)
    }

    // MARK: StdioChannel

    public func send(_ data: Data) {
        writeQueue.async { [self] in
            let fd = lock.withLock { stdinFD }
            guard fd >= 0 else { return }
            var off = 0
            data.withUnsafeBytes { raw in
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return }
                }
            }
        }
    }

    public func closeStdin() {
        writeQueue.async { [self] in
            let fd = lock.withLock { () -> Int32 in let f = stdinFD; stdinFD = -1; return f }
            if fd >= 0 { Darwin.close(fd) }
        }
    }

    public func close() { closeStdin() }

    private func waitExit(_ seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !hasExited {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// Close stdin and wait 1 s, then SIGTERM the group and wait 3 s, then SIGKILL.
    public func terminate() async {
        closeStdin()
        if await waitExit(1) { return }
        killpg(pid, SIGTERM)
        if await waitExit(3) { return }
        killpg(pid, SIGKILL)
        _ = await waitExit(2)
    }
}
