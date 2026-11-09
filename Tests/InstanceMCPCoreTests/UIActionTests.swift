import CoreGraphics
import Foundation
import XCTest
@testable import InstanceMCPCore

// MARK: - fixture

private func node(_ role: String?, _ title: String? = nil, extra: [String: UIAttrValue] = [:],
                  _ kids: FakeUIElement...) -> FakeUIElement {
    var a: [String: UIAttrValue] = [:]
    if let role { a["AXRole"] = .string(role) }
    if let title { a["AXTitle"] = .string(title) }
    a.merge(extra) { _, b in b }
    let e = FakeUIElement(a, kids)
    e.pidValue = 20
    return e
}

private let display = UIDisplayMap(displays: [(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))], mainID: 1)

private func encode(_ v: JSONValue) -> String {
    String(decoding: try! JSONCoding.encoder.encode(v), as: UTF8.self)
}

/// A fake TextEdit: one window (e1) with a text area (e2), an OK button (e3), a secure
/// field (e4) and a node whose role is unreadable (e5); with `include_menu_bar`, the
/// menu bar (e6) › File (e7) › menu (e8) › Close (e9). Both tools share one private
/// cache and one fake clock.
private final class Fixture: @unchecked Sendable {
    let app = node("AXApplication")
    let textArea = node("AXTextArea", extra: ["AXValue": .string("hello")])
    let ok = node("AXButton", "OK")
    let secure = node("AXSecureTextField", "Password")
    let blob = node(nil)
    let window: FakeUIElement
    let close = node("AXMenuItem", "Close")
    let menuBar: FakeUIElement
    let cache: UISnapshotCache
    let clock = FakeClock()
    let events = LogBox()
    var activateResult = true
    var trusted = true
    let gate = UIAXGate()
    private let ids = Counter()

    init(cache: UISnapshotCache = UISnapshotCache()) {
        self.cache = cache
        window = node("AXWindow", "Untitled", textArea, ok, secure, blob)
        menuBar = node("AXMenuBar", nil, node("AXMenuBarItem", "File", node("AXMenu", "File", close)))
        for e in [textArea, ok, secure, blob] { e.named["AXWindow"] = window }
        app.named["AXFocusedWindow"] = window
        app.lists["AXWindows"] = [window]
        app.named["AXMenuBar"] = menuBar
        textArea.settable = ["AXValue", "AXFocused"]
        secure.settable = ["AXValue", "AXFocused"]
        ok.actions = ["AXPress"]
    }

    var snapshotEnv: UISnapshotTool.Environment {
        let running = [UIRunningApp(pid: 20, bundleID: "com.apple.TextEdit", name: "TextEdit")]
        let app = self.app, clock = self.clock, ids = self.ids
        return UISnapshotTool.Environment(
            isTrusted: { true }, selfPid: 99, runningApps: { running }, frontmostPid: { _ in 20 },
            frontmostGate: UIAXGate(), appElement: { _ in app }, displays: { display },
            now: { clock.t }, newSnapshotID: { String(format: "snap-%08ld", ids.add(1)) }, cache: cache)
    }

    var actionEnv: UIActionTool.Environment {
        let clock = self.clock
        return UIActionTool.Environment(
            isTrusted: { [unowned self] in trusted }, selfPid: 99, cache: cache, now: { clock.t },
            activateApp: { [unowned self] pid, _ in events.add("activate \(pid)"); return activateResult },
            gate: gate)
    }

    var server: MCPServer {
        MCPServer(name: "t", version: "0", tools: [UISnapshotTool(environment: snapshotEnv), UIActionTool(environment: actionEnv)])
    }

    func call(_ tool: String, _ args: JSONValue) async -> JSONRPCResponse {
        let req = try! MCPServer.parse(rpc("tools/call", params: ["name": .string(tool), "arguments": args])).get()
        return await server.handle(req)!
    }

    /// Take a snapshot and return its id.
    @discardableResult
    func snapshot(menuBar: Bool = false) async -> String {
        let r = await call("ui_snapshot", menuBar ? ["include_menu_bar": true] : [:])
        return r.result?["structuredContent"]?["snapshot_id"]?.stringValue ?? "?"
    }

    func act(_ args: JSONValue) async -> JSONRPCResponse { await call("ui_action", args) }
}

private extension JSONRPCResponse {
    var text: String { result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "" }
    var isToolError: Bool { result?["isError"] == true }
    var structured: JSONValue? { result?["structuredContent"] }
}

// MARK: - the cache

final class UISnapshotCacheTests: XCTestCase {
    func testCacheKeepsTheLastFour() async {
        let f = Fixture()
        var ids: [String] = []
        for _ in 0..<5 { ids.append(await f.snapshot()) }
        XCTAssertEqual(Set(ids).count, 5)
        XCTAssertNil(f.cache.lookup(ids[0], at: 0), "the oldest is dropped")
        for id in ids.dropFirst() { XCTAssertNotNil(f.cache.lookup(id, at: 0)) }
        XCTAssertEqual(f.cache.count(at: 0), UISnapshotCache.defaultCapacity)
        XCTAssertEqual(UISnapshotCache.defaultCapacity, 4)
    }

    func testCacheTTL() async {
        let f = Fixture()
        let id = await f.snapshot()
        XCTAssertNotNil(f.cache.lookup(id, at: 299))
        XCTAssertNil(f.cache.lookup(id, at: 300))
        XCTAssertEqual(UISnapshotCache.defaultTTL, 300)
        f.clock.t = 300
        let next = await f.snapshot()
        XCTAssertEqual(f.cache.count(at: 300), 1, "purged on the next store")
        XCTAssertNotNil(f.cache.lookup(next, at: 300))
    }

    func testSnapshotCallStoresRecords() async throws {
        let f = Fixture()
        let id = await f.snapshot()
        let snap = try XCTUnwrap(f.cache.lookup(id, at: 0))
        XCTAssertEqual(snap.app.pid, 20)
        XCTAssertEqual(Set(snap.records.keys), ["e1", "e2", "e3", "e4", "e5"])
        let win = try XCTUnwrap(snap.records["e1"])
        XCTAssertTrue(win.element === f.window && win.root === f.window, "a window ref's root is itself")
        let ok = try XCTUnwrap(snap.records["e3"])
        XCTAssertTrue(ok.element === f.ok && ok.root === f.window)
        XCTAssertEqual(ok.role, "AXButton")
        XCTAssertEqual(ok.title, "OK")
        XCTAssertEqual(ok.rootRole, "AXWindow")
        XCTAssertEqual(ok.path, [f.window.identity, f.ok.identity])
        XCTAssertTrue(try XCTUnwrap(snap.records["e4"]).masked)
        XCTAssertNil(try XCTUnwrap(snap.records["e5"]).role)
    }

    func testIncludeMenuBarAppendsTheMenuBar() async throws {
        let f = Fixture()
        let r = await f.call("ui_snapshot", ["include_menu_bar": true])
        let windows = try XCTUnwrap(r.structured?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[1]["ref"], "e6")
        XCTAssertEqual(windows[1]["role"], "AXMenuBar")
        let snap = try XCTUnwrap(f.cache.lookup(r.structured?["snapshot_id"]?.stringValue ?? "", at: 0))
        let close = try XCTUnwrap(snap.records["e9"])
        XCTAssertTrue(close.element === f.close && close.root === f.menuBar)
        XCTAssertTrue(r.text.contains(#"[e9] AXMenuItem "Close""#), r.text)
    }

    func testMenuBarNotReadByDefault() async {
        let f = Fixture()
        await f.snapshot()
        XCTAssertFalse(f.app.elementRequests.contains("AXMenuBar"))
        let bad = await f.call("ui_snapshot", ["include_menu_bar": "yes"])
        XCTAssertEqual(bad.error?.message, "Invalid params: include_menu_bar must be a boolean")
    }
}

// MARK: - the tool

final class UIActionToolTests: XCTestCase {
    private func assertNothingDone(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        for e in [f.window, f.textArea, f.ok, f.secure, f.close] {
            XCTAssertTrue(e.performed.isEmpty, "performed \(e.performed)", file: file, line: line)
            XCTAssertTrue(e.sets.isEmpty, "set \(e.sets.map(\.0))", file: file, line: line)
        }
    }

    // Stale refs: never a guess, never an action.

    func testUnknownSnapshotIsStale() async {
        let f = Fixture()
        await f.snapshot()
        let r = await f.act(["snapshot_id": "snap-ffffffff", "ref": "e3", "action": "press"])
        XCTAssertTrue(r.isToolError)
        XCTAssertEqual(r.text, UIActionTool.Errors.staleSnapshot("snap-ffffffff"))
        XCTAssertTrue(r.text.hasPrefix("stale ref:") && r.text.contains("take a new ui_snapshot"), r.text)
        assertNothingDone(f)
    }

    func testEvictedSnapshotIsStale() async {
        let f = Fixture()
        let first = await f.snapshot()
        for _ in 0..<4 { await f.snapshot() }
        let r = await f.act(["snapshot_id": .string(first), "ref": "e3", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.staleSnapshot(first))
        assertNothingDone(f)
    }

    func testExpiredSnapshotIsStale() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.clock.t = 300
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.staleSnapshot(id))
        assertNothingDone(f)
    }

    func testUnknownRef() async {
        let f = Fixture()
        let id = await f.snapshot()
        let r = await f.act(["snapshot_id": .string(id), "ref": "e42", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.unknownRef("e42", snapshot: id, count: 5))
        assertNothingDone(f)
    }

    func testVanishedElementIsStale() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.attrError = .invalidElement
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.stale("e3", "no longer exists"))
        assertNothingDone(f)
    }

    func testRoleChangeIsStale() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.attrs["AXRole"] = .string("AXCheckBox")
        f.ok.actions = ["AXPress"]
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.stale("e3", "is now AXCheckBox, not the AXButton it was"))
        f.ok.attrs["AXRole"] = .string("AXButton")
        f.ok.attrs["AXSubrole"] = .string("AXCloseButton")
        let r2 = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r2.text, UIActionTool.Errors.stale("e3", "is now AXButton/AXCloseButton, not the AXButton it was"))
        assertNothingDone(f)
    }

    func testOtherPidIsStale() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.pidValue = 4242
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.stale("e3", "no longer belongs to TextEdit"))
        f.ok.pidValue = nil
        let r2 = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r2.text, UIActionTool.Errors.stale("e3", "no longer belongs to TextEdit"))
        assertNothingDone(f)
    }

    func testElementThatLeftItsWindowIsStale() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.named["AXWindow"] = node("AXWindow", "Untitled")
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.stale("e3", "has left its window"))
        assertNothingDone(f)
    }

    func testGoneWindowRootIsStale() async {
        let f = Fixture()
        f.close.actions = ["AXPress"]
        let id = await f.snapshot(menuBar: true)
        f.menuBar.attrError = .invalidElement
        let r = await f.act(["snapshot_id": .string(id), "ref": "e9", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.stale("e9", "its menu bar is gone"))
        // A text area whose AXWindow went away and whose window is gone too.
        f.textArea.named["AXWindow"] = nil
        f.window.attrError = .invalidElement
        let r2 = await f.act(["snapshot_id": .string(id), "ref": "e2", "action": "focus"])
        XCTAssertEqual(r2.text, UIActionTool.Errors.stale("e2", "has left its window"))
        assertNothingDone(f)
    }

    func testWindowDescendantWithNoWindowIsStaleEvenIfTheWindowLives() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.window.requested = []
        // The recorded window still answers, but the field no longer names any window:
        // only menu-bar refs may lack an AXWindow.
        f.textArea.named["AXWindow"] = nil
        let r = await f.act(["snapshot_id": .string(id), "ref": "e2", "action": "set_value", "value": "x"])
        XCTAssertEqual(r.text, UIActionTool.Errors.stale("e2", "has left its window"))
        f.ok.named["AXWindow"] = nil
        let r2 = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r2.text, UIActionTool.Errors.stale("e3", "has left its window"))
        XCTAssertTrue(f.window.requested.isEmpty, "no fallback to probing the old window")
        assertNothingDone(f)
    }

    func testMenuItemWithNoWindowStillWorks() async {
        let f = Fixture()
        f.close.actions = ["AXPress"]
        let id = await f.snapshot(menuBar: true)
        let r = await f.act(["snapshot_id": .string(id), "ref": "e9", "action": "press"])
        XCTAssertFalse(r.isToolError, r.text)
        XCTAssertEqual(f.close.performed, ["AXPress"])
    }

    func testUnreadableRoleRefIsRefused() async {
        let f = Fixture()
        let id = await f.snapshot()
        let r = await f.act(["snapshot_id": .string(id), "ref": "e5", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.unverifiable("e5"))
        XCTAssertTrue(f.blob.calls.isEmpty, "not even asked")
    }

    // Support checks.

    func testUnsupportedActionListsSupported() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.actions = ["AXShowMenu", "AXSomethingCustom"]
        f.ok.settable = ["AXFocused"]
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertTrue(r.isToolError)
        XCTAssertEqual(r.text, "e3 (AXButton) does not support press. Supported on it: focus, show_menu")
        assertNothingDone(f)
    }

    func testSetValueNeedsSettableValue() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.textArea.settable = ["AXFocused"]
        let r = await f.act(["snapshot_id": .string(id), "ref": "e2", "action": "set_value", "value": "x"])
        XCTAssertEqual(r.text, UIActionTool.Errors.unsupported(action: "set_value", ref: "e2", role: "AXTextArea", supported: ["focus"]))
        // An unsupported-attribute error counts as unsupported, not as a failure.
        f.textArea.settableError = .other(-25205)
        let r2 = await f.act(["snapshot_id": .string(id), "ref": "e2", "action": "set_value", "value": "x"])
        XCTAssertTrue(r2.text.contains("does not support set_value"), r2.text)
        assertNothingDone(f)
    }

    func testNoSupportedActionPointsToMouse() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.actions = []
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r.text, "e3 (AXButton) does not support press. No ui_action action is supported on it; use screenshot + mouse")
        assertNothingDone(f)
    }

    func testEachActionMapsToItsAXCall() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.actions = ["AXPress", "AXShowMenu", "AXConfirm", "AXCancel", "AXIncrement", "AXDecrement"]
        for a in ["press", "show_menu", "confirm", "cancel", "increment", "decrement"] {
            let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": .string(a)])
            XCTAssertFalse(r.isToolError, r.text)
            XCTAssertEqual(r.structured?["success"], true)
            XCTAssertEqual(r.structured?["action"], .string(a))
        }
        XCTAssertEqual(f.ok.performed, ["AXPress", "AXShowMenu", "AXConfirm", "AXCancel", "AXIncrement", "AXDecrement"])

        _ = await f.act(["snapshot_id": .string(id), "ref": "e2", "action": "focus"])
        for v: JSONValue in ["text", 3.5, true] {
            _ = await f.act(["snapshot_id": .string(id), "ref": "e2", "action": "set_value", "value": v])
        }
        XCTAssertEqual(f.textArea.sets.map(\.0), ["AXFocused", "AXValue", "AXValue", "AXValue"])
        XCTAssertEqual(f.textArea.sets.map(\.1), [.bool(true), .string("text"), .number(3.5), .bool(true)])

        // focus is AXFocused only: a window that offers AXRaise but no settable
        // AXFocused is refused, never raised without activate.
        f.window.actions = ["AXRaise"]
        let w = await f.act(["snapshot_id": .string(id), "ref": "e1", "action": "focus"])
        XCTAssertEqual(w.text, UIActionTool.Errors.unsupported(action: "focus", ref: "e1", role: "AXWindow", supported: []))
        XCTAssertTrue(f.window.performed.isEmpty, "not raised")
        f.window.settable = ["AXFocused"]
        let w2 = await f.act(["snapshot_id": .string(id), "ref": "e1", "action": "focus"])
        XCTAssertFalse(w2.isToolError, w2.text)
        XCTAssertEqual(f.window.sets.map(\.0), ["AXFocused"])
        XCTAssertTrue(f.window.performed.isEmpty, "still not raised")
        XCTAssertTrue(f.events.all.isEmpty, "never activated")
    }

    func testUnsupportedReportsStaleFoundWhileListing() async {
        let f = Fixture()
        let id = await f.snapshot()
        // set_value passes the settable check, the app rejects it as unsupported, and the
        // element vanishes while the supported list is built: stale wins.
        f.textArea.setError = .other(-25205)
        f.textArea.actionNamesError = .invalidElement
        let r = await f.act(["snapshot_id": .string(id), "ref": "e2", "action": "set_value", "value": "x"])
        XCTAssertEqual(r.text, UIActionTool.Errors.stale("e2", "no longer exists"))
    }

    func testSchemaAndParserShareTheRefPattern() {
        XCTAssertEqual(UIActionTool().inputSchema["properties"]?["ref"]?["pattern"], .string(UIActionTool.refPattern))
        XCTAssertThrowsError(try UIActionTool.parse(["snapshot_id": "s", "ref": "e1234567890", "action": "press"]))
        XCTAssertNoThrow(try UIActionTool.parse(["snapshot_id": "s", "ref": "e123456789", "action": "press"]))
    }

    func testClockAdvancesMonotonically() {
        let a = UIClock.now()
        let b = UIClock.now()
        XCTAssertGreaterThan(a, 0)
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func testSuccessResponse() async {
        let f = Fixture()
        let id = await f.snapshot()
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r.text, #"ui_action press [e3] AXButton "OK" in TextEdit (pid 20): done. Take a new ui_snapshot to confirm."#)
        let s = r.structured
        XCTAssertEqual(s?["snapshot_id"], .string(id))
        XCTAssertEqual(s?["ref"], "e3")
        XCTAssertEqual(s?["target"], ["role": "AXButton", "title": "OK"])
        XCTAssertEqual(s?["app"], ["pid": 20, "name": "TextEdit", "bundle_id": "com.apple.TextEdit"])
        XCTAssertEqual(s?["activated"], false)
        XCTAssertEqual(s?["post_state"], ["focused": false])
        XCTAssertNotNil(s?["elapsed_ms"])
    }

    // Secure fields and value redaction.

    func testSecureSetValueIsNeverLoggedOrEchoed() async throws {
        for subroleCase in [false, true] {
            let f = Fixture()
            if subroleCase {
                f.secure.attrs["AXRole"] = .string("AXTextField")
                f.secure.attrs["AXSubrole"] = .string("AXSecureTextField")
            }
            let secret = "hunter2-" + UUID().uuidString
            f.secure.onPerform = { f.secure.attrs["AXNumberOfCharacters"] = .number(Double(secret.count)) }

            // Through the HTTP endpoint: agent.log and the menu bar read these lines.
            let box = LogBox()
            let ep = MCPHTTPEndpoint(server: f.server, auth: AuthPolicy(allowedLogins: ["a@b"]), log: { box.add($0) })
            func post(_ body: Data) -> HTTPRequest {
                HTTPRequest(method: "POST", path: "/mcp", query: nil,
                            headers: ["content-type": "application/json", "tailscale-user-login": "a@b"], body: body)
            }
            _ = await ep.handle(post(rpc("initialize", params: ["protocolVersion": "2025-06-18"])), remoteIsLoopback: true)
            let snap = await ep.handle(post(rpc("tools/call", params: ["name": "ui_snapshot", "arguments": [:]])), remoteIsLoopback: true)
            let id = try XCTUnwrap(decodeJSON(snap.body)["result"]?["structuredContent"]?["snapshot_id"]?.stringValue)
            let r = await ep.handle(post(rpc("tools/call", params: ["name": "ui_action", "arguments":
                ["snapshot_id": .string(id), "ref": "e4", "action": "set_value", "value": .string(secret)]])), remoteIsLoopback: true)
            let body = String(decoding: r.body, as: UTF8.self)
            XCTAssertFalse(body.contains(secret), body)
            XCTAssertFalse(body.contains("hunter2"), body)
            let result = decodeJSON(r.body)["result"]
            XCTAssertNil(result?["isError"], body)
            XCTAssertEqual(result?["structuredContent"]?["post_state"]?["masked"], true)
            XCTAssertEqual(result?["structuredContent"]?["target"]?["masked"], true)
            XCTAssertNil(result?["structuredContent"]?["post_state"]?["value"])
            XCTAssertTrue(body.contains("value set (not shown)"), body)
            XCTAssertEqual(box.all.filter { $0.contains(" tools/call ") }, ["a@b tools/call ui_snapshot", "a@b tools/call ui_action"])
            for l in box.all { XCTAssertFalse(l.contains(secret), l) }

            // It did reach the field, and its value was never read back.
            XCTAssertEqual(f.secure.sets.map(\.0), ["AXValue"])
            XCTAssertEqual(f.secure.sets.first?.1, .string(secret))
            XCTAssertFalse(f.secure.requested.contains("AXValue"), "\(f.secure.requested)")
            XCTAssertFalse(f.secure.requested.contains("AXStringForRange"))

            // Through a reverse attach (openab-pty / switchboard): the same.
            let rbox = LogBox()
            let cfg = ReverseAttachClient.Config(runtime: URL(string: "ws://h:1")!, session: "s", secret: "x",
                                                 profile: .owner, deadline: .distantFuture)
            let client = ReverseAttachClient(config: cfg, server: f.server, log: { rbox.add($0) })
            let reply = await client.answer(String(decoding: rpc("tools/call", id: 3, params: ["name": "ui_action", "arguments":
                ["snapshot_id": .string(id), "ref": "e4", "action": "set_value", "value": .string(secret)]]), as: UTF8.self))
            let rtext = try XCTUnwrap(reply)
            XCTAssertFalse(rtext.contains(secret), rtext)
            XCTAssertEqual(rbox.all, ["sandbox[s] tools/call ui_action"])
            XCTAssertFalse(f.secure.requested.contains("AXValue"))
        }
    }

    /// Through the switchboard (which audits call arguments, openab-sb#16), secure
    /// set_value is refused unless the operator opted in. Non-secure fields and other
    /// actions are unaffected, and the value is never in the reply or the log.
    func testSecureSetValueThroughTheSwitchboard() async throws {
        for subroleCase in [false, true] {
            for allowed in [false, true] {
                let f = Fixture()
                if subroleCase {
                    f.secure.attrs["AXRole"] = .string("AXTextField")
                    f.secure.attrs["AXSubrole"] = .string("AXSecureTextField")
                }
                let id = await f.snapshot()
                let secret = "canary-" + UUID().uuidString
                let box = LogBox()
                let cfg = ReverseAttachClient.Config.switchboard(url: URL(string: "wss://sb.example.invalid/vm/attach")!,
                                                                 secret: "x", profile: .owner)
                let served = allowed ? Switchboard.server(f.server, profile: .owner, allowSecureSetValue: true)
                                     : Switchboard.server(f.server, profile: .owner)
                let client = ReverseAttachClient(config: cfg, server: served, log: { box.add($0) })
                func call(_ ref: String, _ action: String, _ value: JSONValue?) async throws -> JSONValue {
                    var a: [String: JSONValue] = ["snapshot_id": .string(id), "ref": .string(ref), "action": .string(action)]
                    if let value { a["value"] = value }
                    let answered = await client.answer(String(decoding: rpc("tools/call", id: 7, params:
                        ["name": "ui_action", "arguments": .object(a)]), as: UTF8.self))
                    let reply = try XCTUnwrap(answered)
                    XCTAssertFalse(reply.contains(secret), reply)
                    return decodeJSON(Data(reply.utf8))["result"] ?? .null
                }
                let r = try await call("e4", "set_value", .string(secret))
                let text = r["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
                if allowed {
                    XCTAssertNil(r["isError"], text)
                    XCTAssertEqual(f.secure.sets.map(\.0), ["AXValue"])
                } else {
                    XCTAssertEqual(r["isError"], true)
                    XCTAssertEqual(text, UIActionTool.Errors.secureOverSwitchboard)
                    XCTAssertTrue(f.secure.sets.isEmpty, "nothing was done")
                    XCTAssertFalse(text.contains("`key`"), "key type is audited the same way")
                    XCTAssertTrue(text.contains("/mcp") && text.contains("audit_args = false"), text)
                }
                // Focus on the secure field, and set_value on a plain field, still work.
                let focus = try await call("e4", "focus", nil)
                XCTAssertNil(focus["isError"])
                let plain = try await call("e2", "set_value", "plain text")
                XCTAssertNil(plain["isError"])
                XCTAssertEqual(f.textArea.sets.first?.1, .string("plain text"))
                for l in box.all { XCTAssertFalse(l.contains(secret), l) }
                XCTAssertEqual(box.all.count, 3)
            }
        }
        // A direct connection (/mcp, openab-pty attach) is not affected: the default is allowed.
        XCTAssertTrue(UIActionTool().environment.allowSecureSetValue)
        let full = MCPServer(name: "t", version: "0", tools: ToolCatalog.local(agentVersion: "t"))
        let sbTool = Switchboard.server(full, profile: .owner).allTools.compactMap { $0 as? UIActionTool }
        XCTAssertEqual(sbTool.map(\.environment.allowSecureSetValue), [false])
        XCTAssertEqual(Switchboard.server(full, profile: .owner).toolNames, full.scoped(to: .owner).toolNames)
        XCTAssertEqual(Switchboard.server(full, profile: .owner, allowSecureSetValue: true).allTools
            .compactMap { ($0 as? UIActionTool)?.environment.allowSecureSetValue }, [true])
        XCTAssertEqual(Switchboard.server(full, profile: .observe).toolNames, ["sys_info", "screenshot"])
    }

    func testValueIsNeverInLogsOrErrorsForAnyTarget() async {
        let secret = "canary-" + UUID().uuidString
        let f = Fixture()
        let id = await f.snapshot()
        func run(_ args: JSONValue, setup: () -> Void = {}) async -> (String, [String]) {
            setup()
            let box = LogBox()
            let ep = MCPHTTPEndpoint(server: f.server, auth: AuthPolicy(allowedLogins: ["a@b"]), log: { box.add($0) })
            let r = await ep.handle(HTTPRequest(method: "POST", path: "/mcp", query: nil,
                                                headers: ["content-type": "application/json", "tailscale-user-login": "a@b"],
                                                body: rpc("tools/call", params: ["name": "ui_action", "arguments": args])),
                                    remoteIsLoopback: true)
            return (String(decoding: r.body, as: UTF8.self), box.all)
        }
        let set: JSONValue = .string(secret)
        let cases: [(String, JSONValue, () -> Void, String)] = [
            ("stale snapshot", ["snapshot_id": "snap-gone", "ref": "e2", "action": "set_value", "value": set], {}, "stale ref"),
            ("unsupported", ["snapshot_id": .string(id), "ref": "e2", "action": "set_value", "value": set],
             { f.textArea.settable = [] }, "does not support"),
            ("ax failure", ["snapshot_id": .string(id), "ref": "e2", "action": "set_value", "value": set],
             { f.textArea.settable = ["AXValue"]; f.textArea.setError = .other(-25200) }, "AX error -25200"),
            ("unconfirmed", ["snapshot_id": .string(id), "ref": "e2", "action": "set_value", "value": set],
             { f.textArea.setError = .timeout }, "did not confirm"),
            ("value on press", ["snapshot_id": .string(id), "ref": "e3", "action": "press", "value": set], {},
             "value is only accepted with set_value"),
            ("bad ref", ["snapshot_id": .string(id), "ref": .string(secret), "action": "set_value", "value": set], {},
             "ref must look like"),
        ]
        for (name, args, setup, want) in cases {
            let (body, logs) = await run(args, setup: setup)
            XCTAssertTrue(body.contains(want), "\(name): \(body)")
            XCTAssertFalse(body.contains(secret), "\(name): \(body)")
            XCTAssertTrue(logs == ["a@b tools/call ui_action"] || logs == ["a@b tools/call ui_action -> rpc error"],
                          "\(name): \(logs)")
        }
        XCTAssertTrue(f.textArea.sets.isEmpty)
    }

    // Activation: never by default.

    func testActivateDefaultsToFalse() async {
        let f = Fixture()
        let id = await f.snapshot()
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r.structured?["activated"], false)
        XCTAssertTrue(f.events.all.isEmpty)
        XCTAssertEqual(f.ok.performed, ["AXPress"])
        XCTAssertTrue(f.window.performed.isEmpty, "the window is not raised either")
        XCTAssertEqual(UIActionTool().inputSchema["properties"]?["activate"]?["default"], false)
    }

    func testActivateTrueRunsFirst() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.window.actions = ["AXRaise"]
        f.ok.onPerform = { f.events.add("press") }
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press", "activate": true])
        XCTAssertEqual(r.structured?["activated"], true)
        XCTAssertEqual(f.events.all, ["activate 20", "press"])
        XCTAssertEqual(f.window.performed, ["AXRaise"], "its window is raised after activation")
    }

    func testActivationFailureDoesNothing() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.activateResult = false
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press", "activate": true])
        XCTAssertEqual(r.text, UIActionTool.Errors.activationFailed("TextEdit"))
        assertNothingDone(f)
    }

    func testUnsupportedIsRefusedBeforeActivation() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.actions = []
        _ = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press", "activate": true])
        XCTAssertTrue(f.events.all.isEmpty)
    }

    // Deadlines.

    func testPreActionReadsAreBounded() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.clock = f.clock
        f.ok.delay = 0.6
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press", "timeout_ms": 1000])
        XCTAssertEqual(r.text, UIActionTool.Errors.appBusy("TextEdit"))
        XCTAssertEqual(f.ok.timeouts.last, 0.5, "a check gets at most 0.5 s")
        XCTAssertEqual(f.clock.t, 0.5, accuracy: 1e-9)
        assertNothingDone(f)

        // Budget spent by the checks: no action starts.
        f.ok.delay = 0.3
        f.clock.t = 0
        let r2 = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press", "timeout_ms": 500])
        XCTAssertEqual(r2.text, UIActionTool.Errors.appBusy("TextEdit"))
        XCTAssertFalse(f.ok.calls.contains { $0.0.hasPrefix("perform") })
        assertNothingDone(f)
    }

    func testActionGetsTheRemainingBudget() async throws {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.clock = f.clock
        f.ok.delay = 0.1
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press", "timeout_ms": 2000])
        XCTAssertFalse(r.isToolError, r.text)
        let perform = try XCTUnwrap(f.ok.calls.first { $0.0 == "perform AXPress" })
        // role + window + action names: 0.3 s spent, 1.7 s left for the action.
        XCTAssertEqual(Double(perform.1 ?? 0), 1.7, accuracy: 1e-4)
    }

    func testUnconfirmedOnTimeout() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.performError = .timeout
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertTrue(r.isToolError)
        XCTAssertEqual(r.text, UIActionTool.Errors.unconfirmed(action: "press", ref: "e3", app: "TextEdit"))
        XCTAssertTrue(r.text.contains("may have happened") && r.text.contains("do not repeat it blindly"))
    }

    func testNoPostReadWithoutBudget() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.onPerform = { f.clock.t += 5 }
        let before = f.ok.requested.count
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r.structured?["success"], true)
        XCTAssertNil(r.structured?["post_state"])
        XCTAssertEqual(Array(f.ok.requested.dropFirst(before)), ["AXRole", "AXSubrole"], "no read after the action")
    }

    func testActionsAreSerialized() async {
        let f = Fixture()
        let id = await f.snapshot()
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let gate = f.gate
        DispatchQueue.global().async {
            _ = gate.run(UIDeadline(timeoutMs: 10_000, now: { ProcessInfo.processInfo.systemUptime })) { _ in
                holding.signal(); release.wait()
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { holding.wait(); c.resume() }
        }
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press", "timeout_ms": 100])
        release.signal()
        XCTAssertEqual(r.text, UIActionTool.Errors.busy)
        assertNothingDone(f)
    }

    // Post-action state.

    func testPostState() async throws {
        let f = Fixture()
        let id = await f.snapshot()
        f.textArea.onPerform = { f.textArea.attrs["AXFocused"] = .bool(true) }
        let r = await f.act(["snapshot_id": .string(id), "ref": "e2", "action": "set_value", "value": "new text"])
        XCTAssertEqual(r.structured?["post_state"], ["focused": true, "value": "new text"])
        XCTAssertTrue(r.text.contains("value set (not shown)"), r.text)
        XCTAssertFalse(r.text.contains("new text"), "the text never shows a value")

        let long = String(repeating: "a", count: 300)
        f.textArea.onPerform = { f.textArea.attrs["AXNumberOfCharacters"] = .number(300) }
        let r2 = await f.act(["snapshot_id": .string(id), "ref": "e2", "action": "set_value", "value": .string(long)])
        let post = try XCTUnwrap(r2.structured?["post_state"])
        XCTAssertEqual(post["value"], .string(String(repeating: "a", count: 200) + "…"))
        XCTAssertEqual(post["value_truncated"], true)
        XCTAssertTrue(f.textArea.requested.contains("AXStringForRange"), "read as a prefix")
    }

    func testElementGoneAfterPress() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.ok.onPerform = { f.ok.attrError = .invalidElement }
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertFalse(r.isToolError, r.text)
        XCTAssertEqual(r.structured?["element_gone"], true)
        XCTAssertNil(r.structured?["post_state"])
        XCTAssertTrue(r.text.contains("The element is gone now"), r.text)
    }

    func testMenuItemPress() async {
        let f = Fixture()
        f.close.actions = ["AXPress"]
        let id = await f.snapshot(menuBar: true)
        let r = await f.act(["snapshot_id": .string(id), "ref": "e9", "action": "press"])
        XCTAssertFalse(r.isToolError, r.text)
        XCTAssertEqual(f.close.performed, ["AXPress"])
        XCTAssertEqual(f.close.elementRequests, ["AXWindow"])
    }

    // Arguments, trust, profile.

    func testInvalidParams() async {
        let f = Fixture()
        let id = await f.snapshot()
        let sid: JSONValue = .string(id)
        let cases: [(JSONValue, String)] = [
            (["ref": "e1", "action": "press"], "snapshot_id is required"),
            (["snapshot_id": "", "ref": "e1", "action": "press"], "snapshot_id is required"),
            (["snapshot_id": .string(String(repeating: "s", count: 65)), "ref": "e1", "action": "press"],
             "snapshot_id must be at most 64 characters"),
            (["snapshot_id": sid, "action": "press"], "ref must look like e1, e2, …"),
            (["snapshot_id": sid, "ref": "e0", "action": "press"], "ref must look like e1, e2, …"),
            (["snapshot_id": sid, "ref": "E1", "action": "press"], "ref must look like e1, e2, …"),
            (["snapshot_id": sid, "ref": "e1", "action": "drag"],
             "action must be one of press, set_value, focus, show_menu, confirm, cancel, increment, decrement"),
            (["snapshot_id": sid, "ref": "e2", "action": "set_value"], "value is required for set_value"),
            (["snapshot_id": sid, "ref": "e3", "action": "press", "value": "x"], "value is only accepted with set_value"),
            (["snapshot_id": sid, "ref": "e2", "action": "set_value", "value": ["a"]], "value must be a string, number or boolean"),
            (["snapshot_id": sid, "ref": "e2", "action": "set_value", "value": .string(String(repeating: "x", count: 65_537))],
             "value is longer than 65536 characters"),
            (["snapshot_id": sid, "ref": "e3", "action": "press", "activate": "yes"], "activate must be a boolean"),
            (["snapshot_id": sid, "ref": "e3", "action": "press", "timeout_ms": 1.5], "timeout_ms must be an integer"),
        ]
        for (args, why) in cases {
            let r = await f.act(args)
            XCTAssertEqual(r.error?.code, JSONRPCError.invalidParams, "\(why)")
            XCTAssertEqual(r.error?.message, "Invalid params: \(why)")
        }
        assertNothingDone(f)
        // Timeouts are clamped, like ui_snapshot's.
        XCTAssertEqual(try UIActionTool.parse(["snapshot_id": sid, "ref": "e3", "action": "press", "timeout_ms": 5]).timeoutMs, 100)
        XCTAssertEqual(try UIActionTool.parse(["snapshot_id": sid, "ref": "e3", "action": "press", "timeout_ms": 99_999]).timeoutMs, 10_000)
        XCTAssertEqual(try UIActionTool.parse(["snapshot_id": sid, "ref": "e3", "action": "press"]).timeoutMs, 2000)
    }

    func testNotTrusted() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.trusted = false
        let r = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertTrue(r.isToolError)
        XCTAssertEqual(r.text, UIActionTool.Errors.notTrusted)
        // A grant revoked mid-call fails the call too.
        f.trusted = true
        f.ok.attrError = .apiDisabled
        let r2 = await f.act(["snapshot_id": .string(id), "ref": "e3", "action": "press"])
        XCTAssertEqual(r2.text, UIActionTool.Errors.notTrusted)
        assertNothingDone(f)
    }

    func testObserveCannotSeeOrCallIt() async throws {
        let full = MCPServer(name: "t", version: "0", tools: ToolCatalog.local(agentVersion: "t"))
        func names(_ s: MCPServer) async throws -> [String] {
            let r = await s.handle(try MCPServer.parse(rpc("tools/list")).get())
            return r?.result?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        }
        let fullNames = try await names(full)
        XCTAssertTrue(fullNames.contains("ui_action"))
        let observe = full.scoped(to: .observe)
        let observeNames = try await names(observe)
        XCTAssertEqual(observeNames, ["sys_info", "screenshot"])
        let r = await observe.handle(try MCPServer.parse(rpc("tools/call", params: ["name": "ui_action", "arguments":
            ["snapshot_id": "snap-1", "ref": "e1", "action": "press"]])).get())
        XCTAssertEqual(r?.error?.code, JSONRPCError.invalidParams)
        XCTAssertEqual(r?.error?.message, "Invalid params: unknown tool: ui_action")
        let ownerNames = try await names(full.scoped(to: .owner))
        XCTAssertTrue(ownerNames.contains("ui_action"))
    }

    /// The tool acts through AX only: it never synthesizes input and never moves the pointer.
    func testNeverPostsEventsOrMovesTheCursor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/InstanceMCPCore")
        for file in ["Tools/UIActionTool.swift", "UISnapshot/UIAction.swift", "UISnapshot/UISnapshotCache.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for banned in ["CGEvent", "CGWarpMouseCursorPosition", "CGDisplayMoveCursorToPoint", "NSEvent", "Input."] {
                XCTAssertFalse(text.contains(banned), "\(file) uses \(banned)")
            }
        }
    }

    func testDescriptorSteersCallers() {
        let t = UIActionTool()
        XCTAssertEqual(t.name, "ui_action")
        for s in ["ui_snapshot", "snapshot_id", "activate: true", "mouse", "Accessibility", "never logs or returns their value", "switchboard"] {
            XCTAssertTrue(t.description.contains(s), s)
        }
        XCTAssertEqual(t.inputSchema["required"], ["snapshot_id", "ref", "action"])
        XCTAssertEqual(t.inputSchema["properties"]?["timeout_ms"]?["maximum"], 10_000)
        XCTAssertEqual(t.inputSchema["properties"]?["action"]?["enum"]?.arrayValue?.count, 8)
    }
}

/// Elements that report no `AXWindow` (#98): controls of a save sheet, as TextEdit's do,
/// and of popovers and drawers. They are found through `AXTopLevelUIElement` or the
/// nearest container up their `AXParent` chain, which must be one they were walked under.
final class UIActionContainerTests: XCTestCase {
    /// The fixture's window (e1, children e2–e5) plus a save sheet (e6) holding a
    /// group (e7) with a Delete button (e8). Like TextEdit's: the sheet names the window
    /// as its `AXWindow`, the button names none.
    private final class Sheet {
        let f = Fixture()
        let sheet = node("AXSheet", "save")
        let group = node("AXGroup")
        let delete = node("AXButton", "Delete")
        init(role: String = "AXSheet") {
            sheet.attrs["AXRole"] = .string(role)
            group.kids = [delete]
            sheet.kids = [group]
            f.window.kids.append(sheet)
            sheet.named = ["AXWindow": f.window, "AXParent": f.window]
            group.named = ["AXParent": sheet]
            delete.named = ["AXParent": group]
            delete.actions = ["AXPress"]
        }
        func press() async -> JSONRPCResponse {
            let id = await f.snapshot()
            return await f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press"])
        }
    }

    func testSheetControlWithNoWindowIsFoundThroughItsParents() async {
        let s = Sheet()
        let r = await s.press()
        XCTAssertFalse(r.isToolError, r.text)
        XCTAssertEqual(s.delete.performed, ["AXPress"])
        XCTAssertEqual(s.delete.elementRequests, ["AXWindow", "AXTopLevelUIElement", "AXParent"])
        XCTAssertEqual(s.group.elementRequests, ["AXParent"], "a group is not a container: keep going")
        XCTAssertTrue(s.sheet.elementRequests.isEmpty, "the nearest container (the sheet) decides")
    }

    func testPopoverAndDrawerControlsToo() async {
        for role in ["AXPopover", "AXDrawer"] {
            let s = Sheet(role: role)
            let r = await s.press()
            XCTAssertFalse(r.isToolError, "\(role): \(r.text)")
            XCTAssertEqual(s.delete.performed, ["AXPress"], role)
        }
    }

    func testWindowControlWithNoWindowButAWindowParent() async {
        let f = Fixture()
        let id = await f.snapshot()
        f.textArea.named = ["AXParent": f.window]
        let r = await f.act(["snapshot_id": .string(id), "ref": "e2", "action": "focus"])
        XCTAssertFalse(r.isToolError, r.text)
        XCTAssertEqual(f.textArea.sets.map(\.0), ["AXFocused"])
    }

    func testRecordedTopLevelElementIsEnough() async {
        let s = Sheet()
        s.delete.named = ["AXTopLevelUIElement": s.f.window]
        let r = await s.press()
        XCTAssertFalse(r.isToolError, r.text)
        XCTAssertEqual(s.delete.elementRequests, ["AXWindow", "AXTopLevelUIElement"])
    }

    func testChainToAnUnrecordedContainerIsStale() async {
        // Moved into another window's sheet: the nearest container was never walked.
        let s = Sheet()
        let id = await s.f.snapshot()
        let otherWindow = node("AXWindow", "Other"), otherSheet = node("AXSheet")
        otherSheet.named = ["AXParent": otherWindow]
        s.delete.named = ["AXParent": otherSheet]
        let r = await s.f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.stale("e8", "has left its window"))

        // The nearest container decides, even with a recorded window above it.
        otherSheet.named = ["AXParent": s.f.window]
        let r2 = await s.f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press"])
        XCTAssertEqual(r2.text, UIActionTool.Errors.stale("e8", "has left its window"))

        // A window it was not walked under, by AXWindow and by AXTopLevelUIElement.
        s.delete.named = ["AXWindow": otherWindow, "AXTopLevelUIElement": otherWindow, "AXParent": otherWindow]
        let r3 = await s.f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press"])
        XCTAssertEqual(r3.text, UIActionTool.Errors.stale("e8", "has left its window"))

        // No container at all, or a vanished ancestor.
        s.delete.named = ["AXParent": s.group]
        s.group.named = [:]
        let r4 = await s.f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press"])
        XCTAssertEqual(r4.text, UIActionTool.Errors.stale("e8", "has left its window"))
        s.group.attrError = .invalidElement
        s.group.named = ["AXParent": s.sheet]
        let r5 = await s.f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press"])
        XCTAssertEqual(r5.text, UIActionTool.Errors.stale("e8", "has left its window"))
        XCTAssertTrue(s.delete.performed.isEmpty)
    }

    func testSheetControlFromAnotherPidOrRoleIsStale() async {
        let s = Sheet()
        let id = await s.f.snapshot()
        s.delete.pidValue = 4242
        let r = await s.f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.stale("e8", "no longer belongs to TextEdit"))
        s.delete.pidValue = 20
        s.delete.attrs["AXRole"] = .string("AXCheckBox")
        let r2 = await s.f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press"])
        XCTAssertEqual(r2.text, UIActionTool.Errors.stale("e8", "is now AXCheckBox, not the AXButton it was"))
        XCTAssertTrue(s.delete.performed.isEmpty)
        XCTAssertTrue(s.delete.elementRequests.isEmpty, "rejected before any container lookup")
    }

    func testParentChainIsBounded() async {
        // A cycle ends the walk.
        let s = Sheet()
        let id = await s.f.snapshot()
        let a = node("AXGroup"), b = node("AXGroup")
        a.named = ["AXParent": b]
        b.named = ["AXParent": a]
        s.delete.named = ["AXParent": a]
        let r = await s.f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press"])
        XCTAssertEqual(r.text, UIActionTool.Errors.stale("e8", "has left its window"))

        // So does the depth cap, before a recorded container far above.
        var top: FakeUIElement = s.sheet
        var chain: [FakeUIElement] = []
        for _ in 0..<UISnapshotLimits.maxDepthCap {
            let g = node("AXGroup")
            g.named = ["AXParent": top]
            chain.append(g)
            top = g
        }
        s.delete.named = ["AXParent": top]
        let r2 = await s.f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press", "timeout_ms": 10_000])
        XCTAssertEqual(r2.text, UIActionTool.Errors.stale("e8", "has left its window"))
        XCTAssertTrue(chain[0].elementRequests.isEmpty, "the last group before the sheet is never reached")
        XCTAssertTrue(s.delete.performed.isEmpty)
    }

    func testParentReadsAreArmed() async {
        let s = Sheet()
        let id = await s.f.snapshot()
        s.group.clock = s.f.clock
        s.group.delay = 0.6
        let r = await s.f.act(["snapshot_id": .string(id), "ref": "e8", "action": "press", "timeout_ms": 1000])
        XCTAssertEqual(r.text, UIActionTool.Errors.appBusy("TextEdit"))
        XCTAssertEqual(s.group.timeouts.last, 0.5, "a check gets at most 0.5 s")
        XCTAssertTrue(s.delete.performed.isEmpty)
    }
}

/// `AXLive.activate` without a live app: the AX write, the AppKit fallback and the
/// `AXFrontmost` read-back, each armed by the call's deadline.
final class UIActivateTests: XCTestCase {
    private func run(_ app: FakeUIElement, clock: FakeClock, timeoutMs: Int = 2000,
                     appKitActive: @escaping () -> Bool = { false },
                     fallback: @escaping () -> Bool = { false }, fallbacks: inout Int) -> Bool {
        var n = 0
        let ok = AXLive.activate(appElement: app, appKitActive: appKitActive,
                                 fallbackActivate: { n += 1; return fallback() },
                                 deadline: UIDeadline(timeoutMs: timeoutMs, now: { clock.t }),
                                 sleep: { clock.t += $0 })
        fallbacks = n
        return ok
    }

    func testAlreadyFrontmostPerAXDoesNothing() {
        let app = FakeUIElement(["AXFrontmost": .bool(true)]), clock = FakeClock()
        var fallbacks = 0
        XCTAssertTrue(run(app, clock: clock, fallbacks: &fallbacks))
        XCTAssertTrue(app.sets.isEmpty)
        XCTAssertEqual(fallbacks, 0)
        XCTAssertEqual(app.requested, ["AXFrontmost"])
        XCTAssertEqual(app.timeouts, [0.5], "the read-back is armed")
    }

    func testAXWriteIsReadBackWithoutAppKit() {
        // AppKit never notices (a busy main run loop); the app's own AXFrontmost does.
        let app = FakeUIElement(["AXFrontmost": .bool(false)]), clock = FakeClock()
        var fallbacks = 0
        XCTAssertTrue(run(app, clock: clock, fallbacks: &fallbacks))
        XCTAssertEqual(app.sets.map(\.0), ["AXFrontmost"])
        XCTAssertEqual(app.sets.first?.1, .bool(true))
        XCTAssertEqual(fallbacks, 0)
        XCTAssertFalse(app.timeouts.isEmpty)
        XCTAssertTrue(app.timeouts.allSatisfy { $0 <= 0.5 })
    }

    func testFailedAXWriteFallsBackToAppKit() {
        let app = FakeUIElement(["AXFrontmost": .bool(false)]), clock = FakeClock()
        app.setError = .other(-25205)
        var activated = false, fallbacks = 0
        XCTAssertTrue(run(app, clock: clock, appKitActive: { activated }, fallback: { activated = true; return true },
                          fallbacks: &fallbacks))
        XCTAssertEqual(fallbacks, 1)
    }

    func testDeclinedFallbackFailsClosed() {
        let app = FakeUIElement(["AXFrontmost": .bool(false)]), clock = FakeClock()
        app.setError = .other(-25205)
        var fallbacks = 0
        XCTAssertFalse(run(app, clock: clock, fallbacks: &fallbacks))
        XCTAssertEqual(fallbacks, 1)
        XCTAssertEqual(clock.t, 0, "no wait after a declined activation")
    }

    func testFailedReadBackCountsAsNotActiveAndThePollIsBounded() {
        // The write "succeeds" but the app never reports frontmost and reads fail.
        let app = FakeUIElement(), clock = FakeClock()
        app.attrError = .other(-25205)
        var fallbacks = 0
        XCTAssertFalse(run(app, clock: clock, fallbacks: &fallbacks))
        XCTAssertGreaterThanOrEqual(clock.t, 0.5)
        XCTAssertLessThan(clock.t, 0.6, "the poll stops after 0.5 s")
    }

    func testPollNeverRunsPastTheDeadline() {
        let app = FakeUIElement(["AXFrontmost": .bool(false)]), clock = FakeClock()
        app.onPerform = { app.attrs["AXFrontmost"] = .bool(false) }   // the app refuses
        var fallbacks = 0
        XCTAssertFalse(run(app, clock: clock, timeoutMs: 100, fallbacks: &fallbacks))
        XCTAssertLessThan(clock.t, 0.15)
    }

    func testSpentBudgetMakesNoAXCall() {
        let app = FakeUIElement(["AXFrontmost": .bool(false)]), clock = FakeClock()
        var fallbacks = 0
        XCTAssertFalse(run(app, clock: clock, timeoutMs: 0, fallbacks: &fallbacks))
        XCTAssertTrue(app.requested.isEmpty)
        XCTAssertTrue(app.sets.isEmpty)
        XCTAssertEqual(fallbacks, 0)
    }
}
