import Foundation
import XCTest
@testable import InstanceMCPCore

private func sse(_ v: JSONValue, sid: String? = "s1") -> HTTPResponse {
    let body = "event: message\ndata: " + String(decoding: jsonBody(v), as: UTF8.self) + "\n\n"
    return HTTPResponse(status: 200, headers: [("Content-Type", "text/event-stream")] + (sid.map { [("Mcp-Session-Id", $0)] } ?? []),
                        body: Data(body.utf8))
}

final class ExternalPlaywrightRedirectTests: XCTestCase {
    func testRedirectsAreRefusedAndNoSecondRequestIsSent() async throws {
        for status in [301, 302, 307, 308] {
            let target = try StubHTTPServer { _ in .text(200, "should not be reached\n") }
            defer { target.stop() }
            let tport = target.port
            let origin = try StubHTTPServer { _ in
                HTTPResponse(status: status, headers: [("Location", "http://127.0.0.1:\(tport)/mcp")], body: Data())
            }
            defer { origin.stop() }
            let client = ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(origin.port)/mcp")!, timeout: 5)
            do { _ = try await client.listTools(); XCTFail("\(status): no error") }
            catch let e as ExternalPlaywrightError { XCTAssertEqual(e.errorClass, "upstream_redirect", "\(status)") }
            XCTAssertTrue(target.requests.isEmpty, "\(status): the redirect target received a request")
            XCTAssertEqual(origin.requests.count, 1, "\(status): body re-sent or retried")
        }
    }
}

final class ExternalPlaywrightErrorTests: XCTestCase {
    static let canary = "CANARY-9f3a-secret-page-text"

    func klass(_ handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) async throws -> String {
        let s = try StubHTTPServer(handler); defer { s.stop() }
        let client = ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 5)
        do { _ = try await client.callTool("browser_navigate", arguments: [:]); return "no error" }
        catch let e as ExternalPlaywrightError { return e.errorClass }
    }

    func testFixedClassesCarryNoUpstreamText() async throws {
        let c = Self.canary
        let http = try await klass { _ in .text(500, "\(c)\n") }
        XCTAssertEqual(http, "upstream_http_500")
        let bad = try await klass { _ in .text(200, "\(c) not json\n") }
        XCTAssertEqual(bad, "upstream_bad_body")
        let rpcErr = try await klass { req in
            let m = (try? JSONCoding.decoder.decode(JSONRPCRequest.self, from: req.body))?.method
            if m == "initialize" { return sse(["jsonrpc": "2.0", "id": 0, "result": [:]]) }
            if m == "tools/call" { return sse(["jsonrpc": "2.0", "id": 1, "error": ["code": -1, "message": .string(c)]]) }
            return .init(status: 202)
        }
        XCTAssertEqual(rpcErr, "upstream_rpc_error")
        for k in [http, bad, rpcErr] { XCTAssertFalse(k.contains("CANARY")) }
    }

    func testUnreachableAndSuccessPassthrough() async throws {
        let dead = try StubHTTPServer { _ in .text(200, "") }; let p = dead.port; dead.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let c1 = ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(p)/mcp")!, timeout: 2)
        do { _ = try await c1.listTools(); XCTFail() } catch let e as ExternalPlaywrightError {
            XCTAssertEqual(e.errorClass, "upstream_unreachable")
        }
        let s = try StubHTTPServer { req in
            let m = (try? JSONCoding.decoder.decode(JSONRPCRequest.self, from: req.body))?.method
            if m == "initialize" { return sse(["jsonrpc": "2.0", "id": 0, "result": [:]]) }
            if m == "tools/call" {
                return sse(["jsonrpc": "2.0", "id": 1, "result": ["content": [["type": "text", "text": "page text"]], "isError": true]])
            }
            return .init(status: 202)
        }
        defer { s.stop() }
        let ok = try await ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!)
            .callTool("browser_navigate", arguments: [:])
        XCTAssertEqual(ok["content"]?.arrayValue?.first?["text"]?.stringValue, "page text")
        XCTAssertEqual(ok["isError"]?.boolValue, true)
    }
}

final class PortOwnerProbeTests: XCTestCase {
    private func backend(_ owner: PortOwner?, _ s: StubHTTPServer, euid: UInt32 = 501,
                         trust: BrowserTrust = .operatorFlag) -> PlaywrightBackend {
        PlaywrightBackend(external: ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 5),
                          port: s.port, probe: FakePortOwnerProbe(result: owner), trust: trust, euid: euid)
    }
    private func fake() throws -> StubHTTPServer {
        try StubHTTPServer { req in
            let m = (try? JSONCoding.decoder.decode(JSONRPCRequest.self, from: req.body))?.method
            if m == "initialize" { return sse(["jsonrpc": "2.0", "id": 0, "result": [:]]) }
            if m == "tools/list" { return sse(["jsonrpc": "2.0", "id": 1, "result": ["tools": [["name": "browser_navigate"]]]]) }
            if m == "tools/call" { return sse(["jsonrpc": "2.0", "id": 1, "result": ["content": []]]) }
            return .init(status: 202)
        }
    }

    func testSameUidIsReady() async throws {
        let s = try fake(); defer { s.stop() }
        let b = backend(PortOwner(pid: 7, uid: 501, name: "node"), s)
        let st = await b.status()
        XCTAssertEqual(st, .ready)
        let summary = await b.ownerSummary
        XCTAssertEqual(summary, "node (uid 501)")
    }

    func testUnknownAndForeignOwnersFailClosedWithNoRequest() async throws {
        let s = try fake(); defer { s.stop() }
        for owner in [nil, PortOwner(pid: 7, uid: 0, name: "node")] {
            let b = backend(owner, s)
            let st = await b.status()
            if case .unavailable = st {} else { XCTFail("not unavailable: \(st)") }
            let t = await b.tools()
            XCTAssertTrue(t.isEmpty)
            do { _ = try await b.call("browser_navigate", arguments: [:]); XCTFail("call went through") } catch {}
        }
        XCTAssertTrue(s.requests.isEmpty, "a request reached a listener that failed the ownership check")
    }

    func testManagedModeIsNotSetUpYet() async {
        let b = PlaywrightBackend()
        let st = await b.status()
        XCTAssertEqual(st, .needsSetup("playwright_not_installed"))
        let mode = await b.mode
        XCTAssertEqual(mode, "managed")
    }

    func testLibprocFindsOurOwnListener() throws {
        let s = try fake(); defer { s.stop() }
        let o = LibprocPortOwnerProbe().owner(ofLoopbackPort: s.port)
        XCTAssertEqual(o?.pid, getpid())
        XCTAssertEqual(o?.uid, geteuid())
    }
}

final class BrowserSecretHygieneTests: XCTestCase {
    func testBackendErrorsAndLogsCarryOnlyClasses() async throws {
        let canary = "CANARY-token-abc123"
        let s = try StubHTTPServer { _ in .text(502, "\(canary)\n") }; defer { s.stop() }
        nonisolated(unsafe) var lines: [String] = []
        let lock = NSLock()
        let b = PlaywrightBackend(external: ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 5),
                                  port: s.port, probe: FakePortOwnerProbe(result: PortOwner(pid: 1, uid: 501, name: "node")),
                                  trust: .operatorFlag, euid: 501, log: { l in lock.withLock { lines.append(l) } })
        let router = BrowserRouter(playwright: b, store: MemoryPreferenceStore(.playwright),
                                   log: { l in lock.withLock { lines.append(l) } })
        let res = await router.call("browser_navigate", arguments: ["url": .string(canary)], BrowserConnection(key: "k"))
        let all = String(decoding: jsonBody(res), as: UTF8.self) + lines.joined()
        XCTAssertFalse(all.contains("CANARY"), all)
    }
}
