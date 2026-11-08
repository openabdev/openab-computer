import ApplicationServices
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
    /// Per-entry errors inside an otherwise successful batch, reduced the way the live
    /// provider reduces them.
    var entryErrors: [String: AXError] = [:]
    var valueError: UIAXError?
    var childError: UIAXError?
    var elementError: UIAXError?
    var prefixError: UIAXError?
    var supportsPrefix = true
    var requested: [String] = []
    var timeouts: [Float] = []
    var onAttributes: (() -> Void)?
    /// With `clock`, every AX call takes `delay` seconds of fake time, and like the real
    /// API gives up with `.timeout` once it exceeds the last messaging timeout.
    var clock: FakeClock?
    var delay: TimeInterval = 0

    init(_ attrs: [String: UIAttrValue] = [:], _ kids: [FakeUIElement] = []) {
        self.attrs = attrs; self.kids = kids
    }

    var identity: AnyHashable { AnyHashable(ObjectIdentifier(self)) }

    /// Spend one call's fake time; true when the call ran out of messaging timeout.
    private func spend() -> Bool {
        guard let clock else { return false }
        let limit = TimeInterval(timeouts.last ?? .infinity)
        if delay > limit { clock.t += limit; return true }
        clock.t += delay
        return false
    }

    func attributes(_ names: [String]) -> Result<[String: UIAttrValue], UIAXError> {
        requested += names
        onAttributes?()
        if spend() { return .failure(.timeout) }
        if names == ["AXValue"], let valueError { return .failure(valueError) }
        if names != ["AXValue"], let attrError { return .failure(attrError) }
        var entries: [String: AXLiveElement.BatchEntry] = [:]
        for n in names {
            if let e = entryErrors[n] { entries[n] = .error(e) } else if let v = attrs[n] { entries[n] = .value(v) }
        }
        return AXLiveElement.reduceBatch(entries)
    }

    func element(_ name: String) -> Result<(any UIElement)?, UIAXError> {
        if spend() { return .failure(.timeout) }
        if let elementError { return .failure(elementError) }
        return .success(named[name])
    }

    func elements(_ name: String) -> Result<[any UIElement], UIAXError> {
        if spend() { return .failure(.timeout) }
        if let elementError { return .failure(elementError) }
        return .success(lists[name] ?? [])
    }

    /// Two IPCs like the live provider: count, then (re-armed) copy.
    func children(max: Int, rearm: () -> Bool) -> Result<(elements: [any UIElement], total: Int), UIAXError> {
        requested.append("AXChildren")
        if spend() { return .failure(.timeout) }
        if let childError { return .failure(childError) }
        let want = Swift.min(Swift.max(max, 0), kids.count)
        guard want > 0 else { return .success(([], kids.count)) }
        guard rearm() else { return .failure(.timeout) }
        requested.append("AXChildren.copy")
        if spend() { return .failure(.timeout) }
        return .success((Array(kids.prefix(want)), kids.count))
    }

    func stringPrefix(utf16Length: Int) -> Result<String?, UIAXError> {
        requested.append("AXStringForRange")
        if spend() { return .failure(.timeout) }
        if let prefixError { return .failure(prefixError) }
        guard supportsPrefix, case .string(let s)? = attrs["AXValue"] else { return .success(nil) }
        return .success(String(decoding: Array(s.utf16.prefix(utf16Length)), as: UTF16.self))
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
    try UITreeWalker(limits: limits, newSnapshotID: { "snap-0000beef" })
        .walk(app: app, windows: windows, displays: displays,
              deadline: UIDeadline(timeoutMs: limits.timeoutMs, now: { clock.t }))
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
        XCTAssertEqual(s.nodeCount, 2, "w (to 0.08 s) and k0's base read (to 0.12 s), then the 0.1 s budget is gone")
        XCTAssertEqual(s.windows[0].children.count + s.windows[0].childrenOmitted, 4)
        XCTAssertEqual(s.omittedCount, 3)
        // Re-armed before every call: min(0.5, remaining), floored at 0.05.
        XCTAssertEqual(w.timeouts.map { Double($0) }, [0.1, 0.06, 0.05, 0.05].map { Double(Float($0)) })
        XCTAssertEqual(kids[0].timeouts, [0.05])
        XCTAssertFalse(kids[0].requested.contains("AXValue"), "no call starts after the budget is spent")
        XCTAssertTrue(kids[1].timeouts.isEmpty, "never touched once the budget ran out")
        XCTAssertEqual(s.unresponsiveCount, 0)
        XCTAssertTrue(s.renderText().hasSuffix("timed_out: the 100 ms budget ran out after 120 ms; raise timeout_ms up to 10000 or retry"))
    }

    /// Several slow calls per node must not each get the whole remainder: the budget
    /// bounds base + value + children reads together.
    func testBudgetBoundsEveryCallOfANode() throws {
        let clock = FakeClock()
        let kids = (0..<3).map { el("AXButton", "k\($0)") }
        let w = el("AXWindow", "w")
        w.kids = kids
        for e in [w] + kids { e.clock = clock; e.delay = 0.3 }
        let r = try walk([w], limits: .init(timeoutMs: 1000), clock: clock)
        let s = r.snapshot
        XCTAssertTrue(s.timedOut)
        XCTAssertEqual(s.unresponsiveCount, 0, "a call cut by the budget is a timeout, not an unresponsive app")
        // Base, value, child count, then the child copy re-armed with the last 0.1 s.
        XCTAssertEqual(w.timeouts.map { Double($0) }, [0.5, 0.5, 0.4, 0.1].map { Double(Float($0)) })
        XCTAssertEqual(s.elapsedMs, 1000)
        XCTAssertEqual(s.nodeCount, 1)
        for k in kids { XCTAssertTrue(k.requested.isEmpty) }
    }

    /// The child copy is a second IPC: it is not started once the count spent the budget.
    func testChildCopyIsReArmed() throws {
        let clock = FakeClock()
        let w = el("AXWindow", "w", el("AXButton", "k"))
        w.clock = clock
        w.delay = 0.1
        let r = try walk([w], limits: .init(timeoutMs: 300), clock: clock)
        XCTAssertTrue(r.snapshot.timedOut)
        XCTAssertEqual(r.snapshot.unresponsiveCount, 0)
        XCTAssertEqual(w.requested.filter { $0.hasPrefix("AXChildren") }, ["AXChildren"], "count only, no copy")
        XCTAssertEqual(clock.t, 0.3, accuracy: 1e-9)
    }

    func testMessagingTimeoutIsSetOnEveryElement() throws {
        let kids = [el("AXButton", "a"), el("AXButton", "b")]
        let w = el("AXWindow", "w")
        w.kids = kids
        _ = try walk([w])
        for e in kids {
            XCTAssertEqual(e.timeouts, [0.5, 0.5, 0.5], "armed before the base, value and child-count reads")
        }
        XCTAssertEqual(w.timeouts, [0.5, 0.5, 0.5, 0.5], "and again before the child copy")
    }

    func testHungNodeIsKeptButNotDescended() throws {
        let hung = el("AXGroup", "hung", el("AXButton", "never"))
        hung.attrError = .timeout
        let r = try walk([el("AXWindow", "w", hung, el("AXButton", "ok"))])
        let s = r.snapshot
        XCTAssertFalse(s.timedOut, "budget left: one slow element is not a spent budget")
        XCTAssertEqual(s.unresponsiveCount, 1)
        XCTAssertEqual(s.nodeCount, 3)
        XCTAssertNil(s.windows[0].children[0].role)
        XCTAssertTrue(s.windows[0].children[0].unresponsive)
        XCTAssertTrue(s.windows[0].children[0].children.isEmpty)
        XCTAssertEqual(s.windows[0].children[1].title, "ok")
        XCTAssertEqual(s.windows[0].children[0].json["unresponsive"], true)
        XCTAssertEqual(s.json["unresponsive_count"], 1)
        XCTAssertEqual(s.json["timed_out"], false)
        let text = s.renderText()
        XCTAssertTrue(text.contains("[e2] ? unresponsive"), text)
        XCTAssertTrue(text.hasSuffix("unresponsive: 1 elements did not answer within 500 ms and were not descended; the app may be busy — retry"), text)
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

    func testSecureFieldsAreNotDescended() throws {
        let inner = el("AXStaticText", extra: ["AXValue": .string("hunter2")])
        let secure = el("AXSecureTextField", nil, inner)
        let r = try walk([el("AXWindow", "w", secure)])
        XCTAssertTrue(r.snapshot.windows[0].children[0].children.isEmpty)
        XCTAssertFalse(secure.requested.contains("AXChildren"))
        XCTAssertTrue(inner.requested.isEmpty)
    }

    /// Masking fails closed: without a role the node could be a secure field, so its
    /// value is never requested.
    func testUnknownRoleValueIsNotRead() throws {
        let noRole = FakeUIElement(["AXValue": .string("hunter2")])
        let failed = el("AXSecureTextField", extra: ["AXValue": .string("hunter2")])
        failed.attrError = .other(-25200)
        let r = try walk([el("AXWindow", "w", noRole, failed)])
        for e in [noRole, failed] {
            XCTAssertFalse(e.requested.contains("AXValue"))
            XCTAssertFalse(e.requested.contains("AXStringForRange"))
        }
        XCTAssertFalse(encode(r.snapshot.json).contains("hunter2"))
        XCTAssertEqual(r.snapshot.nodeCount, 3)
    }

    /// A partial batch (role readable, subrole not) must not pass as a known
    /// non-secure node: the value is never requested.
    func testPartialBatchErrorOnSubroleNeverReadsTheValue() throws {
        let secret: [String: UIAttrValue] = ["AXValue": .string("hunter2"), "AXSubrole": .string("AXSecureTextField")]
        let cases: [(AXError, Bool)] = [(.cannotComplete, true), (.invalidUIElement, false), (.failure, true)]
        for (code, kept) in cases {
            let field = el("AXTextField", extra: secret)
            field.entryErrors = ["AXSubrole": code]
            let r = try walk([el("AXWindow", "w", field)])
            XCTAssertFalse(field.requested.contains("AXValue"), "AXValue requested after subrole error \(code)")
            XCTAssertEqual(r.snapshot.windows[0].children.count, kept ? 1 : 0, "\(code)")
            XCTAssertFalse(encode(r.snapshot.json).contains("hunter2"))
        }
    }

    func testReduceBatch() {
        typealias B = AXLiveElement
        let role: [String: B.BatchEntry] = ["AXRole": .value(.string("AXTextField"))]
        XCTAssertEqual(try B.reduceBatch(role).get(), ["AXRole": .string("AXTextField")])
        // Absent or unsupported entries are dropped.
        for code in [AXError.noValue, .attributeUnsupported, .notImplemented] {
            XCTAssertEqual(try B.reduceBatch(role.merging(["AXSubrole": .error(code), "AXHelp": .error(code)]) { a, _ in a }).get(),
                           ["AXRole": .string("AXTextField")])
        }
        // Grant, timeout and vanished on any entry fail the element.
        let failures: [(AXError, UIAXError)] = [(.apiDisabled, .apiDisabled), (.cannotComplete, .timeout),
                                                (.invalidUIElement, .invalidElement)]
        for (code, want) in failures {
            for key in ["AXSubrole", "AXHelp"] {
                let r = B.reduceBatch(role.merging([key: .error(code)]) { a, _ in a })
                XCTAssertEqual(r.failureValue, want, "\(key) \(code)")
            }
        }
        // Any other error fails only on a masking-relevant entry.
        XCTAssertEqual(B.reduceBatch(role.merging(["AXSubrole": .error(.failure)]) { a, _ in a }).failureValue,
                       .other(AXError.failure.rawValue))
        XCTAssertEqual(try B.reduceBatch(role.merging(["AXHelp": .error(.failure)]) { a, _ in a }).get(),
                       ["AXRole": .string("AXTextField")])
    }

    /// A long text is read as a prefix, not copied whole; without prefix support the
    /// walker falls back to AXValue.
    func testLongTextIsReadAsAPrefix() throws {
        let long = String(repeating: "y", count: 5000)
        let attrs: [String: UIAttrValue] = ["AXValue": .string(long), "AXNumberOfCharacters": .number(5000)]
        let area = el("AXTextArea", extra: attrs)
        let old = el("AXTextArea", extra: attrs)
        old.supportsPrefix = false
        let short = el("AXTextField", extra: ["AXValue": .string("hi"), "AXNumberOfCharacters": .number(2)])
        let r = try walk([el("AXWindow", "w", area, old, short)])
        let k = r.snapshot.windows[0].children
        XCTAssertTrue(area.requested.contains("AXStringForRange"))
        XCTAssertFalse(area.requested.contains("AXValue"))
        XCTAssertTrue(old.requested.contains("AXValue"))
        XCTAssertFalse(short.requested.contains("AXStringForRange"))
        for n in k[0...1] {
            XCTAssertEqual(n.valueTruncated, true)
            if case .string(let v)? = n.value { XCTAssertEqual(v, String(repeating: "y", count: 200) + "…") } else { XCTFail() }
        }
        XCTAssertEqual(k[2].value, .string("hi"))
        XCTAssertFalse(k[2].valueTruncated)
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
        s.unresponsiveCount = 2
        XCTAssertEqual(s.renderText(), """
            ui_snapshot snap-1 · pid 7 · 0 nodes · 41 ms
            (no elements)
            truncated: node limit 300 reached (max_nodes up to 2000); 12 elements not walked
            unresponsive: 2 elements did not answer within 500 ms and were not descended; the app may be busy — retry
            timed_out: the 3000 ms budget ran out after 41 ms; raise timeout_ms up to 10000 or retry
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
        // One main and three others: the same helper numbers screenshot, mouse and ui_snapshot.
        XCTAssertEqual(DisplayOrder.sorted([9, 2, 7, 5] as [UInt32], mainID: 7) { $0 }, [7, 2, 5, 9])
        let four = UIDisplayMap(displays: [9, 2, 7, 5].map { (id: UInt32($0), bounds: CGRect(x: Double($0) * 100, y: 0, width: 100, height: 100)) },
                                mainID: 7)
        XCTAssertEqual(four.ordered.map(\.id), DisplayOrder.sorted([9, 2, 7, 5] as [UInt32], mainID: 7) { $0 })
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
        try UITarget.windows(of: app, appName: "TextEdit", selector: sel, all: all,
                             deadline: UIDeadline(timeoutMs: 3000, now: { 0 })).map { $0 as! FakeUIElement }
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

    /// Title reads run under the call's deadline, each with a bounded messaging timeout.
    func testTitleSelectionRunsUnderTheDeadline() {
        let clock = FakeClock()
        let ws = ["a", "b", "c"].map { el("AXWindow", $0) }
        for w in ws { w.clock = clock; w.delay = 0.3 }
        let app = appElement(windows: ws)
        XCTAssertThrowsError(try UITarget.windows(of: app, appName: "TextEdit", selector: .title("c"), all: false,
                                                  deadline: UIDeadline(timeoutMs: 500, now: { clock.t }))) { e in
            XCTAssertEqual((e as? ToolError)?.description, UISnapshotTool.Errors.appBusy("TextEdit"))
        }
        XCTAssertEqual(clock.t, 0.5, accuracy: 1e-6, "stopped at the budget")
        XCTAssertEqual(ws[0].timeouts, [0.5])
        XCTAssertEqual(Double(ws[1].timeouts.first ?? 0), 0.2, accuracy: 1e-6)
        XCTAssertTrue(ws[2].requested.isEmpty)
        // With budget for every read the same selection succeeds.
        clock.t = 0
        XCTAssertTrue(try UITarget.windows(of: app, appName: "TextEdit", selector: .title("c"), all: false,
                                           deadline: UIDeadline(timeoutMs: 1000, now: { clock.t })).first === ws[2])
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}

// MARK: - the tool

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func add(_ d: Int) -> Int { lock.lock(); defer { lock.unlock() }; n += d; return n }
    func max(_ v: Int) { lock.lock(); n = Swift.max(n, v); lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
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
            isTrusted: { trusted }, selfPid: 99, runningApps: { running }, frontmostPid: { _ in 20 },
            frontmostGate: UIAXGate(),
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

    /// App enumeration that uses up the budget: the system-wide frontmost lookup is not started.
    func testFrontmostLookupIsNotStartedAfterTheBudget() {
        let clock = FakeClock()
        let asked = LogBox()
        var env = Self.environment()
        env.now = { clock.t }
        env.runningApps = {
            clock.t += 2
            return [UIRunningApp(pid: 20, bundleID: "com.apple.TextEdit", name: "TextEdit")]
        }
        env.frontmostPid = { _ in asked.add("frontmost"); return 20 }
        var req = UISnapshotTool.Request()
        req.limits = UISnapshotLimits(maxDepth: nil, maxNodes: nil, timeoutMs: 1000)
        XCTAssertThrowsError(try UISnapshotTool.run(req, env: env)) { e in
            XCTAssertEqual((e as? ToolError)?.description, UISnapshotTool.Errors.budgetSpent)
        }
        XCTAssertTrue(asked.all.isEmpty)
    }

    /// Concurrent default-target calls take the frontmost lookup one at a time, so one
    /// call cannot replace another's process-global timeout between the set and the read.
    func testFrontmostLookupsAreSerialized() {
        let gate = UIAXGate()
        let inside = Counter(), peak = Counter()
        var env = Self.environment()
        env.frontmostGate = gate
        env.now = { ProcessInfo.processInfo.systemUptime }
        // A fresh fake tree per call: the fakes are not thread-safe, the gate is under test.
        env.appElement = { pid in Self.environment().appElement(pid) }
        env.frontmostPid = { _ in
            let n = inside.add(1)
            peak.max(n)
            Thread.sleep(forTimeInterval: 0.02)
            inside.add(-1)
            return 20
        }
        var req = UISnapshotTool.Request()
        req.limits = UISnapshotLimits(maxDepth: nil, maxNodes: nil, timeoutMs: 5000)
        let ok = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if (try? UISnapshotTool.run(req, env: env)) != nil { ok.add(1) }
        }
        XCTAssertEqual(ok.value, 8)
        XCTAssertEqual(peak.value, 1)
    }

    /// A call whose budget runs out while another holds the gate never starts its lookup.
    func testFrontmostLookupIsNotStartedAfterWaitingOutTheBudget() {
        let gate = UIAXGate()
        let asked = LogBox()
        let now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var env = Self.environment()
        env.frontmostGate = gate
        env.now = now
        env.frontmostPid = { _ in asked.add("frontmost"); return 20 }
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = gate.run(UIDeadline(timeoutMs: 10_000, now: now)) { _ in holding.signal(); release.wait() }
            done.signal()
        }
        holding.wait()
        var req = UISnapshotTool.Request()
        req.limits = UISnapshotLimits(maxDepth: nil, maxNodes: nil, timeoutMs: UISnapshotLimits.minTimeoutMs)
        XCTAssertThrowsError(try UISnapshotTool.run(req, env: env)) { e in
            XCTAssertEqual((e as? ToolError)?.description, UISnapshotTool.Errors.budgetSpent)
        }
        release.signal()
        done.wait()
        XCTAssertTrue(asked.all.isEmpty)
    }

    /// The timeout is computed after the gate is acquired: time spent waiting shrinks it.
    func testGateTimeoutIsComputedAfterTheWait() {
        let clock = FakeClock()
        clock.t = 0
        let deadline = UIDeadline(timeoutMs: 1000, now: { clock.t })
        clock.t = 0.9
        XCTAssertEqual(UIAXGate().run(deadline) { $0 } ?? -1, 0.1, accuracy: 0.0001)
        clock.t = 1.0
        XCTAssertNil(UIAXGate().run(deadline) { $0 })
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
