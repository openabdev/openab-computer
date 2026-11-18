import Foundation
import XCTest
@testable import InstanceMCPCore

private func names(_ tools: [JSONValue]) -> [String] { tools.compactMap { $0["name"]?.stringValue } }
private func toolObjs(_ range: Range<Int>) -> JSONValue { .array(range.map { ["name": .string("t\($0)")] }) }

/// A scripted stdio server: `page(cursor)` returns the `result` JSON for one tools/list request.
private func serve(_ ch: ScriptedChannel, _ page: @escaping @Sendable (String?) -> String?) {
    ch.onSend = { v in
        guard v["method"]?.stringValue == "tools/list", let id = v["id"]?.intValue else { return }
        let cursor = v["params"]?["cursor"]?.stringValue
        if let result = page(cursor) { ch.feed("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}\n") }
        else { ch.feed("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"error\":{\"code\":-1,\"message\":\"CANARY\"}}\n") }
    }
}
private func listJSON(_ range: Range<Int>, next: String?) -> String {
    let tools = range.map { "{\"name\":\"t\($0)\"}" }.joined(separator: ",")
    return "{\"tools\":[\(tools)]" + (next.map { ",\"nextCursor\":\"\($0)\"" } ?? "") + "}"
}
private func errClass(_ body: () async throws -> Any) async -> String {
    do { _ = try await body(); return "no error" }
    catch let e as PlaywrightTransportError { return e.errorClass }
    catch { return "other" }
}

final class StdioListToolsPaginationTests: XCTestCase {
    func testThreePagesAreFollowedInOrder() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        serve(ch) { cur in
            switch cur {
            case nil: return listJSON(0..<2, next: "p2")
            case "p2": return listJSON(2..<4, next: "p3")
            default: return listJSON(4..<5, next: nil)
            }
        }
        let tools = try await c.listTools(timeout: 5)
        XCTAssertEqual(names(tools), ["t0", "t1", "t2", "t3", "t4"])
        XCTAssertEqual(ch.sent.filter { $0["method"]?.stringValue == "tools/list" }.count, 3)
    }

    func testSinglePageIsUnchanged() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        serve(ch) { _ in listJSON(0..<3, next: nil) }
        let tools = try await c.listTools(timeout: 5)
        XCTAssertEqual(names(tools), ["t0", "t1", "t2"])
        let reqs = ch.sent.filter { $0["method"]?.stringValue == "tools/list" }
        XCTAssertEqual(reqs.count, 1)
        XCTAssertNil(reqs[0]["params"]?["cursor"])
    }

    func testNullNextCursorEndsTheList() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        serve(ch) { _ in "{\"tools\":[{\"name\":\"a\"}],\"nextCursor\":null}" }
        let tools = try await c.listTools(timeout: 5)
        XCTAssertEqual(names(tools), ["a"])
        XCTAssertEqual(ch.sent.filter { $0["method"]?.stringValue == "tools/list" }.count, 1)
    }

    func testEmptyStringNextCursorEndsTheList() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        serve(ch) { cur in cur == nil ? "{\"tools\":[{\"name\":\"a\"}],\"nextCursor\":\"\"}" : listJSON(1..<2, next: nil) }
        let tools = try await c.listTools(timeout: 5)
        XCTAssertEqual(names(tools), ["a"])
        XCTAssertEqual(ch.sent.filter { $0["method"]?.stringValue == "tools/list" }.count, 1)
    }

    func testEmptyPageWithNextCursorIsFollowed() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        serve(ch) { cur in
            switch cur {
            case nil: return "{\"tools\":[],\"nextCursor\":\"p2\"}"
            default: return listJSON(0..<2, next: nil)
            }
        }
        let tools = try await c.listTools(timeout: 5)
        XCTAssertEqual(names(tools), ["t0", "t1"])
    }

    func testEndlessCursorsStopAtThePageCap() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        serve(ch) { cur in
            let n = cur.flatMap { Int($0.dropFirst()) } ?? 0
            return "{\"tools\":[{\"name\":\"t\(n)\"}],\"nextCursor\":\"c\(n + 1)\"}"
        }
        let k = await errClass { try await c.listTools(timeout: 10) }
        XCTAssertEqual(k, "tools_list_too_many_pages")
        XCTAssertEqual(ch.sent.filter { $0["method"]?.stringValue == "tools/list" }.count, ToolListPagination.maxPages)
    }

    func testToolCapIsEnforcedBeforeThePageCap() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        serve(ch) { cur in
            let n = cur.flatMap { Int($0.dropFirst()) } ?? 0
            return listJSON((n * 100)..<(n * 100 + 100), next: "c\(n + 1)")
        }
        let k = await errClass { try await c.listTools(timeout: 10) }
        XCTAssertEqual(k, "tools_list_too_many_tools")
        XCTAssertLessThan(ch.sent.filter { $0["method"]?.stringValue == "tools/list" }.count, ToolListPagination.maxPages)
    }

    func testCyclingCursorIsRejected() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        serve(ch) { cur in
            switch cur {
            case nil: return listJSON(0..<1, next: "a")
            case "a": return listJSON(1..<2, next: "b")
            default: return listJSON(2..<3, next: "a")
            }
        }
        let k = await errClass { try await c.listTools(timeout: 5) }
        XCTAssertEqual(k, "tools_list_cursor_cycle")
    }

    func testFailingSecondPageFailsClosed() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        serve(ch) { cur in cur == nil ? listJSON(0..<2, next: "p2") : nil }
        let k = await errClass { try await c.listTools(timeout: 5) }
        XCTAssertEqual(k, "playwright_rpc_error")   // fixed class, no CANARY text
    }

    func testStalledSecondPageTimesOutAgainstTheOverallDeadline() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        ch.onSend = { v in
            guard v["method"]?.stringValue == "tools/list", let id = v["id"]?.intValue else { return }
            if v["params"]?["cursor"] == nil {
                ch.feed("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(listJSON(0..<1, next: "p2"))}\n")
            }   // the second page is never answered
        }
        let start = Date()
        let k = await errClass { try await c.listTools(timeout: 0.5) }
        XCTAssertEqual(k, "playwright_timeout")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testDuplicateNamesKeepTheFirstAndNonStringCursorIsRejected() async throws {
        let ch = ScriptedChannel(); let c = StdioMCPClient(channel: ch)
        serve(ch) { cur in
            cur == nil ? "{\"tools\":[{\"name\":\"a\",\"v\":1},{\"name\":\"b\"}],\"nextCursor\":\"p2\"}"
                       : "{\"tools\":[{\"name\":\"a\",\"v\":2},{\"name\":\"c\"}]}"
        }
        let tools = try await c.listTools(timeout: 5)
        XCTAssertEqual(names(tools), ["a", "b", "c"])
        XCTAssertEqual(tools[0]["v"]?.intValue, 1)

        let ch2 = ScriptedChannel(); let c2 = StdioMCPClient(channel: ch2)
        serve(ch2) { _ in "{\"tools\":[],\"nextCursor\":7}" }
        let k = await errClass { try await c2.listTools(timeout: 5) }
        XCTAssertEqual(k, "tools_list_bad_cursor")
    }
}

final class ExternalListToolsPaginationTests: XCTestCase {
    private func sse(_ v: JSONValue) -> HTTPResponse {
        let body = "event: message\ndata: " + String(decoding: jsonBody(v), as: UTF8.self) + "\n\n"
        return HTTPResponse(status: 200, headers: [("Content-Type", "text/event-stream"), ("Mcp-Session-Id", "s1")], body: Data(body.utf8))
    }
    private func stub(_ page: @escaping @Sendable (String?) -> JSONValue?) throws -> StubHTTPServer {
        try StubHTTPServer { [self] req in
            let m = (try? JSONCoding.decoder.decode(JSONRPCRequest.self, from: req.body))?.method
            if m == "initialize" { return sse(["jsonrpc": "2.0", "id": 0, "result": [:]]) }
            guard m == "tools/list" else { return .init(status: 202) }
            let obj = try? JSONCoding.decoder.decode(JSONValue.self, from: req.body)
            if let r = page(obj?["params"]?["cursor"]?.stringValue) { return sse(["jsonrpc": "2.0", "id": 1, "result": r]) }
            return .init(status: 500)
        }
    }
    private func client(_ s: StubHTTPServer) -> ExternalPlaywrightClient {
        ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 10)
    }

    func testThreePagesAndSinglePage() async throws {
        let s = try stub { cur in
            switch cur {
            case nil: return ["tools": toolObjs(0..<2), "nextCursor": "p2"]
            case "p2": return ["tools": toolObjs(2..<4), "nextCursor": "p3"]
            default: return ["tools": toolObjs(4..<5)]
            }
        }
        defer { s.stop() }
        let tools = try await client(s).listTools()
        XCTAssertEqual(names(tools), ["t0", "t1", "t2", "t3", "t4"])

        let one = try stub { _ in ["tools": toolObjs(0..<3), "nextCursor": .null] }
        defer { one.stop() }
        let t1 = try await client(one).listTools()
        XCTAssertEqual(names(t1), ["t0", "t1", "t2"])
    }

    func testCycleAndEndlessAndFailingSecondPage() async throws {
        let cyc = try stub { _ in ["tools": toolObjs(0..<1), "nextCursor": "a"] }
        defer { cyc.stop() }
        let c1 = client(cyc)
        let k1 = await errClass { try await c1.listTools() }
        XCTAssertEqual(k1, "tools_list_cursor_cycle")

        let endless = try stub { cur in
            let n = cur.flatMap { Int($0.dropFirst()) } ?? 0
            return ["tools": toolObjs(n..<(n + 1)), "nextCursor": .string("c\(n + 1)")]
        }
        defer { endless.stop() }
        let c2 = client(endless)
        let k2 = await errClass { try await c2.listTools() }
        XCTAssertEqual(k2, "tools_list_too_many_pages")

        let failing = try stub { cur in cur == nil ? ["tools": toolObjs(0..<2), "nextCursor": "p2"] : nil }
        defer { failing.stop() }
        let c3 = client(failing)
        let k3 = await errClass { try await c3.listTools() }
        XCTAssertEqual(k3, "upstream_http_500")
    }

    func testEmptyStringNextCursorEndsTheList() async throws {
        let s = try stub { cur in cur == nil ? ["tools": toolObjs(0..<1), "nextCursor": ""] : ["tools": toolObjs(1..<2)] }
        defer { s.stop() }
        let tools = try await client(s).listTools()
        XCTAssertEqual(names(tools), ["t0"])
        XCTAssertEqual(s.requests.filter { methodName($0) == "tools/list" }.count, 1)
    }

    private func methodName(_ r: HTTPRequest) -> String? {
        (try? JSONCoding.decoder.decode(JSONRPCRequest.self, from: r.body))?.method
    }

    /// A server where `initialize` and `tools/list` take `delay` each (notifications are instant);
    /// pages chain forever so only the budget stops the walk. `events` records what was served.
    /// With `retryListDelay`, the second `tools/list` (the retry after a reset) takes that long instead of `delay`.
    private func slowServer(delay: TimeInterval, resetFirstList: Bool = false, retryListDelay: TimeInterval? = nil,
                            events: EventLog = EventLog()) throws -> StubHTTPServer {
        let lock = NSLock(); nonisolated(unsafe) var lists = 0
        return try StubHTTPServer { [self] req in
            let m = methodName(req)
            let n = m == "tools/list" ? lock.withLock { lists += 1; return lists } : 0
            if m == "initialize" || m == "tools/list" {
                Thread.sleep(forTimeInterval: (m == "tools/list" && n == 2 ? retryListDelay : nil) ?? delay)
            }
            if m == "initialize" { events.add("initialize"); return sse(["jsonrpc": "2.0", "id": 0, "result": [:]]) }
            guard m == "tools/list" else { return .init(status: 202) }
            if resetFirstList && n == 1 { events.add("list-404"); return .init(status: 404) }
            events.add("list")
            return sse(["jsonrpc": "2.0", "id": 1, "result": ["tools": toolObjs(n..<(n + 1)), "nextCursor": .string("c\(n)")]])
        }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ e: String) { lock.withLock { items.append(e) } }
        var all: [String] { lock.withLock { items } }
    }

    func testSlowPagesSummingAboveTheBudgetFailWithTheBudgetError() async throws {
        let s = try slowServer(delay: 0.35)
        defer { s.stop() }
        let c = ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 1.2)
        let t0 = ContinuousClock.now
        let k = await errClass { try await c.listTools() }
        XCTAssertEqual(k, "playwright_timeout")
        XCTAssertLessThan(t0.duration(to: .now), .seconds(2.2))
    }

    func testSessionResetMidListingStillHonorsTheOverallBudget() async throws {
        // initialize 0.4 s, the first tools/list 404s after 0.4 s (0.8 s in), the re-initialize ends at 1.2 s and the
        // retried tools/list takes 2 s, so it would end at 3.2 s. Under one overall 1.5 s budget the call ends at about
        // 1.5 s. Without the budget the retry gets a fresh 1.5 s request timeout and ends at about 2.7 s with a
        // different class, so the bound below and the class both tell the two apart.
        let events = EventLog()
        let s = try slowServer(delay: 0.4, resetFirstList: true, retryListDelay: 2, events: events)
        defer { s.stop() }
        let c = ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 1.5)
        let t0 = ContinuousClock.now
        let k = await errClass { try await c.listTools() }
        let elapsed = t0.duration(to: .now)
        XCTAssertEqual(k, "playwright_timeout")
        XCTAssertLessThan(elapsed, .seconds(2.5), "the retry was cut at the overall budget, not given its own timeout")
        let seen = events.all
        XCTAssertEqual(Array(seen.prefix(3)), ["initialize", "list-404", "initialize"], "the reset path ran")
    }

    func testToolCapIsEnforcedOnTheHTTPPath() async throws {
        // 500 tools per page and a next cursor each time: the cap (2000 raw entries) ends it at the fifth page, long
        // before the 50-page cap.
        let s = try stub { cur in
            let n = cur.flatMap { Int($0.dropFirst()) } ?? 0
            return ["tools": toolObjs((n * 500)..<(n * 500 + 500)), "nextCursor": .string("c\(n + 1)")]
        }
        defer { s.stop() }
        let c = client(s)
        let k = await errClass { try await c.listTools() }
        XCTAssertEqual(k, "tools_list_too_many_tools")
        let lists = s.requests.filter { methodName($0) == "tools/list" }.count
        XCTAssertEqual(lists, 5, "2000 entries over four pages are accepted, the fifth page crosses the cap")
        XCTAssertLessThan(lists, ToolListPagination.maxPages)
    }

    func testExactlyTheToolCapIsAccepted() async throws {
        let s = try stub { cur in
            cur == nil ? ["tools": toolObjs(0..<1000), "nextCursor": "p2"] : ["tools": toolObjs(1000..<2000)]
        }
        defer { s.stop() }
        let tools = try await client(s).listTools()
        XCTAssertEqual(tools.count, 2000)
    }

    func testOneToolOverTheCapIsRejected() async throws {
        let s = try stub { cur in
            cur == nil ? ["tools": toolObjs(0..<1000), "nextCursor": "p2"] : ["tools": toolObjs(1000..<2001)]
        }
        defer { s.stop() }
        let k = await errClass { try await client(s).listTools() }
        XCTAssertEqual(k, "tools_list_too_many_tools")
    }
}
