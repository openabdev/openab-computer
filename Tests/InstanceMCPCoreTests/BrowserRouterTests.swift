import Foundation
import XCTest
@testable import InstanceMCPCore

final class BrowserRouterTests: XCTestCase {
    let conn = BrowserConnection(key: "c1")

    func router(a: FakeBrowserBackend?, p: FakeBrowserBackend?, pref: BrowserPreference = .auto,
                clock: TestClock = TestClock()) -> BrowserRouter {
        BrowserRouter(appleEvents: a, playwright: p, store: MemoryPreferenceStore(pref), clock: { clock.date() })
    }
    func text(_ r: JSONValue) -> String { r["content"]?.arrayValue?.first?["text"]?.stringValue ?? "" }
    func names(_ t: [JSONValue]) -> Set<String> { Set(t.compactMap { $0["name"]?.stringValue }) }

    func testAutoPrefersPlaywright() async {
        let a = FakeBrowserBackend(.appleEvents), p = FakeBrowserBackend(.playwright)
        let r = router(a: a, p: p)
        let res = await r.call("browser_navigate", arguments: [:], conn)
        XCTAssertEqual(res["structuredContent"]?["backend"]?.stringValue, "playwright")
        XCTAssertEqual(p.calls, ["browser_navigate"]); XCTAssertTrue(a.calls.isEmpty)
    }

    func testAutoFallsToAppleEventsWhenPlaywrightNotReady() async {
        let a = FakeBrowserBackend(.appleEvents), p = FakeBrowserBackend(.playwright, status: .needsSetup("x"))
        let res = await router(a: a, p: p).call("browser_navigate", arguments: [:], conn)
        XCTAssertEqual(res["structuredContent"]?["backend"]?.stringValue, "appleEvents")
    }

    func testPreferenceTable() async {
        let ready = FakeBrowserBackend(.appleEvents), down = FakeBrowserBackend(.playwright, status: .unavailable("x"))
        // appleEvents pinned, ready: A. playwright pinned, not ready: none, no silent switch.
        var r = router(a: ready, p: down, pref: .appleEvents)
        let t1 = await r.tools(conn); XCTAssertFalse(t1.isEmpty)
        r = router(a: ready, p: down, pref: .playwright)
        let none = await r.call("browser_navigate", arguments: [:], conn)
        XCTAssertEqual(text(none), BrowserRouter.notSetUp)
        XCTAssertEqual(none["isError"]?.boolValue, true)
        XCTAssertTrue(ready.calls.isEmpty)
        let r2 = router(a: down2(), p: FakeBrowserBackend(.playwright), pref: .appleEvents)
        let t2 = await r2.tools(conn); XCTAssertTrue(t2.isEmpty)
    }
    func down2() -> FakeBrowserBackend { FakeBrowserBackend(.appleEvents, status: .needsSetup("x")) }

    func testNothingReadyListsNothingAndSaysNotSetUp() async {
        let r = router(a: nil, p: FakeBrowserBackend(.playwright, status: .needsSetup("playwright_not_installed")))
        let t3 = await r.tools(conn); XCTAssertTrue(t3.isEmpty)
        let c3 = await r.call("browser_click", arguments: [:], conn)
        XCTAssertEqual(text(c3), BrowserRouter.notSetUp)
    }

    func testHeaderOverridesStoredPreferenceAndStoresNothing() async {
        let a = FakeBrowserBackend(.appleEvents), p = FakeBrowserBackend(.playwright)
        let store = MemoryPreferenceStore(.playwright)
        let r = BrowserRouter(appleEvents: a, playwright: p, store: store)
        let res = await r.call("browser_navigate", arguments: [:], BrowserConnection(key: "h", override: .appleEvents))
        XCTAssertEqual(res["structuredContent"]?["backend"]?.stringValue, "appleEvents")
        XCTAssertEqual(store.load(), .playwright)
    }

    func testIdentityGuardBothDirectionsAndExpiry() async {
        let clock = TestClock()
        // Playwright conversation; Playwright goes away; Apple Events is ready but not used.
        let a = FakeBrowserBackend(.appleEvents), p = FakeBrowserBackend(.playwright)
        let r = router(a: a, p: p, clock: clock)
        _ = await r.call("browser_navigate", arguments: [:], conn)
        p.status_ = .unavailable("gone")
        let t4 = await r.tools(conn); XCTAssertTrue(t4.isEmpty)
        let blocked = await r.call("browser_navigate", arguments: [:], conn)
        XCTAssertEqual(blocked["isError"]?.boolValue, true)
        XCTAssertTrue(text(blocked).contains("not used automatically"))
        XCTAssertTrue(a.calls.isEmpty, "no fallback")
        clock.advance(31 * 60)
        let t5 = await r.tools(conn); XCTAssertFalse(t5.isEmpty, "recomputed after 30 minutes")
        // Reverse: Apple Events conversation; Playwright becomes ready later and does not take over.
        let a2 = FakeBrowserBackend(.appleEvents), p2 = FakeBrowserBackend(.playwright, status: .needsSetup("x"))
        let r2 = router(a: a2, p: p2, clock: clock)
        _ = await r2.call("browser_navigate", arguments: [:], conn)
        p2.status_ = .ready
        let again = await r2.call("browser_navigate", arguments: [:], conn)
        XCTAssertEqual(again["structuredContent"]?["backend"]?.stringValue, "appleEvents")
        // A header pin recomputes.
        let pinned = await r2.call("browser_navigate", arguments: [:], BrowserConnection(key: "c1", override: .playwright))
        XCTAssertEqual(pinned["structuredContent"]?["backend"]?.stringValue, "playwright")
    }

    func testNoFallbackOnCallFailureAndFixedErrorText() async {
        let a = FakeBrowserBackend(.appleEvents), p = FakeBrowserBackend(.playwright)
        p.failure = BrowserBackendError("upstream_timeout")
        let res = await router(a: a, p: p).call("browser_navigate", arguments: [:], conn)
        XCTAssertEqual(res["isError"]?.boolValue, true)
        XCTAssertEqual(text(res), "Browser call failed: upstream_timeout")
        XCTAssertTrue(a.calls.isEmpty)
    }

    func testUnsupportedToolIsAToolErrorAndListIsFilteredToCatalog() async {
        let p = FakeBrowserBackend(.playwright, names: ["browser_navigate", "browser_something_new"])
        let r = router(a: nil, p: p)
        let t6 = await r.tools(conn); XCTAssertEqual(names(t6), ["browser_navigate"])
        let res = await r.call("browser_click", arguments: [:], conn)
        XCTAssertEqual(res["isError"]?.boolValue, true)
        XCTAssertTrue(text(res).contains("not available"))
        XCTAssertTrue(p.calls.isEmpty)
    }

    func testStructuredContentIsMergedAndContentKept() {
        let r = BrowserRouter.tag(["content": [["type": "image", "data": "AA", "mimeType": "image/png"]],
                                   "structuredContent": ["k": 1]], backend: .playwright)
        XCTAssertEqual(r["content"]?.arrayValue?.count, 1)
        XCTAssertEqual(r["structuredContent"]?["k"]?.intValue, 1)
        XCTAssertEqual(r["structuredContent"]?["backend"]?.stringValue, "playwright")
    }

    func testPreferenceStoreResetsUnknownValue() {
        let d = UserDefaults(suiteName: "oab.test.\(UUID().uuidString)")!
        d.set("bogus", forKey: UserDefaultsBrowserPreferenceStore.key)
        let lines = NSLock(); nonisolated(unsafe) var logged: [String] = []
        let s = UserDefaultsBrowserPreferenceStore(defaults: d, log: { line in lines.withLock { logged.append(line) } })
        XCTAssertEqual(s.load(), .auto)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("browserTools.backend.v1"))
        s.save(.playwright); XCTAssertEqual(s.load(), .playwright)
    }
}

final class BrowserServerWiringTests: XCTestCase {
    func server(_ profile: ToolProfile, backend: FakeBrowserBackend) -> MCPServer {
        let router = BrowserRouter(playwright: backend, store: MemoryPreferenceStore())
        return MCPServer(name: "t", version: "0", tools: ToolCatalog.local(agentVersion: "test"), browser: router)
            .scoped(to: profile)
    }
    func call(_ s: MCPServer, _ name: String) async throws -> JSONRPCResponse? {
        try await serverRequest(s, "tools/call", params: ["name": .string(name), "arguments": [:]])
    }

    func testOwnerListsAndCallsCatalogToolsOnly() async throws {
        let b = FakeBrowserBackend(.playwright, names: BrowserToolCatalog.allNames + ["browser_something_new"])
        let s = server(.owner, backend: b)
        let names = Set(listedNames(try await serverRequest(s, "tools/list")))
        XCTAssertTrue(BrowserToolCatalog.allNameSet.isSubset(of: names))
        XCTAssertFalse(names.contains("browser_something_new"))
        let ok = try await call(s, "browser_navigate")
        XCTAssertNil(ok?.error)
        XCTAssertEqual(ok?.result?["structuredContent"]?["backend"]?.stringValue, "playwright")
        let unknown = try await call(s, "browser_something_new")
        XCTAssertEqual(unknown?.error?.code, JSONRPCError.invalidParams)
        XCTAssertTrue(unknown?.error?.message.contains("unknown tool") == true)
    }

    func testObserveSeesAndReachesNone() async throws {
        let b = FakeBrowserBackend(.playwright)
        let s = server(.observe, backend: b)
        let lr = try await serverRequest(s, "tools/list")
        XCTAssertEqual(Set(listedNames(lr)), ["sys_info", "screenshot"])
        for n in BrowserToolCatalog.allNames + ["browser_something_new"] {
            let r = try await call(s, n)
            XCTAssertEqual(r?.error?.code, JSONRPCError.invalidParams, n)
            XCTAssertTrue(r?.error?.message.contains("unknown tool") == true, n)
        }
        XCTAssertTrue(b.calls.isEmpty)
    }

    func testScopedAndMappingForwardTheRouter() async throws {
        let b = FakeBrowserBackend(.playwright)
        let base = MCPServer(name: "t", version: "0", tools: ToolCatalog.local(agentVersion: "test"),
                             browser: BrowserRouter(playwright: b, store: MemoryPreferenceStore()))
        XCTAssertNotNil(base.scoped(to: .owner).browser)
        XCTAssertNotNil(base.mappingTools { $0 }.browser)
        XCTAssertNotNil(base.withBrowserConnection(key: "k").browser)
        XCTAssertNotNil(Switchboard.server(base, profile: .owner).browser)
    }
}
