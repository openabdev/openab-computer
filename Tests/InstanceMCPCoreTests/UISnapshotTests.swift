import CoreGraphics
import Foundation
import XCTest
@testable import InstanceMCPCore

// MARK: - fakes

/// An accessibility element with scripted attributes, children and failures. Records
/// every attribute name it is asked for, so tests can prove a secure value is never read.
final class FakeUIElement: UIElement, @unchecked Sendable {
    var attrs: [String: UIAttrValue]
    var kids: [FakeUIElement]
    var named: [String: FakeUIElement] = [:]
    var lists: [String: [FakeUIElement]] = [:]
    var attrError: UIAXError?
    var valueError: UIAXError?
    var childError: UIAXError?
    var elementError: UIAXError?
    var requested: [String] = []
    var timeouts: [Float] = []
    var onAttributes: (() -> Void)?

    init(_ attrs: [String: UIAttrValue] = [:], _ kids: [FakeUIElement] = []) {
        self.attrs = attrs; self.kids = kids
    }

    var identity: AnyHashable { AnyHashable(ObjectIdentifier(self)) }

    func attributes(_ names: [String]) -> Result<[String: UIAttrValue], UIAXError> {
        requested += names
        onAttributes?()
        if names == ["AXValue"], let valueError { return .failure(valueError) }
        if names != ["AXValue"], let attrError { return .failure(attrError) }
        var out: [String: UIAttrValue] = [:]
        for n in names { if let v = attrs[n] { out[n] = v } }
        return .success(out)
    }

    func element(_ name: String) -> Result<(any UIElement)?, UIAXError> {
        if let elementError { return .failure(elementError) }
        return .success(named[name])
    }

    func elements(_ name: String) -> Result<[any UIElement], UIAXError> {
        if let elementError { return .failure(elementError) }
        return .success(lists[name] ?? [])
    }

    func children(max: Int) -> Result<(elements: [any UIElement], total: Int), UIAXError> {
        if let childError { return .failure(childError) }
        return .success((Array(kids.prefix(Swift.max(max, 0))), kids.count))
    }

    func setMessagingTimeout(_ seconds: Float) { timeouts.append(seconds) }
}

final class FakeClock: @unchecked Sendable {
    var t: TimeInterval = 0
}

private func el(_ role: String, _ title: String? = nil, frame: CGRect? = nil,
                extra: [String: UIAttrValue] = [:], _ kids: FakeUIElement...) -> FakeUIElement {
    var a: [String: UIAttrValue] = ["AXRole": .string(role)]
    if let title { a["AXTitle"] = .string(title) }
    if let frame { a["AXPosition"] = .point(frame.origin); a["AXSize"] = .size(frame.size) }
    a.merge(extra) { _, b in b }
    return FakeUIElement(a, kids)
}

private let mainDisplay = UIDisplayMap(displays: [(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))], mainID: 1)

private func walk(_ windows: [FakeUIElement], limits: UISnapshotLimits = .init(),
                  displays: UIDisplayMap = mainDisplay, clock: FakeClock = FakeClock(),
                  app: UIRunningApp = UIRunningApp(pid: 123, bundleID: "com.apple.TextEdit", name: "TextEdit")) throws -> UISnapshotResult {
    try UITreeWalker(limits: limits, now: { clock.t }, newSnapshotID: { "snap-0000beef" })
        .walk(app: app, windows: windows, displays: displays)
}

private func titles(_ nodes: [UINode]) -> [String] {
    nodes.flatMap { [$0.title ?? "?"] + titles($0.children) }
}

private func refs(_ nodes: [UINode]) -> [String] {
    nodes.flatMap { [$0.ref] + refs($0.children) }
}

private func encode(_ v: JSONValue) -> String {
    String(decoding: try! JSONCoding.encoder.encode(v), as: UTF8.self)
}

// MARK: - walker

final class UISnapshotWalkerTests: XCTestCase {
    func testRefsArePreOrderAcrossWindows() throws {
        let b = el("AXButton", "b")
        let w1 = el("AXWindow", "w1", el("AXGroup", "a", b), el("AXButton", "c"))
        let w2 = el("AXWindow", "w2", el("AXButton", "d"))
        let r = try walk([w1, w2])
        XCTAssertEqual(titles(r.snapshot.windows), ["w1", "a", "b", "c", "w2", "d"])
        XCTAssertEqual(refs(r.snapshot.windows), ["e1", "e2", "e3", "e4", "e5", "e6"])
        XCTAssertEqual(r.snapshot.nodeCount, 6)
        XCTAssertEqual(r.elements.count, 6, "one element per ref, for phase 2")
        XCTAssertTrue(r.elements["e3"] === b)
        XCTAssertFalse(r.snapshot.truncated)
        XCTAssertFalse(r.snapshot.timedOut)
    }

    func testNodeLimitCutsTheDeepestFirst() throws {
        let a = el("AXGroup", "a", el("AXButton", "a1"), el("AXButton", "a2"))
        let b = el("AXGroup", "b", el("AXButton", "b1"))
        let r = try walk([el("AXWindow", "w", a, b)], limits: .init(maxNodes: 4))
        let s = r.snapshot
        XCTAssertEqual(titles(s.windows), ["w", "a", "a1", "b"])
        XCTAssertEqual(s.nodeCount, 4)
        XCTAssertTrue(s.truncated)
        XCTAssertTrue(s.nodeLimitHit)
        XCTAssertFalse(s.depthLimitHit)
        XCTAssertEqual(s.omittedCount, 2)
        XCTAssertEqual(s.windows[0].children[0].childrenOmitted, 1)
        XCTAssertEqual(s.windows[0].children[1].childrenOmitted, 1)
        XCTAssertEqual(s.json["truncated_by"], ["max_nodes"])
    }

    func testWindowsBeyondTheNodeLimitAreCounted() throws {
        let r = try walk([el("AXWindow", "w1"), el("AXWindow", "w2"), el("AXWindow", "w3")], limits: .init(maxNodes: 2))
        XCTAssertEqual(titles(r.snapshot.windows), ["w1", "w2"])
        XCTAssertTrue(r.snapshot.nodeLimitHit)
        XCTAssertEqual(r.snapshot.omittedCount, 1)
    }

    func testDepthLimit() throws {
        let r = try walk([el("AXWindow", "w", el("AXGroup", "a", el("AXGroup", "b", el("AXButton", "c"))))],
                         limits: .init(maxDepth: 1))
        let s = r.snapshot
        XCTAssertEqual(titles(s.windows), ["w", "a"])
        XCTAssertEqual(s.windows[0].children[0].childrenOmitted, 1)
        XCTAssertTrue(s.depthLimitHit)
        XCTAssertFalse(s.nodeLimitHit)
        XCTAssertEqual(s.json["truncated_by"], ["max_depth"])
    }

    func testLimitsAreClamped() {
        let d = UISnapshotLimits()
        XCTAssertEqual([d.maxDepth, d.maxNodes, d.timeoutMs], [20, 300, 3000])
        let lo = UISnapshotLimits(maxDepth: 0, maxNodes: -5, timeoutMs: 0)
        XCTAssertEqual([lo.maxDepth, lo.maxNodes, lo.timeoutMs], [1, 1, 100])
        let hi = UISnapshotLimits(maxDepth: 999, maxNodes: 99_999, timeoutMs: 99_999)
        XCTAssertEqual([hi.maxDepth, hi.maxNodes, hi.timeoutMs], [50, 2000, 10_000])
        XCTAssertEqual(hi.json, ["max_depth": 50, "max_nodes": 2000, "timeout_ms": 10_000])
    }

    func testTimeBudgetStopsTheWalkWithAPartialTree() throws {
        let clock = FakeClock()
        let kids = (0..<4).map { el("AXButton", "k\($0)") }
        let w = el("AXWindow", "w")
        w.kids = kids
        for e in [w] + kids { e.onAttributes = { clock.t += 0.04 } }
        let r = try walk([w], limits: .init(timeoutMs: 100), clock: clock)
        let s = r.snapshot
        XCTAssertTrue(s.timedOut)
        XCTAssertFalse(s.truncated)
        XCTAssertEqual(s.nodeCount, 2, "w (0.08 s) and k0 (to 0.16 s), then the 0.1 s budget is gone")
        XCTAssertEqual(s.windows[0].children.count + s.windows[0].childrenOmitted, 4)
        XCTAssertEqual(s.omittedCount, 3)
        // Messaging timeout: min(0.5, remaining), floored at 0.05.
        XCTAssertEqual(Double(w.timeouts.first ?? 0), 0.1, accuracy: 1e-6)
        XCTAssertEqual(Double(kids[0].timeouts.first ?? 0), 0.05, accuracy: 1e-6)
        XCTAssertTrue(kids[1].timeouts.isEmpty, "never touched once the budget ran out")
        XCTAssertTrue(s.renderText().hasSuffix("timed_out: walk stopped after 160 ms; the app may be busy — raise timeout_ms up to 10000 or retry"))
    }

    func testMessagingTimeoutIsSetOnEveryElement() throws {
        let kids = [el("AXButton", "a"), el("AXButton", "b")]
        let w = el("AXWindow", "w")
        w.kids = kids
        _ = try walk([w])
        for e in [w] + kids {
            XCTAssertEqual(e.timeouts, [0.5])
        }
    }

    func testHungNodeIsKeptButNotDescended() throws {
        let hung = el("AXGroup", "hung", el("AXButton", "never"))
        hung.attrError = .timeout
        let r = try walk([el("AXWindow", "w", hung, el("AXButton", "ok"))])
        let s = r.snapshot
        XCTAssertTrue(s.timedOut)
        XCTAssertEqual(s.nodeCount, 3)
        XCTAssertNil(s.windows[0].children[0].role)
        XCTAssertTrue(s.windows[0].children[0].children.isEmpty)
        XCTAssertEqual(s.windows[0].children[1].title, "ok")
    }

    func testVanishedNodeIsDropped() throws {
        let gone = el("AXButton", "gone")
        gone.attrError = .invalidElement
        let r = try walk([el("AXWindow", "w", gone, el("AXButton", "ok"))])
        XCTAssertEqual(titles(r.snapshot.windows), ["w", "ok"])
        XCTAssertEqual(refs(r.snapshot.windows), ["e1", "e2"])
    }

    func testAPIDisabledFailsTheWholeCallWithTheTCCText() {
        let a = el("AXGroup", "a")
        a.childError = .apiDisabled
        XCTAssertThrowsError(try walk([el("AXWindow", "w", a)])) { e in
            XCTAssertEqual((e as? ToolError)?.description, UISnapshotTool.Errors.notTrusted)
        }
        XCTAssertTrue(UISnapshotTool.Errors.notTrusted.contains("dev.openab.instance-mcp"))
        XCTAssertTrue(UISnapshotTool.Errors.notTrusted.contains("Privacy & Security → Accessibility"))
    }

    func testCycleIsWalkedOnce() throws {
        let a = el("AXGroup", "a")
        let w = el("AXWindow", "w", a)
        a.kids = [w, a, el("AXButton", "b")]
        let r = try walk([w, w])
        XCTAssertEqual(titles(r.snapshot.windows), ["w", "a", "b"])
        a.kids = []   // break the retain cycle
    }

    func testSecureFieldsAreMaskedAndTheirValueIsNeverRead() throws {
        let secret: [String: UIAttrValue] = ["AXValue": .string("hunter2")]
        let byRole = el("AXSecureTextField", extra: secret)
        let bySubrole = el("AXTextField", extra: secret.merging(["AXSubrole": .string("AXSecureTextField")]) { a, _ in a })
        let byName = el("AXTextField", extra: secret.merging(["AXSubrole": .string("AXMySecureInput")]) { a, _ in a })
        let plain = el("AXTextField", extra: ["AXValue": .string("visible")])
        let r = try walk([el("AXWindow", "w", byRole, bySubrole, byName, plain)])
        for e in [byRole, bySubrole, byName] {
            XCTAssertFalse(e.requested.contains("AXValue"), "AXValue requested from a secure node")
        }
        XCTAssertTrue(plain.requested.contains("AXValue"))
        let kids = r.snapshot.windows[0].children
        XCTAssertEqual(kids.map(\.masked), [true, true, true, false])
        XCTAssertEqual(kids[3].value, .string("visible"))
        let json = encode(r.snapshot.json)
        let text = r.snapshot.renderText()
        XCTAssertFalse(json.contains("hunter2"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertEqual(text.components(separatedBy: "‹masked›").count - 1, 3)
        XCTAssertEqual(kids[0].json["masked"], true)
        XCTAssertNil(kids[0].json["value"])
    }

    func testStringsAreCapped() throws {
        let long = String(repeating: "x", count: 300)
        let r = try walk([el("AXWindow", long, extra: ["AXValue": .string(long), "AXHelp": .string(long)])])
        let n = r.snapshot.windows[0]
        XCTAssertEqual(n.title?.count, 201)
        XCTAssertEqual(n.title?.hasSuffix("…"), true)
        XCTAssertEqual(n.help?.count, 201)
        XCTAssertTrue(n.valueTruncated)
        XCTAssertEqual(n.json["value_truncated"], true)
        XCTAssertNil(n.json["title_truncated"])
        let line = r.snapshot.renderText().split(separator: "\n")[1]
        XCTAssertLessThan(line.count, 200, "the text rendering caps at 80 characters per string")
    }

    func testValueTypesAndFlags() throws {
        let num = el("AXSlider", extra: ["AXValue": .number(3.5), "AXEnabled": .bool(false), "AXFocused": .bool(true)])
        let bool = el("AXCheckBox", extra: ["AXValue": .bool(true), "AXSelected": .bool(true), "AXEnabled": .bool(true)])
        let point = el("AXGroup", extra: ["AXValue": .point(CGPoint(x: 1, y: 2)), "AXFocused": .bool(false)])
        let r = try walk([el("AXWindow", "w", num, bool, point)])
        let k = r.snapshot.windows[0].children.map(\.json)
        XCTAssertEqual(k[0]["value"], 3.5)
        XCTAssertEqual(k[0]["enabled"], false)
        XCTAssertEqual(k[0]["focused"], true)
        XCTAssertEqual(k[1]["value"], true)
        XCTAssertEqual(k[1]["selected"], true)
        XCTAssertNil(k[1]["enabled"], "enabled is emitted only when false")
        XCTAssertNil(k[2]["value"], "a point is never a value")
        XCTAssertNil(k[2]["focused"])
        XCTAssertNil(k[2]["selected"])
    }

    func testJSONGolden() throws {
        let close = el("AXButton", frame: CGRect(x: 108, y: 86, width: 14, height: 16),
                       extra: ["AXSubrole": .string("AXCloseButton"), "AXEnabled": .bool(false)])
        let field = el("AXTextField", frame: CGRect(x: 120, y: 120, width: 200, height: 22),
                       extra: ["AXValue": .string("hi"), "AXFocused": .bool(true)])
        let w = el("AXWindow", "Untitled", frame: CGRect(x: 100, y: 80, width: 800, height: 600),
                   extra: ["AXSubrole": .string("AXStandardWindow")], close, field)
        let s = try walk([w]).snapshot
        XCTAssertEqual(encode(s.windows[0].json), #"{"children":[{"display":0,"enabled":false,"frame":{"height":16,"width":14,"x":108,"y":86},"ref":"e2","role":"AXButton","subrole":"AXCloseButton"},{"display":0,"focused":true,"frame":{"height":22,"width":200,"x":120,"y":120},"ref":"e3","role":"AXTextField","value":"hi"}],"display":0,"frame":{"height":600,"width":800,"x":100,"y":80},"ref":"e1","role":"AXWindow","subrole":"AXStandardWindow","title":"Untitled"}"#)
        var top = s.json.objectValue ?? [:]
        top["windows"] = nil
        XCTAssertEqual(encode(.object(top)), #"{"app":{"bundle_id":"com.apple.TextEdit","name":"TextEdit","pid":123},"coordinates":"display points relative to the display's top-left, same space as screenshot and mouse","displays":[{"height":982,"index":0,"width":1512,"x":0,"y":0}],"elapsed_ms":0,"limits":{"max_depth":20,"max_nodes":300,"timeout_ms":3000},"node_count":3,"snapshot_id":"snap-0000beef","timed_out":false,"truncated":false}"#)
    }

    func testTextGolden() throws {
        let displays = UIDisplayMap(displays: [(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
                                               (id: 2, bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080))], mainID: 1)
        let group = el("AXGroup", frame: CGRect(x: 1600, y: 10, width: 100, height: 50), el("AXButton", "deep"))
        let off = el("AXButton", frame: CGRect(x: -5000, y: -5000, width: 10, height: 10),
                     extra: ["AXDescription": .string("Close"), "AXEnabled": .bool(false)])
        let secure = el("AXTextField", frame: CGRect(x: 120, y: 120, width: 200, height: 22),
                        extra: ["AXSubrole": .string("AXSecureTextField"), "AXValue": .string("pw")])
        let area = el("AXTextArea", frame: CGRect(x: 100, y: 108, width: 785, height: 572),
                      extra: ["AXValue": .string("line1\nline2"), "AXFocused": .bool(true)])
        let w = el("AXWindow", "Doc", frame: CGRect(x: 100, y: 80, width: 800, height: 600), group, off, secure, area)
        let s = try walk([w], limits: .init(maxDepth: 1), displays: displays).snapshot
        XCTAssertEqual(s.renderText(), """
            ui_snapshot snap-0000beef · TextEdit (com.apple.TextEdit, pid 123) · 5 nodes · 0 ms
            [e1] AXWindow "Doc" (100,80 800×600)
              [e2] AXGroup (d1:88,10 100×50) +1 more
              [e3] AXButton desc="Close" (-5000,-5000 10×10) offscreen disabled
              [e4] AXTextField/AXSecureTextField = ‹masked› (120,120 200×22)
              [e5] AXTextArea = "line1⏎line2" (100,108 785×572) focused
            truncated: depth limit 1 reached (max_depth up to 50); 1 elements not walked
            """)
        XCTAssertEqual(s.windows[0].children[0].json["display"], 1)
        XCTAssertEqual(s.windows[0].children[1].json["offscreen"], true)
        XCTAssertNil(s.windows[0].children[1].json["display"])
    }

    func testFootersForNodeLimitAndTimeout() {
        var s = UISnapshot(snapshotID: "snap-1", app: UIRunningApp(pid: 7, bundleID: nil, name: nil),
                           windows: [], nodeCount: 0, elapsedMs: 41, limits: .init(maxNodes: 300), displays: mainDisplay)
        s.nodeLimitHit = true
        s.omittedCount = 12
        s.timedOut = true
        XCTAssertEqual(s.renderText(), """
            ui_snapshot snap-1 · pid 7 · 0 nodes · 41 ms
            (no elements)
            truncated: node limit 300 reached (max_nodes up to 2000); 12 elements not walked
            timed_out: walk stopped after 41 ms; the app may be busy — raise timeout_ms up to 10000 or retry
            """)
        XCTAssertEqual(s.json["omitted_count"], 12)
    }
}

// MARK: - displays and targets

final class UISnapshotTargetTests: XCTestCase {
    func testDisplayOrderMatchesScreenshot() {
        let m = UIDisplayMap(displays: [(id: 5, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
                                        (id: 9, bounds: CGRect(x: 200, y: 0, width: 100, height: 100)),
                                        (id: 2, bounds: CGRect(x: 100, y: 0, width: 100, height: 100))], mainID: 5)
        XCTAssertEqual(m.ordered.map(\.id), [5, 2, 9])
        // Center inside display 1 (id 2).
        XCTAssertEqual(m.locate(CGRect(x: 110, y: 10, width: 20, height: 20))?.display, 1)
        XCTAssertEqual(m.locate(CGRect(x: 110, y: 10, width: 20, height: 20))?.frame, CGRect(x: 10, y: 10, width: 20, height: 20))
        // Center below every display: the largest overlap wins.
        let hit = m.locate(CGRect(x: 70, y: 90, width: 100, height: 30))
        XCTAssertEqual(hit?.display, 1)
        XCTAssertEqual(hit?.frame, CGRect(x: -30, y: 90, width: 100, height: 30))
        XCTAssertNil(m.locate(CGRect(x: -500, y: -500, width: 10, height: 10)))
    }

    private let running = [
        UIRunningApp(pid: 10, bundleID: "com.apple.finder", name: "Finder"),
        UIRunningApp(pid: 20, bundleID: "com.apple.TextEdit", name: "TextEdit"),
        UIRunningApp(pid: 30, bundleID: "a.helper", name: "Helper"),
        UIRunningApp(pid: 31, bundleID: "b.helper", name: "Helper"),
        UIRunningApp(pid: 40, bundleID: "com.apple.AirPlayUIAgent", name: "AirPlayUIAgent", regular: false),
        UIRunningApp(pid: 99, bundleID: "dev.openab.instance-mcp", name: "oab-instance-mcp", regular: false),
    ]

    private func resolve(app: String? = nil, pid: Int32? = nil, front: Int32? = nil,
                         running: [UIRunningApp]? = nil) -> Result<UIRunningApp, ToolError> {
        UITarget.resolveApp(app: app, pid: pid, frontmostPid: front, running: running ?? self.running, selfPid: 99)
    }

    private func failure(_ r: Result<UIRunningApp, ToolError>) -> String? {
        if case .failure(let e) = r { return e.description }
        return nil
    }

    func testResolveApp() throws {
        XCTAssertEqual(try resolve(pid: 20).get().name, "TextEdit")
        XCTAssertEqual(failure(resolve(pid: 77)), "no running app with pid 77")
        XCTAssertEqual(try resolve(app: "COM.APPLE.TEXTEDIT").get().pid, 20)
        XCTAssertEqual(try resolve(app: "finder").get().pid, 10)
        XCTAssertEqual(failure(resolve(app: "Helper")),
                       "app 'Helper' matches 2 running apps (pids 30, 31); pass pid instead")
        XCTAssertEqual(try resolve(app: "a.helper").get().pid, 30, "bundle id beats an ambiguous name")
        XCTAssertEqual(failure(resolve(app: "Nope")),
                       "app not found: no running app has bundle id or name 'Nope'. Running apps: Finder, Helper, TextEdit")
        XCTAssertEqual(failure(resolve(pid: 99)), UISnapshotTool.Errors.selfApp)
        XCTAssertEqual(failure(resolve(app: "dev.openab.instance-mcp")), UISnapshotTool.Errors.selfApp)
        XCTAssertEqual(failure(resolve()), UISnapshotTool.Errors.noFrontmost)
        XCTAssertEqual(try resolve(front: 10).get().name, "Finder")
        XCTAssertEqual(try resolve(front: 55).get(), UIRunningApp(pid: 55, bundleID: nil, name: nil))
        XCTAssertEqual(failure(resolve(front: 99)), UISnapshotTool.Errors.selfApp)
    }

    func testNotFoundListsAtMostTwentyApps() {
        let many = (0..<30).map { UIRunningApp(pid: Int32(100 + $0), bundleID: nil, name: String(format: "App%02d", $0)) }
        let text = failure(resolve(app: "x", running: many)) ?? ""
        let list = text.components(separatedBy: "Running apps: ").last ?? ""
        XCTAssertEqual(list.components(separatedBy: ", ").count, 20)
    }

    private func appElement(focused: FakeUIElement? = nil, main: FakeUIElement? = nil,
                            windows: [FakeUIElement] = []) -> FakeUIElement {
        let app = FakeUIElement(["AXRole": .string("AXApplication")])
        if let focused { app.named["AXFocusedWindow"] = focused }
        if let main { app.named["AXMainWindow"] = main }
        app.lists["AXWindows"] = windows
        return app
    }

    private func pick(_ app: FakeUIElement, _ sel: UITarget.WindowSelector? = nil, all: Bool = false) throws -> [FakeUIElement] {
        try UITarget.windows(of: app, appName: "TextEdit", selector: sel, all: all).map { $0 as! FakeUIElement }
    }

    private func same(_ a: [FakeUIElement], _ b: [FakeUIElement]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
    }

    func testWindowSelection() throws {
        let notes = el("AXWindow", "Notes"), draft = el("AXWindow", "notes draft")
        let ws = [notes, draft]
        XCTAssertTrue(same(try pick(appElement(focused: draft, main: notes, windows: ws)), [draft]))
        XCTAssertTrue(same(try pick(appElement(main: notes, windows: ws)), [notes]))
        XCTAssertTrue(same(try pick(appElement(windows: [draft, notes])), [draft]))
        let app = appElement(focused: draft, windows: ws)
        XCTAssertTrue(same(try pick(app, .index(1)), [draft]))
        XCTAssertTrue(same(try pick(app, .title("Notes")), [notes]), "exact title first")
        XCTAssertTrue(same(try pick(app, .title("DRAFT")), [draft]), "then case-insensitive substring")
        XCTAssertTrue(same(try pick(app, all: true), ws))
        XCTAssertThrowsError(try pick(app, .title("x"))) { e in
            XCTAssertEqual((e as? ToolError)?.description,
                           #"window 'x' not found in TextEdit; windows: [0] "Notes", [1] "notes draft""#)
        }
        XCTAssertThrowsError(try pick(app, .index(5))) { e in
            XCTAssertTrue((e as? ToolError)?.description.hasPrefix("window '5' not found in TextEdit") == true)
        }
        for sel: UITarget.WindowSelector? in [nil, .index(0)] {
            XCTAssertThrowsError(try pick(appElement(), sel)) { e in
                XCTAssertEqual((e as? ToolError)?.description, "TextEdit has no open windows")
            }
        }
        XCTAssertThrowsError(try pick(appElement(), all: true))
    }

    func testWindowLookupErrors() {
        let busy = appElement(windows: [el("AXWindow", "w")])
        busy.elementError = .timeout
        XCTAssertThrowsError(try pick(busy)) { e in
            XCTAssertEqual((e as? ToolError)?.description, UISnapshotTool.Errors.appBusy("TextEdit"))
        }
        busy.elementError = .apiDisabled
        XCTAssertThrowsError(try pick(busy)) { e in
            XCTAssertEqual((e as? ToolError)?.description, UISnapshotTool.Errors.notTrusted)
        }
    }
}

// MARK: - the tool

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class UISnapshotToolTests: XCTestCase {
    static func environment(trusted: Bool = true, window: FakeUIElement? = nil) -> UISnapshotTool.Environment {
        let w = window ?? el("AXWindow", "Untitled", frame: CGRect(x: 100, y: 80, width: 800, height: 600),
                             el("AXButton", "OK", frame: CGRect(x: 120, y: 600, width: 60, height: 24)))
        let app = FakeUIElement(["AXRole": .string("AXApplication")])
        app.named["AXFocusedWindow"] = w
        app.lists["AXWindows"] = [w]
        let running = [UIRunningApp(pid: 20, bundleID: "com.apple.TextEdit", name: "TextEdit")]
        return UISnapshotTool.Environment(
            isTrusted: { trusted }, selfPid: 99, runningApps: { running }, frontmostPid: { 20 },
            appElement: { _ in app }, displays: { mainDisplay }, now: { 0 }, newSnapshotID: { "snap-0000beef" })
    }

    private func call(_ args: JSONValue, env: UISnapshotTool.Environment = environment()) async -> JSONRPCResponse {
        let server = MCPServer(name: "t", version: "0", tools: [UISnapshotTool(environment: env)])
        let req = try! MCPServer.parse(rpc("tools/call", params: ["name": "ui_snapshot", "arguments": args])).get()
        return await server.handle(req)!
    }

    func testSuccessReturnsTextAndStructuredContent() async {
        let r = await call([:])
        XCTAssertNil(r.error)
        XCTAssertNil(r.result?["isError"])
        XCTAssertEqual(r.result?["structuredContent"]?["snapshot_id"], "snap-0000beef")
        XCTAssertEqual(r.result?["structuredContent"]?["node_count"], 2)
        let text = r.result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.hasPrefix("ui_snapshot snap-0000beef · TextEdit (com.apple.TextEdit, pid 20) · 2 nodes"), text)
        XCTAssertTrue(text.contains(#"[e2] AXButton "OK" (120,600 60×24)"#), text)
    }

    func testNotTrustedIsAToolErrorNamingTheSetting() async {
        let r = await call([:], env: Self.environment(trusted: false))
        XCTAssertNil(r.error)
        XCTAssertEqual(r.result?["isError"], true)
        XCTAssertEqual(r.result?["content"]?.arrayValue?.first?["text"]?.stringValue, UISnapshotTool.Errors.notTrusted)
    }

    func testAppNotFoundIsAToolError() async {
        let r = await call(["app": "Nope"])
        XCTAssertEqual(r.result?["isError"], true)
        XCTAssertEqual(r.result?["content"]?.arrayValue?.first?["text"]?.stringValue,
                       "app not found: no running app has bundle id or name 'Nope'. Running apps: TextEdit")
    }

    func testConflictingArgumentsAreInvalidParams() async {
        let cases: [(JSONValue, String)] = [(["app": "TextEdit", "pid": 20], "pass app or pid, not both"),
                            (["window": "x", "all_windows": true], "pass window or all_windows, not both"),
                            (["max_nodes": 1.5], "max_nodes must be an integer"),
                            (["window": -1], "window must be a non-empty title or a window index ≥ 0"),
                            (["app": ""], "app must be a non-empty string")]
        for (args, why) in cases {
            let r = await call(args)
            XCTAssertEqual(r.error?.code, JSONRPCError.invalidParams, "\(args)")
            XCTAssertEqual(r.error?.message, "Invalid params: \(why)")
        }
    }

    func testLimitsAreEchoed() async {
        let r = await call(["max_depth": 0, "max_nodes": 5000, "timeout_ms": 50])
        XCTAssertEqual(r.result?["structuredContent"]?["limits"], ["max_depth": 1, "max_nodes": 2000, "timeout_ms": 100])
    }

    /// The menu bar's "last tool call" and agent.log count `<principal> tools/call <name>`
    /// lines; ui_snapshot must produce exactly one, like every other tool.
    func testEndpointLogsOneToolCallLine() async {
        for env in [Self.environment(), Self.environment(trusted: false)] {
            let box = LogBox()
            let ep = MCPHTTPEndpoint(server: MCPServer(name: "t", version: "0", tools: [UISnapshotTool(environment: env)]),
                                     auth: AuthPolicy(allowedLogins: ["a@b"]), log: { box.add($0) })
            func post(_ body: Data) -> HTTPRequest {
                HTTPRequest(method: "POST", path: "/mcp", query: nil,
                            headers: ["content-type": "application/json", "tailscale-user-login": "a@b"],
                            body: body)
            }
            _ = await ep.handle(post(rpc("initialize", params: ["protocolVersion": "2025-06-18"])), remoteIsLoopback: true)
            let r = await ep.handle(post(rpc("tools/call", params: ["name": "ui_snapshot", "arguments": [:]])), remoteIsLoopback: true)
            XCTAssertEqual(r.status, 200)
            XCTAssertEqual(box.all.filter { $0.contains(" tools/call ") }, ["a@b tools/call ui_snapshot"])
        }
    }

    func testDescriptorSteersCallers() {
        let t = UISnapshotTool(environment: Self.environment())
        XCTAssertTrue(t.description.contains("browser_snapshot"))
        XCTAssertTrue(t.description.contains("screenshot"))
        XCTAssertEqual(t.inputSchema["properties"]?["max_nodes"]?["maximum"], 2000)
    }
}
