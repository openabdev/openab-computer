import Foundation
import Network
import XCTest
@testable import InstanceMCPCore

/// A tool slower than the fake runtime's ping budget.
struct SlowTool: Tool {
    let name = "slow"
    let description = "sleeps"
    let inputSchema: JSONValue = ["type": "object"]
    let seconds: Double
    func call(arguments: JSONValue) async throws -> ToolResult {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return .text("slow done")
    }
}

/// Plays the openab-pty runtime's liveness rule (`runtime/src/tools.rs`
/// `serve_attached`), scaled down: ping every `pingInterval`, count an interval
/// with no inbound frame (pong, ping or text) as missed, and close with 1000
/// after more than `maxMissed` — what evicted the Mac in #68. After
/// `initialize` it sends a slow `tools/call`, then a fast `echo`.
final class LivenessRuntime: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "liveness-runtime")
    let pingInterval: TimeInterval?
    let maxMissed: Int
    private var conn: NWConnection?
    private var timer: DispatchSourceTimer?
    private var missed = 0
    private var _evicted = false
    private var _pongs = 0
    private var _clientPings = 0
    private var _replyOrder: [Int] = []
    let finished = XCTestExpectation(description: "both calls answered")

    var evicted: Bool { queue.sync { _evicted } }
    var pongs: Int { queue.sync { _pongs } }
    var clientPings: Int { queue.sync { _clientPings } }
    var replyOrder: [Int] { queue.sync { _replyOrder } }

    /// `pingInterval == nil`: never ping (to observe the client's own pings).
    init(pingInterval: TimeInterval?, maxMissed: Int = 3) throws {
        self.pingInterval = pingInterval
        self.maxMissed = maxMissed
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = false   // deliver the client's pings to us so we can count them
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.port = self?.listener.port?.rawValue ?? 0; sem.signal() }
            if case .failed = st { sem.signal() }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        sem.wait()
    }

    func stop() {
        queue.sync { timer?.cancel(); conn?.cancel() }
        listener.cancel()
    }

    private func accept(_ c: NWConnection) {
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.ready(c) }
        }
        c.start(queue: queue)
    }

    private func ready(_ c: NWConnection) {
        receiveLoop(c)
        if let interval = pingInterval {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { [weak self] in self?.tick(c) }
            t.resume()
            timer = t
        }
        sendText(c, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                     "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                                "clientInfo": ["name": "openab-pty", "version": "t"]]])
    }

    private func tick(_ c: NWConnection) {
        guard !_evicted else { return }
        missed += 1
        if missed > maxMissed {
            _evicted = true
            timer?.cancel()
            let meta = NWProtocolWebSocket.Metadata(opcode: .close)
            meta.closeCode = .protocolCode(.normalClosure)
            let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
            c.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
            return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .ping)
        meta.setPongHandler(queue) { [weak self] error in
            guard let self, error == nil else { return }
            self._pongs += 1
            self.missed = 0
        }
        let ctx = NWConnection.ContentContext(identifier: "ping", metadata: [meta])
        c.send(content: Data(), contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    private func sendText(_ c: NWConnection, _ v: JSONValue) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "t", metadata: [meta])
        c.send(content: try! JSONCoding.encoder.encode(v), contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    private func receiveLoop(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch meta?.opcode {
            case .ping?:
                self._clientPings += 1
                self.missed = 0
                let pong = NWProtocolWebSocket.Metadata(opcode: .pong)
                let ctx = NWConnection.ContentContext(identifier: "pong", metadata: [pong])
                c.send(content: data ?? Data(), contentContext: ctx, isComplete: true, completion: .idempotent)
            case .pong?:
                self.missed = 0
            case .close?:
                return
            default:
                self.missed = 0
                if let data, let v = try? JSONCoding.decoder.decode(JSONValue.self, from: data) {
                    self.onReply(c, v)
                }
            }
            self.receiveLoop(c)
        }
    }

    private func onReply(_ c: NWConnection, _ v: JSONValue) {
        guard let id = v["id"]?.intValue else { return }
        if id == 1 {
            // The slow call first, then a fast one right behind it.
            sendText(c, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "slow", "arguments": [:]]])
            sendText(c, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "echo", "arguments": ["msg": "hi"]]])
            return
        }
        _replyOrder.append(id)
        if _replyOrder.count == 2 { finished.fulfill() }
    }
}

final class ReverseAttachLivenessTests: XCTestCase {
    func liveClient(port: UInt16, slow: Double, keepalive: TimeInterval) -> ReverseAttachClient {
        var cfg = ReverseAttachClient.Config(runtime: URL(string: "ws://127.0.0.1:\(port)")!, session: "laptop",
                                             secret: "s", profile: .owner, deadline: Date().addingTimeInterval(30))
        cfg.keepaliveInterval = keepalive
        let server = MCPServer(name: "t", version: "0", tools: [EchoTool(), SlowTool(seconds: slow)])
        return ReverseAttachClient(config: cfg, server: server)
    }

    /// #68: a tool call longer than the runtime's ping budget must not silence
    /// the socket. The runtime here evicts after ~0.8 s without an inbound frame
    /// and the tool takes 2.5 s. Our own keepalive is off, so only answered
    /// pings can keep the attach alive.
    func testSlowToolCallSurvivesTheRuntimePingBudget() async throws {
        let runtime = try LivenessRuntime(pingInterval: 0.2, maxMissed: 3)
        defer { runtime.stop() }
        let client = liveClient(port: runtime.port, slow: 2.5, keepalive: 0)
        await client.start()
        await fulfillment(of: [runtime.finished], timeout: 10)
        XCTAssertFalse(runtime.evicted, "the runtime evicted the Mac during a slow call")
        XCTAssertGreaterThanOrEqual(runtime.pongs, 5, "pings must be answered while the tool runs")
        XCTAssertEqual(runtime.replyOrder, [3, 2], "the fast call is answered while the slow one runs")
        let state = await client.state
        XCTAssertEqual(state, .attached)
        await client.cancel()
    }

    /// The second safeguard: while attached we ping the runtime ourselves.
    func testClientSendsItsOwnKeepalivePings() async throws {
        let runtime = try LivenessRuntime(pingInterval: nil)
        defer { runtime.stop() }
        let client = liveClient(port: runtime.port, slow: 0.1, keepalive: 0.2)
        await client.start()
        await fulfillment(of: [runtime.finished], timeout: 10)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertGreaterThanOrEqual(runtime.clientPings, 3, "keepalive pings reach the runtime")
        await client.cancel()
    }
}
