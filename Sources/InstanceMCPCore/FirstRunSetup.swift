import Darwin
import Foundation
import Security

/// The launch with no flags (a double-click in Finder): menu bar app plus the loopback backend, with a
/// bearer token created on first run. Launches with flags never reach this code path.
public enum FirstRunSetup {
    /// The home directory the no-flag launch writes under: HOME when a launch sets it, otherwise the account
    /// home. A Finder launch sets HOME to the user's home, so users get the same path as before. The test sets
    /// HOME to an isolated directory, because NSHomeDirectory() ignores HOME on macOS.
    public static func homeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let home = environment["HOME"], !home.isEmpty { return home }
        return NSHomeDirectory()
    }

    /// Where the app and the 0.12 installer keep the bearer token: ~/.config/oab-computer/token (mode 600). On the
    /// first run (the directory does not exist yet) the app copies an existing token from `legacyTokenPaths`
    /// here, so the token does not rotate. After that the directory exists and the migration never runs again:
    /// deleting this file rotates the token.
    public static func tokenPath(home: String) -> String {
        home + "/.config/oab-computer/token"
    }

    /// The token path used by the 0.11.0 installer and the installed agent. It is copied from, never moved, so the
    /// installed agent keeps working until its owner upgrades.
    public static func legacyTokenPath(home: String) -> String {
        home + "/.config/oab-instance-mcp/token"
    }

    /// The pre-0.4.0 token path. It is the last source the migration tries, after `legacyTokenPath`; the
    /// installer uses the same order.
    public static func oldestTokenPath(home: String) -> String {
        home + "/.config/oab-mac-agent/token"
    }

    /// The sources the one-shot migration reads, newest first. The first one that holds a usable token wins.
    public static func legacyTokenPaths(home: String) -> [String] {
        [legacyTokenPath(home: home), oldestTokenPath(home: home)]
    }

    /// `~/.config/oab-instance-mcp`: the directory the installer and the installed agent read. A no-flag launch
    /// under a given home uses it for the switchboard config as well.
    public static func configDirectory(home: String) -> String {
        home + "/.config/oab-instance-mcp"
    }

    /// The reverse-attach grant record under `home`: the file FileGrantStore.defaultURL names for the account.
    public static func grantsURL(home: String) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/oab-instance-mcp/grants.json")
    }

    /// The agent log under `home`. The menu's Open Log item opens it, and a LaunchAgent writes it through
    /// StandardErrorPath.
    public static func logPath(home: String) -> String {
        home + "/Library/Logs/oab-instance-mcp/agent.log"
    }

    /// Sends this process's stderr to `path` (append, mode 644), as a LaunchAgent's StandardErrorPath does. A Finder
    /// launch has no LaunchAgent, and LaunchServices discards its stderr, so without this the first-run lines are lost.
    /// Returns false when the file cannot be opened; stderr is then unchanged.
    @discardableResult
    public static func redirectStderr(toLogAt path: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return dup2(fd, STDERR_FILENO) >= 0
    }

    /// True when another process already listens on host:port. Binds a probe socket with SO_REUSEADDR, so
    /// connections in TIME_WAIT do not count, and sends no request to the port.
    public static func isPortInUse(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound != 0 && errno == EADDRINUSE
    }

    /// Shown in an alert when the no-flag launch finds its port taken, for example by the installed agent.
    public static func portInUseMessage(host: String, port: UInt16) -> String {
        "Port \(port) on \(host) is already in use, probably by the installed oab-instance-mcp agent. " +
        "This app did not start. Quit the other process, then open the app again."
    }

    /// True when no flag was given. Finder can pass a `-psn_…` process serial argument on older systems;
    /// that alone still counts as a launch with no flags.
    public static func isNoFlagLaunch(arguments: [String]) -> Bool {
        arguments.allSatisfy { $0.hasPrefix("-psn_") }
    }

    /// What the no-flag launch hands to `main.swift`. It never carries the token itself: the backend reads
    /// the token from `tokenPath`, the same way a `--token-file` launch does.
    public struct Plan: Equatable {
        public let tokenPath: String
        public let tokenCreated: Bool
        /// The Tailscale login to pass as `--allow-login`, or nil when none was detected.
        public let allowLogin: String?
        /// Menu line when the launch runs with the token alone; nil when a login was detected.
        public let notice: String?
        /// Log lines. None of them contains the token.
        public let logLines: [String]
    }

    /// Prepares a no-flag launch: creates or reuses the token file under `home`, then looks up the Tailscale
    /// login. A missing login is not an error: the launch continues with the token alone and says so.
    public static func prepare(home: String,
                               detectLogin: (_ note: (String) -> Void) -> String? = { FirstRunSetup.detectTailscaleLogin(note: $0) }) throws -> Plan {
        let path = tokenPath(home: home)
        let made = try loadOrCreateToken(at: path, legacyPaths: legacyTokenPaths(home: home))
        let state = made.copiedFrom.map { "copied from \($0)" } ?? (made.created ? "created" : "reused")
        var lines = ["no-flag launch: token file \(path) \(state) (mode 600; token not logged)"]
        if let login = detectLogin({ lines.append("no-flag launch: \($0)") }) {
            lines.append("no-flag launch: Tailscale login detected, applied as --allow-login")
            return Plan(tokenPath: path, tokenCreated: made.created, allowLogin: login, notice: nil, logLines: lines)
        }
        lines.append("no-flag launch: \(tokenOnlyNotice)")
        return Plan(tokenPath: path, tokenCreated: made.created, allowLogin: nil, notice: tokenOnlyNotice, logLines: lines)
    }

    /// Test seam: called with the staged file's path just before it is renamed into place. Nil in production.
    static var stagedTokenObserver: ((String) -> Void)?

    /// Returns the token at `path`. When the file is missing or empty and this call created the token's directory
    /// (the one-shot migration), copies the first usable token from `legacyPaths`; otherwise creates a new token.
    /// Once the directory exists the legacy files are never read again, so deleting the token rotates it. The
    /// created format matches scripts/install-prebuilt.sh: `openssl rand -hex 32` (64 hex characters and a
    /// newline), mode 600. Nothing here prints the token.
    ///
    /// The legacy files are read without their own locks: a 0.11.0 installer run must not overlap the first
    /// 0.12 launch. If two first runs race, the one that creates the directory is the one that migrates; the
    /// other may generate a fresh token, which is the safe outcome (a new token, never a leaked one).
    /// - Returns: the token; `created` when this call generated it; `copiedFrom` when it came from a legacy file.
    public static func loadOrCreateToken(at path: String, legacyPaths: [String] = [])
        throws -> (token: String, created: Bool, copiedFrom: String?) {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: (dir as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        // mkdir is the atomic "first run" test: only the call that creates the directory may migrate.
        var mayMigrate = false
        if mkdir(dir, 0o700) == 0 {
            mayMigrate = true
        } else if errno != EEXIST {
            throw FirstRunError.io("cannot create \(dir): errno \(errno)")
        }

        // The same lock as scripts/install-prebuilt.sh: an atomic mkdir on "<token>.lock" (mode 700), tried 50
        // times 0.1 s apart, removed on exit. Sharing this lock (not a private one) means a first no-flag launch
        // and an installer run cannot both see a missing token and rotate it under each other.
        let lock = lockPath(for: path)
        var acquired = false
        for _ in 0..<50 {
            if mkdir(lock, 0o700) == 0 { acquired = true; break }
            usleep(100_000)
        }
        guard acquired else { throw FirstRunError.io("timed out waiting for the token lock at \(lock)") }
        defer { try? FileManager.default.removeItem(atPath: lock) }

        // Re-read under the lock: a launch that lost the race reads the winner's token and never replaces it.
        if let existing = try readToken(at: path) {
            try setMode600(path)
            return (existing, false, nil)
        }

        // The staged file lives in the lock directory and is created at mode 600 with O_EXCL, for a copy as for a
        // generated token, so no byte of a token is ever readable by another user.
        let tmp = lock + "/token"
        var copiedFrom: String?
        var token = ""
        if mayMigrate {
            for legacy in legacyPaths {
                if let inherited = try readToken(at: legacy) {
                    token = inherited
                    copiedFrom = legacy
                    break
                }
            }
        }
        // Copy the legacy token byte for byte (the old file stays for the installed agent); generate otherwise.
        var content: [UInt8]
        if let legacy = copiedFrom {
            do { content = [UInt8](try Data(contentsOf: URL(fileURLWithPath: legacy))) } catch {
                throw FirstRunError.io("cannot read the token from \(legacy): \(error.localizedDescription)")
            }
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw FirstRunError.randomUnavailable
            }
            token = bytes.map { String(format: "%02x", $0) }.joined()
            content = Array((token + "\n").utf8)
        }
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw FirstRunError.io("cannot create the temp token in \(lock): errno \(errno)") }
        let written = content.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == content.count else { throw FirstRunError.io("short write to \(tmp)") }
        stagedTokenObserver?(tmp)
        guard rename(tmp, path) == 0 else {
            throw FirstRunError.io("cannot move the token into place at \(path): errno \(errno)")
        }
        try setMode600(path)
        return (token, copiedFrom == nil, copiedFrom)
    }

    /// The lock directory the installer uses for the token file: "$TOKEN_FILE.lock".
    public static func lockPath(for tokenPath: String) -> String {
        tokenPath + ".lock"
    }

    /// The login the installer passes to --allow-login. It reads the same fields from
    /// `tailscale status --self --peers=false --json`: Self.DNSName, Self.UserID (digits), and
    /// User.<UserID>.LoginName. Returns nil when any of them is missing or empty.
    public static func tailscaleLogin(statusJSON: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: statusJSON)) as? [String: Any],
              let me = root["Self"] as? [String: Any],
              let dns = me["DNSName"] as? String,
              !dns.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty,
              let uid = me["UserID"] as? NSNumber,
              let users = root["User"] as? [String: Any],
              let user = users[uid.stringValue] as? [String: Any],
              let login = user["LoginName"] as? String,
              !login.isEmpty
        else { return nil }
        return login
    }

    /// The machine's tailnet name from the same status JSON: Self.DNSName without its trailing dot. Nil when missing.
    public static func tailscaleSelfDNSName(statusJSON: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: statusJSON)) as? [String: Any],
              let me = root["Self"] as? [String: Any],
              let dns = me["DNSName"] as? String else { return nil }
        let name = dns.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return name.isEmpty ? nil : name
    }

    /// Why one run of the Tailscale CLI gave no login. Logged by name; none of these carries output or a login.
    public enum TailscaleFailure: Equatable, Sendable {
        case launchFailed
        case timeout
        case nonZeroExit(Int32)
        case emptyOutput
        /// Exit 0 but the output is not a status JSON with a login. The Tailscale.app binary prints
        /// "The Tailscale GUI failed to start" and exits 0 when it is not started from a terminal.
        case parseNil
    }

    /// One run of `cli`: its stdout and exit status, or the reason it did not finish.
    public enum TailscaleRun: Equatable, Sendable {
        case finished(output: Data, status: Int32)
        case timeout
        case launchFailed
    }

    public typealias TailscaleRunner = (_ cli: String, _ timeout: TimeInterval) -> TailscaleRun
    /// Like `TailscaleRunner` for any argument list. `TailnetExposure` uses it for `serve` and the status reads.
    public typealias TailscaleCommandRunner = (_ cli: String, _ arguments: [String], _ timeout: TimeInterval) -> TailscaleRun

    static let tailscaleStatusArguments = ["status", "--self", "--peers=false", "--json"]

    /// The environment for the CLI. The Tailscale.app binary acts as the command-line tool only when TERM_PROGRAM
    /// is set (as in any terminal); without it, as in a Finder or launchd launch, it prints a GUI error to stdout
    /// and exits 0, so the status could never be parsed. Measured on two Macs: only that variable decides it.
    static func tailscaleEnvironment(_ base: [String: String]) -> [String: String] {
        var env = base
        if (env["TERM_PROGRAM"] ?? "").isEmpty { env["TERM_PROGRAM"] = "oab-instance-mcp" }
        return env
    }

    /// The real runner: starts `cli` with the status arguments and `tailscaleEnvironment`, drains stdout while it
    /// waits (a full pipe cannot stall it), and kills it at the timeout.
    public static let systemTailscaleRunner: TailscaleRunner = { cli, timeout in
        systemTailscaleCommandRunner(cli, tailscaleStatusArguments, timeout)
    }

    /// The same runner for any arguments (same environment, drain, timeout and kill). The only place that starts the CLI.
    public static let systemTailscaleCommandRunner: TailscaleCommandRunner = { cli, arguments, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        process.environment = tailscaleEnvironment(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        let collected = NSMutableData()
        let lock = NSLock()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); collected.append(chunk); lock.unlock()
        }
        defer { out.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch { return .launchFailed }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return .timeout
        }
        process.waitUntilExit()
        usleep(20_000) // let the handler deliver the last chunk
        lock.lock(); defer { lock.unlock() }
        return .finished(output: collected as Data, status: process.terminationStatus)
    }

    /// Looks up the Tailscale login with up to `attempts` tries inside a total `budget`. Each try goes through
    /// every CLI candidate (the app bundle CLI first, then PATH and the Homebrew locations), and a failing
    /// candidate no longer ends the search. Between tries it waits `backoff[n]` seconds. `note` receives one line
    /// per failure (attempt number, CLI path, reason); a line never contains the output or the login.
    /// Returns nil when every try failed, and the launch then serves with the bearer token only.
    public static func detectTailscaleLogin(
        timeout: TimeInterval = 3,
        budget: TimeInterval = 8,
        attempts: Int = 3,
        backoff: [TimeInterval] = [0.5, 1.0],
        candidates: () -> [String] = { FirstRunSetup.tailscaleCandidates() },
        runner: TailscaleRunner = FirstRunSetup.systemTailscaleRunner,
        now: () -> Date = { Date() },
        sleep: (TimeInterval) -> Void = { usleep(UInt32($0 * 1_000_000)) },
        note: (String) -> Void = { _ in }
    ) -> String? {
        let start = now()
        let clis = candidates()
        if clis.isEmpty { note("Tailscale login: no tailscale CLI found"); return nil }
        for attempt in 1...max(1, attempts) {
            for cli in clis {
                let remaining = budget - now().timeIntervalSince(start)
                guard remaining > 0.05 else {
                    note("Tailscale login: attempt \(attempt) skipped, the \(Int(budget)) s budget is used up")
                    return nil
                }
                let run = runner(cli, min(timeout, remaining))
                switch classify(run) {
                case .success(let login):
                    if attempt > 1 { note("Tailscale login: found on attempt \(attempt)") }
                    return login
                case .failure(let why):
                    note("Tailscale login: attempt \(attempt) with \(cli) failed: \(describe(why))")
                }
            }
            if attempt < attempts, attempt - 1 < backoff.count {
                let wait = min(backoff[attempt - 1], max(0, budget - now().timeIntervalSince(start)))
                if wait > 0 { sleep(wait) }
            }
        }
        return nil
    }

    static func classify(_ run: TailscaleRun) -> Result<String, TailscaleFailureBox> {
        switch run {
        case .launchFailed: return .failure(.init(.launchFailed))
        case .timeout: return .failure(.init(.timeout))
        case let .finished(output, status):
            if status != 0 { return .failure(.init(.nonZeroExit(status))) }
            if output.isEmpty { return .failure(.init(.emptyOutput)) }
            guard let login = tailscaleLogin(statusJSON: output) else { return .failure(.init(.parseNil)) }
            return .success(login)
        }
    }

    /// `Result` needs an `Error` failure type.
    struct TailscaleFailureBox: Error { let failure: TailscaleFailure; init(_ f: TailscaleFailure) { failure = f } }

    static func describe(_ box: TailscaleFailureBox) -> String {
        switch box.failure {
        case .launchFailed: return "could not start"
        case .timeout: return "timeout"
        case .nonZeroExit(let code): return "exit status \(code)"
        case .emptyOutput: return "empty output"
        case .parseNil: return "output had no login (parse returned nil)"
        }
    }

    /// Shown in the menu and logged when no Tailscale login is found. The launch continues with the token alone.
    public static let tokenOnlyNotice = "Tailscale login not detected: serving with the bearer token only."

    public static func tailscaleCandidates() -> [String] {
        var found: [String] = []
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        if FileManager.default.isExecutableFile(atPath: app) { found.append(app) }
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            let cli = dir + "/tailscale"
            if FileManager.default.isExecutableFile(atPath: cli), !found.contains(cli) { found.append(cli) }
        }
        return found
    }

    /// nil when the file is missing or holds only whitespace. Throws when the file exists but cannot be
    /// read, so a launch never replaces a token it could not read.
    private static func readToken(at path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let s: String
        do {
            s = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw FirstRunError.io("cannot read the token file at \(path); it was left unchanged")
        }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func setMode600(_ path: String) throws {
        guard chmod(path, 0o600) == 0 else { throw FirstRunError.io("cannot set mode 600 on \(path)") }
    }
}

public enum FirstRunError: Error, CustomStringConvertible {
    case randomUnavailable
    case io(String)

    public var description: String {
        switch self {
        case .randomUnavailable: return "the system random source is unavailable"
        case .io(let message): return message
        }
    }
}
