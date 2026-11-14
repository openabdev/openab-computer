import Foundation
import XCTest
@testable import InstanceMCPCore

final class StderrRingTests: XCTestCase {
    func testRingKeepsNewestAndClassifiesOnlyWhatIsKept() {
        let r = StderrRing()
        r.append(Data("ProcessSingleton: old\n".utf8))
        r.append(Data(String(repeating: "x", count: 70_000).utf8))
        XCTAssertLessThanOrEqual(r.byteCount, StderrRing.capacity)
        XCTAssertNil(r.classify(), "the evicted signature must not be classified")
        r.append(Data("\nError: Cannot find module 'x'\n".utf8))
        XCTAssertEqual(r.classify(), .moduleNotFound)
        r.append(Data("\nSingleton lock held\n".utf8))
        XCTAssertEqual(r.classify(), .profileLocked, "the newest signature wins")
    }
}

final class ManagedProcessTests: XCTestCase {
    private func spawn(_ mode: String, _ extra: [String] = [], env: [String: String] = [:]) throws -> ManagedProcess {
        try ManagedProcess.spawn(executable: fakeServerPath(), arguments: [mode] + extra, environment: env,
                                 workingDirectory: NSTemporaryDirectory())
    }
    private func read(_ p: ManagedProcess) async -> String {
        var out = Data()
        for await c in p.incoming { out.append(c) }
        return String(decoding: out, as: UTF8.self)
    }

    func testSpawnRoundTripThroughTheClient() async throws {
        let p = try spawn("normal")
        let c = StdioMCPClient(channel: p)
        try await c.initialize(timeout: 5)
        let tools = try await c.listTools(timeout: 5)
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, ["browser_navigate", "browser_snapshot"])
        let r = try await c.callTool("browser_navigate", arguments: [:], timeout: 5)
        XCTAssertEqual(r["content"]?.arrayValue?.first?["text"]?.stringValue, "fake did browser_navigate")
        XCTAssertEqual(getpgid(p.pid), p.pid, "the child leads its own group")
        await p.terminate()
        XCTAssertTrue(p.hasExited)
    }

    func testChunkyAndNoisyOutputStillWorks() async throws {
        for mode in ["chunky", "noise"] {
            let p = try spawn(mode)
            let c = StdioMCPClient(channel: p)
            try await c.initialize(timeout: 5)
            _ = try await c.listTools(timeout: 5)
            await p.terminate()
        }
    }

    func testEnvironmentIsExactlyTheAllowList() async throws {
        let p = try spawn("env", env: ["HOME": "/tmp", "LANG": "C", "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp/"])
        let out = await read(p)
        // Foundation in the child adds __CF_USER_TEXT_ENCODING itself; everything else is ours.
        let keys = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
            .filter { $0 != "__CF_USER_TEXT_ENCODING" }
        XCTAssertEqual(keys, ["HOME", "LANG", "PATH", "TMPDIR"])
    }

    func testStdinEOFEndsTheChildGracefully() async throws {
        let p = try spawn("normal")
        let c = StdioMCPClient(channel: p)
        try await c.initialize(timeout: 5)
        let t0 = Date()
        await p.terminate()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
        XCTAssertEqual(p.exitInfo, .exited(0))
    }

    func testChildThatIgnoresTermIsKilled() async throws {
        let p = try spawn("ignore-term")
        try await Task.sleep(nanoseconds: 200_000_000)
        let t0 = Date()
        await p.terminate()
        XCTAssertTrue(p.hasExited)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 7)
        XCTAssertEqual(p.exitInfo, .signaled(SIGKILL))
    }

    func testGrandchildInTheGroupIsKilled() async throws {
        let p = try spawn("grandchild")
        var line = ""
        for await c in p.incoming { line += String(decoding: c, as: UTF8.self); if line.contains("\n") { break } }
        let gc = try XCTUnwrap(Int32(line.split(separator: " ").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""))
        XCTAssertEqual(kill(gc, 0), 0)
        XCTAssertEqual(getpgid(gc), p.pid)
        await p.terminate()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(kill(gc, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func grandchildPid(_ p: ManagedProcess) async throws -> pid_t {
        var line = ""
        for await c in p.incoming { line += String(decoding: c, as: UTF8.self); if line.contains("\n") { break } }
        return try XCTUnwrap(Int32(line.split(separator: " ").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""))
    }
    private func waitGone(_ pid: pid_t, seconds: Double = 5) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if !ProcessTree.isAlive(pid) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Playwright starts Chromium detached: a new session and group, outside killpg and outside the
    /// child's exit. `terminate()` must still end it.
    func testDetachedGrandchildIsKilledByTerminate() async throws {
        let p = try spawn("detached-grandchild")
        let gc = try await grandchildPid(p)
        XCTAssertTrue(ProcessTree.isAlive(gc))
        XCTAssertNotEqual(getpgid(gc), p.pid, "the grandchild is outside the child's group")
        XCTAssertTrue(ProcessTree.descendants(of: [p.pid]).contains(gc))
        await p.terminate()
        let gone = await waitGone(gc)
        if !gone { kill(gc, SIGKILL) }
        XCTAssertTrue(gone, "the detached grandchild survived terminate()")
    }

    func testDetachedGrandchildIsKilledByTheQuitTimeSweep() async throws {
        let p = try spawn("detached-grandchild", ["hold"])
        let gc = try await grandchildPid(p)
        XCTAssertTrue(ProcessTree.isAlive(gc))
        ManagedChildRegistry.shared.terminateAllSync()
        XCTAssertTrue(p.hasExited)
        let gone = await waitGone(gc)
        if !gone { kill(gc, SIGKILL) }
        XCTAssertTrue(gone, "the detached grandchild survived terminateAllSync()")
    }

    func testRegistryTerminatesRegisteredChildren() async throws {
        let p = try spawn("ignore-term")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(ManagedChildRegistry.shared.count, 0)
        ManagedChildRegistry.shared.terminateAllSync()
        XCTAssertTrue(p.hasExited)
        XCTAssertEqual(ManagedChildRegistry.shared.count, 0)
    }

    func testStderrNeverLeavesTheRing() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oab-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let p = try ManagedProcess.spawn(executable: fakeServerPath(), arguments: ["stderr-signature"],
                                         environment: ["HOME": home.path], workingDirectory: home.path)
        _ = await read(p)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertLessThanOrEqual(p.stderrRing.byteCount, StderrRing.capacity)
        XCTAssertEqual(p.stderrRing.classify(), .profileLocked)
        XCTAssertFalse(p.stderrRing.snapshotForTests().contains("CANARY"), "the oldest text was evicted")
        XCTAssertEqual(p.exitInfo, .exited(3))
        let files = FileManager.default.enumerator(atPath: home.path)?.allObjects ?? []
        XCTAssertTrue(files.isEmpty, "nothing was written under HOME: \(files)")
    }
}

final class ShutdownSignalsTests: XCTestCase {
    func testDefaultsCoverTermIntHup() {
        XCTAssertEqual(Set(ShutdownSignals.defaults), [SIGTERM, SIGINT, SIGHUP])
    }

    /// SIGUSR1 and SIGUSR2 stand in for the real ones, which would end the test process on a
    /// failure. The handler must run on the given queue, not inside the signal handler.
    func testHandlerRunsOnTheQueueForEachInstalledSignal() {
        let q = DispatchQueue(label: "test.shutdown")
        final class Seen: @unchecked Sendable { let lock = NSLock(); var sigs: [Int32] = []; var onQueue = true }
        let box = Seen()
        let both = expectation(description: "both signals handled")
        both.expectedFulfillmentCount = 2
        let sources = ShutdownSignals.install([SIGUSR1, SIGUSR2], queue: q) { sig in
            box.lock.withLock { box.sigs.append(sig); box.onQueue = box.onQueue && !Thread.isMainThread }
            both.fulfill()
        }
        kill(getpid(), SIGUSR1)
        kill(getpid(), SIGUSR2)
        wait(for: [both], timeout: 5)
        XCTAssertEqual(Set(box.lock.withLock { box.sigs }), [SIGUSR1, SIGUSR2])
        XCTAssertTrue(box.lock.withLock { box.onQueue })
        sources.forEach { $0.cancel() }
        signal(SIGUSR1, SIG_DFL); signal(SIGUSR2, SIG_DFL)
    }
}
