import Foundation
import XCTest
@testable import InstanceMCPCore

/// A channel the test drives by hand.
final class ScriptedChannel: StdioChannel, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let cont: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var _sent: [Data] = []
    private var _closed = false
    var onSend: (@Sendable (JSONValue) -> Void)?

    init() {
        var c: AsyncStream<Data>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        cont = c
    }
    var sent: [JSONValue] {
        lock.withLock { _sent }.flatMap { d in
            String(decoding: d, as: UTF8.self).split(separator: "\n").compactMap { try? JSONCoding.decoder.decode(JSONValue.self, from: Data($0.utf8)) }
        }
    }
    var rawSent: [Data] { lock.withLock { _sent } }
    var closed: Bool { lock.withLock { _closed } }
    func send(_ data: Data) {
        lock.withLock { _sent.append(data) }
        if let v = try? JSONCoding.decoder.decode(JSONValue.self, from: data.dropLast()) { onSend?(v) }
    }
    func close() { lock.withLock { _closed = true }; cont.finish() }
    func feed(_ s: String) { cont.yield(Data(s.utf8)) }
    func feed(_ d: Data) { cont.yield(d) }
    func finish() { cont.finish() }
}

private func okReply(_ id: JSONValue?) -> String {
    "{\"jsonrpc\":\"2.0\",\"id\":\(id?.intValue ?? 0),\"result\":{}}\n"
}

final class StdioMCPClientTests: XCTestCase {
    func testOutboundIsOneCompactLinePerMessage() async throws {
        let ch = ScriptedChannel()
        ch.onSend = { v in if v["id"] != nil { ch.feed(okReply(v["id"])) } }
        let c = StdioMCPClient(channel: ch)
        try await c.initialize(timeout: 2)
        for d in ch.rawSent {
            XCTAssertEqual(d.last, 0x0A)
            XCTAssertEqual(d.filter { $0 == 0x0A }.count, 1, "exactly one newline, at the end")
        }
        XCTAssertEqual(ch.sent.map { $0["method"]?.stringValue }, ["initialize", "notifications/initialized"])
    }

    func testReplySplitAcrossWritesAndTwoRepliesInOneRead() async throws {
        let ch = ScriptedChannel()
        let c = StdioMCPClient(channel: ch)
        await c.startReading()
        ch.onSend = { v in
            guard let id = v["id"] else { return }
            let line = okReply(id)
            let mid = line.index(line.startIndex, offsetBy: 7)
            ch.feed(String(line[..<mid])); ch.feed(String(line[mid...]))
        }
        try await c.ping(timeout: 2)
        // Two replies in one chunk.
        ch.onSend = nil
        async let a: Void = c.ping(timeout: 2)
        async let b: Void = c.ping(timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        let ids = ch.sent.suffix(2).compactMap { $0["id"] }
        XCTAssertEqual(ids.count, 2)
        ch.feed(okReply(ids[1]) + okReply(ids[0]))   // out of order, one read
        try await a; try await b
    }

    func testCRLFAndNoiseAreTolerated() async throws {
        let ch = ScriptedChannel()
        let c = StdioMCPClient(channel: ch)
        ch.onSend = { v in
            guard let id = v["id"] else { return }
            ch.feed("not json at all CANARY\n")
            ch.feed("\n")
            ch.feed(String(okReply(id).dropLast()) + "\r\n")
        }
        await c.startReading()
        try await c.ping(timeout: 2)
        let dropped = await c.droppedLines
        XCTAssertEqual(dropped, 1)
    }

    func testServerPingIsAnsweredAndOtherRequestsGetMethodNotFound() async throws {
        let ch = ScriptedChannel()
        let c = StdioMCPClient(channel: ch)
        await c.startReading()
        ch.feed("{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"ping\"}\n")
        ch.feed("{\"jsonrpc\":\"2.0\",\"id\":78,\"method\":\"roots/list\"}\n")
        try await Task.sleep(nanoseconds: 150_000_000)
        let byID = Dictionary(uniqueKeysWithValues: ch.sent.compactMap { v in v["id"]?.intValue.map { ($0, v) } })
        XCTAssertNotNil(byID[77]?["result"])
        XCTAssertEqual(byID[78]?["error"]?["code"]?.intValue, -32601)
    }

    func testOversizedLineClosesTheChannelAndFailsPending() async throws {
        let ch = ScriptedChannel()
        let c = StdioMCPClient(channel: ch)
        ch.onSend = { _ in ch.feed(Data(repeating: 0x61, count: 9 * 1024 * 1024)) }
        do { try await c.ping(timeout: 5); XCTFail() }
        catch let e as PlaywrightTransportError { XCTAssertEqual(e.errorClass, "stdio_line_too_long") }
        XCTAssertTrue(ch.closed)
    }

    func testTimeoutSendsCancelAndFailsWithAClass() async throws {
        let ch = ScriptedChannel()
        let c = StdioMCPClient(channel: ch)
        await c.startReading()
        do { try await c.ping(timeout: 0.2); XCTFail() }
        catch let e as PlaywrightTransportError { XCTAssertEqual(e.errorClass, "playwright_timeout") }
        XCTAssertTrue(ch.sent.contains { $0["method"]?.stringValue == "notifications/cancelled" })
        // A late reply for the timed-out id is ignored.
        ch.feed(okReply(ch.sent.first?["id"]))
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testChannelCloseFailsPendingWithExited() async throws {
        let ch = ScriptedChannel()
        let c = StdioMCPClient(channel: ch)
        await c.startReading()
        async let p: Void = c.ping(timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        ch.finish()
        do { try await p; XCTFail() }
        catch let e as PlaywrightTransportError { XCTAssertEqual(e.errorClass, "playwright_exited") }
        do { try await c.ping(timeout: 1); XCTFail() }
        catch let e as PlaywrightTransportError { XCTAssertEqual(e.errorClass, "playwright_exited") }
    }

    func testRPCErrorBecomesAClassWithNoText() async throws {
        let ch = ScriptedChannel()
        let c = StdioMCPClient(channel: ch)
        await c.startReading()
        ch.onSend = { v in ch.feed("{\"jsonrpc\":\"2.0\",\"id\":\(v["id"]?.intValue ?? 0),\"error\":{\"code\":-1,\"message\":\"CANARY-page\"}}\n") }
        do { _ = try await c.callTool("x", arguments: [:], timeout: 2); XCTFail() }
        catch let e as PlaywrightTransportError { XCTAssertEqual(e.errorClass, "playwright_rpc_error") }
    }

    func testIsErrorResultPassesThrough() async throws {
        let ch = ScriptedChannel()
        let c = StdioMCPClient(channel: ch)
        await c.startReading()
        ch.onSend = { v in ch.feed("{\"jsonrpc\":\"2.0\",\"id\":\(v["id"]?.intValue ?? 0),\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"page text\"}]}}\n") }
        let r = try await c.callTool("x", arguments: [:], timeout: 2)
        XCTAssertEqual(r["isError"]?.boolValue, true)
        XCTAssertEqual(r["content"]?.arrayValue?.first?["text"]?.stringValue, "page text")
    }
}
