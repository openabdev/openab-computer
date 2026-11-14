import Foundation

/// A byte channel to a child MCP server. `incoming` carries chunks of the child's stdout and
/// finishes when the child's stdout closes. `send` queues bytes for the child's stdin and never
/// blocks the caller. `close` ends the channel (and, for a process, asks it to stop).
public protocol StdioChannel: Sendable {
    var incoming: AsyncStream<Data> { get }
    func send(_ data: Data)
    func close()
}

/// MCP over stdio (transport spec 2025-06-18): newline-delimited UTF-8 JSON-RPC, one message per
/// line. stdout is the protocol channel and is never logged. Every failure is a fixed class with
/// no child-supplied text (R7.4).
public actor StdioMCPClient {
    public static let maxLineBytes = 8 * 1024 * 1024
    public static let initializeTimeout: TimeInterval = 15
    public static let healthTimeout: TimeInterval = 2
    public static let callTimeout: TimeInterval = 90

    private let channel: any StdioChannel
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closedError: PlaywrightTransportError?
    private var reader: Task<Void, Never>?
    /// Lines that were not JSON. Counted, never logged.
    public private(set) var droppedLines = 0

    public init(channel: any StdioChannel) {
        self.channel = channel
    }

    /// Begin reading. Must be called once, before any request.
    public func startReading() {
        guard reader == nil else { return }
        let stream = channel.incoming
        reader = Task { [weak self] in
            for await chunk in stream { await self?.feed(chunk) }
            await self?.channelEnded(PlaywrightTransportError(errorClass: "playwright_exited"))
        }
    }

    public var isClosed: Bool { closedError != nil }

    // MARK: lifecycle

    /// `initialize` then `notifications/initialized`.
    public func initialize(timeout: TimeInterval = StdioMCPClient.initializeTimeout) async throws {
        startReading()
        _ = try await request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:],
            "clientInfo": ["name": "oab-computer", "version": "browser"],
        ], timeout: timeout)
        try sendLine(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    public func ping(timeout: TimeInterval = StdioMCPClient.healthTimeout) async throws {
        _ = try await request("ping", [:], timeout: timeout)
    }

    public func listTools(timeout: TimeInterval = StdioMCPClient.callTimeout) async throws -> [JSONValue] {
        let r = try await request("tools/list", [:], timeout: timeout)
        return r["tools"]?.arrayValue ?? []
    }

    public func callTool(_ name: String, arguments: JSONValue,
                         timeout: TimeInterval = StdioMCPClient.callTimeout) async throws -> JSONValue {
        try await request("tools/call", ["name": .string(name), "arguments": arguments], timeout: timeout)
    }

    public func close() {
        channel.close()
        channelEnded(PlaywrightTransportError(errorClass: "playwright_exited"))
    }

    // MARK: requests

    private func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        startReading()
        if let e = closedError { throw e }
        let id = nextID; nextID += 1
        let line = try Self.frame(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            pending[id] = cont
            channel.send(line)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timedOut(id)
            }
        }
    }

    private func timedOut(_ id: Int) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        try? sendLine(["jsonrpc": "2.0", "method": "notifications/cancelled",
                       "params": ["requestId": .number(Double(id)), "reason": "timeout"]])
        cont.resume(throwing: PlaywrightTransportError(errorClass: "playwright_timeout"))
    }

    /// Compact JSON plus `\n`. The encoder is not pretty-printing and escapes control characters,
    /// so the line holds no raw newline.
    static func frame(_ v: JSONValue) throws -> Data {
        var d = try JSONCoding.encoder.encode(v)
        guard !d.contains(0x0A) else { throw PlaywrightTransportError(errorClass: "playwright_bad_frame") }
        d.append(0x0A)
        return d
    }

    private func sendLine(_ v: JSONValue) throws {
        if let e = closedError { throw e }
        channel.send(try Self.frame(v))
    }

    // MARK: inbound

    private func feed(_ chunk: Data) {
        guard closedError == nil else { return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            if line.last == 0x0D { line = line.dropLast() }
            if line.count > Self.maxLineBytes { overflow(); return }
            if !line.isEmpty { handle(Data(line)) }
        }
        if buffer.count > Self.maxLineBytes { overflow() }
    }

    private func overflow() {
        buffer = Data()
        channel.close()
        channelEnded(PlaywrightTransportError(errorClass: "stdio_line_too_long"))
    }

    private func handle(_ line: Data) {
        guard let v = try? JSONCoding.decoder.decode(JSONValue.self, from: line), v.objectValue != nil else {
            droppedLines += 1; return
        }
        let hasID = v["id"] != nil && v["id"] != .null
        if let method = v["method"]?.stringValue {
            guard hasID else { return }   // notification
            let reply: JSONValue = method == "ping"
                ? ["jsonrpc": "2.0", "id": v["id"]!, "result": [:]]
                : ["jsonrpc": "2.0", "id": v["id"]!, "error": ["code": -32601, "message": "method not found"]]
            try? sendLine(reply)
            return
        }
        guard hasID, let id = v["id"]?.intValue, let cont = pending.removeValue(forKey: id) else { return }
        if v["error"] != nil { cont.resume(throwing: PlaywrightTransportError(errorClass: "playwright_rpc_error")) }
        else { cont.resume(returning: v["result"] ?? .null) }
    }

    private func channelEnded(_ error: PlaywrightTransportError) {
        if closedError == nil { closedError = error }
        let all = pending; pending = [:]
        for (_, c) in all { c.resume(throwing: closedError ?? error) }
    }
}
