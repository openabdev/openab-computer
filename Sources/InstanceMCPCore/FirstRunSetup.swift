import Darwin
import Foundation
import Security

/// The launch with no flags (a double-click in Finder): menu bar app plus the loopback backend, with a
/// bearer token created on first run. Launches with flags never reach this code path.
public enum FirstRunSetup {
    /// Where the no-flag launch keeps its bearer token. The installer's token lives under
    /// ~/.config/oab-instance-mcp/token and is untouched by this path.
    public static func tokenPath(home: String) -> String {
        home + "/Library/Application Support/oab-instance-mcp/token"
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

        // Serialize first launches with an exclusive flock on a sibling lock file. Each launch re-reads the
        // token under the lock, so a launch that lost the race reads the winner's token and never replaces it.
        // flock is per open file description, so threads in one process serialize too.
        let lockFd = open("\(dir)/.first-run.lock", O_RDWR | O_CREAT, 0o600)
        guard lockFd >= 0 else { throw FirstRunError.io("cannot open the first-run lock in \(dir): errno \(errno)") }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_EX) == 0 else { throw FirstRunError.io("cannot lock \(dir): errno \(errno)") }

        if let existing = try readToken(at: path) {
            try setMode600(path)
            return (existing, false)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw FirstRunError.randomUnavailable
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        // Write a sibling temp file created at mode 600, then rename it over the target (the file is missing or
        // empty here, under the lock). A reader never sees a partial token, and the file is never readable by
        // other users.
        let tmp = "\(dir)/.token.\(getpid()).\(UUID().uuidString).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw FirstRunError.io("cannot create \(tmp): errno \(errno)") }
        let line = Array((token + "\n").utf8)
        let written = line.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        defer { unlink(tmp) }
        guard written == line.count else { throw FirstRunError.io("short write to \(tmp)") }
        guard rename(tmp, path) == 0 else {
            throw FirstRunError.io("cannot move the token into place at \(path): errno \(errno)")
        }
        try setMode600(path)
        return (token, true)
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
