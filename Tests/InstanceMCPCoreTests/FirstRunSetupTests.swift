import Darwin
import Foundation
import XCTest
@testable import InstanceMCPCore

final class FirstRunSetupTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = (FileManager.default.temporaryDirectory
            .appendingPathComponent("first-run-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func mode(of path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testNoArgumentsIsTheFirstRunLaunchAndFlagsAreNot() {
        XCTAssertTrue(FirstRunSetup.isNoFlagLaunch(arguments: []))
        XCTAssertTrue(FirstRunSetup.isNoFlagLaunch(arguments: ["-psn_0_12345"]))
        XCTAssertFalse(FirstRunSetup.isNoFlagLaunch(arguments: ["--menu-bar"]))
        XCTAssertFalse(FirstRunSetup.isNoFlagLaunch(arguments: ["--port", "8796"]))
        XCTAssertFalse(FirstRunSetup.isNoFlagLaunch(arguments: ["--token-file", "/tmp/t", "--menu-bar"]))
    }

    func testTokenPathIsTheAppTokenFileAndTheOldPathIsTheLegacyOne() {
        XCTAssertEqual(FirstRunSetup.tokenPath(home: "/Users/x"),
                       "/Users/x/.config/oab-computer/token")
        XCTAssertEqual(FirstRunSetup.legacyTokenPath(home: "/Users/x"),
                       "/Users/x/.config/oab-instance-mcp/token")
    }

    func testPortInUseIsDetectedWhileAnotherProcessListens() throws {
        let port = UInt16(40_000 + Int.random(in: 0..<20_000))
        XCTAssertFalse(FirstRunSetup.isPortInUse(host: "127.0.0.1", port: port), "a free port is reported free")

        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var on: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        XCTAssertEqual(inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr), 1)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)

        XCTAssertTrue(FirstRunSetup.isPortInUse(host: "127.0.0.1", port: port), "a listening port is reported in use")
        XCTAssertTrue(FirstRunSetup.portInUseMessage(host: "127.0.0.1", port: port).contains("\(port)"))
    }

    // MARK: no-flag startup (the same `prepare` call main.swift makes)

    func testNoFlagStartupCreatesTokenWithMode600AndLaterStartupReusesIt() throws {
        let first = try FirstRunSetup.prepare(home: home, detectLogin: { _ in nil })
        XCTAssertEqual(first.tokenPath, FirstRunSetup.tokenPath(home: home))
        XCTAssertTrue(first.tokenCreated)
        XCTAssertEqual(try mode(of: first.tokenPath), 0o600)
        let stored = try String(contentsOfFile: first.tokenPath, encoding: .utf8)
        let token = stored.trimmingCharacters(in: .newlines)
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(stored, token + "\n", "same format as `openssl rand -hex 32` written by the installer")

        let second = try FirstRunSetup.prepare(home: home, detectLogin: { _ in nil })
        XCTAssertFalse(second.tokenCreated)
        XCTAssertEqual(try String(contentsOfFile: second.tokenPath, encoding: .utf8), stored,
                       "a later launch reuses the stored token")
        XCTAssertEqual(try mode(of: second.tokenPath), 0o600)
    }

    func testNoFlagStartupWithoutTailscaleLoginSaysSoAndStillStarts() throws {
        let plan = try FirstRunSetup.prepare(home: home, detectLogin: { _ in nil })
        XCTAssertNil(plan.allowLogin)
        XCTAssertEqual(plan.notice, FirstRunSetup.tokenOnlyNotice)
        XCTAssertTrue(plan.logLines.contains { $0.contains(FirstRunSetup.tokenOnlyNotice) })
    }

    func testNoFlagStartupAppliesADetectedLoginAndLogsNoToken() throws {
        let plan = try FirstRunSetup.prepare(home: home, detectLogin: { _ in "owner@example.com" })
        XCTAssertEqual(plan.allowLogin, "owner@example.com")
        XCTAssertNil(plan.notice)
        let token = try String(contentsOfFile: plan.tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(plan.logLines.joined(separator: "\n").contains(token))
    }

    private func writeToken(_ token: String, at path: String, mode: mode_t) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try (token + "\n").write(toFile: path, atomically: false, encoding: .utf8)
        XCTAssertEqual(chmod(path, mode), 0)
    }

    func testOldTokenIsCopiedOnFirstRunAndTheOldFileIsKept() throws {
        let old = String(repeating: "a", count: 64)
        let legacy = FirstRunSetup.legacyTokenPath(home: home)
        try writeToken(old, at: legacy, mode: 0o644)

        let plan = try FirstRunSetup.prepare(home: home, detectLogin: { _ in nil })
        XCTAssertEqual(plan.tokenPath, FirstRunSetup.tokenPath(home: home))
        XCTAssertFalse(plan.tokenCreated, "a copied token is not a new one")
        XCTAssertEqual(try String(contentsOfFile: plan.tokenPath, encoding: .utf8), old + "\n",
                       "the 0.11.0 token is copied byte for byte")
        XCTAssertEqual(try mode(of: plan.tokenPath), 0o600)
        XCTAssertEqual(try String(contentsOfFile: legacy, encoding: .utf8), old + "\n",
                       "the 0.11.0 file is copied, not moved, so the installed agent keeps working")
        XCTAssertTrue(plan.logLines.contains { $0.contains("copied from \(legacy)") })
        XCTAssertFalse(plan.logLines.joined(separator: "\n").contains(old), "the token is not logged")
    }

    /// The staged copy must be private from the moment it exists, even when the legacy file is 0644.
    func testStagedCopyOfALooseLegacyTokenIsNeverGroupOrOtherAccessible() throws {
        let old = String(repeating: "c", count: 64)
        let legacy = FirstRunSetup.legacyTokenPath(home: home)
        try writeToken(old, at: legacy, mode: 0o644)
        let path = FirstRunSetup.tokenPath(home: home)

        var stagedMode = -1
        var lockMode = -1
        var observed = false
        FirstRunSetup.stagedTokenObserver = { staged in
            observed = true
            stagedMode = (try? self.mode(of: staged)) ?? -1
            lockMode = (try? self.mode(of: (staged as NSString).deletingLastPathComponent)) ?? -1
        }
        defer { FirstRunSetup.stagedTokenObserver = nil }

        let made = try FirstRunSetup.loadOrCreateToken(at: path, legacyPaths: [legacy])
        XCTAssertEqual(made.copiedFrom, legacy)
        XCTAssertTrue(observed, "the copy was staged in the lock directory")
        XCTAssertEqual(stagedMode & 0o077, 0, "the staged copy has no group or other bits")
        XCTAssertEqual(stagedMode, 0o600)
        XCTAssertEqual(lockMode, 0o700, "the lock directory is private")
        XCTAssertEqual(try mode(of: path), 0o600)
        XCTAssertEqual(try mode(of: (path as NSString).deletingLastPathComponent), 0o700)
    }

    /// Deleting the new token rotates it: the migration ran once, when the directory was created.
    func testDeletingTheNewTokenGeneratesAFreshOneAndNeverCopiesTheOldOneBack() throws {
        let old = String(repeating: "a", count: 64)
        let legacy = FirstRunSetup.legacyTokenPath(home: home)
        try writeToken(old, at: legacy, mode: 0o600)
        let first = try FirstRunSetup.prepare(home: home, detectLogin: { _ in nil })
        XCTAssertEqual(try String(contentsOfFile: first.tokenPath, encoding: .utf8), old + "\n")

        try FileManager.default.removeItem(atPath: first.tokenPath)
        let second = try FirstRunSetup.prepare(home: home, detectLogin: { _ in nil })
        XCTAssertTrue(second.tokenCreated, "a fresh token is generated")
        let fresh = try String(contentsOfFile: second.tokenPath, encoding: .utf8)
        XCTAssertNotEqual(fresh, old + "\n", "the legacy token is not copied back")
        XCTAssertEqual(fresh.count, 65)
        XCTAssertEqual(try String(contentsOfFile: legacy, encoding: .utf8), old + "\n", "the legacy file is untouched")
        XCTAssertTrue(second.logLines.contains { $0.contains("created") })
    }

    /// An existing token directory means the migration is over, even when it holds no token.
    func testExistingEmptyTokenDirectoryMeansNoMigration() throws {
        let legacy = FirstRunSetup.legacyTokenPath(home: home)
        try writeToken(String(repeating: "a", count: 64), at: legacy, mode: 0o600)
        let path = FirstRunSetup.tokenPath(home: home)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let made = try FirstRunSetup.loadOrCreateToken(at: path, legacyPaths: [legacy])
        XCTAssertTrue(made.created)
        XCTAssertNil(made.copiedFrom)
    }

    /// The 0.11.0 token wins over the pre-0.4.0 one, and a whitespace-only file counts as absent.
    func testLegacySourceOrderIsTheElevenTokenThenThePreFourToken() throws {
        let eleven = String(repeating: "b", count: 64)
        let ancient = String(repeating: "d", count: 64)
        let sources = FirstRunSetup.legacyTokenPaths(home: home)
        XCTAssertEqual(sources, [FirstRunSetup.legacyTokenPath(home: home), FirstRunSetup.oldestTokenPath(home: home)])
        try writeToken(eleven, at: sources[0], mode: 0o600)
        try writeToken(ancient, at: sources[1], mode: 0o600)
        let both = try FirstRunSetup.prepare(home: home, detectLogin: { _ in nil })
        XCTAssertEqual(try String(contentsOfFile: both.tokenPath, encoding: .utf8), eleven + "\n")
        XCTAssertEqual(try String(contentsOfFile: sources[1], encoding: .utf8), ancient + "\n", "the oldest file is untouched")

        // Only the pre-0.4.0 file usable (the 0.11.0 one is whitespace only): it is copied.
        try FileManager.default.removeItem(atPath: (both.tokenPath as NSString).deletingLastPathComponent)
        try "  \n".write(toFile: sources[0], atomically: false, encoding: .utf8)
        let onlyOldest = try FirstRunSetup.prepare(home: home, detectLogin: { _ in nil })
        XCTAssertEqual(try String(contentsOfFile: onlyOldest.tokenPath, encoding: .utf8), ancient + "\n")

        // Both whitespace only: a fresh token.
        try FileManager.default.removeItem(atPath: (both.tokenPath as NSString).deletingLastPathComponent)
        try "\n".write(toFile: sources[1], atomically: false, encoding: .utf8)
        let neither = try FirstRunSetup.prepare(home: home, detectLogin: { _ in nil })
        XCTAssertTrue(neither.tokenCreated)
    }

    func testExistingNewTokenIsNotReplacedByTheOldOne() throws {
        let path = FirstRunSetup.tokenPath(home: home)
        let current = String(repeating: "b", count: 64)
        try writeToken(current, at: path, mode: 0o600)
        try writeToken(String(repeating: "a", count: 64), at: FirstRunSetup.legacyTokenPath(home: home), mode: 0o600)

        let plan = try FirstRunSetup.prepare(home: home, detectLogin: { _ in nil })
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), current + "\n")
        XCTAssertTrue(plan.logLines.contains { $0.contains("reused") })
    }

    func testExistingTokenIsReusedEvenWhenItsModeWasLoosened() throws {
        let path = FirstRunSetup.tokenPath(home: home)
        let first = try FirstRunSetup.loadOrCreateToken(at: path)
        XCTAssertEqual(chmod(path, 0o644), 0)

        let again = try FirstRunSetup.loadOrCreateToken(at: path)
        XCTAssertEqual(again.token, first.token)
        XCTAssertEqual(try mode(of: path), 0o600, "every launch restores mode 600, as the installer does")
    }

    func testEmptyTokenFileIsReplacedNotReused() throws {
        let path = FirstRunSetup.tokenPath(home: home)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try "  \n".write(toFile: path, atomically: false, encoding: .utf8)

        let result = try FirstRunSetup.loadOrCreateToken(at: path)
        XCTAssertTrue(result.created)
        XCTAssertEqual(result.token.count, 64)
    }

    func testUnreadableTokenFileIsNotRotated() throws {
        let path = FirstRunSetup.tokenPath(home: home)
        let first = try FirstRunSetup.loadOrCreateToken(at: path)
        XCTAssertEqual(chmod(path, 0o000), 0)
        defer { chmod(path, 0o600) }

        XCTAssertThrowsError(try FirstRunSetup.loadOrCreateToken(at: path))
        XCTAssertEqual(chmod(path, 0o600), 0)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), first.token + "\n",
                       "a file that cannot be read is an error, not a reason to rotate the token")
    }

    /// Several first launches racing on one path must end with one token that every launch reads back.
    /// Threads in one process share the PID, so this also covers the per-attempt temp file names.
    func testConcurrentFirstRunsAgreeOnOneToken() throws {
        let path = FirstRunSetup.tokenPath(home: home)
        let lock = NSLock()
        var tokens: [String] = []
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            guard let made = try? FirstRunSetup.loadOrCreateToken(at: path) else { return }
            lock.lock()
            tokens.append(made.token)
            lock.unlock()
        }
        XCTAssertEqual(tokens.count, 16, "every racing launch succeeds")
        XCTAssertEqual(Set(tokens).count, 1, "every racing launch uses the same token")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), (tokens.first ?? "") + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".lock"), "the lock directory is removed")
    }

    /// The installer and the no-flag launch must use one lock. While an installer run holds "token.lock", a first
    /// launch waits and writes nothing; when the installer releases it, the launch reuses the installer's token.
    func testFirstRunWaitsForTheInstallersTokenLockAndReusesItsToken() throws {
        let path = FirstRunSetup.tokenPath(home: home)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let lock = path + ".lock"
        XCTAssertEqual(mkdir(lock, 0o777), 0, "the installer's lock is taken first")

        let outcome = NSLock()
        var result: (token: String, created: Bool, copiedFrom: String?)?
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let made = try? FirstRunSetup.loadOrCreateToken(at: path)
            outcome.lock()
            result = made
            outcome.unlock()
            finished.signal()
        }

        usleep(400_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the first launch writes nothing while the lock is held")

        // The installer's own protocol: write "$LOCK/token", move it into place, then remove the lock directory.
        let installerToken = String(repeating: "ab", count: 32)
        XCTAssertTrue(FileManager.default.createFile(atPath: lock + "/token",
                                                     contents: Data((installerToken + "\n").utf8),
                                                     attributes: [.posixPermissions: 0o600]))
        XCTAssertEqual(rename(lock + "/token", path), 0)
        XCTAssertEqual(rmdir(lock), 0)

        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success, "the waiting launch proceeds once the lock is free")
        outcome.lock()
        let made = result
        outcome.unlock()
        XCTAssertEqual(made?.token, installerToken, "the launch uses the installer's token")
        XCTAssertEqual(made?.created, false)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), installerToken + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock), "the launch leaves no lock directory behind")
    }

    func testTailscaleLoginIsReadTheSameWayTheInstallerReadsIt() {
        let json = """
        {"Self":{"DNSName":"mac.tailb836bb.ts.net.","UserID":12345},
         "User":{"12345":{"LoginName":"owner@example.com"}}}
        """
        XCTAssertEqual(FirstRunSetup.tailscaleLogin(statusJSON: Data(json.utf8)), "owner@example.com")
    }

    func testTailscaleLoginIsNilWhenAnyInstallerFieldIsMissing() {
        let noDNS = #"{"Self":{"DNSName":"","UserID":1},"User":{"1":{"LoginName":"a@b.c"}}}"#
        let badUID = #"{"Self":{"DNSName":"m.ts.net.","UserID":"abc"},"User":{"abc":{"LoginName":"a@b.c"}}}"#
        let noUser = #"{"Self":{"DNSName":"m.ts.net.","UserID":1},"User":{"2":{"LoginName":"a@b.c"}}}"#
        let emptyLogin = #"{"Self":{"DNSName":"m.ts.net.","UserID":1},"User":{"1":{"LoginName":""}}}"#
        let notJSON = "Logged out"
        for case let body in [noDNS, badUID, noUser, emptyLogin, notJSON] {
            XCTAssertNil(FirstRunSetup.tailscaleLogin(statusJSON: Data(body.utf8)), body)
        }
    }

    func testTokenOnlyNoticeNamesTheFallback() {
        XCTAssertTrue(FirstRunSetup.tokenOnlyNotice.contains("bearer token only"))
    }

    func testAgentLogIsTheFileTheMenuOpensUnderTheSameHome() {
        XCTAssertEqual(FirstRunSetup.logPath(home: "/Users/x"),
                       "/Users/x/Library/Logs/oab-instance-mcp/agent.log")
        XCTAssertEqual(FirstRunSetup.grantsURL(home: "/Users/x").path,
                       "/Users/x/Library/Application Support/oab-instance-mcp/grants.json")
        XCTAssertEqual(FirstRunSetup.configDirectory(home: "/Users/x"), "/Users/x/.config/oab-instance-mcp")
    }

    // MARK: flag launch (process level, the built `oab-instance-mcp` binary)

    private func builtBinary() throws -> URL {
        let dir = Bundle(for: FirstRunSetupTests.self).bundleURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent("oab-instance-mcp")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("oab-instance-mcp is not built next to the test bundle: \(url.path)")
        }
        return url
    }

    /// HTTP status of a request to `url`, or 0 when nothing answered.
    private func status(of url: URL, bearer: String?) -> Int {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let done = DispatchSemaphore(value: 0)
        var code = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        done.wait()
        return code
    }

    func testFlagLaunchStillServesMCPWithTheTokenFromItsFile() throws {
        let binary = try builtBinary()
        let tokenFile = home + "/flag-token"
        let token = "flag-test-" + UUID().uuidString.lowercased()
        try (token + "\n").write(toFile: tokenFile, atomically: false, encoding: .utf8)
        let port = 40_000 + Int.random(in: 0..<20_000)

        let child = Process()
        child.executableURL = binary
        child.arguments = ["--host", "127.0.0.1", "--port", String(port), "--token-file", tokenFile,
                           "--no-attach", "--no-grant-persistence", "--quiet"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["OAB_INSTANCE_MCP_NO_TAILNET_EXPOSURE"] = "1"
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }

        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var anonymous = 0
        for _ in 0..<100 {
            anonymous = status(of: url, bearer: nil)
            if anonymous != 0 { break }
            usleep(100_000)
        }
        XCTAssertEqual(anonymous, 401, "the flag launch answers /mcp and refuses a request without a bearer token")
        let accepted = status(of: url, bearer: token)
        XCTAssertNotEqual(accepted, 0, "the flag launch answers a request that carries the token")
        XCTAssertEqual(accepted, 405, "the token from --token-file is accepted: GET /mcp answers 405, not 401")
    }

    // MARK: no-flag launch (process level, no arguments)

    /// Polls `url` until something answers or the attempts run out. Returns the last status (0 when nothing answered).
    private func waitForStatus(of url: URL, bearer: String?, attempts: Int = 200) -> Int {
        var code = 0
        for _ in 0..<attempts {
            code = status(of: url, bearer: bearer)
            if code != 0 { break }
            usleep(100_000)
        }
        return code
    }

    private func launchWithoutArguments(_ binary: URL, port: UInt16? = nil) throws -> Process {
        // HOME isolates the token, the agent log, the grant store and the switchboard config. The wizard's saved
        // state lives in the app's UserDefaults domain, which HOME does not move: a run on a developer Mac writes
        // those two keys (hasShown and the core-granted record) for that domain.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        // Moves only the no-flag launch's port, for the free-port test. Unset means the default 8795.
        environment["OAB_INSTANCE_MCP_FIRST_RUN_PORT"] = port.map(String.init)
        // Structural guard: the test-launched binary builds no TailnetExposure, so it can never run `tailscale serve`.
        environment["OAB_INSTANCE_MCP_NO_TAILNET_EXPOSURE"] = "1"
        let child = Process()
        child.executableURL = binary
        child.arguments = []
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        return child
    }

    private func stop(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        child.waitUntilExit()
    }

    /// Names the process listening on 127.0.0.1:8795, as lsof reports it.
    private func holderOfDefaultPort() -> String {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-iTCP:8795", "-sTCP:LISTEN", "-Fpc"]
        let out = Pipe()
        lsof.standardOutput = out
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return "an unknown process" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        var pid = "", command = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p"), pid.isEmpty { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), command.isEmpty { command = String(line.dropFirst()) }
        }
        return command.isEmpty ? "an unknown process" : "\(command) (pid \(pid))"
    }

    /// A loopback port nothing is listening on, so the no-flag launch under test can bind it.
    private func freePort() -> UInt16 {
        for _ in 0..<100 {
            let candidate = UInt16(40_000 + Int.random(in: 0..<20_000))
            if !FirstRunSetup.isPortInUse(host: "127.0.0.1", port: candidate) { return candidate }
        }
        return 40_000
    }

    /// Whether the no-flag launch found a Tailscale login. When it did, the launch also requires that identity
    /// (`--allow-login`), so a bearer token alone is refused. The test checks the behavior the launch has.
    private func tailscaleLoginDetected() -> Bool {
        let log = (try? String(contentsOfFile: FirstRunSetup.logPath(home: home), encoding: .utf8)) ?? ""
        return log.contains("Tailscale login detected")
    }

    /// The agent log as bytes, and the text appended after `offset` bytes. Used to read the refusal reason of one request.
    private func logBytes() -> Data {
        (try? Data(contentsOf: URL(fileURLWithPath: FirstRunSetup.logPath(home: home)))) ?? Data()
    }

    private func logSince(_ offset: Int) -> String {
        String(decoding: logBytes().dropFirst(offset), as: UTF8.self)
    }

    /// A wrong bearer must be refused for the "bad token" reason, read from the new log lines. The bearer check runs
    /// first, so this holds with or without a Tailscale login. It also shows the request reached this server, not
    /// another process on the port. A correct token must pass the bearer check. When a Tailscale login is detected,
    /// the refusal must then be the missing identity; otherwise the token is accepted.
    private func assertTokenAuthentication(url: URL, token: String, _ label: String) {
        let beforeWrong = logBytes().count
        XCTAssertEqual(status(of: url, bearer: "wrong-" + UUID().uuidString.lowercased()), 401,
                       "\(label): a wrong bearer is refused")
        XCTAssertTrue(logSince(beforeWrong).contains("deny GET /mcp from local: bad token"),
                      "\(label): a wrong bearer is refused for the bad-token reason")

        let beforeToken = logBytes().count
        let code = status(of: url, bearer: token)
        if tailscaleLoginDetected() {
            XCTAssertEqual(code, 401, "\(label): a detected Tailscale login is also required, so the bearer alone is refused")
            XCTAssertTrue(logSince(beforeToken).contains("deny GET /mcp from local: no Tailscale identity on request"),
                          "\(label): the refusal is the missing Tailscale identity, after the bearer check passed")
        } else {
            XCTAssertNotEqual(code, 0, "\(label): the request got an HTTP response")
            XCTAssertEqual(code, 405, "\(label) is accepted: GET /mcp answers 405, not 401")
        }
    }

    func testNoArgumentLaunchCreatesTokenAndServesMCP() throws {
        let binary = try builtBinary()
        // Runs on a free port through the test seam, so a busy 8795 on a developer Mac does not affect it.
        // The default port is checked only by testNoArgumentLaunchUsesDefaultPortWhenItIsFree.
        let port = freePort()

        let tokenPath = FirstRunSetup.tokenPath(home: home)
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!

        let first = try launchWithoutArguments(binary, port: port)
        defer { stop(first) }
        XCTAssertEqual(waitForStatus(of: url, bearer: nil), 401,
                       "the no-flag launch serves /mcp on 127.0.0.1 and refuses a request without a bearer")
        XCTAssertEqual(try mode(of: tokenPath), 0o600, "the first launch creates the token file at mode 600")
        let token = try String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(token.count, 64)
        assertTokenAuthentication(url: url, token: token, "the token created on first run")
        stop(first)

        // Wait for the port to free before the second launch.
        for _ in 0..<50 where FirstRunSetup.isPortInUse(host: "127.0.0.1", port: port) { usleep(100_000) }

        let second = try launchWithoutArguments(binary, port: port)
        defer { stop(second) }
        XCTAssertEqual(waitForStatus(of: url, bearer: nil), 401, "the second no-flag launch starts too")
        XCTAssertEqual(try String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), token, "a later launch reuses the stored token")
        XCTAssertEqual(try mode(of: tokenPath), 0o600)
        assertTokenAuthentication(url: url, token: token, "the reused token")

        // A Finder launch has no LaunchAgent, so its first-run lines reach agent.log only through the stderr redirect.
        // Both launches must log what they did, and neither may log the token.
        let log = try String(contentsOfFile: FirstRunSetup.logPath(home: home), encoding: .utf8)
        XCTAssertFalse(log.contains(token), "the token never reaches the log")
        XCTAssertTrue(log.contains("no-flag launch: token file \(tokenPath) created"),
                      "the first launch logs that it created the token file")
        XCTAssertTrue(log.contains("no-flag launch: token file \(tokenPath) reused"),
                      "the second launch logs that it reused the token file")
        XCTAssertTrue(log.contains(FirstRunSetup.tokenOnlyNotice) || log.contains("no-flag launch: Tailscale login detected"),
                      "the Tailscale result (token-only notice or detected login) reaches the log")
    }

    /// The default-port check. It runs only where 127.0.0.1:8795 is free (a clean CI runner). Where the installed
    /// agent holds the port it is skipped, and the skip names the holder. The test never stops that process.
    func testNoArgumentLaunchUsesDefaultPortWhenItIsFree() throws {
        let binary = try builtBinary()
        if FirstRunSetup.isPortInUse(host: "127.0.0.1", port: 8795) {
            throw XCTSkip("127.0.0.1:8795 is held by \(holderOfDefaultPort()); the default-port check runs only on a clean runner")
        }
        let child = try launchWithoutArguments(binary)
        defer { stop(child) }
        let url = URL(string: "http://127.0.0.1:8795/mcp")!
        XCTAssertEqual(waitForStatus(of: url, bearer: nil), 401,
                       "a launch with no arguments serves /mcp on the default port 8795")
    }
}
