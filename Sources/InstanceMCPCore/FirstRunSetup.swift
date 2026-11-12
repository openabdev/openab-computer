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

    /// Where the no-flag launch keeps its bearer token: the installer's token file. The installed agent and the
    /// app therefore share one token, and clients need to copy only one.
    public static func tokenPath(home: String) -> String {
        home + "/.config/oab-instance-mcp/token"
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
    public static func prepare(home: String, detectLogin: () -> String? = { FirstRunSetup.detectTailscaleLogin() }) throws -> Plan {
        let path = tokenPath(home: home)
        let made = try loadOrCreateToken(at: path)
        var lines = ["no-flag launch: token file \(path) \(made.created ? "created" : "reused") (mode 600; token not logged)"]
        if let login = detectLogin() {
            lines.append("no-flag launch: Tailscale login detected, applied as --allow-login")
            return Plan(tokenPath: path, tokenCreated: made.created, allowLogin: login, notice: nil, logLines: lines)
        }
        lines.append("no-flag launch: \(tokenOnlyNotice)")
        return Plan(tokenPath: path, tokenCreated: made.created, allowLogin: nil, notice: tokenOnlyNotice, logLines: lines)
    }

    /// Returns the token at `path`, creating it when the file is missing or empty. The format matches
    /// scripts/install-prebuilt.sh: `openssl rand -hex 32` (64 hex characters and a newline), mode 600.
    /// The token is returned to the caller only; nothing here prints it.
    /// - Returns: the token and whether this call created the file.
    public static func loadOrCreateToken(at path: String) throws -> (token: String, created: Bool) {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // The same lock as scripts/install-prebuilt.sh: an atomic mkdir on "<token>.lock", tried 50 times 0.1 s
        // apart, removed on exit. Sharing this lock (not a private one) means a first no-flag launch and an
        // installer run cannot both see a missing token and rotate it under each other.
        let lock = lockPath(for: path)
        var acquired = false
        for _ in 0..<50 {
            if mkdir(lock, 0o777) == 0 { acquired = true; break }
            usleep(100_000)
        }
        guard acquired else { throw FirstRunError.io("timed out waiting for the token lock at \(lock)") }
        defer { try? FileManager.default.removeItem(atPath: lock) }

        // Re-read under the lock: a launch that lost the race reads the winner's token and never replaces it.
        if let existing = try readToken(at: path) {
            try setMode600(path)
            return (existing, false)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw FirstRunError.randomUnavailable
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        // Write the temp file inside the lock directory, at mode 600, then rename it over the target, as the
        // installer does with "$LOCK/token". A reader never sees a partial token, and other users never read it.
        let tmp = lock + "/token"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw FirstRunError.io("cannot create the temp token in \(lock): errno \(errno)") }
        let line = Array((token + "\n").utf8)
        let written = line.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == line.count else { throw FirstRunError.io("short write to \(tmp)") }
        guard rename(tmp, path) == 0 else {
            throw FirstRunError.io("cannot move the token into place at \(path): errno \(errno)")
        }
        try setMode600(path)
        return (token, true)
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

    /// Runs the Tailscale CLI the way the installer does and parses its status. The app bundle's CLI
    /// is tried first, then `tailscale` on PATH and the usual Homebrew and /usr/local locations, because
    /// a GUI launch does not inherit the shell PATH. Returns nil on any failure, including a timeout.
    public static func detectTailscaleLogin(timeout: TimeInterval = 5) -> String? {
        for cli in tailscaleCandidates() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["status", "--self", "--peers=false", "--json"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continue }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return tailscaleLogin(statusJSON: data)
        }
        return nil
    }

    /// Shown in the menu and logged when no Tailscale login is found. The launch continues with the token alone.
    public static let tokenOnlyNotice = "Tailscale login not detected: serving with the bearer token only."

    static func tailscaleCandidates() -> [String] {
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
