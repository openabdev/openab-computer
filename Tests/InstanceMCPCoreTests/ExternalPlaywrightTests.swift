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
                          endpoint: .init(family: .v4, port: s.port), probe: FakePortOwnerProbe(result: owner), trust: trust, euid: euid)
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

    func testManagedModeWithNothingInstalledIsNotSetUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oab-pw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = PlaywrightBackend(managed: ManagedPlaywrightLocator(root: dir))
        let st = await b.status()
        XCTAssertEqual(st, BrowserBackendStatus.needsSetup("playwright_not_installed"))
        let mode = await b.mode
        XCTAssertEqual(mode, "managed")
        let peek = await b.peekStatus()
        XCTAssertEqual(peek, BrowserBackendStatus.needsSetup("playwright_not_installed"))
    }

    func testBackendPassesTheValidatedEndpointFamilyToTheProbe() async throws {
        let s = try fake(); defer { s.stop() }
        let probe = FakePortOwnerProbe(result: PortOwner(pid: 7, uid: 501, name: "node"))
        let b = PlaywrightBackend(external: ExternalPlaywrightClient(url: URL(string: "http://[::1]:\(s.port)/mcp")!, timeout: 5),
                                  endpoint: .init(family: .v6, port: s.port), probe: probe, trust: .operatorFlag, euid: 501)
        _ = await b.status()
        XCTAssertEqual(probe.asked.first, BrowserUpstreamURL.Endpoint(family: .v6, port: s.port))
    }

    func testOwnerSuccessIsReusedBrieflyAndFailureIsNeverCached() async throws {
        let s = try fake(); defer { s.stop() }
        let clock = TestClock()
        let probe = FakePortOwnerProbe(result: PortOwner(pid: 7, uid: 501, name: "node"))
        let b = PlaywrightBackend(external: ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 5),
                                  endpoint: .init(family: .v4, port: s.port), probe: probe, trust: .operatorFlag, euid: 501,
                                  clock: { clock.date() })
        _ = await b.status(); _ = await b.tools(); _ = await b.tools()
        XCTAssertEqual(probe.asked.count, 1)
        clock.advance(3)
        _ = await b.tools()
        XCTAssertEqual(probe.asked.count, 2)
        probe.result = nil; clock.advance(3)
        _ = await b.tools(); _ = await b.tools()
        XCTAssertEqual(probe.asked.count, 4, "a failed check must not be cached")
    }

    func testToolListKeepsLastKnownOnATransientFailure() async throws {
        let s = try fake()
        let clock = TestClock()
        let b = PlaywrightBackend(external: ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 2),
                                  endpoint: .init(family: .v4, port: s.port), probe: FakePortOwnerProbe(result: PortOwner(pid: 7, uid: 501, name: "node")),
                                  trust: .operatorFlag, euid: 501, clock: { clock.date() })
        let first = await b.tools()
        XCTAssertEqual(first.count, 1)
        s.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        clock.advance(60)
        let second = await b.tools()
        XCTAssertEqual(second.count, 1, "the previous list is kept")
    }

    func testLibprocFindsOurOwnListener() throws {
        guard let p = BSDListener.freePort() else { throw XCTSkip("no free port") }
        let l = try XCTUnwrap(BSDListener(v6: false, port: p))
        _ = l
        let o = LibprocPortOwnerProbe().owner(of: .init(family: .v4, port: p))
        XCTAssertEqual(o?.pid, getpid())
        XCTAssertEqual(o?.uid, geteuid())
    }

    func testSimultaneousV4AndV6ListenersAreToldApart() throws {
        guard let p = BSDListener.freePort() else { throw XCTSkip("no free port") }
        let v4 = try XCTUnwrap(BSDListener(v6: false, port: p))
        _ = v4
        // Only v4 is open: the v6 endpoint has no owner.
        XCTAssertNil(LibprocPortOwnerProbe().owner(of: .init(family: .v6, port: p)))
        // The v6 listener is held by a different process.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: fakeServerPath())
        child.arguments = ["listen6", String(p)]
        let out = Pipe(); child.standardOutput = out
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let ready = out.fileHandleForReading.availableData
        XCTAssertEqual(String(decoding: ready, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "ready")
        let o4 = LibprocPortOwnerProbe().owner(of: .init(family: .v4, port: p))
        let o6 = LibprocPortOwnerProbe().owner(of: .init(family: .v6, port: p))
        XCTAssertEqual(o4?.pid, getpid())
        XCTAssertEqual(o6?.pid, child.processIdentifier)
    }

    func testSameProcessOwnsBothFamilies() throws {
        guard let p = BSDListener.freePort() else { throw XCTSkip("no free port") }
        let a = try XCTUnwrap(BSDListener(v6: false, port: p)), b = try XCTUnwrap(BSDListener(v6: true, port: p))
        _ = (a, b)
        XCTAssertEqual(LibprocPortOwnerProbe().owner(of: .init(family: .v4, port: p))?.pid, getpid())
        XCTAssertEqual(LibprocPortOwnerProbe().owner(of: .init(family: .v6, port: p))?.pid, getpid())
    }
}

final class BrowserSecretHygieneTests: XCTestCase {
    func testBackendErrorsAndLogsCarryOnlyClasses() async throws {
        let canary = "CANARY-token-abc123"
        let s = try StubHTTPServer { _ in .text(502, "\(canary)\n") }; defer { s.stop() }
        nonisolated(unsafe) var lines: [String] = []
        let lock = NSLock()
        let b = PlaywrightBackend(external: ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 5),
                                  endpoint: .init(family: .v4, port: s.port), probe: FakePortOwnerProbe(result: PortOwner(pid: 1, uid: 501, name: "node")),
                                  trust: .operatorFlag, euid: 501, log: { l in lock.withLock { lines.append(l) } })
        let router = BrowserRouter(playwright: b, store: MemoryPreferenceStore(.playwright),
                                   log: { l in lock.withLock { lines.append(l) } })
        let res = await router.call("browser_navigate", arguments: ["url": .string(canary)], BrowserConnection(key: "k"))
        let all = String(decoding: jsonBody(res), as: UTF8.self) + lines.joined()
        XCTAssertFalse(all.contains("CANARY"), all)
    }
}

final class ListenerMatchTests: XCTestCase {
    private let zero = [UInt8](repeating: 0, count: 16)
    private var loop6: [UInt8] { var a = zero; a[15] = 1; return a }
    private let v4 = BrowserUpstreamURL.Endpoint(family: .v4, port: 1)
    private let v6 = BrowserUpstreamURL.Endpoint(family: .v6, port: 1)

    func testTable() {
        let I4 = UInt8(INI_IPV4), I6 = UInt8(INI_IPV6)
        // v4 loopback and wildcard
        XCTAssertTrue(ListenerMatch.matches(vflag: I4, addr4: 0x7f00_0001, addr6: zero, endpoint: v4))
        XCTAssertTrue(ListenerMatch.matches(vflag: I4, addr4: 0, addr6: zero, endpoint: v4))
        XCTAssertFalse(ListenerMatch.matches(vflag: I4, addr4: 0x7f00_0001, addr6: zero, endpoint: v6))
        // v6 loopback and wildcard
        XCTAssertTrue(ListenerMatch.matches(vflag: I6, addr4: 0, addr6: loop6, endpoint: v6))
        XCTAssertTrue(ListenerMatch.matches(vflag: I6, addr4: 0, addr6: zero, endpoint: v6))
        XCTAssertFalse(ListenerMatch.matches(vflag: I6, addr4: 0, addr6: loop6, endpoint: v4))
        // dual-stack wildcard serves both
        XCTAssertTrue(ListenerMatch.matches(vflag: I4 | I6, addr4: 0, addr6: zero, endpoint: v4))
        XCTAssertTrue(ListenerMatch.matches(vflag: I4 | I6, addr4: 0, addr6: zero, endpoint: v6))
        // a LAN address does not match
        XCTAssertFalse(ListenerMatch.matches(vflag: I4, addr4: 0xc000_0201, addr6: zero, endpoint: v4))
        var lan6 = zero; lan6[0] = 0x20; lan6[1] = 0x01; lan6[15] = 5
        XCTAssertFalse(ListenerMatch.matches(vflag: I6, addr4: 0, addr6: lan6, endpoint: v6))
    }
}

final class ExternalPlaywrightHealthTests: XCTestCase {
    private func methodOf(_ r: HTTPRequest) -> String? { (try? JSONCoding.decoder.decode(JSONRPCRequest.self, from: r.body))?.method }

    private func stub() throws -> StubHTTPServer {
        try StubHTTPServer { [self] req in
            if req.method == "DELETE" { return .init(status: 200) }
            switch methodOf(req) {
            case "initialize": return sse(["jsonrpc": "2.0", "id": 0, "result": [:]], sid: "sid-\(Int.random(in: 1...1_000_000))")
            case "ping": return sse(["jsonrpc": "2.0", "id": 1, "result": [:]])
            default: return .init(status: 202)
            }
        }
    }

    func testRepeatedHealthChecksInitializeOnceAndPing() async throws {
        let s = try stub(); defer { s.stop() }
        let c = ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 90)
        try await c.healthCheck(); try await c.healthCheck(); try await c.healthCheck()
        let methods = s.requests.compactMap { methodOf($0) }
        XCTAssertEqual(methods.filter { $0 == "initialize" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "ping" }.count, 2)
        XCTAssertTrue(s.requests.allSatisfy { $0.method != "DELETE" })
    }

    func testRejectedSessionIsDeletedBeforeANewInitialize() async throws {
        let lock = NSLock(); nonisolated(unsafe) var pings = 0; nonisolated(unsafe) var n = 0
        let s = try StubHTTPServer { [self] req in
            if req.method == "DELETE" { return .init(status: 200) }
            switch methodOf(req) {
            case "initialize": return sse(["jsonrpc": "2.0", "id": 0, "result": [:]], sid: "sid-\(lock.withLock { n += 1; return n })")
            case "ping":
                let k = lock.withLock { pings += 1; return pings }
                return k == 1 ? .init(status: 400) : sse(["jsonrpc": "2.0", "id": 1, "result": [:]])
            default: return .init(status: 202)
            }
        }
        defer { s.stop() }
        let c = ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 90)
        try await c.healthCheck()   // initialize (sid-1)
        try await c.healthCheck()   // ping -> 400 -> DELETE sid-1 -> initialize (sid-2)
        let seq = s.requests.map { $0.method == "DELETE" ? "DELETE:" + ($0.header("mcp-session-id") ?? "") : (methodOf($0) ?? "?") }
        let del = try XCTUnwrap(seq.firstIndex(of: "DELETE:sid-1"))
        XCTAssertEqual(seq.filter { $0 == "initialize" }.count, 2)
        XCTAssertEqual(seq[del + 1], "initialize")
    }

    func testHealthCheckUsesTwoSecondsEvenWithALongClientTimeout() async throws {
        let s = try StubHTTPServer { _ in Thread.sleep(forTimeInterval: 3.5); return .text(200, "") }
        defer { s.stop() }
        let c = ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!, timeout: 90)
        let t0 = Date()
        do { try await c.healthCheck(); XCTFail("no error") }
        catch let e as PlaywrightTransportError { XCTAssertEqual(e.errorClass, "upstream_timeout") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3.2)
    }

    func testHostHeaderIsBracketedForIPv6() async throws {
        guard let p = BSDListener.freePort() else { throw XCTSkip("no free port") }
        _ = p
        let c = ExternalPlaywrightClient(url: URL(string: "http://[::1]:9/mcp")!)
        let h = await c.hostHeaderForTests
        XCTAssertEqual(h, "[::1]")
        let c4 = ExternalPlaywrightClient(url: URL(string: "http://127.0.0.1:9/mcp")!)
        let h4 = await c4.hostHeaderForTests
        XCTAssertEqual(h4, "127.0.0.1")
    }
}

final class BrowserUpstreamEndpointTests: XCTestCase {
    func testFamilyPortAndRange() throws {
        XCTAssertEqual(try BrowserUpstreamURL.endpoint(URL(string: "http://127.0.0.1:8794/mcp")!), .init(family: .v4, port: 8794))
        XCTAssertEqual(try BrowserUpstreamURL.endpoint(URL(string: "http://[::1]:8794/mcp")!), .init(family: .v6, port: 8794))
        XCTAssertEqual(try BrowserUpstreamURL.endpoint(URL(string: "http://127.0.0.1/mcp")!).port, 80)
        XCTAssertThrowsError(try BrowserUpstreamURL.endpoint(URL(string: "http://127.0.0.1:70000/mcp")!))
        XCTAssertThrowsError(try BrowserUpstreamURL.endpoint(URL(string: "http://127.0.0.1:0/mcp")!))
        XCTAssertThrowsError(try BrowserUpstreamURL.endpoint(URL(string: "http://localhost:8794/mcp")!))
    }
}
