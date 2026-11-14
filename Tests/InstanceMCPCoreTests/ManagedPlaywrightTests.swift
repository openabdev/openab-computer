import Foundation
import XCTest
@testable import InstanceMCPCore

/// A child driven by the test, so the supervisor can be exercised without processes.
final class FakeChild: ManagedChild, @unchecked Sendable {
    let script = ScriptedChannel()
    var channel: any StdioChannel { script }
    private let lock = NSLock()
    private var _exit: ExitInfo?
    var stderrClass: StderrClass?
    var hasExited: Bool { lock.withLock { _exit != nil } }
    var exitInfo: ExitInfo? { lock.withLock { _exit } }
    func die(_ code: Int32 = 1) { lock.withLock { _exit = .exited(code) }; script.finish() }
    func terminate() async { if !hasExited { lock.withLock { _exit = .exited(0) }; script.finish() } }
    func healthy() {
        script.onSend = { [script] v in
            guard let id = v["id"]?.intValue else { return }
            let result = v["method"]?.stringValue == "tools/call" ? "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}" : "{}"
            script.feed("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}\n")
        }
    }
}

final class FakeLauncher: ChildLauncher, @unchecked Sendable {
    enum Behavior { case healthy, dieAtStart }
    private let lock = NSLock()
    private var _launches = 0
    private var _behavior: Behavior
    private var _last: FakeChild?
    init(_ b: Behavior) { _behavior = b }
    var behavior: Behavior { get { lock.withLock { _behavior } } set { lock.withLock { _behavior = newValue } } }
    var launches: Int { lock.withLock { _launches } }
    var last: FakeChild? { lock.withLock { _last } }
    func launch(_ spec: ManagedLaunchSpec) throws -> any ManagedChild {
        let c = FakeChild()
        lock.withLock { _launches += 1; _last = c }
        switch behavior {
        case .healthy: c.healthy()
        case .dieAtStart: c.die(1)
        }
        return c
    }
}

private let dummySpec = ManagedLaunchSpec(executable: "/bin/false", arguments: [], environment: [:], workingDirectory: "/tmp")

final class ManagedPlaywrightSupervisionTests: XCTestCase {
    private func klass(_ t: ManagedPlaywrightTransport) async -> String {
        do { try await t.healthCheck(); return "ok" }
        catch let e as PlaywrightTransportError { return e.errorClass }
        catch { return "other" }
    }

    func testColdStartAndRoundTrip() async throws {
        let l = FakeLauncher(.healthy)
        let t = ManagedPlaywrightTransport(spec: dummySpec, launcher: l, initializeTimeout: 2)
        try await t.healthCheck()
        try await t.healthCheck()   // a ping, not a second launch
        XCTAssertEqual(l.launches, 1)
        let r = try await t.callTool("browser_navigate", arguments: [:])
        XCTAssertEqual(r["content"]?.arrayValue?.first?["text"]?.stringValue, "ok")
        await t.shutdown()
        XCTAssertTrue(l.last?.hasExited == true)
    }

    func testBackoffDoublesAndCaps() async throws {
        let clock = TestClock()
        let l = FakeLauncher(.dieAtStart)
        let t = ManagedPlaywrightTransport(spec: dummySpec, launcher: l, initializeTimeout: 2, clock: { clock.date() })
        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            delays.append(await t.nextBackoff)
            let k = await klass(t); XCTAssertEqual(k, "playwright_exited")
            let gated = await klass(t); XCTAssertEqual(gated, "playwright_restarting")
            clock.advance(delays.last! + 0.01)
        }
        XCTAssertEqual(delays, [1, 2, 4, 8])
        XCTAssertEqual(l.launches, 4, "calls inside the gate do not launch")
        XCTAssertEqual(ManagedPlaywrightTransport.backoff.last, 30)
    }

    func testLatchesAfterFiveFailuresInTwoMinutesAndRetryClears() async throws {
        let clock = TestClock()
        let l = FakeLauncher(.dieAtStart)
        let t = ManagedPlaywrightTransport(spec: dummySpec, launcher: l, initializeTimeout: 2, clock: { clock.date() })
        for d in [1.0, 2, 4, 8] { _ = await klass(t); clock.advance(d + 0.01) }
        _ = await klass(t)   // fifth failure
        let latched = await t.isLatched
        XCTAssertTrue(latched)
        let launches = l.launches
        let fast = await klass(t); XCTAssertEqual(fast, "playwright_unavailable")
        XCTAssertEqual(l.launches, launches, "no launch while latched")
        l.behavior = .healthy
        await t.retry()
        let ok = await klass(t); XCTAssertEqual(ok, "ok")
    }

    func testFailuresOutsideTheWindowDoNotLatch() async throws {
        let clock = TestClock()
        let l = FakeLauncher(.dieAtStart)
        let t = ManagedPlaywrightTransport(spec: dummySpec, launcher: l, initializeTimeout: 2, clock: { clock.date() })
        for _ in 0..<6 { _ = await klass(t); clock.advance(100) }
        let latched = await t.isLatched
        XCTAssertFalse(latched)
    }

    func testCrashMidCallThenRestartAfterBackoff() async throws {
        let clock = TestClock()
        let l = FakeLauncher(.healthy)
        let t = ManagedPlaywrightTransport(spec: dummySpec, launcher: l, initializeTimeout: 2, clock: { clock.date() })
        try await t.healthCheck()
        let child = try XCTUnwrap(l.last)
        child.script.onSend = { [child] v in if v["method"]?.stringValue == "tools/call" { child.die(9) } }
        do { _ = try await t.callTool("browser_navigate", arguments: [:]); XCTFail() }
        catch let e as PlaywrightTransportError { XCTAssertEqual(e.errorClass, "playwright_exited") }
        let gated = await klass(t); XCTAssertEqual(gated, "playwright_restarting")
        clock.advance(1.1)
        let back = await klass(t); XCTAssertEqual(back, "ok")
        XCTAssertEqual(l.launches, 2)
    }

    func testExitIsLoggedAsAClassOnly() async throws {
        let clock = TestClock()
        nonisolated(unsafe) var lines: [String] = []
        let lock = NSLock()
        let l = FakeLauncher(.healthy)
        let t = ManagedPlaywrightTransport(spec: dummySpec, launcher: l, initializeTimeout: 2, clock: { clock.date() },
                                           log: { s in lock.withLock { lines.append(s) } })
        try await t.healthCheck()
        let child = try XCTUnwrap(l.last)
        child.stderrClass = .profileLocked
        child.die(1)
        _ = await klass(t)
        XCTAssertTrue(lines.contains("browser: playwright_exit class=profile_locked status=1"), "\(lines)")
    }

    func testHungChildIsTerminatedAndRestartedUnderBackoff() async throws {
        let clock = TestClock()
        let lock = NSLock(); var lines: [String] = []
        let l = FakeLauncher(.healthy)
        let t = ManagedPlaywrightTransport(spec: dummySpec, launcher: l, initializeTimeout: 2, healthTimeout: 0.15,
                                           clock: { clock.date() }, log: { s in lock.withLock { lines.append(s) } })
        try await t.healthCheck()
        let hung = try XCTUnwrap(l.last)
        hung.script.onSend = nil   // alive, but answers nothing
        let k = await klass(t); XCTAssertEqual(k, "playwright_timeout")
        XCTAssertTrue(hung.hasExited, "the hung child was terminated")
        XCTAssertTrue(lock.withLock { lines }.contains { $0.hasPrefix("browser: playwright_hung") })
        let gated = await klass(t); XCTAssertEqual(gated, "playwright_restarting")
        XCTAssertEqual(l.launches, 1)
        clock.advance(1.01)
        let again = await klass(t); XCTAssertEqual(again, "ok")
        XCTAssertEqual(l.launches, 2, "restarted after the backoff")
        XCTAssertFalse(l.last === hung)
        await t.shutdown()
    }

    func testHungCallIsTerminatedOnlyWhenTheConfirmingPingAlsoTimesOut() async throws {
        let l = FakeLauncher(.healthy)
        let t = ManagedPlaywrightTransport(spec: dummySpec, launcher: l, initializeTimeout: 2, healthTimeout: 0.15,
                                           callTimeout: 0.15)
        try await t.healthCheck()
        let c = try XCTUnwrap(l.last)
        // A slow call on a child that still answers pings is not a hang.
        c.script.onSend = { [script = c.script] v in
            guard let id = v["id"]?.intValue, v["method"]?.stringValue == "ping" else { return }
            script.feed("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{}}\n")
        }
        do { _ = try await t.callTool("browser_navigate", arguments: [:]); XCTFail("expected a timeout") }
        catch let e as PlaywrightTransportError { XCTAssertEqual(e.errorClass, "playwright_timeout") }
        XCTAssertFalse(c.hasExited)
        // Now nothing is answered: the call and the confirming ping both time out.
        c.script.onSend = nil
        do { _ = try await t.callTool("browser_navigate", arguments: [:]); XCTFail("expected a timeout") }
        catch let e as PlaywrightTransportError { XCTAssertEqual(e.errorClass, "playwright_timeout") }
        XCTAssertTrue(c.hasExited)
        await t.shutdown()
    }
}

/// A temporary install tree whose `node` is a shell shim that runs the fake MCP server.
final class InstallTree {
    let root: URL
    init(mode: String = "normal", chromium: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("oab-pw-\(UUID().uuidString)")
        let v = root.appendingPathComponent("1.0")
        let fm = FileManager.default
        try fm.createDirectory(at: v.appendingPathComponent("node/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: v.appendingPathComponent("pkg/node_modules/@playwright/mcp"), withIntermediateDirectories: true)
        try fm.createDirectory(at: v.appendingPathComponent("chromium"), withIntermediateDirectories: true)
        let node = v.appendingPathComponent("node/bin/node")
        try "#!/bin/sh\nexec \"\(fakeServerPath())\" \(mode)\n".write(to: node, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        try "// cli".write(to: v.appendingPathComponent("pkg/node_modules/@playwright/mcp/cli.js"), atomically: true, encoding: .utf8)
        if chromium {
            let c = v.appendingPathComponent("chromium/chrome")
            try "#!/bin/sh\n".write(to: c, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: c.path)
        }
        try "{\"version\":\"1.0\",\"chromiumExecutable\":\"chromium/chrome\"}".write(to: root.appendingPathComponent("install.json"), atomically: true, encoding: .utf8)
    }
    var locator: ManagedPlaywrightLocator { .init(root: root) }
    deinit { try? FileManager.default.removeItem(at: root) }
}

final class ManagedPlaywrightLocatorTests: XCTestCase {
    func testMissingInvalidAndEscapingInstalls() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("oab-pw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        guard case .failure(let e0) = ManagedPlaywrightLocator(root: empty).locate() else { return XCTFail() }
        XCTAssertEqual(e0.errorClass, "playwright_not_installed")

        let noChromium = try InstallTree(chromium: false)
        guard case .failure(let e1) = noChromium.locator.locate() else { return XCTFail() }
        XCTAssertEqual(e1.errorClass, "playwright_install_invalid")

        let bad = try InstallTree()
        try "{ nope".write(to: bad.root.appendingPathComponent("install.json"), atomically: true, encoding: .utf8)
        guard case .failure(let e2) = bad.locator.locate() else { return XCTFail() }
        XCTAssertEqual(e2.errorClass, "playwright_install_invalid")

        let esc = try InstallTree()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("oab-outside-\(UUID().uuidString)")
        try "#!/bin/sh\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = esc.root.appendingPathComponent("1.0/chromium/evil")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try "{\"version\":\"1.0\",\"chromiumExecutable\":\"chromium/evil\"}".write(to: esc.root.appendingPathComponent("install.json"), atomically: true, encoding: .utf8)
        guard case .failure(let e3) = esc.locator.locate() else { return XCTFail() }
        XCTAssertEqual(e3.errorClass, "playwright_install_invalid")

        let dots = try InstallTree()
        try "{\"version\":\"../x\",\"chromiumExecutable\":\"chromium/chrome\"}".write(to: dots.root.appendingPathComponent("install.json"), atomically: true, encoding: .utf8)
        guard case .failure = dots.locator.locate() else { return XCTFail() }
    }

    func testLaunchVectorHasNoListenerFlagsAndAnAllowListEnvironment() throws {
        let t = try InstallTree()
        guard case .success(let spec) = t.locator.locate() else { return XCTFail() }
        let a = spec.arguments
        for banned in ["--port", "--host", "--allowed-hosts"] { XCTAssertFalse(a.contains(banned)) }
        XCTAssertTrue(a[0].hasSuffix("pkg/node_modules/@playwright/mcp/cli.js"))
        XCTAssertEqual(Array(a.dropFirst()).filter { $0.hasPrefix("--") },
                       ["--user-data-dir", "--output-dir", "--idle-timeout", "--browser", "--executable-path",
                        "--shared-browser-context", "--caps"])
        XCTAssertEqual(a[a.firstIndex(of: "--idle-timeout")! + 1], "1800000")
        XCTAssertEqual(a[a.firstIndex(of: "--caps")! + 1], "vision,pdf")
        XCTAssertEqual(Set(spec.environment.keys), ["HOME", "TMPDIR", "LANG", "PATH"])
        XCTAssertTrue(spec.environment["PATH"]!.hasSuffix(":/usr/bin:/bin"))
        let attrs = try FileManager.default.attributesOfItem(atPath: t.root.appendingPathComponent("profile").path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int ?? 0) & 0o777, 0o700)
    }
}

final class ManagedPlaywrightEndToEndTests: XCTestCase {
    func testRouterServesTheManagedChildThroughTheMCPServer() async throws {
        let t = try InstallTree()
        let backend = PlaywrightBackend(managed: t.locator)
        let router = BrowserRouter(playwright: backend, store: MemoryPreferenceStore())
        let server = MCPServer(name: "t", version: "0", tools: ToolCatalog.local(agentVersion: "test"), browser: router)
        let owner = server.scoped(to: .owner)
        let names = Set(listedNames(try await serverRequest(owner, "tools/list")))
        XCTAssertTrue(names.isSuperset(of: ["browser_navigate", "browser_snapshot"]))
        let res = try await serverRequest(owner, "tools/call", params: ["name": "browser_navigate", "arguments": [:]])
        XCTAssertEqual(res?.result?["structuredContent"]?["backend"]?.stringValue, "playwright")
        XCTAssertEqual(res?.result?["content"]?.arrayValue?.first?["text"]?.stringValue, "fake did browser_navigate")
        // observe sees and reaches no browser tool.
        let observe = Set(listedNames(try await serverRequest(server.scoped(to: .observe), "tools/list")))
        XCTAssertTrue(observe.filter { $0.hasPrefix("browser_") }.isEmpty)
        // sys_info-style report names the mode without a URL.
        let rep = await router.report()
        XCTAssertEqual(rep.backends.first?.mode, "managed")
        XCTAssertEqual(rep.active, .playwright)
        await backend.shutdown()
    }

    func testNotInstalledListsNothingAndSaysSo() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("oab-pw-\(UUID().uuidString)")
        let backend = PlaywrightBackend(managed: ManagedPlaywrightLocator(root: empty))
        let apple = FakeBrowserBackend(.appleEvents)
        let router = BrowserRouter(appleEvents: apple, playwright: backend, store: MemoryPreferenceStore())
        // Router falls back to Apple Events when it is ready.
        let r = await router.call("browser_navigate", arguments: [:], BrowserConnection(key: "a"))
        XCTAssertEqual(r["structuredContent"]?["backend"]?.stringValue, "appleEvents")
        // With nothing else, the call says Playwright is not installed.
        let solo = BrowserRouter(playwright: backend, store: MemoryPreferenceStore())
        let tools = await solo.tools(BrowserConnection(key: "b"))
        XCTAssertTrue(tools.isEmpty)
        let n = await solo.call("browser_navigate", arguments: [:], BrowserConnection(key: "b"))
        XCTAssertEqual(n["content"]?.arrayValue?.first?["text"]?.stringValue, BrowserRouter.notSetUp + " Playwright is not installed.")
        let rep = await solo.report()
        XCTAssertEqual(rep.line, "browser tools: playwright not installed")
        XCTAssertNil(rep.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path), "reading state must not create the install dir")
    }

    func testManagedPreferredOverAppleEventsWhenBothReady() async throws {
        let t = try InstallTree()
        let backend = PlaywrightBackend(managed: t.locator)
        let router = BrowserRouter(appleEvents: FakeBrowserBackend(.appleEvents), playwright: backend, store: MemoryPreferenceStore())
        let r = await router.call("browser_navigate", arguments: [:], BrowserConnection(key: "a"))
        XCTAssertEqual(r["structuredContent"]?["backend"]?.stringValue, "playwright")
        await backend.shutdown()
    }

    func testChildStderrCanaryNeverReachesLogsOrResults() async throws {
        let t = try InstallTree(mode: "stderr-canary")
        nonisolated(unsafe) var lines: [String] = []
        let lock = NSLock()
        let backend = PlaywrightBackend(managed: t.locator, log: { s in lock.withLock { lines.append(s) } })
        let router = BrowserRouter(playwright: backend, store: MemoryPreferenceStore(), log: { s in lock.withLock { lines.append(s) } })
        let r = await router.call("browser_navigate", arguments: [:], BrowserConnection(key: "a"))
        let rep = await router.report()
        let all = String(decoding: jsonBody(r), as: UTF8.self) + String(decoding: jsonBody(rep.json), as: UTF8.self) + lines.joined()
        XCTAssertFalse(all.contains("CANARY"), all)
    }
}

/// Records the order of transport creation and shutdown.
final class RecordingTransport: PlaywrightTransport, @unchecked Sendable {
    let name: String
    let events: EventLog
    init(_ name: String, _ events: EventLog) { self.name = name; self.events = events; events.add("create \(name)") }
    func healthCheck() async throws {}
    func listTools() async throws -> [JSONValue] { [] }
    func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue { .object([:]) }
    func shutdown() async { try? await Task.sleep(nanoseconds: 50_000_000); events.add("shutdown \(name)") }
}
final class EventLog: @unchecked Sendable {
    private let lock = NSLock(); private var _e: [String] = []
    func add(_ s: String) { lock.withLock { _e.append(s) } }
    var all: [String] { lock.withLock { _e } }
}

final class ManagedInstallChangeTests: XCTestCase {
    func testChangedInstallShutsDownTheOldChildBeforeCreatingTheNewTransport() async throws {
        let t = try InstallTree()
        let events = EventLog()
        let n = NSLock(); var count = 0
        let backend = PlaywrightBackend(managed: t.locator, makeTransport: { _, _ in
            let i = n.withLock { count += 1; return count }
            return RecordingTransport("t\(i)", events)
        })
        _ = await backend.status()
        _ = await backend.status()
        XCTAssertEqual(events.all, ["create t1"], "an unchanged install keeps its transport")
        // A new version: copy 1.0 to 2.0 and repoint install.json.
        let fm = FileManager.default
        try fm.copyItem(at: t.root.appendingPathComponent("1.0"), to: t.root.appendingPathComponent("2.0"))
        try "{\"version\":\"2.0\",\"chromiumExecutable\":\"chromium/chrome\"}"
            .write(to: t.root.appendingPathComponent("install.json"), atomically: true, encoding: .utf8)
        _ = await backend.status()
        XCTAssertEqual(events.all, ["create t1", "shutdown t1", "create t2"])
        await backend.shutdown()
        XCTAssertEqual(events.all.last, "shutdown t2")
    }
}
