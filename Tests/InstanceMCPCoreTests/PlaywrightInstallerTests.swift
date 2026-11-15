import Foundation
import XCTest
@testable import InstanceMCPCore

/// Downloader double: can fail the first call, hang until cancelled, or pass through.
final class ScriptedDownloader: ArtifactDownloader, @unchecked Sendable {
    let inner: any ArtifactDownloader
    let failFirst = MutableBox<PlaywrightInstallFailure?>(nil)
    let hang: Bool
    let calls = MutableBox(0)
    init(inner: any ArtifactDownloader, hang: Bool = false) { self.inner = inner; self.hang = hang }
    func download(from url: URL, to path: String, expectedSize: Int64, expectedSHA256: String,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        calls.value += 1
        if let f = failFirst.value { failFirst.value = nil; throw f }
        if hang {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 30_000_000) }
            throw PlaywrightInstallFailure.cancelled
        }
        try await inner.download(from: url, to: path, expectedSize: expectedSize, expectedSHA256: expectedSHA256, progress: progress)
    }
}

func describe(_ r: Result<Void, PlaywrightInstallFailure>) -> String {
    switch r { case .success: return "ok"; case .failure(let f): return f.errorClass }
}

class InstallerTestCase: XCTestCase {
    var work: TempDir!
    var root: URL!
    override func setUp() {
        work = TempDir()
        root = work.url.appendingPathComponent("playwright", isDirectory: true)
    }
    override func tearDown() {
        // Nothing the test started may outlive it.
        ManagedChildRegistry.shared.terminateAllSync()
        work.remove()
    }

    func installOK(_ i: PlaywrightInstaller, file: StaticString = #filePath, line: UInt = #line) async -> PlaywrightInstallState? {
        let r = await i.install { _ in }
        if case .success(let s) = r { return s }
        XCTFail("install failed: \(r)", file: file, line: line)
        return nil
    }

    func installFailure(_ i: PlaywrightInstaller) async -> PlaywrightInstallFailure? {
        let r = await i.install { _ in }
        if case .failure(let f) = r { return f }
        XCTFail("install unexpectedly succeeded")
        return nil
    }

    func children() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] }
    func assertNothingInstalled(file: StaticString = #filePath, line: UInt = #line) {
        let c = children()
        XCTAssertFalse(c.contains("install.json"), "\(c)", file: file, line: line)
        XCTAssertFalse(c.contains { $0.hasPrefix(".staging-") || $0 == ".install.lock" || $0.hasPrefix("mcp") }, "\(c)", file: file, line: line)
    }
    func perms(_ u: URL) -> Int { (try! FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
    func waitFor(_ cond: @escaping () -> Bool, seconds: Double = 15) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return cond()
    }
    func pid(_ f: URL) -> pid_t? { (try? String(contentsOf: f)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
}

final class PlaywrightInstallerTests: InstallerTestCase {
    private let logPattern = try! NSRegularExpression(pattern: "^browser: [a-z_]+( [a-z]+=[A-Za-z0-9_.-]+)*$")
    private func assertLogsClean(_ logs: [String], file: StaticString = #filePath, line: UInt = #line) {
        for l in logs {
            XCTAssertNotNil(logPattern.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), l, file: file, line: line)
            for canary in ["CANARY", "token", work.url.path, "http", "sha256"] {
                XCTAssertFalse(l.contains(canary), "\(canary) in \(l)", file: file, line: line)
            }
        }
    }

    func testFullInstall() async throws {
        let fx = try FakeInstallFixture()
        let logs = MutableBox<[String]>([])
        let steps = MutableBox<[PlaywrightInstallStep]>([])
        let i = fx.installer(root: root, logs: logs)
        let r = await i.install { p in if steps.value.last != p.step { steps.value += [p.step] } }
        guard case .success(.installed(let id, let update, let stale)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(id, fx.manifest.id)
        XCTAssertFalse(update); XCTAssertFalse(stale)
        XCTAssertEqual(steps.value, [.preflight, .downloadNode, .downloadChromium, .extract, .signature, .packages, .healthCheck, .commit, .switchOver])
        XCTAssertEqual(perms(root.appendingPathComponent("install.json")), 0o600)
        XCTAssertEqual(perms(root.appendingPathComponent("profile")), 0o700)
        XCTAssertEqual(perms(root.appendingPathComponent("output")), 0o700)
        let rec = try JSONDecoder().decode(PlaywrightInstaller.Record.self, from: Data(contentsOf: root.appendingPathComponent("install.json")))
        XCTAssertEqual(rec.version, fx.manifest.id)
        XCTAssertEqual(rec.chromiumExecutable, "chromium/" + fx.crExe)
        XCTAssertEqual(rec.digests?.node, fx.manifest.nodeArtifact(.arm64)?.sha256)
        let vd = root.appendingPathComponent(fx.manifest.id)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: vd.appendingPathComponent("node/bin/node").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vd.appendingPathComponent("pkg/node_modules/@playwright/mcp/cli.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vd.appendingPathComponent("pkg/package-lock.json").path))
        XCTAssertFalse(children().contains { $0.hasPrefix(".staging-") || $0 == ".install.lock" })
        // The locator accepts what the installer wrote, unchanged.
        if case .failure(let e) = ManagedPlaywrightLocator(root: root).locate() { XCTFail(e.errorClass) }
        assertLogsClean(logs.value)
        XCTAssertTrue(logs.value.contains("browser: playwright_install_ok id=\(fx.manifest.id)"))
        // A second install of the same version is a no-op: nothing is fetched again.
        let before = fx.requested.value.count
        _ = await installOK(i)
        XCTAssertEqual(fx.requested.value.count, before)
    }

    func testDigestMismatchOfEachArtifactInstallsNothing() async throws {
        for which in ["node", "chromium"] {
            let fx = try FakeInstallFixture()
            let logs = MutableBox<[String]>([])
            if which == "node" { fx.nodeData.value = fx.nodeData.value + Data([0]) } else { fx.chromiumData.value = Data(fx.chromiumData.value.reversed()) }
            let f = await installFailure(fx.installer(root: root, logs: logs))
            XCTAssertEqual(f, .digestMismatch, which)
            assertNothingInstalled()
            assertLogsClean(logs.value)
            XCTAssertTrue(logs.value.contains("browser: playwright_install_failed class=digest_mismatch"))
        }
    }

    func testLockfileThatDoesNotMatchTheManifestIsRefusedBeforeAnyDownload() async throws {
        let fx = try FakeInstallFixture()
        let f = await installFailure(fx.installer(root: root, lockfile: "{\"lockfileVersion\":3,\"tampered\":true}\n"))
        XCTAssertEqual(f, .other("manifest_invalid"))
        XCTAssertTrue(fx.requested.value.isEmpty)
    }

    func testHostileArchiveInPlaceOfNode() async throws {
        let hostile = ArchiveFixtures.tarGz([.file("../escape", "x")])
        let fx = try FakeInstallFixture(hostileNodeTar: hostile)
        let f = await installFailure(fx.installer(root: root))
        XCTAssertEqual(f, .archiveRejected)
        assertNothingInstalled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.url.appendingPathComponent("escape").path))
    }

    func testNodeSignatureFailureNeverStartsNpm() async throws {
        let fx = try FakeInstallFixture()
        let v = StubVerifier(false)
        let f = await installFailure(fx.installer(root: root, verifier: v))
        XCTAssertEqual(f, .nodeSignature)
        XCTAssertEqual(v.asked.value, ["ABCDE12345"])
        let started = (try? FileManager.default.contentsOfDirectory(atPath: fx.record.path))?.filter { $0.hasPrefix("npm-") } ?? []
        XCTAssertTrue(started.isEmpty, "npm must not run before the signature check passes")
        assertNothingInstalled()
    }

    func testNotEnoughDiskStopsBeforeAnyDownload() async throws {
        let fx = try FakeInstallFixture()
        let f = await installFailure(fx.installer(root: root, freeDisk: { _ in 10 }))
        guard case .notEnoughDisk(let needed, let available) = f else { return XCTFail("\(String(describing: f))") }
        XCTAssertEqual(available, 10)
        XCTAssertGreaterThanOrEqual(needed, Int64(fx.manifest.freeDiskFactor) * fx.manifest.downloadBytes(.arm64))
        XCTAssertTrue(fx.requested.value.isEmpty)
        assertNothingInstalled()
    }

    func testOfflineThenRetrySucceeds() async throws {
        let fx = try FakeInstallFixture()
        let d = ScriptedDownloader(inner: URLSessionArtifactDownloader(policy: DownloadPolicy(allowedHosts: ["127.0.0.1"], allowLoopbackHTTP: true)))
        d.failFirst.value = .offline
        let i = fx.installer(root: root, downloader: d)
        let f = await installFailure(i)
        XCTAssertEqual(f, .offline)
        assertNothingInstalled()
        let r1 = await installOK(i)
        XCTAssertNotNil(r1)
    }

    func testNpmCommandVector() async throws {
        let fx = try FakeInstallFixture()
        _ = await installOK(fx.installer(root: root))
        let files = try FileManager.default.contentsOfDirectory(atPath: fx.record.path).filter { $0.hasPrefix("npm-") }
        XCTAssertEqual(files.count, 1)
        let lines = try String(contentsOf: fx.record.appendingPathComponent(files[0])).split(separator: "\n").map(String.init)
        let args = lines.filter { $0.hasPrefix("arg=") }.map { String($0.dropFirst(4)) }
        let env = Dictionary(uniqueKeysWithValues: lines.filter { $0.hasPrefix("env=") }.compactMap { l -> (String, String)? in
            let kv = l.dropFirst(4).split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        })
        XCTAssertTrue(lines[0].hasPrefix("cwd=") && lines[0].hasSuffix("/pkg"), lines[0])
        XCTAssertTrue(args[0].hasSuffix("npm-cli.js"))
        XCTAssertEqual(Array(args[1...5]), ["ci", "--ignore-scripts", "--omit=dev", "--no-audit", "--no-fund"])
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        XCTAssertEqual(value(after: "--registry"), "https://registry.npmjs.org/")
        let u = try XCTUnwrap(value(after: "--userconfig")), g = try XCTUnwrap(value(after: "--globalconfig"))
        XCTAssertNotEqual(u, g, "npm refuses one file loaded as both configs")
        XCTAssertTrue(try XCTUnwrap(value(after: "--cache")).contains("/.staging-"))
        for k in env.keys {
            XCTAssertFalse(k.lowercased().hasPrefix("npm_config"), k)
            XCTAssertFalse(k.lowercased().contains("proxy"), k)
            XCTAssertNotEqual(k, "NODE_OPTIONS")
            XCTAssertFalse(k.lowercased().contains("token"), k)
        }
        XCTAssertNotEqual(env["HOME"], NSHomeDirectory(), "~/.npmrc must never be read")
        XCTAssertTrue(env["HOME"]?.contains("/.staging-") == true)
        XCTAssertTrue(env["PATH"]?.hasSuffix(":/usr/bin:/bin") == true)
    }

    func testHealthCheckFailureLeavesAnInstalledVersionUntouched() async throws {
        let ok = try FakeInstallFixture(id: "mcpfixture-1")
        _ = await installOK(ok.installer(root: root))
        let before = try Data(contentsOf: root.appendingPathComponent("install.json"))
        let bad = try FakeInstallFixture(id: "mcpfixture-2", node: .missingTool)
        let stops = MutableBox(0)
        let f = await installFailure(bad.installer(root: root, stop: { stops.value += 1 }))
        XCTAssertEqual(f, .healthCheckFailed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("install.json")), before)
        XCTAssertEqual(stops.value, 0, "the running version is not stopped by a failed update")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mcpfixture-1").path))
        XCTAssertFalse(children().contains { $0.hasPrefix(".staging-") || $0 == "mcpfixture-2" })
    }

    func testRefusedLaunchIsClassifiedAndLeaksNoStderr() async throws {
        let fx = try FakeInstallFixture(node: .refused)
        let logs = MutableBox<[String]>([])
        let f = await installFailure(fx.installer(root: root, logs: logs))
        XCTAssertEqual(f, .launchRefused)
        XCTAssertFalse("\(String(describing: f))".contains("CANARY"))
        assertLogsClean(logs.value)
        assertNothingInstalled()
    }

    func testNpmFailureClasses() async throws {
        for (mode, want) in [(FakeInstallFixture.NpmMode.fail, PlaywrightInstallFailure.other("packages_failed")),
                             (.offline, .offline), (.integrity, .digestMismatch)] {
            let fx = try FakeInstallFixture(npm: mode)
            let logs = MutableBox<[String]>([])
            let f = await installFailure(fx.installer(root: root, logs: logs))
            XCTAssertEqual(f, want, "\(mode)")
            assertLogsClean(logs.value)
            assertNothingInstalled()
        }
    }

    func testNpmTimeoutKillsTheTree() async throws {
        let fx = try FakeInstallFixture(npm: .hang)
        let f = await installFailure(fx.installer(root: root, npmTimeout: 1))
        XCTAssertEqual(f, .interrupted)
        let p = try XCTUnwrap(pid(fx.record.appendingPathComponent("npm.pid")))
        let c = try XCTUnwrap(pid(fx.record.appendingPathComponent("npm-child.pid")))
        let dead = await waitFor { !pidIsAlive(p) && !pidIsAlive(c) }
        XCTAssertTrue(dead)
        assertNothingInstalled()
    }

    // MARK: lock

    func testSecondInstallGetsLockHeldAndTheLockIsReleased() async throws {
        let fx = try FakeInstallFixture(npm: .hang)
        let first = fx.installer(root: root)
        let t = Task { await first.install { _ in } }
        let started = await waitFor { FileManager.default.fileExists(atPath: fx.record.appendingPathComponent("npm.pid").path) }
        XCTAssertTrue(started)
        let second = fx.installer(root: root, lockTries: 3)
        let f = await installFailure(second)
        XCTAssertEqual(f, .lockHeld)
        let removal = await second.remove()
        XCTAssertEqual(describe(removal), "lock_held", "no removal while an install runs")
        await first.cancel()
        _ = await t.value
        XCTAssertFalse(children().contains(".install.lock"))
    }

    /// Holds the installer's lock the way another process would: an open descriptor with flock(2).
    func holdLock() throws -> Int32 {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".install.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        return fd
    }

    func testALeftoverLockFileWithNoHolderIsJustTaken() async throws {
        let fx = try FakeInstallFixture()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "999999 1\n".write(to: root.appendingPathComponent(".install.lock"), atomically: true, encoding: .utf8)
        let r2 = await installOK(fx.installer(root: root, lockTries: 3))
        XCTAssertNotNil(r2)
    }

    func testAnOwnerThatExitedReleasesTheLockWithoutAnyReclaim() async throws {
        let fx = try FakeInstallFixture()
        let fd = try holdLock()
        let f = await installFailure(fx.installer(root: root, lockTries: 2))
        XCTAssertEqual(f, .lockHeld)
        close(fd)   // what the kernel does when the owner exits
        let r = await installOK(fx.installer(root: root, lockTries: 2))
        XCTAssertNotNil(r)
    }

    func testSweepDoesNotRunWhileAnotherHoldsTheLock() throws {
        let fx = try FakeInstallFixture()
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let fd = try holdLock()
        fx.installer(root: root).sweepStaging()
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path), "a live holder keeps its staging")
        close(fd)
        fx.installer(root: root).sweepStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(children().contains(".install.lock"))
    }

    func testLockIsReleasedOnEveryFailurePath() async throws {
        for mode in [FakeInstallFixture.NpmMode.fail, .offline] {
            let fx = try FakeInstallFixture(npm: mode)
            _ = await installFailure(fx.installer(root: root))
            XCTAssertFalse(children().contains(".install.lock"))
        }
    }

    // MARK: cancel

    func testCancelDuringDownloadRemovesStaging() async throws {
        let fx = try FakeInstallFixture()
        let d = ScriptedDownloader(inner: URLSessionArtifactDownloader(policy: DownloadPolicy(allowedHosts: ["127.0.0.1"], allowLoopbackHTTP: true)), hang: true)
        let i = fx.installer(root: root, downloader: d)
        let t = Task { await i.install { _ in } }
        _ = await waitFor { d.calls.value > 0 }
        await i.cancel()
        let r = await t.value
        XCTAssertEqual(r, .failure(.cancelled))
        assertNothingInstalled()
    }

    func testCancelDuringNpmKillsTheWholeTree() async throws {
        let fx = try FakeInstallFixture(npm: .detached)
        let i = fx.installer(root: root)
        let t = Task { await i.install { _ in } }
        let up = await waitFor { (try? String(contentsOf: fx.record.appendingPathComponent("gc.out")))?.contains("grandchild") == true }
        XCTAssertTrue(up)
        let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["60"]; try sleeper.run()
        defer { sleeper.terminate() }
        let npm = try XCTUnwrap(pid(fx.record.appendingPathComponent("npm.pid")))
        let gc = try XCTUnwrap((try String(contentsOf: fx.record.appendingPathComponent("gc.out"))).split(separator: " ").last.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        XCTAssertTrue(pidIsAlive(gc))
        await i.cancel()
        let r = await t.value
        XCTAssertEqual(r, .failure(.cancelled))
        let gone = await waitFor { !pidIsAlive(npm) && !pidIsAlive(gc) }
        XCTAssertTrue(gone, "no orphan: the detached grandchild must be gone")
        XCTAssertTrue(pidIsAlive(sleeper.processIdentifier), "an unrelated process is never touched")
        assertNothingInstalled()
    }

    func testAppExitPathKillsARunningNpm() async throws {
        let fx = try FakeInstallFixture(npm: .detached)
        let i = fx.installer(root: root)
        let t = Task { await i.install { _ in } }
        let up = await waitFor { (try? String(contentsOf: fx.record.appendingPathComponent("gc.out")))?.contains("grandchild") == true }
        XCTAssertTrue(up)
        let npm = try XCTUnwrap(pid(fx.record.appendingPathComponent("npm.pid")))
        ManagedChildRegistry.shared.terminateAllSync()
        let gone = await waitFor { !pidIsAlive(npm) }
        XCTAssertTrue(gone)
        await i.cancel()
        _ = await t.value
    }

    // MARK: update

    func testUpdateInstallsBesideStopsTheOldChildAndPrunes() async throws {
        let v1 = try FakeInstallFixture(id: "mcpfixture-1")
        _ = await installOK(v1.installer(root: root))
        let events = MutableBox<[String]>([])
        let v2 = try FakeInstallFixture(id: "mcpfixture-2")
        let i2 = v2.installer(root: root, stop: { events.value += ["stop"] }, serving: { events.value += ["serving"]; return true })
        // Before the user chooses to update, the state only says an update exists.
        guard case .installed(let id, let update, _) = i2.state() else { return XCTFail("\(i2.state())") }
        XCTAssertEqual(id, "mcpfixture-1"); XCTAssertTrue(update)
        XCTAssertEqual(events.value, [])
        let r3 = await installOK(i2)
        XCTAssertNotNil(r3)
        XCTAssertEqual(events.value, ["stop", "serving"])
        XCTAssertEqual(i2.state(), .installed(id: "mcpfixture-2", updateAvailable: false, stale: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mcpfixture-1").path), "pruned after the new one served")
        let rec = try JSONDecoder().decode(PlaywrightInstaller.Record.self, from: Data(contentsOf: root.appendingPathComponent("install.json")))
        XCTAssertEqual(rec.previous, "mcpfixture-1")
        XCTAssertEqual(perms(root.appendingPathComponent("profile")), 0o700, "the profile is shared across versions")
    }

    func testUpdateThatDoesNotServeRollsBack() async throws {
        let v1 = try FakeInstallFixture(id: "mcpfixture-1")
        _ = await installOK(v1.installer(root: root))
        let before = try Data(contentsOf: root.appendingPathComponent("install.json"))
        let marker = root.appendingPathComponent("profile/cookie")
        try Data("session".utf8).write(to: marker)
        let events = MutableBox<[String]>([])
        let logs = MutableBox<[String]>([])
        let v2 = try FakeInstallFixture(id: "mcpfixture-2")
        let f = await installFailure(v2.installer(root: root, stop: { events.value += ["stop"] },
                                                  serving: { events.value += ["serving"]; return false }, logs: logs))
        XCTAssertEqual(f, .healthCheckFailed)
        XCTAssertEqual(events.value, ["stop", "serving", "stop", "serving"], "the old version is served again")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("install.json")), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mcpfixture-1/node/bin/node").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mcpfixture-2").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the profile survives a failed update")
        XCTAssertTrue(logs.value.contains("browser: playwright_update_rolled_back"))
    }

    func testAHandWrittenRecordWithAForgedManifestIdIsNeverOverwrittenOrRemoved() async throws {
        let hand = root.appendingPathComponent("handmade")
        try FileManager.default.createDirectory(at: hand.appendingPathComponent("node/bin"), withIntermediateDirectories: true)
        for d in ["profile", "output"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            try Data("mine".utf8).write(to: root.appendingPathComponent(d).appendingPathComponent("keep"))
        }
        let rec = Data("{\"version\":\"handmade\",\"chromiumExecutable\":\"x\",\"manifestId\":\"handmade\"}".utf8)
        try rec.write(to: root.appendingPathComponent("install.json"))
        let fx = try FakeInstallFixture()
        let f = await installFailure(fx.installer(root: root))
        XCTAssertEqual(f, .other("foreign_data"))   // the user's profile stops the install before anything else
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("install.json")), rec)
        let rr = await fx.installer(root: root).remove()
        XCTAssertEqual(describe(rr), "ok")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("install.json")), rec)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("profile/keep")), "mine")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("output/keep")), "mine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hand.path))
    }

    func testAHandMadeInstallJsonWithNoProfileIsRefusedAsForeignInstall() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rec = Data("{\"version\":\"handmade\",\"chromiumExecutable\":\"x\"}".utf8)
        try rec.write(to: root.appendingPathComponent("install.json"))
        let fx = try FakeInstallFixture()
        let f = await installFailure(fx.installer(root: root))
        XCTAssertEqual(f, .other("foreign_install"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("install.json")), rec)
    }

    func testAHandMadeInstallIsNeverOverwritten() async throws {
        let hand = root.appendingPathComponent("handmade")
        try FileManager.default.createDirectory(at: hand.appendingPathComponent("node/bin"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: hand.appendingPathComponent("my-notes.txt"))
        for d in ["profile", "output"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            try Data("mine".utf8).write(to: root.appendingPathComponent(d).appendingPathComponent("keep"))
        }
        let rec = Data("{\"version\":\"handmade\",\"chromiumExecutable\":\"x\"}".utf8)
        try rec.write(to: root.appendingPathComponent("install.json"))
        let fx = try FakeInstallFixture()
        let f = await installFailure(fx.installer(root: root))
        XCTAssertEqual(f, .other("foreign_data"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("install.json")), rec)
        XCTAssertEqual(try String(contentsOf: hand.appendingPathComponent("my-notes.txt")), "mine")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("profile/keep")), "mine")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("output/keep")), "mine")
        XCTAssertEqual(Set(children()), ["handmade", "install.json", "profile", "output"])
        // And remove() leaves a record it did not write, and what it points at, alone.
        let rr = await fx.installer(root: root).remove()
        XCTAssertEqual(describe(rr), "ok")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("install.json")), rec)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("profile/keep")), "mine")
    }

    func testPreExistingUnmarkedProfileOrOutputStopsTheInstallAndStaysUntouched() async throws {
        for d in ["profile", "output"] {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            try Data("mine".utf8).write(to: root.appendingPathComponent(d).appendingPathComponent("keep"))
            let fx = try FakeInstallFixture()
            let f = await installFailure(fx.installer(root: root))
            XCTAssertEqual(f, .other("foreign_data"))
            XCTAssertEqual(Set(children()), [d], "nothing downloaded, nothing added")
            XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(d).path)) ?? []), ["keep"])
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(d + "/keep")), "mine")
        }
    }

    func testAProfileThisInstallerMarkedIsReusedAndRemoved() async throws {
        let fx = try FakeInstallFixture()
        let i = fx.installer(root: root)
        _ = await installOK(i)
        let again = await installOK(fx.installer(root: root))
        XCTAssertNotNil(again)
        let rr = await i.remove()
        XCTAssertEqual(describe(rr), "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testASymlinkedProfileIsRefusedAndNothingBehindItIsTouched() async throws {
        let elsewhere = work.url.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: elsewhere.appendingPathComponent("keep"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("profile"), withDestinationURL: elsewhere)
        let fx = try FakeInstallFixture()
        let f = await installFailure(fx.installer(root: root))
        XCTAssertEqual(f, .other("commit_collision"))
        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent("keep")), "mine")
        XCTAssertFalse(children().contains(fx.manifest.id))
    }

    func testAServerThatIsNotPlaywrightFailsTheHealthCheck() async throws {
        let fx = try FakeInstallFixture(node: .otherServer)
        let f = await installFailure(fx.installer(root: root))
        XCTAssertEqual(f, .healthCheckFailed)
        assertNothingInstalled()
    }

    func testALiveLockIsNotTaken() async throws {
        let fx = try FakeInstallFixture()
        let fd = try holdLock()
        defer { close(fd) }
        let f = await installFailure(fx.installer(root: root, lockTries: 2))
        XCTAssertEqual(f, .lockHeld)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".install.lock").path))
    }

    func testFirstInstallThatDoesNotServeLeavesNothing() async throws {
        let fx = try FakeInstallFixture()
        let f = await installFailure(fx.installer(root: root, serving: { false }))
        XCTAssertEqual(f, .healthCheckFailed)
        assertNothingInstalled()
        XCTAssertFalse(children().contains("profile") || children().contains("output"), "\(children())")
    }

    func testACollidingDirectoryWithoutOurMarkerIsNeverDeleted() async throws {
        let fx = try FakeInstallFixture()
        let theirs = root.appendingPathComponent(fx.manifest.id)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: theirs.appendingPathComponent("notes.txt"))
        let f = await installFailure(fx.installer(root: root))
        XCTAssertEqual(f, .other("commit_collision"))
        XCTAssertEqual(try String(contentsOf: theirs.appendingPathComponent("notes.txt")), "mine")
    }

    func testRemoveWithoutAReadableRecordKeepsProfileAndOutputButDeletesTheVersionDirectory() async throws {
        let fx = try FakeInstallFixture()
        let i = fx.installer(root: root)
        _ = await installOK(i)
        try Data("cookie".utf8).write(to: root.appendingPathComponent("profile/Cookies"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("install.json"))
        let rr = await i.remove()
        XCTAssertEqual(describe(rr), "ok")
        XCTAssertEqual(children(), ["output", "profile"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("profile/Cookies")), "cookie")
    }

    func testCrashBetweenRenameAndInstallJsonLeavesTheOldSelectedAndSweepCleans() async throws {
        let v1 = try FakeInstallFixture(id: "mcpfixture-1")
        _ = await installOK(v1.installer(root: root))
        // What a crash after the rename leaves: a new version directory no install.json points at,
        // a staging directory, and a lock whose owner is gone.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mcpfixture-2/node"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("mcpfixture-2/.oab-owned"))
        // A hand-made directory with a matching name but no marker must survive.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mcp-handmade/node"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".staging-\(UUID().uuidString)/pkg"), withIntermediateDirectories: true)
        try "999999 1\n".write(to: root.appendingPathComponent(".install.lock"), atomically: true, encoding: .utf8)
        try Data("keep".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let logs = MutableBox<[String]>([])
        let i = v1.installer(root: root, logs: logs)
        XCTAssertEqual(i.state(), .installed(id: "mcpfixture-1", updateAvailable: false, stale: false))
        i.sweepStaging()
        let c = Set(children())
        XCTAssertEqual(c, ["install.json", "mcpfixture-1", "profile", "output", "notes.txt", "mcp-handmade"])
        XCTAssertTrue(logs.value.contains("browser: playwright_swept count=2"))
    }

    // MARK: state

    func testStateReadsOnlyInstallJson() throws {
        let fx = try FakeInstallFixture()
        let i = fx.installer(root: root)
        XCTAssertEqual(i.state(), .notInstalled)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("install.json"))
        XCTAssertEqual(i.state(), .invalid)
        try Data("{\"version\":\"mcpfixture-1\",\"chromiumExecutable\":\"x\"}".utf8).write(to: root.appendingPathComponent("install.json"))
        XCTAssertEqual(i.state(), .invalid, "the version directory is missing")
        try Data("{\"version\":\"../etc\",\"chromiumExecutable\":\"x\"}".utf8).write(to: root.appendingPathComponent("install.json"))
        XCTAssertEqual(i.state(), .invalid)
    }

    func testStaleWarningUsesTheManifestWindow() async throws {
        let fx = try FakeInstallFixture()
        let i = fx.installer(root: root)
        _ = await installOK(i)
        let url = root.appendingPathComponent("install.json")
        var rec = try JSONDecoder().decode(PlaywrightInstaller.Record.self, from: Data(contentsOf: url))
        rec.chromiumReleasedAt = "2026-06-01"   // 92 days before the manifest's 2026-09-01: inside 180
        try JSONEncoder().encode(rec).write(to: url)
        XCTAssertEqual(i.state(), .installed(id: fx.manifest.id, updateAvailable: false, stale: false))
        rec.chromiumReleasedAt = "2026-01-01"   // 243 days: outside
        try JSONEncoder().encode(rec).write(to: url)
        XCTAssertEqual(i.state(), .installed(id: fx.manifest.id, updateAvailable: false, stale: true))
    }

    // MARK: removal

    func testRemoveDeletesOnlyWhatTheInstallerCreated() async throws {
        let fx = try FakeInstallFixture()
        let events = MutableBox<[String]>([])
        let i = fx.installer(root: root, stop: { events.value += ["stop"] }, removed: { events.value += ["removed"] })
        _ = await installOK(i)
        events.value = []
        try Data("cookie".utf8).write(to: root.appendingPathComponent("profile/Cookies"))
        let sibling = work.url.appendingPathComponent("sibling-sentinel")
        try Data("keep".utf8).write(to: sibling)
        try Data("mine".utf8).write(to: root.appendingPathComponent("not-ours.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mcp-handmade"), withIntermediateDirectories: true)
        let r = await i.remove()
        XCTAssertEqual(describe(r), "ok")
        XCTAssertEqual(events.value, ["stop", "removed"])
        XCTAssertEqual(Set(children()), ["not-ours.txt", "mcp-handmade"])
        XCTAssertEqual(try String(contentsOf: sibling), "keep")
        XCTAssertEqual(i.state(), .notInstalled)
    }

    func testRemoveIsIdempotentAndRemovesAnEmptyRoot() async throws {
        let fx = try FakeInstallFixture()
        let i = fx.installer(root: root)
        _ = await installOK(i)
        let r6 = await i.remove()
        XCTAssertEqual(describe(r6), "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let r7 = await i.remove()
        XCTAssertEqual(describe(r7), "ok")
    }

    func testRemoveRefusesWhileAnInstallLockIsLive() async throws {
        let fx = try FakeInstallFixture()
        let fd = try holdLock()
        defer { close(fd) }
        let r8 = await fx.installer(root: root).remove()
        XCTAssertEqual(describe(r8), "lock_held")
    }

    func testASymlinkedRootIsRefusedByInstallRemoveAndSweep() async throws {
        let elsewhere = work.url.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: elsewhere.appendingPathComponent("keep"))
        let stale = elsewhere.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: elsewhere)
        let fx = try FakeInstallFixture()
        let f = await installFailure(fx.installer(root: root))
        XCTAssertEqual(f, .other("root_not_directory"))
        let r = await fx.installer(root: root).remove()
        XCTAssertEqual(describe(r), "root_not_directory")
        fx.installer(root: root).sweepStaging()
        XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: elsewhere.path)) ?? []), ["keep", stale.lastPathComponent])
    }

    func testCompareAndSwapKeepsAFileThatIsNotWhatWasExpected() throws {
        let fx = try FakeInstallFixture()
        let i = fx.installer(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("install.json")
        try Data("theirs".utf8).write(to: url)
        // Expected bytes differ: the file is put back untouched and the write refused.
        XCTAssertThrowsError(try i.writeAtomically(Data("ours".utf8), to: url, replacing: Data("other".utf8))) {
            XCTAssertEqual($0 as? PlaywrightInstallFailure, .other("foreign_install"))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("theirs".utf8))
        // Nothing to replace but a file is there: refused, untouched.
        XCTAssertThrowsError(try i.writeAtomically(Data("ours".utf8), to: url, replacing: nil))
        XCTAssertEqual(try Data(contentsOf: url), Data("theirs".utf8))
        // The file vanished while a replacement was expected: refused, nothing created.
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try i.writeAtomically(Data("ours".utf8), to: url, replacing: Data("theirs".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Matching bytes: replaced, and no temp or grab files remain.
        try Data("theirs".utf8).write(to: url)
        try i.writeAtomically(Data("ours".utf8), to: url, replacing: Data("theirs".utf8))
        XCTAssertEqual(try Data(contentsOf: url), Data("ours".utf8))
        XCTAssertEqual(children(), ["install.json"])
    }

    // MARK: quarantine and logs

    func testQuarantineAttributesAreNeitherAddedNorStripped() async throws {
        let fx = try FakeInstallFixture()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let value = Array("0081;00000000;Test;".utf8)
        XCTAssertEqual(setxattr(root.path, "com.apple.quarantine", value, value.count, 0, 0), 0)
        _ = await installOK(fx.installer(root: root))
        func names(_ p: String) -> [String] {
            let n = listxattr(p, nil, 0, XATTR_NOFOLLOW)
            guard n > 0 else { return [] }
            var buf = [CChar](repeating: 0, count: n)
            _ = listxattr(p, &buf, n, XATTR_NOFOLLOW)
            return buf.split(separator: 0).map { String(cString: Array($0) + [0]) }
        }
        XCTAssertEqual(names(root.path), ["com.apple.quarantine"], "left alone")
        for f in ["install.json", "\(fx.manifest.id)/node/bin/node", "\(fx.manifest.id)/chromium/\(fx.crExe)"] {
            XCTAssertFalse(names(root.appendingPathComponent(f).path).contains("com.apple.quarantine"), f)
        }
    }

    func testLogHygieneAcrossFailures() async throws {
        let logs = MutableBox<[String]>([])
        for npm in [FakeInstallFixture.NpmMode.fail, .offline, .integrity] {
            let fx = try FakeInstallFixture(npm: npm)
            _ = await installFailure(fx.installer(root: root, logs: logs))
        }
        let fx = try FakeInstallFixture(node: .refused)
        _ = await installFailure(fx.installer(root: root, logs: logs))
        let ok = try FakeInstallFixture()
        _ = await installOK(ok.installer(root: root, logs: logs))
        XCTAssertGreaterThan(logs.value.count, 10)
        assertLogsClean(logs.value)
        // Nothing the fake child wrote to stderr reached a file the installer left behind.
        let e = FileManager.default.enumerator(atPath: root.path)
        while let rel = e?.nextObject() as? String {
            let p = root.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir), !isDir.boolValue,
                  let d = try? Data(contentsOf: p), d.count < 100_000 else { continue }
            XCTAssertNil(d.range(of: Data("CANARY".utf8)), rel)
        }
    }

    // MARK: connection to the managed tier

    func testInstallThenBackendServesWithoutRestart() async throws {
        let locator = ManagedPlaywrightLocator(root: root)
        let backend = PlaywrightBackend(managed: locator)
        let s0 = await backend.status()
        XCTAssertEqual(s0, .needsSetup("playwright_not_installed"))

        let v1 = try FakeInstallFixture(id: "mcpfixture-1")
        let i1 = v1.installer(root: root, stop: { await backend.shutdown() }, serving: { await backend.status().isReady })
        let r4 = await installOK(i1)
        XCTAssertNotNil(r4)

        // The same backend object, no restart: it now serves.
        let s1 = await backend.status()
        XCTAssertEqual(s1, .ready)
        let names = await backend.tools().compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names), Set(BrowserToolCatalog.allNames))
        let r = try await backend.call("browser_navigate", arguments: ["url": "about:blank"])
        XCTAssertNotNil(r["content"])
        let oldPid = try XCTUnwrap(pid(v1.record.appendingPathComponent("serving.pid")))
        XCTAssertTrue(pidIsAlive(oldPid))

        // Update: the next call runs the new version and the old child is gone.
        let v2 = try FakeInstallFixture(id: "mcpfixture-2")
        let i2 = v2.installer(root: root, stop: { await backend.shutdown() }, serving: { await backend.status().isReady })
        let r5 = await installOK(i2)
        XCTAssertNotNil(r5)
        _ = try await backend.call("browser_navigate", arguments: ["url": "about:blank"])
        let newPid = try XCTUnwrap(pid(v2.record.appendingPathComponent("serving.pid")))
        XCTAssertNotEqual(newPid, oldPid)
        let oldGone = await waitFor { !pidIsAlive(oldPid) }
        XCTAssertTrue(oldGone, "no two children for one profile")
        XCTAssertTrue(pidIsAlive(newPid))

        // Removal: the backend goes back to needing setup and no child remains.
        let r9 = await i2.remove()
        XCTAssertEqual(describe(r9), "ok")
        let s3 = await backend.status()
        XCTAssertEqual(s3, .needsSetup("playwright_not_installed"))
        let newGone = await waitFor { !pidIsAlive(newPid) }
        XCTAssertTrue(newGone)
    }
}
